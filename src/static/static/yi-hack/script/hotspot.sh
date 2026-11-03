#!/tmp/sd/yi-hack/bin/busybox ash
# Local AP. Primary credentials and provisioning partitions are never changed.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
BB="$YI_HACK_PREFIX/bin/busybox"
RUNTIME=${YI_HOTSPOT_RUNTIME:-/tmp/yi-hotspot}
REQUEST=${YI_HOTSPOT_REQUEST:-/tmp/yi-hotspot.request}
PRIMARY=${YI_HOTSPOT_PRIMARY:-/tmp/wpa_supplicant.conf}
SYSTEM_CONF="$YI_HACK_PREFIX/etc/system.conf"
WPA_BIN=${YI_HOTSPOT_WPA:-/backup/tools/wpa_supplicant}
WPA_CLI=${YI_HOTSPOT_WPA_CLI:-/home/base/tools/wpa_cli}
AP_BIN=${YI_HOTSPOT_AP:-$YI_HACK_PREFIX/bin/hostapd}
AP_CLI=${YI_HOTSPOT_AP_CLI:-$YI_HACK_PREFIX/bin/hostapd_cli}
DISPATCH=${YI_HOTSPOT_DISPATCH:-/home/app/dispatch}

config() { sed -n "s/^$1=//p" "$SYSTEM_CONF" | tail -n 1; }
state() { cat "$RUNTIME/state" 2>/dev/null; }
set_state() { printf '%s\n' "$1" > "$RUNTIME/state.$$" && mv -f "$RUNTIME/state.$$" "$RUNTIME/state"; }
log() { "$YI_HACK_PREFIX/script/bounded_log.sh" /tmp/hotspot.log "$*" || :; }
reset_armed()
{
    [ -f /tmp/yi-reset-hotspot.armed ] || return 1
    ARMED_PID=$(cat /tmp/yi-reset-hotspot.armed 2>/dev/null)
    case "$ARMED_PID" in ''|*[!0-9]*) return 1 ;; esac
    [ "$("$BB" readlink "/proc/$ARMED_PID/exe" 2>/dev/null)" = "$DISPATCH" ] || return 1
    grep -Fq "$YI_HACK_PREFIX/lib/ipc_multiplex.so" "/proc/$ARMED_PID/maps" 2>/dev/null
}
reset_supported()
{
    case "$(cat "$YI_HACK_PREFIX/model_suffix"):$(md5sum "$DISPATCH" 2>/dev/null | cut -d' ' -f1)" in
        y623:033ff9e7091c72ab2209eaac74ad802e|y623:f4e457a4cc195460e5f6a63bd46351ef|y28ga:c6ae77baf1821023c2138cf46bb793ec|y28ga:2388704364446d01857c3cf11937f3f4) return 0 ;;
    esac
    return 1
}
settings()
{
    MODEL=$(cat "$YI_HACK_PREFIX/model_suffix")
    case "$MODEL" in y623|y28ga) ;; *) return 1 ;; esac
    SSID=$(config WIFI_HOTSPOT_SSID)
    if [ -z "$SSID" ]; then
        MAC=$(cat /sys/class/net/wlan0/address 2>/dev/null | tr -d ':' | tail -c 7)
        SSID="yi-$MODEL-${MAC:-camera}"
    fi
    [ "$(printf %s "$SSID" | "$BB" wc -c)" -le 32 ] || return 1
    [ -n "$SSID" ] || return 1
    CHANNEL=$(config WIFI_HOTSPOT_CHANNEL)
    [ -n "$CHANNEL" ] || CHANNEL=6
    case "$CHANNEL" in 1|2|3|4|5|6|7|8|9|10|11) ;; *) return 1 ;; esac
    PASSWORD=$(config WIFI_HOTSPOT_PASSWORD)
    if [ -n "$PASSWORD" ]; then
        [ "${#PASSWORD}" -ge 8 ] && [ "${#PASSWORD}" -le 63 ] || return 1
        LC_ALL=C; export LC_ALL
        case "$PASSWORD" in *[!\ -~]*) return 1 ;; esac
    fi
}
radio_is_ap()
{
    "$BB" timeout -s KILL 2 iwconfig wlan0 2>/dev/null | grep -q 'Mode:Master'
}
boot_request()
{
    # Explicit SD/UI hotspot settings take precedence over the unprovisioned
    # fallback. Never clear a deliberately configured hotspot password at boot.
    if [ "$(config WIFI_HOTSPOT_BOOT)" = yes ]; then
        check && request start
        return 0
    fi
    WIFI_CONFIG=${YI_HOTSPOT_WIFI_CONFIG:-/tmp/sd/Factory/configure_wifi.cfg}
    WIFI_MTD=${YI_HOTSPOT_WIFI_MTD:-/dev/mtdblock7}
    KEY_HEX=$(dd if="$WIFI_MTD" bs=1 skip=92 count=64 2>/dev/null | "$BB" od -An -v -tx1 | tr -d ' \n')
    if [ ! -e "$WIFI_CONFIG" ] && [ "${#KEY_HEX}" -eq 128 ] &&
       [ -z "$(printf %s "$KEY_HEX" | sed 's/00//g; s/ff//g')" ]; then
        if [ -n "$(config WIFI_HOTSPOT_PASSWORD)" ]; then
            check && request start
        else
            request start-open
        fi
    fi
    return 0
}
clear_password()
{
    [ -n "$(config WIFI_HOTSPOT_PASSWORD)" ] || return 0
    if grep -q '^WIFI_HOTSPOT_PASSWORD=' "$SYSTEM_CONF"; then
        sed -i 's/^WIFI_HOTSPOT_PASSWORD=.*/WIFI_HOTSPOT_PASSWORD=/' "$SYSTEM_CONF" || return 1
    else
        printf '\nWIFI_HOTSPOT_PASSWORD=\n' >> "$SYSTEM_CONF" || return 1
    fi
    if [ -f "$YI_HACK_PREFIX/flash-core" ]; then
        "$YI_HACK_PREFIX/bin/service_guard" 5 "$YI_HACK_PREFIX/script/flash_config_sync.sh" || true
    fi
}
check()
{
    settings || return 1
    [ -x "$WPA_BIN" ] && [ -x "$WPA_CLI" ] && [ -x "$AP_BIN" ] && [ -x "$AP_CLI" ] || return 1
    command -v iwconfig >/dev/null 2>&1 || return 1
    "$BB" --list | grep -qx udhcpd || return 1
}
request()
{
    umask 077
    mkdir -p "$RUNTIME" || return 1
    printf '%s\n' "$1" > "$RUNTIME/request.$$" || return 1
    mv -f "$RUNTIME/request.$$" "$REQUEST"
}
pid_alive()
{
    PID=$(cat "$1" 2>/dev/null)
    case "$PID" in ''|*[!0-9]*) return 1 ;; esac
    "$BB" kill -0 "$PID" 2>/dev/null || return 1
    tr '\000' '\n' < "/proc/$PID/cmdline" 2>/dev/null |
        awk -v config="$2" '$0 == config || $0 == "-c" config { found=1 } END { exit !found }'
}
stop_owned()
{
    if pid_alive "$1" "$2"; then
        "$BB" kill "$PID" 2>/dev/null
        for WAIT in 1 2 3; do
            pid_alive "$1" "$2" || break
            sleep 1
        done
        if pid_alive "$1" "$2"; then "$BB" kill -9 "$PID" 2>/dev/null; fi
    fi
    rm -f "$1"
}
stop_ap()
{
    "$BB" timeout -s KILL 2 "$AP_CLI" -p "$RUNTIME/ctrl" -i wlan0 terminate >/dev/null 2>&1 || true
    stop_owned "$RUNTIME/dhcp.pid" "$RUNTIME/udhcpd.conf"
    stop_owned "$RUNTIME/wpa.pid" "$RUNTIME/hostapd.conf"
}
restore_station()
{
    set_state stopping || return 1
    stop_ap
    # Restore the original primary profile, not a maintenance-only AP profile.
    ifconfig wlan0 0.0.0.0
    if [ -s "$PRIMARY" ]; then
        # dispatch can relaunch its primary supplicant before rollback gets here.
        # Its station control directory differs from the AP's private directory.
        if ! "$BB" timeout -s KILL 2 "$WPA_CLI" -i wlan0 ping 2>/dev/null | grep -qx PONG; then
            "$BB" timeout -s KILL 10 "$WPA_BIN" -c"$PRIMARY" -g/var/run/wpa_supplicant-global -Dnl80211 -iwlan0 -B || return 1
        fi
        "$YI_HACK_PREFIX/bin/service_guard" 15 "$BB" ash "$YI_HACK_PREFIX/script/wifidhcp.sh" || return 1
    else
        return 1
    fi
    set_state station
}
start_ap()
{
    check || { log "Hotspot prerequisites/settings unavailable; keeping current network."; return 1; }
    # Generate and validate everything before stopping the current connection.
    SSID_HEX=$(printf %s "$SSID" | "$BB" od -An -v -tx1 | tr -d ' \n') || return 1
    umask 077
    mkdir -p "$RUNTIME/ctrl" || return 1
    SECURITY='wpa=0'
    if [ -n "$PASSWORD" ]; then
        SECURITY="wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$PASSWORD"
    fi
    cat > "$RUNTIME/hostapd.conf" <<EOC
interface=wlan0
driver=nl80211
ctrl_interface=$RUNTIME/ctrl
ssid2=$SSID_HEX
hw_mode=g
channel=$CHANNEL
wmm_enabled=1
ignore_broadcast_ssid=0
auth_algs=1
$SECURITY
EOC
    cat > "$RUNTIME/udhcpd.conf" <<EOC
start 192.168.10.100
end 192.168.10.150
interface wlan0
max_leases 16
lease_file $RUNTIME/leases
pidfile $RUNTIME/dhcp.pid
opt subnet 255.255.255.0
opt router 192.168.10.1
opt lease 600
EOC
    : > "$RUNTIME/leases"
    set_state starting || return 1
    # Both recovery paths use wifi-recovery ownership. Do not cycle wlan0 down.
    "$BB" killall udhcpc 2>/dev/null || true
    "$BB" killall wpa_supplicant 2>/dev/null || true
    sleep 1
    "$BB" killall -q -9 udhcpc wpa_supplicant 2>/dev/null || true
    stop_ap
    mkdir -p "$RUNTIME/ctrl" || return 1
    ifconfig wlan0 up || return 1
    (ulimit -f 32; "$BB" timeout -s KILL 10 "$AP_BIN" -B -P "$RUNTIME/wpa.pid" "$RUNTIME/hostapd.conf") > "$RUNTIME/startup.log" 2>&1 || return 1
    AP_READY=no
    for WAIT in 1 2 3 4 5; do
        STATUS=$("$BB" timeout -s KILL 2 "$AP_CLI" -p "$RUNTIME/ctrl" -i wlan0 status 2>/dev/null)
        if printf '%s\n' "$STATUS" | grep -qx 'state=ENABLED' && radio_is_ap; then
            AP_READY=yes
            break
        fi
        sleep 1
    done
    [ "$AP_READY" = yes ] || return 1
    ifconfig wlan0 192.168.10.1 netmask 255.255.255.0 || return 1
    "$BB" udhcpd -f "$RUNTIME/udhcpd.conf" >/dev/null 2>&1 &
    echo $! > "$RUNTIME/dhcp.pid"
    sleep 1
    pid_alive "$RUNTIME/dhcp.pid" "$RUNTIME/udhcpd.conf" || return 1
    set_state active || return 1
    log "Hotspot active: $SSID at 192.168.10.1. Camera authentication is unchanged."
}
apply()
{
    yi_lock wifi-recovery || return $?
    umask 077
    mkdir -p "$RUNTIME" || return 1
    NEW_REQUEST=no
    if [ -f "$REQUEST" ]; then
        mv -f "$REQUEST" "$RUNTIME/pending" || return 1
        NEW_REQUEST=yes
    fi
    ACTION=$(cat "$RUNTIME/pending" 2>/dev/null)
    case "$ACTION" in
        start-open) clear_password || return 1; ACTION=start ;;
        start|stop) ;;
        '')
            case "$(state)" in
                starting|stopping) ACTION=stop ;;
                active)
                    if pid_alive "$RUNTIME/wpa.pid" "$RUNTIME/hostapd.conf" && pid_alive "$RUNTIME/dhcp.pid" "$RUNTIME/udhcpd.conf"; then
                        radio_is_ap && return 0
                        log "Hotspot radio left AP mode; restoring primary WiFi."
                        ACTION=stop
                    else
                        ACTION=start
                    fi ;;
                *) return 0 ;;
            esac ;;
        *) return 1 ;;
    esac
    # Resume a timed-out rollback before replaying its original start request.
    if [ "$NEW_REQUEST" = no ] && [ "$(state)" = stopping ]; then ACTION=stop; fi
    if [ "$ACTION" = stop ]; then
        case "$(state)" in
            ''|station) rm -f "$RUNTIME/pending"; return 0 ;;
        esac
        restore_station || { set_state failed; rm -f "$RUNTIME/pending"; log "Primary WiFi restoration needs watchdog recovery."; return 1; }
    elif ! start_ap; then
        case "$(state)" in
            starting|stopping)
                log "Hotspot startup failed; restoring primary WiFi."
                restore_station || true ;;
            active)
                # Prerequisites failed before teardown: keep the working AP.
                rm -f "$RUNTIME/pending"
                return 1 ;;
        esac
        set_state failed
        rm -f "$RUNTIME/pending"
        return 1
    fi
    rm -f "$RUNTIME/pending"
}
case "$1" in
    start) check || exit 1; request start ;;
    boot) boot_request ;;
    stop) request stop ;;
    apply) apply ;;
    poll)
        NEED_WORK=no
        if [ -s "$REQUEST" ] || [ -s "$RUNTIME/pending" ]; then
            NEED_WORK=yes
        else
            case "$(state)" in
                starting|stopping) NEED_WORK=yes ;;
                active)
                    if ! pid_alive "$RUNTIME/wpa.pid" "$RUNTIME/hostapd.conf" || ! pid_alive "$RUNTIME/dhcp.pid" "$RUNTIME/udhcpd.conf" || ! radio_is_ap; then NEED_WORK=yes; fi ;;
            esac
        fi
        if [ "$NEED_WORK" = yes ]; then
            "$YI_HACK_PREFIX/bin/service_guard" 45 "$0" apply >/dev/null 2>&1 &
        fi ;;
    scan)
        yi_lock wifi-recovery || exit $?
        case "$(state)" in starting|active|stopping) exit 0 ;; esac
        "$YI_HACK_PREFIX/bin/service_guard" 8 iwlist wlan0 scan ;;
    status) state ;;
    settings) settings && printf '%s\n%s\n' "$SSID" "$CHANNEL" ;;
    reset-supported) reset_supported ;;
    reset-armed) reset_armed ;;
    check) check ;;
    *) echo "usage: $0 {boot|start|stop|status|settings|check|reset-supported|poll|apply}" >&2; exit 2 ;;
esac
