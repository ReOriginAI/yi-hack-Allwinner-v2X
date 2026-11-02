#!/bin/sh
# A bind mount below /tmp/sd is not evidence that an SD card is mounted.
sd_present()
{
    awk '$2 == "/tmp/sd" && $1 ~ /^\/dev\/(block\/)?mmcblk/ && $3 == "vfat" { found=1 } END { exit !found }' "${YI_STORAGE_MOUNTS:-/proc/mounts}"
}
