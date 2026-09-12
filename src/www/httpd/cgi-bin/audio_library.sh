#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

YI_HACK_PREFIX="/tmp/sd/yi-hack"
AUDIO_DIR="/tmp/sd/audio"
MAX_UPLOAD=8388608

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
        ''|.*|*/*|*\\*|*[!A-Za-z0-9._-]*)
            return 1
            ;;
        *.pcm|*.PCM|*.wav|*.WAV)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

sanitize_audio_name()
{
    printf '%s' "$1" | sed 's|.*[\\/]||; s/[^A-Za-z0-9._-]/_/g; s/^\.*//'
}

read_post_name()
{
    IFS= read -r POST_NAME
    printf '%s' "$POST_NAME"
}

file_size()
{
    ls -ln "$1" 2>/dev/null | awk '{print $5}'
}

if ! $(validateQueryString "$QUERY_STRING"); then
    json_error "Wrong parameter"
fi

ACTION=""
VOLDB="0"

for I in 1 2 3
do
    PARAM="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f1)"
    VALUE="$(echo "$QUERY_STRING" | cut -d'&' -f$I | cut -d'=' -f2)"

    if [ "$PARAM" = "action" ]; then
        ACTION="$VALUE"
    elif [ "$PARAM" = "voldb" ]; then
        VOLDB="$VALUE"
    fi
done

if ! $(validateNumber "$VOLDB"); then
    json_error "Invalid volume"
fi

mount | grep " /tmp/sd " >/dev/null || json_error "SD card is not mounted"
mkdir -p "$AUDIO_DIR" || json_error "Unable to create audio library"

if [ "$ACTION" = "list" ]; then
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"files":['
    FIRST=1
    for FILE in "$AUDIO_DIR"/*
    do
        [ -f "$FILE" ] || continue
        NAME="${FILE##*/}"
        valid_audio_name "$NAME" || continue
        SIZE="$(file_size "$FILE")"
        [ -n "$SIZE" ] || SIZE=0
        if [ "$FIRST" -eq 0 ]; then
            printf ','
        fi
        printf '{"name":"%s","size":%s}' "$NAME" "$SIZE"
        FIRST=0
    done
    printf ']}'
    exit
fi

if [ "$ACTION" = "upload" ]; then
    [ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"

    case "$CONTENT_LENGTH" in
        ''|*[!0-9]*) json_error "Invalid content length" ;;
    esac

    if [ "$CONTENT_LENGTH" -le 0 ] || [ "$CONTENT_LENGTH" -gt "$MAX_UPLOAD" ]; then
        json_error "File is too big or empty"
    fi

    REQUEST_FILE="$AUDIO_DIR/.upload_request.$$"
    PAYLOAD_FILE="$AUDIO_DIR/.upload_payload.$$"
    trap 'rm -f "$REQUEST_FILE" "$PAYLOAD_FILE"' 0 1 2 15

    cat > "$REQUEST_FILE" || json_error "Upload failed"

    ROW1="$(sed -n '1p' "$REQUEST_FILE")"
    ROW2="$(sed -n '2p' "$REQUEST_FILE")"
    ROW3="$(sed -n '3p' "$REQUEST_FILE")"
    ROW4="$(sed -n '4p' "$REQUEST_FILE")"

    case "$ROW1" in
        --*) ;;
        *) json_error "Invalid multipart upload" ;;
    esac

    ORIGINAL_NAME="$(printf '%s\n' "$ROW2" | sed -n 's/.*filename="\([^"]*\)".*/\1/p' | tr -d '\r')"
    SAFE_NAME="$(sanitize_audio_name "$ORIGINAL_NAME")"
    valid_audio_name "$SAFE_NAME" || json_error "Only .pcm and .wav files with simple filenames are supported"

    # Browser FormData produces: boundary, Content-Disposition, Content-Type,
    # blank line, payload, CRLF, closing boundary. Command substitution keeps
    # the CR byte, so +1 accounts for each removed LF byte.
    LENSKIPSTART=$((${#ROW1} + 1 + ${#ROW2} + 1 + ${#ROW3} + 1 + ${#ROW4} + 1))
    LENSKIPEND=$((${#ROW1} + 1 + 4))
    PAYLOAD_LEN=$((CONTENT_LENGTH - LENSKIPSTART - LENSKIPEND))

    if [ "$PAYLOAD_LEN" -le 0 ]; then
        json_error "Uploaded file is empty"
    fi

    dd if="$REQUEST_FILE" of="$PAYLOAD_FILE" bs=1 skip="$LENSKIPSTART" count="$PAYLOAD_LEN" >/dev/null 2>&1 || json_error "Unable to extract upload"

    SIZE="$(file_size "$PAYLOAD_FILE")"
    [ -n "$SIZE" ] || SIZE=0
    if [ "$SIZE" -le 0 ]; then
        json_error "Uploaded file is empty"
    fi

    case "$SAFE_NAME" in
        *.wav|*.WAV)
            MAGIC="$(dd if="$PAYLOAD_FILE" bs=1 count=4 2>/dev/null)"
            [ "$MAGIC" = "RIFF" ] || json_error "WAV file is not RIFF/WAVE"
            speaker decode "$PAYLOAD_FILE" >/dev/null 2>&1 || json_error "WAV must be PCM 16 kHz, 16-bit, mono"
            ;;
        *.pcm|*.PCM)
            if [ $((SIZE % 2)) -ne 0 ]; then
                json_error "PCM file must contain complete 16-bit samples"
            fi
            ;;
    esac

    mv -f "$PAYLOAD_FILE" "$AUDIO_DIR/$SAFE_NAME" || json_error "Unable to store audio file"
    chmod 0644 "$AUDIO_DIR/$SAFE_NAME"
    rm -f "$REQUEST_FILE"
    trap - 0 1 2 15

    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"description":"Uploaded","name":"%s","size":%s}' "$SAFE_NAME" "$SIZE"
    exit
fi

if [ "$ACTION" = "delete" ]; then
    [ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
    NAME="$(read_post_name)"
    valid_audio_name "$NAME" || json_error "Invalid filename"
    [ -f "$AUDIO_DIR/$NAME" ] || json_error "File not found"
    rm -f "$AUDIO_DIR/$NAME" || json_error "Unable to delete file"

    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"description":"Deleted","name":"%s"}' "$NAME"
    exit
fi

if [ "$ACTION" = "play" ]; then
    [ "$REQUEST_METHOD" = "POST" ] || json_error "POST required"
    NAME="$(read_post_name)"
    valid_audio_name "$NAME" || json_error "Invalid filename"
    AUDIO_FILE="$AUDIO_DIR/$NAME"

    [ -f "$AUDIO_FILE" ] || json_error "File not found"
    [ -e /tmp/audio_in_fifo ] || json_error "Audio input is not available"
    speaker decode "$AUDIO_FILE" >/dev/null 2>&1 || json_error "Unsupported audio format"

    speaker decode "$AUDIO_FILE" 2>/dev/null | pcmvol -G "$VOLDB" | speaker stream pcm >/dev/null 2>&1
    RES=$?

    if [ "$RES" -ne 0 ]; then
        json_error "Speaker busy or unavailable"
    fi

    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"description":"Played","name":"%s"}' "$NAME"
    exit
fi

json_error "Unknown action"
