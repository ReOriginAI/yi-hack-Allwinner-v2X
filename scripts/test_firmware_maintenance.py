#!/usr/bin/env python3
"""Exercise firmware status and reject incompatible uploads before any writes."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CGI = ROOT / 'src/www/httpd/cgi-bin'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')


class FirmwareMaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='firmware-maintenance-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.prefix = self.root / 'core'
        self.sd = self.root / 'sd'
        self.backup = self.root / 'backup'
        for directory in (self.prefix / 'www/cgi-bin', self.sd, self.backup):
            directory.mkdir(parents=True)
        shutil.copy2(CGI / 'validate.sh', self.prefix / 'www/cgi-bin/validate.sh')
        (self.prefix / 'flash-core').write_text('1\n')
        (self.prefix / 'model_suffix').write_text('y623\n')
        (self.prefix / 'version').write_text('3.8.0-flash-core\n')
        (self.backup / 'init.sh').write_text('bootstrap must survive\n')
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.prefix),
                        YI_HACK_SD_ROOT=str(self.sd), YI_HACK_BACKUP_ROOT=str(self.backup),
                        YI_HACK_REBOOT_CMD='/bin/false', REQUEST_METHOD='POST',
                        CONTENT_LENGTH='1000000', QUERY_STRING='get=upgrade')

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() if p.is_file() else None
                for p in self.root.rglob('*')}

    def parse(self, result):
        header, body = result.stdout.split('\n\n', 1)
        self.assertIn('Content-type: application/json', header)
        return json.loads(body)

    def call(self, script, **env):
        return subprocess.run([BUSYBOX, 'ash', str(CGI / script)],
                              env=dict(self.env, **env), input='', text=True,
                              capture_output=True, timeout=3)

    def test_core_status_is_local_and_disables_stale_sd_payloads_for_both_models(self):
        for model in ('y623', 'y28ga'):
            with self.subTest(model=model):
                (self.prefix / 'model_suffix').write_text(model + '\n')
                (self.sd / (model + '_x.x.x.tgz')).write_bytes(b'stale legacy package')
                before = self.snapshot()
                result = self.call('fw_upgrade.sh', QUERY_STRING='get=info')
                self.assertEqual(result.returncode, 0, result.stderr)
                data = self.parse(result)
                self.assertEqual(data['fw_version'], '3.8.0-flash-core')
                self.assertEqual(data['profile'], 'flash-core')
                self.assertFalse(data['error'])
                self.assertFalse(data['upload_supported'])
                self.assertFalse(data['local_fw'])
                self.assertIn('not supported', data['description'])
                self.assertEqual(self.snapshot(), before)

    def test_core_upload_rejects_without_waiting_for_body_or_removing_another_lock(self):
        for model in ('y623', 'y28ga'):
            with self.subTest(model=model):
                (self.prefix / 'model_suffix').write_text(model + '\n')
                lock = self.sd / '.fw_upload.lock.d'
                lock.mkdir(exist_ok=True)
                (lock / 'pid').write_text(str(os.getpid()))
                before = self.snapshot()
                # Keep the pipe open: a handler that reads stdin would hang here.
                process = subprocess.Popen([BUSYBOX, 'ash', str(CGI / 'fw_upload.sh')],
                                           env=self.env, stdin=subprocess.PIPE,
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                           text=True)
                try:
                    self.assertEqual(process.wait(timeout=2), 1)
                    output, error = process.communicate(timeout=1)
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.communicate()
                data = self.parse(subprocess.CompletedProcess([], 1, output, error))
                self.assertTrue(data['error'])
                self.assertIn('not supported on flash-core', data['description'])
                self.assertEqual(self.snapshot(), before)

    def test_info_accepts_browser_cache_buster_for_both_profiles(self):
        for profile in ('flash-core', 'sd-legacy'):
            if profile == 'sd-legacy':
                (self.prefix / 'flash-core').unlink()
            with self.subTest(profile=profile):
                result = self.call('fw_upgrade.sh', QUERY_STRING='get=info&_=1793790000000')
                self.assertEqual(result.returncode, 0, result.stderr)
                data = self.parse(result)
                self.assertFalse(data['error'])
                self.assertEqual(data['profile'], profile)

    def test_core_direct_upgrade_rejects_without_staging_rollback_or_bootstrap_changes(self):
        for model in ('y623', 'y28ga'):
            (self.prefix / 'model_suffix').write_text(model + '\n')
            (self.sd / (model + '_x.x.x.tgz')).write_bytes(b'staged package')
            for query in ('get=upgrade', '', 'get=upgrade&extra=value'):
                with self.subTest(model=model, query=query):
                    before = self.snapshot()
                    result = self.call('fw_upgrade.sh', QUERY_STRING=query)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertTrue(self.parse(result)['error'])
                    self.assertEqual(self.snapshot(), before)

    def test_core_rejects_with_no_sd_card(self):
        self.sd.rmdir()
        for script in ('fw_upload.sh', 'fw_upgrade.sh'):
            with self.subTest(script=script):
                before = self.snapshot()
                result = self.call(script)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn('flash-core', self.parse(result)['description'])
                self.assertEqual(self.snapshot(), before)

    def test_legacy_info_still_reports_staged_packages(self):
        (self.prefix / 'flash-core').unlink()
        for model in ('y623', 'y28ga'):
            for staged in (False, True):
                with self.subTest(model=model, staged=staged):
                    (self.prefix / 'model_suffix').write_text(model + '\n')
                    archive = self.sd / (model + '_x.x.x.tgz')
                    if staged:
                        archive.write_bytes(b'legacy package')
                    result = self.call('fw_upgrade.sh', QUERY_STRING='get=info')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    data = self.parse(result)
                    self.assertEqual(data['profile'], 'sd-legacy')
                    self.assertTrue(data['upload_supported'])
                    self.assertEqual(data['local_fw'], staged)

    def test_legacy_upload_still_validates_and_stages_matching_y28ga_package(self):
        (self.prefix / 'flash-core').unlink()
        (self.prefix / 'model_suffix').write_text('y28ga\n')
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for name, data in {'yi-hack/model_suffix': b'y28ga\n',
                               'yi-hack/version': b'3.8.0\n',
                               'Factory/local_init.sh': b'#!/bin/sh\nexit 0\n',
                               'lower_half_init.sh': b'#!/bin/sh\nexit 0\n'}.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        payload = stream.getvalue()
        result = subprocess.run([BUSYBOX, 'ash', str(CGI / 'fw_upload.sh')],
                                env=dict(self.env, CONTENT_LENGTH=str(len(payload))),
                                input=payload, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(json.loads(result.stdout.split(b'\r\n\r\n', 1)[1])['error'])
        self.assertEqual((self.sd / 'y28ga_x.x.x.tgz').read_bytes(), payload)
        self.assertFalse((self.sd / '.fw_upload.lock.d').exists())

    @unittest.skipUnless(shutil.which('rsync'), 'web installer needs rsync')
    def test_web_rebuild_removes_retired_endpoints_and_preserves_onvif_program(self):
        workspace = self.root / 'web-install'
        source = workspace / 'src/www'
        (source / '_install/www/cgi-bin').mkdir(parents=True)
        (source / '_install/www/cgi-bin/fw_upgrade.sh').write_text('new status endpoint\n')
        output = workspace / 'build/yi-hack/www'
        (output / 'onvif').mkdir(parents=True)
        (output / 'onvif/onvif_simple_server').write_bytes(b'separately compiled program')
        (output / 'cgi-bin').mkdir()
        (output / 'cgi-bin/fw_online.sh').write_text('retired endpoint\n')
        installer = source / 'install.www'
        shutil.copy2(ROOT / 'src/www/install.www', installer)
        subprocess.run(['bash', str(installer)], check=True, capture_output=True, timeout=5)
        self.assertFalse((output / 'cgi-bin/fw_online.sh').exists())
        self.assertEqual((output / 'cgi-bin/fw_upgrade.sh').read_text(), 'new status endpoint\n')
        self.assertEqual((output / 'onvif/onvif_simple_server').read_bytes(), b'separately compiled program')


if __name__ == '__main__':
    unittest.main()
