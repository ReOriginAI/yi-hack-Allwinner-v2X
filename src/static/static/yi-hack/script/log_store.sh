#!/bin/sh
# A shared hard limit for the ONVIF/discovery logs; no resident logger.
LOGDIR=/tmp/yi-service-logs
if ! awk '$2 == "/tmp/yi-service-logs" && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts; then
    mkdir -p "$LOGDIR" || exit 1
    if ! mount -t tmpfs -o size=128k,nr_inodes=16,mode=0755 tmpfs "$LOGDIR"; then
        # Fail closed: never fall back to unbounded RAM-backed logs.
        echo "yi-hack: bounded log mount failed; daemon file logging disabled" >&2
        for name in onvif_notify_server onvif_simple_server wsd_simple_server; do
            ln -sf /dev/null "/tmp/$name.log" || exit 1
        done
        exit 0
    fi
fi
for name in onvif_notify_server onvif_simple_server wsd_simple_server; do
    target="$LOGDIR/$name.log"
    [ "$name" != onvif_simple_server ] || target="$LOGDIR/cgi.log"
    [ -e "$target" ] || : > "$target"
    [ -L "/tmp/$name.log" ] && [ "$(readlink "/tmp/$name.log")" = "$target" ] && continue
    ln -sf "$target" "/tmp/$name.log" || exit 1
done
