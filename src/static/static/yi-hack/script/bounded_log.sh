#!/bin/sh
# Short-lived script logs: retain at most 200 lines AND 64 KiB.
[ "$#" -ge 2 ] || exit 2
LOGFILE=$1
shift
LOCK="${LOGFILE}.lock.d"
TEMP="${LOGFILE}.new"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rm -f "$TEMP"; rmdir "$LOCK" 2>/dev/null' 0
trap 'exit 1' 1 2 15
{
    tail -n 199 "$LOGFILE" 2>/dev/null
    printf '%s\n' "$*"
} | tail -c 65536 > "$TEMP" || exit 1
mv -f "$TEMP" "$LOGFILE"
