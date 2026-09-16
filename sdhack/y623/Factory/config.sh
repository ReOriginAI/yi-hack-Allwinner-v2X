#!/bin/sh
# SD Factory installer for y623. A release extracted to SD is treated as a
# complete install: validate the package, preserve recovery copies, provision
# Wi-Fi if requested, install the matching /backup/init.sh, retire Factory, reboot.

MODEL=y623
EXPECTED_HOMEVER='12.0.51.01_202303091901'
LOCAL_INIT=/tmp/sd/Factory/local_init.sh
RESULT=/tmp/sd/hack_result.txt
BACKUP_DIR=/tmp/sd/backup
RECLAIM_DIR=$BACKUP_DIR/reclaimed
MIN_BACKUP_FREE_KIB=128
RECLAIM_PATHS='/backup/tools/upgrade.sh /backup/tools/extpkg.sh /backup/tools/rsa_pub_dec'

install_fail()
{
    echo "Install failed: $*" > "$RESULT"
    echo "yi-hack: install failed: $*" > /dev/console
    sync
    exit 1
}

md5_file()
{
    md5sum "$1" 2>/dev/null | awk '{print $1}'
}

preserve_once()
{
    src=$1
    dst=$2
    [ -e "$src" ] || return 0
    [ -e "$dst" ] && return 0
    cp "$src" "$dst" || install_fail "cannot preserve $src"
}

configure_wifi_if_requested()
{
    if [ -e /tmp/sd/Factory/configure_wifi.cfg ]; then
        /tmp/sd/Factory/configure_wifi.sh || install_fail "Wi-Fi configuration failed"
    fi
}

finish_install()
{
    echo "Install completed successfully" > "$RESULT"
    rm -rf /tmp/sd/Factory.done
    mv /tmp/sd/Factory /tmp/sd/Factory.done || install_fail "cannot retire Factory trigger"
    sync
    sync
    sync
    reboot
    exit 0
}

[ "$(cat /home/homever 2>/dev/null)" = "$EXPECTED_HOMEVER" ] || install_fail "unsupported firmware"
[ "$(cat /tmp/sd/yi-hack/model_suffix 2>/dev/null)" = "$MODEL" ] || install_fail "wrong model payload"
[ -s "$LOCAL_INIT" ] || install_fail "missing generated bootstrap"
/bin/sh -n "$LOCAL_INIT" || install_fail "invalid generated bootstrap"
LOCAL_INIT_MD5=$(md5_file "$LOCAL_INIT")
[ -n "$LOCAL_INIT_MD5" ] || install_fail "cannot hash generated bootstrap"

MANIFEST=/tmp/yi-hack-install-manifest.$$
grep -E '^[0-9a-f]{32}  [^ /][^ ]*$' "$LOCAL_INIT" > "$MANIFEST" || install_fail "missing payload manifest"
MANIFEST_LINES=$(awk 'END {print NR}' "$MANIFEST")
case "$MANIFEST_LINES" in ''|*[!0-9]*) rm -f "$MANIFEST"; install_fail "invalid payload manifest" ;; esac
[ "$MANIFEST_LINES" -ge 10 ] || { rm -f "$MANIFEST"; install_fail "incomplete payload manifest"; }
(cd /tmp/sd/yi-hack && md5sum -c "$MANIFEST" >/dev/null 2>&1) || { rm -f "$MANIFEST"; install_fail "SD payload does not match bootstrap"; }
rm -f "$MANIFEST"

CURRENT_INIT_MD5=$(md5_file /backup/init.sh)
if [ "$CURRENT_INIT_MD5" = "$LOCAL_INIT_MD5" ]; then
    configure_wifi_if_requested
    finish_install
fi

mkdir -p "$BACKUP_DIR/mtd" "$RECLAIM_DIR" || install_fail "cannot create recovery directory"
cat /proc/mtd > "$BACKUP_DIR/mtd.txt" || install_fail "cannot save MTD map"
for n in 0 1 2 3 4 5 6 7; do
    [ -e "/dev/mtdblock$n" ] || continue
    if [ ! -s "$BACKUP_DIR/mtd/mtdblock$n.bin" ]; then
        dd if="/dev/mtdblock$n" of="$BACKUP_DIR/mtd/mtdblock$n.bin" bs=65536 2>/dev/null || install_fail "MTD backup failed: $n"
    fi
done
cp /home/homever "$BACKUP_DIR/homever.txt" || install_fail "cannot preserve homever"
if [ -s /backup/init.sh ]; then
    [ -n "$CURRENT_INIT_MD5" ] || install_fail "cannot hash current init"
    preserve_once /backup/init.sh "$BACKUP_DIR/init.$CURRENT_INIT_MD5.sh"
fi

# Stock /backup is almost full. Preserve these unused vendor updater components
# to SD, then reclaim their JFFS2 space so the replacement init can be staged.
for path in $RECLAIM_PATHS; do
    [ -e "$path" ] || continue
    label=$(echo "$path" | sed 's#^/##; s#/#_#g')
    preserve_once "$path" "$RECLAIM_DIR/$label"
done

configure_wifi_if_requested

for path in $RECLAIM_PATHS; do
    [ -e "$path" ] || continue
    rm -f "$path" || install_fail "cannot reclaim $path"
done
sync

FREE_KIB=$(df -k /backup 2>/dev/null | awk 'NR==2 {print $4}')
case "$FREE_KIB" in ''|*[!0-9]*) install_fail "cannot determine /backup free space" ;; esac
[ "$FREE_KIB" -ge "$MIN_BACKUP_FREE_KIB" ] || install_fail "/backup has only $FREE_KIB KiB free"

rm -f /backup/init.sh.local-new
cp "$LOCAL_INIT" /backup/init.sh.local-new || install_fail "cannot stage new init"
[ "$(md5_file /backup/init.sh.local-new)" = "$LOCAL_INIT_MD5" ] || install_fail "staged init hash mismatch"
/bin/sh -n /backup/init.sh.local-new || install_fail "staged init syntax failure"
chmod 755 /backup/init.sh.local-new || install_fail "cannot chmod staged init"
sync
mv /backup/init.sh.local-new /backup/init.sh || install_fail "cannot activate new init"
sync
[ "$(md5_file /backup/init.sh)" = "$LOCAL_INIT_MD5" ] || install_fail "installed init hash mismatch"
/bin/sh -n /backup/init.sh || install_fail "installed init syntax failure"

finish_install