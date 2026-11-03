#!/bin/sh
# Flash core retains the low H.264 image used by the motion-mask grid.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/storage.sh" || exit 1
full=no
file_input=no
low=yes
expect_resolution=no
for argument in "$@"; do
    if [ "$expect_resolution" = yes ]; then
        [ "$argument" = low ] || low=no
        expect_resolution=no
        continue
    fi
    case "$argument" in
        -r|--res) expect_resolution=yes ;;
        -rlow|--res=low) ;;
        -r*|--res=*) low=no ;;
        -f|--file|-f*|--file=*) full=yes; file_input=yes ;;
        -w|--watermark|-t|--watermark_time|-t*|--watermark_time=*) full=yes ;;
    esac
done
[ "$low" = yes ] || full=yes
if [ "$full" = yes ]; then
    decoder=/tmp/sd/yi-hack-optional/bin/imggrabber
    if ! sd_present || [ ! -x "$decoder" ]; then
        echo 'High-resolution, file and watermark snapshots require the optional SD snapshot program.' >&2
        exit 1
    fi
    export YI_SNAPSHOT_WM_ROOT=/tmp/sd/yi-hack-optional/etc/wm_res
else
    decoder=$YI_HACK_PREFIX/bin/imggrabber-grid
fi
# VENC1 can be paused for high-only RTSP. Enable it briefly for the grid frame,
# then restore the recorder-aware stream policy even when capture times out.
restore=no
cleanup() {
    if [ "$restore" = yes ]; then
        "$YI_HACK_PREFIX/bin/service_guard" 3 /bin/sh "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ "$low" = yes ] && [ "$file_input" = no ]; then
    restore=yes
    "$YI_HACK_PREFIX/bin/service_guard" 3 /bin/sh "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" both >/dev/null 2>&1 || exit 1
    sleep 1
fi
"$YI_HACK_PREFIX/bin/service_guard" 10 "$decoder" "$@"
exit $?
