#!/bin/sh

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
SYSTEM_CONF="$YI_HACK_PREFIX/etc/system.conf"

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

json_string()
{
    printf '%s' "$1" | jq -Rs .
}

get_system_config()
{
    grep -w "$1" "$SYSTEM_CONF" 2>/dev/null | cut -d "=" -f2-
}

set_system_config()
{
    KEY="$1"
    VALUE="$2"
    ESCAPED=$(printf '%s' "$VALUE" | sed 's/\\/\\\\/g; s/&/\\&/g; s/|/\\|/g')
    if grep -q "^${KEY}=" "$SYSTEM_CONF"; then
        sed -i "s|^${KEY}=.*|${KEY}=${ESCAPED}|" "$SYSTEM_CONF" || json_error "could not save WiFi configuration"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$SYSTEM_CONF" || json_error "could not save WiFi configuration"
    fi
}

current_primary_ssid()
{
    dd bs=1 skip=28 count=64 if=/dev/mtdblock7 2>/dev/null | tr -d "\000\r"
}

json_error()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":"true","message":%s}\n' "$(json_string "$1")"
    exit
}

json_ok()
{
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":"false"}\n'
    exit
}

if ! $(validateQueryString "$QUERY_STRING"); then
    json_error "invalid query"
fi

PARAM="$(echo "$QUERY_STRING" | cut -d'=' -f1)"
VAL="$(echo "$QUERY_STRING" | cut -d'=' -f2)"
ACTION="none"
[ "$PARAM" = "action" ] && ACTION="$VAL"

if [ "$ACTION" = "scan" ] || [ "$ACTION" = "status" ]; then
    PRIMARY=$(current_primary_ssid)
    MAINT_ENABLED=$(get_system_config WIFI_MAINTENANCE_ENABLED)
    MAINT_SSID=$(get_system_config WIFI_MAINTENANCE_SSID)
    MAINT_GRACE=$(get_system_config WIFI_MAINTENANCE_GRACE)
    MAINT_PASSWORD=$(get_system_config WIFI_MAINTENANCE_PASSWORD)
    [ -n "$MAINT_GRACE" ] || MAINT_GRACE=180
    if [ -n "$MAINT_PASSWORD" ]; then
        MAINT_PASSWORD_SET=true
    else
        MAINT_PASSWORD_SET=false
    fi

    HOTSPOT_STATE=$("$YI_HACK_PREFIX/script/hotspot.sh" status)
    HOTSPOT_SETTINGS=$("$YI_HACK_PREFIX/script/hotspot.sh" settings)
    HOTSPOT_SSID=$(printf '%s\n' "$HOTSPOT_SETTINGS" | sed -n '1p')
    HOTSPOT_CHANNEL=$(get_system_config WIFI_HOTSPOT_CHANNEL)
    HOTSPOT_BOOT=$(get_system_config WIFI_HOTSPOT_BOOT)
    RESET_HOTSPOT=$(get_system_config WIFI_RESET_HOTSPOT)
    RESET_ARMED=false
    "$YI_HACK_PREFIX/script/hotspot.sh" reset-armed && RESET_ARMED=true
    RESET_SUPPORTED=false
    "$YI_HACK_PREFIX/script/hotspot.sh" reset-supported && RESET_SUPPORTED=true
    [ -n "$HOTSPOT_STATE" ] || HOTSPOT_STATE=station
    [ -n "$HOTSPOT_CHANNEL" ] || HOTSPOT_CHANNEL=6
    [ -n "$HOTSPOT_BOOT" ] || HOTSPOT_BOOT=no
    [ -n "$RESET_HOTSPOT" ] || RESET_HOTSPOT=no
    SCAN_FILE="/tmp/wifi_scan.$$"
    trap 'rm -f "$SCAN_FILE"' 0
    trap 'exit 1' 1 2 15
    case "$HOTSPOT_STATE" in
        starting|active|stopping) : > "$SCAN_FILE" ;;
        *) "$YI_HACK_PREFIX/script/hotspot.sh" scan 2>/dev/null | grep "ESSID:" | sed 's/^[ \t]*ESSID://g; s/^"//; s/"$//' | grep -v '^$' > "$SCAN_FILE" ;;
    esac

    printf "Content-type: application/json\r\n\r\n"
    printf '{"current_ssid":%s,' "$(json_string "$PRIMARY")"
    printf '"maintenance_enabled":%s,' "$(json_string "$MAINT_ENABLED")"
    printf '"maintenance_ssid":%s,' "$(json_string "$MAINT_SSID")"
    printf '"maintenance_grace":%s,' "$(json_string "$MAINT_GRACE")"
    printf '"maintenance_password_set":%s,' "$MAINT_PASSWORD_SET"
    printf '"hotspot_state":%s,' "$(json_string "$HOTSPOT_STATE")"
    printf '"hotspot_ssid":%s,' "$(json_string "$HOTSPOT_SSID")"
    printf '"hotspot_configured_ssid":%s,' "$(json_string "$(get_system_config WIFI_HOTSPOT_SSID)")"
    printf '"hotspot_channel":%s,' "$(json_string "$HOTSPOT_CHANNEL")"
    printf '"hotspot_boot":%s,' "$(json_string "$HOTSPOT_BOOT")"
    printf '"reset_hotspot":%s,' "$(json_string "$RESET_HOTSPOT")"
    printf '"reset_hotspot_supported":%s,' "$RESET_SUPPORTED"
    printf '"reset_hotspot_armed":%s,' "$RESET_ARMED"
    printf '"wifi":['

    FIRST=1
    while IFS= read -r SSID; do
        [ -n "$SSID" ] || continue
        if [ "$FIRST" -eq 0 ]; then
            printf ','
        fi
        printf '%s' "$(json_string "$SSID")"
        FIRST=0
    done < "$SCAN_FILE"
    rm -f "$SCAN_FILE"
    printf ']}\n'
    exit
fi

if [ "$ACTION" = hotspot_start ] || [ "$ACTION" = hotspot_stop ]; then
    [ "$REQUEST_METHOD" = POST ] || json_error "use POST for hotspot changes"
    if [ "$ACTION" = hotspot_start ]; then
        "$YI_HACK_PREFIX/script/hotspot.sh" start || json_error "hotspot prerequisites or settings are unavailable"
    else
        "$YI_HACK_PREFIX/script/hotspot.sh" stop || json_error "unable to queue primary WiFi restoration"
    fi
    json_ok
fi

if [ "$ACTION" = "save" ]; then
    read -r POST_DATA
    printf '%s\n' "$POST_DATA" | jq -e . >/dev/null 2>&1 || json_error "invalid json"

    # Validate hotspot fields before any primary credential write. Missing fields
    # preserve saved values for clients using the older WiFi API.
    for HOTSPOT_KEY in WIFI_HOTSPOT_BOOT WIFI_HOTSPOT_SSID WIFI_HOTSPOT_CHANNEL WIFI_RESET_HOTSPOT; do
        printf '%s\n' "$POST_DATA" | jq -e --arg key "$HOTSPOT_KEY" 'if has($key) then (.[$key] | type == "string" and (test("[\u0000-\u001f\u007f]") | not)) else true end' >/dev/null 2>&1 || json_error "invalid hotspot field"
    done
    HOTSPOT_BOOT=$(printf '%s\n' "$POST_DATA" | jq -r --arg saved "$(get_system_config WIFI_HOTSPOT_BOOT)" '.WIFI_HOTSPOT_BOOT // $saved')
    HOTSPOT_SSID=$(printf '%s\n' "$POST_DATA" | jq -r --arg saved "$(get_system_config WIFI_HOTSPOT_SSID)" '.WIFI_HOTSPOT_SSID // $saved')
    HOTSPOT_CHANNEL=$(printf '%s\n' "$POST_DATA" | jq -r --arg saved "$(get_system_config WIFI_HOTSPOT_CHANNEL)" '.WIFI_HOTSPOT_CHANNEL // $saved')
    RESET_HOTSPOT=$(printf '%s\n' "$POST_DATA" | jq -r --arg saved "$(get_system_config WIFI_RESET_HOTSPOT)" '.WIFI_RESET_HOTSPOT // $saved')
    [ -n "$HOTSPOT_BOOT" ] || HOTSPOT_BOOT=no
    [ -n "$HOTSPOT_CHANNEL" ] || HOTSPOT_CHANNEL=6
    [ -n "$RESET_HOTSPOT" ] || RESET_HOTSPOT=no
    case "$HOTSPOT_BOOT:$RESET_HOTSPOT" in yes:yes|yes:no|no:yes|no:no) ;; *) json_error "invalid hotspot option" ;; esac
    case "$HOTSPOT_CHANNEL" in 1|2|3|4|5|6|7|8|9|10|11) ;; *) json_error "hotspot channel must be 1-11" ;; esac
    [ "$(printf %s "$HOTSPOT_SSID" | "$YI_HACK_PREFIX/bin/busybox" wc -c)" -le 32 ] || json_error "hotspot SSID must fit in 32 bytes"
    if [ "$RESET_HOTSPOT" = yes ]; then
        "$YI_HACK_PREFIX/script/hotspot.sh" reset-supported || json_error "reset button override is unavailable for this firmware"
    fi

    HAS_PRIMARY=$(printf '%s\n' "$POST_DATA" | jq -r 'if has("WIFI_ESSID") or has("WIFI_PASSWORD") or has("WIFI_PASSWORD2") then "yes" else "no" end')
    if [ "$HAS_PRIMARY" = "yes" ]; then
        PRIMARY_SSID=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_ESSID // ""')
        PRIMARY_PASSWORD=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_PASSWORD // ""')
        PRIMARY_PASSWORD2=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_PASSWORD2 // ""')

        [ -n "$PRIMARY_SSID" ] || json_error "primary SSID is blank"
        [ "${#PRIMARY_SSID}" -le 63 ] || json_error "primary SSID is too long"
        [ -n "$PRIMARY_PASSWORD" ] || json_error "primary password is blank"
        [ "${#PRIMARY_PASSWORD}" -le 63 ] || json_error "primary password is too long"
        [ "$PRIMARY_PASSWORD" = "$PRIMARY_PASSWORD2" ] || json_error "primary passwords do not match"

        rm -f /tmp/configure_wifi.cfg
        printf 'wifi_ssid=%s\n' "$PRIMARY_SSID" >> /tmp/configure_wifi.cfg
        printf 'wifi_psk=%s\n' "$PRIMARY_PASSWORD" >> /tmp/configure_wifi.cfg
        "$YI_HACK_PREFIX/script/configure_wifi.sh" >/dev/null 2>&1 || {
            rm -f /tmp/configure_wifi.cfg
            json_error "could not save primary WiFi"
        }
        rm -f /tmp/configure_wifi.cfg
    fi

    MAINT_ENABLED=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_ENABLED // "no"')
    MAINT_SSID=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_SSID // ""')
    MAINT_GRACE=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_GRACE // "180"')
    NEW_MAINT_PASSWORD=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_PASSWORD // ""')
    NEW_MAINT_PASSWORD2=$(printf '%s\n' "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_PASSWORD2 // ""')
    CURRENT_MAINT_PASSWORD=$(get_system_config WIFI_MAINTENANCE_PASSWORD)

    case "$MAINT_ENABLED" in yes|no) ;; *) json_error "invalid maintenance enabled value" ;; esac
    case "$MAINT_GRACE" in ''|*[!0-9]*) json_error "maintenance grace must be a number" ;; esac
    [ "$MAINT_GRACE" -ge 30 ] && [ "$MAINT_GRACE" -le 3600 ] || json_error "maintenance grace must be 30-3600 seconds"

    if [ -n "$NEW_MAINT_PASSWORD" ]; then
        [ "${#NEW_MAINT_PASSWORD}" -ge 8 ] && [ "${#NEW_MAINT_PASSWORD}" -le 63 ] || json_error "maintenance password must be 8-63 characters"
        [ "$NEW_MAINT_PASSWORD" = "$NEW_MAINT_PASSWORD2" ] || json_error "maintenance passwords do not match"
        CURRENT_MAINT_PASSWORD="$NEW_MAINT_PASSWORD"
    fi

    if [ "$MAINT_ENABLED" = "yes" ]; then
        [ -n "$MAINT_SSID" ] || json_error "maintenance SSID is blank"
        [ "${#MAINT_SSID}" -le 32 ] || json_error "maintenance SSID is too long"
        [ "${#CURRENT_MAINT_PASSWORD}" -ge 8 ] && [ "${#CURRENT_MAINT_PASSWORD}" -le 63 ] || json_error "maintenance password is not configured"
    fi

    set_system_config WIFI_HOTSPOT_BOOT "$HOTSPOT_BOOT"
    set_system_config WIFI_HOTSPOT_SSID "$HOTSPOT_SSID"
    set_system_config WIFI_HOTSPOT_CHANNEL "$HOTSPOT_CHANNEL"
    set_system_config WIFI_RESET_HOTSPOT "$RESET_HOTSPOT"
    set_system_config WIFI_MAINTENANCE_ENABLED "$MAINT_ENABLED"
    set_system_config WIFI_MAINTENANCE_SSID "$MAINT_SSID"
    set_system_config WIFI_MAINTENANCE_GRACE "$MAINT_GRACE"
    if [ -n "$NEW_MAINT_PASSWORD" ]; then
        set_system_config WIFI_MAINTENANCE_PASSWORD "$NEW_MAINT_PASSWORD"
    fi

    sync
    json_ok
fi

json_error "unknown action"
