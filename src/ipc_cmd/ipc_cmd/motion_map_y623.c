#define _GNU_SOURCE
#include "motion_map.h"
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifdef __arm__
/* The launcher checks the exact y623 motion-lite rmm MD5. Constructor guards
 * additionally verify the native cache callback and both relevant call sites.
 * No driver, video buffer, motion result, or encoder parameter is modified. */
static struct motion_map_shared *shared;
static int (*native_flush)(void *, int);
static uint32_t load_word(uintptr_t p) { return *(uint32_t *)p; }
static uintptr_t substream_state(void) {
    uintptr_t manager=load_word(0x2256a8);
    if (!manager) return 0;
    uintptr_t head=manager+24, link=load_word(head);
    for (unsigned i=0;i<16 && link && link!=head;++i) {
        uintptr_t node=link-136;
        if (load_word(node)==1) {
            uintptr_t component=load_word(node+4);
            if (!component) return 0;
            uintptr_t private_data=load_word(component);
            if (!private_data) return 0;
            uintptr_t encoder=load_word(private_data+0x150);
            return encoder ? load_word(encoder+4) : 0;
        }
        link=load_word(link);
    }
    return 0;
}
static int publish_after_flush(void *address, int size) {
    uintptr_t caller=(uintptr_t)__builtin_return_address(0);
    int result=native_flush(address,size);
    /* The native analysis loop has already invalidated its SAD buffer, then
     * invalidates MV data here, after hardware completion and before analyzing
     * the next frame. This is an encoder-owner snapshot, not a DMA race reader. */
    if (result || caller!=0xaf6c0 || size!=7360 ||
        !__atomic_load_n(&shared->enabled,__ATOMIC_RELAXED)) return result;
    uintptr_t state=substream_state();
    if (!state || load_word(state+0x10c0)!=40 || load_word(state+0x10c4)!=23 ||
        load_word(state+0x16a4)!=(uintptr_t)address ||
        load_word(state+0x1c50)!=5520 || !load_word(state+0x1c58)) return result;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC,&now)) return result;
    int64_t now_ms=(int64_t)now.tv_sec*1000+now.tv_nsec/1000000;
    if ((uint32_t)now_ms-__atomic_load_n(&shared->reader_ms,__ATOMIC_RELAXED)>2000) return result;
    const unsigned char *sad=(void *)(uintptr_t)load_word(state+0x1c58);
    unsigned generation=__atomic_load_n(&shared->generation,__ATOMIC_RELAXED);
    __atomic_store_n(&shared->generation,generation+1,__ATOMIC_SEQ_CST);
    shared->sample.pid=(uint32_t)getpid();
    shared->sample.frame=load_word(state+0x4d4);
    /* The audited encoder sets the output key-frame flag when this native
     * type is 18 (ae458..ae474); ordinary predicted frames have type zero.
     * Version 1 accidentally published the key-frame test as p_frame. */
    shared->sample.p_frame=load_word(state+0x4b4)!=18;
    shared->sample.monotonic_ms=now_ms;
    memcpy(shared->sample.vectors,address,7360);
    for (unsigned i=0;i<MOTION_MAP_BLOCKS;++i) shared->sample.difference[i]=sad[i*6];
    __atomic_store_n(&shared->generation,generation+2,__ATOMIC_RELEASE);
    return result;
}
__attribute__((constructor)) static void initialize_map(void) {
    const char *model=getenv("YI_NIGHTVISION_MODEL");
    char exe[80];ssize_t n=readlink("/proc/self/exe",exe,sizeof(exe)-1);
    if (!model || strcmp(model,"y623") || n<0) return;
    exe[n]=0;if (strcmp(exe,"/home/app/rmm")) return;
    if (load_word(0x1747e8+24)!=0xce2d8 || load_word(0xaf6bc)!=0xeb0079c8 ||
        load_word(0xaf528)!=0xeb007a2d || load_word(0x29ab8)!=0xe3a00000) return;
    int fd=open(MOTION_MAP_PATH,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0644);
    if (fd<0) return;
    struct stat st;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) ||
        ftruncate(fd,sizeof(*shared))) {close(fd);return;}
    shared=mmap(NULL,sizeof(*shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    close(fd);if (shared==MAP_FAILED) {shared=NULL;return;}
    memset(shared,0,sizeof(*shared));
    shared->magic=MOTION_MAP_MAGIC;shared->version=MOTION_MAP_VERSION;
    native_flush=(void *)0xce2d8;
    __atomic_store_n((uintptr_t *)(0x1747e8+24),(uintptr_t)publish_after_flush,__ATOMIC_RELEASE);
}
#endif
