#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Isolated synthetic replay. Do not load classifiers or touch camera capture,
 * IPC, or the production rmm. The generic IVA pixel processing is unmodified. */
int HM_Init(void) { return 0; }
int HM_Uninit(void) { return 0; }
int HM_Detection(void *image,int w,int h,int stride,float *confidence) {
    (void)image;(void)w;(void)h;(void)stride;*confidence=0;return 0;
}
static int64_t cpu_ns(void) {
    struct timespec t;clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);
    return (int64_t)t.tv_sec*1000000000+t.tv_nsec;
}
static void make_frame(unsigned char *p,int side,int phase) {
    for (int y=0;y<360;++y) for (int x=0;x<640;++x) {
        unsigned hash=(unsigned)(x*131+y*719);hash^=hash>>7;
        p[y*640+x]=100+hash%70;
        if (side && x> (side==1?30:350) && x<(side==1?290:610) && y>40 && y<320) {
            unsigned texture=(unsigned)((x+phase*3)*137+(y+phase*5)*811);
            texture^=texture>>5;p[y*640+x]=80+texture%120;
        }
    }
}
int main(int argc,char **argv) {
    alarm(45);nice(15);setvbuf(stdout,NULL,_IOLBF,0);
    if (argc!=2) return 2;
    void *lib=dlopen("/home/app/locallib/libYiHm_L1.so.4.1.9",RTLD_NOW|RTLD_GLOBAL);
    if (!lib) {fprintf(stderr,"dlopen: %s\n",dlerror());return 1;}
    int (*init)(void *,int,int)=dlsym(lib,"ivaInitMotionContext");
    int (*detect)(void *,void *,int16_t *,int64_t)=dlsym(lib,"ivaDetectMotion");
    int (*reset)(void *)=dlsym(lib,"ivaResetDetectMotion");
    int (*sensitivity)(void *,int)=dlsym(lib,"ivaSetSensitivityLevel");
    if (!init||!detect||!reset||!sensitivity) return 1;
    void *prototype=NULL;
    if (getenv("YI_IVA_REPLAY_MASK")) {
        prototype=dlopen("/tmp/yi-motion-iva-prototype.so",RTLD_NOW|RTLD_LOCAL);
        if (!prototype) {fprintf(stderr,"prototype: %s\n",dlerror());return 1;}
    }
    uint32_t context[48]={0};unsigned char *input=malloc(640*360),*private_frame=malloc(640*360);
    if (!input||!private_frame) return 1;
    if (init(context,640,360)) {fprintf(stderr,"init failed\n");return 1;}
    sensitivity(context,1);
    int masked=!strcmp(argv[1],"mask-left");
    for (int trial=0;trial<3;++trial) {
        int16_t rect[4]={0,0,(int16_t)(trial==0?640:320),360};
        int side=trial==2?2:1;
        reset(context);int signals=0,flags=0;unsigned peak=0,peak_run=0;
        int64_t preparation_ns=0,mask_ns=0,detector_ns=0;
        for (int frame=0;frame<110;++frame) {
            int64_t begin=cpu_ns();
            make_frame(input,frame>=25?side:0,frame);
            preparation_ns+=cpu_ns()-begin;begin=cpu_ns();
            unsigned char *image=input;
            if (masked) {
                memcpy(private_frame,input,640*360);
                for (int y=0;y<360;++y) memset(private_frame+y*640,128,320);
                image=private_frame;
            }
            mask_ns+=cpu_ns()-begin;begin=cpu_ns();
            int rc=detect(context,image,rect,100000+trial*100000+frame*100);
            detector_ns+=cpu_ns()-begin;
            unsigned char *foreground=(void *)(uintptr_t)context[76/4];
            unsigned count=0;for (int i=0;i<640*360;++i) count+=foreground[i]!=0;
            if (count>peak) peak=count;
            if (context[140/4]>peak_run) peak_run=context[140/4];
            if (rc) {signals++;flags|=rc;}
            usleep(2000);
        }
        printf("trial=%d side=%s rectangle=%s masked_left=%d nonzero_results=%d flags=%d peak_foreground=%u peak_run=%u prepare_cpu_ms=%.3f mask_cpu_ms=%.3f detector_cpu_ms=%.3f\n",
            trial,side==1?"left":"right",trial==0?"full":"left",masked,signals,flags,
            peak,peak_run,preparation_ns/110000000.0,mask_ns/110000000.0,detector_ns/110000000.0);
    }
    if (prototype) {
        void (*report)(void)=dlsym(prototype,"motion_iva_report");
        if (report) report();
    }
    /* Exit ends the private library worker. Do not unload a running SDK. */
    return 0;
}
