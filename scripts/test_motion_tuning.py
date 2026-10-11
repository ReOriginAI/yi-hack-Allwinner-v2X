#!/usr/bin/env python3
"""Exercise motion hysteresis, input rejection and saved/runtime UI settings."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CGI = ROOT / "src/www/httpd/cgi-bin"
STATIC = ROOT / "src/static/static/yi-hack"


class MotionTuningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.binary = Path(cls.temp.name) / "motiond"
        subprocess.run(["gcc", "-Wall", "-Wextra", "-Werror", "-O2",
                        str(ROOT / "src/motiond/motiond/motiond.c"), "-lrt", "-o", str(cls.binary)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.root = Path(self.dir.name)
        for sub in ("etc", "bin", "script", "www/cgi-bin"):
            (self.root / sub).mkdir(parents=True)
        shutil.copy(CGI / "validate.sh", self.root / "www/cgi-bin")
        shutil.copy(STATIC / "script/motion_settings.sh", self.root / "script")
        shutil.copy(STATIC / "etc/camera.conf", self.root / "etc")
        self.config = self.root / "etc/camera.conf"
        (self.root / "model_suffix").write_text("y623\n")
        self.log = self.root / "apply.log"
        service = self.root / "script/motion_service.sh"
        service.write_text('''#!/bin/sh
case "$1" in
  backend) echo "${TEST_BACKEND:-encoder-stats}" ;;
  status) echo "${TEST_STATUS:-started}" ;;
  settings) "$TEST_BINARY" --settings ;;
  restart) echo restart >> "$TEST_LOG"; exit "${TEST_FAILURE:-0}" ;;
esac
''')
        service.chmod(0o755)
        self.env = {**os.environ, "YI_HACK_PREFIX": str(self.root), "QUERY_STRING": "conf=camera",
                    "TEST_BINARY": str(self.binary), "TEST_LOG": str(self.log),
                    "MOTION_TELEMETRY_PATH": str(self.root / "telemetry")}

    def call(self, name, changes=None):
        result = subprocess.run(["busybox", "ash", str(CGI / name)], env=self.env,
                                input=json.dumps(changes) + "\n" if changes is not None else "",
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout.split("\n\n", 1)[1])

    def settings(self, *args):
        return json.loads(subprocess.check_output([str(self.binary), *args, "--settings"], text=True))

    def test_presets_and_custom_arguments(self):
        for sensitivity in range(1, 11):
            data = self.settings("-s", str(sensitivity))
            self.assertTrue(data["level_boost"])
            self.assertFalse(data["custom"])
            self.assertGreater(data["trigger"], data["release"])
        data = self.settings("--trigger", "3.25", "--release", "2.10", "--confirm", "2",
                             "--quiet-ms", "1500", "-i", "250", "--require-zero", "0")
        self.assertEqual(data["trigger"], 3.25)
        self.assertEqual(data["release"], 2.1)
        self.assertTrue(data["custom"])
        self.assertFalse(data["level_boost"])
        self.assertFalse(data["require_zero"])
        self.assertEqual(data["interval_ms"], 250)

    def test_cli_rejects_bad_values_before_opening_devices(self):
        for args in (("--trigger", "nan"), ("--trigger", "1e1"), ("--trigger", "2.001"),
                     ("--trigger", "0"), ("--release", "3"), ("--confirm", "0"),
                     ("--confirm", "3x"), ("--quiet-ms", "30001"), ("-i", "99"),
                     ("--require-zero", "2"), ("-s", "11")):
            result = subprocess.run([str(self.binary), *args, "--settings"], capture_output=True)
            self.assertEqual(result.returncode, 2, args)

    def test_motion_transitions_ignore_background_and_missing_samples(self):
        source = self.root / "sequence.c"
        source.write_text('''#include "motion_tuning.h"
#include <assert.h>
int main(void) {
  for (int i=0;i<10;i++) assert(motion_config_valid(&cfgs[i],100));
  struct sens_cfg c={3.0,2.0,3,2000,0,0};
  struct motion_detector d={.quiet_since=-1};
  struct motion_stats s={.moving_level=1,.bin_ratio=1.7};
  for (int t=0;t<10000;t+=100) assert(!motion_update(&d,&c,&s,t));
  assert(!d.active);
  s.bin_ratio=4;
  assert(!motion_update(&d,&c,&s,10000));
  assert(!motion_update(&d,&c,&s,10100));
  assert(motion_update(&d,&c,&s,10200)==1);
  s.bin_ratio=1.7;
  assert(!motion_update(&d,&c,&s,10300));
  assert(!motion_update(&d,&c,NULL,12000)); // Missing sample breaks quiet timing.
  assert(!motion_update(&d,&c,&s,12300));
  assert(!motion_update(&d,&c,&s,14299));
  assert(motion_update(&d,&c,&s,14300)==-1);
  assert(!d.active);
  // A fresh threshold violation resets confirmation instead of accumulating.
  s.bin_ratio=4; assert(!motion_update(&d,&c,&s,15000));
  s.bin_ratio=1.7; assert(!motion_update(&d,&c,&s,15100));
  s.bin_ratio=4;
  assert(!motion_update(&d,&c,&s,15200));
  assert(!motion_update(&d,&c,&s,15300));
  assert(motion_update(&d,&c,&s,15400)==1);
  // Presets preserve the level-zero guard; custom can deliberately relax it.
  c.require_zero=1; s.bin_ratio=1.7;
  assert(!motion_update(&d,&c,&s,16000));
  assert(!motion_update(&d,&c,&s,30000)); assert(d.active);
  s.moving_level=0;
  assert(!motion_update(&d,&c,&s,30100));
  assert(motion_update(&d,&c,&s,32100)==-1);
  // A high encoder hint cannot override an explicit custom start threshold.
  s.bin_ratio=2; s.moving_level=2;
  for (int t=33000;t<34000;t+=100) assert(!motion_update(&d,&c,&s,t));
  c.level_boost=1;
  assert(!motion_update(&d,&c,&s,34000));
  assert(!motion_update(&d,&c,&s,34100));
  assert(motion_update(&d,&c,&s,34200)==1);
  s.bin_ratio=NAN; assert(!motion_update(&d,&c,&s,40000)); assert(d.active);
  return 0;
}
''')
        exe = self.root / "sequence"
        subprocess.run(["gcc", "-Wall", "-Wextra", "-Werror", "-I",
                        str(ROOT / "src/motiond/motiond"), str(source), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)

    def test_invalid_api_request_changes_nothing(self):
        original = self.config.read_bytes()
        for changes in ({"MOTION_START_THRESHOLD":"0"}, {"MOTION_STOP_THRESHOLD":"3.00"},
                        {"MOTION_START_SAMPLES":"0"}, {"MOTION_STOP_DELAY":"2.5"},
                        {"MOTION_POLL_INTERVAL":"50"}, {"MOTION_CUSTOM":True},
                        {"MOTION_STOP_REQUIRE_ZERO":"maybe"}, {"MOTION_SENSITIVITY":"11"},
                        {"MOTION_START_THRESHOLD":"nan"}, {"MOTION_START_THRESHOLD":None},
                        {"MOTION_STOP_THRESHOLD":"1;touch /tmp/unsafe"}):
            result = self.call("set_configs.sh", {"LED":"yes", **changes})
            self.assertTrue(result["error"], changes)
            self.assertEqual(self.config.read_bytes(), original)
            self.assertFalse(self.log.exists())

    def test_apply_once_and_preserve_preferences(self):
        changes={"MOTION_CUSTOM":"yes", "MOTION_START_THRESHOLD":"3.25",
                 "MOTION_STOP_THRESHOLD":"2.10", "MOTION_STOP_REQUIRE_ZERO":"no"}
        self.assertEqual(self.call("set_configs.sh", changes)["error"], "false")
        self.assertEqual(self.log.read_text(), "restart\n")
        self.assertIn("NIGHTVISION_MODE=auto\n", self.config.read_text())
        self.call("set_configs.sh", changes)
        self.assertEqual(self.log.read_text(), "restart\n")
        self.call("set_configs.sh", {"MOTION_CUSTOM":"no"})
        self.assertEqual(self.log.read_text(), "restart\nrestart\n")

    def test_service_uses_saved_values_and_returns_to_preset(self):
        script=(STATIC / "script/motion_service.sh").read_text()
        ve=self.root / "ve"
        ve.touch()
        script=script.replace("/sys/kernel/debug/mpp/ve",str(ve))
        service=self.root / "script/motion_service.sh"
        service.write_text(script)
        shutil.copy(self.binary,self.root / "bin/motiond")
        self.config.write_text(self.config.read_text().replace("MOTION_CUSTOM=no","MOTION_CUSTOM=yes")
                               .replace("MOTION_START_THRESHOLD=3.00","MOTION_START_THRESHOLD=3.25")
                               .replace("MOTION_STOP_THRESHOLD=0.30","MOTION_STOP_THRESHOLD=2.10")
                               .replace("MOTION_STOP_REQUIRE_ZERO=yes","MOTION_STOP_REQUIRE_ZERO=no")
                               .replace("MOTION_POLL_INTERVAL=100","MOTION_POLL_INTERVAL=250"))
        result=subprocess.check_output(["busybox","ash",str(service),"settings"],env=self.env,text=True)
        settings=json.loads(result)
        self.assertEqual(settings["trigger"],3.25)
        self.assertEqual(settings["release"],2.1)
        self.assertEqual(settings["interval_ms"],250)
        self.assertFalse(settings["require_zero"])
        self.config.write_text(self.config.read_text().replace("MOTION_CUSTOM=yes","MOTION_CUSTOM=no")
                               .replace("MOTION_SENSITIVITY=5","MOTION_SENSITIVITY=8"))
        result=subprocess.check_output(["busybox","ash",str(service),"settings"],env=self.env,text=True)
        self.assertEqual(json.loads(result)["trigger"],0.8)
        self.assertFalse(json.loads(result)["custom"])

    def test_y28ga_rejects_unsupported_custom_mode(self):
        (self.root / "model_suffix").write_text("y28ga\n")
        before=self.config.read_bytes()
        result=self.call("set_configs.sh", {"MOTION_CUSTOM":"yes"})
        self.assertTrue(result["error"])
        self.assertEqual(before,self.config.read_bytes())
        self.assertEqual(self.call("set_configs.sh", {"MOTION_SENSITIVITY":"9"})["error"], "false")

    def test_old_configuration_is_migrated(self):
        self.config.write_text("MOTION_DETECTION=yes\nSAVE_VIDEO_ON_MOTION=yes\nMOTION_SENSITIVITY=8\nIR=yes\nLED=no\n")
        result=self.call("set_configs.sh", {"MOTION_CUSTOM":"yes", "MOTION_STOP_THRESHOLD":"2.00"})
        self.assertEqual(result["error"], "false")
        text=self.config.read_text()
        self.assertIn("MOTION_SENSITIVITY=8\n",text)
        self.assertIn("MOTION_STOP_DELAY=2000\n",text)
        self.assertIn("MOTION_STOP_THRESHOLD=2.00\n",text)

    def test_runtime_failure_is_visible(self):
        self.env["TEST_FAILURE"]="1"
        result=self.call("set_configs.sh", {"MOTION_CUSTOM":"yes"})
        self.assertTrue(result["error"])
        self.assertIn("failed to apply",result["description"])

    def test_status_reports_backend_and_rejects_stale_samples(self):
        uptime=float(Path('/proc/uptime').read_text().split()[0])*1000
        sample={"monotonic_ms":int(uptime),"active":False,"bin_ratio":1.7,"moving_level":1,
                "read_error":0,"effective":self.settings()}
        (self.root / "telemetry").write_text(json.dumps(sample))
        data=self.call("motion_status.sh")
        self.assertTrue(data["custom_supported"])
        self.assertEqual(data["metrics"]["bin_ratio"],1.7)
        sample["monotonic_ms"]-=10000
        (self.root / "telemetry").write_text(json.dumps(sample))
        self.assertIsNone(self.call("motion_status.sh")["metrics"])
        self.env["TEST_BACKEND"]="ipc-events"
        (self.root / "model_suffix").write_text("y28ga\n")
        data=self.call("motion_status.sh")
        self.assertFalse(data["custom_supported"])
        self.assertTrue(data["sensitivity_supported"])
        self.assertIsNone(data["metrics"])


if __name__ == "__main__":
    unittest.main()
