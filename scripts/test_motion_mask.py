#!/usr/bin/env python3
"""Replay private encoder snapshots through real motiond; no camera access."""
import ctypes
import json
import mmap
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Frame(ctypes.Structure):
    _fields_ = [("pid", ctypes.c_uint32), ("frame", ctypes.c_uint32),
                ("p_frame", ctypes.c_uint32), ("reserved", ctypes.c_uint32),
                ("monotonic_ms", ctypes.c_int64), ("vectors", ctypes.c_ubyte * 7360),
                ("difference", ctypes.c_ubyte * 920)]


class Shared(ctypes.Structure):
    _fields_ = [(key, ctypes.c_uint32) for key in
                ("magic", "version", "enabled", "generation", "reader_ms", "reserved")]
    _fields_ += [("sample", Frame)]


class MaskTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="motion-mask-test-")
        self.addCleanup(self.temp.cleanup)
        self.dir = Path(self.temp.name)
        self.map_path = self.dir / "map"
        self.binary = self.dir / "motiond"
        self.flags = ["gcc", "-Wall", "-Wextra", "-Werror", "-O2",
                      f'-DMOTION_MAP_PATH="{self.map_path}"']

    def test_score_and_snapshot_contract(self):
        exe = self.dir / "test-mask"
        subprocess.run(self.flags + [str(ROOT / "src/motiond/tests/test_mask.c"), "-o", str(exe)],
                       check=True, capture_output=True)
        subprocess.run([str(exe)], check=True)

    def test_encoder_owner_publisher(self):
        exe = self.dir / 'publisher'
        subprocess.run(self.flags + [str(ROOT / 'src/motiond/tests/test_map_publisher.c'), '-o', str(exe)],
                       check=True, capture_output=True)
        subprocess.run([str(exe)], check=True)

    def test_real_detector_excludes_left_and_keeps_raw_metadata(self):
        flags = self.flags + [f'-DVE_PATH="{self.dir / "ve"}"',
                             f'-DSTATE_PATH="{self.dir / "state"}"',
                             f'-DTELEMETRY_PATH="{self.dir / "telemetry"}"']
        subprocess.run(flags + [str(ROOT / "src/motiond/motiond/motiond.c"),
                               str(ROOT / "src/ipc_cmd/ipc_cmd/motion_metadata_levels.c"),
                               "-lrt", "-o", str(self.binary)], check=True, capture_output=True)
        (self.dir / "ve").write_text("Channel[0]\nScene:0, Move:4, MovingLevel:3, "
                                    "BinImgRatio:30%, MovingTh:20\nEnd Channel[0]\n")
        self.map_path.write_bytes(bytes(ctypes.sizeof(Shared)))
        with self.map_path.open("r+b") as file:
            mapping = mmap.mmap(file.fileno(), 0)
        shared = Shared.from_buffer(mapping)
        shared.magic = 0x594d4150
        shared.version = 2
        mask = ("1" * 10 + "0" * 10) * 12
        env = {**os.environ, "YI_MOTION_LEVELS": str(self.dir / "levels")}
        process = subprocess.Popen([str(self.binary), "--mask", mask, "--trigger", "2",
                                    "--release", "1", "--confirm", "2", "--quiet-ms", "100",
                                    "--require-zero", "0"], env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            def replay(side, count):
                for _ in range(count):
                    shared.generation |= 1
                    shared.sample.pid = os.getpid()
                    shared.sample.frame += 1
                    shared.sample.p_frame = 1
                    shared.sample.monotonic_ms = int(time.monotonic() * 1000)
                    for i in range(920):
                        bits = (1 << 47) if side and ((i % 40 < 20) == (side == "left")) else 0
                        for j in range(8): shared.sample.vectors[i*8+j] = (bits >> (j*8)) & 255
                    shared.generation += 1
                    time.sleep(0.10)
                self.assertIsNone(process.poll())
            # Keep a valid map throughout startup: even strong whole-frame
            # hints cannot override exclusions once spatial snapshots exist.
            replay("left", 20)
            metrics = json.loads((self.dir / "telemetry").read_text())
            self.assertFalse(metrics["active"])
            self.assertEqual(metrics["mask"]["ratio"], 0)
            replay("right", 20)
            metrics = json.loads((self.dir / "telemetry").read_text())
            self.assertTrue(metrics["active"])
            self.assertAlmostEqual(metrics["mask"]["ratio"], 50)
            self.assertEqual(metrics["bin_ratio"], 30)
            replay(None, 20)
            metrics = json.loads((self.dir / "telemetry").read_text())
            self.assertFalse(metrics["active"])
            # Timestamp history remains raw: binary samples use the vendor
            # ratio 30, rather than the spatial ratio 50 used for triggering.
            raw = (self.dir / "levels").read_bytes()
            ratios = [struct.unpack('<d', raw[56+i*32:64+i*32])[0]
                      for i in range(512)]
            self.assertIn(30.0, ratios)
            time.sleep(1.7)
            metrics = json.loads((self.dir / "telemetry").read_text())
            self.assertEqual(metrics["mask"]["error"], 2)
            self.assertTrue(metrics["active"])  # Explicit whole-view fallback.
        finally:
            process.terminate()
            process.wait(timeout=3)
            del shared
            mapping.close()


if __name__ == "__main__":
    unittest.main()
