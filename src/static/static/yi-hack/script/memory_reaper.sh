#!/bin/sh

# Last-resort userspace memory-pressure reaper for small Allwinner cameras.
# Preserve the vendor media core (rmm), networking and SSH. Shed only services
# that can be reconstructed cleanly by yi-hack once memory/fragmentation recovers.

YI_HACK_PREFIX="/tmp/sd/yi-hack"
CONF_FILE="$YI_HACK_PREFIX/etc/system.conf"
CAMERA_CONF_FILE="$YI_HACK_PREFIX/etc/camera.conf"
SERVICE="$YI_HACK_PREFIX/script/service.sh"
MOTION_SERVICE="$YI_HACK_PREFIX/script/motion_service.sh"
LOCKDIR="/tmp/memory_reaper.lock.d"
STATE_DIR="/tmp/memory_reaper.state"
LOG_FILE="/tmp/sd/memory_reaper.log"

INTERVAL=5
# Aggregate-memory thresholds are intentionally below normal y623 steady-state.
# Fragmentation is handled independently by compact_fragmentation().
LOW_MEM_KB=5120
RECOVER_MEM_KB=7168
LOW_ORDER3_UNITS=4
RECOVER_STABLE_CHECKS=3
COOLDOWN_CHECKS=6

# Default VM policy for 64 MiB-class cameras. 384 KiB raises the vendor
# emergency reserve by 50% while preserving y623 userspace headroom.
VM_MIN_FREE_KB=384
# Only compact while aggregate memory is still healthy. A five-minute cooldown
# prevents repeated compaction from turning fragmentation into CPU stalls.
COMPACT_MIN_MEM_KB=7168
COMPACT_COOLDOWN_CHECKS=60
# Reapplying oom_score_adj scans the process table once per protected name.
# Refresh once a minute; recovery paths still refresh immediately after restarts.
OOM_POLICY_REFRESH_CHECKS=12

if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OLD_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
    case "$OLD_PID" in
        ''|*[!0-9]*) OLD_PID=0 ;;
    esac
    if [ "$OLD_PID" -gt 0 ] && [ -d "/proc/$OLD_PID" ]; then
        exit 0
    fi
    rm -rf "$LOCKDIR" 2>/dev/null
    mkdir "$LOCKDIR" 2>/dev/null || exit 0
fi
echo $$ > "$LOCKDIR/pid"
cleanup_lock() { rm -rf "$LOCKDIR" 2>/dev/null; }
trap 'cleanup_lock' 0
trap 'cleanup_lock; exit 0' 1 2 3 15
mkdir -p "$STATE_DIR"

log()
{
    # Keep the SD log bounded. Pressure events should be rare, but a broken
    # sensor/allocator must not turn this safety mechanism into an SD writer.
    if [ -f "$LOG_FILE" ]; then
        SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null)
        case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
        if [ "$SIZE" -gt 65536 ]; then
            tail -n 160 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
    echo "$(date +'%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

get_config()
{
    grep -w "$1" "$CONF_FILE" 2>/dev/null | cut -d '=' -f2-
}

get_camera_config()
{
    grep -w "$1" "$CAMERA_CONF_FILE" 2>/dev/null | cut -d '=' -f2-
}

proc_pids()
{
    NAME="$1"
    ps | awk -v n="$NAME" '{ cmd=$5; gsub(/[{}]/, "", cmd); sub(/^.*\//, "", cmd); app=$6; sub(/^.*\//, "", app); if (cmd == n || (cmd == "busybox" && app == n)) print $1 }'
}

proc_count()
{
    proc_pids "$1" | awk 'END { print NR+0 }'
}

mark_running()
{
    NAME="$1"
    shift
    for PROC in "$@"; do
        if [ "$(proc_count "$PROC")" -gt 0 ]; then
            touch "$STATE_DIR/$NAME.was_running"
            return
        fi
    done
    rm -f "$STATE_DIR/$NAME.was_running"
}

was_running()
{
    [ -f "$STATE_DIR/$1.was_running" ]
}

mem_available_kb()
{
    VALUE=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    case "$VALUE" in
        ''|*[!0-9]*)
            # Older kernels may not expose MemAvailable. This conservative
            # fallback counts immediately reclaimable file cache but not swap.
            VALUE=$(awk '
                /^MemFree:/{f=$2}
                /^Cached:/{c=$2}
                /^Buffers:/{b=$2}
                END { print (f+0)+(c+0)+(b+0) }
            ' /proc/meminfo 2>/dev/null)
            ;;
    esac
    case "$VALUE" in ''|*[!0-9]*) echo 0 ;; *) echo "$VALUE" ;; esac
}

order3_units()
{
    # Convert every Normal-zone order >=3 block into order-3 equivalents.
    # Example: one order-4 block counts as two order-3 blocks.
    awk '
        $4 == "Normal" {
            found=1
            units=0
            weight=1
            for (i=8; i<=NF; i++) {
                units += $i * weight
                weight *= 2
            }
            total += units
        }
        END { if (found) print total+0; else print -1 }
    ' /proc/buddyinfo 2>/dev/null
}

apply_vm_policy()
{
    SYSCTL=/proc/sys/vm/min_free_kbytes
    [ -w "$SYSCTL" ] || return 0
    CURRENT=$(cat "$SYSCTL" 2>/dev/null)
    case "$CURRENT" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$CURRENT" -lt "$VM_MIN_FREE_KB" ]; then
        echo "$VM_MIN_FREE_KB" > "$SYSCTL" 2>/dev/null
    fi
}

compact_fragmentation()
{
    MEM=$(mem_available_kb)
    BUDDY=$(order3_units)
    [ "$BUDDY" -ge 0 ] && [ "$BUDDY" -lt "$LOW_ORDER3_UNITS" ] || return 1
    [ "$MEM" -ge "$COMPACT_MIN_MEM_KB" ] || return 1
    [ "$COMPACT_COOLDOWN" -eq 0 ] || return 1
    [ -w /proc/sys/vm/compact_memory ] || return 1

    BEFORE=$BUDDY
    if echo 1 > /proc/sys/vm/compact_memory 2>/dev/null; then
        AFTER=$(order3_units)
        COMPACT_COOLDOWN="$COMPACT_COOLDOWN_CHECKS"
        log "compaction requested mem_available=${MEM}kB order3_units=${BEFORE}->${AFTER}"
        [ "$AFTER" -ge "$LOW_ORDER3_UNITS" ] && return 0
    else
        COMPACT_COOLDOWN="$COMPACT_COOLDOWN_CHECKS"
    fi
    return 1
}

is_pressure()
{
    # Fragmentation alone is not pressure: the normal media path uses ION/IOMMU
    # and tolerates scattered pages. Low order-3 availability is handled by
    # compact_fragmentation() without sacrificing healthy services.
    MEM=$(mem_available_kb)
    [ "$MEM" -lt "$LOW_MEM_KB" ]
}

is_recovered()
{
    MEM=$(mem_available_kb)
    [ "$MEM" -ge "$RECOVER_MEM_KB" ]
}

set_adj_pid()
{
    PID="$1"
    VALUE="$2"
    [ -w "/proc/$PID/oom_score_adj" ] || return 0
    CURRENT=$(cat "/proc/$PID/oom_score_adj" 2>/dev/null)
    [ "$CURRENT" = "$VALUE" ] || echo "$VALUE" > "/proc/$PID/oom_score_adj" 2>/dev/null
}

set_adj_name()
{
    NAME="$1"
    VALUE="$2"
    for PID in $(proc_pids "$NAME"); do
        set_adj_pid "$PID" "$VALUE"
    done
}

apply_oom_policy()
{
    # Keep the irreplaceable control plane and vendor media process alive.
    set_adj_name rmm -700
    set_adj_name wpa_supplicant -700
    set_adj_name udhcpc -650
    set_adj_name dropbear -650
    set_adj_name dropbearmulti -650
    set_adj_name dispatch -650

    # Prefer cleanly restartable services as kernel OOM victims if userspace
    # shedding loses a race with the allocator.
    set_adj_name go2rtc 350
    set_adj_name rRTSPServer 450
    set_adj_name rtsp_server_yi 450
    set_adj_name mp4record 450
    set_adj_name motiond 500
    set_adj_name ipc2file 550
    set_adj_name onvif_notify_server 600
    set_adj_name onvif_simple_server 600
    set_adj_name wsd_simple_server 650
    set_adj_name httpd 650
    set_adj_name mqttv4 700
    set_adj_name mqtt-config 700
    set_adj_name h264grabber 750
    set_adj_name imggrabber 900
    set_adj_name nanotts 900
    set_adj_name python 900
    set_adj_name python3 900
    set_adj_name proccgi 900
}

capture_state()
{
    rm -f "$STATE_DIR"/*.was_running 2>/dev/null
    mark_running rtsp go2rtc rRTSPServer rtsp_server_yi
    mark_running mp4record mp4record
    if [ "$("$MOTION_SERVICE" status 2>/dev/null)" = "started" ]; then touch "$STATE_DIR/motion.was_running"; else rm -f "$STATE_DIR/motion.was_running"; fi
    mark_running onvif onvif_notify_server onvif_simple_server
    mark_running wsdd wsd_simple_server
    mark_running mqtt mqttv4
    mark_running mqtt_config mqtt-config
    mark_running httpd httpd
    mark_running mdns mdnsd
    mark_running ntpd ntpd
    mark_running ftpd pure-ftpd tcpsvd
}

kill_transients()
{
    for NAME in imggrabber snapshot ffmpeg nanotts tts python python3 proccgi; do
        killall "$NAME" 2>/dev/null
    done
}

shed_services()
{
    capture_state
    MEM=$(mem_available_kb)
    BUDDY=$(order3_units)
    log "pressure detected mem_available=${MEM}kB order3_units=$BUDDY; shedding restartable services"

    # Stage 1: transient helpers can consume several MiB and need no restart.
    kill_transients
    sleep 1

    # Stage 2: the largest persistent restartable consumers.
    killall go2rtc 2>/dev/null
    killall rRTSPServer 2>/dev/null
    killall rtsp_server_yi 2>/dev/null
    killall h264grabber 2>/dev/null
    "$SERVICE" mp4record stop >/dev/null 2>&1
    "$MOTION_SERVICE" stop >/dev/null 2>&1
    # Prevent the RTSP watchdog from immediately undoing deliberate shedding.
    killall wd.sh 2>/dev/null
    sleep 2

    # Stage 3: ancillary network/application services. Never touch Wi-Fi,
    # DHCP, dropbear/SSH, init, or rmm.
    "$SERVICE" onvif stop >/dev/null 2>&1
    "$SERVICE" wsdd stop >/dev/null 2>&1
    "$SERVICE" mqtt stop >/dev/null 2>&1
    "$SERVICE" mqtt-config stop >/dev/null 2>&1
    "$SERVICE" ftpd stop >/dev/null 2>&1
    killall httpd 2>/dev/null
    killall mdnsd 2>/dev/null
    killall ntpd 2>/dev/null

    MEM=$(mem_available_kb)
    BUDDY=$(order3_units)
    log "shed complete mem_available=${MEM}kB order3_units=$BUDDY"
}

pressure_after_pause()
{
    sleep "$1"
    apply_oom_policy
    is_pressure
}

restart_httpd()
{
    was_running httpd || return 0
    [ "$(proc_count httpd)" -eq 0 ] || return 0
    PORT=$(get_config HTTPD_PORT)
    case "$PORT" in ''|*[!0-9]*) PORT=80 ;; esac
    "$YI_HACK_PREFIX/usr/sbin/httpd" -p "$PORT" -h "$YI_HACK_PREFIX/www/" -c /tmp/httpd.conf
}

restart_mdns()
{
    was_running mdns || return 0
    [ "$(proc_count mdnsd)" -eq 0 ] || return 0
    [ -d /tmp/mdns.d ] && "$YI_HACK_PREFIX/sbin/mdnsd" /tmp/mdns.d
}

restart_ntpd()
{
    was_running ntpd || return 0
    [ "$(proc_count ntpd)" -eq 0 ] || return 0
    SERVER=$(get_config NTP_SERVER)
    [ -n "$SERVER" ] && "$YI_HACK_PREFIX/usr/sbin/ntpd" -p "$SERVER" &
}

restore_services()
{
    log "memory stable; beginning staged service recovery"

    # Recover cheap management/discovery services first.
    restart_httpd
    restart_mdns
    restart_ntpd
    if was_running ftpd; then "$SERVICE" ftpd start >/dev/null 2>&1; fi
    if pressure_after_pause 5; then return 1; fi

    # Restore ONVIF/ipc2file before motion. On y28ga the motion service shares
    # ipc2file and will reuse an existing singleton instead of creating one.
    if was_running onvif; then "$SERVICE" onvif start >/dev/null 2>&1; fi
    if was_running wsdd; then "$SERVICE" wsdd start >/dev/null 2>&1; fi
    if was_running mqtt; then "$SERVICE" mqtt start >/dev/null 2>&1; fi
    if was_running mqtt_config; then "$SERVICE" mqtt-config start >/dev/null 2>&1; fi
    if pressure_after_pause 5; then return 1; fi

    # Recorder/motion are small and useful locally.
    if was_running mp4record; then "$SERVICE" mp4record start >/dev/null 2>&1; fi
    if was_running motion; then "$MOTION_SERVICE" start >/dev/null 2>&1; fi
    if pressure_after_pause 5; then return 1; fi

    # RTSP/go2rtc is deliberately last because it has the largest userspace
    # footprint and its exec producers can add pressure when clients reconnect.
    if was_running rtsp; then "$SERVICE" rtsp start >/dev/null 2>&1; fi
    if pressure_after_pause 8; then return 1; fi

    MEM=$(mem_available_kb)
    BUDDY=$(order3_units)
    log "service recovery complete mem_available=${MEM}kB order3_units=$BUDDY"
    rm -f "$STATE_DIR"/*.was_running 2>/dev/null
    return 0
}

# Protect the reaper itself enough to survive long enough to shed services, but
# leave rmm/network/SSH at least as protected.
echo -600 > "/proc/$$/oom_score_adj" 2>/dev/null
COMPACT_COOLDOWN=0
apply_vm_policy
apply_oom_policy
log "started mem_low=${LOW_MEM_KB}kB mem_recover=${RECOVER_MEM_KB}kB compact_order3_low=$LOW_ORDER3_UNITS min_free=${VM_MIN_FREE_KB}kB"

SHED=0
STABLE=0
COOLDOWN=0
OOM_POLICY_COUNTDOWN="$OOM_POLICY_REFRESH_CHECKS"

while true; do
    if [ "$OOM_POLICY_COUNTDOWN" -le 0 ]; then
        apply_oom_policy
        OOM_POLICY_COUNTDOWN="$OOM_POLICY_REFRESH_CHECKS"
    else
        OOM_POLICY_COUNTDOWN=$((OOM_POLICY_COUNTDOWN - 1))
    fi

    if [ "$COMPACT_COOLDOWN" -gt 0 ]; then
        COMPACT_COOLDOWN=$((COMPACT_COOLDOWN - 1))
    fi

    if [ "$SHED" -eq 0 ]; then
        if is_pressure; then
            shed_services
            SHED=1
            STABLE=0
            COOLDOWN="$COOLDOWN_CHECKS"
        else
            # When aggregate memory is healthy, repair fragmentation in place.
            # Failure is non-fatal; the ION/IOMMU media path does not require
            # order-3 Normal-zone blocks during steady-state operation.
            compact_fragmentation || true
        fi
    else
        if is_recovered; then
            STABLE=$((STABLE + 1))
        else
            STABLE=0
        fi

        if [ "$COOLDOWN" -gt 0 ]; then
            COOLDOWN=$((COOLDOWN - 1))
        elif [ "$STABLE" -ge "$RECOVER_STABLE_CHECKS" ]; then
            if restore_services; then
                SHED=0
                STABLE=0
            else
                MEM=$(mem_available_kb)
                BUDDY=$(order3_units)
                log "pressure returned during recovery mem_available=${MEM}kB order3_units=$BUDDY; shedding again"
                shed_services
                SHED=1
                STABLE=0
                COOLDOWN="$COOLDOWN_CHECKS"
            fi
        fi
    fi

    sleep "$INTERVAL"
done
