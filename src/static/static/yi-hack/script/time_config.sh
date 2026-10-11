#!/bin/sh
# Shared wall-clock policy. Keep the system clock and MP4 epochs in UTC.

time_config_value()
{
    sed -n "s/^$1=//p" "${YI_HACK_PREFIX:-/tmp/sd/yi-hack}/etc/system.conf"
}

camera_timezone()
{
    CAMERA_TZ=$(time_config_value TIMEZONE)
    printf '%s\n' "${CAMERA_TZ:-UTC0}"
}

recording_timezone()
{
    case "$(time_config_value EVENTS_TIME)" in
        local) camera_timezone ;;
        gmt) printf '%s\n' UTC0 ;;
        *)
            # Preserve the historical OSD-dependent default in automatic mode.
            if [ "$(time_config_value TIME_OSD)" = yes ]; then
                camera_timezone
            else
                printf '%s\n' UTC0
            fi
            ;;
    esac
}

timezone_offset_seconds()
{
    TZ="${1:-$(camera_timezone)}" date +%z |
        awk '{sign=substr($0,1,1)=="-" ? -1 : 1;
              print sign*(substr($0,2,2)*3600+substr($0,4,2)*60)}'
}
