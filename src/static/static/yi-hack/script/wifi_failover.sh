#!/tmp/sd/yi-hack/bin/busybox ash

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
yi_lock wifi-recovery || exit $?
case "$(cat /tmp/yi-hotspot/state 2>/dev/null)" in starting|active|stopping) exit 75 ;; esac
[ ! -s /tmp/yi-hotspot.request ] && [ ! -s /tmp/yi-hotspot/pending ] || exit 75
CONF_FILE="$YI_HACK_PREFIX/etc/system.conf"
ACTIVE_FILE="/tmp/wifi_maintenance_active"
WPA_CONF="/tmp/wpa_supplicant.maintenance.conf"
LOG_FILE="/tmp/sd/hack_wififailsafe.log"

get_config()
{
    grep -w "$1" "$CONF_FILE" 2>/dev/null | cut -d "=" -f2-
}

log()
{
    if [ -f "$LOG_FILE" ]; then
        SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null)
        case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
        if [ "$SIZE" -gt 65536 ]; then
            if [ -x "$YI_HACK_PREFIX/usr/bin/tail" ]; then
                "$YI_HACK_PREFIX/usr/bin/tail" -n 160 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
            else
                : > "$LOG_FILE"
            fi
        fi
    fi
    echo "$(date): $*" >> "$LOG_FILE"
}


echo -650 > "/proc/$$/oom_score_adj" 2>/dev/null

[ "$(get_config WIFI_RECOVERY_MODE)" = maintenance ] || exit 1

if [ "${1:-}" = reboot ]; then
    case "$(cat "$ACTIVE_FILE" 2>/dev/null)" in
        maintenance|maintenance_pending) reboot; exit $? ;;
        *) exit 75 ;;
    esac
fi

MAINT_SSID=$(get_config WIFI_MAINTENANCE_SSID)
MAINT_PASSWORD=$(get_config WIFI_MAINTENANCE_PASSWORD)

if [ -z "$MAINT_SSID" ] || [ "${#MAINT_SSID}" -gt 32 ]; then
    log "maintenance handoff refused: invalid SSID"
    exit 1
fi
if [ "${#MAINT_PASSWORD}" -lt 8 ] || [ "${#MAINT_PASSWORD}" -gt 63 ]; then
    log "maintenance handoff refused: password must be 8-63 characters"
    exit 1
fi

escape_wpa()
{
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

start_maintenance_dhcp()
{
    killall udhcpc 2>/dev/null
    HN="yi-hack"
    [ -f "$YI_HACK_PREFIX/etc/hostname" ] && HN=$(cat "$YI_HACK_PREFIX/etc/hostname")

    if [ -f /backup/tools/default.script ]; then
        udhcpc -i wlan0 -b -s /backup/tools/default.script -x hostname:"$HN"
    elif [ -f /home/app/script/default.script ]; then
        udhcpc -i wlan0 -b -s /home/app/script/default.script -x hostname:"$HN"
    fi
}

SSID_ESC=$(escape_wpa "$MAINT_SSID")
PASSWORD_ESC=$(escape_wpa "$MAINT_PASSWORD")

umask 077
cat > "$WPA_CONF" <<EOC
ctrl_interface=/var/run/wpa_supplicant
ap_scan=1
network={
    ssid="$SSID_ESC"
    scan_ssid=1
    proto=WPA RSN
    key_mgmt=WPA-PSK
    pairwise=CCMP TKIP
    group=CCMP TKIP
    psk="$PASSWORD_ESC"
}
EOC

WPA_BIN=""
[ -x /backup/tools/wpa_supplicant ] && WPA_BIN=/backup/tools/wpa_supplicant
[ -z "$WPA_BIN" ] && [ -x /home/base/tools/wpa_supplicant ] && WPA_BIN=/home/base/tools/wpa_supplicant
if [ -z "$WPA_BIN" ]; then
    log "maintenance handoff failed: wpa_supplicant not found"
    exit 1
fi

PRIMARY_WPA_BACKUP=/tmp/wpa_supplicant.primary.before-maint.conf
[ -f /tmp/wpa_supplicant.conf ] && cp /tmp/wpa_supplicant.conf "$PRIMARY_WPA_BACKUP" 2>/dev/null

# Publish only after validation, while holding wifi-recovery. Primary recovery
# and vendor station launchers must leave this maintenance connection alone.
# Six failed watchdog checks escalate to a guarded reboot.
echo "maintenance_pending" > "$ACTIVE_FILE"
log "switching once to maintenance-only WiFi profile"

killall udhcpc 2>/dev/null
killall wpa_supplicant 2>/dev/null
sleep 1
killall -q -9 udhcpc wpa_supplicant 2>/dev/null || true
# Keep the SDIO interface up while replacing the supplicant profile. Repeated
# down/up cycling can wedge Wi-Fi on y623.
ifconfig wlan0 0.0.0.0 2>/dev/null
ifconfig wlan0 up 2>/dev/null
mkdir -p /var/run/wpa_supplicant

"$WPA_BIN" -c"$WPA_CONF" -g/var/run/wpa_supplicant-global -Dnl80211 -iwlan0 -B
if [ $? -ne 0 ]; then
    log "maintenance handoff failed: wpa_supplicant start failed"
    exit 1
fi

sleep 2
start_maintenance_dhcp
log "maintenance-only WiFi profile launched; awaiting watchdog connectivity confirmation"
exit 0
