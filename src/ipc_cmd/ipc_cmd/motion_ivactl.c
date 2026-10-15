#define _GNU_SOURCE
#include "motion_iva.h"
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
static int64_t mono_ms(void) {
    struct timespec t;if (clock_gettime(CLOCK_MONOTONIC,&t)) return 0;
    return (int64_t)t.tv_sec*1000+t.tv_nsec/1000000;
}
int main(int argc,char **argv) {
    int init=argc==4 && !strcmp(argv[1],"--init"),set=argc==4 && !strcmp(argv[1],"--set");
    int status=argc==2 && !strcmp(argv[1],"--status");
    if (!init && !set && !status) return 2;
    struct motion_iva_settings settings={0};
    if (init||set) {
        if (strcmp(argv[2],"yes") && strcmp(argv[2],"no")) return 2;
        if (strlen(argv[3])!=MOTION_IVA_CELLS) return 2;
        settings.enabled=!strcmp(argv[2],"yes");memcpy(settings.cells,argv[3],MOTION_IVA_CELLS);
        if (!motion_iva_valid(&settings)) return 2;
    }
    int fd=open(MOTION_IVA_PATH,O_RDWR|O_CLOEXEC|O_NOFOLLOW|(init?O_CREAT:0),0644);
    if (fd<0) {if (status) puts("null");return status?0:1;}
    struct stat st;if (fstat(fd,&st)||!S_ISREG(st.st_mode)) {close(fd);return 1;}
    if (init && st.st_size!=sizeof(struct motion_iva_shared)) {
        if (st.st_size || ftruncate(fd,sizeof(struct motion_iva_shared))) {close(fd);return 1;}
    } else if (st.st_size!=sizeof(struct motion_iva_shared)) {close(fd);return 1;}
    struct motion_iva_shared *shared=mmap(NULL,sizeof(*shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if (shared==MAP_FAILED) {close(fd);return 1;}
    if (init && !shared->magic) {shared->version=MOTION_IVA_VERSION;shared->magic=MOTION_IVA_MAGIC;}
    if (shared->magic!=MOTION_IVA_MAGIC || shared->version!=MOTION_IVA_VERSION) {close(fd);return 1;}
    if (init||set) {
        /* Embedded kernels reject filesystem locking. Serialize controllers
         * with a bounded atomic writer lock; the detector never waits. Only
         * boot initialization without a live owner may recover an odd lock. */
        unsigned generation=__atomic_load_n(&shared->config_generation,__ATOMIC_ACQUIRE);
        unsigned pid=__atomic_load_n(&shared->ready_pid,__ATOMIC_ACQUIRE);
        if (init && (generation&1) && (!pid || kill((pid_t)pid,0)))
            __atomic_store_n(&shared->config_generation,0,__ATOMIC_RELEASE);
        int locked=0;
        for (unsigned attempt=0;attempt<50;++attempt) {
            generation=__atomic_load_n(&shared->config_generation,__ATOMIC_ACQUIRE);
            if (!(generation&1) && __atomic_compare_exchange_n(&shared->config_generation,
                    &generation,generation+1,0,__ATOMIC_ACQ_REL,__ATOMIC_ACQUIRE)) {
                locked=1;break;
            }
            usleep(1000);
        }
        if (!locked) {munmap(shared,sizeof(*shared));close(fd);return 1;}
        int identical=generation && !memcmp(&shared->settings,&settings,sizeof(settings));
        if (!identical) shared->settings=settings;
        __atomic_store_n(&shared->config_generation,identical?generation:generation+2,__ATOMIC_RELEASE);
        munmap(shared,sizeof(*shared));close(fd);return 0;
    }
    int64_t now=mono_ms();__atomic_store_n(&shared->reader_ms,(uint32_t)now,__ATOMIC_RELAXED);
    struct motion_iva_sample sample={0};int coherent=0;
    for (unsigned attempt=0;attempt<3;++attempt) {
        unsigned first=__atomic_load_n(&shared->generation,__ATOMIC_ACQUIRE);
        if (!first || (first&1)) continue;
        memcpy(&sample,&shared->sample,sizeof(sample));__atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (first==__atomic_load_n(&shared->generation,__ATOMIC_ACQUIRE)) {coherent=1;break;}
    }
    unsigned config=__atomic_load_n(&shared->config_generation,__ATOMIC_ACQUIRE);
    int requested=__atomic_load_n(&shared->settings.enabled,__ATOMIC_RELAXED);
    unsigned pid=__atomic_load_n(&shared->ready_pid,__ATOMIC_ACQUIRE);
    int ready=pid && kill((pid_t)pid,0)==0;
    int error=!ready?1:!coherent?5:sample.error;
    int64_t age=coherent?now-sample.monotonic_ms:-1;
    if (!error && (age<0 || age>3500)) error=5;
    int pending=!coherent || (config&1) || config!=sample.applied_generation;
    char activity[MOTION_IVA_CELLS+1];
    for (unsigned i=0;i<MOTION_IVA_CELLS;++i) activity[i]=sample.cells[i]?'1':'0';
    activity[MOTION_IVA_CELLS]=0;
    printf("{\"enabled\":%s,\"ready\":%s,\"pending\":%s,\"error\":%d,\"fallback\":%s,\"age_ms\":%lld,\"monotonic_ms\":%lld,\"ratio\":%.5f,\"raw_ratio\":%.5f,\"raw_count\":%u,\"included_count\":%u,\"activity\":\"%s\"}\n",
        requested?"true":"false",ready?"true":"false",pending?"true":"false",error,
        requested && (!ready || sample.error)?"true":"false",(long long)age,(long long)sample.monotonic_ms,
        sample.included_count*100.0/230400,sample.raw_count*100.0/230400,sample.raw_count,sample.included_count,activity);
    munmap(shared,sizeof(*shared));close(fd);return 0;
}
