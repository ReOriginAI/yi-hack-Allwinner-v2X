#ifndef YI_MOTION_IVA_H
#define YI_MOTION_IVA_H
#include <stdint.h>
#include <stddef.h>
#ifdef __ARM_NEON
#include <arm_neon.h>
#endif
#ifndef MOTION_IVA_PATH
#define MOTION_IVA_PATH "/tmp/yi-motion-iva"
#endif
#define MOTION_IVA_MAGIC 0x59495641U
#define MOTION_IVA_VERSION 1U
#define MOTION_IVA_CELLS 240U
struct motion_iva_settings { uint32_t enabled; char cells[MOTION_IVA_CELLS]; };
struct motion_iva_sample {
    int64_t monotonic_ms;
    uint32_t frame,raw_count,included_count,roi_count,applied_generation,error;
    uint32_t cells[MOTION_IVA_CELLS];
};
struct motion_iva_shared {
    uint32_t magic,version,config_generation,ready_pid,reader_ms,generation;
    struct motion_iva_settings settings;
    struct motion_iva_sample sample;
};
static inline int motion_iva_valid(const struct motion_iva_settings *s) {
    if (s->enabled>1) return 0;
    for (unsigned i=0;i<MOTION_IVA_CELLS;++i) if (s->cells[i]!='0' && s->cells[i]!='1') return 0;
    return 1;
}
static inline unsigned motion_iva_count32(const unsigned char *p) {
#ifdef __ARM_NEON
    uint8x16_t zero=vdupq_n_u8(0);
    uint8x16_t a=vshrq_n_u8(vmvnq_u8(vceqq_u8(vld1q_u8(p),zero)),7);
    uint8x16_t b=vshrq_n_u8(vmvnq_u8(vceqq_u8(vld1q_u8(p+16),zero)),7);
    uint32x4_t sums=vpaddlq_u16(vpaddlq_u8(vaddq_u8(a,b)));
    uint32x2_t pairs=vpadd_u32(vget_low_u32(sums),vget_high_u32(sums));
    return vget_lane_u32(vpadd_u32(pairs,pairs),0);
#else
    unsigned count=0;for (unsigned i=0;i<32;++i) count+=p[i]!=0;return count;
#endif
}
/* The native foreground is already eroded, row-major 640x360, byte-valued.
 * Counts use the full visible image denominator; no frame/reference writes. */
static inline void motion_iva_count(const unsigned char *map,const int16_t *rect,
        const struct motion_iva_settings *settings,struct motion_iva_sample *sample) {
    sample->raw_count=sample->included_count=sample->roi_count=0;
    for (unsigned i=0;i<MOTION_IVA_CELLS;++i) sample->cells[i]=0;
    for (int y=0;y<360;++y) {
        unsigned row=(unsigned)y/30;
        for (unsigned column=0;column<20;++column) {
            int left=(int)column*32,right=left+31;
            unsigned count=motion_iva_count32(map+y*640+left),roi=0;
            if (count && y>=rect[1] && y<=rect[3]) {
                if (left>=rect[0] && right<=rect[2]) roi=count;
                else if (right>=rect[0] && left<=rect[2]) {
                    int begin=left>rect[0]?left:rect[0],end=right<rect[2]?right:rect[2];
                    for (int x=begin;x<=end;++x) roi+=map[y*640+x]!=0;
                }
            }
            unsigned cell=row*20+column;
            sample->cells[cell]+=count;sample->raw_count+=count;
            if (!settings->enabled || settings->cells[cell]=='0') {
                sample->included_count+=count;sample->roi_count+=roi;
            }
        }
    }
}
#endif
