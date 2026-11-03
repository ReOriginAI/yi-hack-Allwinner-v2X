#!/usr/bin/env python3
"""Check compact snapshot routing and real ARM H.264-to-JPEG decoding."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--decoder', type=Path)
parser.add_argument('--full-decoder', type=Path)
parser.add_argument('--rootfs', type=Path)
parser.add_argument('--qemu', type=Path)
parser.add_argument('--ring', action='store_true')
options, remaining = parser.parse_known_args()


def executable(path, body):
    path.write_text('#!/bin/sh\n' + body + '\n')
    path.chmod(0o755)


class RoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='grid-guard-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.guard = Path(cls.tmp.name) / 'service_guard'
        subprocess.run(['cc', '-O2', str(ROOT / 'src/service_guard/service_guard.c'),
                        '-o', str(cls.guard)], check=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='grid-route-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ['bin', 'script', 'optional/bin']:
            (self.root / name).mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.guard, self.root / 'bin/service_guard')
        shutil.copy2(ROOT / 'src/static/static/yi-hack/script/storage.sh', self.root / 'script/storage.sh')
        executable(self.root / 'script/rtsp_stream_venc.sh', 'echo "venc:$*" >> "$TRACE"')
        executable(self.root / 'bin/imggrabber-grid', 'echo grid >> "$TRACE"; printf JPEG; exit "${DECODE_STATUS:-0}"')
        executable(self.root / 'optional/bin/imggrabber', 'echo "full:$YI_SNAPSHOT_WM_ROOT" >> "$TRACE"; printf FULLJPEG')
        executable(self.root / 'bin/sleep', ':')
        self.wrapper = self.root / 'snapshot.sh'
        self.wrapper.write_text((ROOT / 'scripts/flash-core/grid_snapshot.sh').read_text().replace(
            '/tmp/sd/yi-hack-optional', str(self.root / 'optional')))
        self.mounts = self.root / 'mounts'
        self.mounts.write_text('')
        self.trace = self.root / 'trace'
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), TRACE=str(self.trace),
                        YI_STORAGE_MOUNTS=str(self.mounts), PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])

    def run_snapshot(self, *arguments):
        return subprocess.run(['sh', str(self.wrapper), *arguments], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_motion_grid_uses_internal_decoder_without_sd(self):
        result = self.run_snapshot('-m', 'y623', '-r', 'low')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'JPEG')
        self.assertEqual(self.trace.read_text().splitlines(), ['venc:both', 'grid', 'venc:'])

    def test_decoder_failure_restores_stream_policy(self):
        self.env['DECODE_STATUS'] = '7'
        self.assertEqual(self.run_snapshot('-r', 'low').returncode, 7)
        self.assertEqual(self.trace.read_text().splitlines()[-1], 'venc:')

    def test_full_snapshot_requires_real_sd_mount(self):
        for arguments in [('-r', 'high'), ('-r', 'low', '-w'), ('-f', 'clip.h264')]:
            with self.subTest(arguments=arguments):
                result = self.run_snapshot(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
                self.assertFalse(self.trace.exists())

    def test_full_snapshot_and_resources_are_available_on_sd(self):
        self.mounts.write_text('/dev/mmcblk0p1 /tmp/sd vfat rw 0 0\n')
        result = self.run_snapshot('-r', 'high', '-w')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'FULLJPEG')
        self.assertEqual(self.trace.read_text().strip(), 'full:' + str(self.root / 'optional/etc/wm_res'))
        self.trace.unlink()
        self.assertEqual(self.run_snapshot('-r', 'low').stdout, 'JPEG')
        self.assertIn('grid', self.trace.read_text())
        self.trace.unlink()
        self.assertEqual(self.run_snapshot('-f', 'clip.h264', '-r', 'low').stdout, 'FULLJPEG')
        self.assertNotIn('venc:', self.trace.read_text())


@unittest.skipUnless(options.decoder, 'pass --decoder for native ARM integration checks')
class DecoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='grid-decode-')
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.root = Path(cls.tmp.name)
        cls.qemu = str(options.qemu or shutil.which('qemu-arm-static'))
        cls.rootfs = options.rootfs
        if cls.rootfs is None:
            from pack_flash_core_all import extract_bases
            extract_bases(cls.root / 'bases')
            cls.rootfs = cls.root / 'rootfs'
            subprocess.run(['unsquashfs', '-no-progress', '-d', str(cls.rootfs),
                            str(cls.root / 'bases/y28ga/rootfs.bin')], check=True, stdout=subprocess.DEVNULL)
        cls.source = cls.root / 'sample.h264'
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
                        '-i', 'testsrc2=size=640x360:rate=1', '-frames:v', '1', '-c:v', 'libx264',
                        '-x264-params', 'keyint=1:repeat-headers=1', '-f', 'h264', str(cls.source)], check=True)
        nals = {}
        for nal in re.split(b'\x00\x00(?:\x00)?\x01', cls.source.read_bytes()):
            if nal:
                nals.setdefault(nal[0] & 31, b'\0\0\0\1' + nal)
        cls.frame = cls.root / 'camera-frame.h264'
        cls.frame.write_bytes(b''.join(nals[k] for k in [7, 8, 5]))
        records = []
        for i, (kind, payload) in enumerate([(2, bytes(6) + nals[7]), (4, nals[8]), (1, nals[5])]):
            records.append(struct.pack('<IIIIIHHI', len(payload), i, 0, 0, 0, 0x800 | kind, i, 0) + payload)
        content = b''.join(records)
        ring = bytearray(131072)
        ring[368:368 + len(content)] = content
        for offset, value in [(4, len(content)), (12, len(content)), (16, 0)]:
            struct.pack_into('<I', ring, offset, value)
        cls.ring = cls.root / 'camera-ring'
        cls.ring.write_bytes(ring)
        partial = bytearray(ring)
        for offset in [4, 12]:
            struct.pack_into('<I', partial, offset, len(records[0]))
        cls.partial_ring = cls.root / 'partial-ring'
        cls.partial_ring.write_bytes(partial)

    def decode(self, *arguments, full=False):
        binary = options.full_decoder if full else options.decoder
        return subprocess.run([self.qemu, '-L', str(self.rootfs), str(binary), *arguments],
                              capture_output=True, timeout=15)

    def assert_jpeg(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue(result.stdout.startswith(b'\xff\xd8'))
        jpeg = self.root / 'frame.jpg'
        jpeg.write_bytes(result.stdout)
        info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
                          'stream=width,height,codec_name', '-of', 'json', str(jpeg)]))['streams'][0]
        self.assertEqual((info['codec_name'], info['width'], info['height']), ('mjpeg', 640, 360))

    def test_h264_reference_frame_for_both_models(self):
        for model in ['y623', 'y28ga']:
            with self.subTest(model=model):
                self.assert_jpeg(self.decode('-m', model, '-f', str(self.frame), '-r', 'low'))
        if options.full_decoder:
            self.assert_jpeg(self.decode('-f', str(self.frame), '-r', 'low', full=True))

    def test_grid_rejects_high_resolution_and_watermarks(self):
        for arguments in [('-r', 'high'), ('-r', 'low', '-w')]:
            result = self.decode(*arguments)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')

    @unittest.skipUnless(options.ring, 'ring checks require isolated mount namespaces')
    def test_native_shared_frame_buffer_for_both_models(self):
        for model in ['y623', 'y28ga']:
            with self.subTest(model=model):
                result = subprocess.run(self.ring_command(model, self.ring), capture_output=True, timeout=15)
                self.assert_jpeg(result)

    def ring_command(self, model, ring):
        return ['bwrap', '--unshare-all', '--die-with-parent',
                '--ro-bind', str(self.rootfs), '/', '--proc', '/proc', '--dev', '/dev',
                '--dir', '/dev/shm', '--bind', str(ring), '/dev/shm/fshare_frame_buf',
                '--tmpfs', '/tmp', '--ro-bind', str(options.decoder), '/tmp/imggrabber-grid',
                '--ro-bind', self.qemu, '/sbin/udevd', '/sbin/udevd', '/tmp/imggrabber-grid',
                '-m', model, '-r', 'low']

    @unittest.skipUnless(options.ring, 'ring checks require isolated mount namespaces')
    def test_partial_frame_waits_for_caller_deadline(self):
        for model in ['y623', 'y28ga']:
            with self.subTest(model=model), self.assertRaises(subprocess.TimeoutExpired):
                # SPS can arrive before the picture records when VENC1 starts.
                # Wait for them; the wrapper's service_guard bounds this wait.
                subprocess.run(self.ring_command(model, self.partial_ring),
                               capture_output=True, timeout=1)


if __name__ == '__main__':
    unittest.main(argv=[__file__] + remaining)
