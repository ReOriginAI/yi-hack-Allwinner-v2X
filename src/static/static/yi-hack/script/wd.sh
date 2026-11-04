#!/tmp/sd/yi-hack/bin/busybox ash

CONF_FILE="etc/system.conf"
CAMERA_CONF_FILE="etc/camera.conf"

YI_HACK_PREFIX="/tmp/sd/yi-hack"
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
MODEL_SUFFIX=$(cat /tmp/sd/yi-hack/model_suffix)

START_STOP_SCRIPT=$YI_HACK_PREFIX/script/service.sh

# Ownership is released by the kernel even after SIGKILL/OOM.
yi_lock watchdog
LOCK_STATUS=$?
[ "$LOCK_STATUS" -ne 75 ] || exit 0
[ "$LOCK_STATUS" -eq 0 ] || exit "$LOCK_STATUS"

#LOG_FILE="/tmp/sd/wd.log"
LOG_FILE="/dev/null"
LOGWIFI_FILE="/tmp/sd/hack_wififailsafe.log"

COUNTER=0
COUNTER_LIMIT=10
INTERVAL=10
WIFI_FAILSAFE_COUNTER=0
WIFI_FAILSAFE_STARTED=0
WIFI_MAINTENANCE_FAILSAFE_COUNTER=0

# Kernel OOM recovery policy. The kernel chooses victims; this watchdog only
# restarts configured services after enough memory has returned.
OOM_POLICY="$YI_HACK_PREFIX/script/oom_policy.sh"
RESTART_MIN_MEM_KB=4096
OOM_POLICY_EVERY=6
AUX_CHECK_EVERY=3
OOM_POLICY_COUNTER=0
AUX_COUNTER=0

mem_available_kb()
{
    VALUE=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    case "$VALUE" in ''|*[!0-9]*) VALUE=0 ;; esac
    echo "$VALUE"
}

restart_memory_ok()
{
    MEM=$(mem_available_kb)
    [ "$MEM" -ge "$RESTART_MIN_MEM_KB" ]
}

refresh_oom_policy()
{
    [ -x "$OOM_POLICY" ] && "$OOM_POLICY" >/dev/null 2>&1
}

process_count()
{
    ps | grep "$1" | grep -v grep | grep -c ^
}

get_camera_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CAMERA_CONF_FILE | cut -d "=" -f2-
}

get_config()
{
    key=$1
    grep -w $1 $YI_HACK_PREFIX/$CONF_FILE | cut -d "=" -f2-
}

restart_rtsp()
{
    # Avoid an OOM restart loop. The killed service has to leave at least 4 MiB
    # available before we recreate the RTSP stack.
    restart_memory_ok || return 1
    $START_STOP_SCRIPT rtsp start >/dev/null 2>&1
    refresh_oom_policy
}

check_rtsp()
{
    if [[ $(get_camera_config SWITCH_ON) == "yes" ]] ; then
        #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking RTSP process..." >> $LOG_FILE
        LISTEN=`$YI_HACK_PREFIX/bin/netstat -an 2>&1 | grep ":$RTSP_PORT_NUMBER " | grep LISTEN | grep -c ^`
        SOCKET=`$YI_HACK_PREFIX/bin/netstat -an 2>&1 | grep ":$RTSP_PORT_NUMBER " | grep ESTABLISHED | grep -c ^`
        CPU=`top -b -n 2 -d 1 | grep rRTSPServer | grep -v grep | tail -n 1 | awk '{print $8}'`

        if [ $LISTEN -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
            killall -q rRTSPServer
            sleep 1
            restart_rtsp
        fi
        if [ "$CPU" == "" ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes, restarting..." >> $LOG_FILE
            killall -q rRTSPServer
            sleep 1
            restart_rtsp
            COUNTER=0
        fi
        if [ $SOCKET -gt 0 ]; then
            if [ "$CPU" == "0.0" ]; then
                COUNTER=$((COUNTER+1))
                echo "$(date +'%Y-%m-%d %H:%M:%S') - Detected possible locked process ($COUNTER)" >> $LOG_FILE
                if [ $COUNTER -ge $COUNTER_LIMIT ]; then
                    echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
                    killall -q rRTSPServer
                    sleep 1
                    restart_rtsp
                    COUNTER=0
                fi
            else
                COUNTER=0
            fi
        fi
    else
        echo "Camera is swiched off no rtsp restart needed" >> $LOG_FILE
    fi
}

check_rtsp_alt()
{
    if [[ $(get_camera_config SWITCH_ON) == "yes" ]] ; then
        #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking RTSP process..." >> $LOG_FILE
        LISTEN=`$YI_HACK_PREFIX/bin/netstat -an 2>&1 | grep ":$RTSP_PORT_NUMBER " | grep LISTEN | grep -c ^`
        CPU1=`top -b -n 2 -d 1 | grep h264grabber | grep -v grep | tail -n 1 | awk '{print $8}'`
        CPU2=`top -b -n 2 -d 1 | grep rtsp_server_yi | grep -v grep | tail -n 1 | awk '{print $8}'`

        if [ $LISTEN -eq 0 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting rtsp process" >> $LOG_FILE
            killall -q rtsp_server_yi
            killall -q h264grabber
            sleep 1
            restart_rtsp
        fi
        if [ "$CPU1" == "" ] || [ "$CPU2" == "" ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - No running processes, restarting..." >> $LOG_FILE
            killall -q rtsp_server_yi
            killall -q h264grabber
            sleep 1
            restart_rtsp
            COUNTER=0
        fi
    else
        echo "Camera is switched off, rtsp restart not needed" >> $LOG_FILE
    fi
}

check_rmm()
{
    #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking rmm process..." >> $LOG_FILE

    # Method 1: Basic ps check (most reliable, avoids ps ww parsing issues)
    PS_BASIC=`ps | grep -v grep | grep "./rmm" | grep -c ^`
    if [ $PS_BASIC -gt 0 ]; then
        # Reset failure counter on successful detection
        rm -f /tmp/rmm_fail_count 2>/dev/null
        return 0
    fi

    # Method 2: Extended ps as fallback (original method)
    PS_WW=`ps ww | grep rmm | grep -v grep | grep -c ^`
    if [ $PS_WW -gt 0 ]; then
        # Reset failure counter on successful detection  
        rm -f /tmp/rmm_fail_count 2>/dev/null
        return 0
    fi

    # Failure handling with counter to prevent immediate reboots
    echo "$(date +'%Y-%m-%d %H:%M:%S') - rmm detection failed" >> $LOG_FILE

    # Read current failure count
    if [ -f /tmp/rmm_fail_count ]; then
        FAIL_COUNT=$(cat /tmp/rmm_fail_count)
    else
        FAIL_COUNT=0
    fi

    # Increment failure count
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo $FAIL_COUNT > /tmp/rmm_fail_count

    echo "$(date +'%Y-%m-%d %H:%M:%S') - rmm failure count: $FAIL_COUNT/5" >> $LOG_FILE

    # Only reboot after 5 consecutive failures (~50 seconds with 10s interval)
    if [ $FAIL_COUNT -ge 5 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - rmm failed 5 times consecutively, rebooting..." >> $LOG_FILE
        reboot
    fi
}

check_motion()
{
    case "$MODEL_SUFFIX" in
        y623|y28ga) ;;
        *) return 0 ;;
    esac
    [ "$(get_camera_config MOTION_DETECTION)" = "yes" ] || return 0

    STATUS=$("$YI_HACK_PREFIX/script/motion_service.sh" status 2>/dev/null)
    if [ "$STATUS" != "started" ] && restart_memory_ok; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting local motion service (model=$MODEL_SUFFIX status=$STATUS)" >> $LOG_FILE
        "$YI_HACK_PREFIX/script/motion_service.sh" restart >/dev/null 2>&1
        refresh_oom_policy
    fi
}

check_mqtt()
{
    if [ -f "$YI_HACK_PREFIX/flash-core" ]; then
        [ -x "$YI_HACK_PREFIX/bin/mqttv4" ] && [ -x "$YI_HACK_PREFIX/bin/mqtt-config" ] || return 0
    fi
    # Never resurrect MQTT when it is disabled. This was the source of the
    # stray mqttv4 instances observed on y623.
    if [ "$(get_config MQTT)" != "yes" ]; then
        if [ "$(process_count mqttv4)" -gt 0 ]; then
            $START_STOP_SCRIPT mqtt stop >/dev/null 2>&1
        fi
        if [ "$(process_count mqtt-config)" -gt 0 ]; then
            $START_STOP_SCRIPT mqtt-config stop >/dev/null 2>&1
        fi
        return 0
    fi

    if [ "$(process_count mqttv4)" -eq 0 ] && restart_memory_ok; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting mqttv4" >> $LOG_FILE
        $START_STOP_SCRIPT mqtt start >/dev/null 2>&1
        refresh_oom_policy
        return 0
    fi

    if [ "$(process_count mqtt-config)" -eq 0 ] && restart_memory_ok; then
        $START_STOP_SCRIPT mqtt-config start >/dev/null 2>&1
        refresh_oom_policy
    fi
}

check_aux_services()
{
    # Restart at most one configured service per pass. This deliberately
    # serializes recovery after an OOM kill instead of recreating every victim
    # at once and immediately forcing another OOM cycle.
    restart_memory_ok || return 0

    if [ "$(get_config HTTPD)" = "yes" ] && [ "$(process_count httpd)" -eq 0 ]; then
        PORT=$(get_config HTTPD_PORT)
        case "$PORT" in ''|*[!0-9]*) PORT=80 ;; esac
        httpd -p "$PORT" -h "$YI_HACK_PREFIX/www/" -c /tmp/httpd.conf
        refresh_oom_policy
        return 0
    fi

    if [ "$(get_config REC_WITHOUT_CLOUD)" = "yes" ] && [ "$(process_count mp4record)" -eq 0 ] &&
       ( . "$YI_HACK_PREFIX/script/storage.sh" && sd_present ); then
        $START_STOP_SCRIPT mp4record start >/dev/null 2>&1
        refresh_oom_policy
        return 0
    fi

    if [ "$(get_config REC_WITHOUT_CLOUD)" = yes ] ||
       [ "$(get_camera_config MOTION_DETECTION)" = yes ] ||
       [ "$(get_config ONVIF)" = yes ] || [ "$(process_count mp4record)" -gt 0 ]; then
        if [ "$("$YI_HACK_PREFIX/script/motion_service.sh" events-status)" != started ]; then
            # Restore only the shared collector. Keep the current recording and
            # detector running, including when ONVIF is disabled.
            "$YI_HACK_PREFIX/script/motion_service.sh" events >/dev/null 2>&1
            refresh_oom_policy
            return 0
        fi
    fi

    if [ "$(get_config ONVIF)" = "yes" ]; then
        if [ "$(process_count onvif_notify_server)" -eq 0 ]; then
            # ONVIF notifications share the collector with local recordings.
            $START_STOP_SCRIPT onvif stop >/dev/null 2>&1
            $START_STOP_SCRIPT onvif start >/dev/null 2>&1
            refresh_oom_policy
            return 0
        fi
        if [ "$(get_config ONVIF_WSDD)" = "yes" ] && [ "$(process_count wsd_simple_server)" -eq 0 ]; then
            $START_STOP_SCRIPT wsdd start >/dev/null 2>&1
            refresh_oom_policy
            return 0
        fi
    fi

    if [ "$(get_config MDNSD)" = "yes" ] && [ "$(process_count mdnsd)" -eq 0 ] && [ -d /tmp/mdns.d ]; then
        "$YI_HACK_PREFIX/sbin/mdnsd" /tmp/mdns.d >/dev/null 2>&1
        refresh_oom_policy
        return 0
    fi

    if [ "$(get_config NTPD)" = "yes" ] && [ "$(process_count ntpd)" -eq 0 ]; then
        SERVER=$(get_config NTP_SERVER)
        [ -n "$SERVER" ] && "$YI_HACK_PREFIX/usr/sbin/ntpd" -p "$SERVER" >/dev/null 2>&1 &
        refresh_oom_policy
        return 0
    fi

    if [ "$(get_config FTPD)" = "yes" ]; then
        if [ "$(get_config BUSYBOX_FTPD)" = "yes" ] || [ ! -x "$YI_HACK_PREFIX/sbin/pure-ftpd" ]; then
            FTP_COUNT=$(process_count tcpsvd)
        else
            FTP_COUNT=$(process_count pure-ftpd)
        fi
        if [ "$FTP_COUNT" -eq 0 ]; then
            $START_STOP_SCRIPT ftpd start >/dev/null 2>&1
            refresh_oom_policy
            return 0
        fi
    fi

    if [ "$(process_count crond)" -eq 0 ]; then
        "$YI_HACK_PREFIX/usr/sbin/crond" -c /var/spool/cron/crontabs/ >/dev/null 2>&1
        refresh_oom_policy
        return 0
    fi
}

soft_wifi_reconnect()
{
    # Bounded private worker: association or a DHCP hook cannot stop the
    # watchdog from checking media or escalating repeated connection failures.
    "$YI_HACK_PREFIX/bin/service_guard" 35 "$YI_HACK_PREFIX/script/wifi_recovery.sh" >/dev/null 2>&1 &

}

publish_reset_ready()
{
    if [ "$(get_config WIFI_RESET_HOTSPOT)" = yes ] && [ ! -e /tmp/yi-reset-hotspot.ready ]; then
        (umask 077; : > /tmp/yi-reset-hotspot.ready)
    fi
    return 0
}

wifi_station_connected()
{
    EXPECTED_SSID=$1
    [ -n "$EXPECTED_SSID" ] || return 1
    if [ -x /home/base/tools/wpa_cli ]; then
        WPA_OUTPUT=$("$YI_HACK_PREFIX/bin/busybox" timeout -s KILL 2 /home/base/tools/wpa_cli -i wlan0 status 2>/dev/null)
        if [ $? -eq 0 ] && printf '%s\n' "$WPA_OUTPUT" | grep -q '^wpa_state='; then
            # An old DHCP address is not evidence of a live association.
            printf '%s\n' "$WPA_OUTPUT" | grep -qx 'wpa_state=COMPLETED' || return 1
        fi
    fi
    "$YI_HACK_PREFIX/bin/busybox" timeout -s KILL 2 ifconfig wlan0 2>/dev/null | grep -q 'inet addr:' || return 1
    CURRENT_SSID=$("$YI_HACK_PREFIX/bin/busybox" timeout -s KILL 2 iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p')
    [ "$CURRENT_SSID" = "$EXPECTED_SSID" ] || return 1
    if [ -f /sys/class/net/wlan0/carrier ]; then
        [ "$(cat /sys/class/net/wlan0/carrier 2>/dev/null)" = 1 ] || return 1
    fi
    return 0
}

check_wifi()
{
    # Hotspot transitions and queued manual/button requests own the radio.
    # Workers recheck this after acquiring wifi-recovery, closing the race
    # between these watchdog observations and actually changing the interface.
    case "$(cat /tmp/yi-hotspot/state 2>/dev/null)" in
        starting|active|stopping) WIFI_FAILSAFE_STARTED=0; WIFI_FAILSAFE_COUNTER=0; return 0 ;;
    esac
    [ ! -s /tmp/yi-hotspot.request ] && [ ! -s /tmp/yi-hotspot/pending ] || return 0
    MAINT_STATE=$(cat /tmp/wifi_maintenance_active 2>/dev/null)
    case "$MAINT_STATE" in
        maintenance_pending|maintenance)
            if wifi_station_connected "$(get_config WIFI_MAINTENANCE_SSID)"; then
                echo maintenance > /tmp/wifi_maintenance_active
                WIFI_MAINTENANCE_FAILSAFE_COUNTER=0
                return 0
            fi
            # Saving a new mode must not strand an existing maintenance session:
            # keep it while connected, then use the newly selected recovery.
            if [ "$(get_config WIFI_RECOVERY_MODE)" != maintenance ]; then
                "$YI_HACK_PREFIX/bin/service_guard" 45 "$YI_HACK_PREFIX/script/hotspot.sh" recover >/dev/null 2>&1 &
                return 0
            fi
            WIFI_MAINTENANCE_FAILSAFE_COUNTER=$((WIFI_MAINTENANCE_FAILSAFE_COUNTER + 1))
            if [ "$WIFI_MAINTENANCE_FAILSAFE_COUNTER" -ge 6 ]; then
                # Recheck ownership/state inside the worker before rebooting.
                "$YI_HACK_PREFIX/bin/service_guard" 35 "$YI_HACK_PREFIX/script/wifi_failover.sh" reboot >/dev/null 2>&1 &
            else
                "$YI_HACK_PREFIX/bin/service_guard" 35 "$YI_HACK_PREFIX/script/wifi_failover.sh" >/dev/null 2>&1 &
            fi
            return 0 ;;
    esac

    PRIMARY_SSID=$(dd bs=1 skip=28 count=64 if=/dev/mtdblock7 2>/dev/null | tr -d "\000\r")
    if wifi_station_connected "$PRIMARY_SSID"; then
        WIFI_FAILSAFE_COUNTER=0
        WIFI_FAILSAFE_STARTED=0
        return 0
    fi

    WIFI_FAILSAFE_COUNTER=$((WIFI_FAILSAFE_COUNTER + 1))
    WIFI_GRACE=$(get_config WIFI_MAINTENANCE_GRACE)
    case "$WIFI_GRACE" in ''|*[!0-9]*) WIFI_GRACE=180 ;; esac
    [ "$WIFI_GRACE" -ge 30 ] 2>/dev/null || WIFI_GRACE=30
    [ "$WIFI_GRACE" -le 3600 ] 2>/dev/null || WIFI_GRACE=3600
    WIFI_NOW=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    case "$WIFI_NOW" in ''|*[!0-9]*) WIFI_NOW=$((WIFI_FAILSAFE_COUNTER * INTERVAL)) ;; esac
    if [ "$WIFI_FAILSAFE_STARTED" -eq 0 ]; then WIFI_FAILSAFE_STARTED=$WIFI_NOW; fi
    WIFI_LOST_SECONDS=$((WIFI_NOW - WIFI_FAILSAFE_STARTED))
    if [ "$WIFI_LOST_SECONDS" -ge "$WIFI_GRACE" ] && [ "$WIFI_FAILSAFE_COUNTER" -ge 6 ]; then
        case "$(get_config WIFI_RECOVERY_MODE)" in
            maintenance)
                "$YI_HACK_PREFIX/bin/service_guard" 35 "$YI_HACK_PREFIX/script/wifi_failover.sh" >/dev/null 2>&1 & ;;
            *)
                # The hotspot worker already owns/rechecks the same radio lock.
                # Do not hold it here or call apply through a nested lock.
                "$YI_HACK_PREFIX/bin/service_guard" 45 "$YI_HACK_PREFIX/script/hotspot.sh" recover >/dev/null 2>&1 & ;;
        esac
    else
        soft_wifi_reconnect
    fi
}

case $(get_config RTSP_PORT) in
    ''|*[!0-9]*) RTSP_PORT=554 ;;
    *) RTSP_PORT=$(get_config RTSP_PORT) ;;
esac
RTSP_PORT_NUMBER=$RTSP_PORT

# Keep the supervisor itself difficult to kill. oom_policy.sh protects the
# irreplaceable media/network processes and ranks restartable services.
echo -900 > /proc/$$/oom_score_adj 2>/dev/null
# system.sh starts this supervisor after media/network initialization. Arm the
# runtime button hook even if the router is unavailable, so it can recover WiFi.
refresh_oom_policy
publish_reset_ready

echo "$(date +'%Y-%m-%d %H:%M:%S') - Starting service supervisor..." >> $LOG_FILE

while true
do
    RTSP_ENABLED=$(get_config RTSP)
    if [ "$RTSP_ENABLED" = "yes" ]; then
        RTSP_ALT=$(get_config RTSP_ALT)
        case "$RTSP_ALT" in
            alternative) [ -x "$YI_HACK_PREFIX/bin/rtsp_server_yi" ] || RTSP_ALT=standard ;;
            *) RTSP_ALT=standard ;;
        esac
        if [ "$RTSP_ALT" = "standard" ]; then
            check_rtsp
        elif [ "$RTSP_ALT" = "alternative" ]; then
            check_rtsp_alt
        fi
    fi

    check_rmm
    check_motion
    check_mqtt

    AUX_COUNTER=$((AUX_COUNTER + 1))
    if [ "$AUX_COUNTER" -ge "$AUX_CHECK_EVERY" ]; then
        AUX_COUNTER=0
        check_aux_services
        if [ -f "$YI_HACK_PREFIX/flash-core" ]; then
            "$YI_HACK_PREFIX/bin/service_guard" 5 "$YI_HACK_PREFIX/script/flash_config_sync.sh" >/dev/null 2>&1 &
        fi
    fi

    OOM_POLICY_COUNTER=$((OOM_POLICY_COUNTER + 1))
    if [ "$OOM_POLICY_COUNTER" -ge "$OOM_POLICY_EVERY" ]; then
        OOM_POLICY_COUNTER=0
        refresh_oom_policy
    fi

    "$YI_HACK_PREFIX/script/hotspot.sh" poll >/dev/null 2>&1

    # Connection recovery is independent of the streaming service setting.
    check_wifi

    [ -e /sys/class/net/eth0/mtu ] && echo 1500 > /sys/class/net/eth0/mtu
    [ -e /sys/class/net/wlan0/mtu ] && echo 1500 > /sys/class/net/wlan0/mtu

    sleep "$INTERVAL"
done
