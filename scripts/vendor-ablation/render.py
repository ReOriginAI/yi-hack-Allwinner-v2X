#!/usr/bin/env python3
"""Render a self-contained internal bootstrap for the two audited firmwares."""
import argparse
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIRMWARE = {'y623': '12.0.51.01_202303091901', 'y28ga': '9.0.20.06_202007061841'}
RMM = {'y623': 'f8164a1c221ba8c1d4888322a3cf0706', 'y28ga': '46261d809c58dea5b39f3351e322d710'}
REQUIRED = ('bin/hostapd', 'bin/hostapd_cli', 'script/storage.sh', 'script/hotspot.sh', 'script/service_lock.sh', 'script/operation_timeout.sh', 'script/wifi_recovery.sh', 'script/wifi_failover.sh', 'script/wifi_station_guard.sh', 'bin/service_guard', 'bin/busybox', 'www/onvif/onvif_simple_server', 'script/log_store.sh', 'script/bounded_log.sh', 'script/config_work.sh',
            'script/restore_config.sh', 'script/motion_log.sh', 'script/motion_settings.sh', 'script/motion_service.sh', 'bin/motiond', 'script/system.sh', 'script/service.sh', 'script/wd.sh', 'script/check_conf.sh',
            'script/configure_wifi.sh', 'script/wifidhcp.sh', 'script/ethdhcp.sh',
            'script/prepare_rmm.sh', 'script/prepare_mp4record.sh', 'script/rtsp_stream_venc.sh', 'script/ensure_y623_ve_kernel.sh',
            'lib/ipc_multiplex.so', 'bin/cloudAPI',
            'bin/cloudAPI_fake', 'bin/ipc_cmd', 'script/nightvision.sh', 'bin/nightvisionctl', 'lib/nightvision.so', 'lib/motion_map.so', 'bin/motion_ivactl', 'lib/motion_iva.so',
            'script/time_config.sh', 'script/manual_time.sh', 'www/cgi-bin/clock.sh', 'script/apply_time.sh', 'script/update_osd_tz.sh', 'bin/set_tz_offset',
            'lib/record_metadata.so', 'bin/ipc2file',
            'lib/record_preroll-y623.bin', 'lib/record_preroll-y28ga.bin')


def render(model, noop, sd, flash=False):
    text = (Path(__file__).with_name('bootstrap.sh.in')).read_text()
    api = (ROOT / 'src/static/static/yi-hack/bin/cloudAPI_fake').read_text().rstrip()
    required = REQUIRED + (('script/flash_storage.sh', 'script/flash_config_sync.sh', 'script/flash_mount_sd.sh', 'script/flash_dispatch.sh', 'bin/imggrabber', 'bin/imggrabber-grid') if flash else ())
    manifest = ''.join(hashlib.md5((sd / f).read_bytes()).hexdigest() + '  ' + f + '\n' for f in required)
    hw = ''
    if model == 'y623':
        hw += '''echo 198 > /sys/class/gpio/export
echo out > /sys/class/gpio/gpio198/direction
echo 0 > /sys/class/gpio/gpio198/value
sleep 1
echo 1 > /sys/class/gpio/gpio198/value
'''
    hw += '''insmod /backup/ko/8189fs.ko || boot_fail wifi-module
for module in videobuf2-core videobuf2-memops videobuf2-dma-contig videobuf2-v4l2 vin_io cam_sensor vin_v4l2; do
    insmod "/home/base/ko/$module.ko" || boot_fail "$module"
done
'''
    if model == 'y28ga':
        hw += 'insmod /backup/ko/icplus.ko || boot_fail ethernet-module\n'
    hw += '''insmod /home/base/ko/sunxi_gpadc.ko || boot_fail adc
sleep 1
ifconfig lo up
ifconfig wlan0 up || boot_fail wlan0
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
    if flash:
        text = text.replace('export DEVICE_MEMORY=8000000 CPU_MEMORY=-1',
                            '/bin/sh /home/yi-hack/script/flash_dispatch.sh || boot_fail flash-dispatch\nexport DEVICE_MEMORY=8000000 CPU_MEMORY=-1')
        text = text.replace('export DEVICE_MEMORY=8000000 CPU_MEMORY=-1',
                            'mount --bind /home/yi-hack/script/flash_mount_sd.sh /home/app/script/mount_sd.sh || boot_fail sd-mount-hook\nexport DEVICE_MEMORY=8000000 CPU_MEMORY=-1')
        text = text.replace('mount -t vfat /dev/mmcblk0p1 /tmp/sd || mount -t vfat /dev/mmcblk0 /tmp/sd || boot_fail no-sd',
                            '. /home/yi-hack/script/flash_storage.sh || boot_fail storage-helper\nflash_storage_init || boot_fail flash-storage')
        start = text.index('if [ -e /tmp/sd/Factory/factory_test.sh ]; then')
        end = text.index('\nfi', start) + 3
        text = text[:start] + '# Flash profile never executes installers from the data card.\n' + text[end:]
        patched = {'y623':'eb9d532e71d0d8697d22d0775b744b40', 'y28ga':'14aa4ee21e04fb40a3c321fdcd12eef4'}
        text = text.replace(RMM[model], patched[model])
        text = text.replace('y623:033ff9e7091c72ab2209eaac74ad802e|y28ga:c6ae77baf1821023c2138cf46bb793ec)',
                            'y623:033ff9e7091c72ab2209eaac74ad802e|y623:f4e457a4cc195460e5f6a63bd46351ef|y28ga:c6ae77baf1821023c2138cf46bb793ec|y28ga:2388704364446d01857c3cf11937f3f4)')
    return text


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('model', choices=FIRMWARE)
    p.add_argument('noop', type=Path)
    p.add_argument('sd_root', type=Path)
    p.add_argument('output', type=Path)
    a = p.parse_args()
    a.output.write_text(render(a.model, a.noop.read_bytes(), a.sd_root))
