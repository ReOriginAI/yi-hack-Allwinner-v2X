#!/bin/sh
# Runs through the stock SD lower-half hook; root/home writes happen in U-Boot.
SD=/tmp/sd
P=$SD/flash-core
R=$SD/flash-core-recovery
B=/backup
ROLLBACK_READY=no
rollback_uncommitted() {
    [ "$ROLLBACK_READY" = yes ] && [ ! -e "$B/flash-core-install.pending" ] || return 1
    if [ "${CLEAN:-no}" = yes ]; then
        stock_root && stock_home || return 1
        : > "$R/RESTORE" || return 1
        exec /bin/sh "$P/dispatcher.sh"
    fi
    [ "$(hash "$B/init.sh")" = "$(hash "$R/files/init.sh")" ] || return 1
    stock_root && stock_home || return 1
    [ "$(hash /dev/mtdblock6)" = "$(hash "$R/mtd/mtdblock6.bin")" ] || return 1
    (cd "$R" && md5sum -c checksums.md5 >/dev/null 2>&1) || return 1
    # Only the new paths checked absent before staging may be retired. Keep the
    # original startup/identity untouched and preserve staged settings on SD.
    if [ -d "$SD/yi-hack-config" ]; then
        mv "$SD/yi-hack-config" "$R/failed-settings" || return 1
    fi
    rm -rf "$B/yi-hack-config"
    rm -f "$B/flash-core-init.sh.new" "$B/flash-core-original-init.sh" "$B/init.sh.new"
    for f in upgrade.sh upgrade_firmware extpkg.sh rsa_pub_dec mem_update_pack.sh update_homefs.sh; do
        saved="$R/files/tools_$f"
        [ ! -f "$saved" ] || cp "$saved" "$B/tools/$f" || return 1
    done
    [ ! -e "$SD/lower_half_init.sh" ] || mv "$SD/lower_half_init.sh" "$P/lower_half_init.failed" || return 1
    [ ! -e "$SD/Factory/factory_test.sh" ] || mv "$SD/Factory/factory_test.sh" "$P/factory_test.failed" || return 1
    printf '\nPrevious firmware/startup retained; failed installer retired.\n' >> "$SD/hack_result.txt"
    sync
    /bin/busybox reboot -f
}
fail() {
    echo "Flash-core install failed: $*. See RECOVERY.txt." > "$SD/hack_result.txt"
    rollback_uncommitted || true
    sync
    exit 1
}
restart() {
    # No capture processes have started. Flush staged updates and invoke the
    # kernel directly; plain reboot only signals vendor PID 1 and may stall.
    sync
    /bin/busybox reboot -f || fail 'automatic reboot failed; power off and reinsert this same card before powering on'
    exit 0
}
. "$P/install.conf" || fail metadata
hash() { md5sum "$1" | awk '{print $1}'; }
[ "$(cat /home/homever)" = "$HOMEVER" ] || fail 'wrong model/vendor firmware'
(cd "$SD" && md5sum -c flash-core/files.md5 >/dev/null 2>&1) || fail 'package checksum'
# Exact audited partition layout. Do not accept another camera with the same version string.
for item in '0:00060000' '1:001d0000' '2:00120000' '3:00340000' '4:00130000' '5:00020000' '6:00010000' '7:00010000'; do
    n=${item%:*}; size=${item#*:}
    grep -q "^mtd$n: $size 00001000 " /proc/mtd || fail 'unsupported flash layout'
done
# Recovery is also available before the internal dispatcher was activated.
if [ -f "$R/RESTORE" ]; then
    exec /bin/sh "$P/dispatcher.sh"
fi
live_image() { dd if="/dev/mtdblock$1" bs=4096 count="$2" 2>/dev/null | md5sum | awk '{print $1}'; }
stock_root() { [ "$(live_image 2 "$ROOT_STOCK_BLOCKS")" = "$ROOT_STOCK_PREFIX" ]; }
stock_home() { [ "$(live_image 3 "$HOME_STOCK_BLOCKS")" = "$HOME_STOCK_PREFIX" ]; }
# --prepare-clean is safe to invoke on a running older flash-core camera: only
# backups and a reboot dispatcher are staged here. Bound config trees are reset
# on the following boot, before capture/network services start.
if [ "${1:-}" = --prepare-clean ]; then
    [ -f /home/yi-hack/flash-core ] && [ "$(cat /home/yi-hack/model_suffix)" = "$MODEL" ] || fail 'clean reinstall requires matching installed flash-core'
    [ -s "$B/flash-core-init.sh" ] && [ -s "$B/flash-core-original-init.sh" ] || fail 'missing previous flash-core startup'
    [ ! -e "$B/flash-core-install.pending" ] && [ ! -e "$R" ] || fail 'preserve previous recovery directory and use a clean card'
    [ ! -e "$SD/yi-hack-config" ] || fail 'clean reinstall needs a clean card'
    [ ! -e "$B/init.sh.new" ] && [ ! -e "$B/flash-core-init.sh.new" ] || fail 'previous startup staging detected'
    for part in rootfs home backup uboot; do [ ! -e "$SD/${part}_$MODEL" ] || fail 'another flash trigger is present'; done
    free=$(df -k "$SD" | awk 'NR==2 {print $4}')
    case "$free" in ''|*[!0-9]*) fail 'cannot measure SD space';; esac
    [ "$free" -ge 32768 ] || fail 'SD needs at least 32 MiB free'
    if [ "$MODEL" = y623 ]; then
        awk -v sd="$SD" '$2==sd && $3=="vfat" && ($1=="/dev/mmcblk0p1" || $1=="/dev/block/mmcblk0p1") {ok=1} END {exit !ok}' /proc/mounts || fail 'y623 requires FAT32 partition 1'
        MODEL_SUFFIX=y623 YI_HACK_PREFIX="$P/setup" YI_HACK_PATCHED_BOOT_IMAGE="$P/boot-vmalloc.bin" /bin/sh "$P/setup/script/ensure_y623_ve_kernel.sh" --check || fail 'unsupported kernel'
    fi
    umask 077
    mkdir "$R" || fail 'another clean preparation is running'
    mkdir "$R/mtd" "$R/files" || fail 'create clean recovery'
    for n in 0 1 2 3 4 5 6 7; do
        dd if="/dev/mtdblock$n" of="$R/mtd/mtdblock$n.bin" bs=65536 2>/dev/null || fail 'backup partition'
        [ "$(hash "$R/mtd/mtdblock$n.bin")" = "$(hash /dev/mtdblock$n)" ] || fail 'backup verification'
    done
    cp "$B/init.sh" "$R/files/init.sh" || fail 'backup dispatcher'
    tar cf "$R/files/previous-core.tar" -C "$B" flash-core-init.sh flash-core-original-init.sh yi-hack-config || fail 'backup previous settings/startup'
    tar cf "$R/files/backup-files.tar" -C "$B" . || fail 'backup writable files'
    printf "CLEAN_RELEASE='%s'\n" "$RELEASE_ID" > "$R/clean.conf" || fail 'clean journal'
    for item in rootfs:2:ROOT home:3:HOME; do
        part=${item%%:*}; rest=${item#*:}; n=${rest%%:*}; key=${rest#*:}
        blocks=$("$P/clean-image" "$R/mtd/mtdblock$n.bin" "$part" "$R/files/${part}.restore") || fail 'unsupported original SquashFS'
        digest=$(live_image "$n" "$blocks")
        printf "%s_STOCK_BLOCKS='%s'\n%s_STOCK_PREFIX='%s'\n" "$key" "$blocks" "$key" "$digest" >> "$R/clean.conf" || fail 'original image journal'
    done
    (cd "$R" && md5sum mtd/*.bin files/* clean.conf > checksums.md5) || fail 'clean backup manifest'
    (cd "$R" && md5sum -c checksums.md5 >/dev/null 2>&1) || fail 'clean backup verification'
    free=$(df -k "$B" | awk 'NR==2 {print $4}')
    case "$free" in ''|*[!0-9]*) fail 'cannot measure internal space';; esac
    [ "$free" -ge 144 ] || fail 'less than 128 KiB reserve plus activation space'
    cp "$P/dispatcher.sh" "$B/init.sh.new" || fail 'stage clean entry'
    [ "$(hash "$B/init.sh.new")" = "$(hash "$P/dispatcher.sh")" ] || fail 'clean entry verification'
    sh -n "$B/init.sh.new" || fail 'clean entry syntax'
    chmod 755 "$B/init.sh.new"
    printf 'reset-to-hotspot\n' > "$P/CLEAN_INSTALL" || fail 'clean request'
    sync
    mv "$B/init.sh.new" "$B/init.sh" || fail 'activate clean entry'
    restart
fi
CLEAN=no
if [ -f "$R/clean.conf" ]; then
    [ -s "$R/mtd/mtdblock6.bin" ] && [ "$(hash "$R/mtd/mtdblock6.bin")" = "$(hash /dev/mtdblock6)" ] || fail 'clean recovery identity'
    (cd "$R" && md5sum -c checksums.md5 >/dev/null 2>&1) || fail 'clean recovery checksum'
    . "$R/clean.conf"
    [ "$CLEAN_RELEASE" = "$RELEASE_ID" ] || fail 'different clean installation'
    CLEAN=yes
    ROLLBACK_READY=yes
fi
if [ -f "$B/flash-core-install.pending" ]; then
    [ "$(cat "$B/flash-core-install.pending")" = "$RELEASE_ID" ] || fail 'different pending installation'
    [ -s "$R/mtd/mtdblock6.bin" ] && [ "$(hash "$R/mtd/mtdblock6.bin")" = "$(hash /dev/mtdblock6)" ] || fail 'recovery card belongs to another camera'
    # Power can fail between committing the journal and renaming the dispatcher.
    if [ "$(hash "$B/init.sh")" != "$(hash "$P/dispatcher.sh")" ]; then
        current=$(hash "$B/init.sh")
        [ "$current" = "$(hash "$R/files/init.sh")" ] ||
        { [ -n "${PREVIOUS_DISPATCH_HASH:-}" ] && [ "$current" = "$PREVIOUS_DISPATCH_HASH" ]; } || fail 'unknown pending startup'
        cp "$P/dispatcher.sh" "$B/init.sh.new" || fail 'resume dispatcher staging'
        [ "$(hash "$B/init.sh.new")" = "$(hash "$P/dispatcher.sh")" ] || fail 'resume dispatcher checksum'
        chmod 755 "$B/init.sh.new"
        sync
        mv "$B/init.sh.new" "$B/init.sh" || fail 'resume dispatcher activation'
        sync
    fi
    if [ "$(live_image 2 "$ROOT_BLOCKS")" = "$ROOT_NEW" ] && [ "$(live_image 3 "$HOME_BLOCKS")" = "$HOME_NEW" ]; then
        # Verify the installed payload before retiring update triggers.
        [ "$(hash /backup/flash-core-init.sh)" = "$INIT_HASH" ] || fail 'bootstrap mismatch'
        for part in rootfs home; do rm -f "$SD/${part}_$MODEL"; done
        if [ -e "$SD/lower_half_init.sh" ]; then
            mv "$SD/lower_half_init.sh" "$P/lower_half_init.installed" || fail 'retire SD hook'
        fi
        if [ -e "$SD/Factory/factory_test.sh" ]; then
            mv "$SD/Factory/factory_test.sh" "$P/factory_test.installed" || fail 'retire Factory trigger'
        fi
        rm -f "$B/flash-core-install.pending"
        echo 'Flash-core images verified. Starting camera; keep SD inserted until startup finishes.' > "$SD/hack_result.txt"
        restart
    fi
    # A partial update may be resumed only against originals or these exact new images.
    stock_root || [ "$(live_image 2 "$ROOT_BLOCKS")" = "$ROOT_NEW" ] || fail 'unknown partial rootfs'
    stock_home || [ "$(live_image 3 "$HOME_BLOCKS")" = "$HOME_NEW" ] || fail 'unknown partial home'
else
    # Recovery flashing can change unused erase padding. Check every byte of
    # the audited filesystem, without depending on those unused tail bytes.
    stock_root || fail 'rootfs is not the supported stock image'
    stock_home || fail 'home is not the supported stock image'
    if [ "$CLEAN" = no ]; then
    [ ! -e "$R" ] || fail 'recovery directory exists; preserve it and use a clean card'
    [ ! -e "$B/flash-core-original-init.sh" ] || fail 'previous flash-core installation detected'
    [ ! -e "$B/flash-core-init.sh.new" ] && [ ! -e "$B/init.sh.new" ] || fail 'previous startup staging detected'
    [ ! -e "$B/yi-hack-config" ] && [ ! -e "$SD/yi-hack-config" ] || fail 'existing configuration directory; use fresh vendor firmware and a clean card'
    [ -s "$B/init.sh" ] && [ ! -e "$B/tools/hostapd" ] || fail 'unsupported writable startup files'
    fi
    for part in rootfs home backup uboot; do [ ! -e "$SD/${part}_$MODEL" ] || fail 'another flash trigger is present'; done
    free=$(df -k "$SD" | awk 'NR==2 {print $4}')
    case "$free" in ''|*[!0-9]*) fail 'cannot measure SD headroom' ;; esac
    [ "$free" -ge 32768 ] || fail 'SD needs at least 32 MiB free for verified backups and updates'
    # The y623 updater tries mmc "0" (partition 1), then mistakenly "0.0"
    # rather than "0:0". Linux can mount whole-device FAT32, but that updater
    # cannot read it. Catch this before backups, settings or flash are changed.
    # y28ga has the correct whole-device fallback and supports either layout.
    if [ "$MODEL" = y623 ] && ! awk -v sd="$SD" '
        $2 == sd && $3 == "vfat" &&
        ($1 == "/dev/mmcblk0p1" || $1 == "/dev/block/mmcblk0p1") {found=1}
        END {exit !found}
    ' /proc/mounts; then
        [ ! -e "$SD/lower_half_init.sh" ] || mv "$SD/lower_half_init.sh" "$P/lower_half_init.failed" || fail 'retire unsupported-card SD hook'
        [ ! -e "$SD/Factory/factory_test.sh" ] || mv "$SD/Factory/factory_test.sh" "$P/factory_test.failed" || fail 'retire unsupported-card Factory trigger'
        echo 'Flash-core install refused: y623 needs FAT32 on SD partition 1 (MBR recommended), not whole-device FAT32. Nothing flashed; previous startup retained. Preserve this card and prepare another compatible card.' > "$SD/hack_result.txt"
        restart
    fi
    # Check network input before modifying persistent storage.
    if [ "$CLEAN" = no ] && [ -f "$SD/Factory/configure_wifi.cfg" ]; then
        YI_HACK_PREFIX="$P/setup" CFG_FILE="$SD/Factory/configure_wifi.cfg" /bin/sh "$P/setup/script/configure_wifi.sh" --check || fail 'invalid network configuration'
    fi
    if [ "$MODEL" = y623 ]; then
        MODEL_SUFFIX=y623 YI_HACK_PREFIX="$P/setup" YI_HACK_PATCHED_BOOT_IMAGE="$P/boot-vmalloc.bin" /bin/sh "$P/setup/script/ensure_y623_ve_kernel.sh" --check || fail 'unsupported kernel'
    fi
    if [ "$CLEAN" = no ]; then
    umask 077
    mkdir -p "$R/mtd" "$R/files" || fail 'create recovery directory'
    for n in 0 1 2 3 4 5 6 7; do
        dd if="/dev/mtdblock$n" of="$R/mtd/mtdblock$n.bin" bs=65536 2>/dev/null || fail "backup partition $n"
        [ "$(hash "$R/mtd/mtdblock$n.bin")" = "$(hash /dev/mtdblock$n)" ] || fail "backup verification $n"
    done
    cp "$B/init.sh" "$R/files/init.sh" || fail 'backup original init'
    tar cf "$R/files/backup-files.tar" -C "$B" . || fail 'backup writable files'
    (cd "$R" && md5sum mtd/*.bin files/* > checksums.md5) || fail 'backup manifest'
    sync
    # Preserve and reclaim only obsolete updater components, as in the SD installer.
    for f in tools/upgrade.sh tools/upgrade_firmware tools/extpkg.sh tools/rsa_pub_dec tools/mem_update_pack.sh tools/update_homefs.sh; do
        [ -f "$B/$f" ] || continue
        name=$(echo "$f" | tr / _)
        cp "$B/$f" "$R/files/$name" || fail 'preserve updater'
        [ "$(hash "$B/$f")" = "$(hash "$R/files/$name")" ] || fail 'verify preserved updater'
        rm -f "$B/$f" || fail 'reclaim updater'
    done
    (cd "$R" && md5sum mtd/*.bin files/* > checksums.md5) || fail 'updated backup manifest'
    fi
    ROLLBACK_READY=yes
    if [ "$CLEAN" = yes ]; then
        rm -rf "$B/yi-hack-config" || fail 'clear old internal settings'
    else
    cp "$R/files/init.sh" "$B/flash-core-original-init.sh" || fail 'preserve internal init'
    [ "$(hash "$B/flash-core-original-init.sh")" = "$(hash "$R/files/init.sh")" ] || fail 'internal init backup checksum'
    fi
    cp "$P/core-init.sh" "$B/flash-core-init.sh.new" || fail 'stage bootstrap'
    # A new card is required: never overwrite someone else's configuration tree.
    [ ! -e "$SD/yi-hack-config" ] || fail 'existing configuration directory'
    cp -a "$P/setup/etc" "$SD/yi-hack-config" || fail 'stage settings'
    if [ "$CLEAN" = no ] && [ -f "$SD/Factory/configure_wifi.cfg" ]; then
        YI_HACK_PREFIX="$P/setup" YI_WIFI_SYSTEM_CONF="$SD/yi-hack-config/system.conf" CFG_FILE="$SD/Factory/configure_wifi.cfg" /bin/sh "$P/setup/script/configure_wifi.sh" || fail 'apply network settings'
        mv "$SD/Factory/configure_wifi.cfg" "$SD/Factory/configure_wifi.cfg.applied" || fail 'consume settings'
    fi
    if [ "$CLEAN" = yes ]; then
        sed -i 's/^WIFI_HOTSPOT_BOOT=.*/WIFI_HOTSPOT_BOOT=yes/; s/^WIFI_HOTSPOT_PASSWORD=.*/WIFI_HOTSPOT_PASSWORD=/; s/^WIFI_HOTSPOT_SSID=.*/WIFI_HOTSPOT_SSID=/' "$SD/yi-hack-config/system.conf" || fail 'reset hotspot setup'
        [ ! -f "$SD/Factory/configure_wifi.cfg" ] || mv "$SD/Factory/configure_wifi.cfg" "$SD/Factory/configure_wifi.cfg.ignored-clean" || fail 'retire network override'
    fi
    [ ! -e "$B/yi-hack-config" ] || fail 'existing internal configuration'
    mkdir -p "$B/yi-hack-config" || fail 'internal settings directory'
    for f in "$SD/yi-hack-config"/*.conf "$SD/yi-hack-config"/*.json "$SD/yi-hack-config"/hostname; do
        [ ! -f "$f" ] || cp "$f" "$B/yi-hack-config/" || fail 'internal settings'
    done
    for f in fallback.jpg defaults.tar.bz2 watermark; do ln -s "/home/yi-hack/etc/$f" "$B/yi-hack-config/$f" || fail 'immutable default link'; done
    chmod 755 "$B/flash-core-init.sh.new"
    [ "$(hash "$B/flash-core-init.sh.new")" = "$INIT_HASH" ] || fail 'staged bootstrap checksum'
    free=$(df -k /backup | awk 'NR==2 {print $4}')
    case "$free" in ''|*[!0-9]*) fail 'cannot measure flash headroom' ;; esac
    [ "$free" -ge 144 ] || fail 'less than 128 KiB reserve plus activation space'
    if [ "$MODEL" = y623 ]; then
        MODEL_SUFFIX=y623 YI_HACK_PREFIX="$P/setup" YI_HACK_BOOT_BACKUP="$R/mtd/y623-boot-stock.bin" YI_HACK_PATCHED_BOOT_IMAGE="$P/boot-vmalloc.bin" /bin/sh "$P/setup/script/ensure_y623_ve_kernel.sh" || fail 'kernel update'
    fi
    cp "$P/dispatcher.sh" "$B/init.sh.new" || fail 'stage dispatcher'
    [ "$(hash "$B/init.sh.new")" = "$(hash "$P/dispatcher.sh")" ] || fail 'dispatcher checksum'
    chmod 755 "$B/init.sh.new"
    sh -n "$B/init.sh.new" && sh -n "$B/flash-core-init.sh.new" || fail 'bootstrap syntax'
    mv "$B/flash-core-init.sh.new" "$B/flash-core-init.sh" || fail 'activate bootstrap'
    printf '%s\n' "$RELEASE_ID" > "$B/flash-core-install.pending" || fail 'installation journal'
    rm -f "$P/CLEAN_INSTALL"
    sync
    mv "$B/init.sh.new" "$B/init.sh" || fail 'activate dispatcher'
    sync
fi
# Bound retries if U-Boot does not consume this model's update files.
attempts=0
[ ! -e "$R/update-attempts" ] || attempts=$(cat "$R/update-attempts")
case "$attempts" in 0|1|2) ;; *)
    rm -f "$SD/rootfs_$MODEL" "$SD/home_$MODEL"
    # Some bootloader/card combinations ignore staged updates. If neither
    # filesystem changed, reuse the verified recovery path to return to the
    # previous firmware instead of leaving a pending dispatcher with no network.
    # A partially installed filesystem must remain in explicit recovery.
    if stock_root && stock_home; then
        printf '%s\n' 'Flash-core install failed: bootloader ignored images after three attempts. Previous firmware/startup restored; recovery backups retained.' > "$R/automatic-restore.txt" || fail 'write automatic recovery reason'
        : > "$R/RESTORE" || fail 'request automatic recovery'
        sync
        exec /bin/sh "$P/dispatcher.sh"
    fi
    fail 'bootloader update did not finish after three attempts; use recovery'
    ;;
esac
printf '%s\n' "$((attempts + 1))" > "$R/update-attempts.new" || fail 'attempt journal'
mv "$R/update-attempts.new" "$R/update-attempts" || fail 'commit attempt journal'
sync
# Root update names appear only after all checks and verified device backups.
for part in rootfs home; do
    cp "$P/images/${part}_$MODEL.stage" "$SD/${part}_$MODEL.new" || fail 'stage bootloader image'
    [ "$(hash "$P/images/${part}_$MODEL.stage")" = "$(hash "$SD/${part}_$MODEL.new")" ] || fail 'staged image verification'
    mv "$SD/${part}_$MODEL.new" "$SD/${part}_$MODEL" || fail 'activate bootloader image'
done
echo 'Flash-core staged. Automatic reboots will install and verify images. DO NOT remove SD or power.' > "$SD/hack_result.txt"
restart
