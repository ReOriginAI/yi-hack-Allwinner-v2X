#!/tmp/sd/yi-hack/bin/busybox ash
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
[ -f "$YI_HACK_PREFIX/flash-core" ] || exit 0
. "$YI_HACK_PREFIX/script/service_lock.sh" || exit 1
. "$YI_HACK_PREFIX/script/storage.sh" || exit 1
sd_present || exit 0
yi_lock flash-config || exit $?
[ -s "$YI_HACK_PREFIX/etc/system.conf" ] && [ -s "$YI_HACK_PREFIX/etc/camera.conf" ] || exit 1
BB="$YI_HACK_PREFIX/bin/busybox"
DEST=${YI_FLASH_CONFIG:-/backup/yi-hack-config}
umask 077
mkdir -p "$DEST" || exit 1
trap 'exit 1' 1 2 15
TOTAL=0
COUNT=0
# Validate the whole set before writing. Limit flash wear and fallback storage,
# including the SSH identity so removing the card does not change host keys.
for FILE in "$YI_HACK_PREFIX"/etc/*.conf "$YI_HACK_PREFIX"/etc/*.json "$YI_HACK_PREFIX"/etc/hostname "$YI_HACK_PREFIX"/etc/dropbear/*; do
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || continue
    COUNT=$((COUNT + 1))
    [ "$COUNT" -le 32 ] || exit 1
    SIZE=$("$BB" wc -c < "$FILE")
    [ "$SIZE" -le 65536 ] || exit 1
    TOTAL=$((TOTAL + SIZE))
    [ "$TOTAL" -le 131072 ] || exit 1
done
for FILE in "$YI_HACK_PREFIX"/etc/*.conf "$YI_HACK_PREFIX"/etc/*.json "$YI_HACK_PREFIX"/etc/hostname "$YI_HACK_PREFIX"/etc/dropbear/*; do
    [ -f "$FILE" ] && [ ! -L "$FILE" ] || continue
    NAME=${FILE#"$YI_HACK_PREFIX"/etc/}
    case "$NAME" in */*) mkdir -p "$DEST/${NAME%/*}" || exit 1 ;; esac
    "$BB" cmp -s "$FILE" "$DEST/$NAME" && continue
    TEMP="$DEST/$NAME.new"
    trap 'rm -f "$TEMP"' 0
    cp "$FILE" "$TEMP" && chmod 600 "$TEMP" && mv -f "$TEMP" "$DEST/$NAME" || exit 1
done
# Retire removed settings/keys as well; repeated renames cannot grow flash usage.
for FILE in "$DEST"/*.conf "$DEST"/*.json "$DEST"/hostname "$DEST"/dropbear/*; do
    [ -f "$FILE" ] || continue
    NAME=${FILE#"$DEST"/}
    [ -f "$YI_HACK_PREFIX/etc/$NAME" ] || rm -f "$FILE"
done
