#!/bin/sh

# Robust primary Wi-Fi provisioning for both WebUI and SD-card recovery.
# CFG_FILE may be overridden by the caller; the WebUI default remains /tmp/configure_wifi.cfg.
LC_ALL=C
export LC_ALL
CFG_FILE=${CFG_FILE:-/tmp/configure_wifi.cfg}
MTD_DEVICE=${YI_WIFI_MTD_DEVICE:-/dev/mtdblock7}
SD_ROOT=${YI_WIFI_SD_ROOT:-/tmp/sd}
FORCE=no
[ "${1:-}" = "force" ] && FORCE=yes

TMP_BASE=/tmp/configure_wifi.$$
RAW_CFG=${TMP_BASE}.raw
CLEAN_CFG=${TMP_BASE}.clean

cleanup()
{
    rm -f "$RAW_CFG" "$CLEAN_CFG"
}

fail()
{
    echo "configure_wifi.sh: $*" >&2
    cleanup
    exit 1
}

trap cleanup EXIT HUP INT TERM

[ -f "$CFG_FILE" ] || fail "configure_wifi.cfg not found: $CFG_FILE"
[ -r "$CFG_FILE" ] || fail "configure_wifi.cfg is not readable: $CFG_FILE"
[ -r "$MTD_DEVICE" ] || fail "Wi-Fi MTD device is not readable: $MTD_DEVICE"
[ -w "$MTD_DEVICE" ] || fail "Wi-Fi MTD device is not writable: $MTD_DEVICE"
[ -d "$SD_ROOT" ] || fail "SD root is not available: $SD_ROOT"

# Normalize common editor/OS encodings without silently changing credential bytes.
# UTF-8 BOM and CRLF/CR line endings are accepted. UTF-16 is rejected explicitly
# because stripping NUL bytes can corrupt non-ASCII SSIDs/passwords.
PREFIX=$(dd if="$CFG_FILE" bs=1 count=3 2>/dev/null | hexdump -v -e '1/1 "%02x"')
case "$PREFIX" in
    efbbbf*)
        dd if="$CFG_FILE" of="$RAW_CFG" bs=1 skip=3 2>/dev/null || fail "cannot remove UTF-8 BOM"
        ;;
    fffe*|feff*)
        fail "UTF-16 configure_wifi.cfg is not supported; save it as UTF-8 or plain text"
        ;;
    *)
        cat "$CFG_FILE" > "$RAW_CFG" || fail "cannot read configure_wifi.cfg"
        ;;
esac

# Embedded NUL usually means UTF-16 without a BOM or a damaged file. Refuse it
# instead of producing an empty/partial SSID and touching flash.
if hexdump -v -e '1/1 "%02x\n"' "$RAW_CFG" | grep -q '^00$'; then
    fail "configure_wifi.cfg contains NUL bytes; save it as UTF-8 or plain text"
fi

# Accept Unix LF, Windows CRLF, and classic CR line endings. A CR inside a value
# is not a valid credential delimiter and is therefore normalized to a newline.
tr '\r' '\n' < "$RAW_CFG" > "$CLEAN_CFG" || fail "cannot normalize line endings"

# Reject common invisible Unicode formatting characters. Silently stripping
# these could change a legitimate SSID, so fail with a useful error instead.
HEX=$(hexdump -v -e '1/1 "%02x"' "$CLEAN_CFG")
case "$HEX" in
    *efbbbf*|*c2ad*|*c2a0*|*e28087*|*e2808b*|*e2808c*|*e2808d*|*e2808e*|*e2808f*|*e280aa*|*e280ab*|*e280ac*|*e280ad*|*e280ae*|*e280af*|*e281a0*|*e281a6*|*e281a7*|*e281a8*|*e281a9*)
        fail "configure_wifi.cfg contains an invisible Unicode formatting character"
        ;;
esac

SSID=
KEY=
SSID_SEEN=0
KEY_SEEN=0
while IFS= read -r LINE || [ -n "$LINE" ]; do
    case "$LINE" in
        wifi_ssid=*)
            [ "$SSID_SEEN" -eq 0 ] || fail "duplicate wifi_ssid entry"
            SSID=${LINE#wifi_ssid=}
            SSID_SEEN=1
            ;;
        wifi_psk=*)
            [ "$KEY_SEEN" -eq 0 ] || fail "duplicate wifi_psk entry"
            KEY=${LINE#wifi_psk=}
            KEY_SEEN=1
            ;;
    esac
done < "$CLEAN_CFG"

[ "$SSID_SEEN" -eq 1 ] || fail "wifi_ssid entry is missing"
[ "$KEY_SEEN" -eq 1 ] || fail "wifi_psk entry is missing"
[ -n "$SSID" ] || fail "SSID has not been set"
[ -n "$KEY" ] || fail "Wi-Fi key has not been set"

SSID_LEN=${#SSID}
KEY_LEN=${#KEY}
[ "$SSID_LEN" -le 32 ] || fail "SSID is too long ($SSID_LEN bytes; maximum is 32)"
[ "$KEY_LEN" -le 63 ] || fail "Wi-Fi key is too long ($KEY_LEN bytes; maximum is 63)"

CURRENT_SSID=$(dd if="$MTD_DEVICE" bs=1 skip=28 count=64 2>/dev/null)
CURRENT_KEY=$(dd if="$MTD_DEVICE" bs=1 skip=92 count=64 2>/dev/null)
CONNECTED_BIT=$(hexdump -s 24 -n 4 -v -e '1/1 "%02x"' "$MTD_DEVICE" 2>/dev/null)
[ -n "$CONNECTED_BIT" ] || fail "cannot read Wi-Fi state from $MTD_DEVICE"

echo "configure_wifi.sh: parsed SSID length=$SSID_LEN key length=$KEY_LEN"

if [ "$SSID" = "$CURRENT_SSID" ] && [ "$KEY" = "$CURRENT_KEY" ] && [ "$CONNECTED_BIT" = "00000000" ] && [ "$FORCE" != "yes" ]; then
    echo "configure_wifi.sh: SSID and key already configured"
    exit 0
fi

# Preserve the complete partition before the first write. Never continue if the
# backup cannot be created successfully.
DATE=$(date '+%Y%m%d%H%M%S')
BACKUP=$SD_ROOT/mtdblock7_${DATE}_$$.bin
echo "configure_wifi.sh: creating partition backup at $BACKUP"
dd if="$MTD_DEVICE" of="$BACKUP" bs=65536 2>/dev/null || fail "cannot back up $MTD_DEVICE"
[ -s "$BACKUP" ] || fail "MTD backup is empty"

# Clear fixed-width fields first so the stored strings are always NUL-terminated.
dd if=/dev/zero of="$MTD_DEVICE" bs=1 seek=28 count=64 conv=notrunc 2>/dev/null || fail "cannot clear SSID field"
dd if=/dev/zero of="$MTD_DEVICE" bs=1 seek=92 count=64 conv=notrunc 2>/dev/null || fail "cannot clear key field"
printf '%s' "$SSID" | dd of="$MTD_DEVICE" bs=1 seek=28 conv=notrunc 2>/dev/null || fail "cannot write SSID"
printf '%s' "$KEY" | dd of="$MTD_DEVICE" bs=1 seek=92 conv=notrunc 2>/dev/null || fail "cannot write Wi-Fi key"
printf '\000\000\000\000' | dd of="$MTD_DEVICE" bs=1 seek=24 count=4 conv=notrunc 2>/dev/null || fail "cannot write Wi-Fi connected flag"

sync
sync
sync

# Verify exact bytes and NUL termination before reporting success.
VERIFY_SSID=$(dd if="$MTD_DEVICE" bs=1 skip=28 count="$SSID_LEN" 2>/dev/null)
VERIFY_KEY=$(dd if="$MTD_DEVICE" bs=1 skip=92 count="$KEY_LEN" 2>/dev/null)
SSID_TERM=$(hexdump -s $((28 + SSID_LEN)) -n 1 -v -e '1/1 "%02x"' "$MTD_DEVICE" 2>/dev/null)
KEY_TERM=$(hexdump -s $((92 + KEY_LEN)) -n 1 -v -e '1/1 "%02x"' "$MTD_DEVICE" 2>/dev/null)
VERIFY_CONNECTED=$(hexdump -s 24 -n 4 -v -e '1/1 "%02x"' "$MTD_DEVICE" 2>/dev/null)

[ "$VERIFY_SSID" = "$SSID" ] || fail "SSID readback verification failed"
[ "$VERIFY_KEY" = "$KEY" ] || fail "Wi-Fi key readback verification failed"
[ "$SSID_TERM" = "00" ] || fail "SSID is not NUL-terminated"
[ "$KEY_TERM" = "00" ] || fail "Wi-Fi key is not NUL-terminated"
[ "$VERIFY_CONNECTED" = "00000000" ] || fail "Wi-Fi connected flag verification failed"

echo "configure_wifi.sh: Wi-Fi credentials written and verified"
exit 0
