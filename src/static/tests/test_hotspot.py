#!/usr/bin/env python3
"""Hotspot lifecycle with fake radio/DHCP processes; never touches host networking."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest
import time

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'src/static/static/yi-hack/script'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')

class HotspotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if subprocess.run([BUSYBOX, 'ash', '-c', 'command -v yi_lock'], capture_output=True).returncode:
            raise RuntimeError('Build patched BusyBox and set YI_TEST_BUSYBOX')
        cls.temp = tempfile.TemporaryDirectory(prefix='hotspot-tests-')
        cls.guard = Path(cls.temp.name) / 'guard'
        subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'src/service_guard/service_guard.c'), '-o', str(cls.guard)], check=True)

    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for part in ['script', 'bin', 'etc', 'runtime']:
            (self.root / part).mkdir()
        self.calls = self.root / 'calls'
        self.calls.touch()
        self.runtime = self.root / 'runtime'
        self.request = self.root / 'request'
        self.primary = self.root / 'primary.conf'
        self.primary.write_text('network={ssid="original"; psk="unchanged";}\n')
        (self.root / 'model_suffix').write_text('y623\n')
        self.config = self.root / 'etc/system.conf'
        self.config.write_text('WIFI_HOTSPOT_SSID=Camera "open" #name\nWIFI_HOTSPOT_CHANNEL=6\n')
        shutil.copyfile(SCRIPTS / 'service_lock.sh', self.root / 'script/service_lock.sh')
        (self.root / 'bin/service_guard').symlink_to(self.guard)
        # The DHCP process has the real config argument/PID ownership semantics.
        wrapper = ('#!/bin/sh\n'
                   'if [ "$1" = killall ]; then echo killall "$*" >> "$TEST_CALLS"; exit 0; fi\n'
                   'if [ "$1" = udhcpd ]; then exec python3 "$TEST_ROOT/daemon.py" "$3"; fi\n'
                   'exec ' + shutil.which(BUSYBOX) + ' "$@"\n')
        self.executable('bin/busybox', wrapper)
        self.executable('daemon.py', '#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n')
        self.executable('wpa', '''#!/usr/bin/env python3
import os,sys,subprocess,pathlib
args=sys.argv[1:]
config=next(a[2:] for a in args if a.startswith('-c'))
with open(os.environ['TEST_CALLS'],'a') as f:f.write('wpa '+config+'\\n')
if config.endswith('/wpa.conf'):
    child=subprocess.Popen(['python3',os.environ['TEST_ROOT']+'/daemon.py',config],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    pathlib.Path(os.environ['TEST_ROOT']+'/runtime/wpa.pid').write_text(str(child.pid))
''')
        self.executable('wpa_cli', '''#!/bin/sh
case "$*" in
 *terminate) exit 0 ;;
esac
[ "$FAIL_AP" != yes ] || exit 1
printf 'mode=AP\\nwpa_state=COMPLETED\\n'
''')
        self.executable('script/wifidhcp.sh', 'echo station-dhcp >> "$TEST_CALLS"\n')
        self.executable('script/bounded_log.sh', '#!/bin/sh\n:;\n')
        source = (SCRIPTS / 'hotspot.sh').read_text()
        source = source.replace('#!/tmp/sd/yi-hack/bin/busybox ash', '#!'+str(self.root / 'bin/busybox')+' ash',1)
        mocks = '''
ifconfig() { printf 'ifconfig %s\\n' "$*" >> "$TEST_CALLS"; }
killall() { printf 'killall %s\\n' "$*" >> "$TEST_CALLS"; }
sleep() { :; }
'''
        source = source.replace('case "$1" in\n    start)', mocks + '\ncase "$1" in\n    start)',1)
        self.script = self.root / 'script/hotspot.sh'
        self.script.write_text(source)
        self.script.chmod(0o755)
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), TEST_ROOT=str(self.root),
                        TEST_CALLS=str(self.calls), YI_HOTSPOT_RUNTIME=str(self.runtime),
                        YI_HOTSPOT_REQUEST=str(self.request), YI_HOTSPOT_PRIMARY=str(self.primary),
                        YI_HOTSPOT_WPA=str(self.root / 'wpa'), YI_HOTSPOT_WPA_CLI=str(self.root / 'wpa_cli'))

    def tearDown(self):
        for path in [self.runtime / 'wpa.pid', self.runtime / 'dhcp.pid']:
            if path.exists():
                pid = int(path.read_text())
                try: os.kill(pid, signal.SIGKILL)
                except ProcessLookupError: pass
        self.tmp.cleanup()

    def executable(self, path, content):
        p = self.root / path
        p.write_text(content)
        p.chmod(0o755)
        return p

    def call(self, action, **extra):
        return subprocess.run([BUSYBOX, 'ash', str(self.script), action], env=dict(self.env, **extra),
                              text=True, capture_output=True, timeout=8)

    def start(self):
        self.assertEqual(self.call('start').returncode, 0)
        result = self.call('apply')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_both_models_open_ap_and_return_preserve_primary(self):
        for model in ['y623', 'y28ga']:
            with self.subTest(model=model):
                (self.root / 'model_suffix').write_text(model+'\n')
                original = self.primary.read_bytes()
                self.start()
                self.assertEqual(self.call('status').stdout.strip(), 'active')
                before_scan = self.calls.read_text()
                self.assertEqual(self.call('scan').returncode, 0)
                self.assertEqual(self.calls.read_text(), before_scan)
                config = (self.runtime / 'wpa.conf').read_text()
                self.assertIn('mode=2\n', config)
                self.assertIn('key_mgmt=NONE\n', config)
                self.assertNotIn('psk=', config)
                encoded = next(line.strip()[5:] for line in config.splitlines() if line.strip().startswith('ssid='))
                self.assertEqual(bytes.fromhex(encoded).decode(), 'Camera "open" #name')
                self.assertNotIn('wlan0 down', self.calls.read_text())
                self.assertEqual(self.call('stop').returncode, 0)
                self.assertEqual(self.call('apply').returncode, 0)
                self.assertEqual(self.call('status').stdout.strip(), 'station')
                self.assertEqual(self.primary.read_bytes(), original)

    def test_ap_failure_rolls_back_without_erasing_station_credentials(self):
        original = self.primary.read_bytes()
        self.assertEqual(self.call('start').returncode, 0)
        result = self.call('apply', FAIL_AP='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.call('status').stdout.strip(), 'failed')
        self.assertIn('station-dhcp', self.calls.read_text())
        self.assertEqual(self.primary.read_bytes(), original)
        self.assertFalse((self.runtime / 'pending').exists())

    def test_diagnostic_log_failure_does_not_tear_down_a_working_ap(self):
        self.executable('script/bounded_log.sh', '#!/bin/sh\nexit 1\n')
        self.start()
        self.assertEqual(self.call('status').stdout.strip(), 'active')
        self.assertNotIn('station-dhcp', self.calls.read_text())

    def test_missing_prerequisite_does_not_touch_radio(self):
        result = self.call('start', YI_HOTSPOT_WPA=str(self.root / 'missing'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls.read_text(), '')
        self.assertFalse(self.request.exists())

    def test_failed_restart_preflight_keeps_existing_hotspot(self):
        self.start()
        self.request.write_text('start\n') # same request format as the button
        result = self.call('apply', YI_HOTSPOT_WPA=str(self.root / 'missing'))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.call('status').stdout.strip(), 'active')
        self.assertNotIn('station-dhcp', self.calls.read_text())

    def test_transition_contends_with_wifi_recovery(self):
        holder = subprocess.Popen([BUSYBOX,'ash','-c','yi_lock wifi-recovery; echo ready; read done'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline(), 'ready\n')
            self.assertEqual(self.call('start').returncode, 0)
            self.assertEqual(self.call('apply').returncode, 75)
            self.assertEqual(self.call('scan').returncode, 75)
            self.assertTrue(self.request.exists())
            self.assertEqual(self.calls.read_text(), '')
        finally:
            holder.kill(); holder.wait(); holder.stdin.close(); holder.stdout.close()
        self.assertEqual(self.call('apply').returncode, 0)

    def test_interrupted_rollback_is_resumed_before_original_start(self):
        (self.runtime / 'state').write_text('stopping\n')
        (self.runtime / 'pending').write_text('start\n')
        self.assertEqual(self.call('apply').returncode, 0)
        self.assertEqual(self.call('status').stdout.strip(), 'station')
        self.assertFalse((self.runtime / 'pending').exists())
        self.assertNotIn('killall', self.calls.read_text())

    def test_watchdog_does_not_attempt_station_recovery_during_ap(self):
        import re
        source = (SCRIPTS / 'wd.sh').read_text()
        function = re.search(r'^check_wifi\(\)\n\{.*?^\}', source, re.M | re.S).group()
        function = function.replace('/tmp/yi-hotspot/state', str(self.runtime / 'state'))
        for mode in ['starting', 'active', 'stopping']:
            with self.subTest(mode=mode):
                (self.runtime / 'state').write_text(mode+'\n')
                # Any fallthrough into ordinary station checks is a test failure.
                body = 'get_config() { exit 99; }; reboot() { exit 99; }; ' + function + '\ncheck_wifi'
                result = subprocess.run([BUSYBOX, 'ash', '-c', body], env=self.env, capture_output=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_unknown_firmware_cannot_enable_button_override(self):
        fake = self.root / 'dispatch'
        fake.write_text('unknown firmware')
        self.assertNotEqual(self.call('reset-supported', YI_HOTSPOT_DISPATCH=str(fake)).returncode, 0)

if __name__ == '__main__':
    unittest.main()
