#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
SD_ROOT=${YI_HACK_SD_ROOT:-/tmp/sd}
RELEASE_API=${YI_HACK_RELEASE_API:-https://api.github.com/repos/ReOriginAI/yi-hack-Allwinner-v2X/releases/latest}
WGET_BIN=${YI_HACK_WGET_BIN:-$YI_HACK_PREFIX/usr/bin/wget}
RELEASE_PREFIX=https://github.com/ReOriginAI/yi-hack-Allwinner-v2X/releases/download/
MAX_DOWNLOAD=67108864
MIN_FREE_AFTER_KB=100000
META_TMP="$SD_ROOT/.fw_online.$$.json"
DOWNLOAD_TMP="$SD_ROOT/.fw_online.$$.tgz"

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"%s"}' "$1"
    exit 1
}

cleanup()
{
    rm -f "$META_TMP" "$DOWNLOAD_TMP" 2>/dev/null
}
trap cleanup EXIT HUP INT TERM

if ! $(validateQueryString "$QUERY_STRING"); then
    json_error "Invalid query string"
fi

NAME=$(echo "$QUERY_STRING" | cut -d'=' -f1)
VAL=$(echo "$QUERY_STRING" | cut -d'=' -f2)
[ "$NAME" = "get" ] || json_error "Invalid query"

MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null | tr -d '\r\n')
FW_VERSION=$(cat "$YI_HACK_PREFIX/version" 2>/dev/null | tr -d '\r\n')
LOCAL_FW="$SD_ROOT/${MODEL_SUFFIX}_x.x.x.tgz"

case "$MODEL_SUFFIX" in ''|*[!A-Za-z0-9_-]*) json_error "Current camera model is invalid" ;; esac
case "$FW_VERSION" in ''|*[!A-Za-z0-9._-]*) json_error "Installed firmware version is invalid" ;; esac
[ -x "$WGET_BIN" ] || json_error "Firmware downloader is unavailable"
[ -d "$SD_ROOT" ] || json_error "SD card is not available"

if ! "$WGET_BIN" -q -O "$META_TMP" "$RELEASE_API" >/dev/null 2>&1; then
    if [ "$VAL" = "info" ]; then
        printf "Content-type: application/json\r\n\r\n"
        printf '{"error":false,"fw_version":"%s","local_fw":%s,"online_available":false,"online_error":true,"latest_fw":""}' \
            "$FW_VERSION" "$([ -f "$LOCAL_FW" ] && echo true || echo false)"
        exit 0
    fi
    json_error "Unable to query the ReOriginAI release feed"
fi

ASSET_URL=$(awk -v model="$MODEL_SUFFIX" -v prefix="$RELEASE_PREFIX" '
/"browser_download_url"[[:space:]]*:/ {
    u=$0
    sub(/^.*"browser_download_url"[[:space:]]*:[[:space:]]*"/, "", u)
    sub(/".*$/, "", u)
    if (index(u, prefix) != 1) next
    n=split(u, p, "/")
    f=p[n]
    if (index(f, model "_") == 1 && f ~ /\.tgz$/) {
        print u
        exit
    }
}
' "$META_TMP")

[ -n "$ASSET_URL" ] || {
    if [ "$VAL" = "info" ]; then
        printf "Content-type: application/json\r\n\r\n"
        printf '{"error":false,"fw_version":"%s","local_fw":%s,"online_available":false,"online_error":true,"latest_fw":""}' \
            "$FW_VERSION" "$([ -f "$LOCAL_FW" ] && echo true || echo false)"
        exit 0
    fi
    json_error "Latest ReOriginAI release has no firmware for this model"
}

case "$ASSET_URL" in
    "$RELEASE_PREFIX"*) ;;
    *) json_error "Release asset URL is not trusted" ;;
esac

ASSET_NAME=${ASSET_URL##*/}
case "$ASSET_NAME" in
    "$MODEL_SUFFIX"_*.tgz) ;;
    *) json_error "Release asset name does not match this model" ;;
esac
LATEST_FW=${ASSET_NAME#${MODEL_SUFFIX}_}
LATEST_FW=${LATEST_FW%.tgz}
case "$LATEST_FW" in ''|*[!A-Za-z0-9._-]*) json_error "Release firmware version is invalid" ;; esac

if [ -f "$LOCAL_FW" ]; then
    LOCAL_FW_PRESENT=true
else
    LOCAL_FW_PRESENT=false
fi

if [ "$FW_VERSION" = "$LATEST_FW" ]; then
    ONLINE_AVAILABLE=false
else
    ONLINE_AVAILABLE=true
fi

if [ "$VAL" = "info" ]; then
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"fw_version":"%s","local_fw":%s,"online_available":%s,"online_error":false,"latest_fw":"%s"}' \
        "$FW_VERSION" "$LOCAL_FW_PRESENT" "$ONLINE_AVAILABLE" "$LATEST_FW"
    exit 0
fi

[ "$VAL" = "download" ] || json_error "Invalid query"
[ "$ONLINE_AVAILABLE" = "true" ] || json_error "The latest online release is already installed"
[ ! -f "$LOCAL_FW" ] || json_error "A firmware upload is already staged; install it before downloading an online release"

FREE_SD=$(df "$SD_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')
case "$FREE_SD" in ''|*[!0-9]*) json_error "Unable to determine free SD space" ;; esac
[ "$FREE_SD" -ge "$MIN_FREE_AFTER_KB" ] || json_error "Not enough free SD space for firmware download"

rm -f "$DOWNLOAD_TMP"
"$WGET_BIN" -q -O "$DOWNLOAD_TMP" "$ASSET_URL" >/dev/null 2>&1 || json_error "Unable to download firmware from ReOriginAI"

DOWNLOAD_SIZE=$(ls -ln "$DOWNLOAD_TMP" 2>/dev/null | awk '{print $5}')
case "$DOWNLOAD_SIZE" in ''|*[!0-9]*) json_error "Unable to verify downloaded firmware size" ;; esac
[ "$DOWNLOAD_SIZE" -gt 0 ] || json_error "Downloaded firmware is empty"
[ "$DOWNLOAD_SIZE" -le "$MAX_DOWNLOAD" ] || json_error "Downloaded firmware is larger than 64 MiB"

# Feed online releases through the exact same validator/stager used by browser uploads.
REQUEST_METHOD=POST \
CONTENT_LENGTH="$DOWNLOAD_SIZE" \
YI_HACK_PREFIX="$YI_HACK_PREFIX" \
YI_HACK_SD_ROOT="$SD_ROOT" \
/bin/sh "$YI_HACK_PREFIX/www/cgi-bin/fw_upload.sh" < "$DOWNLOAD_TMP"
RC=$?
cleanup
trap - EXIT HUP INT TERM
exit "$RC"
