#!/bin/sh
# Explicit offline clock control. The saved value is a boot-time floor, not an RTC.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
CONF="$YI_HACK_PREFIX/etc/system.conf"
value() { sed -n "s/^$1=//p" "$CONF" | tail -n 1; }
valid_epoch()
{
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    # The audited vendor userspace has 32-bit time_t. Stay below 2038 overflow.
    [ "${#1}" -eq 10 ] && [ "$1" -ge 1577836800 ] && [ "$1" -le 2145916799 ]
}
case "${1:-}" in
    status)
        date -u '+%s'
        exit $? ;;
    set|restore)
        . "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
        yi_lock manual-time || exit $?
        ;;
    *) exit 2 ;;
esac
if [ "$1" = restore ]; then
    [ "$(value NTPD)" = no ] || exit 0
    EPOCH=$(value MANUAL_TIME_EPOCH)
    valid_epoch "$EPOCH" || exit 0
    NOW=$(date -u +%s) || exit 1
    [ "$NOW" -lt "$EPOCH" ] || exit 0
    date -u -s "@$EPOCH" >/dev/null || exit 1
else
    EPOCH=${2:-}
    valid_epoch "$EPOCH" || exit 2
    umask 077
    CLOCK_TMP="$CONF.clock.$$"
    trap 'rm -f "$CLOCK_TMP"' 0
    trap 'exit 1' 1 2 15
    awk -v epoch="$EPOCH" '
        /^NTPD=/ { next }
        /^MANUAL_TIME_EPOCH=/ { next }
        { print }
        END { print "NTPD=no"; print "MANUAL_TIME_EPOCH=" epoch }
    ' "$CONF" > "$CLOCK_TMP" || exit 1
    chmod 600 "$CLOCK_TMP" || exit 1
    mv "$CLOCK_TMP" "$CONF" || exit 1
    killall ntpd 2>/dev/null || true
    date -u -s "@$EPOCH" >/dev/null || exit 1
    # Mirror explicit settings once if SD is present. No periodic clock writes.
    if [ -f "$YI_HACK_PREFIX/flash-core" ]; then
        "$YI_HACK_PREFIX/bin/service_guard" 5 "$YI_HACK_PREFIX/script/flash_config_sync.sh" >/dev/null 2>&1 || true
    fi
fi
"$YI_HACK_PREFIX/script/update_osd_tz.sh" >/dev/null 2>&1 || true
