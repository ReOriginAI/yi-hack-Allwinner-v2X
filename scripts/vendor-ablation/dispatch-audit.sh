#!/bin/sh
# Audit one extracted dispatch binary. This script is intentionally read-only:
# an unknown hash is an error, never a reason to patch a new firmware image.
set -eu

MODEL=${1:?model (y623 or y28ga)}
DISPATCH=${2:?path to extracted dispatch}
case "$MODEL" in
    y623) EXPECTED=033ff9e7091c72ab2209eaac74ad802e ;;
    y28ga) EXPECTED=c6ae77baf1821023c2138cf46bb793ec ;;
    *) echo "unsupported model: $MODEL" >&2; exit 2 ;;
esac
[ -r "$DISPATCH" ] || { echo "unreadable dispatch: $DISPATCH" >&2; exit 1; }
ACTUAL=$(md5sum "$DISPATCH" | cut -d ' ' -f1)
[ "$ACTUAL" = "$EXPECTED" ] || {
    echo "refusing unknown dispatch hash: $ACTUAL (expected $EXPECTED)" >&2
    exit 1
}
file "$DISPATCH"
readelf -h -l -d -Ws "$DISPATCH"
printf '\n--- imported network/process APIs ---\n'
readelf -Ws "$DISPATCH" | grep -E ' UND .*\b(socket|connect|send|sendto|recv|recvfrom|listen|accept|system|popen|exec|execl|getaddrinfo)\b' || true
printf '\n--- Yi/network/local strings ---\n'
strings -a "$DISPATCH" | grep -Ei 'cloud|p2p|oss|rtmp|https?://|/tmp/sd|/home/app|/ipc_|wpa_cli|factory|telnetd|upgrade' || true
