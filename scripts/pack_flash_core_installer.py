#!/usr/bin/env python3
"""Build a stock SD entry point with staged U-Boot updates for either model."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import tarfile
import time
import zlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TEMPLATES = ROOT / 'scripts/flash-core'
VERSIONS = {'y623': '12.0.51.01_202303091901', 'y28ga': '9.0.20.06_202007061841'}
LIMITS = {'rootfs': 0x120000, 'home': 0x340000}
INSTALLER_REVISION = 8


def md5(path):
    return hashlib.md5(path.read_bytes()).hexdigest()


def uimage(data, part):
    # The vendor updater checks the partition-specific name, not just CRC/type.
    if part not in LIMITS:
        raise ValueError('unsupported U-Boot image partition')
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', int(time.time())))
    if epoch <= 0 or epoch > 0xffffffff:
        raise ValueError('invalid U-Boot image timestamp')
    header = struct.pack('>7I4B32s', 0x27051956, 0, epoch, len(data), 0, 0,
                         zlib.crc32(data), 5, 2, 7, 0, ('xiaoyi-' + part).encode())
    return header[:4] + struct.pack('>I', zlib.crc32(header)) + header[8:] + data


def stock_payload(data):
    # A raw partition includes unused padding. Wrapping the entire partition
    # adds 64 bytes beyond its budget; restore only the complete SquashFS.
    if data[:4] != b'hsqs' or len(data) < 48:
        raise ValueError('stock partition is not SquashFS')
    used = struct.unpack_from('<Q', data, 40)[0]
    size = (used + 4095) // 4096 * 4096
    if used < 96 or size + 64 > len(data) or set(data[size:]) - {0, 255}:
        raise ValueError('invalid stock SquashFS size/padding')
    return data[:size]


def copy(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, target)


def write(path, data, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(data)
    path.chmod(0o755 if executable else 0o644)


def manifest(tree):
    # Factory input and retiring the SD hook must not invalidate resume checks.
    files = sorted(p for p in (tree / 'flash-core').rglob('*')
                   if p.is_file() and not p.is_symlink() and p.name not in ('files.md5', 'CLEAN_INSTALL'))
    write(tree / 'flash-core/files.md5', ''.join(
        f'{md5(p)}  {p.relative_to(tree).as_posix()}\n' for p in files))


def zip_name(tar_name):
    return tar_name.removesuffix('.tar.gz') + f'-r{INSTALLER_REVISION}.zip'


def write_zip(tree, destination):
    # FAT32 has no symbolic links. Store their in-tree file contents so Windows
    # extraction produces the same usable payload as a FAT-aware tar extractor.
    names = set()
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(tree.rglob('*')):
            if not path.is_file():
                continue
            if not path.resolve().is_relative_to(tree.resolve()):
                raise ValueError('ZIP link leaves installer tree')
            name = path.relative_to(tree).as_posix()
            if name.casefold() in names:
                raise ValueError('case-insensitive SD filename collision: ' + name)
            names.add(name.casefold())
            archive.write(path, name)


def package(candidate, base, output, version, revision):
    report = json.loads((candidate / 'report.json').read_text())
    model = report['model']
    if model not in VERSIONS or not re.fullmatch(r'[A-Za-z0-9._-]+', version):
        raise ValueError('unsupported installer model/version')
    tree = candidate / 'sd-installer'
    tree.mkdir()
    p = tree / 'flash-core'
    p.mkdir()
    core = candidate / 'trees/home/yi-hack'
    values = {'MODEL': model, 'HOMEVER': VERSIONS[model],
              'INIT_HASH': md5(candidate / 'trees/backup/init.sh')}
    for part, prefix in [('rootfs', 'ROOT'), ('home', 'HOME')]:
        image = candidate / (part + '.squashfs')
        size = image.stat().st_size
        stock = base / (part + '.bin')
        if size % 4096 or size + 64 > LIMITS[part] or stock.stat().st_size != LIMITS[part]:
            raise ValueError('unsupported image size: ' + part)
        values[prefix + '_STOCK'] = md5(stock)
        original = stock_payload(stock.read_bytes())
        values[prefix + '_STOCK_PREFIX'] = hashlib.md5(original).hexdigest()
        values[prefix + '_STOCK_BLOCKS'] = str(len(original) // 4096)
        values[prefix + '_NEW'] = md5(image)
        values[prefix + '_BLOCKS'] = str(size // 4096)
        for source, dest in [(image, p / f'images/{part}_{model}.stage'),
                             (stock, p / f'recovery/{part}_{model}.restore')]:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(uimage(original if source == stock else source.read_bytes(), part))
    identity = json.dumps(values, sort_keys=True) + version + revision
    identity += ''.join(path.read_text() for path in sorted(TEMPLATES.iterdir()) if path.is_file())
    values['RELEASE_ID'] = hashlib.sha256(identity.encode()).hexdigest()
    write(p / 'install.conf', ''.join(f"{key}='{value}'\n" for key, value in values.items()))
    dispatcher = (TEMPLATES / 'dispatcher.sh.in').read_text()
    for key, value in values.items():
        dispatcher = dispatcher.replace('@' + key + '@', value)
    if re.search(r'@[A-Z_]+@', dispatcher):
        raise ValueError('unrendered dispatcher token')
    write(p / 'dispatcher.sh', dispatcher, True)
    copy(TEMPLATES / 'install.sh', p / 'install.sh')
    copy(candidate / 'clean-image', p / 'clean-image')
    write(p / 'CLEAN_INSTALL', 'reset-to-hotspot\n')
    copy(TEMPLATES / 'lower_half_init.sh', tree / 'lower_half_init.sh')
    write(tree / 'Factory/factory_test.sh', '', True)
    write(tree / 'Factory/config.sh', '#!/bin/sh\nexec /bin/sh /tmp/sd/flash-core/install.sh "$@"\n', True)
    copy(ROOT / f'sdhack/{model}/Factory/configure_wifi.cfg.ori', tree / 'Factory/configure_wifi.cfg.ori')
    copy(candidate / 'trees/backup/init.sh', p / 'core-init.sh')
    shutil.copytree(core / 'etc', p / 'setup/etc', symlinks=True)
    copy(core / 'bin/busybox', p / 'setup/bin/busybox')
    for name in ['configure_wifi.sh'] + (['ensure_y623_ve_kernel.sh'] if model == 'y623' else []):
        copy(core / 'script' / name, p / 'setup/script' / name)
    if model == 'y623':
        copy(candidate / 'boot-vmalloc.bin', p / 'boot-vmalloc.bin')
    optional = candidate / 'sd-optional/yi-hack-optional'
    if optional.exists():
        shutil.copytree(optional, tree / 'yi-hack-optional', symlinks=True)
    report = dict(report, package_type='sd-installer', installable=True,
                  installer_revision=INSTALLER_REVISION,
                  hardware_validated=False, source_revision=revision,
                  vendor_firmware=VERSIONS[model], release_id=values['RELEASE_ID'])
    write(p / 'report.json', json.dumps(report, indent=2) + '\n')
    for name in ['README.txt', 'RECOVERY.txt']:
        text = (TEMPLATES / name).read_text().replace('@MODEL@', model).replace('@HOMEVER@', VERSIONS[model])
        write(tree / name, text)
    manifest(tree)
    name = f'flash-core-{model}-{version}-EXPERIMENTAL-sd-installer.tar.gz'
    with tarfile.open(output / name, 'w:gz') as archive:
        for path in sorted(tree.iterdir()):
            archive.add(path, arcname=path.name)
    write_zip(tree, output / zip_name(name))
    return name
