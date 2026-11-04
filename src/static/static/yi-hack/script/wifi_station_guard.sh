#!/bin/sh
# Vendor dispatch retries station setup independently of our watchdog. Its
# recovery scripts must leave wlan0 alone while the hotspot owns the radio.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
yi_lock wifi-recovery || exit $?
ROLE=${0##*/}
case "$ROLE" in wificonnect.sh|killwifi.sh|wifidhcp.sh) ;; *) exit 2 ;; esac
case "$(cat /tmp/yi-hotspot/state 2>/dev/null)" in
    starting|active|stopping) exit 0 ;;
esac
[ ! -s /tmp/yi-hotspot.request ] && [ ! -s /tmp/yi-hotspot/pending ] || exit 0
# The parent shell retains ownership while the bounded child runs. exec would
# release the CLOEXEC lock before the vendor script touches the radio.
[ ! -s /tmp/wifi_maintenance_active ] || exit 0
"$YI_HACK_PREFIX/bin/service_guard" 25 /bin/sh "/tmp/local-only/vendor-$ROLE" "$@"
