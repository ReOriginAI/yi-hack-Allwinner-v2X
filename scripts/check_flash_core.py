#!/usr/bin/env python3
"""Check an offline candidate's hashes and ARM programs in an isolated root.

Requires bubblewrap and a static qemu-arm. No mounts or devices on a camera are
accessed. Peripheral initialization and a real cold boot remain hardware tests.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def check(candidate, qemu):
    report = json.loads((candidate / 'report.json').read_text())
    for name, item in report['images'].items():
        path = candidate / (name + ('.jffs2' if name == 'backup' else '.squashfs'))
        assert path.stat().st_size == item['bytes']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256']
        assert item['bytes'] <= report['limits'][name]
    trees = candidate / 'trees'
    for name in ['flash-core', 'bin/busybox', 'script/flash_storage.sh',
                 'script/flash_config_sync.sh', 'etc/defaults.tar.bz2']:
        packed = subprocess.check_output(['unsquashfs', '-cat',
                                         str(candidate / 'home.squashfs'), 'yi-hack/' + name])
        assert packed == (trees / 'home/yi-hack' / name).read_bytes(), name
    packed = subprocess.check_output(['unsquashfs', '-cat', str(candidate / 'rootfs.squashfs'),
                                     'lib/libasound.so.2.0.0'])
    assert packed == (trees / 'rootfs/lib/libasound.so.2.0.0').read_bytes()
    command = ['bwrap', '--ro-bind', str(trees / 'rootfs'), '/',
               '--ro-bind', str(trees / 'home'), '/home', '--tmpfs', '/tmp',
               '--dir', '/tmp/sd', '--symlink', '/home/yi-hack', '/tmp/sd/yi-hack',
               '--ro-bind', str(qemu), '/bin/busybox', '--proc', '/proc', '--dev', '/dev',
               '--setenv', 'LD_LIBRARY_PATH',
               '/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/home/yi-hack/lib',
               '/bin/busybox']

    def target(args):
        result = subprocess.run(command + args, capture_output=True, text=True, timeout=15)
        if result.returncode:
            raise RuntimeError(' '.join(args) + '\n' + result.stdout + result.stderr)
        return result.stdout

    bb = '/home/yi-hack/bin/busybox'
    applets = set(target([bb, '--list']).splitlines())
    assert {'ash', 'tar', 'cmp', 'wc', 'tcpsvd', 'ftpd', 'timeout'} <= applets
    target([bb, 'ash', '-c', 'yi_lock flash-image-check || exit $?; '
            '[ -x /tmp/sd/yi-hack/bin/rRTSPServer ] && '
            '[ -x /tmp/sd/yi-hack/script/flash_config_sync.sh ] && '
            '[ ! -x /tmp/sd/yi-hack/bin/go2rtc ]'])
    target([bb, 'tar', 'tjf', '/home/yi-hack/etc/defaults.tar.bz2'])
    for path in sorted((trees / 'home/yi-hack/script').glob('*.sh')):
        target([bb, 'ash', '-n', '/home/yi-hack/script/' + path.name])
    for name in ['rmm', 'dispatch', 'mp4record']:
        target(['/lib/ld-musl-armhf.so.1', '--list', '/home/app/' + name])
    programs = ['rRTSPServer', 'dropbearmulti', 'motiond', 'jq', 'ipc_cmd',
                'onvif_notify_server', 'wsd_simple_server', 'imggrabber', 'service_guard']
    for name in programs:
        target(['/lib/ld-musl-armhf.so.1', '--list', '/home/yi-hack/bin/' + name])
    target(['/lib/ld-musl-armhf.so.1', '--list', '/home/yi-hack/www/onvif/onvif_simple_server'])
    print(f"PASS: {report['model']} hashes, ARM applets, shell syntax, locks, defaults and loaders without SD")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--qemu', type=Path, required=True)
    args = parser.parse_args()
    check(args.candidate.resolve(), args.qemu.resolve())
