/* Wrap a verified SquashFS prefix for the vendor U-Boot updater. SD output only. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static uint32_t crc(const unsigned char *p, size_t n) {
    uint32_t c=~0u; while(n--) { c^=*p++; for(int i=0;i<8;i++) c=(c>>1)^((0u-(c&1))&0xedb88320u); } return ~c;
}
static uint32_t le(const unsigned char *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static void be(unsigned char *p,uint32_t n) { p[0]=n>>24;p[1]=n>>16;p[2]=n>>8;p[3]=n; }
int main(int argc,char **argv) {
    if(argc!=4 || (strcmp(argv[2],"rootfs") && strcmp(argv[2],"home"))) return 1;
    size_t limit=!strcmp(argv[2],"rootfs")?0x120000:0x340000;
    FILE *in=fopen(argv[1],"rb"); unsigned char sb[96],h[64]={0};
    if(!in || fread(sb,1,sizeof sb,in)!=sizeof sb || memcmp(sb,"hsqs",4) || (le(sb+28)&65535)!=4 || le(sb+44)) return 2;
    size_t used=le(sb+40),n=(used+4095)&~(size_t)4095;
    if(used<96 || n+64>limit) return 3;
    unsigned char *data=malloc(n); if(!data || fseek(in,0,SEEK_SET) || fread(data,1,n,in)!=n) return 4;
    fclose(in); be(h,0x27051956);be(h+12,n);be(h+24,crc(data,n));h[28]=5;h[29]=2;h[30]=7;
    snprintf((char*)h+32,32,"xiaoyi-%s",argv[2]);be(h+4,crc(h,64));
    FILE *out=fopen(argv[3],"wb");if(!out) return 5;
    if(fwrite(h,1,64,out)!=64 || fwrite(data,1,n,out)!=n || fclose(out)) return 6;
    free(data);printf("%zu\n",n/4096);return 0;
}
