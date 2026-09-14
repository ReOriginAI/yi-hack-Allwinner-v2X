#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
STOCK_RMM=${RMM_STOCK_PATH:-/home/app/rmm}
PATCHED_RMM=${RMM_PATCHED_PATH:-$YI_HACK_PREFIX/bin/rmm-y28ga-motionlite}
EXPECTED_STOCK_MD5=46261d809c58dea5b39f3351e322d710
EXPECTED_PATCHED_MD5=b5e38328a3516de69f60e596add05c38

file_md5()
{
    set -- $(md5sum "$1" 2>/dev/null)
    printf '%s\n' "$1"
}

if [ "$MODEL_SUFFIX" != "y28ga" ]; then
    printf '%s\n' "$STOCK_RMM"
    exit 0
fi

if [ ! -r "$STOCK_RMM" ]; then
    echo "prepare_rmm: stock rmm is not readable" >&2
    exit 1
fi

if [ -r "$PATCHED_RMM" ] && [ "$(file_md5 "$PATCHED_RMM")" = "$EXPECTED_PATCHED_MD5" ]; then
    chmod 755 "$PATCHED_RMM" 2>/dev/null
    printf '%s\n' "$PATCHED_RMM"
    exit 0
fi

if [ "$(file_md5 "$STOCK_RMM")" != "$EXPECTED_STOCK_MD5" ]; then
    echo "prepare_rmm: refusing unknown y28ga rmm build" >&2
    exit 1
fi

TMP_RMM="${PATCHED_RMM}.tmp.$$"
rm -f "$TMP_RMM"
if ! cp "$STOCK_RMM" "$TMP_RMM"; then
    echo "prepare_rmm: could not copy stock rmm" >&2
    rm -f "$TMP_RMM"
    exit 1
fi

# y28ga old-firmware motion-lite patch:
#  - VIPP1 virtual channels: 3 -> 1
#  - face/NNA frame processor: return 0
#  - PTZ tracking frame processor: return 0
printf '\001\060\240\343' | dd of="$TMP_RMM" bs=1 seek=91056 conv=notrunc 2>/dev/null
printf '\000\000\240\343\036\377\057\341' | dd of="$TMP_RMM" bs=1 seek=74668 conv=notrunc 2>/dev/null
printf '\000\000\240\343\036\377\057\341' | dd of="$TMP_RMM" bs=1 seek=79964 conv=notrunc 2>/dev/null

if [ "$(file_md5 "$TMP_RMM")" != "$EXPECTED_PATCHED_MD5" ]; then
    echo "prepare_rmm: patched rmm verification failed" >&2
    rm -f "$TMP_RMM"
    exit 1
fi

chmod 755 "$TMP_RMM" || {
    rm -f "$TMP_RMM"
    exit 1
}
if ! mv -f "$TMP_RMM" "$PATCHED_RMM"; then
    rm -f "$TMP_RMM"
    exit 1
fi

printf '%s\n' "$PATCHED_RMM"
