#!/usr/bin/env python3
"""WiFi CGI validation and requests with no real radio or flash operations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
STATIC = ROOT / 'src/static/static/yi-hack'
CGI = ROOT / 'src/www/httpd/cgi-bin'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')

class HotspotApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='hotspot-api-')
        cls.guard = Path(cls.temp.name) / 'guard'
        subprocess.run(['cc', '-std=c99', str(ROOT / 'src/service_guard/service_guard.c'), '-o', str(cls.guard)], check=True)

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for part in ['etc', 'bin', 'script', 'www/cgi-bin', 'mock']:
            (self.root / part).mkdir(parents=True)
        self.config = self.root / 'etc/system.conf'
        shutil.copyfile(STATIC / 'etc/system.conf', self.config)
        shutil.copyfile(CGI / 'validate.sh', self.root / 'www/cgi-bin/validate.sh')
        (self.root / 'bin/busybox').symlink_to(shutil.which(BUSYBOX))
        (self.root / 'bin/service_guard').symlink_to(self.guard)
        self.calls = self.root / 'calls'
        for path, text in {
            'script/hotspot.sh': '''#!/bin/sh
case "$1" in
status) echo "${TEST_STATE:-active}";;
settings) printf 'Camera test\\n6\\n';;
scan) echo 'ESSID:"Network A"';;
reset-supported) [ "$TEST_RESET" = yes ];;
reset-armed) [ "$TEST_ARMED" = yes ];;
start|stop) echo "$1" >> "$TEST_CALLS";;
esac
''',
            'script/configure_wifi.sh': '#!/bin/sh\necho flash-write >> "$TEST_CALLS"\n',
            'mock/iwlist': '#!/bin/sh\necho \'ESSID:"Network A"\'\n'
        }.items():
            p = self.root / path
            p.write_text(text)
            p.chmod(0o755)
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), TEST_CALLS=str(self.calls),
                        TEST_RESET='yes', TEST_ARMED='no', PATH=str(self.root / 'mock')+':'+os.environ['PATH'])

    def call(self, action, payload=None, method='POST', **extra):
        body = json.dumps(payload) if payload is not None else ''
        result = subprocess.run([BUSYBOX, 'ash', str(CGI / 'wifi.sh')],
            env=dict(self.env, QUERY_STRING='action='+action, REQUEST_METHOD=method, **extra),
            input=body+'\n', capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout.split('\n\n', 1)[1])

    def test_status_reports_open_hotspot_and_actual_button_arming(self):
        data = self.call('status', method='GET')
        self.assertEqual(data['hotspot_state'], 'active')
        self.assertEqual(data['hotspot_ssid'], 'Camera test')
        self.assertTrue(data['reset_hotspot_supported'])
        self.assertFalse(data['reset_hotspot_armed'])
        self.assertEqual(data['wifi'], []) # do not scan while acting as an AP
        data = self.call('status', method='GET', TEST_ARMED='yes', TEST_STATE='station')
        self.assertTrue(data['reset_hotspot_armed'])
        self.assertEqual(data['wifi'], ['Network A'])

    def test_changes_require_post_and_only_queue_transitions(self):
        self.assertEqual(self.call('hotspot_start', method='GET')['error'], 'true')
        self.assertFalse(self.calls.exists())
        self.assertEqual(self.call('hotspot_start')['error'], 'false')
        self.assertEqual(self.call('hotspot_stop')['error'], 'false')
        self.assertEqual(self.calls.read_text().splitlines(), ['start','stop'])

    def test_settings_accept_escaped_ssid_and_keep_camera_credentials(self):
        values = {'WIFI_HOTSPOT_BOOT':'yes', 'WIFI_HOTSPOT_CHANNEL':'11',
                  'WIFI_HOTSPOT_SSID':'Open "A" & B|C\\D', 'WIFI_RESET_HOTSPOT':'yes'}
        self.assertEqual(self.call('save', values)['error'], 'false')
        saved = dict(line.split('=',1) for line in self.config.read_text().splitlines() if '=' in line)
        for key, value in values.items(): self.assertEqual(saved[key], value)
        self.assertEqual(saved['PASSWORD'], '')
        self.assertFalse(self.calls.exists())

    def test_invalid_hotspot_input_is_rejected_before_primary_flash_write(self):
        cases = [{'WIFI_HOTSPOT_CHANNEL':'12'}, {'WIFI_HOTSPOT_BOOT':True},
                 {'WIFI_HOTSPOT_SSID':'a\nb'}, {'WIFI_HOTSPOT_SSID':'a\x00b'},
                 {'WIFI_HOTSPOT_SSID':'é'*17}, {'WIFI_RESET_HOTSPOT':'maybe'}]
        before = self.config.read_bytes()
        for value in cases:
            with self.subTest(value=value):
                body = dict(WIFI_ESSID='new', WIFI_PASSWORD='secret', WIFI_PASSWORD2='secret', **value)
                self.assertEqual(self.call('save', body)['error'], 'true')
                self.assertEqual(self.config.read_bytes(), before)
                self.assertFalse(self.calls.exists())

    def test_unknown_firmware_rejects_button_override(self):
        before = self.config.read_bytes()
        data = self.call('save', {'WIFI_RESET_HOTSPOT':'yes'}, TEST_RESET='no')
        self.assertEqual(data['error'], 'true')
        self.assertEqual(self.config.read_bytes(), before)

if __name__ == '__main__':
    unittest.main()
