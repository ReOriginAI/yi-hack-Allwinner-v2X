#!/bin/sh

# One-shot OOM policy for low-memory Yi cameras.
# The kernel decides when memory is exhausted. This script only tells it which
# processes are irreplaceable and which services are safe to kill and restart.
# It is intentionally non-resident; wd.sh reapplies it after service restarts
# and periodically to cover newly-created producer/helper processes.

VM_MIN_FREE_KB=384

# Keep a modest emergency reserve for the vendor media path.
if [ -r /proc/sys/vm/min_free_kbytes ] && [ -w /proc/sys/vm/min_free_kbytes ]; then
    IFS= read -r CURRENT < /proc/sys/vm/min_free_kbytes
    case "$CURRENT" in
        ''|*[!0-9]*) ;;
        *) [ "$CURRENT" -lt "$VM_MIN_FREE_KB" ] && echo "$VM_MIN_FREE_KB" > /proc/sys/vm/min_free_kbytes 2>/dev/null ;;
    esac
fi

# Scan /proc without ps/grep/awk so applying policy creates very little
# transient memory pressure. Linux task names are limited to 15 characters,
# hence the truncated ONVIF/WSD names below.
for PROC in /proc/[0-9]*; do
    [ -r "$PROC/status" ] || continue

    NAME=""
    PARENT=""
    while IFS=':' read -r KEY VALUE; do
        case "$KEY" in
            Name)
                set -- $VALUE
                NAME="$1"
                ;;
            PPid)
                set -- $VALUE
                PARENT="$1"
                ;;
        esac
        [ -n "$NAME" ] && [ -n "$PARENT" ] && break
    done < "$PROC/status"

    ADJ=""
    case "$NAME" in
        # Never sacrifice the vendor media core or Wi-Fi control plane.
        rmm|wpa_supplicant|udhcpc)
            ADJ=-1000
            ;;

        # Protect only the SSH listener completely. Session children are put
        # back at neutral priority so a runaway SSH command cannot become
        # unkillable merely because it inherited the listener's OOM setting.
        dropbear|dropbearmulti)
            if [ "$PARENT" = "1" ]; then ADJ=-1000; else ADJ=0; fi
            ;;

        # The supervisor must survive long enough to restore OOM victims.
        wd.sh|dispatch)
            ADJ=-900
            ;;

        # Streaming is useful and relatively expensive, but less disposable
        # than recording/discovery/management helpers.
        go2rtc)
            ADJ=250
            ;;
        rRTSPServer|rtsp_server_yi|h264grabber)
            ADJ=300
            ;;

        # Restartable local services.
        mp4record|motiond)
            ADJ=650
            ;;
        ipc2file|onvif_notify_se|onvif_simple_se)
            ADJ=700
            ;;
        httpd)
            ADJ=750
            ;;
        wsd_simple_serv|mdnsd|ntpd|pure-ftpd|tcpsvd)
            ADJ=800
            ;;
        mqttv4|mqtt-config)
            ADJ=900
            ;;

        # Short-lived helpers are always preferable OOM victims.
        imggrabber|snapshot|ffmpeg|nanotts|tts|python|python3|proccgi)
            ADJ=1000
            ;;
    esac

    [ -n "$ADJ" ] || continue
    [ -w "$PROC/oom_score_adj" ] || continue

    IFS= read -r OLD < "$PROC/oom_score_adj"
    [ "$OLD" = "$ADJ" ] || echo "$ADJ" > "$PROC/oom_score_adj" 2>/dev/null
done

exit 0
