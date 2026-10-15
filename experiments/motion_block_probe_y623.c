/* Read-only resource probe for the audited y623 rmm (MD5
 * eb9d532e71d0d8697d22d0775b744b40). Never calls the vendor SDK, attaches a
 * debugger, writes target memory, or controls recording. Not a detector.
 * The offsets are specific to this binary. Run only after verifying its hash.
 */
#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define MAX_BYTES 93312U
static int memory_fd;
static int read_memory(uint32_t address, void *output, size_t size) {
    if (address < 0x10000U || address > 0xc0000000U ||
        size > MAX_BYTES || size > 0xc0000000U-address) return -1;
    return pread(memory_fd, output, size, (off_t)address) == (ssize_t)size ? 0 : -1;
}
static int word(uint32_t address, uint32_t *value) {
    return read_memory(address, value, sizeof(*value));
}
static int channel_state(unsigned wanted_channel, uint32_t *state) {
    uint32_t manager, link, channel, component, private_data, encoder;
    if (word(0x2256a8, &manager) || word(manager+24, &link)) return -1;
    for (int i=0; i<16 && link != manager+24; ++i) {
        if (link < 136 || word(link-136, &channel)) return -1;
        if (channel==wanted_channel) {
            if (word(link-132, &component) || word(component, &private_data) ||
                word(private_data+0x150, &encoder) || word(encoder+4, state)) return -1;
            return 0;
        }
        if (word(link, &link)) return -1;
    }
    return -1;
}
static int signed_bits(unsigned value, unsigned sign) {
    return (int)(value ^ sign) - (int)sign;
}
/* Same packed-vector extraction as the audited encoder's motion-analysis
 * loop. The mask experiment excludes the left half at macroblock boundaries.
 * Motion threshold here is illustrative (quarter-pixel vectors), unrelated to
 * vendor BinImgRatio/SAD thresholds. No detection verdict is produced. */
static void filter(const unsigned char *data, unsigned width, unsigned height,
                   unsigned *moving, unsigned *kept) {
    unsigned stride=(width+3)&~3U;
    *moving=*kept=0;
    for (unsigned y=0; y<height; ++y) for (unsigned x=0; x<width; ++x) {
        const unsigned char *p=data+(y*stride+x)*8;
        unsigned lo=(unsigned)p[0]|(unsigned)p[1]<<8|(unsigned)p[2]<<16|(unsigned)p[3]<<24;
        unsigned hi=(unsigned)p[4]|(unsigned)p[5]<<8|(unsigned)p[6]<<16|(unsigned)p[7]<<24;
        int base_x=signed_bits((hi>>15)&255,128)*4;
        int base_y=signed_bits(p[5]&127,64)*4;
        int changed=0;
        for (unsigned k=0; k<4; ++k) {
            unsigned bx=k==3 ? p[4]>>3 : (lo>>(k*10+5))&31;
            unsigned by=k==3 ? ((unsigned)(p[4]&7)<<2)|(p[3]>>6) : (lo>>(k*10))&31;
            int vx=base_x+signed_bits(bx,16), vy=base_y+signed_bits(by,16);
            if (vx>=4 || vx<=-4 || vy>=4 || vy<=-4) changed=1;
        }
        if (changed) { ++*moving; if (x>=width/2) ++*kept; }
    }
}
static int64_t nanoseconds(clockid_t clock) {
    struct timespec value;
    if (clock_gettime(clock,&value)) return -1;
    return (int64_t)value.tv_sec*1000000000+value.tv_nsec;
}
int main(int argc, char **argv) {
    if (argc!=4) { fprintf(stderr,"usage: %s rmm_pid channel_0_or_1 samples_1_to_300\n",argv[0]); return 2; }
    long pid=strtol(argv[1],NULL,10), channel=strtol(argv[2],NULL,10), count=strtol(argv[3],NULL,10);
    if (pid<1 || channel<0 || channel>1 || count<1 || count>300) return 2;
    char path[64]; snprintf(path,sizeof(path),"/proc/%ld/mem",pid);
    memory_fd=open(path,O_RDONLY|O_CLOEXEC);
    if (memory_fd<0) { perror("open target memory"); return 1; }
    uint32_t guard[2], state, geometry[8], buffer, bytes, enabled;
    if (read_memory(0x29ab8,guard,sizeof(guard)) || guard[0]!=0xe3a00000U ||
        guard[1]!=0xe12fff1eU || channel_state((unsigned)channel,&state) ||
        read_memory(state+0x10a8,geometry,sizeof(geometry)) ||
        word(state+0x16a4,&buffer) || word(state+0x16ac,&bytes) ||
        word(state+0x16b0,&enabled) || geometry[0]!=(channel?640U:2304U) ||
        geometry[1]!=(channel?368U:1296U) || geometry[6]!=(channel?40U:144U) ||
        geometry[7]!=(channel?23U:81U) || bytes!=(channel?7360U:MAX_BYTES) || enabled!=1) {
        fprintf(stderr,"Unsupported or unavailable encoder context\n"); close(memory_fd); return 1;
    }
    unsigned char *a=malloc(bytes),*b=malloc(bytes);
    if (!a || !b) { free(a);free(b);close(memory_fd);return 1; }
    setpriority(PRIO_PROCESS,0,15);
    unsigned accepted=0, inconsistent=0, failed=0, fresh=0, last_frame=0;
    int64_t cpu_total=0,read_cpu_total=0,filter_cpu_total=0,wall_total=0,wall_max=0,wall_min=INT64_MAX;
    unsigned moving=0,kept=0;
    for (long i=0;i<count;++i) {
        uint32_t before,after,current_buffer,current_bytes;
        int64_t cpu=nanoseconds(CLOCK_PROCESS_CPUTIME_ID),wall=nanoseconds(CLOCK_MONOTONIC);
        int bad=word(state+0x4d4,&before) || word(state+0x16a4,&current_buffer) ||
            word(state+0x16ac,&current_bytes) || current_buffer!=buffer || current_bytes!=bytes ||
            read_memory(buffer,a,bytes) || read_memory(buffer,b,bytes) || word(state+0x4d4,&after);
        int64_t read_finished=nanoseconds(CLOCK_PROCESS_CPUTIME_ID);
        read_cpu_total+=read_finished-cpu;
        if (bad) ++failed;
        else if (before!=after || memcmp(a,b,bytes)) ++inconsistent;
        else {
            filter(a,geometry[6],geometry[7],&moving,&kept);
            ++accepted;if(after!=last_frame)++fresh;last_frame=after;
        }
        filter_cpu_total+=nanoseconds(CLOCK_PROCESS_CPUTIME_ID)-read_finished;
        int64_t spent=nanoseconds(CLOCK_MONOTONIC)-wall;
        wall_total+=spent;cpu_total+=nanoseconds(CLOCK_PROCESS_CPUTIME_ID)-cpu;
        if(spent>wall_max)wall_max=spent;
        if(spent<wall_min)wall_min=spent;
        printf("sample=%ld accepted=%d frame=%u read_filter_wall_us=%.3f moving_mb=%u after_left_half_mask=%u\n",
               i,!bad && before==after && !memcmp(a,b,bytes),bad?0:after,spent/1000.0,moving,kept);
        struct timespec pause={.tv_nsec=100000000}; nanosleep(&pause,NULL);
    }
    printf("summary channel=%ld bytes=%u scratch_bytes=%u accepted=%u inconsistent=%u failed=%u fresh=%u "
           "mean_cpu_us=%.3f mean_read_cpu_us=%.3f mean_check_filter_cpu_us=%.3f "
           "mean_wall_us=%.3f min_wall_us=%.3f max_wall_us=%.3f estimated_CPU_10Hz_percent=%.4f\n",
           channel,bytes,bytes*2,accepted,inconsistent,failed,fresh,cpu_total/(1000.0*count),
           read_cpu_total/(1000.0*count),filter_cpu_total/(1000.0*count),
           wall_total/(1000.0*count),wall_min/1000.0,wall_max/1000.0,cpu_total/(1000000.0*count));
    free(a);free(b);close(memory_fd);
    return failed || !accepted ? 1 : 0;
}
