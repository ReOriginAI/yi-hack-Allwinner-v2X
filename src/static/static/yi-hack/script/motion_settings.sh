#!/bin/sh
# Shared validation/defaults for saved motion settings. Source this file.
motion_read_config()
{
    jq -Rn 'reduce inputs as $line ({
        MOTION_DETECTION:"no", SAVE_VIDEO_ON_MOTION:"yes", MOTION_SENSITIVITY:"5",
        MOTION_CUSTOM:"no", MOTION_START_THRESHOLD:"3.00", MOTION_STOP_THRESHOLD:"0.30",
        MOTION_START_SAMPLES:"3", MOTION_STOP_DELAY:"2000", MOTION_POLL_INTERVAL:"100",
        MOTION_STOP_REQUIRE_ZERO:"yes"
    }; ($line | index("=")) as $n | if $n == null then .
       else . + {($line[:$n]):$line[$n+1:]} end)' < "$YI_HACK_PREFIX/etc/camera.conf"
}

motion_validate_json()
{
    printf '%s\n' "$1" | jq -e '
        def number($key; $lo; $hi; $pattern):
            .[$key] | if type == "string" or type == "number" then tostring else "" end |
            if test($pattern) then tonumber | . >= $lo and . <= $hi else false end;
        (.MOTION_DETECTION == "yes" or .MOTION_DETECTION == "no") and
        (.SAVE_VIDEO_ON_MOTION == "yes" or .SAVE_VIDEO_ON_MOTION == "no") and
        (.MOTION_CUSTOM == "yes" or .MOTION_CUSTOM == "no") and
        (.MOTION_STOP_REQUIRE_ZERO == "yes" or .MOTION_STOP_REQUIRE_ZERO == "no") and
        number("MOTION_SENSITIVITY";1;10;"^([1-9]|10)$") and
        number("MOTION_START_THRESHOLD";0.01;100;"^[0-9]{1,3}(\\.[0-9]{1,2})?$") and
        number("MOTION_STOP_THRESHOLD";0;100;"^[0-9]{1,3}(\\.[0-9]{1,2})?$") and
        number("MOTION_START_SAMPLES";1;50;"^[0-9]{1,5}$") and
        number("MOTION_STOP_DELAY";100;30000;"^[0-9]{1,5}$") and
        number("MOTION_POLL_INTERVAL";100;2000;"^[0-9]{1,5}$") and
        ((.MOTION_STOP_THRESHOLD | tonumber) < (.MOTION_START_THRESHOLD | tonumber))
    ' >/dev/null 2>&1
}
