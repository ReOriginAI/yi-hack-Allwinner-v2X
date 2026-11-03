#!/bin/sh
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
reply_error()
{
    printf 'Content-type: application/json\r\nCache-Control: no-store\r\n\r\n'
    printf '{"error":true,"message":%s}\n' "$(printf %s "$1" | jq -Rs .)"
    exit 0
}
case "${REQUEST_METHOD:-GET}" in
    GET) ;;
    POST)
        case "${CONTENT_LENGTH:-}" in ''|*[!0-9]*) reply_error 'Invalid request length' ;; esac
        [ "${#CONTENT_LENGTH}" -le 3 ] && [ "$CONTENT_LENGTH" -gt 0 ] && [ "$CONTENT_LENGTH" -le 512 ] || reply_error 'Request too large'
        BODY=$("$YI_HACK_PREFIX/bin/service_guard" 5 dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null) || reply_error 'Timed out reading request'
        EPOCH=$(printf %s "$BODY" | jq -er 'select(type == "object") | .epoch | select(type == "number" and . == floor and . >= 1577836800 and . <= 2145916799) | tostring' 2>/dev/null) || reply_error 'Use an integer Unix timestamp between 2020 and 2037'
        "$YI_HACK_PREFIX/script/manual_time.sh" set "$EPOCH" || reply_error 'Could not apply clock; check saved time settings'
        ;;
    *) reply_error 'Use GET to read or POST to set the clock' ;;
esac
EPOCH=$(date -u +%s) || reply_error 'Could not read clock'
UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
NTP=false
grep -qx 'NTPD=yes' "$YI_HACK_PREFIX/etc/system.conf" && NTP=true
printf 'Content-type: application/json\r\nCache-Control: no-store\r\n\r\n'
jq -n --argjson epoch "$EPOCH" --arg utc "$UTC" --argjson ntp "$NTP" '{error:false,epoch:$epoch,utc:$utc,ntp_enabled:$ntp}'
