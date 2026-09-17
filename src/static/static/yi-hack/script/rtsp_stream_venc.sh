#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
IPC_CMD=${YI_HACK_IPC_CMD:-$YI_HACK_PREFIX/bin/ipc_cmd}
RMM_PATH=${RMM_PATH:-/home/app/rmm}
MP4RECORD_PATH=${MP4RECORD_PATH:-/home/app/mp4record}
SYSTEM_CONF="$YI_HACK_PREFIX/etc/system.conf"
CAMERA_CONF="$YI_HACK_PREFIX/etc/camera.conf"
STREAM=${1:-$(grep '^RTSP_STREAM=' "$SYSTEM_CONF" 2>/dev/null | cut -d= -f2-)}
Y28GA_MAINONLY_MP4_MD5=c541480baa510ad34944e9e763c6b505

get_conf()
{
    KEY=$1
    FILE=$2
    grep -w "$KEY" "$FILE" 2>/dev/null | cut -d= -f2-
}

file_md5()
{
    set -- $(md5sum "$1" 2>/dev/null)
    printf '%s\n' "$1"
}

mp4record_running()
{
    ps | awk '$5 == "./mp4record" || $5 == "/home/app/mp4record" { found=1 } END { exit found ? 0 : 1 }'
}

recording_needs_low_venc()
{
    # The audited y28ga main-only recorder muxes VENC0 + AAC only, so recording
    # no longer requires VENC1. Check the binary actually bound at /home/app so
    # a failed/unknown patch automatically falls back to the safe vendor policy.
    if [ "$MODEL_SUFFIX" = "y28ga" ] &&
       [ "$(file_md5 "$MP4RECORD_PATH")" = "$Y28GA_MAINONLY_MP4_MD5" ]; then
        return 1
    fi

    # Stock Yi mp4record declares lower-resolution video tracks. If VENC1 is
    # paused, those tracks can be emitted with zero chunks but a live STSC map,
    # producing MP4s that browsers/FFmpeg reject as contradictory STSC/STCO.
    if mp4record_running; then
        return 0
    fi

    if [ "$(get_conf REC_WITHOUT_CLOUD "$SYSTEM_CONF")" = "yes" ]; then
        return 0
    fi

    if [ "$(get_conf MOTION_DETECTION "$CAMERA_CONF")" = "yes" ] &&
       [ "$(get_conf SAVE_VIDEO_ON_MOTION "$CAMERA_CONF")" = "yes" ]; then
        return 0
    fi

    return 1
}

# Runtime low-VENC control is verified on the audited y623 and y28ga rmm builds.
case "$MODEL_SUFFIX" in
    y623) EXPECTED_RMM_MD5=eb9d532e71d0d8697d22d0775b744b40 ;;
    y28ga) EXPECTED_RMM_MD5=14aa4ee21e04fb40a3c321fdcd12eef4 ;;
    *) exit 0 ;;
esac
[ -x "$IPC_CMD" ] || exit 0
set -- $(md5sum "$RMM_PATH" 2>/dev/null)
[ "$1" = "$EXPECTED_RMM_MD5" ] || exit 0

case "$STREAM" in
    high)
        if recording_needs_low_venc; then
            STATE=on
        else
            STATE=off
        fi
        ;;
    low|both)
        STATE=on
        ;;
    *)
        echo "rtsp_stream_venc: invalid RTSP_STREAM '$STREAM'" >&2
        exit 2
        ;;
esac

"$IPC_CMD" -V "$STATE" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    echo "rtsp_stream_venc: could not set $MODEL_SUFFIX low VENC $STATE" >&2
fi
exit "$RC"
