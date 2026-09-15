#!/bin/sh

CONF_FILE="etc/system.conf"
CAMERA_CONF_FILE="etc/camera.conf"

YI_HACK_PREFIX="/tmp/sd/yi-hack"
MODEL_SUFFIX=$(cat /tmp/sd/yi-hack/model_suffix)

START_STOP_SCRIPT=$YI_HACK_PREFIX/script/service.sh

# Singleton supervisor. service.sh may have a delayed watchdog launch pending
# while another path starts wd.sh immediately; only one may survive.
WD_LOCKDIR=/tmp/yi_hack_wd.lock.d
if ! mkdir "$WD_LOCKDIR" 2>/dev/null; then
    OLD_PID=$(cat "$WD_LOCKDIR/pid" 2>/dev/null)
    case "$OLD_PID" in ''|*[!0-9]*) OLD_PID=0 ;; esac
    if [ "$OLD_PID" -gt 0 ] && [ -d "/proc/$OLD_PID" ]; then
        exit 0
    fi
    rm -rf "$WD_LOCKDIR" 2>/dev/null
    mkdir "$WD_LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$WD_LOCKDIR/pid"
cleanup_wd_lock() { rm -rf "$WD_LOCKDIR" 2>/dev/null; }
trap 'cleanup_wd_lock' 0
trap 'cleanup_wd_lock; exit 0' HUP INT TERM

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

check_rtsp_go2rtc()
{
    if [[ $(get_camera_config SWITCH_ON) == "yes" ]] ; then
        # go2rtc exec producers are lazy: zero h264grabber processes is the
        # normal idle state. Health is one go2rtc daemon plus its listen socket.
        LISTEN=`$YI_HACK_PREFIX/bin/netstat -an 2>&1 | grep ":$RTSP_PORT_NUMBER " | grep LISTEN | grep -c ^`
        GO2RTC_COUNT=$(ps | awk '$5 == "go2rtc" { n++ } END { print n+0 }')

        if [ "$LISTEN" -eq 0 ] || [ "$GO2RTC_COUNT" -ne 1 ]; then
            echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting go2rtc (listen=$LISTEN count=$GO2RTC_COUNT)" >> $LOG_FILE
            killall -q go2rtc
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

    if [ "$(get_config REC_WITHOUT_CLOUD)" = "yes" ] && [ "$(process_count mp4record)" -eq 0 ]; then
        $START_STOP_SCRIPT mp4record start >/dev/null 2>&1
        refresh_oom_policy
        return 0
    fi

    if [ "$(get_config ONVIF)" = "yes" ]; then
        if [ "$(process_count onvif_notify_server)" -eq 0 ] || [ "$(process_count ipc2file)" -eq 0 ]; then
            # ONVIF owns ipc2file as a pair. Recreate the pair cleanly rather
            # than starting a duplicate survivor.
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
        if [ "$(get_config BUSYBOX_FTPD)" = "yes" ]; then
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

check_wifi()
{
    MAINT_STATE=$(cat /tmp/wifi_maintenance_active 2>/dev/null)

    # After primary failover, monitor only the maintenance profile. Never poll
    # or retry the primary SSID until reboot. If maintenance itself cannot
    # establish or keep a usable connection for six recovery attempts, reboot
    # so the WiFi driver/hardware and the primary boot profile get a clean start.
    if [ "$(get_config WIFI_MAINTENANCE_ENABLED)" = "yes" ] &&
       { [ "$MAINT_STATE" = "maintenance_pending" ] || [ "$MAINT_STATE" = "maintenance" ]; }; then
        WIFI_CONNECTED=0
        WPA_STATUS_VALID=0

        if [ -x /home/base/tools/wpa_cli ]; then
            (sleep 2 && killall -9 wpa_cli 2>/dev/null) &
            KILLER_PID=$!
            WPA_OUTPUT=$(/home/base/tools/wpa_cli -i wlan0 status 2>/dev/null)
            WPA_EXIT=$?
            kill $KILLER_PID 2>/dev/null
            wait $KILLER_PID 2>/dev/null
            if [ $WPA_EXIT -eq 0 ] && echo "$WPA_OUTPUT" | grep -q "wpa_state="; then
                WPA_STATUS_VALID=1
                if echo "$WPA_OUTPUT" | grep -q "wpa_state=COMPLETED"; then
                    WIFI_CONNECTED=1
                fi
            fi
        fi

        # Only trust an existing IPv4 address when wpa_cli is unavailable/broken.
        # If wpa_cli explicitly reports a non-COMPLETED state, the old address
        # may be stale and must not hide a failed maintenance association.
        if [ $WIFI_CONNECTED -eq 0 ] && [ $WPA_STATUS_VALID -eq 0 ] && ifconfig wlan0 2>/dev/null | grep -q "inet addr:"; then
            WIFI_CONNECTED=1
        fi

        if [ $WIFI_CONNECTED -eq 1 ]; then
            MAINT_SSID=$(get_config WIFI_MAINTENANCE_SSID)
            CURRENT_SSID=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p')
            if [ -z "$MAINT_SSID" ] || [ "$CURRENT_SSID" != "$MAINT_SSID" ]; then
                WIFI_CONNECTED=0
            fi
        fi

        if [ $WIFI_CONNECTED -eq 0 ] && [ -f /sys/class/net/wlan0/carrier ]; then
            CARRIER=$(cat /sys/class/net/wlan0/carrier 2>/dev/null)
            [ "$CARRIER" = "1" ] || WIFI_CONNECTED=0
        fi

        if [ $WIFI_CONNECTED -eq 1 ]; then
            if [ "$MAINT_STATE" != "maintenance" ]; then
                echo "maintenance" > /tmp/wifi_maintenance_active
                echo -e "$(date): Maintenance WiFi connected; primary will not be retried until reboot" >> "$LOGWIFI_FILE"
            elif [ "$WIFI_MAINTENANCE_FAILSAFE_COUNTER" -gt 0 ]; then
                echo -e "$(date): Maintenance WiFi connection restored" >> "$LOGWIFI_FILE"
            fi
            WIFI_MAINTENANCE_FAILSAFE_COUNTER=0
            return 0
        fi

        WIFI_MAINTENANCE_FAILSAFE_COUNTER=$((WIFI_MAINTENANCE_FAILSAFE_COUNTER + 1))
        echo -e "$(date): Maintenance WiFi unavailable (failsafe attempt $WIFI_MAINTENANCE_FAILSAFE_COUNTER/6)" >> "$LOGWIFI_FILE"

        if [ "$WIFI_MAINTENANCE_FAILSAFE_COUNTER" -ge 6 ]; then
            echo -e "$(date): Primary and maintenance WiFi both failed; rebooting for clean driver/hardware recovery" >> "$LOGWIFI_FILE"
            reboot
            return 0
        fi

        echo -e "$(date): Retrying maintenance WiFi only" >> "$LOGWIFI_FILE"
        "$YI_HACK_PREFIX/script/wifi_failover.sh" >/dev/null 2>&1
        return 0
    fi

    WIFI_CONNECTED=0

    # Method 1: Try wpa_cli if available and working.
    if [ -x /home/base/tools/wpa_cli ]; then
        (sleep 2 && killall -9 wpa_cli 2>/dev/null) &
        KILLER_PID=$!
        WPA_OUTPUT=$(/home/base/tools/wpa_cli -i wlan0 status 2>/dev/null)
        WPA_EXIT=$?
        kill $KILLER_PID 2>/dev/null
        wait $KILLER_PID 2>/dev/null

        if [ $WPA_EXIT -eq 0 ] && echo "$WPA_OUTPUT" | grep -q "wpa_state=COMPLETED"; then
            WIFI_CONNECTED=1
        fi
    fi

    # Method 2: Fallback to an assigned IPv4 address.
    if [ $WIFI_CONNECTED -eq 0 ]; then
        if ifconfig wlan0 2>/dev/null | grep -q "inet addr:"; then
            WIFI_CONNECTED=1
        fi
    fi

    # With maintenance failover enabled, only the configured primary SSID
    # counts as healthy during the grace period. This prevents a vendor
    # secondary network block from masking loss of the real primary network.
    if [ "$(get_config WIFI_MAINTENANCE_ENABLED)" = "yes" ] && [ $WIFI_CONNECTED -eq 1 ]; then
        PRIMARY_SSID=$(dd bs=1 skip=28 count=64 if=/dev/mtdblock7 2>/dev/null | tr -d "\000\r")
        CURRENT_SSID=$(iwconfig wlan0 2>/dev/null | sed -n 's/.*ESSID:"\([^"]*\)".*/\1/p')
        if [ -z "$PRIMARY_SSID" ] || [ "$CURRENT_SSID" != "$PRIMARY_SSID" ]; then
            WIFI_CONNECTED=0
        fi
    fi

    # Preserve the vendor carrier sanity check.
    if [ $WIFI_CONNECTED -eq 0 ] && [ -f /sys/class/net/wlan0/carrier ]; then
        CARRIER=$(cat /sys/class/net/wlan0/carrier 2>/dev/null)
        [ "$CARRIER" = "1" ] || WIFI_CONNECTED=0
    fi

    if [ $WIFI_CONNECTED -eq 0 ]; then
        if [ -e "$LOGWIFI_FILE" ]; then
            $YI_HACK_PREFIX/usr/bin/tail -n 145 "$LOGWIFI_FILE" > "$LOGWIFI_FILE.tmp" && mv "$LOGWIFI_FILE.tmp" "$LOGWIFI_FILE"
        fi

        WIFI_FAILSAFE_COUNTER=$((WIFI_FAILSAFE_COUNTER + 1))

        if [ "$(get_config WIFI_MAINTENANCE_ENABLED)" = "yes" ]; then
            WIFI_GRACE=$(get_config WIFI_MAINTENANCE_GRACE)
            case "$WIFI_GRACE" in ''|*[!0-9]*) WIFI_GRACE=180 ;; esac
            [ "$WIFI_GRACE" -ge 30 ] 2>/dev/null || WIFI_GRACE=30
            [ "$WIFI_GRACE" -le 3600 ] 2>/dev/null || WIFI_GRACE=3600
            WIFI_NOW=$(cut -d. -f1 /proc/uptime 2>/dev/null)
            case "$WIFI_NOW" in ''|*[!0-9]*) WIFI_NOW=$((WIFI_FAILSAFE_COUNTER * INTERVAL)) ;; esac
            if [ "$WIFI_FAILSAFE_STARTED" -eq 0 ]; then
                WIFI_FAILSAFE_STARTED=$WIFI_NOW
            fi
            WIFI_LOST_SECONDS=$((WIFI_NOW - WIFI_FAILSAFE_STARTED))

            echo -e "$(date): Primary WiFi unavailable (${WIFI_LOST_SECONDS}s/${WIFI_GRACE}s, recovery attempt $WIFI_FAILSAFE_COUNTER/6 before maintenance handoff)" >> "$LOGWIFI_FILE"

            if [ "$WIFI_LOST_SECONDS" -ge "$WIFI_GRACE" ] && [ "$WIFI_FAILSAFE_COUNTER" -ge 6 ]; then
                echo -e "$(date): Grace period expired; switching to maintenance WiFi" >> "$LOGWIFI_FILE"
                if "$YI_HACK_PREFIX/script/wifi_failover.sh" >/dev/null 2>&1; then
                    WIFI_FAILSAFE_COUNTER=0
                    WIFI_FAILSAFE_STARTED=0
                    WIFI_MAINTENANCE_FAILSAFE_COUNTER=0
                    return 0
                fi
                # A failed maintenance launcher is still a maintenance failure.
                # wifi_failover.sh leaves maintenance_pending set so subsequent
                # watchdog passes retry maintenance only and reboot after six
                # failures rather than falling back into primary polling.
                WIFI_FAILSAFE_COUNTER=0
                WIFI_FAILSAFE_STARTED=0
                echo "maintenance_pending" > /tmp/wifi_maintenance_active
                WIFI_MAINTENANCE_FAILSAFE_COUNTER=1
                echo -e "$(date): Maintenance handoff attempt 1/6 failed; entering maintenance-only recovery" >> "$LOGWIFI_FILE"
                return 0
            fi

            # During the grace period, preserve the existing reconnect behavior
            # but never reboot. This gives the primary network time to recover.
            sleep 2
            ifconfig wlan0 down
            sleep 1
            ifconfig wlan0 up
            sleep 1

            if [ -x /home/base/tools/wpa_cli ]; then
                (sleep 2 && killall -9 wpa_cli 2>/dev/null) &
                KILLER_PID=$!
                /home/base/tools/wpa_cli -i wlan0 reconfigure 2>/dev/null
                kill $KILLER_PID 2>/dev/null
                wait $KILLER_PID 2>/dev/null
            fi

            $YI_HACK_PREFIX/script/wifidhcp.sh
            return 0
        fi

        # Legacy behavior is unchanged when maintenance failover is disabled.
        echo -e "$(date): WiFi connection lost (failsafe attempt $WIFI_FAILSAFE_COUNTER/6)" >> "$LOGWIFI_FILE"

        if [ "$WIFI_FAILSAFE_COUNTER" -ge 6 ]; then
            echo -e "$(date): WiFi connection could not be restored after 6 attempts. Rebooting..." >> "$LOGWIFI_FILE"
            reboot
        else
            echo -e "$(date): Attempting WiFi reconnect..." >> "$LOGWIFI_FILE"

            sleep 2
            ifconfig wlan0 down
            sleep 1
            ifconfig wlan0 up
            sleep 1

            if [ -x /home/base/tools/wpa_cli ]; then
                (sleep 2 && killall -9 wpa_cli 2>/dev/null) &
                KILLER_PID=$!
                /home/base/tools/wpa_cli -i wlan0 reconfigure 2>/dev/null
                kill $KILLER_PID 2>/dev/null
                wait $KILLER_PID 2>/dev/null
            fi

            $YI_HACK_PREFIX/script/wifidhcp.sh
        fi
    else
        if [ $WIFI_FAILSAFE_COUNTER -gt 0 ]; then
            echo -e "$(date): WiFi connection restored" >> "$LOGWIFI_FILE"
            WIFI_FAILSAFE_COUNTER=0
            WIFI_FAILSAFE_STARTED=0
        fi
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
refresh_oom_policy

echo "$(date +'%Y-%m-%d %H:%M:%S') - Starting service supervisor..." >> $LOG_FILE

while true
do
    RTSP_ENABLED=$(get_config RTSP)
    if [ "$RTSP_ENABLED" = "yes" ]; then
        RTSP_ALT=$(get_config RTSP_ALT)
        if [ "$RTSP_ALT" = "standard" ]; then
            check_rtsp
        elif [ "$RTSP_ALT" = "alternative" ]; then
            check_rtsp_alt
        else
            check_rtsp_go2rtc
        fi
    fi

    check_rmm
    check_motion
    check_mqtt

    AUX_COUNTER=$((AUX_COUNTER + 1))
    if [ "$AUX_COUNTER" -ge "$AUX_CHECK_EVERY" ]; then
        AUX_COUNTER=0
        check_aux_services
    fi

    OOM_POLICY_COUNTER=$((OOM_POLICY_COUNTER + 1))
    if [ "$OOM_POLICY_COUNTER" -ge "$OOM_POLICY_EVERY" ]; then
        OOM_POLICY_COUNTER=0
        refresh_oom_policy
    fi

    # Preserve the existing Wi-Fi recovery loop when RTSP is active, and keep
    # it available without RTSP when maintenance failover is explicitly used.
    if [ "$RTSP_ENABLED" = "yes" ] || [ "$(get_config WIFI_MAINTENANCE_ENABLED)" = "yes" ]; then
        check_wifi
    fi

    [ -e /sys/class/net/eth0/mtu ] && echo 1500 > /sys/class/net/eth0/mtu
    [ -e /sys/class/net/wlan0/mtu ] && echo 1500 > /sys/class/net/wlan0/mtu

    sleep "$INTERVAL"
done
