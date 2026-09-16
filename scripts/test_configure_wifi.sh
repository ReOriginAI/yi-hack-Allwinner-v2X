#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/src/static/static/yi-hack/script/configure_wifi.sh"
TMP=${TMPDIR:-/tmp}/yi-wifi-test.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

new_mtd()
{
    MTD="$TMP/mtdblock7.bin"
    dd if=/dev/zero of="$MTD" bs=256 count=1 2>/dev/null
    printf 'old-network' | dd of="$MTD" bs=1 seek=28 conv=notrunc 2>/dev/null
    printf 'old-password' | dd of="$MTD" bs=1 seek=92 conv=notrunc 2>/dev/null
    printf '\001\000\000\000' | dd of="$MTD" bs=1 seek=24 count=4 conv=notrunc 2>/dev/null
}

run_writer()
{
    CFG_FILE="$1" YI_WIFI_MTD_DEVICE="$MTD" YI_WIFI_SD_ROOT="$TMP" /bin/sh "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
}

assert_stored()
{
    want_ssid=$1
    want_key=$2
    got_ssid=$(dd if="$MTD" bs=1 skip=28 count=${#want_ssid} 2>/dev/null)
    got_key=$(dd if="$MTD" bs=1 skip=92 count=${#want_key} 2>/dev/null)
    [ "$got_ssid" = "$want_ssid" ] || { echo "SSID mismatch: $got_ssid" >&2; exit 1; }
    [ "$got_key" = "$want_key" ] || { echo "key mismatch" >&2; exit 1; }
    bit=$(hexdump -s 24 -n 4 -v -e '1/1 "%02x"' "$MTD")
    [ "$bit" = 00000000 ] || { echo "connected flag mismatch: $bit" >&2; exit 1; }
}

assert_rejected_without_write()
{
    cfg=$1
    before=$(md5sum "$MTD" | awk '{print $1}')
    if run_writer "$cfg"; then
        echo "expected rejection for $cfg" >&2
        exit 1
    fi
    after=$(md5sum "$MTD" | awk '{print $1}')
    [ "$before" = "$after" ] || { echo "MTD changed on rejected config: $cfg" >&2; exit 1; }
}

# Unix LF.
new_mtd
printf 'wifi_ssid=TestSSID\nwifi_psk=test-password-123\n' > "$TMP/lf.cfg"
run_writer "$TMP/lf.cfg"
assert_stored TestSSID test-password-123
! grep -q 'test-password-123' "$TMP/out" "$TMP/err" || { echo "PSK leaked to output" >&2; exit 1; }

# Windows CRLF.
new_mtd
printf 'wifi_ssid=windows-ap\r\nwifi_psk=windows-pass\r\n' > "$TMP/crlf.cfg"
run_writer "$TMP/crlf.cfg"
assert_stored windows-ap windows-pass

# UTF-8 BOM plus CRLF.
new_mtd
printf '\357\273\277wifi_ssid=bom-ap\r\nwifi_psk=bom-password\r\n' > "$TMP/bom.cfg"
run_writer "$TMP/bom.cfg"
assert_stored bom-ap bom-password

# Classic CR line endings.
new_mtd
printf 'wifi_ssid=cr-ap\rwifi_psk=cr-password\r' > "$TMP/cr.cfg"
run_writer "$TMP/cr.cfg"
assert_stored cr-ap cr-password

# UTF-16LE with BOM must fail closed rather than being NUL-stripped.
new_mtd
printf '\377\376w\000i\000f\000i\000_\000s\000s\000i\000d\000=\000x\000\r\000\n\000' > "$TMP/utf16.cfg"
assert_rejected_without_write "$TMP/utf16.cfg"

# UTF-16/NUL without BOM must also fail closed.
new_mtd
printf 'w\000i\000f\000i\000_\000s\000s\000i\000d\000=\000x\000\n\000' > "$TMP/nul.cfg"
assert_rejected_without_write "$TMP/nul.cfg"

# Zero-width space in the SSID must not be silently stripped.
new_mtd
printf 'wifi_ssid=bad\342\200\213ssid\nwifi_psk=password123\n' > "$TMP/zero-width.cfg"
assert_rejected_without_write "$TMP/zero-width.cfg"

# Duplicate keys are ambiguous and must fail closed.
new_mtd
printf 'wifi_ssid=one\nwifi_ssid=two\nwifi_psk=password123\n' > "$TMP/duplicate.cfg"
assert_rejected_without_write "$TMP/duplicate.cfg"

echo "configure_wifi.sh tests passed"
