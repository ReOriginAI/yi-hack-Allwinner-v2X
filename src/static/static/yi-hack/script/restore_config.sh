#!/bin/sh
# Validate and unpack a config backup in its SD-backed staging directory.
[ "$#" -eq 2 ] || exit 2
ARCHIVE=$1
DEST=$2
PREFIX=${YI_HACK_PREFIX:-/tmp/sd/yi-hack}
TARFILE="$DEST/config.tar"
# ulimit is confined to this child: a compressed bomb cannot grow past 1 MiB.
(ulimit -f 1024 || exit 1; bzip2 -dc "$ARCHIVE" > "$TARFILE") 2>/dev/null || exit 1
tar -tf "$TARFILE" > "$DEST/names" 2>/dev/null || exit 1
tar -tvf "$TARFILE" > "$DEST/listing" 2>/dev/null || exit 1
# Only ordinary top-level config files; no links, directories or traversal.
awk 'substr($0,1,1)!="-" { bad=1 } END { exit bad }' "$DEST/listing" || exit 1
COUNT=0
while IFS= read -r NAME; do
    COUNT=$((COUNT + 1))
    [ "$COUNT" -le 32 ] || exit 1
    case "$NAME" in
        hostname) ;;
        *.conf)
            printf '%s\n' "$NAME" | grep -Eq '^[A-Za-z0-9_-]+\.conf$' || exit 1
            [ -f "$PREFIX/etc/$NAME" ] || exit 1
            ;;
        *) exit 1 ;;
    esac
done < "$DEST/names"
[ "$COUNT" -gt 0 ] || exit 1
mkdir "$DEST/unpacked" || exit 1
(ulimit -f 1024 || exit 1; cd "$DEST/unpacked" && tar -xf "$TARFILE") 2>/dev/null || exit 1
[ -f "$DEST/unpacked/system.conf" ] && [ -f "$DEST/unpacked/camera.conf" ] || exit 1
