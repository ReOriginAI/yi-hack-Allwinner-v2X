#!/usr/bin/env python3
"""Exercise corrupted caches, download failure recovery and Makefile failure propagation."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fetch_snapshot_source as source

ROOT = Path(__file__).resolve().parents[1]
MAKEFILE = ROOT / 'src/snapshot/snapshot/Makefile'


class SnapshotSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='snapshot-source-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.destination = self.root / 'SDK/archive.tar'
        self.data = b'verified source fixture'
        self.hash = hashlib.sha256(self.data).hexdigest()
        self.archives = [{'sha256': self.hash, 'urls': ['https://primary/source', 'https://fallback/source']}]

    def assert_clean(self):
        self.assertFalse(list(self.destination.parent.glob('*.part')))

    def test_verified_cache_does_not_require_network(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(self.data)
        with patch.object(source.subprocess, 'run') as download:
            source.fetch(self.destination, self.archives)
        download.assert_not_called()

    def test_failed_partial_download_falls_back_and_replaces_corrupt_cache_atomically(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(b'old truncated archive')
        calls = []

        def download(command, check, timeout):
            self.assertTrue(check)
            self.assertEqual(timeout, 90)
            self.assertIn('--timeout=20', command)
            path = Path(command[command.index('-O') + 1])
            calls.append(command[-1])
            self.assertEqual(self.destination.read_bytes(), b'old truncated archive')
            if len(calls) == 1:
                path.write_bytes(b'incomplete')
                raise subprocess.TimeoutExpired(command, timeout)
            path.write_bytes(self.data)

        with patch.object(source.subprocess, 'run', side_effect=download):
            source.fetch(self.destination, self.archives)
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.destination.read_bytes(), self.data)
        self.assert_clean()

    def test_wrong_checksum_falls_back_to_alternative_archive_hash(self):
        alternate = b'official release archive'
        archives = [self.archives[0], {'sha256': hashlib.sha256(alternate).hexdigest(),
                                      'urls': ['https://release/source']}]

        def download(command, **kwargs):
            Path(command[command.index('-O') + 1]).write_bytes(
                alternate if command[-1] == 'https://release/source' else b'wrong data')

        with patch.object(source.subprocess, 'run', side_effect=download):
            source.fetch(self.destination, archives)
        self.assertEqual(self.destination.read_bytes(), alternate)
        with patch.object(source.subprocess, 'run') as network:
            source.fetch(self.destination, archives)
        network.assert_not_called()
        self.assert_clean()

    def test_all_failures_remove_invalid_cache_and_temporary_files(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(b'bad cache')
        with patch.object(source.subprocess, 'run', side_effect=subprocess.CalledProcessError(4, 'wget')):
            with self.assertRaises(RuntimeError):
                source.fetch(self.destination, self.archives)
        self.assertFalse(self.destination.exists())
        self.assert_clean()

    def test_makefile_stops_before_extraction_when_fetch_fails(self):
        tools = self.root / 'tools'
        tools.mkdir()
        for name, body in [('python3', 'exit 42'), ('tar', 'touch "$EXTRACTED"')]:
            path = tools / name
            path.write_text('#!/bin/sh\n' + body + '\n')
            path.chmod(0o755)
        result = subprocess.run(['make', '-f', str(MAKEFILE), 'libs'], cwd=self.root,
                                env=dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                                         EXTRACTED=str(self.root / 'extracted')), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'extracted').exists())

    def test_makefile_stops_before_next_library_when_configure_fails(self):
        tools = self.root / 'tools'
        tools.mkdir()
        fake = tools / 'python3'
        fake.write_text('#!/bin/sh\necho "$2" >> "$FETCHED"\n')
        fake.chmod(0o755)
        ffmpeg = self.root / 'ffmpeg-8.1.1'
        ffmpeg.mkdir()
        (ffmpeg / 'README.md').write_text('fixture\n')
        configure = ffmpeg / 'configure'
        configure.write_text('#!/bin/sh\nexit 7\n')
        configure.chmod(0o755)
        result = subprocess.run(['make', '-f', str(MAKEFILE), 'libs'], cwd=self.root,
                                env=dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                                         FETCHED=str(self.root / 'fetched')), capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'fetched').read_text().splitlines(), ['ffmpeg'])

    def test_makefile_versions_match_pinned_manifest(self):
        manifest = json.loads(source.MANIFEST.read_text())
        text = MAKEFILE.read_text()
        for component, variable in [('ffmpeg', 'FFMPEG_VERSION'), ('jpeg', 'JPEGLIB_VERSION')]:
            self.assertIn(variable + ' = ' + manifest[component]['version'], text)
            for archive in manifest[component]['archives']:
                self.assertEqual(len(bytes.fromhex(archive['sha256'])), 32)
                self.assertTrue(all(url.startswith('https://') for url in archive['urls']))


if __name__ == '__main__':
    unittest.main()
