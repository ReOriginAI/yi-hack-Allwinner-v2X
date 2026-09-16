#!/usr/bin/env python3
"""Render a self-contained internal bootstrap for the two audited firmwares."""
import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIRMWARE = {'y623': '12.0.51.01_202303091901', 'y28ga': '9.0.20.06_202007061841'}
RMM = {'y623': 'f8164a1c221ba8c1d4888322a3cf0706', 'y28ga': '46261d809c58dea5b39f3351e322d710'}
REQUIRED = ('script/system.sh', 'script/service.sh', 'script/check_conf.sh',
            'script/configure_wifi.sh', 'script/wifidhcp.sh', 'script/ethdhcp.sh',
            'script/prepare_rmm.sh', 'lib/ipc_multiplex.so', 'bin/cloudAPI',
            'bin/cloudAPI_fake', 'bin/ipc_cmd')


def render(model, noop, sd):
    text = (Path(__file__).with_name('bootstrap.sh.in')).read_text()
    api = (ROOT / 'src/static/static/yi-hack/bin/cloudAPI_fake').read_text().rstrip()
    manifest = ''.join(hashlib.md5((sd / f).read_bytes()).hexdigest() + '  ' + f + '\n' for f in REQUIRED)
    hw = ''
    if model == 'y623':
        hw += '''echo 198 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio198/direction
echo 0 > /sys/class/gpio/gpio198/value
sleep 1
echo 1 > /sys/class/gpio/gpio198/value
'''
    hw += '''insmod /backup/ko/8189fs.ko || fail_closed wifi-module
for module in videobuf2-core videobuf2-memops videobuf2-dma-contig videobuf2-v4l2 vin_io cam_sensor vin_v4l2; do
    insmod "/home/base/ko/$module.ko" || fail_closed "$module"
done
'''
    if model == 'y28ga':
        hw += 'insmod /backup/ko/icplus.ko || fail_closed ethernet-module\n'
    hw += '''insmod /home/base/ko/sunxi_gpadc.ko || fail_closed adc
sleep 1
ifconfig lo up
ifconfig wlan0 up || fail_closed wlan0
ethmac=d2:$(ifconfig wlan0 | awk '/HWaddr/ {print $5}' | cut -d: -f2-)
ifconfig eth0 hw ether "$ethmac"
ifconfig eth0 up
'''
    values = {'MODEL': model, 'FIRMWARE': FIRMWARE[model], 'HARDWARE': hw,
              'NOOP': ''.join('\\%03o' % b for b in noop),
              'NOOP_MD5': hashlib.md5(noop).hexdigest(), 'CLOUD_API': api,
              'SD_MANIFEST': manifest.rstrip(), 'RMM_MD5': RMM[model]}
    for key, value in values.items():
        text = text.replace('@' + key + '@', value)
    return text


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('model', choices=FIRMWARE)
    p.add_argument('noop', type=Path)
    p.add_argument('sd_root', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    a.output.write_text(render(a.model, a.noop.read_bytes(), a.sd_root))
