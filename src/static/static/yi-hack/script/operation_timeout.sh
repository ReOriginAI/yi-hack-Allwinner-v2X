#!/bin/sh
# Use our BusyBox explicitly: vendor PATH applets differ between y623/y28ga.
# KILL gives even a command ignoring TERM a hard wall-clock deadline.
runWithTimeout ()
{
    timeout_seconds=$1
    shift
    "$YI_HACK_PREFIX/bin/busybox" timeout -s KILL "$timeout_seconds" "$@"
    timeout_status=$?
    if [ "$timeout_status" -ne 0 ]; then
        logAdd "[ERROR] $1 failed or timed out (limit ${timeout_seconds}s, status $timeout_status)."
    fi
    return "$timeout_status"
}
