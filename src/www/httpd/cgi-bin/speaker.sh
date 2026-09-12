#!/bin/sh

# Immediate speaker playback endpoint.
# Accepts either a raw request body or a browser multipart/form-data upload.
# Audio must be raw PCM16LE/16000/mono or a PCM WAV with the same format.

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

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

VOL="1"
VOLDB="0"
IS_DB="0"

PARAM="$(echo "$QUERY_STRING" | cut -d'&' -f1 | cut -d'=' -f1)"
VALUE="$(echo "$QUERY_STRING" | cut -d'&' -f1 | cut -d'=' -f2)"

if [ "$PARAM" = "vol" ]; then
    VOL="$VALUE"
    if ! $(validateNumber "$VOL"); then
        json_error "Invalid volume"
    fi
    IS_DB=0
elif [ "$PARAM" = "voldb" ]; then
    VOLDB="$VALUE"
    if ! $(validateNumber "$VOLDB"); then
        json_error "Invalid volume (dB)"
    fi
    IS_DB=1
fi

[ -e /tmp/audio_in_fifo ] || json_error "Audio input is not available"

case "$CONTENT_LENGTH" in
    ''|*[!0-9]*) CONTENT_LENGTH=0 ;;
esac

mount | grep /tmp/sd >/dev/null
if [ $? -eq 0 ]; then
    TMP_BASE="/tmp/sd/speaker.$$"
    MAX_UPLOAD=8388608
    ASYNC=1
else
    TMP_BASE="/tmp/speaker.$$"
    MAX_UPLOAD=512000
    ASYNC=0
fi

if [ "$CONTENT_LENGTH" -gt "$MAX_UPLOAD" ]; then
    json_error "File is too big"
fi

REQUEST_FILE="$TMP_BASE.request"
PCM_FILE="$TMP_BASE.audio"
trap 'rm -f "$REQUEST_FILE" "$PCM_FILE"' 0 1 2 15

cat > "$REQUEST_FILE" || json_error "Unable to read audio upload"

ROW1="$(sed -n '1p' "$REQUEST_FILE")"
ROW2="$(sed -n '2p' "$REQUEST_FILE")"
ROW3="$(sed -n '3p' "$REQUEST_FILE")"
ROW4="$(sed -n '4p' "$REQUEST_FILE")"

case "$ROW1" in
    --*)
        LENSKIPSTART=$((${#ROW1} + 1 + ${#ROW2} + 1 + ${#ROW3} + 1 + ${#ROW4} + 1))
        LENSKIPEND=$((${#ROW1} + 1 + 4))
        PAYLOAD_LEN=$((CONTENT_LENGTH - LENSKIPSTART - LENSKIPEND))
        [ "$PAYLOAD_LEN" -gt 0 ] || json_error "Uploaded file is empty"
        dd if="$REQUEST_FILE" of="$PCM_FILE" bs=1 skip="$LENSKIPSTART" count="$PAYLOAD_LEN" >/dev/null 2>&1 || json_error "Unable to extract upload"
        rm -f "$REQUEST_FILE"
        ;;
    *)
        mv "$REQUEST_FILE" "$PCM_FILE" || json_error "Unable to prepare audio upload"
        ;;
esac

speaker decode "$PCM_FILE" >/dev/null 2>&1 || json_error "Audio must be PCM16LE 16 kHz mono or compatible PCM WAV"

play_audio()
{
    if [ "$IS_DB" -eq 1 ]; then
        speaker decode "$PCM_FILE" 2>/dev/null | pcmvol -G "$VOLDB" | speaker stream pcm >/dev/null 2>&1
    else
        speaker decode "$PCM_FILE" 2>/dev/null | pcmvol -g "$VOL" | speaker stream pcm >/dev/null 2>&1
    fi
    RES=$?
    rm -f "$PCM_FILE"
    return "$RES"
}

if [ "$ASYNC" -eq 1 ]; then
    (play_audio) &
    trap - 0 1 2 15
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"description":"Queued"}'
else
    play_audio
    RES=$?
    trap - 0 1 2 15
    if [ "$RES" -ne 0 ]; then
        json_error "Speaker busy or unavailable"
    fi
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"description":"Played"}'
fi
