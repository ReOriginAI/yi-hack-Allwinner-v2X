#!/bin/sh
# First-install bootstrap for the exact audited y28ga firmware. Unknown internal
# files are never modified; failures leave Factory in place so the next boot
# returns here instead of falling through to vendor services.

MODEL=y28ga
EXPECTED_HOMEVER='9.0.20.06_202007061841'
EXPECTED_LEGACY_INIT_MD5='aac66b89b51ddc460e44cf4bb1b4f77b'
LOCAL_INIT=/tmp/sd/Factory/local_init.sh
RESULT=/tmp/sd/hack_result.txt
BACKUP_DIR=/tmp/sd/backup
REMOVED_DIR=$BACKUP_DIR/local-only-removed
MIN_BACKUP_FREE_KIB=128

fail_closed()
{
    echo "Local-only install failed: $*" > "$RESULT"
    echo "yi-hack: local-only install failed: $*" > /dev/console
    sync
    exit 1
}

md5_file()
{
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

# The audit archive contains the previous yi-hack init, after its installer
# removed the stock lower-half call and appended telnet/lower-half dispatch.
# Normalize a pristine init in /tmp through that exact historical transform;
# matching the audited result proves the input is the supported predecessor
# without modifying flash or guessing an unaudited stock hash.
legacy_normalized_md5()
{
    audit=/tmp/yi-hack-legacy-init.$$
    cp /backup/init.sh "$audit" || return 1
    sed -n '1{$!N;$!N;$!N;$!N};$!N;s@\nif \[ \-f \/home\/app\/lower_half_init.sh \];then\n    source \/home\/app\/lower_half_init.sh\nelse\n    source \/backup\/lower_half_init.sh\nfi@@;P;D' -i "$audit" || { rm -f "$audit"; return 1; }
    sed -n '1{$!N;$!N;$!N;$!N};$!N;s@\nif \[ \-f \/home\/app\/lower_half_init.sh \];then\n\tsource \/home\/app\/lower_half_init.sh\nelse\n\tsource \/backup\/lower_half_init.sh\nfi@@;P;D' -i "$audit" || { rm -f "$audit"; return 1; }
    sed -e 's/^source \/home\/app\/lower_half_init.sh//g' -i "$audit" || { rm -f "$audit"; return 1; }
    {
        echo "# Running telnetd"
        echo "/usr/sbin/telnetd &"
        echo ""
        echo "if [ -f /tmp/sd/lower_half_init.sh ];then"
        echo "    source /tmp/sd/lower_half_init.sh"
        echo "elif [ -f /home/app/lower_half_init.sh ];then"
        echo "    source /home/app/lower_half_init.sh"
        echo "else"
        echo "    source /backup/lower_half_init.sh"
        echo "fi"
    } >> "$audit" || { rm -f "$audit"; return 1; }
    digest=$(md5_file "$audit")
    rm -f "$audit"
    echo "$digest"
}

verify_or_absent()
{
    path=$1
    expected=$2
    [ -e "$path" ] || return 0
    got=$(md5_file "$path")
    [ "$got" = "$expected" ] || fail_closed "unexpected $path ($got)"
}

preserve_file()
{
    path=$1
    expected=$2
    label=$3
    [ -e "$path" ] || return 0
    verify_or_absent "$path" "$expected"
    mkdir -p "$REMOVED_DIR" || fail_closed "cannot create recovery directory"
    cp "$path" "$REMOVED_DIR/$label" || fail_closed "cannot preserve $path"
    [ "$(md5_file "$REMOVED_DIR/$label")" = "$expected" ] || fail_closed "recovery copy mismatch: $path"
}

remove_verified()
{
    path=$1
    expected=$2
    [ -e "$path" ] || return 0
    verify_or_absent "$path" "$expected"
    rm -f "$path" || fail_closed "cannot remove disabled $path"
}

configure_wifi_if_requested()
{
    if [ -e /tmp/sd/Factory/configure_wifi.cfg ]; then
        /tmp/sd/Factory/configure_wifi.sh || fail_closed "Wi-Fi configuration failed"
    fi
}

finish_install()
{
    echo "Local-only install completed successfully" > "$RESULT"
    rm -rf /tmp/sd/Factory.done
    mv /tmp/sd/Factory /tmp/sd/Factory.done || fail_closed "cannot retire Factory trigger"
    sync
    sync
    sync
    reboot
    exit 0
}

[ "$(cat /home/homever 2>/dev/null)" = "$EXPECTED_HOMEVER" ] || fail_closed "unsupported firmware"
[ "$(cat /tmp/sd/yi-hack/model_suffix 2>/dev/null)" = "$MODEL" ] || fail_closed "wrong model payload"
[ -s "$LOCAL_INIT" ] || fail_closed "missing generated bootstrap"
/bin/sh -n "$LOCAL_INIT" || fail_closed "invalid generated bootstrap"
LOCAL_INIT_MD5=$(md5_file "$LOCAL_INIT")
[ -n "$LOCAL_INIT_MD5" ] || fail_closed "cannot hash generated bootstrap"

CURRENT_INIT_MD5=$(md5_file /backup/init.sh)
if [ "$CURRENT_INIT_MD5" = "$LOCAL_INIT_MD5" ]; then
    configure_wifi_if_requested
    finish_install
fi
if [ "$CURRENT_INIT_MD5" != "$EXPECTED_LEGACY_INIT_MD5" ]; then
    NORMALIZED_INIT_MD5=$(legacy_normalized_md5) || fail_closed "cannot audit /backup/init.sh"
    [ "$NORMALIZED_INIT_MD5" = "$EXPECTED_LEGACY_INIT_MD5" ] || fail_closed "unknown /backup/init.sh ($CURRENT_INIT_MD5)"
fi

# Validate every file that may be reclaimed before writing recovery data.
verify_or_absent /backup/lower_half_init.sh a9d297fcc801efac89c1f11d6214f9e5
verify_or_absent /backup/tools/upgrade.sh 65a65c9d63dab9540dcd8b2ea012d477
verify_or_absent /backup/tools/upgrade_firmware 0aa30bcf2c6fdf39794841aa8d999f7b
verify_or_absent /backup/tools/extpkg.sh 8cc192c260b237e3d0ccfd05d77e3693
verify_or_absent /backup/tools/rsa_pub_dec 8dfa7388b38d978a85c2ffee7c843c8d

# Preserve the complete current flash and predecessor init before any requested
# Wi-Fi change or JFFS2 deletion.
mkdir -p "$BACKUP_DIR/mtd" "$REMOVED_DIR" || fail_closed "cannot create SD recovery directory"
cat /proc/mtd > "$BACKUP_DIR/mtd.txt" || fail_closed "cannot save MTD map"
for n in 0 1 2 3 4 5 6 7; do
    [ -e "/dev/mtdblock$n" ] || continue
    dd if="/dev/mtdblock$n" of="$BACKUP_DIR/mtd/mtdblock$n.bin" bs=65536 2>/dev/null || fail_closed "MTD backup failed: $n"
done
cp /home/homever "$BACKUP_DIR/homever.txt" || fail_closed "cannot preserve homever"
cp /backup/init.sh "$BACKUP_DIR/init.pre-local-only.sh" || fail_closed "cannot preserve predecessor init"
[ "$(md5_file "$BACKUP_DIR/init.pre-local-only.sh")" = "$CURRENT_INIT_MD5" ] || fail_closed "predecessor init recovery copy mismatch"
preserve_file /backup/lower_half_init.sh a9d297fcc801efac89c1f11d6214f9e5 backup_lower_half_init.sh
preserve_file /backup/tools/upgrade.sh 65a65c9d63dab9540dcd8b2ea012d477 backup_tools_upgrade.sh
preserve_file /backup/tools/upgrade_firmware 0aa30bcf2c6fdf39794841aa8d999f7b backup_tools_upgrade_firmware
preserve_file /backup/tools/extpkg.sh 8cc192c260b237e3d0ccfd05d77e3693 backup_tools_extpkg.sh
preserve_file /backup/tools/rsa_pub_dec 8dfa7388b38d978a85c2ffee7c843c8d backup_tools_rsa_pub_dec

# Apply user-requested Wi-Fi changes before deleting updater components or
# activating the new init, so a configuration failure remains safely retryable.
configure_wifi_if_requested

# These are vendor firmware-update components already masked by the hardened
# bootstrap. All present copies were preserved and verified above before the
# first deletion. Reclaiming them creates the JFFS2 GC headroom needed to stage
# the larger fail-closed init safely.
remove_verified /backup/lower_half_init.sh a9d297fcc801efac89c1f11d6214f9e5
remove_verified /backup/tools/upgrade.sh 65a65c9d63dab9540dcd8b2ea012d477
remove_verified /backup/tools/upgrade_firmware 0aa30bcf2c6fdf39794841aa8d999f7b
remove_verified /backup/tools/extpkg.sh 8cc192c260b237e3d0ccfd05d77e3693
remove_verified /backup/tools/rsa_pub_dec 8dfa7388b38d978a85c2ffee7c843c8d
sync

FREE_KIB=$(df -k /backup 2>/dev/null | awk 'NR==2 {print $4}')
case "$FREE_KIB" in ''|*[!0-9]*) fail_closed "cannot determine /backup free space" ;; esac
[ "$FREE_KIB" -ge "$MIN_BACKUP_FREE_KIB" ] || fail_closed "/backup has only $FREE_KIB KiB free"

rm -f /backup/init.sh.local-new
cp "$LOCAL_INIT" /backup/init.sh.local-new || fail_closed "cannot stage hardened init"
[ "$(md5_file /backup/init.sh.local-new)" = "$LOCAL_INIT_MD5" ] || fail_closed "staged init hash mismatch"
/bin/sh -n /backup/init.sh.local-new || fail_closed "staged init syntax failure"
chmod 755 /backup/init.sh.local-new || fail_closed "cannot chmod staged init"
sync
mv /backup/init.sh.local-new /backup/init.sh || fail_closed "cannot activate hardened init"
sync
[ "$(md5_file /backup/init.sh)" = "$LOCAL_INIT_MD5" ] || fail_closed "installed init hash mismatch"
/bin/sh -n /backup/init.sh || fail_closed "installed init syntax failure"

finish_install
