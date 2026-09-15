#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
SD_ROOT=${YI_HACK_SD_ROOT:-/tmp/sd}
MAX_UPLOAD=67108864
MIN_FREE_AFTER_KB=100000
LOCKDIR="$SD_ROOT/.fw_upload.lock.d"
UPLOAD_TMP="$SD_ROOT/.fw_upload.$$.tgz"
LIST_TMP="$SD_ROOT/.fw_upload.$$.list"
INIT_TMP="$SD_ROOT/.fw_upload.$$.init"

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"%s"}' "$1"
    exit 1
}

json_ok()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"description":"Firmware validated and staged.","model":"%s","version":"%s","size":%s}' "$1" "$2" "$3"
    exit 0
}

file_size()
{
    ls -ln "$1" 2>/dev/null | awk '{print $5}'
}

cleanup()
{
    rm -f "$UPLOAD_TMP" "$LIST_TMP" "$INIT_TMP" 2>/dev/null
    rm -f "$LOCKDIR/pid" 2>/dev/null
    rmdir "$LOCKDIR" 2>/dev/null
}
trap cleanup EXIT HUP INT TERM

[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"

case "$CONTENT_LENGTH" in
    ''|*[!0-9]*) json_error "Invalid content length" ;;
esac

if [ "$CONTENT_LENGTH" -le 0 ] || [ "$CONTENT_LENGTH" -gt "$MAX_UPLOAD" ]; then
    json_error "Firmware file is empty or larger than 64 MiB"
fi

[ -d "$SD_ROOT" ] || json_error "SD card is not available"

FREE_SD=$(df "$SD_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')
case "$FREE_SD" in
    ''|*[!0-9]*) json_error "Unable to determine free SD space" ;;
esac

UPLOAD_KB=$(((CONTENT_LENGTH + 1023) / 1024))
NEEDED_KB=$((UPLOAD_KB + MIN_FREE_AFTER_KB))
if [ "$FREE_SD" -lt "$NEEDED_KB" ]; then
    json_error "Not enough free SD space for firmware staging"
fi

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    case "$OLD_PID" in ''|*[!0-9]*) OLD_PID=0 ;; esac
    if [ "$OLD_PID" -gt 1 ] && [ -d "/proc/$OLD_PID" ]; then
        json_error "Another firmware upload is already in progress"
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || json_error "Unable to acquire firmware upload lock"
fi
echo $$ > "$LOCKDIR/pid"

cat > "$UPLOAD_TMP" || json_error "Firmware upload failed"

ACTUAL_SIZE=$(file_size "$UPLOAD_TMP")
case "$ACTUAL_SIZE" in
    ''|*[!0-9]*) json_error "Unable to verify uploaded file size" ;;
esac
[ "$ACTUAL_SIZE" -eq "$CONTENT_LENGTH" ] || json_error "Firmware upload was incomplete"

gzip -t "$UPLOAD_TMP" >/dev/null 2>&1 || json_error "Uploaded file is not a valid gzip archive"
tar tzf "$UPLOAD_TMP" > "$LIST_TMP" 2>/dev/null || json_error "Uploaded file is not a valid firmware tar.gz"
# Legitimate packed firmware contains only regular files and directories. Reject
# links and device nodes so an archive cannot redirect extraction outside staging.
tar tvzf "$UPLOAD_TMP" 2>/dev/null | awk 'BEGIN { bad=0 } { t=substr($1,1,1); if (t != "-" && t != "d") bad=1 } END { exit bad }' || json_error "Firmware archive contains links or special files"

# Firmware packages produced by pack_fw.sh have exactly these top-level roots.
# Reject absolute paths, traversal and unexpected roots before reading members.
awk '
BEGIN { bad=0; seen=0 }
{
    p=$0
    sub(/^\.\//, "", p)
    if (p == "" || p ~ /^\// || p ~ /(^|\/)\.\.(\/|$)/ || p ~ /\\/) bad=1
    split(p, a, "/")
    if (a[1] != "Factory" && a[1] != "lower_half_init.sh" && a[1] != "yi-hack") bad=1
    seen=1
}
END { if (!seen || bad) exit 1; exit 0 }
' "$LIST_TMP" || json_error "Firmware archive contains unsafe or unexpected paths"

grep -qx 'yi-hack/model_suffix' "$LIST_TMP" || json_error "Firmware archive is missing model information"
grep -qx 'yi-hack/version' "$LIST_TMP" || json_error "Firmware archive is missing version information"
grep -qx 'Factory/local_init.sh' "$LIST_TMP" || json_error "Firmware archive is missing the local-only bootstrap"
tar xOzf "$UPLOAD_TMP" Factory/local_init.sh > "$INIT_TMP" 2>/dev/null || json_error "Unable to extract firmware bootstrap"
/bin/sh -n "$INIT_TMP" || json_error "Firmware bootstrap has invalid syntax"
grep -qx 'lower_half_init.sh' "$LIST_TMP" || json_error "Firmware archive is incomplete"
grep -q '^Factory/' "$LIST_TMP" || json_error "Firmware archive is missing Factory files"

CURRENT_MODEL=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null | tr -d '\r\n')
ARCHIVE_MODEL=$(tar xOzf "$UPLOAD_TMP" yi-hack/model_suffix 2>/dev/null | tr -d '\r\n')
ARCHIVE_VERSION=$(tar xOzf "$UPLOAD_TMP" yi-hack/version 2>/dev/null | tr -d '\r\n')

case "$CURRENT_MODEL" in ''|*[!A-Za-z0-9_-]*) json_error "Current camera model is invalid" ;; esac
case "$ARCHIVE_MODEL" in ''|*[!A-Za-z0-9_-]*) json_error "Firmware model metadata is invalid" ;; esac
case "$ARCHIVE_VERSION" in ''|*[!A-Za-z0-9._-]*) json_error "Firmware version metadata is invalid" ;; esac
[ "${#ARCHIVE_VERSION}" -le 64 ] || json_error "Firmware version metadata is too long"

if [ "$ARCHIVE_MODEL" != "$CURRENT_MODEL" ]; then
    json_error "Firmware is for $ARCHIVE_MODEL, but this camera is $CURRENT_MODEL"
fi

LOCAL_FW="$SD_ROOT/${CURRENT_MODEL}_x.x.x.tgz"
rm -f "$LOCAL_FW" 2>/dev/null
mv "$UPLOAD_TMP" "$LOCAL_FW" || json_error "Unable to stage uploaded firmware"
chmod 0600 "$LOCAL_FW" 2>/dev/null

rm -f "$LIST_TMP"
trap - EXIT HUP INT TERM
rm -f "$LOCKDIR/pid" 2>/dev/null
rmdir "$LOCKDIR" 2>/dev/null

json_ok "$ARCHIVE_MODEL" "$ARCHIVE_VERSION" "$ACTUAL_SIZE"
