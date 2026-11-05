#!/usr/bin/env python3
"""Build and check both experimental flash-core artifact packages, offline."""
import argparse
import hashlib
import json
import shutil
import struct
import zlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pack_flash_core_installer as installer

ROOT = Path(__file__).resolve().parents[1]
BASES = ROOT / 'scripts/vendor-images/flash-core'
MODELS = ('y623', 'y28ga')
NOTICE = """EXPERIMENTAL FLASH-CORE IMAGES — NOT AN SD INSTALLER

These are raw partition candidates. Copying this archive or its extracted files
onto SD will NOT install flash-core. No Factory installer is included.
The complete installation/recovery and client test matrix is still pending.
Never rename these files to vendor auto-flash names or mix camera models.

rootfs.squashfs: raw rootfs candidate
home.squashfs: raw home candidate
backup-updates.tar.gz: bootstrap files for updating the EXISTING
  backup filesystem; not a raw partition image or automatic installer
report.json: model, image sizes, free space and SHA-256 checksums
sd-optional/: optional SD programs and voice data (not needed for core startup)
boot-vmalloc.bin: y623 only, audited patched kernel prerequisite

Read docs/FLASH_CORE.md in the matching source revision before any installation.
Wi-Fi provisioning and manufacturing partitions are not part of this package.
"""


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def extract_bases(directory, bases=BASES):
    """Verify the complete allowlist before extracting regular files only."""
    manifest = json.loads((bases / 'manifest.json').read_text())
    archive = bases / manifest['archive']
    if digest(archive) != manifest['sha256']:
        raise ValueError('vendor base archive checksum mismatch')
    with tarfile.open(archive) as source:
        members = source.getmembers()
        if len(members) != len(manifest['files']) or {m.name for m in members} != set(manifest['files']):
            raise ValueError('vendor base archive members differ from allowlist')
        for member in members:
            path = PurePosixPath(member.name)
            if not member.isfile() or path.is_absolute() or '..' in path.parts:
                raise ValueError('unsafe vendor base archive member')
            expected = manifest['files'][member.name]
            data = source.extractfile(member).read()
            if len(data) != expected['bytes'] or hashlib.sha256(data).hexdigest() != expected['sha256']:
                raise ValueError('vendor base member checksum mismatch: ' + member.name)
        directory.mkdir(parents=True, mode=0o700)
        for member in members:
            destination = directory / member.name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(source.extractfile(member).read())
            destination.chmod(member.mode & 0o777)
    return manifest['sha256']


def package(candidate, output, version, revision):
    report = json.loads((candidate / 'report.json').read_text())
    report.update(installable=False, hardware_validated=False, source_revision=revision)
    (candidate / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    (candidate / 'README.txt').write_text(NOTICE)
    # Host mkfs.jffs2 can force 8 KiB node packing on 4 KiB flash. Do not
    # publish an incompatible raw backup image; retain the existing filesystem.
    updates = candidate / 'backup-updates.tar.gz'
    with tarfile.open(updates, 'w:gz') as archive:
        for name in ('init.sh', 'tools/hostapd'):
            path = candidate / 'trees/backup' / name
            if path.is_file():
                archive.add(path, arcname=name)
    name = f"flash-core-{report['model']}-{version}-EXPERIMENTAL-images.tar.gz"
    with tarfile.open(output / name, 'w:gz') as archive:
        for filename in ('README.txt', 'report.json', 'rootfs.squashfs', 'home.squashfs',
                         'backup-updates.tar.gz', 'sd-optional', 'boot-vmalloc.bin'):
            path = candidate / filename
            if path.exists():
                archive.add(path, arcname=filename)
    return name, report


def build(args):
    if args.output.exists():
        raise ValueError('output must not exist; preserve earlier candidates')
    args.output.mkdir(parents=True)
    work = args.output / 'work'
    work.mkdir(mode=0o700)
    base_sha = extract_bases(work / 'bases')
    toolchain_env = dict(os.environ, STAGING_DIR=str(args.toolchain.parent.parent))
    noop = work / 'noop'
    run([args.toolchain / 'arm-openwrt-linux-muslgnueabi-as', '-o', work / 'noop.o',
         ROOT / 'scripts/vendor-ablation/noop.S'], env=toolchain_env)
    run([args.toolchain / 'arm-openwrt-linux-muslgnueabi-ld', '-N', '-nostdlib', '-static',
         '-s', '-o', noop, work / 'noop.o'], env=toolchain_env)
    run([args.toolchain / 'arm-openwrt-linux-muslgnueabi-gcc', '-Os', '-static', '-s',
         ROOT / 'scripts/flash-core/clean_image.c',
         '-Wl,--start-group', '-lc', '-lgcc_eh', '-lgcc', '-Wl,--end-group', '-o', work / 'clean-image'], env=toolchain_env)
    version = (ROOT / 'VERSION').read_text().strip()
    if not re.fullmatch(r'[0-9A-Za-z._-]+', version):
        raise ValueError('invalid VERSION for artifact name')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    releases = args.output / 'packages'
    releases.mkdir()
    reports = []
    installers = []
    for model in MODELS:
        base = work / 'bases' / model
        for part in ('rootfs', 'home'):
            run(['unsquashfs', '-no-progress', '-d', base / part, base / (part + '.bin')],
                stdout=subprocess.DEVNULL)
        candidate = work / model
        run(['python3', ROOT / 'scripts/pack_flash_core.py', model,
             '--rootfs', base / 'rootfs', '--home', base / 'home', '--backup', base / 'backup',
             '--payload', args.payload, '--web', args.payload / 'www', '--noop', noop,
             '--host-busybox', args.host_busybox, '--mkfs-jffs2', args.mkfs_jffs2,
             '--output', candidate])
        if model == 'y623':
            run(['python3', ROOT / 'scripts/patch_y623_ve_debugfs.py',
                 ROOT / 'scripts/vendor-images/y623-boot-stock.bin', candidate / 'boot-vmalloc.bin'])
            if hashlib.md5((candidate / 'boot-vmalloc.bin').read_bytes()).hexdigest() != '26a2e9a432fbe36efe97f0e7cee84dc9':
                raise ValueError('unexpected y623 patched kernel')
        run(['python3', ROOT / 'scripts/check_flash_core.py', candidate, '--qemu', args.qemu])
        shutil.copy2(work / 'clean-image', candidate / 'clean-image')
        # Execute the actual ARM recovery wrapper on both filesystem images.
        for part in ('rootfs', 'home'):
            wrapped = work / (model + '-' + part + '.restore-check')
            run([args.qemu, work / 'clean-image', candidate / (part + '.squashfs'),
                 part, wrapped], stdout=subprocess.DEVNULL)
            data = wrapped.read_bytes()
            header = list(struct.unpack('>7I4B32s', data[:64]))
            saved_crc = header[1]
            header[1] = 0
            if (header[0] != 0x27051956 or header[3] != len(data) - 64 or
                header[6] != zlib.crc32(data[64:]) or
                saved_crc != zlib.crc32(struct.pack('>7I4B32s', *header)) or
                header[7:11] != [5, 2, 7, 0] or
                header[11].rstrip(b'\0') != ('xiaoyi-' + part).encode() or
                data[64:] != (candidate / (part + '.squashfs')).read_bytes()):
                raise ValueError('invalid clean-reinstall recovery wrapper: ' + part)
        name, report = package(candidate, releases, version, revision)
        reports.append((name, report))
        installer_name = installer.package(candidate, base, releases, version, revision)
        installers.extend([installer_name, installer.zip_name(installer_name)])
    (releases / 'SHA256SUMS').write_text(''.join(
        f'{digest(releases / name)}  {name}\n' for name in [name for name, _ in reports] + installers))
    summary = ['# Experimental flash-core build', '',
               '**Experimental SD installers and raw images. Automatic installation/recovery needs hardware validation.**', '',
               f'Source revision: `{revision}`', f'Vendor bases SHA-256: `{base_sha}`', '',
               'Backup size is a staging estimate; incompatible raw JFFS2 is excluded.', '',
               '| Model | Rootfs spare | Home spare | Backup estimate spare |',
               '| --- | ---: | ---: | ---: |']
    for _, report in reports:
        images = report['images']
        summary.append('| ' + report['model'] + ' | ' + ' | '.join(
            str(images[name]['headroom']) + ' B' for name in ('rootfs', 'home', 'backup')) + ' |')
    summary += ['', 'Extract the matching revision 8 `*-sd-installer-r8.zip` (or `.tar.gz`) to a clean FAT32 card for a fresh vendor camera. y623 needs FAT32 on partition 1 (MBR recommended); whole-device FAT32 is not supported by its updater.',
                'For an existing flash-core camera, follow the README clean-reinstall instructions using a clean card. Older bootstraps need the one-time --prepare-clean SSH command. A clean reinstall resets settings and enters an open cam-... hotspot.',
                'The `*-images.tar.gz` archives remain raw development inputs, not installers.', ''] + installers
    text = '\n'.join(summary) + '\n'
    (releases / 'BUILD.md').write_text(text)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream:
            stream.write(text)
    print(text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('payload', 'toolchain', 'host-busybox', 'qemu', 'mkfs-jffs2', 'output'):
        parser.add_argument('--' + name, type=Path, required=True)
    options = parser.parse_args()
    for name, value in vars(options).items():
        setattr(options, name, value.resolve())
    build(options)
