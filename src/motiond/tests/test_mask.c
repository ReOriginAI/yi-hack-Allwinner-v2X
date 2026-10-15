#define _GNU_SOURCE
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include "../motiond/motion_mask.h"

static void vector(unsigned char *p,int x,int y) {
    uint64_t bits=((uint64_t)(x&255)<<47)|((uint64_t)(y&127)<<40);
    for (unsigned i=0;i<8;++i) p[i]=(unsigned char)(bits>>(i*8));
}
int main(void) {
    struct motion_mask m={.vector_pixels=1,.difference_threshold=12};
    memset(m.cells,'0',240);m.cells[240]=0;
    assert(motion_mask_valid(m.cells));m.cells[0]='x';assert(!motion_mask_valid(m.cells));m.cells[0]='0';
    assert(!motion_mask_valid("0"));
    unsigned char p[8]={0};
    assert(!motion_mask_vector(p,1));
    vector(p,1,0);assert(motion_mask_vector(p,1));assert(!motion_mask_vector(p,2));
    vector(p,-1,0);assert(motion_mask_vector(p,1));
    vector(p,0,-1);assert(motion_mask_vector(p,1));
    p[6]|=128;assert(!motion_mask_vector(p,1));
    for (unsigned k=0;k<4;++k) {
        uint64_t bits=4ULL<<(k*10+5);
        for (unsigned i=0;i<8;++i) p[i]=(unsigned char)(bits>>(i*8));
        assert(motion_mask_vector(p,1));
    }
    struct motion_map_frame s={.pid=1,.frame=1,.p_frame=1,.monotonic_ms=1000};
    vector(s.vectors,1,0);
    double one=256.0*100/(640*360);
    assert(motion_mask_score(&m,&s)==one);
    m.cells[0]='1';s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==0); // Exclusion removes a moving block.
    vector(s.vectors+39*8,1,0);s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==one); // Right edge remains detectable.
    memset(s.vectors,0,sizeof(s.vectors));
    vector(s.vectors+(22*40+39)*8,1,0);s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==one/2); // Coded padding never enters denominator.
    m.cells[11*20+19]='1';s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==0); // Last visible row maps to last UI row.
    memset(m.cells,'1',240);
    for (unsigned i=0;i<920;++i) vector(s.vectors+i*8,2,2);
    s.frame++;s.monotonic_ms+=100;assert(motion_mask_score(&m,&s)==0);
    memset(m.cells,'0',240);s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==100);
    memset(s.vectors,0,sizeof(s.vectors));s.vectors[6]=128;
    s.difference[0]=12;s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==one); // New intra blocks can change without a vector.
    s.frame++;s.monotonic_ms+=100;assert(motion_mask_score(&m,&s)==0);
    s.difference[0]=24;s.pid=2;s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==0); // Restart never compares unrelated reference frames.
    s.difference[0]=36;s.frame++;s.monotonic_ms+=501;
    assert(motion_mask_score(&m,&s)==0); // Stale temporal reference discarded.
    s.p_frame=0;s.frame++;s.monotonic_ms+=100;
    assert(motion_mask_score(&m,&s)==0); // I frames don't create periodic motion spikes.

    int fd=open(MOTION_MAP_PATH,O_RDWR|O_CREAT|O_EXCL,0600);assert(fd>=0);
    assert(!ftruncate(fd,sizeof(struct motion_map_shared)));
    struct motion_map_shared *map=mmap(NULL,sizeof(*map),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    assert(map!=MAP_FAILED);close(fd);
    map->magic=MOTION_MAP_MAGIC;map->version=MOTION_MAP_VERSION;
    map->generation=2;s.pid=5;s.frame=1;s.p_frame=1;s.monotonic_ms=10000;map->sample=s;
    assert(motion_mask_read(&m,10010)==1);assert(map->enabled==1);
    assert(motion_mask_read(&m,10020)==0); // No repeated confirmation on duplicate frame.
    map->generation=3;assert(motion_mask_read(&m,10030)==0); // Mid-publication keeps last coherent frame.
    map->generation=4;assert(motion_mask_read(&m,10501)==-1); // Frozen source reported unavailable.
    map->sample.monotonic_ms=11000;assert(motion_mask_read(&m,10999)==-1);
    map->sample.frame=2;assert(motion_mask_read(&m,11000)==1);
    map->version=MOTION_MAP_LEGACY_VERSION;map->generation+=2;
    map->sample.p_frame=0;map->sample.frame=3;map->sample.monotonic_ms=11100;
    assert(motion_mask_read(&m,11100)==1 && m.frame.p_frame); // Hot repair accepts old producer.
    map->sample.p_frame=1;map->sample.frame=4;map->sample.monotonic_ms=11200;map->generation+=2;
    assert(motion_mask_read(&m,11200)==1 && !m.frame.p_frame); // Legacy key frame stays excluded.
    map->version=MOTION_MAP_VERSION;map->sample.p_frame=1;map->sample.frame=5;
    map->sample.monotonic_ms=11300;map->generation+=2;
    assert(motion_mask_read(&m,11300)==1 && m.frame.p_frame); // Producer restart/upgrade in place.
    for (long long t=11400;t<=13700;t+=100) {
        map->sample.p_frame=0;map->sample.frame++;map->sample.monotonic_ms=t;map->generation+=2;
        int rc=motion_mask_read(&m,t);
        if (t>13300) assert(rc==-1 && m.error==3); // Fresh all-I source cannot silently disable recording.
    }
    map->sample.p_frame=1;map->sample.frame++;map->sample.monotonic_ms=14000;map->generation+=2;
    assert(motion_mask_read(&m,14000)==1 && !m.error);
    motion_mask_close(&m);assert(!map->enabled);
    munmap(map,sizeof(*map));unlink(MOTION_MAP_PATH);
    puts("mask scoring, geometry, frame freshness and bounded publication checks passed");
}
