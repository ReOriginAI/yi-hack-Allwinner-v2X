#ifndef MOTION_MASK_H
#define MOTION_MASK_H
#include "../../ipc_cmd/ipc_cmd/motion_map.h"
#include <sys/mman.h>
#include <sys/stat.h>

struct motion_mask {
    int enabled, vector_pixels, difference_threshold, have_previous;
    char cells[MOTION_MASK_CELLS+1];
    char activity[MOTION_MASK_CELLS+1];
    struct motion_map_shared *shared;
    struct motion_map_frame frame;
    unsigned char previous[MOTION_MAP_BLOCKS];
    uint32_t last_pid,last_frame;
    unsigned source_version;
    long long previous_ms,retry_after;
    long long first_map_ms,last_predicted_ms;
    double ratio;
    int error,fallback;
};
static int motion_mask_valid(const char *cells) {
    if (strlen(cells)!=MOTION_MASK_CELLS) return 0;
    for (unsigned i=0;i<MOTION_MASK_CELLS;++i) if (cells[i]!='0' && cells[i]!='1') return 0;
    return 1;
}
static int motion_mask_signed(unsigned bits,unsigned sign) {
    return (int)(bits^sign)-(int)sign;
}
static int motion_mask_vector(const unsigned char *p,int pixels) {
    if (p[6]&128) return 0; /* Intra-coded: packed vector bits aren't motion. */
    unsigned lo=(unsigned)p[0]|(unsigned)p[1]<<8|(unsigned)p[2]<<16|(unsigned)p[3]<<24;
    unsigned hi=(unsigned)p[4]|(unsigned)p[5]<<8|(unsigned)p[6]<<16;
    int base_x=motion_mask_signed((hi>>15)&255,128)*4;
    int base_y=motion_mask_signed(p[5]&127,64)*4;
    int threshold=pixels*4;
    for (unsigned k=0;k<4;++k) {
        unsigned bx=k==3?p[4]>>3:(lo>>(k*10+5))&31;
        unsigned by=k==3?((unsigned)(p[4]&7)<<2)|(p[3]>>6):(lo>>(k*10))&31;
        int x=base_x+motion_mask_signed(bx,16),y=base_y+motion_mask_signed(by,16);
        if (x>=threshold || x<=-threshold || y>=threshold || y<=-threshold) return 1;
    }
    return 0;
}
/* Score as percent of the entire visible image. Excluded blocks contribute
 * zero; reducing the included area never amplifies the remaining movement.
 * The last coded row contains only 8 visible pixels, not 16. */
static double motion_mask_score(struct motion_mask *m,const struct motion_map_frame *s) {
    unsigned moving_pixels=0;
    memset(m->activity,'0',MOTION_MASK_CELLS);m->activity[MOTION_MASK_CELLS]=0;
    int temporal=m->have_previous && s->pid==m->last_pid &&
        s->monotonic_ms>m->previous_ms && s->monotonic_ms-m->previous_ms<=500;
    for (unsigned y=0;y<MOTION_MAP_ROWS;++y) for (unsigned x=0;x<MOTION_MAP_COLS;++x) {
        unsigned i=y*MOTION_MAP_COLS+x,h=y==22?8:16;
        unsigned row=(y*16+h/2)*MOTION_MASK_ROWS/360;
        unsigned col=x/2;
        const unsigned char *p=s->vectors+i*8;
        int delta=(int)s->difference[i]-m->previous[i];
        if (delta<0) delta=-delta;
        int moving=s->p_frame && (motion_mask_vector(p,m->vector_pixels) ||
            (temporal && (p[6]&128) && m->difference_threshold>0 && delta>=m->difference_threshold));
        if (moving) {
            m->activity[row*MOTION_MASK_COLS+col]='1';
            if (m->cells[row*MOTION_MASK_COLS+col]=='0') moving_pixels+=16*h;
        }
    }
    memcpy(m->previous,s->difference,sizeof(m->previous));
    m->have_previous=s->p_frame;
    m->previous_ms=s->monotonic_ms;
    m->last_pid=s->pid;m->last_frame=s->frame;
    return moving_pixels*100.0/(640*360);
}
static void motion_mask_close(struct motion_mask *m) {
    if (m->shared) {
        __atomic_store_n(&m->shared->enabled,0,__ATOMIC_RELEASE);
        munmap(m->shared,sizeof(*m->shared));m->shared=NULL;
    }
}
/* Return 1 for a fresh coherent frame, 0 for a duplicate, -1 unavailable.
 * Two bounded attempts; never wait for the encoder writer. */
static int motion_mask_read(struct motion_mask *m,long long now) {
    if (!m->shared) {
        if (now<m->retry_after) {m->error=1;return -1;}
        m->retry_after=now+1000;
        int fd=open(MOTION_MAP_PATH,O_RDWR|O_CLOEXEC|O_NOFOLLOW);
        struct stat st;
        if (fd<0) {m->error=1;return -1;}
        if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size!=sizeof(*m->shared)) {
            close(fd);m->error=1;return -1;
        }
        m->shared=mmap(NULL,sizeof(*m->shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
        close(fd);if (m->shared==MAP_FAILED) {m->shared=NULL;m->error=1;return -1;}
        if (m->shared->magic!=MOTION_MAP_MAGIC ||
            (m->shared->version!=MOTION_MAP_VERSION && m->shared->version!=MOTION_MAP_LEGACY_VERSION)) {
            munmap(m->shared,sizeof(*m->shared));m->shared=NULL;m->error=1;return -1;
        }
    }
    __atomic_store_n(&m->shared->reader_ms,(uint32_t)now,__ATOMIC_RELAXED);
    __atomic_store_n(&m->shared->enabled,1,__ATOMIC_RELEASE);
    for (unsigned attempt=0;attempt<2;++attempt) {
        struct motion_map_frame candidate;
        unsigned first=__atomic_load_n(&m->shared->generation,__ATOMIC_ACQUIRE);
        if (!first || (first&1)) continue;
        unsigned version=__atomic_load_n(&m->shared->version,__ATOMIC_RELAXED);
        if (version!=MOTION_MAP_VERSION && version!=MOTION_MAP_LEGACY_VERSION) break;
        memcpy(&candidate,&m->shared->sample,sizeof(candidate));
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (first!=__atomic_load_n(&m->shared->generation,__ATOMIC_ACQUIRE)) continue;
        if (version!=__atomic_load_n(&m->shared->version,__ATOMIC_RELAXED)) continue;
        if (!candidate.pid || now<candidate.monotonic_ms || now-candidate.monotonic_ms>500) break;
        if (version==MOTION_MAP_LEGACY_VERSION) candidate.p_frame=!candidate.p_frame;
        if (!m->first_map_ms) m->first_map_ms=now;
        if (candidate.p_frame) m->last_predicted_ms=now;
        if (now-(m->last_predicted_ms?m->last_predicted_ms:m->first_map_ms)>2000) {
            m->error=3;return -1; /* Fresh but unusable frame types must not suppress recording. */
        }
        m->source_version=version;
        m->frame=candidate;
        m->error=0;
        if (m->frame.pid==m->last_pid && m->frame.frame==m->last_frame) return 0;
        m->ratio=motion_mask_score(m,&m->frame);
        return 1;
    }
    if (m->last_pid && now>=m->frame.monotonic_ms && now-m->frame.monotonic_ms<=500) {
        m->error=0;return 0; /* Publication overlap keeps the last coherent score. */
    }
    m->error=2;return -1;
}
#endif
