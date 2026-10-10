#!/usr/bin/env python3
"""Host regressions for RTSP engine changes and advertised audio endpoints."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CGI = ROOT / "src/www/httpd/cgi-bin"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.prefix = Path(self.temp.name)
        for path in ("etc", "bin", "script", "www/cgi-bin"):
            (self.prefix / path).mkdir(parents=True)
        self.conf = self.prefix / "etc/system.conf"
        shutil.copy(ROOT / "src/static/static/yi-hack/etc/system.conf", self.conf)
        shutil.copy(CGI / "validate.sh", self.prefix / "www/cgi-bin")
        self.log = self.prefix / "services.log"
        self.log.touch()
        for name in ("service.sh", "rtsp_stream_venc.sh"):
            script = self.prefix / "script" / name
            script.write_text('#!/bin/sh\nprintf "%s %s\\n" "$1" "$2" >>"$TEST_SERVICE_LOG"\n')
            script.chmod(0o755)
        for name in ("tts", "speaker", "go2rtc"):
            binary = self.prefix / "bin" / name
            binary.touch()
            binary.chmod(0o755)
        self.env = {**os.environ, "YI_HACK_PREFIX": str(self.prefix),
                    "LOCAL_IP": "198.51.100.12", "QUERY_STRING": "conf=system",
                    "TEST_SERVICE_LOG": str(self.log)}

    def configure(self, **changes):
        values = dict(line.split("=", 1) for line in self.conf.read_text().splitlines())
        values.update(changes)
        self.conf.write_text("".join(f"{key}={value}\n" for key, value in values.items()))

    def cgi(self, name, body=""):
        result = subprocess.run(["busybox", "ash", str(CGI / name)], env=self.env,
                                input=body + "\n", text=True, capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout.split("\n\n", 1)[1])

    def test_standard_endpoints_without_onvif(self):
        self.configure(RTSP_BACKCHANNEL="G711", ONVIF="no")
        links = self.cgi("links.sh")
        self.assertEqual(links["high_res_backchannel"],
                         "rtsp://198.51.100.12:554/ch0_0.h264?backchannel=1")
        self.assertIn("audio_stream", links)
        self.assertNotIn("low_res_stream", links)
        self.assertIn("/cgi-bin/tts.sh?voice=", links["tts"])

    def test_both_streams_custom_ports(self):
        self.configure(RTSP_STREAM="both", RTSP_BACKCHANNEL="G711", RTSP_PORT="8554", HTTPD_PORT="8080")
        links = self.cgi("links.sh")
        self.assertEqual(links["low_res_backchannel"],
                         "rtsp://198.51.100.12:8554/ch0_1.h264?backchannel=1")
        self.assertEqual(links["audio_page"], "http://198.51.100.12:8080/?page=audio")

    def test_go2rtc_does_not_advertise_missing_audio_only_endpoint(self):
        self.configure(RTSP_ALT="go2rtc", RTSP_STREAM="both", RTSP_BACKCHANNEL="G711")
        links = self.cgi("links.sh")
        self.assertNotIn("audio_stream", links)
        self.assertIn("low_res_backchannel", links)
        (self.prefix / "bin/go2rtc").unlink()
        self.assertIn("audio_stream", self.cgi("links.sh"))

    def test_disabled_speaker_or_rtsp(self):
        self.configure(RTSP_BACKCHANNEL="G711", SPEAKER_AUDIO="no")
        links = self.cgi("links.sh")
        self.assertNotIn("high_res_backchannel", links)
        self.assertIn("tts", links)
        self.configure(RTSP="no")
        links = self.cgi("links.sh")
        self.assertNotIn("high_res_stream", links)
        self.assertNotIn("audio_stream", links)

    def test_engine_switch_applies_once(self):
        self.configure(RTSP_ALT="go2rtc")
        response = self.cgi("set_configs.sh", json.dumps({"RTSP_ALT": "standard"}))
        self.assertEqual(response["error"], "false")
        self.assertEqual(self.log.read_text().splitlines(),
                         ["rtsp stop", "rtsp start", "onvif stop", "onvif start"])
        self.log.write_text("")
        self.cgi("set_configs.sh", json.dumps({"RTSP_ALT": "standard"}))
        self.assertEqual(self.log.read_text(), "")

    def test_audio_and_backchannel_changes_without_onvif(self):
        self.configure(ONVIF="no")
        self.cgi("set_configs.sh", json.dumps({"RTSP_AUDIO": "ulaw", "RTSP_BACKCHANNEL": "G711"}))
        self.assertEqual(self.log.read_text().splitlines(), ["rtsp stop", "rtsp start"])
        self.assertIn("ONVIF_AUDIO_BC=G711\n", self.conf.read_text())

    def test_disabling_rtsp_stops_previous_server(self):
        self.cgi("set_configs.sh", json.dumps({"RTSP": "no"}))
        self.assertEqual(self.log.read_text().splitlines(), ["rtsp stop", "onvif stop", "onvif start"])


if __name__ == "__main__":
    unittest.main()
