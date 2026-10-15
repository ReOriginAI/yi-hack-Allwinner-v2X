#!/usr/bin/env python3
"""Exercise the shared collector lifecycle with isolated BusyBox process stubs."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "src/static/static/yi-hack/script"


def function(script, name):
    return re.search(r"^" + name + r"\(\)\n\{\n.*?^\}\n", script,
                     re.MULTILINE | re.DOTALL).group()


class HistoryServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.prefix = Path(self.temp.name)
        for sub in ("etc", "bin", "script", "mock"):
            (self.prefix / sub).mkdir()
        (self.prefix / "model_suffix").write_text("y623\n")
        self.camera = self.prefix / "etc/camera.conf"
        self.system = self.prefix / "etc/system.conf"
        self.camera.write_text("MOTION_DETECTION=yes\n")
        self.system.write_text("REC_WITHOUT_CLOUD=yes\nONVIF=no\n")
        self.count = self.prefix / "count"
        self.count.write_text("0\n")
        self.history = self.prefix / "history"
        self.log = self.prefix / "calls"
        self.service = self.prefix / "script/motion_service.sh"
        # BusyBox ash may resolve its own applets before PATH. Shell functions
        # keep every process mutation inside this test's stubs.
        self.mocks = '''
ps() { "$YI_HACK_PREFIX/mock/ps" "$@"; }
killall() { "$YI_HACK_PREFIX/mock/killall" "$@"; }
sleep() { "$YI_HACK_PREFIX/mock/sleep" "$@"; }
'''
        self.service.write_text(self.mocks + (SCRIPTS / "motion_service.sh").read_text()
                                .replace("/tmp/motion_events.lock.d", str(self.prefix / "lock")))
        self.service.chmod(0o755)
        stubs = {
            "bin/ipc2file": '''#!/bin/sh
printf 'start\n' >> "$TEST_LOG"
printf '1\n' > "$TEST_COUNT"
printf 'fresh history\n' > "$YI_MOTION_EVENTS"
''',
            "mock/ps": '''#!/bin/sh
awk 'BEGIN { for (i=0;i<ENVIRON["TEST_MP4_COUNT"];i++) print "90 root 100 S ./mp4record" }
     { for (i=0;i<$1;i++) print "100 root 100 S /tmp/sd/yi-hack/bin/ipc2file" }' "$TEST_COUNT"
''',
            "mock/killall": '''#!/bin/sh
printf 'kill %s\n' "$*" >> "$TEST_LOG"
case "$*" in *ipc2file*) printf '0\n' > "$TEST_COUNT" ;; esac
''',
            "mock/sleep": "#!/bin/sh\nexit 0\n",
        }
        for path, body in stubs.items():
            p = self.prefix / path
            p.write_text(body)
            p.chmod(0o755)
        self.env = {**os.environ, "YI_HACK_PREFIX": str(self.prefix),
                    "YI_MOTION_EVENTS": str(self.history), "TEST_COUNT": str(self.count),
                    "TEST_LOG": str(self.log), "TEST_MP4_COUNT": "0",
                    "PATH": str(self.prefix / "mock") + ":" + os.environ["PATH"]}

    def call(self, action):
        return subprocess.check_output(["busybox", "ash", str(self.service), action],
                                       env=self.env, text=True).strip()

    def shell(self, body):
        return subprocess.check_output(["busybox", "ash", "-c", self.mocks + body],
                                       env=self.env, text=True)

    def test_recording_without_onvif_starts_history_and_reuses_it(self):
        self.assertEqual(self.call("events-status"), "failed")
        self.call("events")
        self.assertEqual(self.call("events-status"), "started")
        self.history.write_text("retained timestamps\n")
        self.call("events")
        self.assertEqual(self.history.read_text(), "retained timestamps\n")
        self.assertEqual(self.log.read_text(), "start\n")

    def test_missing_file_and_duplicate_consumers_recover(self):
        self.call("events")
        self.history.unlink()
        self.assertEqual(self.call("events-status"), "failed")
        self.call("events")
        self.assertEqual(self.call("events-status"), "started")
        self.count.write_text("2\n")
        self.call("events")
        self.assertEqual(self.count.read_text(), "1\n")
        self.assertEqual(self.log.read_text().splitlines(),
                         ["start", "kill ipc2file", "start", "kill ipc2file", "start"])

    def test_onvif_stop_preserves_motion_or_recording_history(self):
        stop = function((SCRIPTS / "service.sh").read_text(), "stop_onvif")
        for motion, record, native in (("yes", "no", "0"), ("no", "yes", "0"),
                                       ("no", "no", "1")):
            with self.subTest(motion=motion, record=record, native=native):
                self.camera.write_text(f"MOTION_DETECTION={motion}\n")
                self.system.write_text(f"REC_WITHOUT_CLOUD={record}\nONVIF=no\n")
                self.env["TEST_MP4_COUNT"] = native
                self.call("events")
                self.history.write_text("retained timestamps\n")
                self.shell(stop + "\nstop_onvif\n")
                self.assertEqual(self.count.read_text(), "1\n")
                self.assertEqual(self.history.read_text(), "retained timestamps\n")

    def test_onvif_stop_releases_collector_when_unused(self):
        self.call("events")
        self.camera.write_text("MOTION_DETECTION=no\n")
        self.system.write_text("REC_WITHOUT_CLOUD=no\nONVIF=no\n")
        stop = function((SCRIPTS / "service.sh").read_text(), "stop_onvif")
        self.shell(stop + "\nstop_onvif\n")
        self.assertEqual(self.count.read_text(), "0\n")

    def test_watchdog_recovers_history_without_restarting_recording(self):
        self.env["TEST_MP4_COUNT"] = "1"
        aux = function((SCRIPTS / "wd.sh").read_text(), "check_aux_services")
        harness = '''
restart_memory_ok() { return 0; }
refresh_oom_policy() { :; }
get_config() { awk -F= -v k="$1" '$1==k { print $2 }' "$YI_HACK_PREFIX/etc/system.conf"; }
get_camera_config() { awk -F= -v k="$1" '$1==k { print $2 }' "$YI_HACK_PREFIX/etc/camera.conf"; }
process_count() { case "$1" in mp4record) echo "$TEST_MP4_COUNT" ;; *) echo 0 ;; esac; }
'''
        self.shell(harness + aux + "\ncheck_aux_services\n")
        self.assertEqual(self.call("events-status"), "started")
        self.assertEqual(self.log.read_text(), "start\n")

    def test_collector_lock_does_not_remove_callers_trap(self):
        script = self.service.read_text().split("# Serialize y623 lifecycle operations", 1)[0]
        harness = f'''{script}
trap 'echo outer >> "$TEST_LOG"' 0
ensure_ipc_events
'''
        self.shell(harness)
        self.assertEqual(self.log.read_text(), "start\nouter\n")
        self.assertFalse((self.prefix / "lock").exists())


if __name__ == "__main__":
    unittest.main()
