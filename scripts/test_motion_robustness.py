#!/usr/bin/env python3
"""Exercise real detector processes with private files, queues, and log pipes."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MotionRobustnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="motiond-robustness-")
        cls.root = Path(cls.temp.name)
        cls.binary = cls.root / "motiond"
        cls.queue = f"/motiond-runtime-test-{os.getpid()}"
        args = ["gcc", "-Wall", "-Wextra", "-Werror", "-O2"]
        for key, value in {"VE_PATH": str(cls.root / "ve"),
                           "STATE_PATH": str(cls.root / "state"),
                           "TELEMETRY_PATH": str(cls.root / "telemetry"),
                           "IPC_QUEUE_NAME": cls.queue}.items():
            args.append(f'-D{key}="{value}"')
        subprocess.run(args + [str(ROOT / "src/motiond/motiond/motiond.c"),
                               str(ROOT / "src/ipc_cmd/ipc_cmd/motion_metadata_levels.c"),
                               "-lrt", "-o", str(cls.binary)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        for name in ("state", "telemetry", "levels"):
            (self.root / name).unlink(missing_ok=True)
        self.reading(4)

    def reading(self, ratio):
        temp = self.root / "ve.new"
        temp.write_text("Channel[0]\nScene:0, Move:1, MovingLevel:1, "
                        f"BinImgRatio:{ratio}%, MovingTh:20\nEnd Channel[0]\n")
        temp.replace(self.root / "ve")

    def launch(self, output=subprocess.DEVNULL, record=False):
        env = {**os.environ, "YI_MOTION_LEVELS": str(self.root / "levels")}
        process = subprocess.Popen([str(self.binary), "-a", "--trigger", "2",
                                    "--release", "1", "--confirm", "1", "--quiet-ms", "100",
                                    "--require-zero", "0", *(["-r"] if record else [])],
                                   env=env, stdout=output, stderr=output)
        self.addCleanup(self.stop, process)
        return process

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise AssertionError("Detector shutdown blocked")

    def metrics(self, process, after=-1):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.assertIsNone(process.poll(), "Detector exited unexpectedly")
            try:
                data = json.loads((self.root / "telemetry").read_text())
                if data["monotonic_ms"] > after:
                    self.assertEqual(data["read_error"], 0)
                    return data
            except FileNotFoundError:
                pass
            time.sleep(0.02)
        self.fail("Detector stopped publishing telemetry")

    def test_full_log_pipe_keeps_sampling_and_shutdown_responsive(self):
        reader, writer = os.pipe()
        self.addCleanup(os.close, reader)
        self.addCleanup(os.close, writer)
        os.set_blocking(writer, False)
        try:
            while True:
                os.write(writer, b"x" * 4096)
        except BlockingIOError:
            pass
        os.set_blocking(writer, True)
        process = self.launch(writer)
        first = self.metrics(process)
        second = self.metrics(process, first["monotonic_ms"])
        self.assertTrue(second["active"])
        self.assertFalse(second["state_pending"])
        self.stop(process)
        self.assertEqual(process.returncode, 0)

    def test_closed_log_pipe_does_not_kill_detector(self):
        reader, writer = os.pipe()
        os.close(reader)
        self.addCleanup(os.close, writer)
        process = self.launch(writer)
        first = self.metrics(process)
        self.assertTrue(self.metrics(process, first["monotonic_ms"])["active"])
        self.stop(process)
        self.assertEqual(process.returncode, 0)

    def test_absent_broker_does_not_stop_detection(self):
        process = self.launch(record=True)
        first = self.metrics(process)
        second = self.metrics(process, first["monotonic_ms"])
        self.assertTrue(second["active"])
        self.assertTrue(second["ipc_pending"])
        self.assertNotEqual(second["ipc_error"], 0)
        self.stop(process)
        self.assertEqual(process.returncode, 0)

    def test_state_file_never_contains_partial_updates(self):
        process = self.launch()
        self.metrics(process)
        seen = set()
        begin = time.monotonic()
        phase = -1
        while time.monotonic() - begin < 1.6:
            current = int((time.monotonic() - begin) / 0.4)
            if current != phase:
                self.reading(0 if current % 2 == 0 else 4)
                phase = current
            state = (self.root / "state").read_bytes()
            self.assertIn(state, (b"0\n", b"1\n"))
            seen.add(state)
            time.sleep(0.001)
        self.assertEqual(seen, {b"0\n", b"1\n"})

    def test_failed_state_publication_recovers_without_restart(self):
        blocked = self.root / "state.tmp"
        blocked.mkdir()
        process = self.launch()
        first = self.metrics(process)
        self.assertTrue(first["state_pending"])
        blocked.rmdir()
        second = self.metrics(process, first["monotonic_ms"])
        self.assertFalse(second["state_pending"])
        self.assertTrue(second["active"])
        self.assertEqual((self.root / "state").read_bytes(), b"1\n")

    def test_real_queue_backpressure_and_reconnection(self):
        executable = self.root / "delivery-test"
        subprocess.run(["gcc", "-Wall", "-Wextra", "-Werror", "-O2",
                        str(ROOT / "src/motiond/tests/test_delivery.c"),
                        "-lrt", "-o", str(executable)], check=True, capture_output=True)
        subprocess.run([str(executable)], check=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
