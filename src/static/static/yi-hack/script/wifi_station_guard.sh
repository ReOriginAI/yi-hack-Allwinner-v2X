#!/bin/sh
# Vendor dispatch retries station setup independently of our watchdog. Its
# recovery scripts must leave wlan0 alone while the hotspot owns the radio.
ROLE=${0##*/}
case "$ROLE" in wificonnect.sh|killwifi.sh|wifidhcp.sh) ;; *) exit 2 ;; esac
case "$(cat /tmp/yi-hotspot/state 2>/dev/null)" in
    starting|active|stopping) exit 0 ;;
esac
exec /bin/sh "/tmp/local-only/vendor-$ROLE" "$@"
