#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
STOCK_RMM=${RMM_STOCK_PATH:-/home/app/rmm}

file_md5()
{
    set -- $(md5sum "$1" 2>/dev/null)
    printf '%s\n' "$1"
}

case "$MODEL_SUFFIX" in
    y623)
        PATCHED_RMM=${RMM_PATCHED_PATH:-$YI_HACK_PREFIX/bin/rmm-y623-motionlite}
        EXPECTED_STOCK_MD5=f8164a1c221ba8c1d4888322a3cf0706
        EXPECTED_PATCHED_MD5=45be10e9be161e4c36e9ce48958abb9f
        ;;
    y28ga)
        PATCHED_RMM=${RMM_PATCHED_PATH:-$YI_HACK_PREFIX/bin/rmm-y28ga-motionlite}
        EXPECTED_STOCK_MD5=46261d809c58dea5b39f3351e322d710
        EXPECTED_PATCHED_MD5=b5e38328a3516de69f60e596add05c38
        ;;
    *)
        printf '%s\n' "$STOCK_RMM"
        exit 0
        ;;
esac

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
    echo "prepare_rmm: refusing unknown $MODEL_SUFFIX rmm build" >&2
    exit 1
fi

TMP_RMM="${PATCHED_RMM}.tmp.$$"
rm -f "$TMP_RMM"
if ! cp "$STOCK_RMM" "$TMP_RMM"; then
    echo "prepare_rmm: could not copy stock rmm" >&2
    rm -f "$TMP_RMM"
    exit 1
fi

case "$MODEL_SUFFIX" in
    y623)
        # Yi Pro 2K low-RAM patch, verified on the tested 12.0.51-class rmm:
        #  - vi_algo_process: return 0 (removes Pilot AI/model initialization)
        #  - VIPP1 virtual channels: 3 -> 1
        #  - skip the unused VI2/raw-analysis setup; motiond uses H264 encoder stats
        printf '\000\000\240\343\036\377\057\341' | dd of="$TMP_RMM" bs=1 seek=105144 conv=notrunc 2>/dev/null
        printf '\001' | dd of="$TMP_RMM" bs=1 seek=113568 conv=notrunc 2>/dev/null
        printf '\002\000\240\343\000\020\240\343\314\177\000\353\052\000\000\352' | dd of="$TMP_RMM" bs=1 seek=124076 conv=notrunc 2>/dev/null
        ;;
    y28ga)
        # Kami 1080p old-firmware motion-lite patch:
        #  - VIPP1 virtual channels: 3 -> 1
        #  - face/NNA frame processor: return 0
        #  - PTZ tracking frame processor: return 0
        # VI2 remains enabled because generic IVA motion requires it.
        printf '\001\060\240\343' | dd of="$TMP_RMM" bs=1 seek=91056 conv=notrunc 2>/dev/null
        printf '\000\000\240\343\036\377\057\341' | dd of="$TMP_RMM" bs=1 seek=74668 conv=notrunc 2>/dev/null
        printf '\000\000\240\343\036\377\057\341' | dd of="$TMP_RMM" bs=1 seek=79964 conv=notrunc 2>/dev/null
        ;;
esac

if [ "$(file_md5 "$TMP_RMM")" != "$EXPECTED_PATCHED_MD5" ]; then
    echo "prepare_rmm: patched $MODEL_SUFFIX rmm verification failed" >&2
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
