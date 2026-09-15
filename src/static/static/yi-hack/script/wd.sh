#!/bin/sh

CONF_FILE="etc/system.conf"
CAMERA_CONF_FILE="etc/camera.conf"

YI_HACK_PREFIX="/tmp/sd/yi-hack"
MODEL_SUFFIX=$(cat /tmp/sd/yi-hack/model_suffix)

START_STOP_SCRIPT=$YI_HACK_PREFIX/script/service.sh

#LOG_FILE="/tmp/sd/wd.log"
LOG_FILE="/dev/null"
LOGWIFI_FILE="/tmp/sd/hack_wififailsafe.log"

COUNTER=0
COUNTER_LIMIT=10
INTERVAL=10
WIFI_FAILSAFE_COUNTER=0
WIFI_FAILSAFE_STARTED=0
WIFI_MAINTENANCE_FAILSAFE_COUNTER=0

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
    $START_STOP_SCRIPT rtsp start
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
    [ "$MODEL_SUFFIX" = "y623" ] || return 0
    [ "$(get_config DISABLE_CLOUD)" = "yes" ] || return 0
    [ "$(get_camera_config MOTION_DETECTION)" = "yes" ] || return 0

    COUNT=$(ps | awk '$5 == "/tmp/sd/yi-hack/bin/motiond" { n++ } END { print n+0 }')
    if [ "$COUNT" -ne 1 ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') - Restarting local motion detector (count=$COUNT)" >> $LOG_FILE
        "$YI_HACK_PREFIX/script/motion_service.sh" restart >/dev/null 2>&1
    fi
}

check_mqtt()
{
    #  echo "$(date +'%Y-%m-%d %H:%M:%S') - Checking mqttv4 process..." >> $LOG_FILE

    PS=`ps ww | grep mqttv4 | grep -v grep | grep -c ^`

    if [ $PS -eq 0 ]; then
        echo "check_mqtt failed, restart it!" >> $LOG_FILE
        $START_STOP_SCRIPT mqtt start
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

if [[ $(get_config RTSP) == "no" ]] ; then
    # With streaming disabled, wd.sh is normally unnecessary. Keep it alive
    # only when maintenance failover needs the existing 10-second watchdog loop.
    if [ "$(get_config WIFI_MAINTENANCE_ENABLED)" = "yes" ]; then
        while true; do
            check_rmm
            check_motion
            check_wifi
            sleep "$INTERVAL"
        done
    fi

    # Preserve the prior local-motion-only behavior for y623.
    if [ "$MODEL_SUFFIX" = "y623" ] &&
       [ "$(get_config DISABLE_CLOUD)" = "yes" ] &&
       [ "$(get_camera_config MOTION_DETECTION)" = "yes" ]; then
        while true; do
            check_motion
            sleep "$INTERVAL"
        done
    fi
    exit
fi

case $(get_config RTSP_PORT) in
    ''|*[!0-9]*) RTSP_PORT=554 ;;
    *) RTSP_PORT=$(get_config RTSP_PORT) ;;
esac

if [ ! -z $RTSP_PORT ]; then
    RTSP_PORT_NUMBER=$RTSP_PORT
fi

RTSP_ALT=$(get_config RTSP_ALT)

echo "$(date +'%Y-%m-%d %H:%M:%S') - Starting RTSP watchdog..." >> $LOG_FILE

while true
do
    if [[ "$RTSP_ALT" == "standard" ]] ; then
        check_rtsp
    elif [[ "$RTSP_ALT" == "alternative" ]] ; then
        check_rtsp_alt
    else
        check_rtsp_go2rtc
    fi
    check_rmm
    check_motion
    check_mqtt
    check_wifi

    echo 1500 > /sys/class/net/eth0/mtu
    echo 1500 > /sys/class/net/wlan0/mtu

    if [ $COUNTER -eq 0 ]; then
        sleep $INTERVAL
    fi
done
