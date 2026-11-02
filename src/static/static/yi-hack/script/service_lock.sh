#!/bin/sh
# Scripts source this before acquiring locks. No unlocked fallback on old ash.
if ! command -v yi_lock >/dev/null 2>&1; then
    if ! "$YI_HACK_PREFIX/bin/busybox" ash -c 'command -v yi_lock' >/dev/null 2>&1; then
        echo "Service ownership requires the rebuilt BusyBox ash with yi_lock." >&2
        exit 1
    fi
    exec "$YI_HACK_PREFIX/bin/busybox" ash "$0" "$@"
    exit 1
fi
