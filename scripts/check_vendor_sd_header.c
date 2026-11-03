/* Run the audited y28ga U-Boot SD header validator under qemu-arm-static.
 * Input is a private local dump; no vendor binary is distributed here.
 * Only the header-validation function runs. It cannot write flash or reboot.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static unsigned crc(unsigned seed, const void *data, unsigned size)
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

static char *empty_env(const char *key)
{
    (void)key;
    return NULL;
}

static unsigned number(const char *text, char **end, int base)
{
    return strtoul(text, end, base);
}

static int log_message(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int count = vprintf(format, arguments);
    va_end(arguments);
    return count;
}

static char *match(const char *text, const char *needle)
{
    return strstr(text, needle);
}

static void redirect(uintptr_t address, uintptr_t target)
{
    /* Thumb ldr.w pc, [pc, #0], followed by the host stub's ARM/Thumb pointer. */
    uint16_t *code = (void *)address;
    code[0] = 0xf8df;
    code[1] = 0xf000;
    *(uint32_t *)(address + 4) = target;
}

static unsigned char *read_file(const char *name, size_t *size)
{
    FILE *file = fopen(name, "rb");
    if (!file) {
        perror(name);
        exit(2);
    }
    if (fseek(file, 0, SEEK_END))
        exit(2);
    long length = ftell(file);
    if (length < 64 || length > 0x340000 || fseek(file, 0, SEEK_SET))
        exit(2);
    *size = length;
    unsigned char *bytes = malloc(*size);
    if (!bytes || fread(bytes, 1, *size, file) != *size)
        exit(2);
    fclose(file);
    return bytes;
}

int main(int argc, char **argv)
{
    if (argc != 4 || (strcmp(argv[3], "2") && strcmp(argv[3], "3"))) {
        fputs("Usage: check-vendor-sd-header PRIVATE-UBOOT-DUMP IMAGE 2|3\n", stderr);
        return 2;
    }
    size_t boot_size, image_size;
    unsigned char *boot = read_file(argv[1], &boot_size);
    unsigned char *image = read_file(argv[2], &image_size);
    if (boot_size < 0x48c00 || image_size > (argv[3][0] == '2' ? 0x120000u : 0x340000u))
        return 2;
    /* Gate captured generic code, excluding private/device-specific partitions. */
    if (crc(0, boot + 0x18c00, 0x30000) != 0xe15d863c) {
        fputs("Unrecognized vendor U-Boot code; refusing execution\n", stderr);
        return 2;
    }
    void *region = mmap((void *)0x4a000000, 0x100000,
                        PROT_READ | PROT_WRITE | PROT_EXEC,
                        MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED) {
        perror("mmap");
        return 2;
    }
    memcpy(region, boot + 0x18c00, 0x30000);
    redirect(0x4a01ae40, (uintptr_t)log_message);
    redirect(0x4a005cb4, (uintptr_t)empty_env);
    redirect(0x4a01af60, (uintptr_t)number);
    redirect(0x4a01a418, (uintptr_t)match);
    redirect(0x4a01a174, (uintptr_t)crc);
    __builtin___clear_cache(region, (char *)region + 0x100000);
    int (*validate)(int, void *, unsigned) = (void *)0x4a01b51d;
    int result = validate(atoi(argv[3]), image, image_size);
    printf("vendor validation result=%d\n", result);
    return result ? 1 : 0;
}
