#define _GNU_SOURCE
#define __arm__ 1
#include <assert.h>
#include <stdio.h>
#include "../../ipc_cmd/ipc_cmd/motion_iva_y28ga.c"
void motion_iva_boundary(void) {}
int main(void) {
    unsigned char *map=mmap(NULL,230400,PROT_READ|PROT_WRITE,
        MAP_PRIVATE|MAP_ANONYMOUS|MAP_32BIT,-1,0);
    assert(map!=MAP_FAILED && (uintptr_t)map<=UINT32_MAX);
    uint32_t context[48]={0},registers[14]={0};
    int16_t rectangle[4]={0,0,319,359};
    context[0]=context[20]=context[22]=640;context[1]=context[21]=360;
    context[19]=(uintptr_t)map;
    struct motion_iva_shared control={.magic=MOTION_IVA_MAGIC,.version=MOTION_IVA_VERSION};
    shared=&control;
    memset(control.settings.cells,'0',240);control.settings.enabled=1;
    for (unsigned row=0;row<12;++row) memset(control.settings.cells+row*20,'1',10);
    control.config_generation=2;
    map[10*640+10]=255;map[10*640+330]=255;
    map[359*640+639]=255;map[0]=255;
    registers[4]=2;registers[11]=2;
    context[35]=context[36]=5;
    motion_iva_filter(context,rectangle,registers);
    assert(!control.sample.error && control.sample.raw_count==4 && control.sample.included_count==2);
    assert(control.sample.roi_count==0 && registers[4]==2 && registers[11]==0);
    assert(context[35]==0 && context[36]==0);
    assert(control.sample.cells[0]==2 && control.sample.cells[10]==1 && control.sample.cells[239]==1);
    /* Duplicate saved settings retain native confirmation counters. */
    context[35]=3;registers[4]=registers[11]=2;
    motion_iva_filter(context,rectangle,registers);assert(context[35]==3);
    /* A writer collision retains the last coherent mask without waiting. */
    control.config_generation=3;memset(control.settings.cells,'0',240);
    registers[4]=registers[11]=2;motion_iva_filter(context,rectangle,registers);
    assert(control.sample.included_count==2 && control.sample.applied_generation==2);
    /* A layout/counter mismatch must preserve original recording decisions. */
    registers[4]=17;registers[11]=22;motion_iva_filter(context,rectangle,registers);
    assert(control.sample.error==3 && registers[4]==17 && registers[11]==22);
    /* Apply Include all, then Ignore all, including boundaries. */
    control.config_generation=4;registers[4]=registers[11]=2;
    motion_iva_filter(context,rectangle,registers);
    assert(!control.sample.error && registers[4]==2 && registers[11]==2);
    memset(control.settings.cells,'1',240);control.config_generation=6;
    registers[4]=registers[11]=2;motion_iva_filter(context,rectangle,registers);
    assert(registers[4]==0 && registers[11]==0 && control.sample.included_count==0);
    context[20]=1280;registers[4]=registers[11]=2;
    motion_iva_filter(context,rectangle,registers);
    assert(control.sample.error==2 && registers[4]==2 && registers[11]==2);
    context[20]=640;
    /* Disabling restores all native counts. */
    control.settings.enabled=0;control.config_generation=8;
    control.reader_ms=(uint32_t)mono_ms();registers[4]=registers[11]=2;
    motion_iva_filter(context,rectangle,registers);
    assert(!control.sample.error && control.sample.included_count==4 && registers[4]==2 && registers[11]==2);
    uint32_t frame_before=frame;
    control.reader_ms=(uint32_t)mono_ms()-5000;
    motion_iva_filter(context,rectangle,registers);assert(frame==frame_before);
    assert(motion_iva_valid(&control.settings));control.settings.cells[3]='x';
    assert(!motion_iva_valid(&control.settings));
    munmap(map,230400);puts("Native IVA mask counting, controls and fallback passed.");return 0;
}
