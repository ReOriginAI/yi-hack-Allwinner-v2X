/* Keep a vendor SD rescan from covering the flash-core compatibility mounts. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#ifndef YI_FLASH_MOUNTS_FILE
#define YI_FLASH_MOUNTS_FILE "/proc/mounts"
#endif

static int sd_already_mounted(void)
{
    char line[1024], source[256], target[256], type[64];
    FILE *file = fopen(YI_FLASH_MOUNTS_FILE, "r");
    int found = 0;
    if (!file) return 0;
    while (fgets(line, sizeof(line), file)) {
        if (sscanf(line, "%255s %255s %63s", source, target, type) == 3 &&
            !strcmp(target, "/tmp/sd") && !strcmp(type, "vfat") &&
            (!strncmp(source, "/dev/mmcblk", 11) ||
             !strncmp(source, "/dev/block/mmcblk", 17))) {
            found = 1;
            break;
        }
    }
    fclose(file);
    return found;
}

int mount(const char *source, const char *target, const char *type,
          unsigned long flags, const void *data)
{
    const char *flash = getenv("YI_FLASH_CORE");
    int saved = errno;
    if (flash && !strcmp(flash, "1") && source && target && type &&
        !strcmp(target, "/tmp/sd") && !strcmp(type, "vfat") &&
        (!strncmp(source, "/dev/mmcblk", 11) ||
         !strncmp(source, "/dev/block/mmcblk", 17)) &&
        !(flags & (MS_BIND | MS_MOVE | MS_REMOUNT)) && sd_already_mounted()) {
        errno = saved;
        return 0;
    }
    return syscall(SYS_mount, source, target, type, flags, data);
}
