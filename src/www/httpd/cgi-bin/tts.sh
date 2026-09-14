#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib

YI_HACK_PREFIX="/tmp/sd/yi-hack"
TTS="$YI_HACK_PREFIX/bin/tts"
BUSYBOX="$YI_HACK_PREFIX/bin/busybox"
MAX_TEXT=1024
MAX_BODY=4096
LOG_FILE="/tmp/tts-cgi-last"

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"%s"}' "$1"
    exit
}

number_in_range()
{
    VALUE="$1"
    MIN="$2"
    MAX="$3"
    validateNumber "$VALUE" || return 1
    awk -v v="$VALUE" -v lo="$MIN" -v hi="$MAX" 'BEGIN { exit !(v >= lo && v <= hi) }'
}

url_decode()
{
    "$BUSYBOX" httpd -d "$1"
}

[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
[ -x "$TTS" ] || json_error "Text-to-speech is not installed"
[ -x "$BUSYBOX" ] || json_error "BusyBox is not installed"
[ -e /tmp/audio_in_fifo ] || json_error "Audio input is not available"

if ! validateQueryString "$QUERY_STRING"; then
    json_error "Wrong parameter"
fi

VOICE="en-US"
SPEED="1.0"
PITCH="1.0"
VOLUME="1.0"
TEXT=""

# AJAX clients pass options in the query string.
for I in 1 2 3 4
do
    PARAM="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f1)"
    VALUE="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f2-)"
    case "$PARAM" in
        voice) VOICE="$VALUE" ;;
        speed) SPEED="$VALUE" ;;
        pitch) PITCH="$VALUE" ;;
        volume) VOLUME="$VALUE" ;;
    esac
done

case "$CONTENT_LENGTH" in
    ''|*[!0-9]*) json_error "Invalid content length" ;;
esac

if [ "$CONTENT_LENGTH" -le 0 ] || [ "$CONTENT_LENGTH" -gt "$MAX_BODY" ]; then
    json_error "Request body is empty or too long"
fi

BODY="$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)"
[ -n "$BODY" ] || json_error "Text is empty"

# Native HTML form fallback. This keeps WebUI TTS usable even if the bundled
# JavaScript fails to initialize or its delegated click handler is stale.
case "$CONTENT_TYPE" in
    application/x-www-form-urlencoded*)
        for I in 1 2 3 4 5 6 7 8
        do
            PAIR="$(echo "$BODY" | cut -d'&' -f$I)"
            [ -n "$PAIR" ] || continue
            PARAM="${PAIR%%=*}"
            VALUE="${PAIR#*=}"
            PARAM="$(url_decode "$PARAM")"
            VALUE="$(url_decode "$VALUE")"
            case "$PARAM" in
                text) TEXT="$VALUE" ;;
                voice) VOICE="$VALUE" ;;
                speed) SPEED="$VALUE" ;;
                pitch) PITCH="$VALUE" ;;
                volume) VOLUME="$VALUE" ;;
            esac
        done
        ;;
    *)
        TEXT="$BODY"
        ;;
esac

[ -n "$TEXT" ] || json_error "Text is empty"
[ "${#TEXT}" -le "$MAX_TEXT" ] || json_error "Text is too long"

case "$VOICE" in
    en-US|en-GB|de-DE|es-ES|fr-FR|it-IT) ;;
    *) json_error "Unsupported voice" ;;
esac

number_in_range "$SPEED" 0.2 5.0 || json_error "Invalid speed"
number_in_range "$PITCH" 0.5 2.0 || json_error "Invalid pitch"
number_in_range "$VOLUME" 0.0 5.0 || json_error "Invalid volume"

printf 'time=%s remote=%s len=%s type=%s voice=%s speed=%s pitch=%s volume=%s\n' \
    "$(date +%s 2>/dev/null)" "${REMOTE_ADDR:-local}" "${#TEXT}" "${CONTENT_TYPE:-unknown}" \
    "$VOICE" "$SPEED" "$PITCH" "$VOLUME" >"$LOG_FILE"

ERR="/tmp/tts-cgi.err.$$"
"$TTS" -v "$VOICE" --speed "$SPEED" --pitch "$PITCH" --volume "$VOLUME" "$TEXT" >/dev/null 2>"$ERR"
RES=$?
printf 'result=%s\n' "$RES" >>"$LOG_FILE"

if [ "$RES" -ne 0 ]; then
    MSG="$(sed -n '1p' "$ERR" 2>/dev/null)"
    rm -f "$ERR"
    [ -n "$MSG" ] || MSG="Speaker busy, voice unavailable, or TTS failed"
    json_error "$MSG"
fi
rm -f "$ERR"

printf "Content-type: application/json\r\n\r\n"
printf '{"error":false,"description":"Spoken"}'
