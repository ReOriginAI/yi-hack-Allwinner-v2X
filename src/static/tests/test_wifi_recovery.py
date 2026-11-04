#!/usr/bin/env python3
"""Outage policy, maintenance handoff and stale address checks, with fake radios."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'src/static/static/yi-hack/script'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')

class WifiRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for d in ['bin', 'script', 'etc', 'runtime']: (self.root / d).mkdir()
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), TEST_ROOT=str(self.root),
                        PATH=str(self.root / 'bin')+':'+os.environ['PATH'])
        (self.root / 'bin/busybox').symlink_to(shutil.which(BUSYBOX))
        subprocess.run(['cc', str(ROOT / 'src/service_guard/service_guard.c'),
                        '-o', str(self.root / 'bin/service_guard')], check=True)
        self.mapping = {
            '/tmp/yi-hotspot': str(self.root / 'runtime'),
            '/tmp/wifi_maintenance_active': str(self.root / 'maintenance'),
            '/tmp/wpa_supplicant': str(self.root / 'wpa_supplicant'),
            '/tmp/sd/hack_wififailsafe.log': str(self.root / 'wifi.log'),
            '/tmp/local-only/vendor-wificonnect.sh': str(self.root / 'vendor-connect'),
            '/home/base/tools/wpa_cli': str(self.root / 'bin/wpa_cli'),
            '/backup/tools/wpa_supplicant': str(self.root / 'bin/wpa'),
            '/home/base/tools/wpa_supplicant': str(self.root / 'missing-wpa'),
            '/backup/tools/default.script': str(self.root / 'dhcp-hook'),
            '/dev/mtdblock7': str(self.root / 'wifi-mtd'),
            '/proc/uptime': str(self.root / 'uptime'),
            '/sys/class/net/wlan0/carrier': str(self.root / 'carrier')}
        for name in ['wifi_failover.sh', 'wifi_recovery.sh', 'service_lock.sh']:
            text = self.translate((SCRIPTS / name).read_text())
            text = text.replace('#!/tmp/sd/yi-hack/bin/busybox ash', '#!'+str(self.root / 'bin/busybox')+' ash')
            self.executable('script/'+name, text)
        self.executable('script/wifidhcp.sh', '#!/bin/sh\necho primary-dhcp >> "$TEST_ROOT/calls"\n')
        self.executable('script/hotspot.sh', '#!/bin/sh\necho "hotspot:$1" >> "$TEST_ROOT/calls"\n')
        self.executable('bin/wpa_cli', '#!/bin/sh\necho "wpa_state=${TEST_ASSOC:-DISCONNECTED}"\n')
        self.executable('bin/ifconfig', '#!/bin/sh\nif [ "$#" -gt 1 ]; then echo "ifconfig:$*" >> "$TEST_ROOT/calls"; exit 0; fi\n[ "$TEST_NO_IP" = yes ] || echo "inet addr:192.168.1.112"\n')
        self.executable('bin/iwconfig', '#!/bin/sh\necho "ESSID:\\"${TEST_SSID:-Router}\\""\n')
        for name in ['killall', 'udhcpc', 'wpa', 'reboot']:
            self.executable('bin/'+name, '#!/bin/sh\necho '+name+' >> "$TEST_ROOT/calls"\nexit "${TEST_START_STATUS:-0}"\n')
        (self.root / 'wifi-mtd').write_bytes(bytes(28)+b'Router'+bytes(58))
        (self.root / 'dhcp-hook').touch()
        (self.root / 'carrier').write_text('1\n')
        (self.root / 'uptime').write_text('200.5 0\n')
        self.conf = self.root / 'etc/system.conf'
        self.conf.write_text('WIFI_MAINTENANCE_GRACE=30\nWIFI_MAINTENANCE_SSID=Repair\nWIFI_MAINTENANCE_PASSWORD=repair-password\n')
        self.calls = self.root / 'calls'
        source = (SCRIPTS / 'wd.sh').read_text()
        functions = '\n'.join(re.search('^'+name+r'\(\)\n\{.*?^\}', source, re.M | re.S).group()
                              for name in ['soft_wifi_reconnect', 'wifi_station_connected', 'check_wifi'])
        self.functions = self.translate(functions)

    def translate(self, text):
        for a, b in self.mapping.items(): text = text.replace(a, b)
        return text

    def executable(self, name, text):
        p = self.root / name; p.write_text(text); p.chmod(0o755)

    def worker(self, name, *args, **env):
        return subprocess.run([BUSYBOX, 'ash', str(self.root / 'script' / name), *args],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=6)

    def watchdog(self, setup='', **env):
        body = '''
get_config() { sed -n "s/^$1=//p" "$YI_HACK_PREFIX/etc/system.conf"; }
WIFI_FAILSAFE_COUNTER=5
WIFI_FAILSAFE_STARTED=1
WIFI_MAINTENANCE_FAILSAFE_COUNTER=0
INTERVAL=10
''' + self.functions + '\n' + setup + '\ncheck_wifi\nwait\n'
        r = subprocess.run([BUSYBOX, 'ash', '-c', body], env=dict(self.env, **env),
                           capture_output=True, text=True, timeout=6)
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def mode(self, value):
        with self.conf.open('a') as f: f.write('WIFI_RECOVERY_MODE='+value+'\n')

    def test_default_and_explicit_hotspot_recover_after_outage(self):
        self.assertEqual(self.watchdog(), ['hotspot:recover'])
        self.calls.unlink(); self.mode('hotspot')
        self.assertEqual(self.watchdog(), ['hotspot:recover'])

    def test_grace_retries_primary_then_selects_maintenance_only(self):
        self.mode('maintenance')
        self.assertEqual(self.watchdog(setup='WIFI_FAILSAFE_STARTED=190'), ['primary-dhcp'])
        self.calls.unlink()
        calls = self.watchdog()
        self.assertIn('wpa', calls)
        self.assertIn('udhcpc', calls)
        self.assertIn('ifconfig:wlan0 0.0.0.0', calls)
        self.assertFalse(any('wlan0 down' in call for call in calls))
        self.assertNotIn('hotspot:recover', calls)
        self.assertEqual((self.root / 'maintenance').read_text().strip(), 'maintenance_pending')
        self.calls.unlink()
        self.assertEqual(self.worker('wifi_recovery.sh').returncode, 75)
        self.assertFalse(self.calls.exists())

    def test_stale_ip_does_not_mask_lost_association_or_wrong_ssid(self):
        for env in [dict(TEST_ASSOC='DISCONNECTED'), dict(TEST_ASSOC='COMPLETED', TEST_NO_IP='yes'),
                    dict(TEST_ASSOC='COMPLETED', TEST_SSID='Other')]:
            with self.subTest(env=env):
                self.calls.unlink(missing_ok=True)
                self.assertEqual(self.watchdog(**env), ['hotspot:recover'])
        self.calls.unlink()
        self.assertEqual(self.watchdog(TEST_ASSOC='COMPLETED'), [])

    def test_manual_requests_and_active_transitions_suppress_fallback(self):
        for state in ['starting', 'active', 'stopping']:
            (self.root / 'runtime/state').write_text(state)
            self.assertEqual(self.watchdog(), [])
        (self.root / 'runtime/state').unlink()
        (self.root / 'runtime.request').write_text('stop\n')
        self.assertEqual(self.watchdog(), [])
        self.mode('maintenance')
        self.assertEqual(self.worker('wifi_failover.sh').returncode, 75)

    def test_primary_launcher_uses_original_under_owned_radio_lock(self):
        self.executable('bin/ps', '#!/bin/sh\nexit 0\n')
        self.executable('vendor-connect', '#!/bin/sh\necho original-primary-launch >> "$TEST_ROOT/calls"\n')
        (self.root / 'wpa_supplicant.conf').write_text('network={}\n')
        self.assertEqual(self.worker('wifi_recovery.sh').returncode, 0)
        self.assertEqual(self.calls.read_text().splitlines(), ['original-primary-launch', 'primary-dhcp'])

    def test_switching_mode_does_not_strand_existing_maintenance_connection(self):
        self.mode('hotspot')
        (self.root / 'maintenance').write_text('maintenance\n')
        self.assertEqual(self.watchdog(TEST_ASSOC='COMPLETED', TEST_SSID='Repair'), [])
        self.assertEqual(self.watchdog(), ['hotspot:recover'])

    def test_failed_maintenance_is_retried_and_reboot_rechecks_state(self):
        self.mode('maintenance')
        (self.root / 'maintenance').write_text('maintenance_pending\n')
        self.assertIn('wpa', self.watchdog())
        self.calls.unlink()
        self.assertEqual(self.watchdog(setup='WIFI_MAINTENANCE_FAILSAFE_COUNTER=5'), ['reboot'])
        self.calls.unlink()
        (self.root / 'runtime.request').write_text('start-open\n')
        self.assertEqual(self.worker('wifi_failover.sh', 'reboot').returncode, 75)
        self.assertFalse(self.calls.exists())

if __name__ == '__main__': unittest.main()
