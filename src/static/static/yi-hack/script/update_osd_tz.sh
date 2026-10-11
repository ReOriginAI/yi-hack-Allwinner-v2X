#!/bin/sh

CONF_FILE="etc/system.conf"

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/time_config.sh"
MODEL_SUFFIX=$(cat /tmp/sd/yi-hack/model_suffix)

HOMEVER=$(cat /home/homever)
HV=${HOMEVER:0:2}
if [ "${HV:1:1}" == "." ]; then
    HV=${HV:0:1}
fi

get_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CONF_FILE | cut -d "=" -f2-
}

if [ "$(get_config TIME_OSD)" = yes ]; then
    "$YI_HACK_PREFIX/bin/set_tz_offset" -c osd -o on || exit 1
else
    "$YI_HACK_PREFIX/bin/set_tz_offset" -c osd -o off || exit 1
fi
# Apply the sign to both hours and minutes (for example Newfoundland -03:30).
TZP_SET=$(timezone_offset_seconds)
"$YI_HACK_PREFIX/bin/set_tz_offset" -c tz_offset_osd -m "$MODEL_SUFFIX" -f "$HV" -v "$TZP_SET"
