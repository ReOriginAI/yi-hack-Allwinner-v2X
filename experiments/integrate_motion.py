from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    if old not in s:
        raise SystemExit(f"missing expected text in {path}: {old[:80]!r}")
    s2 = s.replace(old, new, count)
    p.write_text(s2)

# Defaults / config migration target.
replace(
    "src/static/static/yi-hack/etc/camera.conf",
    "MOTION_DETECTION=no\nSENSITIVITY=low",
    "MOTION_DETECTION=no\nMOTION_SENSITIVITY=5\nSENSITIVITY=low",
)
replace(
    "src/static/static/yi-hack/script/check_conf.sh",
    "MOTION_DETECTION=no\nSENSITIVITY=low",
    "MOTION_DETECTION=no\nMOTION_SENSITIVITY=5\nSENSITIVITY=low",
)

# service.sh: singleton mp4record plus motion service lifecycle.
service = "src/static/static/yi-hack/script/service.sh"
replace(
    service,
    '''    elif [ "$NAME" == "mp4record" ]; then\n        cd /home/app\n        if [[ $(get_config TIME_OSD) == "yes" ]] ; then\n            TZP=`TZ=$TZ_TMP date +%z`\n            TZP=${TZP:0:3}:${TZP:3:2}\n            TZ=GMT$TZP ./mp4record > /dev/null &\n        else\n            ./mp4record > /dev/null &\n        fi\n    elif [ "$NAME" == "all" ]; then''',
    '''    elif [ "$NAME" == "mp4record" ]; then\n        # mp4record is not internally singleton-safe. Never start a duplicate.\n        MP4_COUNT=$(ps | grep mp4record | grep -v grep | grep -c '^')\n        if [ "$MP4_COUNT" -eq 0 ]; then\n            cd /home/app\n            if [[ $(get_config TIME_OSD) == "yes" ]] ; then\n                TZP=`TZ=$TZ_TMP date +%z`\n                TZP=${TZP:0:3}:${TZP:3:2}\n                TZ=GMT$TZP ./mp4record > /dev/null &\n            else\n                ./mp4record > /dev/null &\n            fi\n        fi\n    elif [ "$NAME" == "motion" ]; then\n        $YI_HACK_PREFIX/script/motion_service.sh start\n    elif [ "$NAME" == "all" ]; then''',
)
replace(
    service,
    '''        mqtt-config > /dev/null &\n        cd /home/app\n        if [[ $(get_config TIME_OSD) == "yes" ]] ; then\n            TZP=`TZ=$TZ_TMP date +%z`\n            TZP=${TZP:0:3}:${TZP:3:2}\n            TZ=GMT$TZP ./mp4record > /dev/null &\n        else\n            ./mp4record > /dev/null &\n        fi\n    fi\nelif [ "$ACTION" == "stop" ] ; then''',
    '''        mqtt-config > /dev/null &\n        $YI_HACK_PREFIX/script/service.sh mp4record start\n        $YI_HACK_PREFIX/script/motion_service.sh start\n    fi\nelif [ "$ACTION" == "stop" ] ; then''',
)
replace(
    service,
    '''    elif [ "$NAME" == "mp4record" ]; then\n        killall mp4record\n    elif [ "$NAME" == "all" ]; then''',
    '''    elif [ "$NAME" == "mp4record" ]; then\n        if [ $(ps | grep mp4record | grep -v grep | grep -c '^') -gt 0 ]; then\n            killall mp4record\n        fi\n    elif [ "$NAME" == "motion" ]; then\n        $YI_HACK_PREFIX/script/motion_service.sh stop\n    elif [ "$NAME" == "all" ]; then''',
)
replace(
    service,
    '''        killall mqtt-config\n        killall mqttv4\n        killall mp4record\n    fi\nelif [ "$ACTION" == "status" ] ; then''',
    '''        killall mqtt-config\n        killall mqttv4\n        $YI_HACK_PREFIX/script/motion_service.sh stop\n        if [ $(ps | grep mp4record | grep -v grep | grep -c '^') -gt 0 ]; then\n            killall mp4record\n        fi\n    fi\nelif [ "$ACTION" == "status" ] ; then''',
)
replace(
    service,
    '''    elif [ "$NAME" == "mp4record" ]; then\n        RES=$(ps_program mp4record)\n    elif [ "$NAME" == "all" ]; then''',
    '''    elif [ "$NAME" == "mp4record" ]; then\n        RES=$(ps_program mp4record)\n    elif [ "$NAME" == "motion" ]; then\n        RES=$($YI_HACK_PREFIX/script/motion_service.sh status)\n    elif [ "$NAME" == "all" ]; then''',
)

# system.sh: use singleton service for local recorder and start local motion after rmm init.
system = "src/static/static/yi-hack/script/system.sh"
replace(
    system,
    '''        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then\n            if [[ $(get_config TIME_OSD) == "yes" ]] ; then\n                (sleep 30; export TZP=`TZ=$TZ_TMP date +%z`; export TZP=${TZP:0:3}:${TZP:3:2}; export TZ=GMT$TZP; ./mp4record) &\n            else\n                ./mp4record &\n            fi\n        fi''',
    '''        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then\n            $START_STOP_SCRIPT mp4record start\n        fi''',
)
replace(
    system,
    '''log "Yi processes started successfully" 1\n\n# The cam works in GMT time when the hack is disabled''',
    '''log "Yi processes started successfully" 1\n\n# Low-RAM H264-statistics motion detector. The service is a no-op unless\n# DISABLE_CLOUD=yes and MOTION_DETECTION=yes.\n$START_STOP_SCRIPT motion start\n\n# The cam works in GMT time when the hack is disabled''',
)

# Runtime camera CGI: accept numeric local sensitivity and delegate local mode to motion_service.
cgi = "src/www/httpd/cgi-bin/camera_settings.sh"
replace(cgi, "for I in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15", "for I in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16")
replace(
    cgi,
    '''    elif [ "$CONF" == "sensitivity" ] ; then\n        if [ "$VAL" == "low" ] || [ "$VAL" == "medium" ] || [ "$VAL" == "high" ]; then\n            ipc_cmd -s $VAL\n        fi''',
    '''    elif [ "$CONF" == "sensitivity" ] ; then\n        if [ "$VAL" == "low" ] || [ "$VAL" == "medium" ] || [ "$VAL" == "high" ]; then\n            ipc_cmd -s $VAL\n        fi\n    elif [ "$CONF" == "motion_sensitivity" ] ; then\n        case "$VAL" in\n            1|2|3|4|5|6|7|8|9|10) MOTION_SENSITIVITY=$VAL ;;\n        esac''',
)
old_tail = '''if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then\n    if [ "$MOTION_DETECTION" == "no" ]; then\n        ipc_cmd -O off\n\n        if [ "$AI_HUMAN_DETECTION" == "no" ]; then\n            ipc_cmd -a off\n        else\n            ipc_cmd -a on\n        fi\n        if [ "$AI_VEHICLE_DETECTION" == "no" ]; then\n            ipc_cmd -E off\n        else\n            ipc_cmd -E on\n        fi\n        if [ "$AI_ANIMAL_DETECTION" == "no" ]; then\n            ipc_cmd -N off\n        else\n            ipc_cmd -N on\n        fi\n    else\n        ipc_cmd -O on\n    fi\nelse\n    if [ "$AI_HUMAN_DETECTION" == "no" ]; then\n        ipc_cmd -a off\n    else\n        ipc_cmd -a on\n    fi\nfi'''
new_tail = '''DISABLE_CLOUD=$(grep -w DISABLE_CLOUD $YI_HACK_PREFIX/etc/system.conf | cut -d "=" -f2-)\nif [ "$DISABLE_CLOUD" == "yes" ]; then\n    # In local-only mode MOTION_DETECTION is provided by motiond, not YI/Pilot AI.\n    $YI_HACK_PREFIX/script/motion_service.sh restart\nelse\n    if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then\n        if [ "$MOTION_DETECTION" == "no" ]; then\n            ipc_cmd -O off\n\n            if [ "$AI_HUMAN_DETECTION" == "no" ]; then\n                ipc_cmd -a off\n            else\n                ipc_cmd -a on\n            fi\n            if [ "$AI_VEHICLE_DETECTION" == "no" ]; then\n                ipc_cmd -E off\n            else\n                ipc_cmd -E on\n            fi\n            if [ "$AI_ANIMAL_DETECTION" == "no" ]; then\n                ipc_cmd -N off\n            else\n                ipc_cmd -N on\n            fi\n        else\n            ipc_cmd -O on\n        fi\n    else\n        if [ "$AI_HUMAN_DETECTION" == "no" ]; then\n            ipc_cmd -a off\n        else\n            ipc_cmd -a on\n        fi\n    fi\nfi'''
replace(cgi, old_tail, new_tail)

# Web UI: keep legacy sensitivity and add the local 1..10 control; persist configs before runtime apply.
js = "src/www/httpd/htdocs/js/modules/camera_settings.js"
replace(
    js,
    'if(key=="SENSITIVITY" || key=="SOUND_SENSITIVITY" || key=="CRUISE")',
    'if(key=="SENSITIVITY" || key=="MOTION_SENSITIVITY" || key=="SOUND_SENSITIVITY" || key=="CRUISE")',
)
replace(
    js,
    '''        configs["SENSITIVITY"] = $('select[data-key="SENSITIVITY"]').prop('value');\n        configs["SOUND_SENSITIVITY"] = $('select[data-key="SOUND_SENSITIVITY"]').prop('value');''',
    '''        configs["SENSITIVITY"] = $('select[data-key="SENSITIVITY"]').prop('value');\n        configs["MOTION_SENSITIVITY"] = $('select[data-key="MOTION_SENSITIVITY"]').prop('value');\n        configs["SOUND_SENSITIVITY"] = $('select[data-key="SOUND_SENSITIVITY"]').prop('value');''',
)
old_ajax = '''        $.ajax({\n            type: "GET",\n            url: 'cgi-bin/camera_settings.sh?' +\n                'save_video_on_motion=' + configs["SAVE_VIDEO_ON_MOTION"] +\n                '&motion_detection=' + configs["MOTION_DETECTION"] +\n                '&sensitivity=' + configs["SENSITIVITY"] +\n                '&ai_human_detection=' + configs["AI_HUMAN_DETECTION"] +\n                '&ai_vehicle_detection=' + configs["AI_VEHICLE_DETECTION"] +\n                '&ai_animal_detection=' + configs["AI_ANIMAL_DETECTION"] +\n                '&face_detection=' + configs["FACE_DETECTION"] +\n                '&motion_tracking=' + configs["MOTION_TRACKING"] +\n                '&sound_detection=' + configs["SOUND_DETECTION"] +\n                '&sound_sensitivity=' + configs["SOUND_SENSITIVITY"] +\n                '&led=' + configs["LED"] +\n                '&ir=' + configs["IR"] +\n                '&rotate=' + configs["ROTATE"] +\n                '&cruise=' + configs["CRUISE"] +\n                '&switch_on=' + configs["SWITCH_ON"],\n            dataType: "json",\n            success: function(response) {\n                saveStatusElem.text("Saved");\n            },\n            error: function(response) {\n                saveStatusElem.text("Error while saving");\n                console.log('error', response);\n            }\n        });'''
new_ajax = '''        $.ajax({\n            type: "POST",\n            url: 'cgi-bin/set_configs.sh?conf=camera',\n            data: JSON.stringify(configs),\n            dataType: "json",\n            success: function(response) {\n                $.ajax({\n                    type: "GET",\n                    url: 'cgi-bin/camera_settings.sh?' +\n                        'save_video_on_motion=' + configs["SAVE_VIDEO_ON_MOTION"] +\n                        '&motion_detection=' + configs["MOTION_DETECTION"] +\n                        '&motion_sensitivity=' + configs["MOTION_SENSITIVITY"] +\n                        '&sensitivity=' + configs["SENSITIVITY"] +\n                        '&ai_human_detection=' + configs["AI_HUMAN_DETECTION"] +\n                        '&ai_vehicle_detection=' + configs["AI_VEHICLE_DETECTION"] +\n                        '&ai_animal_detection=' + configs["AI_ANIMAL_DETECTION"] +\n                        '&face_detection=' + configs["FACE_DETECTION"] +\n                        '&motion_tracking=' + configs["MOTION_TRACKING"] +\n                        '&sound_detection=' + configs["SOUND_DETECTION"] +\n                        '&sound_sensitivity=' + configs["SOUND_SENSITIVITY"] +\n                        '&led=' + configs["LED"] +\n                        '&ir=' + configs["IR"] +\n                        '&rotate=' + configs["ROTATE"] +\n                        '&cruise=' + configs["CRUISE"] +\n                        '&switch_on=' + configs["SWITCH_ON"],\n                    dataType: "json",\n                    success: function(response) {\n                        saveStatusElem.text("Saved");\n                    },\n                    error: function(response) {\n                        saveStatusElem.text("Saved, but runtime apply failed");\n                        console.log('error', response);\n                    }\n                });\n            },\n            error: function(response) {\n                saveStatusElem.text("Error while saving");\n                console.log('error', response);\n            }\n        });'''
replace(js, old_ajax, new_ajax)

html = "src/www/httpd/htdocs/pages/camera_settings.html"
old_row = '''                    <tr class="row">\n                        <td>Detection sensitivity</td>\n                        <td>\n                            <div class="standard-select">\n                                <select data-key="SENSITIVITY" id="SENSITIVITY">\n                                    <option value="low">Low</option>\n                                    <option value="medium">Medium</option>\n                                    <option value="high">High</option>\n                                </select>\n                            </div>\n                        </td>\n                    </tr>'''
new_row = old_row + '''\n                    <tr class="row">\n                        <td>Local motion sensitivity</td>\n                        <td>\n                            <div class="standard-select">\n                                <select data-key="MOTION_SENSITIVITY" id="MOTION_SENSITIVITY">\n                                    <option value="1">1 - Lowest</option>\n                                    <option value="2">2</option>\n                                    <option value="3">3</option>\n                                    <option value="4">4</option>\n                                    <option value="5">5 - Recommended</option>\n                                    <option value="6">6</option>\n                                    <option value="7">7</option>\n                                    <option value="8">8</option>\n                                    <option value="9">9</option>\n                                    <option value="10">10 - Highest</option>\n                                </select>\n                            </div>\n                            <span class="switch-description">\n                                Sensitivity for the low-RAM H264 encoder-statistics detector used in local-only mode.\n                            </span>\n                        </td>\n                    </tr>'''
replace(html, old_row, new_row)
replace(
    html,
    "Enable/disable generic Motion Detection (if you select this option, all AI detections will be disabled).",
    "Enable/disable Motion Detection. In local-only mode this uses low-RAM H264 encoder statistics instead of the YI/Pilot AI pipeline.",
)

print("motion integration source patch complete")
