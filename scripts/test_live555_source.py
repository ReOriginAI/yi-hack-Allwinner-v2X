#!/usr/bin/env python3
"""Verify the retained LIVE555 source and initialization failure behavior."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'src/rRTSPServer'
INIT = (MODULE / 'init.rRTSPServer').read_text()
ARCHIVE = re.search(r'^ARCHIVE=(.+)$', INIT, re.M).group(1)
SHA256 = re.search(r'^ARCHIVE_SHA256=(.+)$', INIT, re.M).group(1)

class Live555SourceTests(unittest.TestCase):
    def test_bundled_source_version_and_patch_compatibility(self):
        archive = MODULE / 'vendor' / ARCHIVE
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), SHA256)
        with tempfile.TemporaryDirectory(prefix='live555-source-') as temp:
            with tarfile.open(archive) as source:
                # Upstream includes absolute symlinks to demo media. Those
                # assets are not source code and are unnecessary for building.
                members=[member for member in source if member.isfile() or member.isdir()]
                source.extractall(temp, members=members, filter='data')
            version = Path(temp, 'live/liveMedia/include/liveMedia_version.hh').read_text()
            self.assertIn('"2026.09.23"', version)
            self.assertTrue(list(Path(temp, 'live').rglob('COPYING*')))
            for patch in ('rRTSPServer.patch', 'friend.patch', 'capture-clock.patch'):
                subprocess.run(['patch', '--batch', '-p0', '-i', str(MODULE / patch)],
                               cwd=temp, check=True, capture_output=True)
            subprocess.run(['sh', './genMakefiles', 'linux-cross'],
                           cwd=Path(temp, 'live'), check=True, capture_output=True)
            self.assertIn('YI_SHARED_CAPTURE_CLOCK', Path(temp, 'live/liveMedia/Makefile').read_text())

    def test_invalid_source_fails_before_network_or_cleanup(self):
        for source in (None, b'corrupted archive'):
            with self.subTest(source=source), tempfile.TemporaryDirectory(prefix='live555-invalid-') as temp:
                root = Path(temp); script = root / 'init.rRTSPServer'
                script.write_text(INIT)
                (root / 'vendor').mkdir()
                if source is not None:
                    (root / 'vendor' / ARCHIVE).write_bytes(source)
                for name in ('live', '_install', 'libhelix-aac'):
                    (root / name).mkdir(); (root / name / 'sentinel').write_text('keep')
                (root / 'bin').mkdir()
                wget = root / 'bin/wget'
                wget.write_text('#!/bin/sh\ntouch "$TEST_NETWORK_MARKER"\nexit 99\n')
                wget.chmod(0o755)
                marker = root / 'network-called'
                result = subprocess.run(['bash', str(script)], capture_output=True, text=True,
                                        env={**os.environ, 'PATH':str(root / 'bin')+':'+os.environ['PATH'],
                                             'TEST_NETWORK_MARKER':str(marker)})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
                for name in ('live', '_install', 'libhelix-aac'):
                    self.assertEqual((root / name / 'sentinel').read_text(), 'keep')

if __name__ == '__main__':
    unittest.main()
