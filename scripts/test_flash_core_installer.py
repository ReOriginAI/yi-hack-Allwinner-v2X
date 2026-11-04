#!/usr/bin/env python3
"""Exercise real installer/dispatcher scripts with file-backed flash and fake reboots."""
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib
import pack_flash_core_installer as pack

ROOT = Path(__file__).resolve().parents[1]
SIZES = [0x60000, 0x1d0000, 0x120000, 0x340000, 0x130000, 0x20000, 0x10000, 0x10000]


class InstallerTests(unittest.TestCase):
    def fixture(self, model='y28ga'):
        tmp = tempfile.TemporaryDirectory(prefix='yi-installer-')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        candidate = root / 'candidate'
        base = root / 'base'
        base.mkdir()
        core = candidate / 'trees/home/yi-hack'
        for folder in ['etc', 'bin', 'script']:
            (core / folder).mkdir(parents=True)
        (core / 'etc/system.conf').write_text('WIFI_HOTSPOT_BOOT=no\n')
        (core / 'etc/camera.conf').write_text('SWITCH_ON=yes\n')
        (core / 'etc/hostname').write_text('yi-hack\n')
        (core / 'bin/busybox').write_text('fixture executable\n')
        (core / 'script/configure_wifi.sh').write_text('exit 1\n')
        (core / 'script/ensure_y623_ve_kernel.sh').write_text('echo "$*" >> "$KERNEL_CALLS"\n')
        b = root / 'backup'
        (b / 'tools').mkdir(parents=True)
        (b / 'init.sh').write_text('#!/bin/sh\necho VENDOR\n')
        (b / 'lower_half_init.sh').write_text('original lower half\n')
        (b / 'tools/upgrade.sh').write_text('original updater\n')
        (b / 'private-identity').write_text('private data stays on device\n')
        (candidate / 'trees/backup/tools').mkdir(parents=True)
        (candidate / 'trees/backup/init.sh').write_text('#!/bin/sh\necho CORE\n')
        (core / 'bin/hostapd').write_text('fixture AP daemon\n')
        (candidate / 'boot-vmalloc.bin').write_bytes(b'kernel fixture')
        (candidate / 'report.json').write_text(json.dumps({'model': model, 'images': {}}))
        for part, n in [('rootfs', 2), ('home', 3)]:
            stock = bytearray(bytes([n]) * 4096 + bytes(SIZES[n] - 4096))
            stock[:4] = b'hsqs'
            struct.pack_into('<Q', stock, 40, 1024)
            (base / (part + '.bin')).write_bytes(stock)
            (candidate / (part + '.squashfs')).write_bytes(bytes([n + 20]) * 4096)
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-O2', str(ROOT / 'scripts/flash-core/clean_image.c'), '-o', str(candidate / 'clean-image')], check=True)
        name = pack.package(candidate, base, root, 'test', 'fixture')
        sd = candidate / 'sd-installer'
        p = sd / 'flash-core'
        (root / 'dev').mkdir()
        for n, size in enumerate(SIZES):
            (root / f'dev/mtdblock{n}').write_bytes(bytes([n]) * size)
        for part, n in [('rootfs', 2), ('home', 3)]:
            shutil.copyfile(base / (part + '.bin'), root / f'dev/mtdblock{n}')
        (root / 'homever').write_text(pack.VERSIONS[model] + '\n')
        (root / 'mtd').write_text('dev: size erasesize name\n' + ''.join(
            f'mtd{n}: {size:08x} 00001000 "partition{n}"\n' for n, size in enumerate(SIZES)))
        (root / 'mounts').write_text(f'{root}/dev/mmcblk0p1 {sd} vfat rw 0 0\n')
        (root / 'bin').mkdir()
        for command, body in {'df': 'echo "Filesystem 1K-blocks Used Available Use% Mounted"\necho "mock 100000 1000 ${FREE_KIB:-99000} 1% mock"',
                              'mount': 'exit 0', 'sync': 'exit 0',
                              'reboot': 'echo "$*" >> "$REBOOTS"'}.items():
            pack.write(root / 'bin' / command, '#!/bin/sh\n' + body + '\n', True)
        for path in [p / 'install.sh', p / 'dispatcher.sh']:
            script = path.read_text()
            for original, replacement in [('/tmp/sd', sd), ('/backup', b),
                                          ('/home/homever', root / 'homever'),
                                          ('/home/yi-hack', root / 'installed-core'),
                                          ('/proc/mtd', root / 'mtd'), ('/proc/mounts', root / 'mounts'),
                                          ('/dev/mtdblock', root / 'dev/mtdblock'),
                                          ('/dev/mmcblk', root / 'dev/mmcblk')]:
                if original == '/backup':
                    script = re.sub(r'/backup(?=/|["\s]|$)', str(replacement), script)
                else:
                    script = script.replace(original, str(replacement))
            script = script.replace('/bin/busybox reboot -f', 'reboot -f')
            path.write_text(script)
        pack.manifest(sd)
        env = dict(os.environ, PATH=str(root / 'bin') + ':' + os.environ['PATH'],
                   REBOOTS=str(root / 'reboots'), KERNEL_CALLS=str(root / 'kernel-calls'))
        return root, candidate, sd, b, env, name

    def run_script(self, path, env, ok=True, args=()):
        result = subprocess.run(['/bin/sh', str(path), *args], env=env, text=True, capture_output=True, timeout=20)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def flash(self, root, candidate, part):
        n = 2 if part == 'rootfs' else 3
        image = (candidate / (part + '.squashfs')).read_bytes()
        (root / f'dev/mtdblock{n}').write_bytes(image + b'\xff' * (SIZES[n] - len(image)))

    def clean_fixture(self, model):
        root, c, sd, b, env, name = self.fixture(model)
        installed = root / 'installed-core'
        installed.mkdir()
        (installed / 'flash-core').write_text('1\n')
        (installed / 'model_suffix').write_text(model + '\n')
        (b / 'flash-core-init.sh').write_text('#!/bin/sh\necho OLD_CORE\n')
        (b / 'flash-core-original-init.sh').write_text('original vendor bootstrap\n')
        (b / 'yi-hack-config').mkdir()
        (b / 'yi-hack-config/system.conf').write_text('WIFI_HOTSPOT_PASSWORD=old-private-password\n')
        for n in (2, 3):
            data = bytearray(bytes([n + 40]) * SIZES[n])
            data[:4] = b'hsqs'
            struct.pack_into('<H', data, 28, 4)
            struct.pack_into('<Q', data, 40, 5000)
            (root / f'dev/mtdblock{n}').write_bytes(data)
        return root, c, sd, b, env, name

    def test_clean_upgrade_both_models_resumes_resets_to_hotspot_and_recovers_previous_core(self):
        for model in pack.VERSIONS:
            with self.subTest(model=model):
                root, c, sd, b, env, _ = self.clean_fixture(model)
                old_settings = (b / 'yi-hack-config/system.conf').read_bytes()
                identity = (root / 'dev/mtdblock6').read_bytes()
                self.run_script(sd / 'flash-core/install.sh', env, args=('--prepare-clean',))
                self.assertEqual((b / 'yi-hack-config/system.conf').read_bytes(), old_settings)
                recovery = sd / 'flash-core-recovery'
                self.assertTrue((recovery / 'files/previous-core.tar').exists())
                # Even an explicit router config must not override clean setup.
                (sd / 'Factory/configure_wifi.cfg').write_text('wifi_ssid=ignored\nwifi_psk=ignored\n')
                self.run_script(b / 'init.sh', env)
                self.assertIn('WIFI_HOTSPOT_BOOT=yes', (b / 'yi-hack-config/system.conf').read_text())
                self.assertNotIn('old-private-password', (b / 'yi-hack-config/system.conf').read_text())
                self.assertFalse((sd / 'Factory/configure_wifi.cfg').exists())
                self.flash(root, c, 'rootfs')
                self.run_script(b / 'init.sh', env)
                self.flash(root, c, 'home')
                self.run_script(b / 'init.sh', env)
                self.assertFalse((b / 'flash-core-install.pending').exists())
                self.assertFalse((sd / 'flash-core/CLEAN_INSTALL').exists())
                self.assertEqual((root / 'dev/mtdblock6').read_bytes(), identity)
                absent = sd.with_name('absent')
                sd.rename(absent)
                self.assertIn('CORE', self.run_script(b / 'init.sh', env).stdout)
                absent.rename(sd)
                for part, n in [('rootfs', 2), ('home', 3)]:
                    wrapped = (recovery / f'files/{part}.restore').read_bytes()
                    h = struct.unpack('>7I4B32s', wrapped[:64])
                    self.assertEqual(h[6], zlib.crc32(wrapped[64:]))
                    self.assertEqual(h[11].rstrip(b'\0'), ('xiaoyi-' + part).encode())
                    (root / f'dev/mtdblock{n}').write_bytes(wrapped[64:] + b'\xff' * (SIZES[n] - len(wrapped[64:])))
                (recovery / 'RESTORE').touch()
                self.run_script(b / 'init.sh', env)
                self.assertEqual((b / 'yi-hack-config/system.conf').read_bytes(), old_settings)
                self.assertEqual((b / 'flash-core-original-init.sh').read_text(), 'original vendor bootstrap\n')
                self.assertIn('OLD_CORE', (b / 'flash-core-init.sh').read_text())
                self.assertFalse((sd / 'yi-hack-config').exists())

    def test_clean_ignored_updates_restore_previous_settings_and_startup(self):
        root, c, sd, b, env, _ = self.clean_fixture('y28ga')
        old_settings = (b / 'yi-hack-config/system.conf').read_bytes()
        self.run_script(sd / 'flash-core/install.sh', env, args=('--prepare-clean',))
        for _ in range(4):
            self.run_script(b / 'init.sh', env)
        self.assertFalse((b / 'flash-core-install.pending').exists())
        self.assertEqual((b / 'yi-hack-config/system.conf').read_bytes(), old_settings)
        self.assertFalse((sd / 'yi-hack-config').exists())
        self.assertIn('three attempts', (sd / 'hack_result.txt').read_text())

    def test_clean_interrupted_settings_staging_restores_previous_boot(self):
        root, c, sd, b, env, _ = self.clean_fixture('y28ga')
        old = (b / 'yi-hack-config/system.conf').read_bytes()
        self.run_script(sd / 'flash-core/install.sh', env, args=('--prepare-clean',))
        # Simulate power loss after staging began, before pending was committed.
        (sd / 'yi-hack-config').mkdir()
        (sd / 'yi-hack-config/system.conf').write_text('partial defaults\n')
        self.run_script(b / 'init.sh', env)
        self.assertEqual((b / 'yi-hack-config/system.conf').read_bytes(), old)
        self.assertFalse((b / 'flash-core-install.pending').exists())
        self.assertFalse((sd / 'yi-hack-config').exists())

    def test_clean_resume_rejects_foreign_identity_before_resetting_settings(self):
        root, c, sd, b, env, _ = self.clean_fixture('y28ga')
        old = (b / 'yi-hack-config/system.conf').read_bytes()
        self.run_script(sd / 'flash-core/install.sh', env, args=('--prepare-clean',))
        (root / 'dev/mtdblock6').write_bytes(b'foreign camera')
        self.run_script(b / 'init.sh', env, ok=False)
        self.assertEqual((b / 'yi-hack-config/system.conf').read_bytes(), old)
        self.assertFalse((sd / 'rootfs_y28ga').exists())

    def test_clean_prepare_rejects_unsupported_inputs_without_changing_startup(self):
        for kind in ('model', 'layout', 'space', 'image', 'package'):
            with self.subTest(kind=kind):
                root, c, sd, b, env, _ = self.clean_fixture('y623')
                before = (b / 'init.sh').read_bytes()
                if kind == 'model': (root / 'installed-core/model_suffix').write_text('y28ga\n')
                if kind == 'layout': (root / 'mounts').write_text('')
                if kind == 'space': env['FREE_KIB'] = '1'
                if kind == 'image': (root / 'dev/mtdblock2').write_bytes(b'corrupt image')
                if kind == 'package': (sd / 'flash-core/core-init.sh').write_text('damaged\n')
                self.run_script(sd / 'flash-core/install.sh', env, ok=False, args=('--prepare-clean',))
                self.assertEqual((b / 'init.sh').read_bytes(), before)
                self.assertFalse((sd / 'rootfs_y623').exists())

    def test_both_models_install_resume_finalize_boot_without_sd_and_restore(self):
        for model in pack.VERSIONS:
            with self.subTest(model=model):
                root, c, sd, b, env, _ = self.fixture(model)
                self.run_script(sd / 'flash-core/install.sh', env)
                self.assertEqual((sd / 'flash-core-recovery/mtd/mtdblock6.bin').read_bytes(), (root / 'dev/mtdblock6').read_bytes())
                self.assertEqual((b / 'lower_half_init.sh').read_text(), 'original lower half\n')
                self.assertTrue((b / 'flash-core-install.pending').exists())
                self.assertTrue((sd / f'rootfs_{model}').exists())
                # An interrupted update with only rootfs completed must resume.
                self.flash(root, c, 'rootfs')
                (sd / f'rootfs_{model}').unlink()
                self.run_script(b / 'init.sh', env)
                self.assertTrue((sd / f'rootfs_{model}').exists())
                self.flash(root, c, 'home')
                self.run_script(b / 'init.sh', env)
                self.assertFalse((b / 'flash-core-install.pending').exists())
                self.assertFalse((sd / f'rootfs_{model}').exists())
                self.assertFalse((sd / 'Factory/factory_test.sh').exists())
                self.assertFalse((sd / 'lower_half_init.sh').exists())
                self.assertIn('images verified', (sd / 'hack_result.txt').read_text())
                # Rename away all SD contents: normal dispatcher must need none.
                absent = sd.with_name('absent-sd')
                sd.rename(absent)
                self.assertIn('CORE', self.run_script(b / 'init.sh', env).stdout)
                absent.rename(sd)
                for part, n in [('rootfs', 2), ('home', 3)]:
                    restored = pack.stock_payload((c.parent / 'base' / (part + '.bin')).read_bytes())
                    (root / f'dev/mtdblock{n}').write_bytes(restored + b'\xff' * (SIZES[n] - len(restored)))
                (sd / 'flash-core-recovery/RESTORE').touch()
                self.run_script(b / 'init.sh', env)
                self.assertIn('VENDOR', self.run_script(b / 'init.sh', env).stdout)
                self.assertEqual((b / 'tools/upgrade.sh').read_text(), 'original updater\n')
                self.assertEqual((b / 'private-identity').read_text(), 'private data stays on device\n')
                self.assertFalse((b / 'tools/hostapd').exists())
                self.assertEqual(set((root / 'reboots').read_text().splitlines()), {'-f'})
                if model == 'y623':
                    self.assertEqual((root / 'kernel-calls').read_text().splitlines(), ['--check', ''])

    def test_rejects_wrong_model_image_layout_corrupt_package_and_existing_settings(self):
        for kind in ['version', 'stock-image', 'layout', 'package', 'settings', 'sd-space']:
            with self.subTest(kind=kind):
                root, c, sd, b, env, _ = self.fixture()
                original = (b / 'init.sh').read_bytes()
                if kind == 'version': (root / 'homever').write_text('unsupported')
                if kind == 'stock-image': (root / 'dev/mtdblock3').write_bytes(b'wrong image')
                if kind == 'layout': (root / 'mtd').write_text((root / 'mtd').read_text().replace('00001000', '00010000'))
                if kind == 'package': (sd / 'flash-core/images/home_y28ga.stage').write_bytes(b'corrupt')
                if kind == 'settings': (b / 'yi-hack-config').mkdir()
                if kind == 'sd-space': env['FREE_KIB'] = '1'
                self.run_script(sd / 'flash-core/install.sh', env, ok=False)
                self.assertEqual((b / 'init.sh').read_bytes(), original)
                self.assertFalse((sd / 'home_y28ga').exists())
                self.assertFalse((sd / 'flash-core-recovery').exists())

    def test_low_internal_space_never_activates_bootloader_updates_and_can_recover(self):
        root, c, sd, b, env, _ = self.fixture()
        pack.write(root / 'bin/df', '#!/bin/sh\necho "Filesystem Total Used Available Use% Mounted"\ncase "$*" in *backup*) free=1 ;; *) free=99000 ;; esac\necho "mock 100000 1000 $free 1% mock"\n', True)
        self.run_script(sd / 'flash-core/install.sh', env, ok=False)
        self.assertFalse((b / 'flash-core-install.pending').exists())
        self.assertFalse((sd / 'home_y28ga').exists())
        self.assertFalse((sd / 'Factory/factory_test.sh').exists())
        self.assertFalse((sd / 'lower_half_init.sh').exists())
        self.assertFalse((b / 'yi-hack-config').exists())
        self.assertFalse((b / 'flash-core-original-init.sh').exists())
        self.assertFalse((b / 'flash-core-init.sh.new').exists())
        self.assertTrue((sd / 'flash-core-recovery/failed-settings/system.conf').exists())
        self.assertEqual((b / 'tools/upgrade.sh').read_text(), 'original updater\n')
        self.assertIn('VENDOR', self.run_script(b / 'init.sh', env).stdout)
        (sd / 'flash-core-recovery/RESTORE').touch()
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertIn('VENDOR', self.run_script(b / 'init.sh', env).stdout)

    def test_recovered_vendor_filesystems_accept_erased_padding_only(self):
        root, c, sd, b, env, _ = self.fixture()
        for part, n in [('rootfs', 2), ('home', 3)]:
            prefix = pack.stock_payload((c.parent / 'base' / (part + '.bin')).read_bytes())
            (root / f'dev/mtdblock{n}').write_bytes(prefix + b'\xff' * (SIZES[n] - len(prefix)))
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertTrue((b / 'flash-core-install.pending').exists())

    def test_y623_does_not_stage_hostapd_in_writable_flash(self):
        root, c, sd, b, env, _ = self.fixture('y623')
        self.assertFalse((sd / 'flash-core/hostapd').exists())
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertFalse((b / 'tools/hostapd').exists())
        self.assertTrue((b / 'flash-core-install.pending').exists())

    def test_y623_rejects_unpartitioned_card_before_persistent_changes_and_reboots_previous_startup(self):
        root, c, sd, b, env, _ = self.fixture('y623')
        (root / 'mounts').write_text(f'{root}/dev/mmcblk0 {sd} vfat rw 0 0\n')
        original = (b / 'init.sh').read_bytes()
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertEqual((b / 'init.sh').read_bytes(), original)
        self.assertFalse((b / 'yi-hack-config').exists())
        self.assertFalse((b / 'flash-core-install.pending').exists())
        self.assertFalse((sd / 'flash-core-recovery').exists())
        self.assertFalse((sd / 'rootfs_y623').exists())
        self.assertFalse((sd / 'home_y623').exists())
        self.assertFalse((root / 'kernel-calls').exists())
        self.assertFalse((sd / 'Factory/factory_test.sh').exists())
        self.assertFalse((sd / 'lower_half_init.sh').exists())
        self.assertTrue((sd / 'flash-core/factory_test.failed').exists())
        self.assertTrue((sd / 'flash-core/lower_half_init.failed').exists())
        self.assertIn('Nothing flashed', (sd / 'hack_result.txt').read_text())
        self.assertIn('partition 1', (sd / 'hack_result.txt').read_text())
        self.assertEqual((root / 'reboots').read_text().splitlines(), ['-f'])
        self.assertIn('VENDOR', self.run_script(b / 'init.sh', env).stdout)

    def test_y28ga_still_accepts_whole_device_fat32(self):
        root, c, sd, b, env, _ = self.fixture('y28ga')
        (root / 'mounts').write_text(f'{root}/dev/mmcblk0 {sd} vfat rw 0 0\n')
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertTrue((b / 'flash-core-install.pending').exists())
        self.assertTrue((sd / 'rootfs_y28ga').exists())

    def test_y623_accepts_block_device_alias_for_first_partition(self):
        root, c, sd, b, env, _ = self.fixture('y623')
        (root / 'mounts').write_text(f'/dev/block/mmcblk0p1 {sd} vfat rw 0 0\n')
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertTrue((b / 'flash-core-install.pending').exists())

    def test_pending_rejects_foreign_identity_unknown_partial_image_and_release(self):
        for kind in ['identity', 'partial', 'release']:
            with self.subTest(kind=kind):
                root, c, sd, b, env, _ = self.fixture()
                self.run_script(sd / 'flash-core/install.sh', env)
                if kind == 'identity': (root / 'dev/mtdblock6').write_bytes(b'other camera')
                if kind == 'partial': (root / 'dev/mtdblock3').write_bytes(b'unknown partial')
                if kind == 'release': (b / 'flash-core-install.pending').write_text('other release')
                (sd / 'rootfs_y28ga').unlink()
                self.run_script(b / 'init.sh', env, ok=False)
                self.assertFalse((sd / 'rootfs_y28ga').exists())

    def test_finalization_resumes_after_hook_was_already_retired(self):
        root, c, sd, b, env, _ = self.fixture()
        self.run_script(sd / 'flash-core/install.sh', env)
        for part in ['rootfs', 'home']: self.flash(root, c, part)
        (sd / 'lower_half_init.sh').rename(sd / 'flash-core/lower_half_init.installed')
        (sd / 'Factory/factory_test.sh').rename(sd / 'flash-core/factory_test.installed')
        self.run_script(b / 'init.sh', env)
        self.assertFalse((b / 'flash-core-install.pending').exists())

    def test_journal_committed_before_dispatcher_rename_can_resume(self):
        root, c, sd, b, env, _ = self.fixture()
        self.run_script(sd / 'flash-core/install.sh', env)
        shutil.copyfile(sd / 'flash-core-recovery/files/init.sh', b / 'init.sh')
        self.run_script(sd / 'flash-core/install.sh', env)
        self.assertEqual((b / 'init.sh').read_bytes(), (sd / 'flash-core/dispatcher.sh').read_bytes())
        for part in ['rootfs', 'home']: self.flash(root, c, part)
        self.run_script(b / 'init.sh', env)
        self.assertIn('CORE', self.run_script(b / 'init.sh', env).stdout)

    def test_ignored_updates_restore_working_startup_after_bounded_retries(self):
        for model in pack.VERSIONS:
            with self.subTest(model=model):
                root, c, sd, b, env, _ = self.fixture(model)
                original = (b / 'init.sh').read_bytes()
                self.run_script(sd / 'flash-core/install.sh', env)
                self.run_script(b / 'init.sh', env)
                self.run_script(b / 'init.sh', env)
                self.run_script(b / 'init.sh', env)
                self.assertFalse((sd / f'home_{model}').exists())
                self.assertFalse((sd / f'rootfs_{model}').exists())
                self.assertFalse((b / 'flash-core-install.pending').exists())
                self.assertFalse((sd / 'Factory/factory_test.sh').exists())
                self.assertFalse((sd / 'lower_half_init.sh').exists())
                self.assertEqual((b / 'init.sh').read_bytes(), original)
                self.assertIn('VENDOR', self.run_script(b / 'init.sh', env).stdout)
                self.assertEqual(len((root / 'reboots').read_text().splitlines()), 4)
                self.assertIn('three attempts', (sd / 'hack_result.txt').read_text())
                self.assertIn('Previous firmware/startup restored', (sd / 'hack_result.txt').read_text())
                self.assertTrue((sd / 'flash-core-recovery/mtd/mtdblock6.bin').exists())

    def test_partial_update_retry_exhaustion_preserves_explicit_recovery(self):
        for part in ['rootfs', 'home']:
            with self.subTest(part=part):
                root, c, sd, b, env, _ = self.fixture('y623')
                self.run_script(sd / 'flash-core/install.sh', env)
                self.flash(root, c, part)
                self.run_script(b / 'init.sh', env)
                self.run_script(b / 'init.sh', env)
                self.run_script(b / 'init.sh', env, ok=False)
                self.assertTrue((b / 'flash-core-install.pending').exists())
                self.assertEqual((b / 'init.sh').read_bytes(), (sd / 'flash-core/dispatcher.sh').read_bytes())
                self.assertFalse((sd / 'flash-core-recovery/RESTORE').exists())
                self.assertIn('use recovery', (sd / 'hack_result.txt').read_text())

    def test_automatic_recovery_still_refuses_corrupt_backups(self):
        root, c, sd, b, env, _ = self.fixture('y623')
        self.run_script(sd / 'flash-core/install.sh', env)
        self.run_script(b / 'init.sh', env)
        self.run_script(b / 'init.sh', env)
        (sd / 'flash-core-recovery/files/init.sh').write_text('corrupt')
        before = (b / 'init.sh').read_bytes()
        self.run_script(b / 'init.sh', env, ok=False)
        self.assertEqual((b / 'init.sh').read_bytes(), before)
        self.assertTrue((b / 'flash-core-install.pending').exists())

    def test_recovery_refuses_wrong_identity_corrupt_backups_or_nonstock_images(self):
        for kind in ['identity', 'backup', 'image']:
            with self.subTest(kind=kind):
                root, c, sd, b, env, _ = self.fixture()
                self.run_script(sd / 'flash-core/install.sh', env)
                (sd / 'flash-core-recovery/RESTORE').touch()
                if kind == 'identity': (root / 'dev/mtdblock6').write_bytes(b'foreign')
                if kind == 'backup': (sd / 'flash-core-recovery/files/init.sh').write_text('corrupt')
                if kind == 'image': self.flash(root, c, 'rootfs')
                before = (b / 'init.sh').read_bytes()
                self.run_script(b / 'init.sh', env, ok=False)
                self.assertEqual((b / 'init.sh').read_bytes(), before)

    def test_pending_dispatcher_can_repair_only_explicitly_audited_previous_startup(self):
        for audited in [True, False]:
            with self.subTest(audited=audited):
                root, c, sd, b, env, _ = self.fixture()
                self.run_script(sd / 'flash-core/install.sh', env)
                (b / 'init.sh').write_text('#!/bin/sh\necho PREVIOUS_DISPATCHER\n')
                if audited:
                    with (sd / 'flash-core/install.conf').open('a') as stream:
                        stream.write("PREVIOUS_DISPATCH_HASH='" + pack.md5(b / 'init.sh') + "'\n")
                    pack.manifest(sd)
                for part in ['rootfs', 'home']: self.flash(root, c, part)
                self.run_script(sd / 'flash-core/install.sh', env, ok=audited)
                if audited:
                    self.assertEqual((b / 'init.sh').read_bytes(), (sd / 'flash-core/dispatcher.sh').read_bytes())
                    self.assertIn('CORE', self.run_script(b / 'init.sh', env).stdout)

    def test_early_boot_creates_ram_mount_before_sd_directory(self):
        root, c, sd, b, env, _ = self.fixture()
        (b / 'flash-core-install.pending').write_text('pending')
        marker = root / 'ram-mounted'
        pack.write(root / 'bin/mount', '#!/bin/sh\ncase "$*" in *tmpfs*) touch "' + str(marker) + '" ;; esac\n', True)
        # Emulate missing /tmp/sd on read-only SquashFS until tmpfs is mounted.
        pack.write(root / 'bin/mkdir', '#!/bin/sh\nif [ "$*" = "-p ' + str(sd) + '" ] && [ ! -e "' + str(marker) + '" ]; then\n echo "read-only rootfs" >&2; exit 1; fi\nexec /bin/mkdir "$@"\n', True)
        (root / 'mounts').write_text('')
        dispatcher = sd / 'flash-core/dispatcher.sh'
        dispatcher.write_text(dispatcher.read_text().replace('/proc/mounts', str(root / 'mounts')))
        pack.write(sd / 'flash-core/install.sh', 'echo INSTALLER_RESUMED\n', True)
        self.assertIn('INSTALLER_RESUMED', self.run_script(dispatcher, env).stdout)
        self.assertTrue(marker.exists())

    def test_uimage_header_and_archive_boundaries(self):
        import tarfile
        for model in pack.VERSIONS:
            with self.subTest(model=model):
                root, c, sd, b, env, name = self.fixture(model)
                with tarfile.open(root / name) as archive:
                    names = archive.getnames()
                    self.assertIn('Factory/config.sh', names)
                    self.assertNotIn(f'home_{model}', names)
                    self.assertFalse(any('mtdblock' in n or 'backup.jffs2' in n or 'private-identity' in n for n in names))
                    data = archive.extractfile(f'flash-core/images/home_{model}.stage').read()
                    header = list(struct.unpack('>7I4B32s', data[:64]))
                    self.assertEqual(header[0], 0x27051956)
                    self.assertGreater(header[2], 0)
                    hcrc = header[1]; header[1] = 0
                    self.assertEqual(zlib.crc32(struct.pack('>7I4B32s', *header)), hcrc)
                    self.assertEqual(header[3], len(data) - 64)
                    self.assertEqual(header[6], zlib.crc32(data[64:]))
                    self.assertEqual(data[64:], (c / 'home.squashfs').read_bytes())
                    # Audited U-Boot check at 0x4a01b5e8/0x4a01b600 requires
                    # xiaoyi-rootfs for image 2, xiaoyi-home for image 3.
                    for part in ['rootfs', 'home']:
                        for folder, suffix in [('images', 'stage'), ('recovery', 'restore')]:
                            wrapped = archive.extractfile(f'flash-core/{folder}/{part}_{model}.{suffix}').read()
                            h = struct.unpack('>7I4B32s', wrapped[:64])
                            self.assertEqual(h[8:11], (2, 7, 0))
                            self.assertEqual(h[11].rstrip(b'\0'), ('xiaoyi-' + part).encode())
                            self.assertEqual(h[6], zlib.crc32(wrapped[64:]))
                    report = json.load(archive.extractfile('flash-core/report.json'))
                    self.assertTrue(report['installable'])
                    self.assertFalse(report['hardware_validated'])
                    for part in ['rootfs', 'home']:
                        restored = archive.extractfile(f'flash-core/recovery/{part}_{model}.restore').read()
                        self.assertLessEqual(len(restored), pack.LIMITS[part])
                        self.assertEqual(restored[64:], pack.stock_payload((c.parent / 'base' / (part + '.bin')).read_bytes()))

    def test_windows_zip_preserves_manifest_and_fat_compatible_links(self):
        import zipfile
        root, c, sd, b, env, name = self.fixture()
        optional = sd / 'yi-hack-optional/lib'
        optional.mkdir(parents=True)
        (optional / 'library.so').write_bytes(b'library fixture')
        (optional / 'library.so.1').symlink_to('library.so')
        output = root / 'fat-test.zip'
        pack.write_zip(sd, output)
        with zipfile.ZipFile(root / pack.zip_name(name)) as archive:
            self.assertEqual(archive.read('Factory/factory_test.sh'), b'')
            for row in archive.read('flash-core/files.md5').decode().splitlines():
                digest, filename = row.split('  ', 1)
                self.assertEqual(hashlib.md5(archive.read(filename)).hexdigest(), digest)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read('yi-hack-optional/lib/library.so.1'), b'library fixture')
        (optional / 'escape').symlink_to(root / 'homever')
        with self.assertRaisesRegex(ValueError, 'leaves installer tree'):
            pack.write_zip(sd, root / 'unsafe.zip')


if __name__ == '__main__':
    unittest.main()
