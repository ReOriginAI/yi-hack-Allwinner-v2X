/* Synthetic copy/mask resource benchmark. Does not access camera frames or
 * vendor functions. Actual IVA strides and reference behavior remain unknown.
 * Source allocation represents an existing shared frame; only destination is
 * the proposed additional scratch allocation. */
#define _POSIX_C_SOURCE 200809L
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define BYTES 356352U
#define WIDTH 640U
#define HEIGHT 360U
static volatile unsigned checksum;
static int64_t nanoseconds(clockid_t clock) {
    struct timespec t;
    if (clock_gettime(clock,&t)) return -1;
    return (int64_t)t.tv_sec*1000000000+t.tv_nsec;
}
int main(void) {
    unsigned char *source=malloc(BYTES),*masked=malloc(BYTES);
    if (!source || !masked) { free(source);free(masked);return 1; }
    for (unsigned i=0;i<BYTES;++i) source[i]=(unsigned char)i;
    setpriority(PRIO_PROCESS,0,15);
    int64_t cpu_total=0,wall_total=0,max_wall=0;
    const unsigned count=100;
    for (unsigned i=0;i<count;++i) {
        source[(i*131U)%BYTES]^=(unsigned char)i;
        int64_t cpu=nanoseconds(CLOCK_PROCESS_CPUTIME_ID),wall=nanoseconds(CLOCK_MONOTONIC);
        memcpy(masked,source,BYTES);
        for (unsigned y=0;y<HEIGHT;++y) memset(masked+y*WIDTH,16,WIDTH/2);
        for (unsigned y=0;y<HEIGHT/2;++y) memset(masked+WIDTH*HEIGHT+y*WIDTH,128,WIDTH/2);
        checksum+=masked[(i*197U)%BYTES];
        int64_t spent=nanoseconds(CLOCK_MONOTONIC)-wall;
        wall_total+=spent;cpu_total+=nanoseconds(CLOCK_PROCESS_CPUTIME_ID)-cpu;
        if (spent>max_wall) max_wall=spent;
        struct timespec pause={.tv_nsec=100000000};nanosleep(&pause,NULL);
    }
    printf("synthetic_NV21_left_half_mask bytes=%u source_bytes=%u additional_scratch_bytes=%u "
           "samples=%u mean_cpu_us=%.3f mean_wall_us=%.3f max_wall_us=%.3f "
           "estimated_CPU_10Hz_percent=%.4f checksum=%u\n",
           BYTES,BYTES,BYTES,count,cpu_total/(1000.0*count),wall_total/(1000.0*count),
           max_wall/1000.0,cpu_total/(1000000.0*count),checksum);
    free(source);free(masked);return 0;
}
