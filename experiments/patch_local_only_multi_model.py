from pathlib import Path

root = Path('.')

# 1) Cloud is permanently disabled in this local-only build.
p = root / 'src/static/static/yi-hack/script/check_conf.sh'
s = p.read_text()
s = s.replace('DISABLE_CLOUD=no\nREC_WITHOUT_CLOUD=no', 'DISABLE_CLOUD=yes\nREC_WITHOUT_CLOUD=no', 1)
marker = 'for i in $PARMS1\ndo\n'
# Normalize existing installations too, not just fresh config files.
insert_after = '''done\n\n# Local-only build: Yi vendor cloud is intentionally and permanently disabled.\nif grep -q '^DISABLE_CLOUD=' "$SYSTEM_CONF_FILE" 2>/dev/null; then\n    sed -i 's/^DISABLE_CLOUD=.*/DISABLE_CLOUD=yes/' "$SYSTEM_CONF_FILE"\nelse\n    echo 'DISABLE_CLOUD=yes' >> "$SYSTEM_CONF_FILE"\nfi\n\n'''
needle = '''done\n\nif [ ! -f $CAMERA_CONF_FILE ]; then\n'''
if insert_after not in s:
    if needle not in s:
        raise SystemExit('check_conf insertion point not found')
    s = s.replace(needle, insert_after + 'if [ ! -f $CAMERA_CONF_FILE ]; then\n', 1)
p.write_text(s)

# 2) Strict cloudless buffer kick and no cloud restart in the disabled branch.
p = root / 'src/static/static/yi-hack/script/system.sh'
s = p.read_text()
old = '''start_buffer()\n{\n    # Trick to start circular buffer filling\n    ./cloud &\n    IDX=`hexdump -n 16 /dev/shm/fshare_frame_buf | awk 'NR==1{print $8}'`\n    N=0\n    while [ "$IDX" -eq "0000" ] && [ $N -lt 60 ]; do\n        IDX=`hexdump -n 16 /dev/shm/fshare_frame_buf | awk 'NR==1{print $8}'`\n        N=$(($N+1))\n        sleep 0.2\n    done\n    killall cloud\n    ipc_cmd -x\n}\n'''
new = '''start_buffer()\n{\n    # Strict local-only mode: never execute vendor cloud.\n    # The local IPC kick is sufficient to start/keep the shared encoded buffer flowing\n    # on the tested Allwinner y623 and y28ga firmware families.\n    ipc_cmd -x\n}\n'''
if old in s:
    s = s.replace(old, new, 1)
elif 'Strict local-only mode: never execute vendor cloud.' not in s:
    raise SystemExit('system.sh start_buffer shape not recognized')

old_disabled = '''        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then\n            $START_STOP_SCRIPT mp4record start\n        fi\n        ./cloud &\n\n        if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then\n'''
new_disabled = '''        if [[ $(get_config REC_WITHOUT_CLOUD) == "yes" ]] ; then\n            $START_STOP_SCRIPT mp4record start\n        fi\n        # Strict local-only: vendor cloud intentionally not started.\n\n        if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then\n'''
if old_disabled in s:
    s = s.replace(old_disabled, new_disabled, 1)
elif '# Strict local-only: vendor cloud intentionally not started.' not in s:
    raise SystemExit('system.sh disabled-cloud branch shape not recognized')
p.write_text(s)

# 3) Model-aware motion service: mount debugfs if necessary, but gracefully skip
# old encoder stacks (e.g. y28ga/firmware 9.x) that do not expose mpp/ve.
p = root / 'src/static/static/yi-hack/script/motion_service.sh'
s = p.read_text()
if 'MODEL_SUFFIX=' not in s:
    s = s.replace('SERVICE="$YI_HACK_PREFIX/script/service.sh"\n', 'SERVICE="$YI_HACK_PREFIX/script/service.sh"\nMODEL_SUFFIX=$(cat "$YI_HACK_PREFIX/model_suffix" 2>/dev/null)\n', 1)
helper = '''\nensure_motion_stats()\n{\n    if [ -r /sys/kernel/debug/mpp/ve ]; then\n        return 0\n    fi\n\n    # Some firmware does not mount debugfs during non-interactive boot.\n    if ! grep -q ' /sys/kernel/debug debugfs ' /proc/mounts 2>/dev/null; then\n        mount -t debugfs none /sys/kernel/debug >/dev/null 2>&1 || true\n    fi\n\n    [ -r /sys/kernel/debug/mpp/ve ]\n}\n'''
if 'ensure_motion_stats()' not in s:
    anchor = '\nmotion_sensitivity()\n'
    if anchor not in s:
        raise SystemExit('motion_service helper insertion point not found')
    s = s.replace(anchor, helper + anchor, 1)

check = '''    if [ ! -x "$MOTIOND" ]; then\n        echo "motiond binary not found: $MOTIOND" >&2\n        return 1\n    fi\n\n    SENS=$(motion_sensitivity)\n'''
replace = '''    if [ ! -x "$MOTIOND" ]; then\n        echo "motiond binary not found: $MOTIOND" >&2\n        return 1\n    fi\n\n    if ! ensure_motion_stats; then\n        stop_owned_mp4record\n        echo 0 > "$STATEFILE"\n        echo "motiond unsupported on ${MODEL_SUFFIX:-unknown}: /sys/kernel/debug/mpp/ve unavailable" > "$LOGFILE"\n        return 0\n    fi\n\n    SENS=$(motion_sensitivity)\n'''
if check in s:
    s = s.replace(check, replace, 1)
elif 'motiond unsupported on ${MODEL_SUFFIX:-unknown}' not in s:
    raise SystemExit('motion_service start check shape not recognized')
p.write_text(s)

# 4) UI: Cloud is a status, not a toggle. Keep local recording control separate.
p = root / 'src/www/httpd/htdocs/pages/configurations.html'
s = p.read_text()
s = s.replace('In this page you can enable and disable services, change the camera hostname, disable the cloud features and more.',
              'In this page you can configure local services and change the camera hostname. Yi vendor cloud is disabled by this local-only build.')
old_cloud = '''                    <tr class="row">\n                        <td>Disable Cloud</td>\n                        <td>\n                            <label class="switch small">\n                                <input type="checkbox" data-key="DISABLE_CLOUD"/>\n                                <span class="slider round"></span>\n                                <span class="switch-text"></span>\n                            </label>\n                            <span class="switch-description">\n                                Disable the Yi App and all the Cloud features (aka private mode).\n                            </span>\n                        </td>\n                    </tr>\n'''
new_cloud = '''                    <tr class="row">\n                        <td>Yi Cloud</td>\n                        <td>\n                            <span class="strong">Disabled</span>\n                            <span class="switch-description">\n                                Vendor cloud, Yi App cloud connectivity, and cloud-dependent services are disabled by this local-only build.\n                            </span>\n                        </td>\n                    </tr>\n'''
if old_cloud in s:
    s = s.replace(old_cloud, new_cloud, 1)
elif '<td>Yi Cloud</td>' not in s:
    raise SystemExit('cloud UI block not found')
s = s.replace('Enable recording on the SD card even with the Cloud features disabled. (It takes effect only if the "Disable Cloud" option is enabled).',
              'Enable the stock SD-card recorder while the camera operates in local-only mode.')
p.write_text(s)

print('local-only multi-model patch applied')
