#!/bin/sh

# Play a file stored in /tmp/sd/audio by basename.

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

YI_HACK_PREFIX="/tmp/sd/yi-hack"
FILE_PATH="/tmp/sd/audio"

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"%s"}' "$1"
    exit
}

valid_audio_name()
{
    case "$1" in
        ''|.*|*/*|*\\*|*[!A-Za-z0-9._-]*) return 1 ;;
        *.pcm|*.PCM|*.wav|*.WAV) return 0 ;;
        *) return 1 ;;
    esac
}

if ! $(validateQueryString "$QUERY_STRING"); then
    json_error "Wrong parameter"
fi

VOLDB="0"
for I in 1 2
do
    PARAM="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f1)"
    VALUE="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f2)"
    if [ "$PARAM" = "voldb" ]; then
        VOLDB="$VALUE"
    fi
done

if ! $(validateNumber "$VOLDB"); then
    json_error "Invalid volume"
fi

IFS= read -r POST_DATA
valid_audio_name "$POST_DATA" || json_error "Invalid filename"
AUDIO_FILE="$FILE_PATH/$POST_DATA"

[ -f "$AUDIO_FILE" ] || json_error "File not found"
[ -e /tmp/audio_in_fifo ] || json_error "Audio input disabled"
speaker decode "$AUDIO_FILE" >/dev/null 2>&1 || json_error "Unsupported audio format"

speaker decode "$AUDIO_FILE" 2>/dev/null | pcmvol -G "$VOLDB" | speaker stream pcm >/dev/null 2>&1
RES=$?

if [ "$RES" -ne 0 ]; then
    json_error "Speaker busy or unavailable"
fi

printf "Content-type: application/json\r\n\r\n"
printf '{"error":false,"description":"%s"}' "$POST_DATA"
