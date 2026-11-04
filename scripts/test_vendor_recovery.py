#!/usr/bin/env python3
"""Verify ready SD packages and exercise embedded rescue on file-backed flash."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile
import zlib

import pack_flash_core_all as flash
import pack_vendor_recovery as recovery

ROOT = Path(__file__).resolve().parents[1]
SIZES = [0x60000, 0x1d0000, 0x120000, 0x340000, 0x130000, 0x20000, 0x10000, 0x10000]


class VendorRecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='vendor-recovery-tests-')
        cls.root = Path(cls.temp.name)
        cls.bases = cls.root / 'bases'
        flash.extract_bases(cls.bases)
        cls.output = cls.root / 'output'
        cls.output.mkdir()
        cls.packages = {model: recovery.package(model, cls.bases / model, cls.output)
                        for model in recovery.image.VERSIONS}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def fixture(self, model):
        tmp = tempfile.TemporaryDirectory(prefix='vendor-rescue-device-')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        sd, backup = root / 'sd', root / 'backup'
        shutil.copytree(self.output / ('vendor-recovery-' + model), sd)
        shutil.copytree(self.bases / model / 'backup', backup)
        # Old flash-core helper symlink must be replaced, never followed.
        (backup / 'tools/default.script').unlink()
        (backup / 'tools/default.script').symlink_to('/home/yi-hack/script/vendor-default.script')
        (backup / 'init.sh').write_text('old broken bootstrap\n')
        (backup / 'private-identity').write_text('must remain unchanged\n')
        (root / 'dev').mkdir()
        for n, size in enumerate(SIZES):
            (root / f'dev/mtdblock{n}').write_bytes(bytes([n]) * size)
        (root / 'dev/mtdblock3').write_bytes((self.bases / model / 'home.bin').read_bytes())
        (root / 'homever').write_text(recovery.image.VERSIONS[model] + '\n')
        (root / 'mtd').write_text(''.join(f'mtd{n}: {size:08x} 00001000 "partition{n}"\n'
                                       for n, size in enumerate(SIZES)))
        (root / 'mounts').write_text(f'tmpfs /tmp tmpfs rw 0 0\n/dev/mmcblk0p1 {sd} vfat rw 0 0\n')
        tools = root / 'tools'
        tools.mkdir()
        for name, text in {'mount': 'exit 0', 'sync': 'exit 0',
                           'df': 'echo "Filesystem 1K-blocks Used Available Use% Mounted"; echo "test 999999 0 ${FREE_KIB:-99000} 0% test"',
                           'reboot': 'echo reboot >> "$CALLS"'}.items():
            recovery.image.write(tools / name, '#!/bin/sh\n' + text + '\n', True)
        script = (self.output / ('rescue-rootfs-' + model) / 'etc/vendor-recovery.sh').read_text()
        for old, new in [('/tmp/sd', sd), ('/backup', backup), ('/proc/mounts', root / 'mounts'),
                         ('/proc/mtd', root / 'mtd'), ('/home/homever', root / 'homever'),
                         ('/dev/mtdblock', root / 'dev/mtdblock')]:
            if old == '/backup':
                script = re.sub(r'/backup(?=/|["\s]|$)', str(new), script)
            else:
                script = script.replace(old, str(new))
        script = script.replace('PATH=/usr/bin:', 'PATH=' + str(tools) + ':/usr/bin:', 1)
        script = script.replace('/bin/busybox reboot -f', 'reboot -f')
        script = script.replace('/bin/sh "$B/init.sh" &', 'echo vendor-started >> "$CALLS"')
        path = root / 'rescue.sh'
        path.write_text(script)
        env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'], CALLS=str(root / 'calls'))
        return root, sd, backup, path, env

    def run_rescue(self, path, env, ok=True):
        result = subprocess.run(['sh', str(path)], env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)

    def test_ready_archives_have_model_headers_verified_payloads_and_no_private_images(self):
        for model, name in self.packages.items():
            with self.subTest(model=model), zipfile.ZipFile(self.output / name) as archive:
                names = archive.namelist()
                self.assertIn('rootfs_' + model, names)
                self.assertIn('home_' + model, names)
                self.assertFalse(any('saved/' in n or 'mtdblock' in n or 'boot_' in n or 'backup_' in n for n in names))
                for part in ('rootfs', 'home'):
                    data = archive.read(part + '_' + model)
                    header = list(struct.unpack('>7I4B32s', data[:64]))
                    crc = header[1]; header[1] = 0
                    self.assertEqual(crc, zlib.crc32(struct.pack('>7I4B32s', *header)))
                    self.assertEqual(header[6], zlib.crc32(data[64:]))
                    self.assertEqual(header[11].rstrip(b'\0'), ('xiaoyi-' + part).encode())
                    self.assertLessEqual(len(data), recovery.image.LIMITS[part])
                for line in archive.read('SHA256SUMS').decode().splitlines():
                    digest, filename = line.split('  ', 1)
                    self.assertEqual(hashlib.sha256(archive.read(filename)).hexdigest(), digest)
                report = json.loads(archive.read('report.json'))
                self.assertFalse(report['hardware_validated'])
                self.assertEqual(report['writes_partitions'], ['rootfs', 'home'])
                startup = (self.output / ('rescue-rootfs-' + model) / 'etc/init.d/S02app').read_text()
                start = startup[startup.index('start() {'):startup.index('stop() {')]
                self.assertNotIn('/backup/init.sh', start)

    def test_both_models_preserve_private_partitions_back_up_and_stage_original_rootfs(self):
        for model in self.packages:
            with self.subTest(model=model):
                root, sd, backup, script, env = self.fixture(model)
                before = {n: (root / f'dev/mtdblock{n}').read_bytes() for n in range(8)}
                self.run_rescue(script, env)
                self.assertEqual((sd / ('rootfs_' + model)).read_bytes(), (sd / 'vendor-recovery/rootfs.stage').read_bytes())
                self.assertTrue((sd / 'vendor-recovery/saved/verified').exists())
                self.assertIn('Vendor-service launcher', (backup / 'init.sh').read_text())
                self.assertFalse((backup / 'tools/default.script').is_symlink())
                self.assertEqual((backup / 'private-identity').read_text(), 'must remain unchanged\n')
                for n, data in before.items():
                    self.assertEqual((root / f'dev/mtdblock{n}').read_bytes(), data)
                self.assertEqual((root / 'calls').read_text(), 'reboot\n')
                self.run_rescue(script, env)  # resume a final-rootfs retry without replacing backups
                self.assertEqual((sd / 'vendor-recovery/attempts').read_text(), '2\n')

    def test_final_update_retries_are_bounded_and_vendor_startup_remains_available(self):
        root, sd, backup, script, env = self.fixture('y28ga')
        for _ in range(4):
            self.run_rescue(script, env)
        self.assertEqual((sd / 'vendor-recovery/attempts').read_text(), '3\n')
        self.assertEqual((root / 'calls').read_text().splitlines(), ['reboot'] * 3 + ['vendor-started'])
        self.assertIn('ignored after three attempts', (sd / 'vendor_recovery_result.txt').read_text())

    def test_vendor_launcher_reports_final_images_and_starts_without_sd(self):
        for card in (True, False):
            with self.subTest(card=card):
                root, sd, backup, _, env = self.fixture('y28ga')
                launcher = (sd / 'vendor-recovery/support/init.sh').read_text()
                (root / 'dev/mtdblock2').write_bytes((self.bases / 'y28ga/rootfs.bin').read_bytes())
                (sd / 'rootfs_y28ga').write_bytes((sd / 'vendor-recovery/rootfs.stage').read_bytes())
                if not card:
                    sd.rename(root / 'removed-card')
                lower = root / 'vendor-lower.sh'
                lower.write_text('printf "%s %s\\n" "$SUFFIX" "$NETWORK_IFACE" > "$CALLS"\n')
                mapping = {'/tmp/sd': str(sd), '/tmp': str(root / 'ram'),
                           '/dev/shm': str(root / 'shm'), '/dev/mqueue': str(root / 'mqueue'),
                           '/proc/mounts': str(root / 'mounts'), '/home/homever': str(root / 'homever'),
                           '/dev/mtdblock': str(root / 'dev/mtdblock'),
                           '/home/app/lower_half_init.sh': str(lower)}
                launcher = re.sub('|'.join(re.escape(k) for k in sorted(mapping, key=len, reverse=True)),
                                  lambda m: mapping[m.group()], launcher)
                launcher = launcher.replace('PATH=/usr/bin:', 'PATH=' + str(root / 'tools') + ':/usr/bin:', 1)
                recovery.image.write(root / 'tools/sysctl', '#!/bin/sh\nexit 0\n', True)
                path = root / 'launcher.sh'
                path.write_text(launcher)
                self.run_rescue(path, env)
                self.assertEqual((root / 'calls').read_text(), 'y28ga wlan0\n')
                if card:
                    self.assertIn('Vendor rootfs/home verified', (sd / 'vendor_recovery_result.txt').read_text())
                    self.assertFalse((sd / 'rootfs_y28ga').exists())
                    self.assertFalse((sd / 'home_y28ga').exists())
                else:
                    self.assertFalse((sd / 'vendor_recovery_result.txt').exists())

    def test_corruption_incomplete_home_layout_space_and_foreign_card_fail_before_startup_changes(self):
        for kind in ('payload', 'manifest', 'home', 'layout', 'space', 'foreign', 'incomplete-backup'):
            with self.subTest(kind=kind):
                root, sd, backup, script, env = self.fixture('y623')
                if kind == 'payload': (sd / 'vendor-recovery/rootfs.stage').write_text('damaged')
                if kind == 'manifest': (sd / 'vendor-recovery/payload.md5').write_text('damaged')
                if kind == 'home': (root / 'dev/mtdblock3').write_bytes(b'partial home')
                if kind == 'layout': (root / 'mtd').write_text('wrong layout')
                if kind == 'space': env['FREE_KIB'] = '1'
                if kind == 'foreign':
                    self.run_rescue(script, env)
                    (root / 'dev/mtdblock6').write_bytes(b'another camera')
                if kind == 'incomplete-backup': (sd / 'vendor-recovery/saved').mkdir()
                before = (backup / 'init.sh').read_bytes()
                self.run_rescue(script, env, ok=False)
                self.assertEqual((backup / 'init.sh').read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
