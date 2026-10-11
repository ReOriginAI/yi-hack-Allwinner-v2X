#!/usr/bin/env python3
"""Night-vision configuration, atomic control and native threshold regressions."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ipc_cmd/ipc_cmd"
CGI = ROOT / "src/www/httpd/cgi-bin"


class NightvisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.control = self.root / "control"
        self.binary = self.root / "nightvisionctl"
        subprocess.run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        f'-DNV_PATH="{self.control}"', str(SOURCE / "nightvisionctl.c"),
                        "-o", str(self.binary)], check=True, capture_output=True)
        for sub in ("etc", "bin", "script", "www/cgi-bin"):
            (self.root / sub).mkdir(parents=True)
        shutil.copy(CGI / "validate.sh", self.root / "www/cgi-bin")
        self.config = self.root / "etc/camera.conf"
        shutil.copy(ROOT / "src/static/static/yi-hack/etc/camera.conf", self.config)
        self.log = self.root / "apply.log"
        mock = self.root / "script/nightvision.sh"
        mock.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$NV_TEST_LOG"\nexit "${NV_TEST_FAILURE:-0}"\n')
        mock.chmod(0o755)
        self.env = {**os.environ, "YI_HACK_PREFIX": str(self.root), "QUERY_STRING": "conf=camera",
                    "NV_TEST_LOG": str(self.log)}

    def ctl(self, *args, check=True):
        return subprocess.run([str(self.binary), *args], text=True, capture_output=True, check=check)

    def set_config(self, changes):
        result = subprocess.run(["busybox", "ash", str(CGI / "set_configs.sh")], env=self.env,
                                input=json.dumps(changes) + "\n", text=True,
                                capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout.split("\n\n", 1)[1])

    def test_threshold_preserves_hysteresis_and_original_setting(self):
        fixture = self.root / "levels.c"
        fixture.write_text('''#include "nightvision.h"
#include <assert.h>
int main(void) {
    for (int level = 0; level <= 2000; level++)
        assert(nv_level(level, NV_AUTO, 50) == level);
    assert(nv_level(-1, NV_AUTO, 100) == -1);
    assert(nv_level(INT32_MAX, NV_AUTO, 1) == INT32_MAX);
    assert(nv_level(1000, NV_ON, 50) == 0);
    assert(nv_level(0, NV_OFF, 50) >= 560);
    for (unsigned threshold = 1; threshold <= 100; threshold++) {
        /* Both native firmware threshold pairs retain their hysteresis gap. */
        for (int model = 0; model < 2; model++) {
            int night = model ? 120 : 80, day = model ? 480 : 560;
            int low = night * threshold / 50;
            int high = (day * threshold + 49) / 50;
            assert(high > low);
            if (low) assert(nv_level(low - 1, NV_AUTO, threshold) < night);
            assert(nv_level(high, NV_AUTO, threshold) >= day);
        }
    }
    return 0;
}
''')
        output = self.root / "levels"
        subprocess.run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(SOURCE),
                        str(fixture), "-o", str(output)], check=True, capture_output=True)
        subprocess.run([str(output)], check=True)

    def test_controller_validates_before_writing(self):
        self.ctl("--init", "auto", "50")
        original = self.control.read_bytes()
        for mode, threshold in (("invalid", "50"), ("on", "0"), ("off", "101"),
                                ("auto", "2.5"), ("auto", "12x"), ("auto", "")):
            with self.subTest(mode=mode, threshold=threshold):
                self.assertEqual(self.ctl("--init", mode, threshold, check=False).returncode, 2)
                self.assertEqual(self.control.read_bytes(), original)

    def test_no_runtime_is_reported_instead_of_claiming_success(self):
        self.ctl("--init", "auto", "50")
        result = self.ctl("--set", "on", "75", check=False)
        self.assertEqual(result.returncode, 1)
        status = json.loads(result.stdout)
        self.assertFalse(status["supported"])
        self.assertFalse(status["applied"])
        self.assertEqual(status["state"], "unavailable")

    def test_saved_and_applied_state_are_distinct(self):
        self.ctl("--init", "auto", "50")
        words = list(struct.unpack("<12I", self.control.read_bytes()))
        words[5] = os.getpid()
        words[7] = int(time.monotonic())
        words[8] = words[2]
        words[9:12] = [150, 150, 0]
        self.control.write_bytes(struct.pack("<12I", *words))
        status = json.loads(self.ctl("--status").stdout)
        self.assertTrue(status["supported"])
        self.assertTrue(status["applied"])
        self.assertEqual(status["state"], "day")
        status = json.loads(self.ctl("--set", "on", "75").stdout)
        self.assertEqual(status["mode"], "on")
        self.assertFalse(status["applied"])
        self.assertEqual(struct.unpack("<12I", self.control.read_bytes())[2] % 2, 0)

    def test_api_rejects_invalid_pair_without_changing_other_settings(self):
        before = self.config.read_bytes()
        for bad in (0, 101, 2.5, "nonsense", None, "", "00050"):
            result = self.set_config({"LED": "yes", "NIGHTVISION_MODE": "on", "NIGHTVISION_THRESHOLD": bad})
            self.assertTrue(result["error"])
            self.assertEqual(self.config.read_bytes(), before)
            self.assertFalse(self.log.exists())
        result = self.set_config({"NIGHTVISION_MODE": "bad", "NIGHTVISION_THRESHOLD": "60"})
        self.assertTrue(result["error"])
        self.assertEqual(self.config.read_bytes(), before)

    def test_mode_is_authoritative_and_applies_once(self):
        result = self.set_config({"NIGHTVISION_MODE": "on", "NIGHTVISION_THRESHOLD": "75", "IR": "no"})
        self.assertEqual(result["error"], "false")
        self.assertIn("IR=yes\n", self.config.read_text())
        self.assertEqual(self.log.read_text(), "apply\n")
        self.set_config({"NIGHTVISION_MODE": "on", "NIGHTVISION_THRESHOLD": "75"})
        self.assertEqual(self.log.read_text(), "apply\n")
        self.set_config({"NIGHTVISION_MODE": "off"})
        self.assertIn("IR=no\n", self.config.read_text())
        self.assertEqual(self.log.read_text(), "apply\napply\n")

    def test_legacy_ir_client_updates_mode(self):
        self.set_config({"IR": "no"})
        self.assertIn("NIGHTVISION_MODE=off\n", self.config.read_text())
        self.set_config({"IR": "yes"})
        self.assertIn("NIGHTVISION_MODE=auto\n", self.config.read_text())

    def test_migration_preserves_existing_preferences(self):
        self.config.write_text(self.config.read_text().replace("NIGHTVISION_MODE=auto\n", "")
                              .replace("NIGHTVISION_THRESHOLD=50\n", ""))
        self.set_config({"NIGHTVISION_MODE": "off", "NIGHTVISION_THRESHOLD": "25"})
        self.assertIn("NIGHTVISION_MODE=off\n", self.config.read_text())
        self.assertIn("NIGHTVISION_THRESHOLD=25\n", self.config.read_text())

    def test_apply_failure_is_visible(self):
        self.env["NV_TEST_FAILURE"] = "1"
        result = self.set_config({"NIGHTVISION_MODE": "off"})
        self.assertTrue(result["error"])
        self.assertIn("unavailable", result["description"])


if __name__ == "__main__":
    unittest.main()
