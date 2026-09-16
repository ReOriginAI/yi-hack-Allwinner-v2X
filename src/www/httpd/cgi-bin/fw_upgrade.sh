#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin:/home/base/tools:/home/app/localbin:/home/base:/tmp/sd/yi-hack/bin:/tmp/sd/yi-hack/sbin:/tmp/sd/yi-hack/usr/bin:/tmp/sd/yi-hack/usr/sbin
export LD_LIBRARY_PATH=/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/tmp/sd:/tmp/sd/gdb:/tmp/sd/yi-hack/lib

YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
SD_ROOT=${YI_HACK_SD_ROOT:-/tmp/sd}
BACKUP_ROOT=${YI_HACK_BACKUP_ROOT:-/backup}
REBOOT_CMD=${YI_HACK_REBOOT_CMD:-reboot}
MIN_BACKUP_FREE_KIB=128

. "$YI_HACK_PREFIX/www/cgi-bin/validate.sh"

if ! $(validateQueryString "$QUERY_STRING"); then
    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":true,"description":"Invalid query string"}'
    exit 1
fi

NAME=$(echo "$QUERY_STRING" | cut -d'=' -f1)
VAL=$(echo "$QUERY_STRING" | cut -d'=' -f2)

[ "$NAME" = "get" ] || exit 1

MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null | tr -d '\r\n')
FW_VERSION=$(cat "$YI_HACK_PREFIX/version" 2>/dev/null | tr -d '\r\n')
LOCAL_FW="$SD_ROOT/${MODEL_SUFFIX}_x.x.x.tgz"

case "$MODEL_SUFFIX" in ''|*[!A-Za-z0-9_-]*) exit 1 ;; esac
case "$FW_VERSION" in ''|*[!A-Za-z0-9._-]*) exit 1 ;; esac

if [ "$VAL" = "info" ]; then
    if [ -f "$LOCAL_FW" ]; then
        LOCAL_FW_PRESENT=true
    else
        LOCAL_FW_PRESENT=false
    fi

    printf "Content-type: application/json\r\n\r\n"
    printf '{"error":false,"fw_version":"%s","local_fw":%s}' "$FW_VERSION" "$LOCAL_FW_PRESENT"
    exit 0
fi

[ "$VAL" = "upgrade" ] || exit 1

printf "Content-type: text/plain\r\n\r\n"

STAGE="$SD_ROOT/.fw_upgrade.atomic"
LIST_TMP="$SD_ROOT/.fw_upgrade.atomic.list"
MANIFEST="$SD_ROOT/.fw_upgrade.atomic.md5"
LOCKDIR="$SD_ROOT/.fw_upgrade.atomic.lock.d"
ROLLBACK_TREE="$SD_ROOT/yi-hack.pre-web-$FW_VERSION"
ROLLBACK_INIT="$SD_ROOT/.init.pre-web-$FW_VERSION"
FAILED_TREE="$SD_ROOT/yi-hack.failed-upgrade"
INIT_NEW="$BACKUP_ROOT/init.sh.web-new"

old_moved=0
new_moved=0
init_installed=0

rollback()
{
    set +e
    if [ "$init_installed" -eq 1 ] && [ -s "$ROLLBACK_INIT" ]; then
        cp "$ROLLBACK_INIT" "$BACKUP_ROOT/init.sh"
        chmod 755 "$BACKUP_ROOT/init.sh"
    fi
    if [ "$new_moved" -eq 1 ] && [ -e "$YI_HACK_PREFIX" ]; then
        rm -rf "$FAILED_TREE"
        mv "$YI_HACK_PREFIX" "$FAILED_TREE"
    fi
    if [ "$old_moved" -eq 1 ] && [ -e "$ROLLBACK_TREE" ]; then
        mv "$ROLLBACK_TREE" "$YI_HACK_PREFIX"
    fi
    rm -f "$INIT_NEW" "$ROLLBACK_INIT"
    sync
}

cleanup()
{
    rm -f "$LIST_TMP" "$MANIFEST"
    rm -f "$LOCKDIR/pid" 2>/dev/null
    rmdir "$LOCKDIR" 2>/dev/null
}

on_exit()
{
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ]; then
        rollback
    fi
    cleanup
    exit "$rc"
}
trap on_exit EXIT HUP INT TERM

die()
{
    printf 'Firmware upgrade failed: %s\n' "$1"
    exit 1
}

[ -f "$LOCAL_FW" ] || die "no uploaded firmware is staged"
[ -d "$SD_ROOT" ] || die "SD card is not available"
[ -d "$BACKUP_ROOT" ] || die "internal backup partition is not available"
[ -s "$BACKUP_ROOT/init.sh" ] || die "current bootstrap is missing"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    case "$OLD_PID" in ''|*[!0-9]*) OLD_PID=0 ;; esac
    if [ "$OLD_PID" -gt 1 ] && [ -d "/proc/$OLD_PID" ]; then
        die "another firmware upgrade is already running"
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || die "unable to acquire upgrade lock"
fi
echo $$ > "$LOCKDIR/pid"

FREE_SD=$(df -k "$SD_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')
case "$FREE_SD" in ''|*[!0-9]*) die "unable to determine free SD space" ;; esac
[ "$FREE_SD" -ge 100000 ] || die "not enough free SD space for upgrade staging"

FREE_BACKUP=$(df -k "$BACKUP_ROOT" 2>/dev/null | awk 'NR == 2 {print $4}')
case "$FREE_BACKUP" in ''|*[!0-9]*) die "unable to determine internal free space" ;; esac
[ "$FREE_BACKUP" -ge "$MIN_BACKUP_FREE_KIB" ] || die "internal free space is below 128 KiB"

[ ! -e "$ROLLBACK_TREE" ] || die "rollback tree already exists: $ROLLBACK_TREE"
[ ! -e "$ROLLBACK_INIT" ] || die "rollback bootstrap already exists: $ROLLBACK_INIT"

gzip -t "$LOCAL_FW" >/dev/null 2>&1 || die "uploaded firmware is not a valid gzip archive"
tar tzf "$LOCAL_FW" > "$LIST_TMP" 2>/dev/null || die "uploaded firmware is not a valid tar archive"
tar tvzf "$LOCAL_FW" 2>/dev/null | awk 'BEGIN { bad=0 } { t=substr($1,1,1); if (t != "-" && t != "d") bad=1 } END { exit bad }' || die "firmware archive contains links or special files"

awk '
BEGIN { bad=0; seen=0 }
{
    p=$0
    sub(/^\.\//, "", p)
    if (p == "" || p ~ /^\// || p ~ /(^|\/)\.\.(\/|$)/ || p ~ /\\/) bad=1
    split(p, a, "/")
    if (a[1] != "Factory" && a[1] != "lower_half_init.sh" && a[1] != "yi-hack") bad=1
    seen=1
}
END { if (!seen || bad) exit 1; exit 0 }
' "$LIST_TMP" || die "firmware archive contains unsafe or unexpected paths"

grep -qx 'yi-hack/model_suffix' "$LIST_TMP" || die "firmware is missing model metadata"
grep -qx 'yi-hack/version' "$LIST_TMP" || die "firmware is missing version metadata"
grep -qx 'Factory/local_init.sh' "$LIST_TMP" || die "firmware is missing the local-only bootstrap"

ARCHIVE_MODEL=$(tar xOzf "$LOCAL_FW" yi-hack/model_suffix 2>/dev/null | tr -d '\r\n')
ARCHIVE_VERSION=$(tar xOzf "$LOCAL_FW" yi-hack/version 2>/dev/null | tr -d '\r\n')
case "$ARCHIVE_VERSION" in ''|*[!A-Za-z0-9._-]*) die "firmware version metadata is invalid" ;; esac
[ "$ARCHIVE_MODEL" = "$MODEL_SUFFIX" ] || die "firmware model does not match this camera"

rm -rf "$STAGE" "$FAILED_TREE"
mkdir -p "$STAGE" || die "unable to create upgrade staging directory"
tar xzf "$LOCAL_FW" -C "$STAGE" >/dev/null 2>&1 || die "firmware extraction failed"

NEW_YI="$STAGE/yi-hack"
NEW_INIT="$STAGE/Factory/local_init.sh"
[ -s "$NEW_YI/model_suffix" ] || die "staged payload is incomplete"
[ -s "$NEW_INIT" ] || die "staged bootstrap is missing"
/bin/sh -n "$NEW_INIT" || die "staged bootstrap has invalid syntax"
[ "$(cat "$NEW_YI/model_suffix")" = "$MODEL_SUFFIX" ] || die "staged model mismatch"
[ "$(cat "$NEW_YI/version")" = "$ARCHIVE_VERSION" ] || die "staged version mismatch"

grep -E '^[0-9a-f]{32}  [^ /][^ ]*$' "$NEW_INIT" > "$MANIFEST" || die "unable to extract bootstrap manifest"
MANIFEST_LINES=$(awk 'END {print NR}' "$MANIFEST")
case "$MANIFEST_LINES" in ''|*[!0-9]*) die "bootstrap manifest is invalid" ;; esac
[ "$MANIFEST_LINES" -ge 10 ] || die "bootstrap manifest is incomplete"
(cd "$NEW_YI" && md5sum -c "$MANIFEST" >/dev/null 2>&1) || die "staged payload does not match bootstrap manifest"

mkdir -p "$NEW_YI/etc" || die "unable to prepare staged configuration"
if [ -d "$YI_HACK_PREFIX/etc" ]; then
    cp -rf "$YI_HACK_PREFIX"/etc/* "$NEW_YI/etc/" || die "unable to preserve current configuration"
fi
rm -f "$NEW_YI/etc/"*.tar.gz

cp "$BACKUP_ROOT/init.sh" "$ROLLBACK_INIT" || die "unable to preserve current bootstrap"
[ -s "$ROLLBACK_INIT" ] || die "bootstrap rollback copy is empty"

NEW_INIT_MD5=$(md5sum "$NEW_INIT" | awk '{print $1}')
rm -f "$INIT_NEW"
cp "$NEW_INIT" "$INIT_NEW" || die "unable to stage new bootstrap"
chmod 755 "$INIT_NEW" || die "unable to chmod new bootstrap"
/bin/sh -n "$INIT_NEW" || die "new bootstrap has invalid syntax"
[ "$(md5sum "$INIT_NEW" | awk '{print $1}')" = "$NEW_INIT_MD5" ] || die "new bootstrap hash mismatch"

sync

mv "$YI_HACK_PREFIX" "$ROLLBACK_TREE" || die "unable to preserve current yi-hack tree"
old_moved=1
mv "$NEW_YI" "$YI_HACK_PREFIX" || die "unable to activate new yi-hack tree"
new_moved=1

[ "$(cat "$YI_HACK_PREFIX/model_suffix")" = "$MODEL_SUFFIX" ] || die "active model mismatch"
[ "$(cat "$YI_HACK_PREFIX/version")" = "$ARCHIVE_VERSION" ] || die "active version mismatch"
(cd "$YI_HACK_PREFIX" && md5sum -c "$MANIFEST" >/dev/null 2>&1) || die "active payload does not match bootstrap manifest"

mv "$INIT_NEW" "$BACKUP_ROOT/init.sh" || die "unable to activate new bootstrap"
init_installed=1
[ "$(md5sum "$BACKUP_ROOT/init.sh" | awk '{print $1}')" = "$NEW_INIT_MD5" ] || die "active bootstrap hash mismatch"
/bin/sh -n "$BACKUP_ROOT/init.sh" || die "active bootstrap has invalid syntax"

# A WebUI upgrade has already activated the matching yi-hack tree and bootstrap.
# Any Factory trigger that predates this upgrade is therefore stale; leaving it
# active would make the new bootstrap execute an installer from the old release
# before networking starts. Preserve it under a non-triggering name instead.
if [ -e "$SD_ROOT/Factory" ]; then
    RETIRED_FACTORY="$SD_ROOT/Factory.retired-web-$ARCHIVE_VERSION"
    rm -rf "$RETIRED_FACTORY" || die "unable to clear previous retired Factory tree"
    mv "$SD_ROOT/Factory" "$RETIRED_FACTORY" || die "unable to retire stale Factory trigger"
fi

rm -f "$LOCAL_FW"
rm -rf "$STAGE"
sync
sync
sync

printf 'Firmware activated (%s); rebooting.\n' "$ARCHIVE_VERSION"

trap - EXIT HUP INT TERM
cleanup
(sleep 1; "$REBOOT_CMD") >/dev/null 2>&1 &
exit 0
