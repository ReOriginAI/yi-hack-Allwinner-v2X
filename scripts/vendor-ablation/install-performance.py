#!/usr/bin/env python3
"""Install the audited dispatch IPC optimizations on a local-only bootstrap.

The /backup JFFS2 partition is small on the tested cameras, so this tool never
stages a second complete init there. It preserves exact originals on the host,
requires enough JFFS2 GC headroom before touching flash, stages/verifies the SD
library, then updates only fixed-size byte ranges inside the already-installed
local bootstrap. It does not reboot automatically.
"""
import argparse
import hashlib
from pathlib import Path
import shlex
import subprocess

OLD_LIB_MD5 = '54c5f2704f1de02a0426ae82409005d5'
LIBPATH = '/tmp/sd/yi-hack/lib/ipc_multiplex.so'
# `df` reports 1 KiB blocks. JFFS2 may reject even tiny inode updates while
# nominal free space is low because it also needs erase-block GC/reserve space.
# The y28ga test unit rejected writes at 4-12 KiB free and succeeded after
# obsolete updater payloads were removed and >200 KiB became available.
MIN_BACKUP_FREE_KIB = 128
OLD_BLOCK = b'''if [ -e "$YI/bin/cloudAPI_real" ]; then\n    mount --bind /tmp/local-only/noop "$YI/bin/cloudAPI_real" || fail_closed archived-api\nfi\n# Match the tested media memory limits without stock update/debug hooks.\n'''
NEW_BLOCK = b'''for x in "$YI/bin/cloudAPI_real" /tmp/sd/Factory/factory_test.sh /tmp/sd/telnetd;do [ ! -e "$x" ]||mount --bind /tmp/local-only/noop "$x"||fail_closed "$x";done\n'''


def md5(data):
    return hashlib.md5(data).hexdigest()


def remote(host, command, data=None):
    return subprocess.run(
        ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', host, command],
        input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout


def backup_free_kib(host):
    out = remote(host, "df -k /backup | awk 'NR==2 {print $4}'").decode().strip()
    try:
        return int(out)
    except ValueError as exc:
        raise RuntimeError('Unable to determine /backup free space: ' + repr(out)) from exc


def patch_bootstrap(oldinit, oldlib, newlib):
    oldline = (md5(oldlib) + '  lib/ipc_multiplex.so').encode()
    newline = (md5(newlib) + '  lib/ipc_multiplex.so').encode()
    if oldinit.count(oldline) != 1:
        raise RuntimeError('Missing/ambiguous current multiplex manifest line')
    if OLD_BLOCK not in oldinit:
        raise RuntimeError('Unknown bootstrap cloud-mask block; refusing in-place patch')
    if len(NEW_BLOCK) > len(OLD_BLOCK):
        raise AssertionError('Low-space replacement unexpectedly grew')
    padded_block = NEW_BLOCK + b' ' * (len(OLD_BLOCK) - len(NEW_BLOCK))
    newinit = oldinit.replace(oldline, newline, 1).replace(OLD_BLOCK, padded_block, 1)
    if len(newinit) != len(oldinit):
        raise AssertionError('In-place bootstrap patch changed file size')
    return newinit


def changed_spans(old, new):
    assert len(old) == len(new)
    spans = []
    start = None
    last = None
    for i, (a, b) in enumerate(zip(old, new)):
        if a == b:
            if start is not None and i - last > 32:
                spans.append((start, last + 1))
                start = last = None
            continue
        if start is None:
            start = i
        last = i
    if start is not None:
        spans.append((start, last + 1))
    return spans


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('host')
    p.add_argument('library', type=Path)
    p.add_argument('evidence', type=Path)
    a = p.parse_args()
    a.evidence.mkdir(parents=True, exist_ok=True)

    oldlib = remote(a.host, 'cat ' + LIBPATH)
    oldinit = remote(a.host, 'cat /backup/init.sh')
    newlib = a.library.read_bytes()
    if md5(oldlib) != OLD_LIB_MD5:
        raise SystemExit('Unknown original multiplex library: ' + md5(oldlib))
    if b'fail_closed' not in oldinit or b'SD_MANIFEST' not in oldinit:
        raise SystemExit('Not the audited local-only bootstrap')
    if b'LD_PRELOAD="$YI/lib/ipc_multiplex.so" ./dispatch &' not in oldinit:
        raise SystemExit('Bootstrap does not preload the multiplex library')
    newinit = patch_bootstrap(oldinit, oldlib, newlib)
    subprocess.run(['sh', '-n'], input=newinit, check=True)

    free_kib = backup_free_kib(a.host)
    if free_kib < MIN_BACKUP_FREE_KIB:
        raise SystemExit(
            f'/backup has only {free_kib} KiB free; refusing to modify JFFS2. '
            f'At least {MIN_BACKUP_FREE_KIB} KiB is required for GC/write headroom. '
            'Remove only already-disabled updater payloads after preserving recovery copies.'
        )

    artifacts = {
        'init.before': oldinit,
        'init.after': newinit,
        'ipc_multiplex.before.so': oldlib,
        'ipc_multiplex.after.so': newlib,
    }
    for name, data in artifacts.items():
        path = a.evidence / name
        if path.exists():
            raise SystemExit('Preserve previous recovery evidence: ' + str(path))
        path.write_bytes(data)
    (a.evidence / 'sha256.txt').write_text(''.join(
        hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
        for name, data in artifacts.items()
    ))

    # Verify BusyBox dd's fixed-offset overwrite semantics without touching flash.
    test = remote(a.host, "printf abc > /tmp/yi-dd-test; printf Z | dd of=/tmp/yi-dd-test bs=1 seek=1 conv=notrunc 2>/dev/null; cat /tmp/yi-dd-test; rm -f /tmp/yi-dd-test")
    if test != b'aZc':
        raise RuntimeError('Remote dd does not support the required notrunc semantics')

    stage = LIBPATH + '.perf-new'
    try:
        remote(a.host, 'cat > ' + shlex.quote(stage), newlib)
        got = remote(a.host, 'md5sum ' + shlex.quote(stage)).decode().split()[0]
        if got != md5(newlib):
            raise RuntimeError('Staged library hash mismatch')
        remote(a.host, 'chmod 755 ' + shlex.quote(stage) + ' && sync')

        # Patch the bootstrap structure first while its library hash still points
        # to the old active library. Only changed ranges are written to JFFS2.
        spans = changed_spans(oldinit, newinit)
        hash_start = newinit.index((md5(newlib) + '  lib/ipc_multiplex.so').encode())
        hash_end = hash_start + 32
        structural = []
        hash_spans = []
        for start, end in spans:
            if start < hash_end and end > hash_start:
                # Split around the manifest hash so it can be committed last.
                if start < hash_start:
                    structural.append((start, hash_start))
                hash_spans.append((max(start, hash_start), min(end, hash_end)))
                if end > hash_end:
                    structural.append((hash_end, end))
            else:
                structural.append((start, end))

        for start, end in structural:
            remote(a.host, 'dd of=/backup/init.sh bs=1 seek=%d conv=notrunc 2>/dev/null' % start,
                   newinit[start:end])
        remote(a.host, 'sync')

        # Switch the SD library atomically on VFAT, then commit the 32-byte
        # manifest hash immediately afterward. A power loss in this tiny window
        # fails closed rather than starting vendor cloud code.
        remote(a.host, 'mv ' + shlex.quote(stage) + ' ' + shlex.quote(LIBPATH) + ' && sync')
        for start, end in hash_spans:
            remote(a.host, 'dd of=/backup/init.sh bs=1 seek=%d conv=notrunc 2>/dev/null' % start,
                   newinit[start:end])
        remote(a.host, 'sync')

        if remote(a.host, 'md5sum /backup/init.sh').decode().split()[0] != md5(newinit):
            raise RuntimeError('Installed bootstrap hash mismatch')
        if remote(a.host, 'md5sum ' + LIBPATH).decode().split()[0] != md5(newlib):
            raise RuntimeError('Installed library hash mismatch')
        remote(a.host, 'sh -n /backup/init.sh')
    except Exception:
        # Do not attempt an automatic rollback of a partially changed boot file.
        # Exact recovery bytes are on the host and the camera is still running.
        try:
            remote(a.host, 'rm -f ' + shlex.quote(stage))
        except Exception:
            pass
        raise

    print('Installed and verified; reboot required.')
    print('bootstrap md5:', md5(newinit))
    print('library md5:', md5(newlib))
    print('changed bootstrap ranges:', changed_spans(oldinit, newinit))
    print('/backup free before install:', free_kib, 'KiB')
    print('recovery originals:', a.evidence)


if __name__ == '__main__':
    main()
