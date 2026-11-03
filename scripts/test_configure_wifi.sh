#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/src/static/static/yi-hack/script/configure_wifi.sh"
TMP=${TMPDIR:-/tmp}/yi-wifi-test.$$
mkdir -p "$TMP"
PREFIX="$TMP/yi-hack"
mkdir -p "$PREFIX/etc"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

new_mtd()
{
    printf 'WIFI_HOTSPOT_BOOT=yes\nWIFI_HOTSPOT_SSID=old-camera\nWIFI_HOTSPOT_PASSWORD=old-hotspot-password\nNTPD=no\n' > "$PREFIX/etc/system.conf"
    MTD="$TMP/mtdblock7.bin"
    dd if=/dev/zero of="$MTD" bs=256 count=1 2>/dev/null
    printf 'old-network' | dd of="$MTD" bs=1 seek=28 conv=notrunc 2>/dev/null
    printf 'old-password' | dd of="$MTD" bs=1 seek=92 conv=notrunc 2>/dev/null
    printf '\001\000\000\000' | dd of="$MTD" bs=1 seek=24 count=4 conv=notrunc 2>/dev/null
}

run_writer()
{
    YI_HACK_PREFIX="$PREFIX" CFG_FILE="$1" YI_WIFI_MTD_DEVICE="$MTD" YI_WIFI_SD_ROOT="$TMP" /bin/sh "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
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
    config_before=$(md5sum "$PREFIX/etc/system.conf" | awk '{print $1}')
    before=$(md5sum "$MTD" | awk '{print $1}')
    if run_writer "$cfg"; then
        echo "expected rejection for $cfg" >&2
        exit 1
    fi
    after=$(md5sum "$MTD" | awk '{print $1}')
    [ "$before" = "$after" ] || { echo "MTD changed on rejected config: $cfg" >&2; exit 1; }
    config_after=$(md5sum "$PREFIX/etc/system.conf" | awk '{print $1}')
    [ "$config_before" = "$config_after" ] || { echo "settings changed on rejected config" >&2; exit 1; }
}

# Preflight validates either mode without changing MTD or saved settings.
for pair in 'wifi_ssid=preflight-router|wifi_psk=preflight-password' 'hotspot_ssid=preflight-camera|hotspot_psk='; do
    new_mtd
    printf '%s\n' "$pair" | tr '|' '\n' > "$TMP/check.cfg"
    before=$(md5sum "$MTD" "$PREFIX/etc/system.conf")
    YI_HACK_PREFIX="$PREFIX" CFG_FILE="$TMP/check.cfg" YI_WIFI_MTD_DEVICE="$MTD" YI_WIFI_SD_ROOT="$TMP" /bin/sh "$SCRIPT" --check
    [ "$before" = "$(md5sum "$MTD" "$PREFIX/etc/system.conf")" ] || { echo 'preflight changed settings' >&2; exit 1; }
done

# Unix LF.
new_mtd
printf 'wifi_ssid=TestSSID\nwifi_psk=test-password-123\n' > "$TMP/lf.cfg"
run_writer "$TMP/lf.cfg"
assert_stored TestSSID test-password-123
grep -qx 'WIFI_HOTSPOT_BOOT=no' "$PREFIX/etc/system.conf"
grep -qx 'WIFI_HOTSPOT_SSID=old-camera' "$PREFIX/etc/system.conf"
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

# Router and hotspot fields are mutually exclusive, including empty/partial pairs.
for body in \
    'wifi_ssid=router\nwifi_psk=password123\nhotspot_ssid=cam\nhotspot_psk=hotspot-pass' \
    'wifi_ssid=\nhotspot_ssid=cam\nhotspot_psk=' \
    'wifi_ssid=router\nwifi_psk=password123\nhotspot_psk=' \
    ' wifi_ssid=router\nhotspot_ssid=cam\nhotspot_psk=' \
    'hotspot_ssid=cam\nhotspot_psk=\nunknown=value' \
    'hotspot_ssid=cam' \
    'hotspot_psk=password123' \
    'hotspot_ssid=cam\nhotspot_ssid=again\nhotspot_psk=password123' \
    'hotspot_ssid=cam\nhotspot_psk=onepassword\nhotspot_psk=twopassword' \
    'hotspot_ssid=\nhotspot_psk=' \
    'hotspot_ssid=cam\nhotspot_psk=short' \
    'hotspot_ssid=cam\nhotspot_psk=pass\tword' \
    'hotspot_ssid=cam\nhotspot_psk=épassword' \
    'hotspot_ssid=123456789012345678901234567890123\nhotspot_psk=' \
    'hotspot_ssid=cam\nhotspot_psk=1234567890123456789012345678901234567890123456789012345678901234'; do
    new_mtd
    printf '%b\n' "$body" > "$TMP/invalid-pair.cfg"
    assert_rejected_without_write "$TMP/invalid-pair.cfg"
done

# Hotspot imports preserve every provisioning byte and do not create MTD backups.
for model in y623 y28ga; do
    new_mtd
    printf '%s\n' "$model" > "$PREFIX/model_suffix"
    before=$(md5sum "$MTD" | awk '{print $1}')
    backup_before=$(find "$TMP" -name 'mtdblock7_*.bin' | sort)
    printf 'hotspot_ssid=Camera AP\nhotspot_psk=hotspot-password\n' > "$TMP/hotspot.cfg"
    run_writer "$TMP/hotspot.cfg"
    grep -qx 'WIFI_HOTSPOT_BOOT=yes' "$PREFIX/etc/system.conf"
    grep -qx 'WIFI_HOTSPOT_SSID=Camera AP' "$PREFIX/etc/system.conf"
    grep -qx 'WIFI_HOTSPOT_PASSWORD=hotspot-password' "$PREFIX/etc/system.conf"
    grep -qx 'NTPD=no' "$PREFIX/etc/system.conf"
    [ "$(md5sum "$MTD" | awk '{print $1}')" = "$before" ]
    [ "$(find "$TMP" -name 'mtdblock7_*.bin' | sort)" = "$backup_before" ]
    ! grep -q 'hotspot-password' "$TMP/out" "$TMP/err"
    # Empty hotspot password explicitly removes the saved password.
    printf 'hotspot_ssid=Open Camera\nhotspot_psk=\n' > "$TMP/open.cfg"
    run_writer "$TMP/open.cfg"
    grep -qx 'WIFI_HOTSPOT_PASSWORD=' "$PREFIX/etc/system.conf"
    [ "$(md5sum "$MTD" | awk '{print $1}')" = "$before" ]
done

# Hotspot settings do not even require a readable/writable provisioning device.
MTD="$TMP/nonexistent-device"
run_writer "$TMP/hotspot.cfg"
[ ! -e "$MTD" ]

# Escapes, quotes and spaces remain literal data, including a CRLF/BOM input.
new_mtd
printf '\357\273\277hotspot_ssid=Camera "A" #1 \\ \r\nhotspot_psk=safe"pass\\word\r\n' > "$TMP/quoted-hotspot.cfg"
run_writer "$TMP/quoted-hotspot.cfg"
grep -Fqx 'WIFI_HOTSPOT_SSID=Camera "A" #1 \ ' "$PREFIX/etc/system.conf"
grep -Fqx 'WIFI_HOTSPOT_PASSWORD=safe"pass\word' "$PREFIX/etc/system.conf"

# Reapplying already-provisioned router credentials still switches off hotspot boot.
new_mtd
run_writer "$TMP/lf.cfg"
sed -i 's/^WIFI_HOTSPOT_BOOT=.*/WIFI_HOTSPOT_BOOT=yes/' "$PREFIX/etc/system.conf"
before=$(md5sum "$MTD" | awk '{print $1}')
backup_before=$(find "$TMP" -name 'mtdblock7_*.bin' | sort)
run_writer "$TMP/lf.cfg"
grep -qx 'WIFI_HOTSPOT_BOOT=no' "$PREFIX/etc/system.conf"
[ "$(md5sum "$MTD" | awk '{print $1}')" = "$before" ]
[ "$(find "$TMP" -name 'mtdblock7_*.bin' | sort)" = "$backup_before" ]

# Large files are rejected before allocating unbounded parser buffers.
new_mtd
dd if=/dev/zero bs=4097 count=1 2>/dev/null | tr '\000' '#' > "$TMP/oversized.cfg"
assert_rejected_without_write "$TMP/oversized.cfg"

echo "configure_wifi.sh router/hotspot tests passed"
