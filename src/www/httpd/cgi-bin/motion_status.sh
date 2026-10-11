#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
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
STATE="unknown"
SENSITIVITY_SUPPORTED=false

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
        BACKEND_LABEL="Generic firmware IVA motion"
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

CUSTOM_SUPPORTED=false
[ "$BACKEND" = encoder-stats ] && CUSTOM_SUPPORTED=true
. "$YI_HACK_PREFIX/script/motion_settings.sh"
SETTINGS=$(motion_read_config | jq 'with_entries(select(.key | startswith("MOTION_")))')
METRICS=null
EFFECTIVE=null
if [ "$BACKEND" = encoder-stats ]; then
    if [ "$STATUS" = started ]; then
        # Capture before reading uptime: a concurrent publication must not look
        # newer than NOW and cause a valid fresh sample to be discarded.
        SNAPSHOT=$(cat "${MOTION_TELEMETRY_PATH:-/tmp/motion.telemetry}" 2>/dev/null)
        NOW=$(awk '{printf "%.0f", $1 * 1000}' /proc/uptime)
        METRICS=$(printf '%s\n' "$SNAPSHOT" | jq -c --argjson now "$NOW" '
            . + {sample_age_ms:($now - .monotonic_ms)} |
            select(.sample_age_ms >= 0 and .sample_age_ms <= (.effective.interval_ms * 2 + 2500))
        ' 2>/dev/null)
        [ -n "$METRICS" ] || METRICS=null
    fi
    if [ "$METRICS" != null ]; then
        EFFECTIVE=$(printf '%s\n' "$METRICS" | jq '.effective')
    else
        EFFECTIVE=$($SERVICE settings 2>/dev/null)
        [ -n "$EFFECTIVE" ] || EFFECTIVE=null
    fi
fi
case "$SENSITIVITY" in 1|2|3) FIRMWARE_LEVEL=low ;; 8|9|10) FIRMWARE_LEVEL=high ;; *) FIRMWARE_LEVEL=medium ;; esac

printf "Content-type: application/json\r\nCache-Control: no-store\r\n\r\n"
printf '{"error":false,"model":"%s","backend":"%s","backend_label":"%s","status":"%s","state":"%s","sensitivity":%s,"sensitivity_supported":%s,"sd_backup":"%s"}' \
    "$MODEL_SUFFIX" "$BACKEND" "$BACKEND_LABEL" "$STATUS" "$STATE" "$SENSITIVITY" "$SENSITIVITY_SUPPORTED" "$RECORDING" |
    jq --argjson custom "$CUSTOM_SUPPORTED" --argjson settings "$SETTINGS" --argjson metrics "$METRICS" \
       --argjson effective "$EFFECTIVE" --arg firmware "$FIRMWARE_LEVEL" \
       '. + {custom_supported:$custom,settings:$settings,metrics:$metrics,effective:$effective,firmware_sensitivity:$firmware}'
