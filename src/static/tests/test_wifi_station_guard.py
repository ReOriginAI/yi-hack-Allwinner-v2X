#!/usr/bin/env python3
"""Serialize vendor station work with AP/maintenance workers, without networking."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'src/static/static/yi-hack/script'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')

class WifiStationGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ['bin', 'script']: (self.root / name).mkdir()
        (self.root / 'bin/busybox').symlink_to(shutil.which(BUSYBOX))
        shutil.copy2(SCRIPTS / 'service_lock.sh', self.root / 'script/service_lock.sh')
        subprocess.run(['cc', str(ROOT / 'src/service_guard/service_guard.c'), '-o',
                        str(self.root / 'bin/service_guard')], check=True)
        self.state, self.calls = self.root / 'state', self.root / 'calls'
        self.maintenance = self.root / 'maintenance'
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), CALLS=str(self.calls))
        for role in ('wificonnect.sh', 'killwifi.sh', 'wifidhcp.sh'):
            (self.root / role).write_text((SCRIPTS / 'wifi_station_guard.sh').read_text()
                .replace('/tmp/yi-hotspot/state', str(self.state))
                .replace('/tmp/yi-hotspot.request', str(self.root / 'request'))
                .replace('/tmp/yi-hotspot/pending', str(self.root / 'pending'))
                .replace('/tmp/wifi_maintenance_active', str(self.maintenance))
                .replace('/tmp/local-only/vendor-', str(self.root / 'vendor-')))
            (self.root / ('vendor-' + role)).write_text('#!/bin/sh\nprintf "%s\\n" "$#" "$1" "$2" >> "$CALLS"\nexit 7\n')

    def call(self, role):
        return subprocess.run([BUSYBOX, 'ash', str(self.root / role), 'argument one', '*'],
                              env=self.env, capture_output=True, timeout=4)

    def test_all_vendor_roles_are_blocked_during_ap_or_maintenance(self):
        for role in ('wificonnect.sh', 'killwifi.sh', 'wifidhcp.sh'):
            for phase in ('starting', 'active', 'stopping'):
                self.state.write_text(phase)
                self.assertEqual(self.call(role).returncode, 0)
                self.assertFalse(self.calls.exists())
            for phase in ('station', 'failed', ''):
                self.state.write_text(phase)
                self.assertEqual(self.call(role).returncode, 7)
                self.assertEqual(self.calls.read_text().splitlines(), ['2', 'argument one', '*'])
                self.calls.unlink()
            self.state.unlink()
            self.assertEqual(self.call(role).returncode, 7)
            self.calls.unlink()
            self.maintenance.write_text('maintenance_pending\n')
            self.assertEqual(self.call(role).returncode, 0)
            self.assertFalse(self.calls.exists())
            self.maintenance.unlink()

    def test_queued_manual_transition_blocks_vendor_before_state_changes(self):
        (self.root / 'request').write_text('start-open\n')
        self.assertEqual(self.call('killwifi.sh').returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_stalled_vendor_child_times_out_and_releases_radio(self):
        wrapper = self.root / 'wificonnect.sh'
        wrapper.write_text(wrapper.read_text().replace('service_guard" 25', 'service_guard" 1'))
        (self.root / 'vendor-wificonnect.sh').write_text('trap "" TERM\nsleep 30\n')
        self.assertEqual(self.call('wificonnect.sh').returncode, 124)
        self.assertEqual(self.call('killwifi.sh').returncode, 7)

    def test_vendor_cannot_enter_after_transition_acquires_radio(self):
        holder = subprocess.Popen([BUSYBOX, 'ash', '-c', 'yi_lock wifi-recovery; echo ready; read done'],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(holder.stdout.readline(), 'ready\n')
            self.assertEqual(self.call('wificonnect.sh').returncode, 75)
            self.assertFalse(self.calls.exists())
        finally:
            holder.kill(); holder.wait(); holder.stdin.close(); holder.stdout.close()
        self.assertEqual(self.call('wificonnect.sh').returncode, 7)

    def test_vendor_child_retains_ownership_and_kill_releases_it(self):
        (self.root / 'vendor-wificonnect.sh').write_text('echo ready; read done\n')
        worker = subprocess.Popen([BUSYBOX, 'ash', str(self.root / 'wificonnect.sh')],
                                  env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(worker.stdout.readline(), 'ready\n')
            self.assertEqual(self.call('killwifi.sh').returncode, 75)
            worker.stdin.write('done\n'); worker.stdin.flush()
            worker.wait(timeout=3)
            self.assertEqual(self.call('killwifi.sh').returncode, 7)
        finally:
            if worker.poll() is None: worker.kill(); worker.wait()
            worker.stdin.close(); worker.stdout.close()

if __name__ == '__main__': unittest.main()
