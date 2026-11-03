#!/bin/sh
# Replaces the vendor's lazy-unmount/remount callback only in flash profiles.
# Detaching /tmp/sd would also detach the core and configuration bind mounts.
. "${YI_FLASH_CORE_PREFIX:-/home/yi-hack}/script/storage.sh" || exit 1
sd_present && exit 0
mount -t vfat /dev/mmcblk0p1 /tmp/sd 2>/dev/null ||
    mount -t vfat /dev/mmcblk0 /tmp/sd 2>/dev/null
