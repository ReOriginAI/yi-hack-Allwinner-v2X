#!/usr/bin/env python3
"""Check pinned CI inputs, archive rejection and output publication boundaries."""
import hashlib
import importlib.util
import io
import json
import os
import subprocess
from pathlib import Path
import tarfile
import tempfile
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('flash_build', ROOT / 'scripts/pack_flash_core_all.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class FlashBuildTests(unittest.TestCase):
    def test_root_programs_remain_available_at_their_service_paths(self):
        spec = importlib.util.spec_from_file_location('flash_packer', ROOT / 'scripts/pack_flash_core.py')
        packer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packer)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            core, rootfs = root / 'core', root / 'rootfs'
            with self.assertRaisesRegex(ValueError, 'missing compiled program'):
                packer.place_root_programs(core, rootfs)
            for name in packer.ROOT_PROGRAMS:
                path = core / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('program fixture ' + name)
                path.chmod(0o755)
            packer.place_root_programs(core, rootfs)
            for original, relocated in packer.ROOT_PROGRAMS.items():
                self.assertEqual((core / original).readlink().as_posix(), '/' + relocated)
                self.assertEqual((rootfs / relocated).read_text(), 'program fixture ' + original)
                self.assertEqual((rootfs / relocated).stat().st_mode & 0o777, 0o755)

    def test_backup_geometry_rejects_nodes_crossing_physical_blocks(self):
        spec = importlib.util.spec_from_file_location('flash_packer', ROOT / 'scripts/pack_flash_core.py')
        packer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(packer)
        with tempfile.TemporaryDirectory() as tmp:
            image = Path(tmp) / 'backup.jffs2'
            node = struct.pack('<HHII', 0x1985, 0xe002, 32, 0) + bytes(20)
            image.write_bytes(node + bytes(4064) + node)
            report = packer.jffs2_geometry(image)
            self.assertTrue(report['flashable'])
            self.assertEqual(report['nodes_crossing_blocks'], 0)
            image.write_bytes(bytes(4080) + node)
            report = packer.jffs2_geometry(image)
            self.assertFalse(report['flashable'])
            self.assertEqual(report['physical_erase_bytes'], 4096)
            self.assertEqual(report['nodes_crossing_blocks'], 1)
            image.write_bytes(b'not a filesystem')
            with self.assertRaises(ValueError):
                packer.jffs2_geometry(image)

    def test_bundled_bases_have_only_reviewed_inputs(self):
        manifest = json.loads((build.BASES / 'manifest.json').read_text())
        self.assertEqual(build.digest(build.BASES / manifest['archive']), manifest['sha256'])
        expected = set()
        for model in build.MODELS:
            expected.update(f'{model}/{name}' for name in ('rootfs.bin', 'home.bin'))
            expected.update(f'{model}/backup/{name}' for name in (
                'ko/8189fs.ko', 'tools/wpa_supplicant', 'tools/default.script',
                'tools/wifidhcp.sh', 'tools/ethdhcp.sh', 'tools/wificonnect.sh'))
        expected.add('y28ga/backup/ko/icplus.ko')
        self.assertEqual(set(manifest['files']), expected)
        with tempfile.TemporaryDirectory() as tmp:
            extracted = Path(tmp) / 'bases'
            build.extract_bases(extracted)
            self.assertEqual({p.relative_to(extracted).as_posix() for p in extracted.rglob('*') if p.is_file()}, expected)

    def test_corrupt_or_unsafe_base_archive_is_rejected_before_extraction(self):
        for kind in ('corrupt-archive', 'corrupt-member', 'traversal', 'symlink', 'duplicate', 'unexpected'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                archive = root / 'base.tar.xz'
                name = '../escape' if kind == 'traversal' else 'model/file'
                with tarfile.open(archive, 'w:xz') as output:
                    member = tarfile.TarInfo(name)
                    member.size = 4
                    if kind == 'symlink':
                        member.type = tarfile.SYMTYPE
                        member.linkname = '/etc/passwd'
                        member.size = 0
                    output.addfile(member, io.BytesIO(b'data'))
                    if kind in ('duplicate', 'unexpected'):
                        member = tarfile.TarInfo(name if kind == 'duplicate' else 'surprise')
                        output.addfile(member)
                manifest = {'archive': archive.name, 'sha256': build.digest(archive),
                            'files': {name: {'bytes': 4, 'sha256': hashlib.sha256(b'data').hexdigest()}}}
                if kind == 'corrupt-archive':
                    manifest['sha256'] = '0' * 64
                if kind == 'corrupt-member':
                    manifest['files'][name]['sha256'] = '0' * 64
                (root / 'manifest.json').write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    build.extract_bases(root / 'extracted', root)
                self.assertFalse((root / 'extracted').exists())

    def test_no_card_broker_patch_changes_only_audited_reboot_call(self):
        helper = ROOT / 'src/static/static/yi-hack/script/flash_dispatch.sh'
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            build.extract_bases(root / 'bases')
            (root / 'script').mkdir()
            (root / 'script/storage.sh').write_bytes((helper.parent / 'storage.sh').read_bytes())
            (root / 'bin').mkdir()
            mounted = root / 'mounted'
            mount = root / 'bin/mount'
            mount.write_text('#!/bin/sh\necho "$*" > "' + str(mounted) + '"\n')
            mount.chmod(0o755)
            mounts = root / 'mounts'
            env = dict(os.environ, YI_HACK_PREFIX=str(root), YI_STORAGE_MOUNTS=str(mounts),
                       PATH=str(root / 'bin') + ':' + os.environ['PATH'])
            for model, offset, branch in [('y623', 40124, 0xebffe642), ('y28ga', 35024, 0xebffe85d)]:
                with self.subTest(model=model):
                    (root / 'model_suffix').write_text(model)
                    original = subprocess.check_output(['unsquashfs', '-cat',
                        str(root / 'bases' / model / 'home.bin'), 'app/dispatch'])
                    self.assertEqual(struct.unpack_from('<I', original, offset)[0], branch)
                    stock, patched = root / 'dispatch', root / 'patched'
                    stock.write_bytes(original)
                    script = root / 'patch.sh'
                    script.write_text(helper.read_text().replace('/home/app/dispatch', str(stock))
                                      .replace('/tmp/local-only/dispatch-no-sd', str(patched)))
                    mounts.write_text('')
                    subprocess.run(['sh', str(script)], env=env, check=True)
                    expected = bytearray(original)
                    expected[offset:offset+4] = struct.pack('<I', 0xe320f000)
                    self.assertEqual(patched.read_bytes(), expected)
                    self.assertIn('--bind', mounted.read_text())
                    patched.unlink()
                    mounted.unlink()
                    mounts.write_text('/dev/mmcblk0p1 /tmp/sd vfat rw 0 0\n')
                    subprocess.run(['sh', str(script)], env=env, check=True)
                    self.assertFalse(patched.exists())
                    self.assertFalse(mounted.exists())
                    mounts.write_text('')
                    stock.write_bytes(original + b'corrupt')
                    self.assertNotEqual(subprocess.run(['sh', str(script)], env=env).returncode, 0)
                    self.assertFalse(patched.exists())
                    self.assertFalse(mounted.exists())

    def test_package_excludes_staging_and_identifies_raw_unvalidated_images(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            candidate = root / 'candidate'
            (candidate / 'trees/backup').mkdir(parents=True)
            (candidate / 'trees/backup/private-device-data').write_text('must stay local')
            (candidate / 'trees/backup/init.sh').write_text('#!/bin/sh\nexit 0\n')
            for name in ('rootfs.squashfs', 'home.squashfs', 'backup.jffs2'):
                (candidate / name).write_bytes(b'fixture image')
            (candidate / 'report.json').write_text(json.dumps({'model': 'y623', 'images': {}, 'deployed': False}))
            name, report = build.package(candidate, root, '3.8.0', 'fixture-revision')
            self.assertFalse(report['installable'])
            self.assertFalse(report['hardware_validated'])
            self.assertIn('EXPERIMENTAL', name)
            with tarfile.open(root / name) as archive:
                self.assertEqual(set(archive.getnames()), {
                    'README.txt', 'report.json', 'rootfs.squashfs', 'home.squashfs', 'backup-updates.tar.gz'})
                self.assertIn(b'NOT AN SD INSTALLER', archive.extractfile('README.txt').read())
                with tarfile.open(fileobj=archive.extractfile('backup-updates.tar.gz'),mode='r:gz') as updates:
                    self.assertEqual(updates.getnames(),['init.sh'])


if __name__ == '__main__':
    unittest.main()
