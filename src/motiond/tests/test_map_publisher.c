#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
static uintptr_t test_caller=0xaf6c0;
#define __arm__ 1
#define __builtin_return_address(level) ((void *)test_caller)
#include "../../ipc_cmd/ipc_cmd/motion_map_y623.c"

static unsigned native_calls;
static int native_error;
static unsigned char *sad;
static int fake_flush(void *address,int size) {
    ++native_calls;
    if (size==7360) { memset(address,0x5a,7360);memset(sad,0x3c,5520); }
    return native_error;
}
static void set_word(uintptr_t address,uint32_t value) {*(uint32_t *)address=value;}
int main(void) {
    void *global=mmap((void *)0x225000,4096,PROT_READ|PROT_WRITE,
                      MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
    void *heap=mmap((void *)0x1000000,32768,PROT_READ|PROT_WRITE,
                    MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);
    assert(global==(void *)0x225000 && heap==(void *)0x1000000);
    uintptr_t manager=0x1000000,node=0x1000080,component=0x1000300;
    uintptr_t private_data=0x1000400,encoder=0x1000600,state=0x1001000;
    unsigned char *vectors=(void *)0x1004000;sad=(void *)0x1006000;
    set_word(0x2256a8,manager);set_word(manager+24,node+136);
    set_word(node,1);set_word(node+4,component);set_word(node+136,manager+24);
    set_word(component,private_data);set_word(private_data+0x150,encoder);
    set_word(encoder+4,state);set_word(state+0x10c0,40);set_word(state+0x10c4,23);
    set_word(state+0x16a4,(uintptr_t)vectors);set_word(state+0x1c50,5520);
    set_word(state+0x1c58,(uintptr_t)sad);set_word(state+0x4b4,0);set_word(state+0x4d4,42);
    static struct motion_map_shared storage;shared=&storage;native_flush=fake_flush;
    assert(publish_after_flush(vectors,7360)==0);assert(native_calls==1 && !shared->generation);
    shared->enabled=1;struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
    shared->reader_ms=(uint32_t)((int64_t)now.tv_sec*1000+now.tv_nsec/1000000);
    assert(publish_after_flush(vectors,7360)==0);
    assert(native_calls==2 && shared->generation==2 && shared->sample.frame==42);
    assert(shared->sample.p_frame && shared->sample.pid==(uint32_t)getpid());
    for (unsigned i=0;i<7360;++i) assert(shared->sample.vectors[i]==0x5a);
    for (unsigned i=0;i<920;++i) assert(shared->sample.difference[i]==0x3c);
    set_word(state+0x4b4,18);publish_after_flush(vectors,7360);
    assert(shared->generation==4 && !shared->sample.p_frame); // Native key-frame type is not P.
    native_error=-1;assert(publish_after_flush(vectors,7360)==-1);assert(shared->generation==4);
    native_error=0;test_caller=0xaf3bc;publish_after_flush(vectors,7360);assert(shared->generation==4);
    test_caller=0xaf6c0;set_word(state+0x10c0,41);publish_after_flush(vectors,7360);assert(shared->generation==4);
    set_word(state+0x10c0,40);shared->reader_ms-=3000;publish_after_flush(vectors,7360);assert(shared->generation==4);
    munmap(global,4096);munmap(heap,32768);
    puts("publisher preserves native flush, copies post-cache data, bounds layout and expires abandoned requests");
}
