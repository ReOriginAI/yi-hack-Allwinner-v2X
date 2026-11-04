/* Exercise captured U-Boot SD selection against synthetic FAT32 layouts.
 * Private U-Boot dumps are local inputs; no vendor binary is distributed.
 * Hardware reads use an in-memory boot sector. The updater's large allocation
 * is deliberately refused, stopping execution before image loading or writes.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

struct profile {
    const char *model;
    unsigned offset, crc;
    uintptr_t part_init, select_fs, open_device, sd_init, update, selector;
    uintptr_t logger, puts, aligned, free, crc32, number, format;
    uintptr_t memcmp, strlen, strcmp, strncmp, strchr, strdup;
};

static const struct profile profiles[] = {
    {"y623", 0x19c00, 0x5c4ce9ea,
     0x4a009915, 0x4a0143a1, 0x4a009a5c, 0x4a004fac, 0x4a01b761, 0x4a027fc0,
     0x4a01adc0, 0x4a007b52, 0x4a008850, 0x4a007fc0, 0x4a01a0f0, 0x4a01aee0, 0x4a01ad38,
     0x4a01a37a, 0x4a01a2ba, 0x4a01a26a, 0x4a01a280, 0x4a01a2a2, 0x4a01a310},
    {"y28ga", 0x18c00, 0xe15d863c,
     0x4a0099c5, 0x4a014425, 0x4a009b0c, 0x4a00506c, 0x4a01b7c1, 0x4a027af8,
     0x4a01ae40, 0x4a007c02, 0x4a008900, 0x4a008070, 0x4a01a174, 0x4a01af60, 0x4a01adb8,
     0x4a01a3fe, 0x4a01a33e, 0x4a01a2ee, 0x4a01a304, 0x4a01a326, 0x4a01a394}
};

static unsigned descriptor[64], partitioned, stopped;
static unsigned char boot_sector[512], mbr[512];

static unsigned crc32(unsigned seed, const void *data, unsigned size)
{
    const unsigned char *bytes = data;
    unsigned value = seed ^ 0xffffffffu;
    while (size--) {
        value ^= *bytes++;
        for (int bit = 0; bit < 8; bit++)
            value = (value >> 1) ^ (0xedb88320u & -(value & 1));
    }
    return value ^ 0xffffffffu;
}

static void redirect(uintptr_t address, uintptr_t target)
{
    uint16_t *code = (void *)address;
    code[0] = 0xf8df;
    code[1] = 0xf000 | (address & 2); /* PC is aligned down to four bytes. */
    memcpy((void *)(address + 4), &target, 4);
}

static int log_message(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int count = vprintf(format, arguments);
    va_end(arguments);
    return count;
}

static unsigned number(const char *text, char **end, int base)
{
    return strtoul(text, end, base);
}

static void *aligned(unsigned alignment, unsigned size)
{
    if (size == 0x800000) {
        stopped++;
        return NULL;
    }
    void *pointer = NULL;
    if (posix_memalign(&pointer, alignment, size))
        return NULL;
    return pointer;
}

static int sd_ready(void) { return 0; }

static int open_sd(const char *interface, const char *device, void **result)
{
    if (strcmp(interface, "mmc") || (strcmp(device, "0") && strcmp(device, "0.0")))
        return -1;
    *result = descriptor;
    return 0;
}

static unsigned sd_read(void *device, unsigned sector, unsigned count, void *buffer)
{
    (void)device;
    if (count > 2048 || sector > descriptor[4] || count > descriptor[4] - sector)
        return 0;
    memset(buffer, 0, count * 512);
    for (unsigned i = 0; i < count; i++) {
        unsigned char *out = (unsigned char *)buffer + i * 512;
        if (partitioned && sector + i == 0)
            memcpy(out, mbr, 512);
        else if (sector + i == (partitioned ? 2048u : 0u))
            memcpy(out, boot_sector, 512);
    }
    return count;
}

static void put32(unsigned char *out, unsigned value)
{
    for (unsigned i = 0; i < 4; i++) out[i] = value >> (8 * i);
}

int main(int argc, char **argv)
{
    if (argc != 2 && argc != 3) {
        fputs("Usage: check-vendor-sd-layout PRIVATE-UBOOT-DUMP [FAT32-BOOT-SECTOR]\n", stderr);
        return 2;
    }
    FILE *input = fopen(argv[1], "rb");
    if (!input) return 2;
    unsigned char *dump = malloc(0x60000);
    if (!dump) return 2;
    size_t size = fread(dump, 1, 0x60000, input);
    fclose(input);
    const struct profile *p = NULL;
    for (unsigned i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++)
        if (size >= profiles[i].offset + 0x30000 &&
            crc32(0, dump + profiles[i].offset, 0x30000) == profiles[i].crc)
            p = &profiles[i];
    if (!p) {
        fputs("Unrecognized U-Boot code; refusing execution\n", stderr);
        return 2;
    }
    if (argc == 3) {
        input = fopen(argv[2], "rb");
        if (!input || fread(boot_sector, 1, 512, input) != 512 || fgetc(input) != EOF)
            return 2;
        fclose(input);
    } else {
        /* A generic 128 MiB FAT32 BPB; no camera or user data. */
        boot_sector[0] = 0xeb; boot_sector[1] = 0x58; boot_sector[2] = 0x90;
        memcpy(boot_sector + 3, "mkfs.fat", 8);
        boot_sector[12] = 2; boot_sector[13] = 1; boot_sector[14] = 32;
        boot_sector[16] = 2; boot_sector[21] = 0xf8;
        put32(boot_sector + 32, 262144); put32(boot_sector + 36, 2048);
        put32(boot_sector + 44, 2);
        memcpy(boot_sector + 82, "FAT32   ", 8);
        boot_sector[510] = 0x55; boot_sector[511] = 0xaa;
    }
    unsigned sectors;
    memcpy(&sectors, boot_sector + 32, 4);
    if (memcmp(boot_sector + 82, "FAT32   ", 8) ||
        boot_sector[510] != 0x55 || boot_sector[511] != 0xaa ||
        sectors < 65536 || sectors > 0xfffff000u)
        return 2;
    mbr[450] = 0x0c;
    put32(mbr + 454, 2048); put32(mbr + 458, sectors);
    mbr[510] = 0x55; mbr[511] = 0xaa;

    void *region = mmap((void *)0x4a000000, 0x100000, 7,
                        MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) return 2;
    for (partitioned = 0; partitioned <= 1; partitioned++) {
        memset(region, 0, 0x100000);
        memcpy(region, dump + p->offset, 0x30000);
        redirect(p->open_device, (uintptr_t)open_sd);
        redirect(p->sd_init, (uintptr_t)sd_ready);
        redirect(p->logger, (uintptr_t)log_message);
        redirect(p->puts, (uintptr_t)puts);
        redirect(p->aligned, (uintptr_t)aligned);
        redirect(p->free, (uintptr_t)free);
        redirect(0x4a000e60, (uintptr_t)memcpy);
        redirect(0x4a000dc0, (uintptr_t)memset);
        redirect(p->memcmp, (uintptr_t)memcmp);
        redirect(p->crc32, (uintptr_t)crc32);
        redirect(p->strlen, (uintptr_t)strlen);
        redirect(p->strcmp, (uintptr_t)strcmp);
        redirect(p->strncmp, (uintptr_t)strncmp);
        redirect(p->strchr, (uintptr_t)strchr);
        redirect(p->strdup, (uintptr_t)strdup);
        redirect(p->number, (uintptr_t)number);
        redirect(p->format, (uintptr_t)sprintf);
        __builtin___clear_cache(region, (char *)region + 0x100000);
        memset(descriptor, 0, sizeof(descriptor));
        descriptor[0] = 6; descriptor[4] = sectors + (partitioned ? 2048 : 0);
        descriptor[5] = 512; descriptor[30] = (uintptr_t)sd_read;
        void (*part_init)(void *) = (void *)p->part_init;
        int (*update)(void) = (void *)p->update;
        int (*select_fs)(const char *, const char *, int) = (void *)p->select_fs;
        part_init(descriptor);
        stopped = 0;
        update(); /* Stops at the deliberately refused image-buffer allocation. */
        if (stopped != 1) return 1;
        char *selector = (void *)p->selector;
        int selected = select_fs("mmc", selector, 1);
        int expected = partitioned || strcmp(p->model, "y623");
        printf("%s %s: updater selects '%s', readable=%s\n", p->model,
               partitioned ? "MBR + partition 1 FAT32" : "whole-device FAT32",
               selector, selected == 0 ? "yes" : "no");
        if ((selected == 0) != expected) return 1;
    }
    puts("PASS: native SD selection reproduced; no image loaded or flash written");
    return 0;
}
