#!/usr/bin/env python3
"""Exercise SD detection, persistent fallback, and both offline boot profiles."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'src/static/static/yi-hack/script'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')


class FlashCoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='flash-core-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'core'
        for name in ('etc/dropbear', 'bin', 'script'):
            (self.prefix / name).mkdir(parents=True)
        (self.prefix / 'flash-core').write_text('1\n')
        (self.prefix / 'etc/system.conf').write_text('RTSP=yes\n')
        (self.prefix / 'etc/camera.conf').write_text('LED=yes\n')
        (self.prefix / 'bin/busybox').symlink_to(shutil.which(BUSYBOX))
        for name in ('storage.sh', 'service_lock.sh'):
            shutil.copyfile(SCRIPTS / name, self.prefix / 'script' / name)
        self.mounts = self.root / 'mounts'
        self.mounts.write_text('/dev/mmcblk0p1 /tmp/sd vfat rw 0 0\n')
        self.dest = self.root / 'backup'
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.prefix),
                        YI_STORAGE_MOUNTS=str(self.mounts), YI_FLASH_CONFIG=str(self.dest))

    def shell(self, body):
        return subprocess.run([BUSYBOX, 'ash', '-c', body], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def sync(self):
        return subprocess.run([BUSYBOX, 'ash', str(SCRIPTS / 'flash_config_sync.sh')],
                              env=self.env, capture_output=True, text=True, timeout=5)

    def test_only_the_actual_fat_sd_mount_counts(self):
        for mounts, present in [
            ('', False),
            ('tmpfs /tmp tmpfs rw 0 0\n/dev/mtdblock3 /tmp/sd/yi-hack squashfs ro 0 0\n', False),
            ('/dev/mmcblk0p1 /tmp/sd vfat rw 0 0\n', True),
            ('/dev/block/mmcblk0 /tmp/sd vfat rw 0 0\n', True),
            ('tmpfs /tmp/sd tmpfs rw 0 0\n', False),
        ]:
            with self.subTest(mounts=mounts):
                self.mounts.write_text(mounts)
                result = self.shell(f'. "{SCRIPTS}/storage.sh"; sd_present')
                self.assertEqual(result.returncode == 0, present)

    def test_fallback_copies_keys_and_only_changed_settings(self):
        key = self.prefix / 'etc/dropbear/dropbear_ecdsa_host_key'
        key.write_text('private fixture key')
        self.assertEqual(self.sync().returncode, 0)
        copied = self.dest / 'system.conf'
        inode = copied.stat().st_ino
        self.assertEqual(self.sync().returncode, 0)
        self.assertEqual(copied.stat().st_ino, inode)
        self.assertEqual((self.dest / 'dropbear' / key.name).read_text(), key.read_text())
        self.assertEqual(copied.stat().st_mode & 0o777, 0o600)
        (self.prefix / 'etc/system.conf').write_text('RTSP=no\n')
        self.assertEqual(self.sync().returncode, 0)
        self.assertEqual(copied.read_text(), 'RTSP=no\n')
        key.unlink()
        self.assertEqual(self.sync().returncode, 0)
        self.assertFalse((self.dest / 'dropbear' / key.name).exists())
        self.assertFalse(list(self.dest.rglob('*.new')))

    def test_no_card_does_not_write_flash(self):
        self.mounts.write_text('/dev/mtdblock3 /tmp/sd/yi-hack squashfs ro 0 0\n')
        self.assertEqual(self.sync().returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_limits_reject_before_changing_fallback(self):
        self.assertEqual(self.sync().returncode, 0)
        for count, size in ((1, 65537), (3, 50000), (33, 0)):
            with self.subTest(count=count, size=size):
                for i in range(count):
                    (self.prefix / f'etc/extra{i}.conf').write_bytes(b'x' * size)
                (self.prefix / 'etc/system.conf').write_text('RTSP=no\n')
                self.assertNotEqual(self.sync().returncode, 0)
                self.assertEqual((self.dest / 'system.conf').read_text(), 'RTSP=yes\n')
                for path in (self.prefix / 'etc').glob('extra*.conf'):
                    path.unlink()

    def test_scheduled_recording_jobs_exit_without_sd(self):
        self.mounts.write_text('')
        for name in ('ftppush.sh', 'thumb.sh', 'time_lapse.sh', 'clean_records.sh'):
            with self.subTest(name=name):
                result = subprocess.run([BUSYBOX, 'ash', str(SCRIPTS / name), 'cron'],
                                        env=self.env, capture_output=True, timeout=2)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_storage_boot_uses_internal_fallback_without_card(self):
        self.mounts.write_text('')
        sd = self.root / 'sd'
        sd.mkdir()
        helper = self.prefix / 'script/flash_storage.sh'
        helper.write_text((SCRIPTS / 'flash_storage.sh').read_text()
                          .replace('/home/yi-hack', str(self.prefix))
                          .replace('/backup/yi-hack-config', str(self.dest))
                          .replace('/tmp/sd', str(sd)))
        guard = self.prefix / 'bin/service_guard'
        guard.write_text('#!/bin/sh\nshift\nexec "$@"\n')
        guard.chmod(0o755)
        sync = self.prefix / 'script/flash_config_sync.sh'
        shutil.copyfile(SCRIPTS / 'flash_config_sync.sh', sync)
        mount = self.prefix / 'bin/mount'
        calls = self.root / 'mount-calls'
        mount.write_text(f'#!/bin/sh\necho "$*" >> "{calls}"\n[ "$1" = --bind ]\n')
        mount.chmod(0o755)
        self.env['PATH'] = str(self.prefix / 'bin') + ':' + os.environ['PATH']
        result = self.shell(f'. "{helper}"; flash_storage_init')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / 'system.conf').read_text(), 'RTSP=yes\n')
        self.assertIn(f'--bind {self.dest} {sd}/yi-hack/etc', calls.read_text())

    def test_no_card_recorder_check_does_not_starve_other_services(self):
        self.mounts.write_text('')
        text = (SCRIPTS / 'wd.sh').read_text()
        start = text.index('    if [ "$(get_config REC_WITHOUT_CLOUD)" = "yes" ]')
        end = text.index('\n    if [ "$(get_config REC_WITHOUT_CLOUD)" = yes ]', start)
        body = '''
get_config() { echo yes; }
process_count() { echo 0; }
refresh_oom_policy() { :; }
START_STOP_SCRIPT=/must-not-execute
check() {
''' + text[start:end] + '\necho next-service\n}\ncheck'
        result = self.shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'next-service')

    def test_flash_boot_is_optional_sd_and_does_not_execute_factory(self):
        spec = importlib.util.spec_from_file_location('render', ROOT / 'scripts/vendor-ablation/render.py')
        renderer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(renderer)
        for name in renderer.REQUIRED + ('script/flash_storage.sh', 'script/flash_config_sync.sh'):
            path = self.root / 'payload' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        for model in ('y623', 'y28ga'):
            with self.subTest(model=model):
                text = renderer.render(model, b'noop', self.root / 'payload', flash=True)
                self.assertIn('flash_storage_init || boot_fail flash-storage', text)
                self.assertNotIn('boot_fail no-sd', text)
                self.assertNotIn('/bin/sh /tmp/sd/Factory/config.sh', text)
                self.assertIn('script/flash_config_sync.sh', text)
                self.assertNotIn(renderer.RMM[model], text)
                subprocess.run(['sh', '-n'], input=text, text=True, check=True)
                normal = renderer.render(model, b'noop', self.root / 'payload')
                self.assertIn('boot_fail no-sd', normal)
                self.assertIn('/bin/sh /tmp/sd/Factory/config.sh', normal)


if __name__ == '__main__':
    unittest.main()
