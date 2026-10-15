#!/usr/bin/env python3
"""Check the two-model repository scope and recovery cleanup boundaries."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SUPPORTED = {'y623', 'y28ga'}

class ModelScopeTests(unittest.TestCase):
    def test_model_trees_and_packaging_allowlist(self):
        for category in ('sysroot', 'sdhack', 'unbrick'):
            self.assertEqual({p.name for p in (ROOT/category).iterdir() if p.is_dir()}, SUPPORTED)
        result = subprocess.check_output(['bash','-c',
            'source "$1"; print_cameras_list','test',str(ROOT/'scripts/common.sh')], text=True)
        self.assertEqual(set(result.splitlines()), SUPPORTED)
        for model in ('y623','y28ga','y21ga','h51ga','unknown'):
            result = subprocess.run(['bash','-c','source "$1"; get_camera_id "$2"',
                'test',str(ROOT/'scripts/common.sh'),model], capture_output=True, text=True)
            self.assertEqual(result.returncode==0, model in SUPPORTED)
            if model in SUPPORTED:self.assertEqual(result.stdout.strip(), model)
        for model in SUPPORTED:
            self.assertTrue((ROOT/'sysroot'/model/'lower_half_init.sh').is_file())
            self.assertTrue((ROOT/'sdhack'/model/'Factory/config.sh').is_file())
            self.assertTrue((ROOT/'unbrick'/model/'mtd.txt').is_file())

    def test_recovery_build_and_clean_leave_other_directories_untouched(self):
        with tempfile.TemporaryDirectory(prefix='two-model-recovery-') as temporary:
            root=Path(temporary)
            for name in ('build.sh','clean.sh'):
                shutil.copy2(ROOT/'unbrick'/name,root/name)
            for model in (*SUPPORTED,'unrelated-backup'):
                directory=root/model;directory.mkdir()
                (directory/'filename').write_text(model+'\n')
                (directory/'mtdblock2.bin').write_bytes(b'fixture partition')
            foreign=root/'unrelated-backup'
            (foreign/'rootfs_unrelated-backup.gz').write_bytes(b'keep recovery data')
            tools=root/'bin';tools.mkdir()
            mkimage=tools/'mkimage'
            mkimage.write_text('#!/bin/sh\nfor argument do output=$argument; done\n'
                               'printf "fixture image" > "$output"\n')
            mkimage.chmod(0o755)
            env={**os.environ,'PATH':str(tools)+':'+os.environ['PATH']}
            subprocess.run(['bash','build.sh','factory'],cwd=root,env=env,
                           check=True,capture_output=True)
            for model in SUPPORTED:self.assertTrue((root/model/f'rootfs_{model}.gz').is_file())
            self.assertEqual((foreign/'rootfs_unrelated-backup.gz').read_bytes(),b'keep recovery data')
            subprocess.run(['bash','clean.sh'],cwd=root,env=env,check=True,capture_output=True)
            for model in SUPPORTED:self.assertFalse((root/model/f'rootfs_{model}.gz').exists())
            self.assertEqual((foreign/'rootfs_unrelated-backup.gz').read_bytes(),b'keep recovery data')
            self.assertEqual((foreign/'mtdblock2.bin').read_bytes(),b'fixture partition')

if __name__ == '__main__':
    unittest.main()
