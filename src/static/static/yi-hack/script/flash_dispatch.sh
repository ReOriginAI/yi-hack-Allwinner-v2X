#!/bin/sh
# The vendor broker initializes SD status from saved state. Without a card its
# first CID poll can report removal and reboot forever. Only no-card flash boots
# use this audited RAM copy; card insertion still requests a clean reboot.
YI_HACK_PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
. "$YI_HACK_PREFIX/script/storage.sh" || exit 1
sd_present && exit 0
MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix")
case "$MODEL_SUFFIX" in
    y28ga)
        STOCK_MD5=c6ae77baf1821023c2138cf46bb793ec
        PATCHED_MD5=2388704364446d01857c3cf11937f3f4
        OFFSET=35024
        ;;
    y623)
        STOCK_MD5=033ff9e7091c72ab2209eaac74ad802e
        PATCHED_MD5=f4e457a4cc195460e5f6a63bd46351ef
        OFFSET=40124
        ;;
    *) exit 1 ;;
esac
DISPATCH=/home/app/dispatch
TARGET=/tmp/local-only/dispatch-no-sd
[ "$(md5sum "$DISPATCH" | cut -d ' ' -f1)" = "$STOCK_MD5" ] || exit 1
cp "$DISPATCH" "$TARGET" || exit 1
# ARM NOP replaces only the SD-removal send_reboot_msg call. SD state updates,
# reset handling, network recovery and other reboot requests remain intact.
printf '\000\360\040\343' | dd of="$TARGET" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null || exit 1
[ "$(md5sum "$TARGET" | cut -d ' ' -f1)" = "$PATCHED_MD5" ] || exit 1
chmod 555 "$TARGET" || exit 1
mount --bind "$TARGET" "$DISPATCH"
