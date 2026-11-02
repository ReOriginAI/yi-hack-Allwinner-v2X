#!/bin/sh
# Boot helper for the flash profile. Executable code always comes from /home.
flash_prepare_sd()
{
    mkdir -p /tmp/sd/yi-hack /tmp/sd/yi-hack-config || return 1
    # A read-only data card must not prevent using the internal fallback.
    ( : > /tmp/sd/yi-hack-config/.write-test ) || return 1
    rm -f /tmp/sd/yi-hack-config/.write-test
    if [ ! -f /tmp/sd/yi-hack-config/system.conf ]; then
        if [ -f /tmp/sd/yi-hack/etc/system.conf ]; then
            cp -a /tmp/sd/yi-hack/etc/. /tmp/sd/yi-hack-config/ || return 1
        else
            cp -a /backup/yi-hack-config/. /tmp/sd/yi-hack-config/ || return 1
        fi
    fi
}

if [ "${1:-}" = --prepare-sd ]; then
    flash_prepare_sd
    exit $?
fi

flash_storage_init()
{
    FLASH_CORE=/home/yi-hack
    FLASH_CONFIG=/backup/yi-hack-config
    [ -s "$FLASH_CORE/flash-core" ] || return 1
    . "$FLASH_CORE/script/storage.sh" || return 1
    "$FLASH_CORE/bin/service_guard" 8 mount -t vfat /dev/mmcblk0p1 /tmp/sd 2>/dev/null ||
        "$FLASH_CORE/bin/service_guard" 8 mount -t vfat /dev/mmcblk0 /tmp/sd 2>/dev/null || true
    umask 077
    mkdir -p "$FLASH_CONFIG" || return 1
    if [ ! -f "$FLASH_CONFIG/system.conf" ]; then
        cp -a "$FLASH_CORE/etc/." "$FLASH_CONFIG/" || return 1
    fi
    CONFIG_SOURCE=$FLASH_CONFIG
    if sd_present; then
        if "$FLASH_CORE/bin/service_guard" 8 "$FLASH_CORE/bin/busybox" ash "$FLASH_CORE/script/flash_storage.sh" --prepare-sd; then
            CONFIG_SOURCE=/tmp/sd/yi-hack-config
        else
            "$FLASH_CORE/bin/service_guard" 5 umount /tmp/sd || return 1
        fi
    fi
    mkdir -p /tmp/sd/yi-hack || return 1
    mount --bind "$FLASH_CORE" /tmp/sd/yi-hack || return 1
    mount --bind "$CONFIG_SOURCE" /tmp/sd/yi-hack/etc || return 1
    "$FLASH_CORE/bin/service_guard" 5 "$FLASH_CORE/bin/busybox" ash "$FLASH_CORE/script/flash_config_sync.sh" || true
    # No SD code is overlaid onto the core; optional executables have explicit
    # symlinks into yi-hack-optional. Config fallback updates are separate.
}
