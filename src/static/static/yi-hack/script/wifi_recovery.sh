#!/tmp/sd/yi-hack/bin/busybox ash
# Invoked in service_guard's private process group. No wlan0 down/up cycle.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
yi_lock wifi-recovery || exit $?
case "$(cat /tmp/yi-hotspot/state 2>/dev/null)" in starting|active|stopping) exit 0 ;; esac
[ ! -s /tmp/yi-hotspot.request ] && [ ! -s /tmp/yi-hotspot/pending ] || exit 75
[ ! -s /tmp/wifi_maintenance_active ] || exit 75
if ! ps 2>/dev/null | grep '[w]pa_supplicant' >/dev/null 2>&1; then
    if [ -s /tmp/wpa_supplicant.conf ] && [ -x /tmp/local-only/vendor-wificonnect.sh ]; then
        /bin/sh /tmp/local-only/vendor-wificonnect.sh >/dev/null 2>&1
        sleep 2
    fi
elif [ -x /home/base/tools/wpa_cli ]; then
    "$YI_HACK_PREFIX/bin/busybox" timeout -s KILL 2 /home/base/tools/wpa_cli -i wlan0 reconfigure >/dev/null 2>&1
fi
"$YI_HACK_PREFIX/script/wifidhcp.sh"
