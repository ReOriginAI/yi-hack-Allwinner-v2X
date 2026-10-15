#!/usr/bin/env python3
"""Software checks for native IVA masks; no camera access or vendor SDK needed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'src/ipc_cmd/ipc_cmd'

class NativeIvaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='motion-iva-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.control = self.root / 'control'
        self.exe = self.root / 'motion_ivactl'
        subprocess.run(['gcc', '-O2', '-Wall', '-Wextra', '-Werror',
                        f'-DMOTION_IVA_PATH="{self.control}"', str(SOURCE / 'motion_ivactl.c'),
                        '-o', str(self.exe)], check=True, capture_output=True)

    def test_native_counter_filter_and_fail_open(self):
        binary = self.root / 'filter'
        subprocess.run(['gcc', '-O2', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'src/motiond/tests/test_iva_mask.c'), '-ldl', '-o', str(binary)],
                       check=True, capture_output=True)
        subprocess.run([str(binary)], check=True,
                       env={k:v for k,v in os.environ.items() if k != 'YI_NIGHTVISION_MODEL'})

    def test_control_validation_and_atomic_settings(self):
        def run(*args):
            return subprocess.run([str(self.exe), *args], capture_output=True, text=True)
        self.assertEqual(json.loads(run('--status').stdout), None)
        cells = ('1'*10+'0'*10)*12
        self.assertEqual(run('--init', 'yes', cells).returncode, 0)
        before = self.control.read_bytes()
        status = json.loads(run('--status').stdout)
        self.assertTrue(status['enabled'])
        self.assertFalse(status['ready'])
        self.assertTrue(status['fallback'])
        self.assertTrue(status['pending'])
        for invalid in ('', '1'*239, '1'*240+'0', 'x'+'0'*239):
            self.assertEqual(run('--set', 'yes', invalid).returncode, 2)
        self.assertEqual(run('--set', 'on', '0'*240).returncode, 2)
        # Status changes only the reader heartbeat, not saved settings.
        self.assertEqual(before[24:268], self.control.read_bytes()[24:268])
        self.assertEqual(run('--set', 'no', '0'*240).returncode, 0)
        self.assertFalse(json.loads(run('--status').stdout)['enabled'])
        generation = int.from_bytes(self.control.read_bytes()[8:12], 'little')
        self.assertEqual(run('--set', 'no', '0'*240).returncode, 0)
        self.assertEqual(generation, int.from_bytes(self.control.read_bytes()[8:12], 'little'))
        # A runtime writer cannot steal a concurrent writer's lock. Boot
        # initialization without a live owner can recover an interrupted one.
        data = bytearray(self.control.read_bytes()); data[8:12] = (generation+1).to_bytes(4,'little')
        self.control.write_bytes(data)
        self.assertEqual(run('--set', 'yes', cells).returncode, 1)
        self.assertEqual(run('--init', 'yes', cells).returncode, 0)
        self.assertEqual(int.from_bytes(self.control.read_bytes()[8:12], 'little') % 2, 0)

    def test_control_rejects_unrecognized_files_and_symlinks(self):
        self.control.write_bytes(b'unknown')
        self.assertEqual(subprocess.run([str(self.exe),'--init','no','0'*240], capture_output=True).returncode, 1)
        self.assertEqual(self.control.read_bytes(), b'unknown')
        self.control.unlink()
        target = self.root / 'target';target.write_bytes(b'protected')
        self.control.symlink_to(target)
        self.assertEqual(subprocess.run([str(self.exe),'--init','no','0'*240], capture_output=True).returncode, 1)
        self.assertEqual(target.read_bytes(), b'protected')

if __name__ == '__main__':
    unittest.main()
