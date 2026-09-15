#!/usr/bin/env python3
"""Install a reviewed bootstrap and staged SD changes over SSH, without rebooting.

Requires the exact pre-install archives on the host. Never deletes the active
internal init to make room and never automatically restores stock boot.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import shlex
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
FILES = ('script/system.sh', 'script/wd.sh', 'script/motion_service.sh',
         'bin/cloudAPI', 'bin/cloudAPI_fake')


def remote(host, command, data=None):
    return subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
                           host, command], input=data, check=True, stdout=subprocess.PIPE).stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('model', choices=('y623', 'y28ga'))
    p.add_argument('host')
    p.add_argument('evidence', type=Path)
    a = p.parse_args()
    records = json.loads((ROOT / 'docs/vendor-ablation/backup-hashes.json').read_text())
    expected = next(x['md5'] for x in records if x.get('model') == a.model and x.get('path') == '/backup/init.sh')
    for name in ('backup.tar', 'sd-before.tar', 'originals.tar'):
        data = (a.evidence / name).read_bytes()
        digest = next(x['sha256'] for x in records if x.get('model') == a.model and x.get('artifact') == name)
        if hashlib.sha256(data).hexdigest() != digest:
            raise SystemExit('Recovery archive hash mismatch: ' + name)
    actual = remote(a.host, 'md5sum /backup/init.sh').decode().split()[0]
    if actual != expected:
        raise SystemExit('Unknown/currently modified internal init; refusing installation')
    payload = (a.evidence / 'init-local.sh').read_bytes()
    subprocess.run(['sh', '-n'], input=payload, check=True)
    digest = hashlib.md5(payload).hexdigest()
    # Stage internal file first: out-of-space leaves existing init untouched.
    remote(a.host, 'cat > /backup/init.sh.local-new', payload)
    try:
        remote(a.host, 'test "$(md5sum /backup/init.sh.local-new | cut -d \' \' -f1)" = ' + shlex.quote(digest)
               + ' && /bin/sh -n /backup/init.sh.local-new && chmod 755 /backup/init.sh.local-new && sync')
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w') as tar:
            for f in FILES:
                tar.add(a.evidence / 'sd-stage' / f, arcname=f)
        remote(a.host, 'mkdir -p /tmp/ablation-sd-stage && tar xf - -C /tmp/ablation-sd-stage', buf.getvalue())
        for f in FILES:
            # Constants above are controlled source paths, not shell input.
            if f == 'bin/cloudAPI':
                # VFAT refuses renaming a bind-mount source. The new wrapper has
                # no real fallback; an interrupted write fails instead of clouds.
                remote(a.host, 'cat /tmp/ablation-sd-stage/' + f + ' > /tmp/sd/yi-hack/' + f)
                continue
            remote(a.host, 'cp /tmp/ablation-sd-stage/' + f + ' /tmp/sd/yi-hack/' + f + '.local-new'
                   + ' && chmod 755 /tmp/sd/yi-hack/' + f + '.local-new'
                   + ' && mv /tmp/sd/yi-hack/' + f + '.local-new /tmp/sd/yi-hack/' + f)
        for f in FILES:
            expected_file = hashlib.md5((a.evidence / 'sd-stage' / f).read_bytes()).hexdigest()
            got = remote(a.host, 'md5sum /tmp/sd/yi-hack/' + f).decode().split()[0]
            if got != expected_file:
                raise RuntimeError('SD verification failed: ' + f)
        remote(a.host, 'test "$(md5sum /backup/init.sh | cut -d \' \' -f1)" = ' + shlex.quote(expected)
               + ' && sync && mv /backup/init.sh.local-new /backup/init.sh && sync')
    except Exception:
        remote(a.host, 'rm -f /backup/init.sh.local-new')
        raise
    print(remote(a.host, 'md5sum /backup/init.sh; df -k /backup').decode())
    print('Installed. Reboot is a separate test step; no vendor rollback was scheduled.')


if __name__ == '__main__':
    main()
