#!/bin/sh

YI_HACK_PREFIX="/tmp/sd/yi-hack"

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"%s"}' "$1"
    exit
}

if ! $(validateQueryString "$QUERY_STRING"); then
    json_error "Wrong parameter"
fi

MOTION_CHANGED=0
CONF_LAST="CONF_LAST"

for I in 1 2 3 4 5 6 7 8 9 10 11 12
do
    CONF="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f1)"
    VAL="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f2-)"

    [ -n "$CONF" ] || continue

    if ! $(validateString "$CONF"); then
        json_error "Invalid setting"
    fi
    if ! $(validateString "$VAL"); then
        json_error "Invalid value"
    fi

    if [ "$CONF" = "$CONF_LAST" ]; then
        continue
    fi
    CONF_LAST="$CONF"

    case "$CONF" in
        switch_on)
            case "$VAL" in
                no) ipc_cmd -t off ;;
                yes) ipc_cmd -t on ;;
            esac
            ;;
        save_video_on_motion)
            case "$VAL" in
                no|yes) MOTION_CHANGED=1 ;;
            esac
            ;;
        motion_detection)
            case "$VAL" in
                no|yes) MOTION_CHANGED=1 ;;
            esac
            ;;
        motion_human_only)
            case "$VAL" in
                no|yes) MOTION_CHANGED=1 ;;
            esac
            ;;
        motion_sensitivity)
            case "$VAL" in
                1|2|3|4|5|6|7|8|9|10) MOTION_CHANGED=1 ;;
            esac
            ;;
        sound_detection)
            case "$VAL" in
                no) ipc_cmd -b off ;;
                yes) ipc_cmd -b on ;;
            esac
            ;;
        sound_sensitivity)
            case "$VAL" in
                30|35|40|45|50|60|70|80|90) ipc_cmd -n "$VAL" ;;
            esac
            ;;
        led)
            case "$VAL" in
                no) ipc_cmd -l off ;;
                yes) ipc_cmd -l on ;;
            esac
            ;;
        ir)
            case "$VAL" in
                no) ipc_cmd -i off ;;
                yes) ipc_cmd -i on ;;
            esac
            ;;
        rotate)
            case "$VAL" in
                no) ipc_cmd -r off ;;
                yes) ipc_cmd -r on ;;
            esac
            ;;
        cruise)
            case "$VAL" in
                no)
                    ipc_cmd -C off
                    ;;
                presets)
                    ipc_cmd -C on
                    sleep 0.5
                    ipc_cmd -C presets
                    ;;
                360)
                    ipc_cmd -C on
                    sleep 0.5
                    ipc_cmd -C 360
                    ;;
            esac
            ;;
    esac
    sleep 0.1
done

if [ "$MOTION_CHANGED" -eq 1 ]; then
    "$YI_HACK_PREFIX/script/motion_service.sh" restart >/dev/null 2>&1 || json_error "Motion service failed to apply settings"
fi

printf "Content-type: application/json\r\n\r\n"
printf '{"error":false}'
