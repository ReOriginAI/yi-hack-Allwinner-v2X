#define _GNU_SOURCE
#include "motion_iva.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <stdlib.h>
#ifdef MOTION_IVA_REPLAY
#include <stdio.h>
#endif
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifdef __arm__
__attribute__((visibility("hidden"))) uintptr_t motion_iva_resume;
extern void motion_iva_boundary(void);
static struct motion_iva_shared *shared;
static struct motion_iva_settings active;
static unsigned active_generation,frame;
static unsigned startup_error;
#ifdef MOTION_IVA_REPLAY
static unsigned replay_scans,replay_mismatches;
static int64_t replay_cpu_ns;
static int64_t cpu_ns(void) {
    struct timespec t;clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);
    return (int64_t)t.tv_sec*1000000000+t.tv_nsec;
}
void motion_iva_report(void) {
    printf("production_replay_scans=%u mismatches=%u mean_hook_cpu_ms=%.4f\n",
        replay_scans,replay_mismatches,replay_scans?replay_cpu_ns/(replay_scans*1000000.0):0);
}
#endif
static int64_t mono_ms(void) {
    struct timespec t;if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
    return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000;
}
__attribute__((visibility("hidden")))
void motion_iva_filter(uint32_t *ctx,const int16_t *rect,uint32_t *registers) {
#ifdef MOTION_IVA_REPLAY
    int64_t replay_begin=cpu_ns();
#endif
    for (unsigned attempt=0;attempt<2;++attempt) {
        unsigned first=__atomic_load_n(&shared->config_generation,__ATOMIC_ACQUIRE);
        if (!first || (first&1) || first==active_generation) break;
        struct motion_iva_settings candidate;
        memcpy(&candidate,&shared->settings,sizeof(candidate));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (first!=__atomic_load_n(&shared->config_generation,__ATOMIC_ACQUIRE)) continue;
        if (!motion_iva_valid(&candidate)) break;
        /* Clear only the two audited motion counters when the mask changes.
         * The owner worker keeps reference frames and native cooldown intact. */
        if (ctx && ctx[0]==640 && ctx[1]==360 && (active.enabled || candidate.enabled))
            ctx[140/4]=ctx[144/4]=0;
        active=candidate;active_generation=first;
        break;
    }
    int64_t now=mono_ms();
    if (!active.enabled && (uint32_t)now-__atomic_load_n(&shared->reader_ms,__ATOMIC_RELAXED)>2500) return;
    struct motion_iva_sample sample={.monotonic_ms=now,.frame=++frame,
        .applied_generation=active_generation};
    if (startup_error) sample.error=startup_error;
    else if (!ctx || !rect || ctx[0]!=640 || ctx[1]!=360 ||
        ctx[20]!=640 || ctx[21]!=360 || ctx[22]!=640 || !ctx[19]) {
        sample.error=2;
    } else {
        const unsigned char *map=(void *)(uintptr_t)ctx[19];
        motion_iva_count(map,rect,&active,&sample);
        /* The original loop counts outside-ROI pixels in r4 and inside-ROI
         * pixels in fp. A mismatch resumes original recording decisions. */
        if (sample.raw_count!=registers[4]+registers[11]) sample.error=3;
        else if (active.enabled) {
            registers[4]=sample.included_count-sample.roi_count;
            registers[11]=sample.roi_count;
        }
    }
    unsigned generation=__atomic_load_n(&shared->generation,__ATOMIC_RELAXED);
    __atomic_store_n(&shared->generation,generation+1,__ATOMIC_SEQ_CST);
    shared->sample=sample;
    __atomic_store_n(&shared->generation,generation+2,__ATOMIC_RELEASE);
#ifdef MOTION_IVA_REPLAY
    replay_scans++;replay_mismatches+=sample.error==3;
    replay_cpu_ns+=cpu_ns()-replay_begin;
#endif
}
__attribute__((constructor)) static void initialize(void) {
#ifndef MOTION_IVA_REPLAY
    const char *model=getenv("YI_NIGHTVISION_MODEL");char exe[80];
    ssize_t n=readlink("/proc/self/exe",exe,sizeof(exe)-1);
    if (!model || strcmp(model,"y28ga") || n<0) return;
    exe[n]=0;if (strcmp(exe,"/home/app/rmm")) return;
#endif
    void *detect=dlsym(RTLD_DEFAULT,"ivaDetectMotion");Dl_info info;
    if (!detect || !dladdr(detect,&info)) return;
    uintptr_t base=(uintptr_t)info.dli_fbase,site=base+0xebba;
    if (*(uint16_t *)site!=0xf8dd || *(uint16_t *)(site+2)!=0xb028 ||
        *(uint16_t *)(base+0xe4c0)!=0x4bd4 || *(uint16_t *)(base+0xebbe)!=0x9b0b) return;
#ifndef MOTION_IVA_REPLAY
    if (*(uint32_t *)0x21394!=0xebffd000) return;
#endif
    int64_t displacement=(int64_t)((uintptr_t)motion_iva_boundary&~1U)-(int64_t)site-4;
    if ((displacement&1)||displacement< -16777216 || displacement>16777214) return;
    uint32_t immediate=(uint32_t)displacement&0x1ffffff,s=immediate>>24;
    uint16_t code[2]={0xf000|(s<<10)|((immediate>>12)&0x3ff),
        0x9000|((1^((immediate>>23)&1)^s)<<13)|((1^((immediate>>22)&1)^s)<<11)|((immediate>>1)&0x7ff)};
    int fd=open(MOTION_IVA_PATH,O_RDWR|O_CLOEXEC|O_NOFOLLOW);struct stat st;
    if (fd<0) return;
    if (fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size!=sizeof(*shared)) {close(fd);return;}
    shared=mmap(NULL,sizeof(*shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);close(fd);
    if (shared==MAP_FAILED) {shared=NULL;return;}
    if (shared->magic!=MOTION_IVA_MAGIC || shared->version!=MOTION_IVA_VERSION) return;
    shared->ready_pid=0;
    memset(active.cells,'0',sizeof(active.cells));
    long page=sysconf(_SC_PAGESIZE);if (page<1) return;
    uintptr_t start=site&~((uintptr_t)page-1);
    if (mprotect((void *)start,page,PROT_READ|PROT_WRITE|PROT_EXEC)) return;
    motion_iva_resume=site+4+1;memcpy((void *)site,code,sizeof(code));
    __builtin___clear_cache((char *)site,(char *)(site+4));
    /* The bridge must remain mapped even if restoring RX fails. The hook is
     * functional; expose that failure instead of removing its jump target. */
    if (mprotect((void *)start,page,PROT_READ|PROT_EXEC)) startup_error=4;
    __atomic_store_n(&shared->ready_pid,getpid(),__ATOMIC_RELEASE);
}
#endif
