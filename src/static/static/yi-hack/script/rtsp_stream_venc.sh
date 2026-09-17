#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
IPC_CMD=${YI_HACK_IPC_CMD:-$YI_HACK_PREFIX/bin/ipc_cmd}
RMM_PATH=${RMM_PATH:-/home/app/rmm}
STREAM=${1:-$(grep '^RTSP_STREAM=' "$YI_HACK_PREFIX/etc/system.conf" 2>/dev/null | cut -d= -f2-)}

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
        STATE=off
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
