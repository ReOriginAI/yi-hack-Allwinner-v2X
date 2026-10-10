#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
CONF_FILE="$YI_HACK_PREFIX/etc/system.conf"

get_config()
{
    sed -n "s/^$1=//p" "$CONF_FILE"
}

LOCAL_IP=${LOCAL_IP:-$(ifconfig eth0 2>/dev/null | awk '/inet addr/{print substr($2,6)}')}
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(ifconfig wlan0 2>/dev/null | awk '/inet addr/{print substr($2,6)}')
fi

case $(get_config RTSP_PORT) in
    ''|*[!0-9]*) RTSP_PORT=554 ;;
    *) RTSP_PORT=$(get_config RTSP_PORT) ;;
esac
case $(get_config HTTPD_PORT) in
    ''|*[!0-9]*) HTTPD_PORT=80 ;;
    *) HTTPD_PORT=$(get_config HTTPD_PORT) ;;
esac
D_HTTPD_PORT=""
[ "$HTTPD_PORT" = "80" ] || D_HTTPD_PORT=:$HTTPD_PORT
RTSP_BASE="rtsp://$LOCAL_IP:$RTSP_PORT"
HTTP_BASE="http://$LOCAL_IP$D_HTTPD_PORT"

RTSP_ALT=$(get_config RTSP_ALT)
case "$RTSP_ALT" in
    alternative) ;;
    go2rtc) [ -x "$YI_HACK_PREFIX/bin/go2rtc" ] || RTSP_ALT=standard ;;
    *) RTSP_ALT=standard ;;
esac
BACKCHANNEL=$(get_config RTSP_BACKCHANNEL)
[ -n "$BACKCHANNEL" ] || BACKCHANNEL=$(get_config ONVIF_AUDIO_BC)
BACKCHANNEL_ENABLED=no
if [ "$BACKCHANNEL" = "G711" ] && [ "$(get_config SPEAKER_AUDIO)" != "no" ]; then
    case "$RTSP_ALT" in standard|go2rtc) BACKCHANNEL_ENABLED=yes ;; esac
fi

link()
{
    printf '"%s":"%s",\n' "$1" "$2"
}

printf 'Content-type: application/json\r\n\r\n{\n'
if [ "$(get_config RTSP)" = "yes" ]; then
    RTSP_STREAM=$(get_config RTSP_STREAM)
    if [ "$RTSP_STREAM" = "high" ] || [ "$RTSP_STREAM" = "both" ]; then
        link high_res_stream "$RTSP_BASE/ch0_0.h264"
        [ "$BACKCHANNEL_ENABLED" != "yes" ] || link high_res_backchannel "$RTSP_BASE/ch0_0.h264?backchannel=1"
    fi
    if [ "$RTSP_STREAM" = "low" ] || [ "$RTSP_STREAM" = "both" ]; then
        link low_res_stream "$RTSP_BASE/ch0_1.h264"
        [ "$BACKCHANNEL_ENABLED" != "yes" ] || link low_res_backchannel "$RTSP_BASE/ch0_1.h264?backchannel=1"
    fi
    RTSP_AUDIO=$(get_config RTSP_AUDIO)
    if [ "$RTSP_ALT" != "go2rtc" ] && [ -n "$RTSP_AUDIO" ] && [ "$RTSP_AUDIO" != "no" ] && [ "$RTSP_AUDIO" != "none" ]; then
        link audio_stream "$RTSP_BASE/ch0_2.h264"
    fi
fi
link low_res_snapshot "$HTTP_BASE/cgi-bin/snapshot.sh?res=low&watermark=yes"
link high_res_snapshot "$HTTP_BASE/cgi-bin/snapshot.sh?res=high&watermark=yes"
if [ -x "$YI_HACK_PREFIX/bin/tts" ]; then
    link tts "$HTTP_BASE/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0"
fi
if [ -x "$YI_HACK_PREFIX/bin/speaker" ]; then
    link audio_library "$HTTP_BASE/cgi-bin/audio_library.sh?action=list"
fi
printf '"audio_page":"%s/?page=audio"\n}\n' "$HTTP_BASE"
