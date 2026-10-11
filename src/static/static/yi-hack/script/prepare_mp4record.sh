#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
STOCK_MP4RECORD=${MP4RECORD_STOCK_PATH:-/home/app/mp4record}

file_md5()
{
    set -- $(md5sum "$1" 2>/dev/null)
    printf '%s\n' "$1"
}

case "$MODEL_SUFFIX" in
    y623)
        PATCHED_MP4RECORD=${MP4RECORD_PATCHED_PATH:-$YI_HACK_PREFIX/bin/mp4record-y623-preroll}
        EXPECTED_STOCK_MD5=c4ee01f6491b26a37db8d92c59605496
        EXPECTED_PATCHED_MD5=06774adfc4368e7dede2ea618a96c2b6
        LEGACY_PATCHED_MD5=
        EXPECTED_BLOB_MD5=08243588199c910f33839785bbfd77f1
        BLOB_OFFSET=36864
        ;;
    y28ga)
        PATCHED_MP4RECORD=${MP4RECORD_PATCHED_PATH:-$YI_HACK_PREFIX/bin/mp4record-y28ga-mainonly}
        EXPECTED_STOCK_MD5=d3aff9fb80bc1d61ec78de281e6e9784
        LEGACY_PATCHED_MD5=c541480baa510ad34944e9e763c6b505
        EXPECTED_PATCHED_MD5=0d7a4ca9e73fd75806a6ebb75a8accbc
        EXPECTED_BLOB_MD5=e7abac10b94a944988038d301997ac80
        BLOB_OFFSET=32768
        ;;
    *) printf '%s\n' "$STOCK_MP4RECORD"; exit 0 ;;
esac

if [ ! -r "$STOCK_MP4RECORD" ]; then
    echo "prepare_mp4record: stock mp4record is not readable" >&2
    exit 1
fi

STOCK_MD5=$(file_md5 "$STOCK_MP4RECORD")
if [ "$STOCK_MD5" = "$EXPECTED_PATCHED_MD5" ]; then
    # Already bind-mounted for this boot.
    printf '%s\n' "$STOCK_MP4RECORD"
    exit 0
fi

# Refuse an unknown vendor recorder before consulting a cached patched copy.
# This prevents a stale patch from an older firmware being reused accidentally.
if [ "$STOCK_MD5" != "$EXPECTED_STOCK_MD5" ] &&
   { [ -z "$LEGACY_PATCHED_MD5" ] || [ "$STOCK_MD5" != "$LEGACY_PATCHED_MD5" ]; }; then
    echo "prepare_mp4record: refusing unknown $MODEL_SUFFIX mp4record build" >&2
    exit 1
fi

BLOB="$YI_HACK_PREFIX/lib/record_preroll-$MODEL_SUFFIX.bin"
if [ "$(file_md5 "$BLOB")" != "$EXPECTED_BLOB_MD5" ]; then
    echo "prepare_mp4record: missing or unverified $MODEL_SUFFIX preroll extension" >&2
    exit 1
fi

if [ -r "$PATCHED_MP4RECORD" ] && [ "$(file_md5 "$PATCHED_MP4RECORD")" = "$EXPECTED_PATCHED_MD5" ]; then
    chmod 755 "$PATCHED_MP4RECORD" 2>/dev/null
    printf '%s\n' "$PATCHED_MP4RECORD"
    exit 0
fi

TMP_MP4RECORD="${PATCHED_MP4RECORD}.tmp.$$"
rm -f "$TMP_MP4RECORD"
if ! cp "$STOCK_MP4RECORD" "$TMP_MP4RECORD"; then
    echo "prepare_mp4record: could not copy stock mp4record" >&2
    rm -f "$TMP_MP4RECORD"
    exit 1
fi

# Six-second lookback: change BOTH comparison and subtraction. The duration
# helper reads retained packet headers under the native lock, avoiding RMM's
# cached timestamp, which can freeze after a backwards NTP correction.
# Append a 536-byte RX extension, keeping all original ELF addresses intact.
# Its first-keyframe hook also sets native MP4 creation time to media time,
# so embedded motion offsets and local filenames include the actual preroll.
dd if="$BLOB" of="$TMP_MP4RECORD" bs=1 seek="$BLOB_OFFSET" conv=notrunc 2>/dev/null
case "$MODEL_SUFFIX" in
    y623)
        printf '\160\067\001\343' | dd of="$TMP_MP4RECORD" bs=1 seek=8368 conv=notrunc 2>/dev/null
        printf '\003\020\100\200' | dd of="$TMP_MP4RECORD" bs=1 seek=8376 conv=notrunc 2>/dev/null
        printf '\000\000\240\341' | dd of="$TMP_MP4RECORD" bs=1 seek=8384 conv=notrunc 2>/dev/null
        printf '\160\067\001\343' | dd of="$TMP_MP4RECORD" bs=1 seek=12160 conv=notrunc 2>/dev/null
        printf '\003\020\100\200' | dd of="$TMP_MP4RECORD" bs=1 seek=12168 conv=notrunc 2>/dev/null
        printf '\000\000\240\341' | dd of="$TMP_MP4RECORD" bs=1 seek=12176 conv=notrunc 2>/dev/null
        printf '\135\022\000\352' | dd of="$TMP_MP4RECORD" bs=1 seek=18052 conv=notrunc 2>/dev/null
        printf '\252\031\000\353' | dd of="$TMP_MP4RECORD" bs=1 seek=11088 conv=notrunc 2>/dev/null
        printf '\030\222\000\000\030\222\000\000' | dd of="$TMP_MP4RECORD" bs=1 seek=132 conv=notrunc 2>/dev/null
        ;;
    y28ga)
        # Keep one main H.264 track plus AAC. Stock's three video tracks create
        # invalid empty sub/fast track tables when the subencoder is paused.
        printf '\001' | dd of="$TMP_MP4RECORD" bs=1 seek=11156 conv=notrunc 2>/dev/null
        printf '\160\067\001\343' | dd of="$TMP_MP4RECORD" bs=1 seek=10228 conv=notrunc 2>/dev/null
        printf '\003\020\100\200' | dd of="$TMP_MP4RECORD" bs=1 seek=10236 conv=notrunc 2>/dev/null
        printf '\000\000\240\341' | dd of="$TMP_MP4RECORD" bs=1 seek=10244 conv=notrunc 2>/dev/null
        printf '\355\020\000\352' | dd of="$TMP_MP4RECORD" bs=1 seek=15428 conv=notrunc 2>/dev/null
        printf '\140\026\000\353' | dd of="$TMP_MP4RECORD" bs=1 seek=10360 conv=notrunc 2>/dev/null
        printf '\030\202\000\000\030\202\000\000' | dd of="$TMP_MP4RECORD" bs=1 seek=132 conv=notrunc 2>/dev/null
        ;;
esac

if [ "$(file_md5 "$TMP_MP4RECORD")" != "$EXPECTED_PATCHED_MD5" ]; then
    echo "prepare_mp4record: patched $MODEL_SUFFIX mp4record verification failed" >&2
    rm -f "$TMP_MP4RECORD"
    exit 1
fi

chmod 755 "$TMP_MP4RECORD" || {
    rm -f "$TMP_MP4RECORD"
    exit 1
}
if ! mv -f "$TMP_MP4RECORD" "$PATCHED_MP4RECORD"; then
    rm -f "$TMP_MP4RECORD"
    exit 1
fi

printf '%s\n' "$PATCHED_MP4RECORD"
