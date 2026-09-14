from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"missing expected text in {path}: {old[:100]!r}")
    p.write_text(s.replace(old, new, count))

service = "/tmp/yi150-motion/service.sh"
replace(service,
'''    elif [ "$NAME" == "mp4record" ]; then
        cd /home/app
        if [[ $(get_config TIME_OSD) == "yes" ]] ; then
            TZP=`TZ=$TZ_TMP date +%z`
            TZP=${TZP:0:3}:${TZP:3:2}
            TZ=GMT$TZP ./mp4record > /dev/null &
        else
            ./mp4record > /dev/null &
        fi
    elif [ "$NAME" == "all" ]; then''',
'''    elif [ "$NAME" == "mp4record" ]; then
        # mp4record is not internally singleton-safe. Never start a duplicate.
        MP4_COUNT=$(ps | grep mp4record | grep -v grep | grep -c '^')
        if [ "$MP4_COUNT" -eq 0 ]; then
            cd /home/app
            if [[ $(get_config TIME_OSD) == "yes" ]] ; then
                TZP=`TZ=$TZ_TMP date +%z`
                TZP=${TZP:0:3}:${TZP:3:2}
                TZ=GMT$TZP ./mp4record > /dev/null &
            else
                ./mp4record > /dev/null &
            fi
        fi
    elif [ "$NAME" == "motion" ]; then
        $YI_HACK_PREFIX/script/motion_service.sh start
    elif [ "$NAME" == "all" ]; then''')
replace(service,
'''        mqtt-config > /dev/null &
        cd /home/app
        if [[ $(get_config TIME_OSD) == "yes" ]] ; then
            TZP=`TZ=$TZ_TMP date +%z`
            TZP=${TZP:0:3}:${TZP:3:2}
            TZ=GMT$TZP ./mp4record > /dev/null &
        else
            ./mp4record > /dev/null &
        fi
    fi
elif [ "$ACTION" == "stop" ] ; then''',
'''        mqtt-config > /dev/null &
        $YI_HACK_PREFIX/script/service.sh mp4record start
        $YI_HACK_PREFIX/script/motion_service.sh start
    fi
elif [ "$ACTION" == "stop" ] ; then''')
replace(service,
'''    elif [ "$NAME" == "mp4record" ]; then
        killall mp4record
    elif [ "$NAME" == "all" ]; then''',
'''    elif [ "$NAME" == "mp4record" ]; then
        if [ $(ps | grep mp4record | grep -v grep | grep -c '^') -gt 0 ]; then
            killall mp4record
        fi
    elif [ "$NAME" == "motion" ]; then
        $YI_HACK_PREFIX/script/motion_service.sh stop
    elif [ "$NAME" == "all" ]; then''')
replace(service,
'''        killall mqtt-config
        killall mqttv4
        killall mp4record
    fi
elif [ "$ACTION" == "status" ] ; then''',
'''        killall mqtt-config
        killall mqttv4
        $YI_HACK_PREFIX/script/motion_service.sh stop
        if [ $(ps | grep mp4record | grep -v grep | grep -c '^') -gt 0 ]; then
            killall mp4record
        fi
    fi
elif [ "$ACTION" == "status" ] ; then''')
replace(service,
'''    elif [ "$NAME" == "mp4record" ]; then
        RES=$(ps_program mp4record)
    elif [ "$NAME" == "all" ]; then''',
'''    elif [ "$NAME" == "mp4record" ]; then
        RES=$(ps_program mp4record)
    elif [ "$NAME" == "motion" ]; then
        RES=$($YI_HACK_PREFIX/script/motion_service.sh status)
    elif [ "$NAME" == "all" ]; then''')

system = "/tmp/yi150-motion/system.sh"
replace(system,
'''        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then
            if [[ $(get_config TIME_OSD) == "yes" ]] ; then
                (sleep 30; export TZP=`TZ=$TZ_TMP date +%z`; export TZP=${TZP:0:3}:${TZP:3:2}; export TZ=GMT$TZP; ./mp4record) &
            else
                ./mp4record &
            fi
        fi''',
'''        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then
            $START_STOP_SCRIPT mp4record start
        fi''')
replace(system,
'''log "Yi processes started successfully" 1

# The cam works in GMT time when the hack is disabled''',
'''log "Yi processes started successfully" 1

# Low-RAM H264-statistics motion detector. The service is a no-op unless
# DISABLE_CLOUD=yes and MOTION_DETECTION=yes.
$START_STOP_SCRIPT motion start

# The cam works in GMT time when the hack is disabled''')

print("live .150 script patch complete")
