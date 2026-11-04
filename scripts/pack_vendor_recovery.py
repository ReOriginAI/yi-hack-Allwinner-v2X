#!/usr/bin/env python3
"""Build SD recovery ZIPs from pinned vendor filesystems; no camera access."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

import pack_flash_core_installer as image

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / 'scripts/vendor-recovery'


def render(name, values):
    text = (TEMPLATES / name).read_text()
    for key, value in values.items():
        text = text.replace('@' + key + '@', str(value))
    if re.search(r'@[A-Z_]+@', text):
        raise ValueError('unrendered recovery token: ' + name)
    return text


def package(model, base, output):
    if model not in image.VERSIONS:
        raise ValueError('unsupported recovery model')
    manifest = json.loads((ROOT / 'scripts/vendor-images/flash-core/manifest.json').read_text())
    # This allowlist excludes every device-specific writable file.
    support = sorted(name.removeprefix(model + '/backup/') for name in manifest['files']
                     if name.startswith(model + '/backup/'))
    for relative in ['rootfs.bin', 'home.bin'] + ['backup/' + p for p in support]:
        data = (base / relative).read_bytes()
        expected = manifest['files'][model + '/' + relative]
        if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
            raise ValueError('unverified recovery input: ' + relative)
    tree = output / ('vendor-recovery-' + model)
    tree.mkdir()
    payload = tree / 'vendor-recovery'
    payload.mkdir()
    values = {'MODEL': model, 'HOMEVER': image.VERSIONS[model],
              'SUPPORT_FILES': ' '.join(support)}
    for part, prefix in [('rootfs', 'ROOT'), ('home', 'HOME')]:
        raw = image.stock_payload((base / (part + '.bin')).read_bytes())
        wrapped = image.uimage(raw, part)
        values[prefix + '_BLOCKS'] = len(raw) // 4096
        values[prefix + '_MD5'] = hashlib.md5(raw).hexdigest()
        values[prefix + '_IMAGE_MD5'] = hashlib.md5(wrapped).hexdigest()
        (payload / (part + '.stage')).write_bytes(wrapped)
    (tree / ('home_' + model)).write_bytes((payload / 'home.stage').read_bytes())
    for name in support:
        image.copy(base / 'backup' / name, payload / 'support' / name)
    image.write(payload / 'support/init.sh', render('launcher.sh.in', values), True)
    checked = sorted(p for p in payload.rglob('*') if p.is_file())
    image.write(payload / 'payload.md5', ''.join(
        f'{image.md5(p)}  {p.relative_to(payload)}\n' for p in checked))
    values['MANIFEST_MD5'] = image.md5(payload / 'payload.md5')
    rescue = output / ('rescue-rootfs-' + model)
    subprocess.run(['unsquashfs', '-no-progress', '-d', str(rescue), str(base / 'rootfs.bin')],
                   check=True, stdout=subprocess.DEVNULL)
    startup = rescue / 'etc/init.d/S02app'
    text = startup.read_text()
    if text.count('/backup/init.sh &') != 1:
        raise ValueError('unknown vendor application startup')
    start = text.index('start() {')
    end = text.index('\n}', start) + 2
    startup.write_text(text[:start] + 'start() {\n    /bin/sh /etc/vendor-recovery.sh &\n}' + text[end:])
    # The rescue code is embedded, independent of old bootstrap/SD installers.
    image.write(rescue / 'etc/vendor-recovery.sh', render('rescue.sh.in', values), True)
    filesystem = output / ('rescue-' + model + '.squashfs')
    subprocess.run(['mksquashfs', str(rescue), str(filesystem), '-noappend', '-comp', 'xz',
                    '-b', '262144', '-all-root', '-no-xattrs', '-processors', '2'],
                   check=True, stdout=subprocess.DEVNULL)
    wrapped = image.uimage(filesystem.read_bytes(), 'rootfs')
    if len(wrapped) > image.LIMITS['rootfs']:
        raise ValueError('rescue rootfs exceeds partition budget')
    (tree / ('rootfs_' + model)).write_bytes(wrapped)
    report = dict(model=model, vendor_firmware=image.VERSIONS[model],
                  hardware_validated=False, startup='project vendor-service launcher',
                  kernel='retained', writes_partitions=['rootfs', 'home'],
                  preserves=['uboot', 'boot', 'env', 'mfg', 'conf'],
                  rescue_rootfs_bytes=len(wrapped),
                  rootfs_sha256=manifest['files'][model + '/rootfs.bin']['sha256'],
                  home_sha256=manifest['files'][model + '/home.bin']['sha256'])
    image.write(tree / 'report.json', json.dumps(report, indent=2) + '\n')
    image.write(tree / 'README.txt', f'''VENDOR FILESYSTEM RECOVERY — {model} / {image.VERSIONS[model]}
EXPERIMENTAL: physical recovery tests are still required for both models.

1. Power OFF. Use a CLEAN SD card with MBR and a primary FAT32 partition 1.
   Preserve previous recovery cards/backups; do not mix installer files.
2. Extract this ZIP's CONTENTS directly to the SD root. It should contain
   rootfs_{model}, home_{model}, and vendor-recovery/. No renaming is needed.
3. Safely eject, insert the card, then power ON. Keep SD and stable power
   connected for five minutes and through all automatic reboots.
4. Check vendor_recovery_result.txt. Success must say:
   "Vendor rootfs/home verified. Vendor services starting."
5. Power OFF before removing SD. Boot normally and use the vendor app.
   Existing vendor Wi-Fi provisioning is retained; normal vendor reset/pairing
   can be used if it no longer matches your router.

The temporary rescue rootfs bypasses broken yi-hack bootstraps, saves this
camera's writable files and partitions on the card, installs a small PROJECT
launcher for the unmodified vendor camera/services, then stages the original
vendor rootfs for U-Boot. Final rootfs/home are the pinned vendor filesystems.
The launcher is NOT a byte-for-byte factory /backup/init.sh. Reclaimed vendor
OTA/update tools are not supplied; app firmware updates may require vendor
recovery media. This package restores vendor camera operation, not every byte
of factory flash. The existing kernel is retained, including a y623 VE patch.
No bootloader/kernel, env, manufacturing/calibration or Wi-Fi provisioning
image is flashed. No generic raw backup/JFFS2 image is written. Damaged kernel,
bootloader or missing device-specific data cannot be repaired with this ZIP.

vendor-recovery/saved/ contains PRIVATE device backups after use. Keep them
safe; never share them or use another camera's saved/ directory. These backups
are captured AFTER the first rootfs/home recovery flash, not the old firmware.
Power loss before a backup completes is reported as incomplete backup: preserve
that card and use another freshly extracted recovery card. A partial final
rootfs stage can be retried with the same card; final retries are bounded.
If recovery fails, preserve the result file. Do not remove SD/power during
writes, mix models, or flash device-private dumps from another camera.
''')
    image.write(tree / 'SHA256SUMS', ''.join(
        f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(tree)}\n'
        for p in sorted(tree.rglob('*')) if p.is_file()))
    name = f'vendor-recovery-{model}-{image.VERSIONS[model]}-sd.zip'
    image.write_zip(tree, output / name)
    return name


def build(output):
    from pack_flash_core_all import extract_bases
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='vendor-recovery-build-') as temporary:
        bases = Path(temporary) / 'bases'
        extract_bases(bases)
        names = [package(model, bases / model, output) for model in image.VERSIONS]
        image.write(output / 'SHA256SUMS', ''.join(
            f'{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n' for name in names))
        for name in names:
            print(name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output.resolve())
