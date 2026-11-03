#!/usr/bin/env python3
"""Vendor recovery must not steal the hotspot radio; normal args pass through."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'static/yi-hack/script/wifi_station_guard.sh'

class WifiStationGuardTests(unittest.TestCase):
    def test_all_vendor_roles_are_blocked_during_ap_transitions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state, calls = root / 'state', root / 'calls'
            for role in ('wificonnect.sh', 'killwifi.sh', 'wifidhcp.sh'):
                wrapper = root / role
                wrapper.write_text(SOURCE.read_text().replace('/tmp/yi-hotspot/state', str(state))
                                   .replace('/tmp/local-only/vendor-', str(root / 'vendor-')))
                original = root / ('vendor-' + role)
                original.write_text('#!/bin/sh\nprintf "%s\\n" "$#" "$1" "$2" >> "$CALLS"\nexit 7\n')
                for phase in ('starting', 'active', 'stopping'):
                    state.write_text(phase)
                    result = subprocess.run(['sh', str(wrapper), 'argument one', '*'], env=dict(os.environ, CALLS=str(calls)))
                    self.assertEqual(result.returncode, 0)
                    self.assertFalse(calls.exists())
                for phase in ('station', 'failed', ''):
                    state.write_text(phase)
                    result = subprocess.run(['sh', str(wrapper), 'argument one', '*'], env=dict(os.environ, CALLS=str(calls)))
                    self.assertEqual(result.returncode, 7)
                    self.assertEqual(calls.read_text().splitlines(), ['2', 'argument one', '*'])
                    calls.unlink()
                state.unlink()
                result = subprocess.run(['sh', str(wrapper), 'argument one', '*'], env=dict(os.environ, CALLS=str(calls)))
                self.assertEqual(result.returncode, 7)
                calls.unlink()

if __name__ == '__main__':
    unittest.main()
