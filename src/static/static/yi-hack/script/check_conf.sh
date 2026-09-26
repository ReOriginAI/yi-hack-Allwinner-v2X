#!/bin/sh

SYSTEM_CONF_FILE="/tmp/sd/yi-hack/etc/system.conf"
CAMERA_CONF_FILE="/tmp/sd/yi-hack/etc/camera.conf"
MQTTV4_CONF_FILE="/tmp/sd/yi-hack/etc/mqttv4.conf"

PARMS1="
HTTPD=yes
TELNETD=yes
SSHD=yes
FTPD=yes
BUSYBOX_FTPD=no
MDNSD=yes
DISABLE_CLOUD=yes
REC_WITHOUT_CLOUD=no
MQTT=no
RTSP=yes
RTSP_ALT=standard
RTSP_STREAM=high
RTSP_AUDIO=aac
RTSP_BACKCHANNEL=NONE
RTSP_STI=yes
SPEAKER_AUDIO=yes
SNAPSHOT=yes
SNAPSHOT_VIDEO=no
SNAPSHOT_LOW=no
TIMELAPSE=no
TIMELAPSE_FTP=no
TIMELAPSE_FTP_SAME_NAME=no
TIMELAPSE_DT=60
TIMELAPSE_VDT=
ONVIF=yes
ONVIF_WSDD=yes
ONVIF_PROFILE=high
ONVIF_NETIF=wlan0
ONVIF_WM_SNAPSHOT=yes
ONVIF_AUDIO_BC=NONE
ONVIF_ENABLE_MEDIA2=no
ONVIF_FAULT_IF_UNKNOWN=no
ONVIF_FAULT_IF_SET=no
ONVIF_SYNOLOGY_NVR=no
TIME_OSD=no
NTPD=yes
NTP_SERVER=pool.ntp.org
PROXYCHAINSNG=no
SWAP_FILE=yes
SWAP_SWAPPINESS=15
WIFI_MAINTENANCE_ENABLED=no
WIFI_MAINTENANCE_SSID=
WIFI_MAINTENANCE_PASSWORD=
WIFI_MAINTENANCE_GRACE=180
RTSP_PORT=554
HTTPD_PORT=80
USERNAME=
PASSWORD=
TIMEZONE=
EVENTS_TIME=autodetect
FREE_SPACE=0
FTP_UPLOAD=no
FTP_HOST=
FTP_DIR=
FTP_DIR_TREE=no
FTP_USERNAME=
FTP_PASSWORD=
FTP_FILE_DELETE_AFTER_UPLOAD=yes
SSH_PASSWORD=
CRONTAB=
DEBUG_LOG=no
STATIC_IP=
STATIC_MASK=
STATIC_GW=
STATIC_DNS1=
STATIC_DNS2=
"

PARMS2="
SWITCH_ON=yes
SAVE_VIDEO_ON_MOTION=yes
MOTION_DETECTION=no
MOTION_HUMAN_ONLY=no
MOTION_FOLIAGE_FILTER=no
MOTION_SENSITIVITY=5
SOUND_DETECTION=no
SOUND_SENSITIVITY=80
LED=no
ROTATE=no
IR=yes
CRUISE=no"

PARMS3="
MQTT_IP=0.0.0.0
MQTT_PORT=1883
MQTT_TLS=0
MQTT_CLIENT_ID=yi-cam
MQTT_USER=
MQTT_PASSWORD=
MQTT_PREFIX=yicam
TOPIC_BIRTH_WILL=status
TOPIC_MOTION=motion_detection
TOPIC_MOTION_IMAGE=motion_detection_image
MOTION_IMAGE_DELAY=0.5
TOPIC_MOTION_FILES=motion_files
TOPIC_SOUND_DETECTION=sound_detection
BIRTH_MSG=online
WILL_MSG=offline
MOTION_START_MSG=motion_start
MOTION_STOP_MSG=motion_stop
AI_HUMAN_DETECTION_MSG=human
AI_VEHICLE_DETECTION_MSG=vehicle
AI_ANIMAL_DETECTION_MSG=animal
BABY_CRYING_MSG=crying
SOUND_DETECTION_MSG=sound_detected
MQTT_KEEPALIVE=120
MQTT_QOS=1
MQTT_RETAIN_BIRTH_WILL=1
MQTT_RETAIN_MOTION=0
MQTT_RETAIN_MOTION_IMAGE=0
MQTT_RETAIN_MOTION_FILES=0
MQTT_RETAIN_SOUND_DETECTION=0"

if [ ! -f $SYSTEM_CONF_FILE ]; then
    touch $SYSTEM_CONF_FILE
fi

# Migrate the old ONVIF-owned backchannel setting once. Backchannel is an RTSP
# transport capability and must remain usable even when the ONVIF service is off.
if ! grep -q '^RTSP_BACKCHANNEL=' "$SYSTEM_CONF_FILE" 2>/dev/null; then
    LEGACY_BACKCHANNEL=$(grep '^ONVIF_AUDIO_BC=' "$SYSTEM_CONF_FILE" 2>/dev/null | cut -d= -f2-)
    case "$LEGACY_BACKCHANNEL" in
        G711|g711) echo 'RTSP_BACKCHANNEL=G711' >> "$SYSTEM_CONF_FILE" ;;
        *)         echo 'RTSP_BACKCHANNEL=NONE' >> "$SYSTEM_CONF_FILE" ;;
    esac
fi

for i in $PARMS1
do
    if [ ! -z "$i" ]; then
        PAR=$(echo "$i" | cut -d= -f1)
        MATCH=$(cat $SYSTEM_CONF_FILE | grep ^$PAR=)
        if [ -z "$MATCH" ]; then
            echo "$i" >> $SYSTEM_CONF_FILE
        fi
    fi
done

# RTSP_BACKCHANNEL is the public/source-of-truth setting. Keep the historical
# ONVIF_AUDIO_BC key only as a compatibility mirror for service.sh and ONVIF
# capability advertisement; ONVIF itself may be disabled without disabling the
# RTSP/go2rtc speaker backchannel.
RTSP_BACKCHANNEL=$(grep '^RTSP_BACKCHANNEL=' "$SYSTEM_CONF_FILE" 2>/dev/null | cut -d= -f2-)
case "$RTSP_BACKCHANNEL" in
    G711|g711) RTSP_BACKCHANNEL=G711 ;;
    *)         RTSP_BACKCHANNEL=NONE ;;
esac
if grep -q '^RTSP_BACKCHANNEL=' "$SYSTEM_CONF_FILE" 2>/dev/null; then
    sed -i "s/^RTSP_BACKCHANNEL=.*/RTSP_BACKCHANNEL=$RTSP_BACKCHANNEL/" "$SYSTEM_CONF_FILE"
else
    echo "RTSP_BACKCHANNEL=$RTSP_BACKCHANNEL" >> "$SYSTEM_CONF_FILE"
fi
if grep -q '^ONVIF_AUDIO_BC=' "$SYSTEM_CONF_FILE" 2>/dev/null; then
    sed -i "s/^ONVIF_AUDIO_BC=.*/ONVIF_AUDIO_BC=$RTSP_BACKCHANNEL/" "$SYSTEM_CONF_FILE"
else
    echo "ONVIF_AUDIO_BC=$RTSP_BACKCHANNEL" >> "$SYSTEM_CONF_FILE"
fi

# Local-only build: Yi vendor cloud is intentionally and permanently disabled.
if grep -q '^DISABLE_CLOUD=' "$SYSTEM_CONF_FILE" 2>/dev/null; then
    sed -i 's/^DISABLE_CLOUD=.*/DISABLE_CLOUD=yes/' "$SYSTEM_CONF_FILE"
else
    echo 'DISABLE_CLOUD=yes' >> "$SYSTEM_CONF_FILE"
fi

if [ ! -f $CAMERA_CONF_FILE ]; then
    touch $CAMERA_CONF_FILE
fi
for i in $PARMS2
do
    if [ ! -z "$i" ]; then
        PAR=$(echo "$i" | cut -d= -f1)
        MATCH=$(cat $CAMERA_CONF_FILE | grep ^$PAR=)
        if [ -z "$MATCH" ]; then
            echo "$i" >> $CAMERA_CONF_FILE
        fi
    fi
done

# Remove deprecated YI/Pilot motion controls from upgraded configurations.
for PAR in SENSITIVITY AI_HUMAN_DETECTION AI_VEHICLE_DETECTION AI_ANIMAL_DETECTION FACE_DETECTION MOTION_TRACKING
do
    sed -i "/^${PAR}=/d" "$CAMERA_CONF_FILE"
done

if [ ! -f $MQTTV4_CONF_FILE ]; then
    touch $MQTTV4_CONF_FILE
fi
for i in $PARMS3
do
    if [ ! -z "$i" ]; then
        PAR=$(echo "$i" | cut -d= -f1)
        MATCH=$(cat $MQTTV4_CONF_FILE | grep ^$PAR=)
        if [ -z "$MATCH" ]; then
            echo "$i" >> $MQTTV4_CONF_FILE
        fi
    fi
done

# Both supported camera families use a small, hash-guarded rmm patch tailored
# to their exact known vendor binary. The flash copy is never modified: a
# verified patched copy is generated on SD and bind-mounted for this boot.
# Unknown rmm builds are refused and safely fall back to the vendor binary.
RMM_MODEL=$(cat /tmp/sd/yi-hack/model_suffix 2>/dev/null)
case "$RMM_MODEL" in
    y623|y28ga)
        RMM_PATCH_LOG=/tmp/rmm_patch.log
        rm -f "$RMM_PATCH_LOG"
        RMM_PATCHED=$(MODEL_SUFFIX="$RMM_MODEL" sh /tmp/sd/yi-hack/script/prepare_rmm.sh 2>"$RMM_PATCH_LOG")
        if [ $? -eq 0 ] && [ -n "$RMM_PATCHED" ] && [ -x "$RMM_PATCHED" ]; then
            if ! grep -q ' /home/app/rmm ' /proc/mounts 2>/dev/null; then
                if ! mount --bind "$RMM_PATCHED" /home/app/rmm; then
                    echo "check_conf: failed to bind patched $RMM_MODEL rmm" >> "$RMM_PATCH_LOG"
                fi
            fi
        else
            echo "check_conf: using stock $RMM_MODEL rmm" >> "$RMM_PATCH_LOG"
        fi
        ;;
esac
# y28ga vendor mp4record normally muxes main, sub, fast, and AAC tracks. The
# audited main-only patch changes only the muxer video-track count (3 -> 1), so
# VENC1 may remain paused during high-only RTSP while VI2/IVA motion stays live.
# Unknown recorder builds fail closed: stock mp4record remains in place and
# rtsp_stream_venc.sh will keep VENC1 enabled whenever recording is needed.
if [ "$RMM_MODEL" = "y28ga" ]; then
    MP4_PATCH_LOG=/tmp/mp4record_patch.log
    rm -f "$MP4_PATCH_LOG"
    MP4_PATCHED=$(MODEL_SUFFIX="$RMM_MODEL" sh /tmp/sd/yi-hack/script/prepare_mp4record.sh 2>"$MP4_PATCH_LOG")
    if [ $? -eq 0 ] && [ -n "$MP4_PATCHED" ] && [ -x "$MP4_PATCHED" ]; then
        if ! grep -q ' /home/app/mp4record ' /proc/mounts 2>/dev/null; then
            if ! mount --bind "$MP4_PATCHED" /home/app/mp4record; then
                echo "check_conf: failed to bind patched y28ga mp4record" >> "$MP4_PATCH_LOG"
            fi
        fi
    else
        echo "check_conf: using stock y28ga mp4record" >> "$MP4_PATCH_LOG"
    fi
fi
