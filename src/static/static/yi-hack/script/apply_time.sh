#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/time_config.sh"

"$YI_HACK_PREFIX/script/update_osd_tz.sh" || exit 1

# Refresh only our OSD schedule; retain user and recording maintenance jobs.
TIME_CRON=${TIME_CRON:-/var/spool/cron/crontabs/root}
mkdir -p "$(dirname "$TIME_CRON")"
TIME_CRON_TMP="$TIME_CRON.time.$$"
if [ -f "$TIME_CRON" ]; then
    sed '\| /tmp/sd/yi-hack/script/update_osd_tz.sh$|d' "$TIME_CRON" > "$TIME_CRON_TMP"
else
    : > "$TIME_CRON_TMP"
fi
if [ "$(time_config_value TIME_OSD)" = yes ]; then
    printf '%s\n' '* * * * * /tmp/sd/yi-hack/script/update_osd_tz.sh' >> "$TIME_CRON_TMP"
fi
mv "$TIME_CRON_TMP" "$TIME_CRON"

# A running recorder retains its startup environment. Apply new filename rules
# to subsequent clips, using the usual singleton and encoder startup policy.
TIME_SERVICE="$YI_HACK_PREFIX/script/service.sh"
if [ "$(time_config_value REC_WITHOUT_CLOUD)" = yes ] &&
   [ "$("$TIME_SERVICE" mp4record status)" = started ]; then
    "$TIME_SERVICE" mp4record stop
    TIME_WAIT=0
    while [ "$("$TIME_SERVICE" mp4record status)" = started ] && [ "$TIME_WAIT" -lt 15 ]; do
        sleep 0.2
        TIME_WAIT=$((TIME_WAIT+1))
    done
    [ "$("$TIME_SERVICE" mp4record status)" != started ] || exit 1
    "$TIME_SERVICE" mp4record start
fi
