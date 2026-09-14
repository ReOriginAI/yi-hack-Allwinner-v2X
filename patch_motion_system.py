from pathlib import Path
p = Path('/tmp/system.sh.motion')
s = p.read_text()
old = '''        # Trick to start circular buffer filling
        start_buffer
        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then
            if [[ $(get_config TIME_OSD) == "yes" ]] ; then
                (sleep 30; export TZP=`TZ=$TZ_TMP date +%z`; export TZP=${TZP:0:3}:${TZP:3:2}; export TZ=GMT$TZP; ./mp4record) &
            else
                ./mp4record &
            fi
        fi
        # Strict local-only: vendor cloud intentionally not started.

        if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then
            ipc_cmd -1
            sleep 0.5
            if [[ $(get_config MOTION_DETECTION) == "yes" ]] ; then
                ipc_cmd -O on
            else
'''
new = '''        # Trick to start circular buffer filling
        start_buffer

        # Lightweight local motion detection using the existing low-stream
        # encoder statistics. This does not restore the PilotAI/YUV path.
        MOTION_ENABLED=$(get_config MOTION_DETECTION)
        MOTION_RECORD=$(get_config SAVE_VIDEO_ON_MOTION)
        MOTION_SENSITIVITY=$(get_config MOTION_SENSITIVITY)
        case "$MOTION_SENSITIVITY" in
            1|2|3|4|5|6|7|8|9|10) ;;
            *) MOTION_SENSITIVITY=5 ;;
        esac

        # Start the stock local MP4 writer once when either the legacy local
        # recording option or lightweight motion recording needs it.
        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] || { [[ "$MOTION_ENABLED" == "yes" ]] && [[ "$MOTION_RECORD" == "yes" ]]; }; then
            if [[ $(get_config TIME_OSD) == "yes" ]] ; then
                (sleep 30; export TZP=`TZ=$TZ_TMP date +%z`; export TZP=${TZP:0:3}:${TZP:3:2}; export TZ=GMT$TZP; ./mp4record) &
            else
                ./mp4record &
            fi
        fi

        if [[ "$MOTION_ENABLED" == "yes" ]] ; then
            MOTIOND_ARGS="-s $MOTION_SENSITIVITY -i 250"
            if [[ "$MOTION_RECORD" == "yes" ]] ; then
                ipc_cmd -v detect
                MOTIOND_ARGS="$MOTIOND_ARGS -R"
            fi
            /tmp/sd/yi-hack/bin/motiond $MOTIOND_ARGS >/tmp/motiond.log 2>&1 &
        fi

        # Strict local-only: vendor cloud intentionally not started.

        if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then
            ipc_cmd -1
            sleep 0.5
            if [[ "$MOTION_ENABLED" == "yes" ]] ; then
                : # motiond replaces the stock PilotAI motion detector.
            else
'''
if old not in s:
    raise SystemExit('target block not found')
p.write_text(s.replace(old, new, 1))
