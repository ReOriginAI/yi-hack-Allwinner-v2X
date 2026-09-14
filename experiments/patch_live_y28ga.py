from pathlib import Path

base = Path('/tmp/yi197-local')

# Patch live system.sh minimally: local buffer kick only, no cloud restart.
p = base / 'system.sh'
s = p.read_text()
old = '''start_buffer()\n{\n    # Trick to start circular buffer filling\n    ./cloud &\n    IDX=`hexdump -n 16 /dev/shm/fshare_frame_buf | awk 'NR==1{print $8}'`\n    N=0\n    while [ "$IDX" -eq "0000" ] && [ $N -lt 60 ]; do\n        IDX=`hexdump -n 16 /dev/shm/fshare_frame_buf | awk 'NR==1{print $8}'`\n        N=$(($N+1))\n        sleep 0.2\n    done\n    killall cloud\n    ipc_cmd -x\n}\n'''
new = '''start_buffer()\n{\n    # Strict local-only mode: never execute vendor cloud.\n    # y28ga firmware 9.x was verified to keep both H264 streams flowing with this IPC kick.\n    ipc_cmd -x\n}\n'''
if old not in s:
    raise SystemExit('unexpected live system.sh start_buffer')
s = s.replace(old, new, 1)
old2 = '''        fi\n        ./cloud &\n\n        if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then\n'''
new2 = '''        fi\n        # Strict local-only: vendor cloud intentionally not started.\n\n        if [ "$HV" == "11" ] || [ "$HV" == "12" ]; then\n'''
# Replace only the occurrence in the DISABLE_CLOUD branch (last matching occurrence).
pos = s.rfind(old2)
if pos < 0:
    raise SystemExit('unexpected live disabled-cloud branch')
s = s[:pos] + s[pos:].replace(old2, new2, 1)
p.write_text(s)

# Force existing and future live configs to local-only.
p = base / 'check_conf.sh'
s = p.read_text()
s = s.replace('DISABLE_CLOUD=no\nREC_WITHOUT_CLOUD=no', 'DISABLE_CLOUD=yes\nREC_WITHOUT_CLOUD=no', 1)
needle = '''done\n\nif [ ! -f $CAMERA_CONF_FILE ]; then\n'''
insert = '''done\n\n# Local-only build: Yi vendor cloud is intentionally and permanently disabled.\nif grep -q '^DISABLE_CLOUD=' "$SYSTEM_CONF_FILE" 2>/dev/null; then\n    sed -i 's/^DISABLE_CLOUD=.*/DISABLE_CLOUD=yes/' "$SYSTEM_CONF_FILE"\nelse\n    echo 'DISABLE_CLOUD=yes' >> "$SYSTEM_CONF_FILE"\nfi\n\nif [ ! -f $CAMERA_CONF_FILE ]; then\n'''
if needle not in s:
    raise SystemExit('unexpected live check_conf.sh')
s = s.replace(needle, insert, 1)
p.write_text(s)

# Replace the live cloud toggle with a fixed disabled status.
p = base / 'configurations.html'
s = p.read_text()
s = s.replace('In this page you can enable and disable services, change the camera hostname, disable the cloud features and more.',
              'In this page you can configure local services and change the camera hostname. Yi vendor cloud is disabled by this local-only build.')
old = '''<tr class="row">\n<td>Disable Cloud</td>                        <td>                            <label class="switch small">                                <input type="checkbox" data-key="DISABLE_CLOUD"><span class="slider round"></span>                                <span class="switch-text"></span>                            </label>                            <span class="switch-description">                                Disable the Yi App and all the Cloud features (aka private mode).                            </span>                        </td>                    </tr>'''
new = '''<tr class="row">\n<td>Yi Cloud</td>                        <td>                            <span class="strong">Disabled</span>                            <span class="switch-description">                                Vendor cloud, Yi App cloud connectivity, and cloud-dependent services are disabled by this local-only build.                            </span>                        </td>                    </tr>'''
if old not in s:
    raise SystemExit('unexpected live cloud HTML block')
s = s.replace(old, new, 1)
s = s.replace('Enable recording on the SD card even with the Cloud features disabled. (It takes effect only if the "Disable Cloud" option is enabled).',
              'Enable the stock SD-card recorder while the camera operates in local-only mode.')
p.write_text(s)

print('live y28ga local-only candidates patched')
