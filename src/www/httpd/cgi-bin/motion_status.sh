#!/bin/sh

YI_HACK_PREFIX="/tmp/sd/yi-hack"
SERVICE="$YI_HACK_PREFIX/script/motion_service.sh"
CAMERA_CONF="$YI_HACK_PREFIX/etc/camera.conf"
MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)
IPC_EVENT_DIR="/tmp/onvif_notify_server"

get_camera_config()
{
    grep -w "$1" "$CAMERA_CONF" 2>/dev/null | cut -d "=" -f2-
}

ipc_motion_active()
{
    [ -e "$IPC_EVENT_DIR/motion_alarm" ]
}

BACKEND=$($SERVICE backend 2>/dev/null)
STATUS=$($SERVICE status 2>/dev/null)
SENSITIVITY=$(get_camera_config MOTION_SENSITIVITY)
RECORDING=$(get_camera_config SAVE_VIDEO_ON_MOTION)
HUMAN_ONLY=$(get_camera_config MOTION_HUMAN_ONLY)
case "$HUMAN_ONLY" in yes|no) ;; *) HUMAN_ONLY=no ;; esac
STATE="unknown"
SENSITIVITY_SUPPORTED=false
HUMAN_ONLY_SUPPORTED=false
[ "$MODEL_SUFFIX" = "y28ga" ] && HUMAN_ONLY_SUPPORTED=true

case "$BACKEND" in
    encoder-stats)
        BACKEND_LABEL="H264 encoder statistics"
        SENSITIVITY_SUPPORTED=true
        if [ "$STATUS" = "started" ]; then
            if [ -r /tmp/motion.state ]; then
                case "$(cat /tmp/motion.state 2>/dev/null)" in
                    1) STATE="motion" ;;
                    *) STATE="idle" ;;
                esac
            else
                STATE="idle"
            fi
        elif [ "$STATUS" = "stopped" ]; then
            STATE="disabled"
        else
            STATE="unavailable"
        fi
        ;;
    ipc-events)
        if [ "$MODEL_SUFFIX" = "y28ga" ] && [ "$HUMAN_ONLY" = "yes" ]; then
            BACKEND_LABEL="Human-confirmed firmware IVA motion"
        else
            BACKEND_LABEL="Generic firmware IVA motion"
        fi
        if [ "$MODEL_SUFFIX" = "y28ga" ]; then
            SENSITIVITY_SUPPORTED=true
        fi
        if [ "$STATUS" = "started" ]; then
            if ipc_motion_active; then
                STATE="motion"
            else
                STATE="idle"
            fi
        elif [ "$STATUS" = "stopped" ]; then
            STATE="disabled"
        else
            STATE="unavailable"
        fi
        ;;
    *)
        BACKEND_LABEL="Unsupported on this firmware"
        if [ "$STATUS" = "stopped" ]; then
            STATE="disabled"
        else
            STATE="unavailable"
        fi
        ;;
esac

case "$SENSITIVITY" in
    1|2|3|4|5|6|7|8|9|10) ;;
    *) SENSITIVITY=5 ;;
esac
case "$RECORDING" in yes|no) ;; *) RECORDING=no ;; esac
case "$STATUS" in started|stopped|failed|duplicate|unsupported) ;; *) STATUS=unknown ;; esac

printf "Content-type: application/json\r\n\r\n"
printf '{"error":false,"model":"%s","backend":"%s","backend_label":"%s","status":"%s","state":"%s","sensitivity":%s,"sensitivity_supported":%s,"human_only":"%s","human_only_supported":%s,"sd_backup":"%s"}' \
    "$MODEL_SUFFIX" "$BACKEND" "$BACKEND_LABEL" "$STATUS" "$STATE" "$SENSITIVITY" "$SENSITIVITY_SUPPORTED" "$HUMAN_ONLY" "$HUMAN_ONLY_SUPPORTED" "$RECORDING"
