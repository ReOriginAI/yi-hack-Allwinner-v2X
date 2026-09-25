#!/bin/sh

YI_HACK_PREFIX="/tmp/sd/yi-hack"
CAMERA_CONF="$YI_HACK_PREFIX/etc/camera.conf"
SYSTEM_CONF="$YI_HACK_PREFIX/etc/system.conf"
MOTIOND="$YI_HACK_PREFIX/bin/motiond"
IPC2FILE="$YI_HACK_PREFIX/bin/ipc2file"
IPC_EVENT_DIR="/tmp/onvif_notify_server"
PIDFILE="/tmp/motiond.pid"
LOGFILE="/tmp/motiond.log"
OWNERFILE="/tmp/motiond.mp4record.owner"
STATEFILE="/tmp/motion.state"
HUMAN_ONLY_FILE="/tmp/motion_human_only"
SERVICE="$YI_HACK_PREFIX/script/service.sh"
IPC_CMD="$YI_HACK_PREFIX/bin/ipc_cmd"
MODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)

get_camera_config()
{
    grep -w "$1" "$CAMERA_CONF" 2>/dev/null | cut -d "=" -f2-
}

get_system_config()
{
    grep -w "$1" "$SYSTEM_CONF" 2>/dev/null | cut -d "=" -f2-
}

process_count()
{
    case "$1" in
        mp4record)
            ps | awk '$5 == "./mp4record" || $5 == "/home/app/mp4record" { n++ } END { print n+0 }'
            ;;
        motiond)
            ps | awk '$5 == "/tmp/sd/yi-hack/bin/motiond" { n++ } END { print n+0 }'
            ;;
        ipc2file)
            ps | awk '$5 == "ipc2file" || $5 == "/tmp/sd/yi-hack/bin/ipc2file" { n++ } END { print n+0 }'
            ;;
        *)
            echo 0
            ;;
    esac
}

ensure_motion_stats()
{
    if [ -r /sys/kernel/debug/mpp/ve ]; then
        return 0
    fi

    if ! grep -q ' /sys/kernel/debug debugfs ' /proc/mounts 2>/dev/null; then
        mount -t debugfs none /sys/kernel/debug >/dev/null 2>&1 || true
    fi

    [ -r /sys/kernel/debug/mpp/ve ]
}

motion_backend()
{
    # y28ga old firmware has no mpp/ve encoder-statistics node. Its firmware
    # IVA path publishes local IPC motion; face/PTZ are patched out while the
    # retained human classifier can optionally confirm motion.
    case "$MODEL_SUFFIX" in
        y28ga)
            echo ipc-events
            return
            ;;
    esac

    if ensure_motion_stats; then
        echo encoder-stats
    else
        echo unsupported
    fi
}

y28ga_human_only()
{
    [ "$MODEL_SUFFIX" = "y28ga" ] || return 1
    [ "$(get_camera_config MOTION_HUMAN_ONLY)" = "yes" ]
}

motion_sensitivity()
{
    VALUE=$(get_camera_config MOTION_SENSITIVITY)
    case "$VALUE" in
        1|2|3|4|5|6|7|8|9|10) echo "$VALUE" ;;
        *) echo 5 ;;
    esac
}

firmware_motion_sensitivity()
{
    case "$(motion_sensitivity)" in
        1|2|3) echo low ;;
        4|5|6|7) echo medium ;;
        8|9|10) echo high ;;
        *) echo medium ;;
    esac
}

disable_y28ga_classifiers()
{
    [ "$MODEL_SUFFIX" = "y28ga" ] || return 0
    [ -x "$IPC_CMD" ] || return 1

    # Reset optional vendor AI controls before applying the selected local
    # motion mode. Human detection is selectively re-enabled below when
    # MOTION_HUMAN_ONLY=yes; vehicle/animal, face, and PTZ stay disabled.
    "$IPC_CMD" -a off >/dev/null 2>&1
    "$IPC_CMD" -E off >/dev/null 2>&1
    "$IPC_CMD" -N off >/dev/null 2>&1
    "$IPC_CMD" -c off >/dev/null 2>&1
    "$IPC_CMD" -o off >/dev/null 2>&1
    rm -f "$HUMAN_ONLY_FILE" "$IPC_EVENT_DIR/human_detection"
}

set_y28ga_generic_motion_gate()
{
    [ "$MODEL_SUFFIX" = "y28ga" ] || return 0
    [ -x "$IPC_CMD" ] || return 1

    # Old y28ga firmware labels this bit AI Motion Detection, but live testing
    # shows it gates publication of the firmware IVA result.
    "$IPC_CMD" -O "$1" >/dev/null 2>&1
}

configure_y28ga_generic_motion()
{
    [ "$MODEL_SUFFIX" = "y28ga" ] || return 0

    disable_y28ga_classifiers || return 1
    LEVEL=$(firmware_motion_sensitivity)
    "$IPC_CMD" -s "$LEVEL" >/dev/null 2>&1 || return 1

    if y28ga_human_only; then
        touch "$HUMAN_ONLY_FILE" || return 1
        if ! "$IPC_CMD" -a on >/dev/null 2>&1; then
            rm -f "$HUMAN_ONLY_FILE"
            return 1
        fi
        # The IVA gate is still off here. Drop any stale marker or control-path
        # event before motion frames can begin producing real detections.
        sleep 0.1
        rm -f "$IPC_EVENT_DIR/motion_alarm" "$IPC_EVENT_DIR/human_detection"
    fi

    if ! set_y28ga_generic_motion_gate on; then
        "$IPC_CMD" -a off >/dev/null 2>&1 || true
        rm -f "$HUMAN_ONLY_FILE"
        return 1
    fi

    if [ "$(get_camera_config SAVE_VIDEO_ON_MOTION)" = "yes" ]; then
        "$IPC_CMD" -v detect >/dev/null 2>&1 || return 1
    fi

    return 0
}

stop_motiond()
{
    if [ "$MODEL_SUFFIX" = "y623" ]; then
        # Ignore stale pidfiles: a recycled PID may belong to rmm or a service.
        for SIGNAL in TERM KILL; do
            PIDS=$(ps | awk '$5 == "/tmp/sd/yi-hack/bin/motiond" { print $1 }')
            [ -n "$PIDS" ] || break
            kill -"$SIGNAL" $PIDS 2>/dev/null
            N=0
            while [ "$(process_count motiond)" -gt 0 ] && [ "$N" -lt 20 ]; do
                sleep 0.1
                N=$((N+1))
            done
        done
        if [ "$(process_count motiond)" -ne 0 ]; then
            echo "unable to stop all motiond instances" >&2
            return 1
        fi
        rm -f "$PIDFILE"
        echo 0 > "$STATEFILE"
        return 0
    fi

    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
            kill "$PID" 2>/dev/null
            N=0
            while [ -d "/proc/$PID" ] && [ $N -lt 20 ]; do
                sleep 0.1
                N=$((N+1))
            done
        fi
    fi

    if [ "$(process_count motiond)" -gt 0 ]; then
        killall motiond 2>/dev/null
        sleep 0.2
    fi

    rm -f "$PIDFILE"
    echo 0 > "$STATEFILE"
}

ensure_ipc_events()
{
    COUNT=$(process_count ipc2file)
    if [ "$COUNT" -gt 1 ]; then
        # ipc2file is a singleton queue consumer. Collapse accidental duplicate
        # instances and create one clean owner instead of running ambiguously.
        killall ipc2file 2>/dev/null
        sleep 0.3
        if [ "$(process_count ipc2file)" -gt 0 ]; then
            killall -9 ipc2file 2>/dev/null
            sleep 0.2
        fi
        COUNT=$(process_count ipc2file)
    fi
    if [ "$COUNT" -eq 1 ]; then
        return 0
    fi
    if [ "$COUNT" -gt 1 ]; then
        echo "unable to collapse duplicate ipc2file consumers" >&2
        return 1
    fi

    [ -x "$IPC2FILE" ] || {
        echo "ipc2file binary not found: $IPC2FILE" >&2
        return 1
    }

    mkdir -p "$IPC_EVENT_DIR" || return 1
    "$IPC2FILE" >/dev/null 2>&1
    sleep 0.3

    [ "$(process_count ipc2file)" -eq 1 ] || {
        echo "unable to start ipc2file event consumer" >&2
        return 1
    }
}

ensure_single_mp4record()
{
    COUNT=$(process_count mp4record)

    if [ "$COUNT" -gt 1 ]; then
        "$SERVICE" mp4record stop >/dev/null 2>&1
        sleep 0.5
        COUNT=0
        if [ "$MODEL_SUFFIX" = "y623" ]; then
            COUNT=$(process_count mp4record)
            # Do not start another recorder while old instances are exiting.
            [ "$COUNT" -le 1 ] || return 1
        fi
    fi

    if [ "$COUNT" -eq 0 ]; then
        "$SERVICE" mp4record start >/dev/null 2>&1
        sleep 0.3
        if [ "$(process_count mp4record)" -eq 1 ]; then
            if [ "$(get_system_config REC_WITHOUT_CLOUD)" != "yes" ]; then
                touch "$OWNERFILE"
            fi
            return 0
        fi
        return 1
    fi

    if [ "$(get_system_config REC_WITHOUT_CLOUD)" = "yes" ]; then
        rm -f "$OWNERFILE"
    fi
    return 0
}

stop_owned_mp4record()
{
    if [ -f "$OWNERFILE" ]; then
        if [ "$(get_system_config REC_WITHOUT_CLOUD)" != "yes" ]; then
            "$SERVICE" mp4record stop >/dev/null 2>&1
        fi
        rm -f "$OWNERFILE"
    fi
}

start_encoder_backend()
{
    if [ ! -x "$MOTIOND" ]; then
        echo "motiond binary not found: $MOTIOND" >&2
        return 1
    fi

    SENS=$(motion_sensitivity)
    RECORD_OPT=""

    if [ "$(get_camera_config SAVE_VIDEO_ON_MOTION)" = "yes" ]; then
        "$IPC_CMD" -v detect >/dev/null 2>&1
        if ! ensure_single_mp4record; then
            echo "unable to start a single mp4record instance" >&2
            return 1
        fi
        RECORD_OPT="-r"
    else
        stop_owned_mp4record
    fi

    "$MOTIOND" -s "$SENS" -i 100 $RECORD_OPT > "$LOGFILE" 2>&1 &
    PID=$!
    echo "$PID" > "$PIDFILE"

    # motiond is expendable compared with rmm: if the kernel must choose an
    # OOM victim, prefer losing/restarting motion detection over video capture.
    if [ -w "/proc/$PID/oom_score_adj" ]; then
        echo 500 > "/proc/$PID/oom_score_adj" 2>/dev/null || true
    fi

    sleep 0.2

    if [ ! -d "/proc/$PID" ]; then
        rm -f "$PIDFILE"
        echo 0 > "$STATEFILE"
        return 1
    fi

    return 0
}

start_ipc_backend()
{
    if ! configure_y28ga_generic_motion; then
        echo "unable to configure y28ga motion" > "$LOGFILE"
        return 1
    fi

    if ! ensure_ipc_events; then
        echo "local IPC motion event consumer is unavailable" > "$LOGFILE"
        return 1
    fi

    if [ "$(get_camera_config SAVE_VIDEO_ON_MOTION)" = "yes" ]; then
        if ! ensure_single_mp4record; then
            echo "unable to start a single mp4record instance" >&2
            return 1
        fi
    else
        stop_owned_mp4record
    fi

    if y28ga_human_only; then
        MODE="human-confirmed IVA"
    else
        MODE="generic IVA"
    fi
    printf '%s\n' "ipc-events backend active on ${MODEL_SUFFIX:-unknown}; $MODE" > "$LOGFILE"
    return 0
}

start_motion()
{
    stop_motiond || return 1

    # Freeze Y28GA IVA while its classifier/event mode is reconfigured so no
    # stale generic or human event can leak across a runtime settings change.
    set_y28ga_generic_motion_gate off >/dev/null 2>&1 || true
    disable_y28ga_classifiers >/dev/null 2>&1 || true

    if [ "$(get_camera_config MOTION_DETECTION)" != "yes" ]; then
        rm -f "$IPC_EVENT_DIR/motion_alarm" "$IPC_EVENT_DIR/human_detection"
        stop_owned_mp4record
        "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" "$(get_system_config RTSP_STREAM)" >/dev/null 2>&1 || true
        echo "motion detection disabled" > "$LOGFILE"
        return 0
    fi

    # Apply the recorder-aware VENC policy before mp4record can start. Patched
    # y28ga records main+AAC with VENC1 paused; stock/unknown recorders fail safe
    # by keeping VENC1 active. Re-evaluate after backend ownership changes.
    "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" "$(get_system_config RTSP_STREAM)" >/dev/null 2>&1 || true

    BACKEND=$(motion_backend)
    case "$BACKEND" in
        encoder-stats)
            start_encoder_backend
            RC=$?
            ;;
        ipc-events)
            start_ipc_backend
            RC=$?
            ;;
        *)
            stop_owned_mp4record
            echo 0 > "$STATEFILE"
            echo "motion detection unsupported on ${MODEL_SUFFIX:-unknown}" > "$LOGFILE"
            RC=1
            ;;
    esac

    "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" "$(get_system_config RTSP_STREAM)" >/dev/null 2>&1 || true
    return "$RC"
}

stop_motion()
{
    stop_motiond || return 1
    stop_owned_mp4record
    set_y28ga_generic_motion_gate off >/dev/null 2>&1 || true
    disable_y28ga_classifiers >/dev/null 2>&1 || true
    rm -f "$IPC_EVENT_DIR/motion_alarm" "$IPC_EVENT_DIR/human_detection"
    echo 0 > "$STATEFILE"
    "$YI_HACK_PREFIX/script/rtsp_stream_venc.sh" "$(get_system_config RTSP_STREAM)" >/dev/null 2>&1 || true
}

status_motion()
{
    if [ "$(get_camera_config MOTION_DETECTION)" != "yes" ]; then
        echo stopped
        return
    fi

    case "$(motion_backend)" in
        encoder-stats)
            COUNT=$(process_count motiond)
            if [ "$COUNT" -eq 1 ]; then
                echo started
            elif [ "$COUNT" -gt 1 ]; then
                echo duplicate
            else
                echo failed
            fi
            ;;
        ipc-events)
            COUNT=$(process_count ipc2file)
            if [ "$COUNT" -eq 1 ]; then
                echo started
            elif [ "$COUNT" -gt 1 ]; then
                echo duplicate
            else
                echo failed
            fi
            ;;
        *)
            echo unsupported
            ;;
    esac
}

# Serialize y623 lifecycle operations from watchdog and configuration callers.
# This kernel returns ENOSYS for flock. An atomic mkdir works without it.
# Fail closed on contention; watchdog retries later. /tmp clears on reboot.
# SIGKILL of this service shell (not motiond) requires removing a stale lock.
if [ "$MODEL_SUFFIX" = "y623" ]; then
    case "$1" in
        start|restart|stop)
            LOCKDIR=/tmp/motion_service.lock.d
            mkdir "$LOCKDIR" 2>/dev/null || exit 1
            trap 'rmdir "$LOCKDIR" 2>/dev/null' 0
            trap 'exit 1' HUP INT TERM
            ;;
    esac
fi

case "$1" in
    start|restart)
        start_motion
        ;;
    stop)
        stop_motion
        ;;
    status)
        status_motion
        ;;
    backend)
        motion_backend
        ;;
    sensitivity)
        motion_sensitivity
        ;;
    *)
        echo "usage: $0 {start|stop|restart|status|backend|sensitivity}" >&2
        exit 2
        ;;
esac
