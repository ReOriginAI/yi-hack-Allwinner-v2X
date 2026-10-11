#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
get_nv_config() { sed -n "s/^$1=//p" "$YI_HACK_PREFIX/etc/camera.conf"; }
MODE=$(get_nv_config NIGHTVISION_MODE)
if [ -z "$MODE" ]; then
    [ "$(get_nv_config IR)" = no ] && MODE=off || MODE=auto
fi
THRESHOLD=$(get_nv_config NIGHTVISION_THRESHOLD)
[ -n "$THRESHOLD" ] || THRESHOLD=50

case "$1" in
    preload)
        MODEL=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)
        HASH=$(md5sum /home/app/rmm 2>/dev/null | cut -d ' ' -f1)
        case "$MODEL:$HASH" in
            y623:eb9d532e71d0d8697d22d0775b744b40|y28ga:14aa4ee21e04fb40a3c321fdcd12eef4) ;;
            *) exit 0 ;;
        esac
        [ -s "$YI_HACK_PREFIX/lib/nightvision.so" ] || exit 0
        "$YI_HACK_PREFIX/bin/nightvisionctl" --init "$MODE" "$THRESHOLD" >/dev/null || exit 1
        printf '%s\n' "$YI_HACK_PREFIX/lib/nightvision.so"
        ;;
    apply)
        "$YI_HACK_PREFIX/bin/nightvisionctl" --set "$MODE" "$THRESHOLD" >/dev/null || exit 1
        # Keep the legacy lamp-enable setting compatible with the new mode.
        [ "$MODE" = off ] && ipc_cmd -i off || ipc_cmd -i on
        ;;
    status) exec "$YI_HACK_PREFIX/bin/nightvisionctl" --status ;;
    *) exit 2 ;;
esac
