#!/bin/sh

CONF_FILE="etc/camera.conf"
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}

get_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CONF_FILE | cut -d "=" -f2-
}

fail()
{
    printf "Content-type: text/html\r\n\r\nUpload failed\r\n"
    exit 1
}
[ "$REQUEST_METHOD" = POST ] || fail
case "$CONTENT_LENGTH" in ''|*[!0-9]*) fail ;; esac
[ "$CONTENT_LENGTH" -gt 0 ] && [ "$CONTENT_LENGTH" -le 10000 ] || fail
. "$YI_HACK_PREFIX/script/config_work.sh"
config_work_begin || fail
TMPOUT="$CONFIG_WORK/request"
TMPOUTbz2="$CONFIG_WORK/config.tar.bz2"
dd bs=1 count="$CONTENT_LENGTH" of="$TMPOUT" 2>/dev/null || fail
[ "$(ls -ln "$TMPOUT" | awk '{print $5}')" -eq "$CONTENT_LENGTH" ] || fail
# Keep the WebUI's existing four-line multipart header format.
set -- $(awk 'NR==1 {end=length($0)+1} NR<=4 {n+=length($0)+1} NR==4 {print n,end; exit}' "$TMPOUT")
[ "$#" -eq 2 ] || fail
LENSKIPSTART=$1
LENSKIPEND=$2
LEN=$((CONTENT_LENGTH-LENSKIPSTART-LENSKIPEND-4))
[ "$LEN" -gt 0 ] || fail
dd if="$TMPOUT" of="$TMPOUTbz2" bs=1 skip="$LENSKIPSTART" count="$LEN" 2>/dev/null || fail
"$YI_HACK_PREFIX/script/restore_config.sh" "$TMPOUTbz2" "$CONFIG_WORK" || fail
cd "$CONFIG_WORK/unpacked" || fail
for FILE in *.conf hostname; do
    [ -f "$FILE" ] || continue
    chmod 0644 "$FILE" || fail
    mv -f "$FILE" "$YI_HACK_PREFIX/etc/" || fail
done
cd / || fail
config_work_cleanup
trap - 0 1 2 15
printf "Content-type: text/html\r\n\r\nUpload completed successfully, restart your camera\r\n"

# Set camera settings
if [[ $(get_config SWITCH_ON) == "no" ]] ; then
    ipc_cmd -t off
else
    ipc_cmd -t on
fi

if [[ $(get_config LED) == "no" ]] ; then
    ipc_cmd -l off
else
    ipc_cmd -l on
fi

if [[ $(get_config IR) == "no" ]] ; then
    ipc_cmd -i off
else
    ipc_cmd -i on
fi

if [[ $(get_config ROTATE) == "no" ]] ; then
    ipc_cmd -r off
else
    ipc_cmd -r on
fi

if [[ $(get_config CRUISE) == "off" ]] ; then
    ipc_cmd -C off
elif [[ $(get_config CRUISE) == "presets" ]] ; then
    ipc_cmd -C on
    sleep 0.5
    ipc_cmd -C presets
elif [[ $(get_config CRUISE) == "360" ]] ; then
    ipc_cmd -C on
    sleep 0.5
    ipc_cmd -C 360
fi

$YI_HACK_PREFIX/script/motion_service.sh restart >/dev/null 2>&1
