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
        sed -i "s|^${KEY}=.*|${KEY}=${ESCAPED}|" "$SYSTEM_CONF"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$SYSTEM_CONF"
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

    SCAN_FILE="/tmp/wifi_scan.$$"
    iwlist wlan0 scan 2>/dev/null | grep "ESSID:" | sed 's/^[ \t]*ESSID://g; s/^"//; s/"$//' | grep -v '^$' > "$SCAN_FILE"

    printf "Content-type: application/json\r\n\r\n"
    printf '{"current_ssid":%s,' "$(json_string "$PRIMARY")"
    printf '"maintenance_enabled":%s,' "$(json_string "$MAINT_ENABLED")"
    printf '"maintenance_ssid":%s,' "$(json_string "$MAINT_SSID")"
    printf '"maintenance_grace":%s,' "$(json_string "$MAINT_GRACE")"
    printf '"maintenance_password_set":%s,' "$MAINT_PASSWORD_SET"
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

if [ "$ACTION" = "save" ]; then
    read -r POST_DATA
    echo "$POST_DATA" | jq -e . >/dev/null 2>&1 || json_error "invalid json"

    HAS_PRIMARY=$(echo "$POST_DATA" | jq -r 'if has("WIFI_ESSID") or has("WIFI_PASSWORD") or has("WIFI_PASSWORD2") then "yes" else "no" end')
    if [ "$HAS_PRIMARY" = "yes" ]; then
        PRIMARY_SSID=$(echo "$POST_DATA" | jq -r '.WIFI_ESSID // ""')
        PRIMARY_PASSWORD=$(echo "$POST_DATA" | jq -r '.WIFI_PASSWORD // ""')
        PRIMARY_PASSWORD2=$(echo "$POST_DATA" | jq -r '.WIFI_PASSWORD2 // ""')

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

    MAINT_ENABLED=$(echo "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_ENABLED // "no"')
    MAINT_SSID=$(echo "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_SSID // ""')
    MAINT_GRACE=$(echo "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_GRACE // "180"')
    NEW_MAINT_PASSWORD=$(echo "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_PASSWORD // ""')
    NEW_MAINT_PASSWORD2=$(echo "$POST_DATA" | jq -r '.WIFI_MAINTENANCE_PASSWORD2 // ""')
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
