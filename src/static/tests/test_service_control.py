#!/usr/bin/env python3
"""Exercise production lifecycle routing with isolated daemon/process stubs."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'src/static/static/yi-hack/script'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')

class ServiceControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='service-controls-')
        cls.guard = Path(cls.tmp.name) / 'guard'
        subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'src/service_guard/service_guard.c'), '-o', str(cls.guard)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.prefix = Path(self.tmpdir.name)
        for part in ['bin', 'script', 'etc']:
            (self.prefix / part).mkdir()
        (self.prefix / 'bin/busybox').symlink_to(shutil.which(BUSYBOX))
        (self.prefix / 'bin/service_guard').symlink_to(self.guard)
        for name in ['service_lock.sh', 'time_config.sh']:
            shutil.copyfile(SCRIPTS / name, self.prefix / 'script' / name)
        (self.prefix / 'etc/system.conf').write_text('MQTT=yes\n')
        self.state = self.prefix / 'state'
        # A script mentioning mqttv4 must not count as the daemon itself.
        self.state.write_text('11 root 100 S /bin/sh service.sh mqttv4 start\n')
        self.calls = self.prefix / 'calls'
        self.calls.touch()
        source = (SCRIPTS / 'service.sh').read_text()
        source = source.replace('/tmp/sd/yi-hack', str(self.prefix))
        a = source.index('HOMEVER=')
        b = source.index('get_config()', a)
        source = source[:a] + 'HV=12\nMODEL_SUFFIX=y623\n' + source[b:]
        mocks = '''
init_config() { RTSP_DAEMON=rRTSPServer; }
ps() { cat "$TEST_STATE"; }
mqttv4() {
    echo launch >> "$TEST_CALLS"
    sleep 0.3
    echo '22 root 100 S mqttv4' > "$TEST_STATE"
}
killall() { : > "$TEST_STATE"; }
'''
        source = source.replace('NAME="null"', mocks + '\nNAME="null"', 1)
        self.script = self.prefix / 'script/service.sh'
        self.script.write_text(source)
        self.env = dict(os.environ, TEST_STATE=str(self.state), TEST_CALLS=str(self.calls))

    def call(self, *args):
        return subprocess.run([BUSYBOX, 'ash', str(self.script), *args], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def test_concurrent_start_then_repeated_start_is_singleton(self):
        p = subprocess.Popen([BUSYBOX, 'ash', str(self.script), 'mqtt', 'start'],
                             env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 2
            while not self.calls.read_text() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.calls.read_text())
            self.assertEqual(self.call('mqtt', 'start').returncode, 75)
            out, err = p.communicate(timeout=5)
            self.assertEqual(p.returncode, 0, err)
            self.assertEqual(self.call('mqtt', 'start').returncode, 0)
            self.assertEqual(self.calls.read_text().splitlines(), ['launch'])
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdout.close(); p.stderr.close()

    def test_old_busybox_fails_closed_without_reexec_loop(self):
        stock = shutil.which('busybox')
        if subprocess.run([stock, 'ash', '-c', 'command -v yi_lock'], capture_output=True).returncode == 0:
            self.skipTest('stock BusyBox is also patched')
        binary = self.prefix / 'bin/busybox'
        binary.unlink()
        binary.symlink_to(stock)
        body = f'YI_HACK_PREFIX="{self.prefix}"; . "$YI_HACK_PREFIX/script/service_lock.sh"; echo unsafe'
        result = subprocess.run(['/bin/sh', '-c', body], capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('unsafe', result.stdout)
        self.assertIn('requires the rebuilt BusyBox', result.stderr)

    def test_stop_observes_exit_before_next_start(self):
        self.state.write_text('22 root 100 S mqttv4\n')
        self.assertEqual(self.call('mqtt', 'stop').returncode, 0)
        self.assertEqual(self.call('mqtt', 'status').stdout.strip(), 'stopped')
        self.assertEqual(self.call('mqtt', 'start').returncode, 0)
        self.assertEqual(self.call('mqtt', 'status').stdout.strip(), 'started')

    def test_missing_pure_ftpd_uses_busybox_for_start_status_and_stop(self):
        with (self.prefix / 'etc/system.conf').open('a') as config:
            config.write('BUSYBOX_FTPD=no\n')
        source = self.script.read_text().replace('NAME="null"', '''
tcpsvd() {
    echo ftp >> "$TEST_CALLS"
    echo '22 root 100 S tcpsvd' > "$TEST_STATE"
}
NAME="null"''', 1)
        self.script.write_text(source)
        self.assertEqual(self.call('ftpd', 'start').returncode, 0)
        self.assertEqual(self.call('ftpd', 'status').stdout.strip(), 'started')
        self.assertEqual(self.calls.read_text().splitlines(), ['ftp'])
        self.assertEqual(self.call('ftpd', 'stop').returncode, 0)
        self.assertEqual(self.call('ftpd', 'status').stdout.strip(), 'stopped')

    def test_wifi_recovery_is_nonblocking_serialized_and_retryable(self):
        worker = self.prefix / 'script/wifi_recovery.sh'
        worker.write_text(f'#!{self.prefix}/bin/busybox ash\n'
                          'yi_lock wifi-recovery || exit $?\necho worker >> "$TEST_CALLS"\n'
                          'trap "" TERM\nsleep 30\n')
        worker.chmod(0o755)
        source = (SCRIPTS / 'wd.sh').read_text()
        function = re.search(r'^soft_wifi_reconnect\(\)\n\{.*?^\}', source, re.M | re.S).group()
        function = function.replace('service_guard" 35', 'service_guard" 1')
        body = f'YI_HACK_PREFIX="{self.prefix}"; ' + function + '\nsoft_wifi_reconnect; soft_wifi_reconnect'
        started = time.monotonic()
        result = subprocess.run([BUSYBOX, 'ash', '-c', body], env=self.env,
                                capture_output=True, text=True, timeout=2)
        self.assertEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 1)
        time.sleep(0.3)
        self.assertEqual(self.calls.read_text().splitlines(), ['worker'])
        time.sleep(2)
        subprocess.run([BUSYBOX, 'ash', '-c', body], env=self.env, check=True, timeout=2)
        time.sleep(0.3)
        self.assertEqual(self.calls.read_text().splitlines(), ['worker', 'worker'])
        # Let the bounded workers finish before removing their fixture.
        time.sleep(2)

    def test_stop_request_cannot_clear_an_active_jobs_ownership(self):
        main = (SCRIPTS / 'ftppush.sh').read_text().split('trap "" SIGHUP', 1)[1]
        stopfile = self.prefix / 'stop'
        setup = f'''YI_HACK_PREFIX="{self.prefix}"
STOPFILE="{stopfile}"
logAdd() {{ echo "$*"; }}
serviceMain() {{ echo ready; sleep 0.5; }}
'''
        runner = self.prefix / 'job.sh'
        runner.write_text(setup + main)
        p = subprocess.Popen([BUSYBOX, 'ash', str(runner), 'cron'], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(p.stdout.readline(), 'ready\n')
            stopped = subprocess.run([BUSYBOX, 'ash', str(runner), 'stop'], capture_output=True, text=True, timeout=2)
            self.assertIn('Stop requested', stopped.stdout)
            started = subprocess.run([BUSYBOX, 'ash', str(runner), 'start'], capture_output=True, text=True, timeout=2)
            self.assertIn('ALREADY RUNNING', started.stdout)
            self.assertTrue(stopfile.exists())
            p.wait(timeout=2)
        finally:
            if p.poll() is None: p.kill(); p.wait()
            p.stdout.close()

if __name__ == '__main__':
    unittest.main()
