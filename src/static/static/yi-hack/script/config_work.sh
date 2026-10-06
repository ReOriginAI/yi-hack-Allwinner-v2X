#!/bin/sh
# Source from config CGIs. Serialize requests and stage only on the SD card.
config_work_begin()
{
    awk '$2=="/tmp/sd" && $3!="tmpfs" {found=1} END {exit !found}' /proc/mounts || return 1
    CONFIG_LOCK=/tmp/yi-config-work.lock.d
    CONFIG_ROOT="$YI_HACK_PREFIX/.config-work"
    if ! mkdir "$CONFIG_LOCK" 2>/dev/null; then
        OWNER=$(cat "$CONFIG_LOCK/pid" 2>/dev/null)
        case "$OWNER" in ''|*[!0-9]*) return 1 ;; esac
        kill -0 "$OWNER" 2>/dev/null && return 1
        rm -f "$CONFIG_LOCK/pid"
        rmdir "$CONFIG_LOCK" 2>/dev/null || return 1
        mkdir "$CONFIG_LOCK" 2>/dev/null || return 1
    fi
    echo "$$" > "$CONFIG_LOCK/pid"
    trap 'config_work_cleanup' 0
    trap 'exit 1' 1 2 15
    umask 077
    # Leftovers from a killed request/reboot are removed by the next request.
    rm -rf "$CONFIG_ROOT"
    mkdir "$CONFIG_ROOT" || return 1
    CONFIG_WORK="$CONFIG_ROOT/request"
    mkdir "$CONFIG_WORK" || return 1
}
config_work_cleanup()
{
    rm -rf "$CONFIG_ROOT"
    rm -f "$CONFIG_LOCK/pid"
    rmdir "$CONFIG_LOCK" 2>/dev/null
}
