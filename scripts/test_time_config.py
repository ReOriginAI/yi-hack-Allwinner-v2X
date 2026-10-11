#!/usr/bin/env python3
"""Check local filename policy, DST, signed fractional offsets and OSD layout."""
import datetime
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "src/static/static/yi-hack/script"
EASTERN = "EST5EDT,M3.2.0,M11.1.0"


class TimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yi-time-test-")
        self.addCleanup(self.temp.cleanup)
        self.prefix = Path(self.temp.name)
        for name in ("etc", "script", "bin"):
            (self.prefix / name).mkdir()
        for name in ("time_config.sh", "apply_time.sh"):
            shutil.copy(SCRIPTS / name, self.prefix / "script" / name)
        self.conf = self.prefix / "etc/system.conf"
        self.configure()
        self.env = {**os.environ, "YI_HACK_PREFIX": str(self.prefix), "TZ": "JST-9"}

    def configure(self, zone=EASTERN, mode="local", osd="yes"):
        self.conf.write_text(f"TIMEZONE={zone}\nEVENTS_TIME={mode}\nTIME_OSD={osd}\nREC_WITHOUT_CLOUD=yes\n")

    def shell(self, code, **env):
        result = subprocess.run(["sh", "-c", '. "$YI_HACK_PREFIX/script/time_config.sh"\n' + code],
                                env={**self.env, **env}, capture_output=True, text=True, check=True)
        self.assertEqual(result.stderr, "")
        return result.stdout.strip()

    def test_local_and_utc_policy_ignores_parent_timezone(self):
        for mode, osd, expected in (("local", "no", EASTERN), ("gmt", "yes", "UTC0"),
                                    ("autodetect", "yes", EASTERN), ("autodetect", "no", "UTC0")):
            self.configure(mode=mode, osd=osd)
            self.assertEqual(self.shell('recording_timezone'), expected)
        self.configure(zone="")
        self.assertEqual(self.shell('camera_timezone'), "UTC0")

    def test_eastern_filename_crosses_local_date_and_follows_dst(self):
        for utc, expected in (("2026-01-15T02:03:04+00:00", "2026Y01M14D21H/03M04S"),
                              ("2026-07-15T02:03:04+00:00", "2026Y07M14D22H/03M04S"),
                              ("2026-03-08T06:59:00+00:00", "2026Y03M08D01H/59M00S"),
                              ("2026-03-08T07:00:00+00:00", "2026Y03M08D03H/00M00S"),
                              ("2026-11-01T05:59:00+00:00", "2026Y11M01D01H/59M00S"),
                              ("2026-11-01T06:00:00+00:00", "2026Y11M01D01H/00M00S")):
            epoch = int(datetime.datetime.fromisoformat(utc).timestamp())
            code = f'TZ="$(recording_timezone)" date -d "@{epoch}" +%YY%mM%dD%HH/%MM%SS'
            self.assertEqual(self.shell(code), expected)

    def test_signed_fractional_offsets(self):
        for zone, instant, expected in ((EASTERN, "2026-01-15", -18000),
                                        (EASTERN, "2026-07-15", -14400),
                                        ("NST3:30NDT,M3.2.0,M11.1.0", "2026-01-15", -12600),
                                        ("IST-5:30", "2026-01-15", 19800),
                                        ("<+0545>-5:45", "2026-01-15", 20700)):
            self.configure(zone=zone)
            code = 'date() { command date -d "$TEST_TIME" "$@"; }\ntimezone_offset_seconds'
            self.assertEqual(int(self.shell(code, TEST_TIME=instant)), expected)

    def test_live_apply_preserves_cron_and_restarts_only_recorder(self):
        log, state, cron = (self.prefix / name for name in ("log", "state", "cron"))
        cron.write_text('0 * * * * clean_records\n1 * * * * /tmp/sd/yi-hack/script/update_osd_tz.sh\n')
        (self.prefix / "script/update_osd_tz.sh").write_text('#!/bin/sh\necho osd >> "$TEST_LOG"\n')
        service = self.prefix / "script/service.sh"
        service.write_text('''#!/bin/sh
case "$2" in
    status) cat "$TEST_STATE" ;;
    stop) echo "recorder stop" >> "$TEST_LOG"; echo stopped > "$TEST_STATE" ;;
    start) echo "recorder start" >> "$TEST_LOG"; echo started > "$TEST_STATE" ;;
esac
''')
        for name in ("update_osd_tz.sh", "service.sh"):
            (self.prefix / "script" / name).chmod(0o755)
        state.write_text("started\n")
        env = {**self.env, "TIME_CRON": str(cron), "TEST_LOG": str(log), "TEST_STATE": str(state)}
        for _ in range(2):
            subprocess.run(["sh", str(self.prefix / "script/apply_time.sh")], env=env, check=True)
        self.assertEqual(log.read_text().splitlines(), ["osd", "recorder stop", "recorder start"] * 2)
        self.assertEqual(cron.read_text().splitlines(), ['0 * * * * clean_records',
                         '* * * * * /tmp/sd/yi-hack/script/update_osd_tz.sh'])

    def test_osd_offset_uses_audited_model_on_firmware_12(self):
        mmap = self.prefix / "mmap.info"
        binary = self.prefix / "bin/set_tz_offset"
        source = ROOT / "src/set_tz_offset/set_tz_offset/set_tz_offset.c"
        subprocess.run(["cc", "-Os", f'-DMMAP_INFO="{mmap}"', str(source), "-lrt", "-o", str(binary)],
                       capture_output=True, text=True, check=True)
        for model, firmware, offset in (("y623", "12", 0x570), ("y28ga", "9", 0x4e0),
                                        ("y21ga", "12", 0x564)):
            original = bytes(0x600)
            mmap.write_bytes(original)
            subprocess.run([str(binary), "-c", "tz_offset_osd", "-m", model, "-f", firmware,
                            "-v", "-14400"], check=True, capture_output=True)
            expected = bytearray(original)
            struct.pack_into("<i", expected, offset, -14400)
            self.assertEqual(mmap.read_bytes(), expected)


if __name__ == "__main__":
    unittest.main()
