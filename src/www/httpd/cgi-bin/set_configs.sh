#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}

sedencode(){
#  echo -e "$(sed 's/\\/\\\\\\/g;s/\&/\\\&/g;s/\//\\\//g;')"
  echo "$(sed 's/\\/\\\\/g;s/\"/\\\"/g;s/\&/\\\&/g;s/\//\\\//g;')"
}

removedoublequotes(){
  echo "$(sed 's/^"//g;s/"$//g')"
}

validateDT()
{
    for x in 1 2 3 4 5 6 10 15 20 30 60 120 180 240 360 1440; do
        if [ "$x" == "$1" ]; then
            return 0
        fi
    done
    if [ "${1:0:5}" == "1440+" ]; then
        OFF="${1:5:10}"
        if [ ! -z $OFF ]; then
            case $OFF in
                ''|*[!0-9]* )
                    OFF_OK=0;;
                * )
                    OFF_OK=1;;
            esac
            if [ "$OFF_OK" == "1" ] && [ $OFF -le 1440 ]; then
                return 0
            fi
        fi
    fi

    return 1
}

get_conf_type()
{
    CONF="$(echo $QUERY_STRING | cut -d'=' -f1)"
    VAL="$(echo $QUERY_STRING | cut -d'=' -f2)"

    if [ $CONF == "conf" ] ; then
        echo $VAL
    fi
}

. $YI_HACK_PREFIX/www/cgi-bin/validate.sh

if ! $(validateQueryString $QUERY_STRING); then
    printf "Content-type: application/json\r\n\r\n"
    printf "{\n"
    printf "\"%s\":\"%s\"\\n" "error" "true"
    printf "}"
    exit
fi

CONF_TYPE="$(get_conf_type)"
CONF_FILE=""

if [ "$CONF_TYPE" == "mqtt" ] ; then
    CONF_FILE="$YI_HACK_PREFIX/etc/mqttv4.conf"
else
    CONF_FILE="$YI_HACK_PREFIX/etc/$CONF_TYPE.conf"
fi

OLD_RTSP_STREAM=""
OLD_RTSP_BACKCHANNEL=""
if [ "$CONF_TYPE" == "system" ]; then
    OLD_RTSP_STREAM=$(grep '^RTSP_STREAM=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
    OLD_RTSP_BACKCHANNEL=$(grep '^RTSP_BACKCHANNEL=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
fi

read -r POST_DATA
# Validate json
VALID=$(echo "$POST_DATA" | jq -e . >/dev/null 2>&1; echo $?)
if [ "$VALID" != "0" ]; then
    printf "Content-type: application/json\r\n\r\n"
    printf "{\n"
    printf "\"%s\":\"%s\"\\n" "error" "true"
    printf "}"
    exit
fi
# Change temporarily \n with \t (2 bytes)
POST_DATA="${POST_DATA//\\n/\\t}"
IFS=$(echo -en "\n\b")
ROWS=$(echo "$POST_DATA" | jq -r '. | keys[] as $k | "\($k)=\(.[$k])"')
for ROW in $ROWS; do
    ROW=$(echo "$ROW" | removedoublequotes)
    KEY=$(echo "$ROW" | cut -d'=' -f1)
    # Change back tab with \n
    VALUE=$(echo "$ROW" | cut -d'=' -f2 | sed 's/\t/\\n/g')

    if ! $(validateKey $KEY); then
        printf "Content-type: application/json\r\n\r\n"
        printf "{\n"
        printf "\"%s\":\"%s\"\\n" "error" "true"
        printf "}"
        exit
    fi

    if [ "$KEY" == "HOSTNAME" ] ; then
        if [ -z $VALUE ] ; then

            # Use 2 last MAC address numbers to set a different hostname
            MAC=$(cat /sys/class/net/wlan0/address|cut -d ':' -f 5,6|sed 's/://g')
            if [ "$MAC" != "" ]; then
                hostname yi-$MAC
            else
                hostname yi-hack
            fi
            hostname > $YI_HACK_PREFIX/etc/hostname
        else
            hostname $VALUE
            echo "$VALUE" > $YI_HACK_PREFIX/etc/hostname
        fi
    elif [ "$KEY" == "MOTION_IMAGE_DELAY" ] ; then
        if $(validateNumber $VALUE); then
            VALUE=$(echo $VALUE | sed 's/,/./g')
            VAR=$(awk 'BEGIN{ print "'$VALUE'"<="'5.0'" }')
            if [ "$VAR" == "1" ]; then
                sed -i "s/^\(${KEY}\s*=\s*\).*$/\1${VALUE}/" $CONF_FILE
            fi
        fi
    elif [ "$KEY" == "PROXYCHAINS_SERVERS" ] ; then
        VALUE=$(echo $VALUE | sed 's/^\"//g')
        VALUE=$(echo $VALUE | sed 's/\"$//g')
        VALUE=$(echo $VALUE | sed 's/;/\\n/g')
        cat $CONF_FILE.template > $CONF_FILE
        echo -e $VALUE >> $CONF_FILE
    elif [ "$KEY" == "TIMELAPSE_DT" ] ; then
        if $(validateDT $VALUE); then
            sed -i "s/^\(${KEY}\s*=\s*\).*$/\1${VALUE}/" $CONF_FILE
        fi
    else
        KEY=$(echo "$KEY" | sedencode)
        VALUE=$(echo "$VALUE" | sedencode)
        sed -i "s/^\(${KEY}\s*=\s*\).*$/\1${VALUE}/" $CONF_FILE
    fi

done

# System settings that can safely be applied immediately are normalized here.
# RTSP_BACKCHANNEL is the public/source-of-truth setting; ONVIF_AUDIO_BC is kept
# only as the compatibility mirror consumed by service.sh and ONVIF advertising.
if [ "$CONF_TYPE" == "system" ]; then
    NEW_RTSP_STREAM=$(grep '^RTSP_STREAM=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
    NEW_RTSP_BACKCHANNEL=$(grep '^RTSP_BACKCHANNEL=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)

    case "$NEW_RTSP_BACKCHANNEL" in
        G711|g711) NEW_RTSP_BACKCHANNEL=G711 ;;
        *)         NEW_RTSP_BACKCHANNEL=NONE ;;
    esac
    if grep -q '^RTSP_BACKCHANNEL=' "$CONF_FILE" 2>/dev/null; then
        sed -i "s/^RTSP_BACKCHANNEL=.*/RTSP_BACKCHANNEL=$NEW_RTSP_BACKCHANNEL/" "$CONF_FILE"
    else
        echo "RTSP_BACKCHANNEL=$NEW_RTSP_BACKCHANNEL" >> "$CONF_FILE"
    fi
    if grep -q '^ONVIF_AUDIO_BC=' "$CONF_FILE" 2>/dev/null; then
        sed -i "s/^ONVIF_AUDIO_BC=.*/ONVIF_AUDIO_BC=$NEW_RTSP_BACKCHANNEL/" "$CONF_FILE"
    else
        echo "ONVIF_AUDIO_BC=$NEW_RTSP_BACKCHANNEL" >> "$CONF_FILE"
    fi

    RTSP_STREAM_CHANGED=no
    RTSP_BACKCHANNEL_CHANGED=no
    if [ -n "$NEW_RTSP_STREAM" ] && [ "$NEW_RTSP_STREAM" != "$OLD_RTSP_STREAM" ]; then
        RTSP_STREAM_CHANGED=yes
    fi
    if [ "$NEW_RTSP_BACKCHANNEL" != "$OLD_RTSP_BACKCHANNEL" ]; then
        RTSP_BACKCHANNEL_CHANGED=yes
    fi

    # RTSP stream selection and speaker backchannel both affect the generated
    # server configuration, so rebuild RTSP once if either changed.
    if [ "$RTSP_STREAM_CHANGED" == "yes" ] || [ "$RTSP_BACKCHANNEL_CHANGED" == "yes" ]; then
        RTSP_ENABLED=$(grep '^RTSP=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
        if [ "$RTSP_ENABLED" == "yes" ]; then
            "$YI_HACK_PREFIX/script/service.sh" rtsp stop >/dev/null 2>&1
            "$YI_HACK_PREFIX/script/service.sh" rtsp start >/dev/null 2>&1
        elif [ "$RTSP_STREAM_CHANGED" == "yes" ]; then
            # With RTSP disabled, only the encoder state itself needs updating.
            "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" "$NEW_RTSP_STREAM" >/dev/null 2>&1 || true
        fi
    fi

    # ONVIF advertises the same backchannel capability, so refresh its generated
    # profile immediately when the backchannel mode changes.
    if [ "$RTSP_BACKCHANNEL_CHANGED" == "yes" ]; then
        ONVIF_ENABLED=$(grep '^ONVIF=' "$CONF_FILE" 2>/dev/null | cut -d= -f2-)
        if [ "$ONVIF_ENABLED" == "yes" ]; then
            "$YI_HACK_PREFIX/script/service.sh" onvif stop >/dev/null 2>&1
            "$YI_HACK_PREFIX/script/service.sh" onvif start >/dev/null 2>&1
        fi
    fi
fi

# Yeah, it's pretty ugly.

printf "Content-type: application/json\r\n\r\n"

printf "{\n"
printf "\"%s\":\"%s\"\\n" "error" "false"
printf "}"
