#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
STOCK="$ROOT/scripts/vendor-images/y623-boot-stock.bin"
PATCHER="$ROOT/scripts/patch_y623_ve_debugfs.py"
HELPER="$ROOT/src/static/static/yi-hack/script/ensure_y623_ve_kernel.sh"
EXPECTED_STOCK=2c8abc0f8376bdb55d8464abc6bf14a8
EXPECTED_PATCHED=26a2e9a432fbe36efe97f0e7cee84dc9

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

md5()
{
    md5sum "$1" | awk '{print $1}'
}

[ "$(md5 "$STOCK")" = "$EXPECTED_STOCK" ]
python3 "$PATCHER" "$STOCK" "$TMP/patched.bin" >/dev/null
[ "$(md5 "$TMP/patched.bin")" = "$EXPECTED_PATCHED" ]

mkdir -p "$TMP/sd/yi-hack" "$TMP/sd/backup/mtd"
echo y623 > "$TMP/sd/yi-hack/model_suffix"
echo '12.0.51.01_202303091901' > "$TMP/homever"
cp "$STOCK" "$TMP/boot.bin"

run_helper()
{
    YI_HACK_PREFIX="$TMP/sd/yi-hack" \
    YI_HACK_SD_ROOT="$TMP/sd" \
    YI_HACK_HOMEVER_PATH="$TMP/homever" \
    YI_HACK_BOOT_DEV="$TMP/boot.bin" \
    YI_HACK_PATCHED_BOOT_IMAGE="$TMP/patched.bin" \
    YI_HACK_BOOT_BACKUP="$TMP/sd/backup/mtd/y623-boot-stock.bin" \
    MODEL_SUFFIX=y623 \
    /bin/sh "$HELPER" "$TMP/patched.bin"
}

YI_HACK_PREFIX="$TMP/sd/yi-hack" \
YI_HACK_SD_ROOT="$TMP/sd" \
YI_HACK_HOMEVER_PATH="$TMP/homever" \
YI_HACK_BOOT_DEV="$TMP/boot.bin" \
YI_HACK_PATCHED_BOOT_IMAGE="$TMP/patched.bin" \
YI_HACK_BOOT_BACKUP="$TMP/sd/backup/mtd/y623-boot-stock.bin" \
MODEL_SUFFIX=y623 \
/bin/sh "$HELPER" --check "$TMP/patched.bin" >/dev/null
[ "$(md5 "$TMP/boot.bin")" = "$EXPECTED_STOCK" ]
[ ! -e "$TMP/sd/backup/mtd/y623-boot-stock.bin" ]

run_helper >/dev/null
[ "$(md5 "$TMP/boot.bin")" = "$EXPECTED_PATCHED" ]
[ "$(md5 "$TMP/sd/backup/mtd/y623-boot-stock.bin")" = "$EXPECTED_STOCK" ]

# Idempotence: an already-patched boot image must remain unchanged.
run_helper >/dev/null
[ "$(md5 "$TMP/boot.bin")" = "$EXPECTED_PATCHED" ]

# Unknown boot images must be rejected without modification.
cp "$STOCK" "$TMP/unknown.bin"
printf '\001' | dd of="$TMP/unknown.bin" bs=1 seek=128 conv=notrunc 2>/dev/null
UNKNOWN_BEFORE=$(md5 "$TMP/unknown.bin")
if YI_HACK_PREFIX="$TMP/sd/yi-hack" \
   YI_HACK_SD_ROOT="$TMP/sd" \
   YI_HACK_HOMEVER_PATH="$TMP/homever" \
   YI_HACK_BOOT_DEV="$TMP/unknown.bin" \
   YI_HACK_PATCHED_BOOT_IMAGE="$TMP/patched.bin" \
   YI_HACK_BOOT_BACKUP="$TMP/sd/backup/mtd/y623-boot-stock.bin" \
   MODEL_SUFFIX=y623 \
   /bin/sh "$HELPER" "$TMP/patched.bin" >/dev/null 2>&1; then
    echo "unknown boot image was incorrectly accepted" >&2
    exit 1
fi
[ "$(md5 "$TMP/unknown.bin")" = "$UNKNOWN_BEFORE" ]

# Other models deliberately do nothing and need no y623 boot payload.
MODEL_SUFFIX=y28ga YI_HACK_PREFIX="$TMP/sd/yi-hack" /bin/sh "$HELPER" /does/not/exist

echo "y623 VE kernel release-path tests passed"
