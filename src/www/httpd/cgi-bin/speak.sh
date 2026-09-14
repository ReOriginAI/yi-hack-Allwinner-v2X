#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib

YI_HACK_PREFIX="/tmp/sd/yi-hack"
TTS="$YI_HACK_PREFIX/bin/tts"
MAX_TEXT=1024

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"%s"}' "$1"
    exit
}

[ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
[ -x "$TTS" ] || json_error "Text-to-speech is not installed"
[ -e /tmp/audio_in_fifo ] || json_error "Audio input is not available"

if ! validateQueryString "$QUERY_STRING"; then
    json_error "Wrong parameter"
fi

LANG="en-US"
VOLDB="0"

for I in 1 2
do
    PARAM="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f1)"
    VALUE="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f2-)"
    case "$PARAM" in
        lang) LANG="$VALUE" ;;
        voldb) VOLDB="$VALUE" ;;
    esac
done

case "$LANG" in
    en-US|en-GB|de-DE|es-ES|fr-FR|it-IT) ;;
    *) json_error "Unsupported voice" ;;
esac

validateNumber "$VOLDB" || json_error "Invalid volume"

case "$CONTENT_LENGTH" in
    ''|*[!0-9]*) json_error "Invalid content length" ;;
esac

if [ "$CONTENT_LENGTH" -le 0 ] || [ "$CONTENT_LENGTH" -gt "$MAX_TEXT" ]; then
    json_error "Text is empty or too long"
fi

TEXT="$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)"
[ -n "$TEXT" ] || json_error "Text is empty"

# Convert the legacy dB setting to the linear volume multiplier expected by
# the new TTS wrapper. Clamp to the wrapper's supported 0.0-5.0 range.
VOLUME="$(awk -v db="$VOLDB" 'BEGIN { v=exp(log(10)*db/20); if (v<0) v=0; if (v>5) v=5; printf "%.3f", v }')"

ERR="/tmp/tts-cgi.err.$$"
"$TTS" -v "$LANG" --speed 1.0 --pitch 1.0 --volume "$VOLUME" "$TEXT" >/dev/null 2>"$ERR"
RES=$?

if [ "$RES" -ne 0 ]; then
    MSG="$(head -n 1 "$ERR" 2>/dev/null)"
    rm -f "$ERR"
    [ -n "$MSG" ] || MSG="Speaker busy, voice unavailable, or TTS failed"
    json_error "$MSG"
fi
rm -f "$ERR"

printf "Content-type: application/json\r\n\r\n"
printf '{"error":false,"description":"Spoken"}'
