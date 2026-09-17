#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
STOCK_MP4RECORD=${MP4RECORD_STOCK_PATH:-/home/app/mp4record}

file_md5()
{
    set -- $(md5sum "$1" 2>/dev/null)
    printf '%s\n' "$1"
}

# Only the audited y28ga recorder is patched. Other models keep their vendor
# recorder unchanged until their track layout is independently verified.
if [ "$MODEL_SUFFIX" != "y28ga" ]; then
    printf '%s\n' "$STOCK_MP4RECORD"
    exit 0
fi

PATCHED_MP4RECORD=${MP4RECORD_PATCHED_PATH:-$YI_HACK_PREFIX/bin/mp4record-y28ga-mainonly}
EXPECTED_STOCK_MD5=d3aff9fb80bc1d61ec78de281e6e9784
EXPECTED_PATCHED_MD5=c541480baa510ad34944e9e763c6b505

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
if [ "$STOCK_MD5" != "$EXPECTED_STOCK_MD5" ]; then
    echo "prepare_mp4record: refusing unknown y28ga mp4record build" >&2
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

# record_file creates its muxer as create(audio_tracks=1, video_tracks=3).
# Track 1 is the 1920x1080 main encoder, track 2 is the 640x360 sub encoder,
# and track 3 is the 5 fps fast stream. When VENC1 is paused the vendor muxer
# still emits empty track-2/3 STSC entries, yielding MP4s rejected by browsers
# and FFmpeg as contradictory STSC/STCO. Limit the muxer to one video track;
# its existing bounds checks safely reject all later track-2/3 setup/writes.
#
# VA 0x12b94 / file offset 0x2b94:
#   e3a01003  mov r1,#3   ->   e3a01001  mov r1,#1
printf '\001' | dd of="$TMP_MP4RECORD" bs=1 seek=11156 conv=notrunc 2>/dev/null

if [ "$(file_md5 "$TMP_MP4RECORD")" != "$EXPECTED_PATCHED_MD5" ]; then
    echo "prepare_mp4record: patched y28ga mp4record verification failed" >&2
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
