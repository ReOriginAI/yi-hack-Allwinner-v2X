#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
CONF_FILE=${AUDIO_AEC_CONF:-$YI_HACK_PREFIX/etc/system.conf}
MODEL_SUFFIX=${MODEL_SUFFIX:-$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)}
ACTION=${1:-apply}

file_md5()
{
    set -- $(md5sum "$1" 2>/dev/null)
    printf '%s\n' "$1"
}

get_mode()
{
    MODE=$(grep '^AUDIO_AEC=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
    case "$MODE" in
        yes|no|auto) ;;
        *) MODE=auto ;;
    esac
    printf '%s\n' "$MODE"
}

case "$MODEL_SUFFIX" in
    y623)
        EXPECTED_RMM_MD5=eb9d532e71d0d8697d22d0775b744b40
        AEC_ADDR=2248868
        ;;
    y28ga)
        EXPECTED_RMM_MD5=14aa4ee21e04fb40a3c321fdcd12eef4
        AEC_ADDR=2342796
        ;;
    *)
        exit 0
        ;;
esac

MODE=$(get_mode)
case "$ACTION" in
    apply)
        case "$MODE" in
            yes) DESIRED=1 ;;
            no)  DESIRED=0 ;;
            auto)
                if ps | grep '[s]peaker stream' >/dev/null 2>&1; then
                    DESIRED=1
                else
                    DESIRED=0
                fi
                ;;
        esac
        ;;
    speaker-start)
        if [ "$MODE" = "no" ]; then DESIRED=0; else DESIRED=1; fi
        ;;
    speaker-stop)
        if [ "$MODE" = "yes" ]; then DESIRED=1; else DESIRED=0; fi
        ;;
    on)  DESIRED=1 ;;
    off) DESIRED=0 ;;
    *)
        echo "Usage: $0 apply|speaker-start|speaker-stop|on|off" >&2
        exit 2
        ;;
esac

PID=$(ps | awk '$5 == "./rmm" || $5 == "/home/app/rmm" { print $1; exit }')
[ -n "$PID" ] && [ -r "/proc/$PID/mem" ] || exit 1

RMM_MD5=$(file_md5 /home/app/rmm)
if [ "$RMM_MD5" != "$EXPECTED_RMM_MD5" ]; then
    echo "audio_aec: refusing unknown $MODEL_SUFFIX rmm ($RMM_MD5)" >&2
    exit 1
fi

VALUE=/tmp/audio_aec.value.$$
READBACK=/tmp/audio_aec.readback.$$
trap 'rm -f "$VALUE" "$READBACK"' EXIT HUP INT TERM

if [ "$DESIRED" -eq 1 ]; then
    printf '\001\000\000\000' > "$VALUE"
    STATE=on
else
    printf '\000\000\000\000' > "$VALUE"
    STATE=off
fi

BLOCK=$((AEC_ADDR / 4))
dd if="$VALUE" of="/proc/$PID/mem" bs=4 seek="$BLOCK" count=1 conv=notrunc 2>/dev/null || exit 1
dd if="/proc/$PID/mem" of="$READBACK" bs=4 skip="$BLOCK" count=1 2>/dev/null || exit 1

[ "$(file_md5 "$VALUE")" = "$(file_md5 "$READBACK")" ] || {
    echo "audio_aec: $MODEL_SUFFIX write verification failed" >&2
    exit 1
}

printf '%s\n' "$STATE" > /tmp/audio_aec.state
exit 0
