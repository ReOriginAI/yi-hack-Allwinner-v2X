#!/usr/bin/env python3
"""Check an offline candidate's hashes and ARM programs in an isolated root.

Requires bubblewrap and a static qemu-arm. No mounts or devices on a camera are
accessed. Peripheral initialization and a real cold boot remain hardware tests.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess


def check(candidate, qemu):
    report = json.loads((candidate / 'report.json').read_text())
    for name, item in report['images'].items():
        path = candidate / (name + ('.jffs2' if name == 'backup' else '.squashfs'))
        assert path.stat().st_size == item['bytes']
        assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256']
        assert item['bytes'] <= report['limits'][name]
    assert not (candidate / 'sd-optional/yi-hack-optional/bin/go2rtc').exists()
    trees = candidate / 'trees'
    assert not (trees / 'home/yi-hack/bin/go2rtc').exists()
    assert not (trees / 'home/yi-hack/bin/go2rtc').is_symlink()
    assert (trees / 'home/yi-hack/bin/hostapd').is_file()
    assert not (trees / 'home/yi-hack/bin/hostapd').is_symlink()
    assert not (trees / 'backup/tools/hostapd').exists()
    assert not (trees / 'home/yi-hack/www/cgi-bin/fw_online.sh').exists()
    for name in ['flash-core', 'bin/busybox', 'script/flash_storage.sh',
                 'script/flash_config_sync.sh', 'etc/defaults.tar.bz2',
                 'www/cgi-bin/fw_upload.sh', 'www/cgi-bin/fw_upgrade.sh']:
        packed = subprocess.check_output(['unsquashfs', '-cat',
                                         str(candidate / 'home.squashfs'), 'yi-hack/' + name])
        assert packed == (trees / 'home/yi-hack' / name).read_bytes(), name
    packed = subprocess.check_output(['unsquashfs', '-cat', str(candidate / 'rootfs.squashfs'),
                                     'lib/libasound.so.2.0.0'])
    assert packed == (trees / 'rootfs/lib/libasound.so.2.0.0').read_bytes()
    # Check early startup against read-only rootfs BEFORE supplying /tmp tmpfs.
    # Older pending dispatchers need this mountpoint to reach their SD repair.
    assert (trees / 'rootfs/tmp/sd').is_dir(), 'missing early SD mountpoint'
    listing = subprocess.check_output(['unsquashfs', '-ll', str(candidate / 'rootfs.squashfs')], text=True)
    assert any(line.endswith('squashfs-root/tmp/sd') for line in listing.splitlines())
    subprocess.run(['bwrap', '--ro-bind', str(trees / 'rootfs'), '/',
                    '--ro-bind', str(trees / 'home'), '/home',
                    '--ro-bind', str(qemu), '/sbin/udevd', '--proc', '/proc', '--dev', '/dev',
                    '--setenv', 'LD_LIBRARY_PATH', '/lib:/usr/lib:/home/yi-hack/lib',
                    '/sbin/udevd', '/bin/busybox', 'mkdir', '-p', '/tmp/sd'],
                   check=True, capture_output=True, timeout=15)
    command = ['bwrap', '--ro-bind', str(trees / 'rootfs'), '/',
               '--ro-bind', str(trees / 'home'), '/home',
               '--ro-bind', str(trees / 'backup'), '/backup', '--tmpfs', '/tmp',
               '--dir', '/tmp/sd', '--symlink', '/home/yi-hack', '/tmp/sd/yi-hack',
               '--ro-bind', str(qemu), '/sbin/udevd', '--proc', '/proc', '--dev', '/dev',
               '--setenv', 'LD_LIBRARY_PATH',
               '/lib:/usr/lib:/home/lib:/home/qigan/lib:/home/app/locallib:/home/yi-hack/lib',
               '/sbin/udevd']

    def target(args, expected=(0,)):
        result = subprocess.run(command + args, capture_output=True, text=True, timeout=15)
        if result.returncode not in expected:
            raise RuntimeError(' '.join(args) + '\n' + result.stdout + result.stderr)
        return result.stdout + result.stderr

    bb = '/home/yi-hack/bin/busybox'
    cgi = '/home/yi-hack/www/cgi-bin/'

    def cgi_json(script, query, expected):
        # Nested ARM execve needs binfmt registration, which is not required by
        # this checker. Route the CGI's utility calls explicitly through QEMU.
        wrappers = ''.join(f'{name}() {{ /sbin/udevd /bin/busybox {name} "$@"; }}; '
                           for name in ('cat', 'cut', 'tr'))
        shell = (wrappers + 'export QUERY_STRING=' + shlex.quote(query) +
                 ' REQUEST_METHOD=POST CONTENT_LENGTH=1000000; . ' + shlex.quote(cgi + script))
        output = target([bb, 'ash', '-c', shell], expected=expected)
        return json.loads(output.split('\n\n', 1)[1])

    info = cgi_json('fw_upgrade.sh', 'get=info&_=1793790000000', (0,))
    assert not info['error'] and info['profile'] == 'flash-core'
    assert not info['upload_supported'] and not info['local_fw']
    assert info['fw_version'] == (trees / 'home/yi-hack/version').read_text().strip()
    for script in ('fw_upload.sh', 'fw_upgrade.sh'):
        error = cgi_json(script, 'get=upgrade', (1,))
        assert error['error'] and 'not supported on flash-core' in error['description']
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
    programs = ['hostapd', 'hostapd_cli', 'rRTSPServer', 'dropbearmulti', 'motiond', 'jq', 'ipc_cmd',
                'onvif_notify_server', 'wsd_simple_server', 'imggrabber-grid', 'service_guard']
    for name in programs:
        target(['/lib/ld-musl-armhf.so.1', '--list', '/home/yi-hack/bin/' + name])
    assert 'hostapd v2.11' in target(['/home/yi-hack/bin/hostapd', '-v'], expected=(0, 1))
    assert 'hostapd_cli v2.11' in target(['/home/yi-hack/bin/hostapd_cli', '-v'])
    target(['/lib/ld-musl-armhf.so.1', '--list', '/home/yi-hack/www/onvif/onvif_simple_server'])
    subprocess.run(['python3', str(Path(__file__).with_name('test_grid_snapshot.py')),
                    '--decoder', str(trees / 'home/yi-hack/bin/imggrabber-grid'),
                    '--rootfs', str(trees / 'rootfs'), '--qemu', str(qemu), '--ring'], check=True)
    print(f"PASS: {report['model']} hashes, ARM applets, shell syntax, locks, defaults, loaders and firmware upload guards without SD")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--qemu', type=Path, required=True)
    args = parser.parse_args()
    check(args.candidate.resolve(), args.qemu.resolve())
