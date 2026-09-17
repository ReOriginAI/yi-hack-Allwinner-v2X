#!/bin/sh

# Ensure the tested y623 kernel uses vmalloc/vfree for VE debugfs snapshots.
# This is intentionally fail-closed: only the exact known stock boot partition
# may be upgraded, and only the exact generated patched image may be written.
# Unknown boot images are never modified.

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
SD_ROOT=${YI_HACK_SD_ROOT:-/tmp/sd}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null | tr -d '\r\n')}
HOMEVER_PATH=${YI_HACK_HOMEVER_PATH:-/home/homever}
BOOT_DEV=${YI_HACK_BOOT_DEV:-/dev/mtdblock1}
MODE=apply
if [ "${1:-}" = "--check" ]; then
    MODE=check
    shift
fi
PATCHED_IMAGE=${YI_HACK_PATCHED_BOOT_IMAGE:-${1:-$SD_ROOT/Factory/boot-vmalloc.bin}}
BACKUP_IMAGE=${YI_HACK_BOOT_BACKUP:-$SD_ROOT/backup/mtd/y623-boot-stock.bin}

EXPECTED_HOMEVER='12.0.51.01_202303091901'
EXPECTED_SIZE=1900544
EXPECTED_STOCK_MD5=2c8abc0f8376bdb55d8464abc6bf14a8
EXPECTED_PATCHED_MD5=26a2e9a432fbe36efe97f0e7cee84dc9

fail()
{
    echo "ensure_y623_ve_kernel: $*" >&2
    exit 1
}

file_md5()
{
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

file_size()
{
    ls -ln "$1" 2>/dev/null | awk '{print $5}'
}

restore_stock()
{
    [ -s "$BACKUP_IMAGE" ] || return 1
    [ "$(file_md5 "$BACKUP_IMAGE")" = "$EXPECTED_STOCK_MD5" ] || return 1
    dd if="$BACKUP_IMAGE" of="$BOOT_DEV" bs=65536 count=29 2>/dev/null || return 1
    sync
    [ "$(file_md5 "$BOOT_DEV")" = "$EXPECTED_STOCK_MD5" ]
}

# This optimization is y623-specific. Other supported models deliberately no-op.
[ "$MODEL_SUFFIX" = "y623" ] || exit 0

[ "$(cat "$HOMEVER_PATH" 2>/dev/null)" = "$EXPECTED_HOMEVER" ] || fail "unsupported y623 firmware"
[ -r "$BOOT_DEV" ] && [ -w "$BOOT_DEV" ] || fail "boot partition is not readable and writable"
[ -s "$PATCHED_IMAGE" ] || fail "patched boot image is missing"
[ "$(file_size "$PATCHED_IMAGE")" = "$EXPECTED_SIZE" ] || fail "patched boot image size mismatch"
[ "$(file_md5 "$PATCHED_IMAGE")" = "$EXPECTED_PATCHED_MD5" ] || fail "patched boot image hash mismatch"

LIVE_MD5=$(file_md5 "$BOOT_DEV")
case "$LIVE_MD5" in
    "$EXPECTED_PATCHED_MD5")
        echo "ensure_y623_ve_kernel: already patched"
        exit 0
        ;;
    "$EXPECTED_STOCK_MD5")
        ;;
    *)
        fail "refusing unknown boot image: ${LIVE_MD5:-unreadable}"
        ;;
esac

if [ "$MODE" = "check" ]; then
    echo "ensure_y623_ve_kernel: stock boot is compatible"
    exit 0
fi

mkdir -p "$(dirname "$BACKUP_IMAGE")" || fail "cannot create boot backup directory"
if [ -s "$BACKUP_IMAGE" ]; then
    [ "$(file_md5 "$BACKUP_IMAGE")" = "$EXPECTED_STOCK_MD5" ] || fail "existing stock boot backup has unexpected hash"
else
    TMP_BACKUP="${BACKUP_IMAGE}.tmp.$$"
    rm -f "$TMP_BACKUP"
    dd if="$BOOT_DEV" of="$TMP_BACKUP" bs=65536 count=29 2>/dev/null || {
        rm -f "$TMP_BACKUP"
        fail "cannot preserve stock boot partition"
    }
    [ "$(file_size "$TMP_BACKUP")" = "$EXPECTED_SIZE" ] || {
        rm -f "$TMP_BACKUP"
        fail "stock boot backup size mismatch"
    }
    [ "$(file_md5 "$TMP_BACKUP")" = "$EXPECTED_STOCK_MD5" ] || {
        rm -f "$TMP_BACKUP"
        fail "stock boot backup hash mismatch"
    }
    mv "$TMP_BACKUP" "$BACKUP_IMAGE" || {
        rm -f "$TMP_BACKUP"
        fail "cannot activate stock boot backup"
    }
    sync
fi

# Write the complete known-good partition image, then read it back and verify.
# If verification fails, immediately restore the exact stock image we just saved.
if ! dd if="$PATCHED_IMAGE" of="$BOOT_DEV" bs=65536 count=29 2>/dev/null; then
    restore_stock >/dev/null 2>&1 || true
    fail "boot partition write failed; stock restore attempted"
fi
sync

WRITTEN_MD5=$(file_md5 "$BOOT_DEV")
if [ "$WRITTEN_MD5" != "$EXPECTED_PATCHED_MD5" ]; then
    if restore_stock; then
        fail "patched boot verification failed; stock boot restored"
    fi
    fail "patched boot verification failed and stock restore failed"
fi

echo "ensure_y623_ve_kernel: patched and verified"
exit 0
