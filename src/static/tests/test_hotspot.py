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
config=next((a[2:] for a in args if a.startswith('-c')),args[-1])
with open(os.environ['TEST_CALLS'],'a') as f:f.write('wpa '+config+'\\n')
if config.endswith('/hostapd.conf'):
    child=subprocess.Popen(['python3',os.environ['TEST_ROOT']+'/daemon.py','-c'+config],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    pathlib.Path(os.environ['TEST_ROOT']+'/runtime/wpa.pid').write_text(str(child.pid))
''')
        self.executable('wpa_cli', '''#!/bin/sh
case "$*" in
 *terminate) exit 0 ;;
esac
[ "$FAIL_AP" != yes ] || exit 1
printf 'state=ENABLED\\n'
''')
        self.executable('bin/iwconfig', '#!/bin/sh\nif [ "$FAIL_RADIO" = yes ]; then echo Mode:Managed; else echo Mode:Master; fi\n')
        self.executable('script/wifidhcp.sh', 'echo station-dhcp >> "$TEST_CALLS"\n')
        self.executable('script/bounded_log.sh', '#!/bin/sh\n:;\n')
        source = (SCRIPTS / 'hotspot.sh').read_text()
        source = source.replace('#!/tmp/sd/yi-hack/bin/busybox ash', '#!'+str(self.root / 'bin/busybox')+' ash',1)
        source = source.replace('/tmp/wifi_maintenance_active', str(self.root / 'maintenance'))
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
                        TEST_CALLS=str(self.calls), PATH=str(self.root / "bin")+":"+os.environ["PATH"], YI_HOTSPOT_RUNTIME=str(self.runtime),
                        YI_HOTSPOT_REQUEST=str(self.request), YI_HOTSPOT_PRIMARY=str(self.primary),
                        YI_HOTSPOT_WPA=str(self.root / 'wpa'), YI_HOTSPOT_AP=str(self.root / 'wpa'), YI_HOTSPOT_AP_CLI=str(self.root / 'wpa_cli'), YI_HOTSPOT_WPA_CLI=str(self.root / 'wpa_cli'))

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
                self.assertEqual(self.call('apply').returncode, 0)
                self.assertEqual(self.calls.read_text(), before_scan)
                config = (self.runtime / 'hostapd.conf').read_text()
                self.assertIn('interface=wlan0\n', config)
                self.assertIn('wpa=0\n', config)
                self.assertNotIn('wpa_passphrase=', config)
                encoded = next(line.strip()[6:] for line in config.splitlines() if line.strip().startswith('ssid2='))
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

    def test_station_takeover_is_detected_despite_live_ap_daemons(self):
        self.start()
        original = self.primary.read_bytes()
        result = self.call('apply', FAIL_RADIO='yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.call('status').stdout.strip(), 'station')
        self.assertIn('station-dhcp', self.calls.read_text())
        self.assertEqual(self.primary.read_bytes(), original)

    def test_enabled_controller_without_master_radio_is_not_ready(self):
        self.assertEqual(self.call('start').returncode, 0)
        result = self.call('apply', FAIL_RADIO='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.call('status').stdout.strip(), 'failed')
        self.assertIn('station-dhcp', self.calls.read_text())

    def test_password_ap_and_button_clear_on_both_models(self):
        for model in ['y623', 'y28ga']:
            with self.subTest(model=model):
                (self.root / 'model_suffix').write_text(model+'\n')
                password = 'safe"pass\\word'
                with self.config.open('a') as conf:
                    conf.write('WIFI_HOTSPOT_PASSWORD='+password+'\n')
                original = self.primary.read_bytes()
                self.start()
                config = (self.runtime / 'hostapd.conf').read_text()
                self.assertIn('wpa_key_mgmt=WPA-PSK\n', config)
                self.assertIn('wpa=2\n', config)
                self.assertIn('wpa_passphrase='+password, config)
                self.assertEqual((self.runtime / 'hostapd.conf').stat().st_mode & 0o777, 0o600)
                self.request.write_text('start-open\n')
                self.assertEqual(self.call('apply').returncode, 0)
                self.assertNotIn(password, self.config.read_text())
                self.assertIn('wpa=0', (self.runtime / 'hostapd.conf').read_text())
                self.assertEqual(self.primary.read_bytes(), original)
                self.assertEqual(self.call('start').returncode, 0)
                self.assertEqual(self.call('apply').returncode, 0)
                self.assertNotIn('wpa_passphrase=', (self.runtime / 'hostapd.conf').read_text())

    def test_invalid_saved_password_does_not_touch_radio_and_button_recovers(self):
        with self.config.open('a') as conf:
            conf.write('WIFI_HOTSPOT_PASSWORD=short\n')
        self.assertNotEqual(self.call('start').returncode, 0)
        self.assertEqual(self.calls.read_text(), '')
        self.request.write_text('start-open\n')
        self.assertEqual(self.call('apply').returncode, 0)
        self.assertIn('wpa=0', (self.runtime / 'hostapd.conf').read_text())

    def test_first_boot_only_opens_without_saved_router_key_or_config(self):
        mtd = self.root / 'wifi-mtd'
        cfg = self.root / 'configure_wifi.cfg'
        for key, provision, expected in [(b'\0'*64,False,True), (b'\xff'*64,False,True),
                                          (b'routerpassword'.ljust(64,b'\0'),False,False),
                                          (b'\0'*64,True,False), (b'',False,False)]:
            with self.subTest(key=key, provision=provision):
                mtd.write_bytes(b'\0'*92+key)
                if provision:cfg.write_text('wifi_ssid=router\nwifi_psk=password\n')
                elif cfg.exists():cfg.unlink()
                self.request.unlink(missing_ok=True)
                result=self.call('boot',YI_HOTSPOT_WIFI_MTD=str(mtd),YI_HOTSPOT_WIFI_CONFIG=str(cfg))
                self.assertEqual(result.returncode,0)
                self.assertEqual(self.request.exists(),expected)
                if expected:self.assertEqual(self.request.read_text(),'start-open\n')

    def test_explicit_hotspot_password_survives_unprovisioned_boot(self):
        mtd = self.root / 'unprovisioned'
        mtd.write_bytes(bytes(256))
        for boot in ('yes', 'no'):
            with self.subTest(boot=boot):
                self.config.write_text('WIFI_HOTSPOT_BOOT='+boot+'\nWIFI_HOTSPOT_SSID=Configured AP\nWIFI_HOTSPOT_PASSWORD=chosen-password\n')
                self.assertEqual(self.call('boot', YI_HOTSPOT_WIFI_MTD=str(mtd),
                    YI_HOTSPOT_WIFI_CONFIG=str(self.root / 'absent.cfg')).returncode, 0)
                self.assertEqual(self.request.read_text(), 'start\n')
                self.assertEqual(self.call('apply').returncode, 0)
                self.assertIn('wpa_passphrase=chosen-password', (self.runtime / 'hostapd.conf').read_text())
                self.assertIn('WIFI_HOTSPOT_PASSWORD=chosen-password', self.config.read_text())
                self.assertEqual(self.call('stop').returncode, 0)
                self.assertEqual(self.call('apply').returncode, 0)

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
        self.assertNotIn('/hostapd.conf', self.calls.read_text())
        self.assertIn(str(self.primary), self.calls.read_text())

    def test_watchdog_does_not_attempt_station_recovery_during_ap(self):
        import re
        source = (SCRIPTS / 'wd.sh').read_text()
        function = re.search(r'^check_wifi\(\)\n\{.*?^\}', source, re.M | re.S).group()
        function = function.replace('/tmp/yi-hotspot/state', str(self.runtime / 'state'))
        for mode in ['starting', 'active', 'stopping']:
            with self.subTest(mode=mode):
                (self.runtime / 'state').write_text(mode+'\n')
                # Any fallthrough into ordinary station checks is a test failure.
                body = 'publish_reset_ready() { :; }; get_config() { exit 99; }; reboot() { exit 99; }; ' + function + '\ncheck_wifi'
                result = subprocess.run([BUSYBOX, 'ash', '-c', body], env=self.env, capture_output=True, timeout=3)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_automatic_recovery_uses_saved_password_on_both_models(self):
        for model in ['y623', 'y28ga']:
            with self.subTest(model=model):
                (self.root / 'model_suffix').write_text(model+'\n')
                self.config.write_text('WIFI_RECOVERY_MODE=hotspot\nWIFI_HOTSPOT_PASSWORD=recovery-password\n')
                self.assertEqual(self.call('recover').returncode, 0)
                self.assertEqual(self.call('status').stdout.strip(), 'active')
                self.assertIn('wpa_passphrase=recovery-password', (self.runtime / 'hostapd.conf').read_text())
                self.call('stop'); self.assertEqual(self.call('apply').returncode, 0)

    def test_automatic_recovery_never_overwrites_manual_requests(self):
        for action in ['stop', 'start-open']:
            with self.subTest(action=action):
                self.request.write_text(action+'\n')
                self.assertEqual(self.call('recover').returncode, 75)
                self.assertEqual(self.request.read_text(), action+'\n')
                self.assertEqual(self.calls.read_text(), '')
        self.request.unlink()
        with self.config.open('a') as conf: conf.write('WIFI_RECOVERY_MODE=maintenance\n')
        self.assertEqual(self.call('recover').returncode, 75)
        self.assertFalse(self.request.exists())

    def test_timed_out_start_is_rolled_back_before_replaying_it(self):
        (self.runtime / 'state').write_text('starting\n')
        (self.runtime / 'pending').write_text('start\n')
        self.assertEqual(self.call('apply').returncode, 0)
        self.assertEqual(self.call('status').stdout.strip(), 'station')
        self.assertIn(str(self.primary), self.calls.read_text())
        self.assertFalse((self.runtime / 'pending').exists())

    def test_manual_stop_during_automatic_start_is_kept_for_next_poll(self):
        # Pause the daemon launch while the transition owns wifi-recovery.
        original = (self.root / 'wpa').read_text()
        (self.root / 'wpa').write_text(original.replace("args=sys.argv[1:]", """import time
pathlib.Path(os.environ['TEST_ROOT']+'/launching').touch()
while not pathlib.Path(os.environ['TEST_ROOT']+'/continue').exists(): time.sleep(.01)
args=sys.argv[1:]"""))
        worker = subprocess.Popen([BUSYBOX, 'ash', str(self.script), 'recover'], env=self.env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic()+3
            while not (self.root / 'launching').exists() and time.monotonic() < deadline: time.sleep(.01)
            self.assertTrue((self.root / 'launching').exists())
            self.assertEqual(self.call('stop').returncode, 0)
            self.assertEqual(self.call('apply').returncode, 75)
            (self.root / 'continue').touch()
            _, err = worker.communicate(timeout=4)
            self.assertEqual(worker.returncode, 0, err)
            self.assertEqual(self.request.read_text(), 'stop\n')
            self.assertEqual(self.call('apply').returncode, 0)
            self.assertEqual(self.call('status').stdout.strip(), 'station')
        finally:
            if worker.poll() is None: worker.kill(); worker.wait()
            worker.stdout.close(); worker.stderr.close()

    def test_return_to_primary_clears_maintenance_and_restarts_correct_profile(self):
        (self.runtime / 'state').write_text('station\n')
        (self.root / 'maintenance').write_text('maintenance\n')
        self.assertEqual(self.call('stop').returncode, 0)
        self.assertEqual(self.call('apply').returncode, 0)
        self.assertFalse((self.root / 'maintenance').exists())
        self.assertIn('wpa '+str(self.primary), self.calls.read_text())
        self.assertEqual(self.call('status').stdout.strip(), 'station')

    def test_unknown_firmware_cannot_enable_button_override(self):
        fake = self.root / 'dispatch'
        fake.write_text('unknown firmware')
        self.assertNotEqual(self.call('reset-supported', YI_HOTSPOT_DISPATCH=str(fake)).returncode, 0)

if __name__ == '__main__':
    unittest.main()
