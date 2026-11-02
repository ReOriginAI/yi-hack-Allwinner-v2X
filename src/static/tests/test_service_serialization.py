#!/usr/bin/env python3
"""Run with YI_TEST_BUSYBOX pointing to BusyBox built with yi-lock.patch."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
import uuid
import time

BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')
ROOT = Path(__file__).resolve().parents[3]

class LockTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if subprocess.run([BUSYBOX, 'ash', '-c', 'command -v yi_lock'], capture_output=True).returncode:
            raise RuntimeError('Build patched BusyBox and set YI_TEST_BUSYBOX; refusing to test stock ash')

    def setUp(self):
        self.name = 'test.' + uuid.uuid4().hex

    def run_shell(self, script):
        return subprocess.run([BUSYBOX, 'ash', '-c', script], capture_output=True, text=True, timeout=5)

    def holder(self):
        p = subprocess.Popen([BUSYBOX, 'ash', '-c', f'yi_lock {self.name} || exit $?; echo ready; read release'],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: self.reap(p))
        self.assertEqual(p.stdout.readline(), 'ready\n')
        return p

    @staticmethod
    def reap(p):
        if p.poll() is None:
            p.kill()
        p.wait()
        if p.stdin: p.stdin.close()
        if p.stdout: p.stdout.close()

    def test_atomic_contention_and_kill_recovery(self):
        p = self.holder()
        competitors = [subprocess.Popen([BUSYBOX, 'ash', '-c', f'yi_lock {self.name}']) for _ in range(12)]
        self.assertEqual([q.wait(timeout=3) for q in competitors], [75] * 12)
        p.kill()
        p.wait(timeout=3)
        self.assertEqual(self.run_shell(f'yi_lock {self.name}').returncode, 0)

    def test_normal_exit_and_explicit_release(self):
        for _ in range(3):
            self.assertEqual(self.run_shell(f'yi_lock {self.name}; yi_lock -u {self.name}').returncode, 0)
        self.assertEqual(self.run_shell(f'yi_lock {self.name}; yi_lock {self.name}').returncode, 75)

    def test_background_daemon_does_not_keep_lifecycle_lock(self):
        result = self.run_shell(f'yi_lock {self.name}; sleep 20 >/dev/null 2>&1 & echo $!')
        pid = int(result.stdout.strip())
        try:
            self.assertEqual(self.run_shell(f'yi_lock {self.name}').returncode, 0)
        finally:
            os.kill(pid, signal.SIGKILL)

    def test_foreground_pipeline_keeps_lock_after_parent_kill(self):
        p = subprocess.Popen([BUSYBOX, 'ash', '-c', f'yi_lock {self.name}; echo clip | while read clip; do echo ready; sleep 1; done'],
                             stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: self.reap(p))
        self.assertEqual(p.stdout.readline(), 'ready\n')
        p.kill()
        p.wait(timeout=3)
        self.assertEqual(self.run_shell(f'yi_lock {self.name}').returncode, 75)
        time.sleep(1.2)
        self.assertEqual(self.run_shell(f'yi_lock {self.name}').returncode, 0)

    def test_last_external_command_keeps_lock(self):
        p = subprocess.Popen([BUSYBOX, 'ash', '-c', f'yi_lock {self.name}; echo ready; sleep 1'],
                             stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: self.reap(p))
        self.assertEqual(p.stdout.readline(), 'ready\n')
        self.assertEqual(self.run_shell(f'yi_lock {self.name}').returncode, 75)
        p.wait(timeout=3)
        self.assertEqual(self.run_shell(f'yi_lock {self.name}').returncode, 0)

    def test_redirects_and_command_substitutions_preserve_lock(self):
        # Includes descriptor collisions with internal script/lock descriptors.
        result = self.run_shell(f'yi_lock {self.name}; exec 10>&- 11>&- 12>&- 13>&-; x=$(echo ok); '
                                f'yi_lock {self.name}; status=$?; yi_lock -u {self.name}; exit "$status"')
        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertEqual(self.run_shell('yi_lock "bad/name"').returncode, 2)

class RecoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='service-guard-')
        cls.binary = Path(cls.tmp.name) / 'guard'
        subprocess.run(['cc', '-std=c99', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'src/service_guard/service_guard.c'), '-o', str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_exit_status_and_timeout(self):
        self.assertEqual(subprocess.run([str(self.binary), '2', '/bin/sh', '-c', 'exit 7']).returncode, 7)
        started = time.monotonic()
        result = subprocess.run([str(self.binary), '1', '/bin/sh', '-c', 'trap "" TERM; sleep 30 & wait'], timeout=5)
        self.assertEqual(result.returncode, 124)
        self.assertLess(time.monotonic() - started, 4)

    def test_timeout_releases_lock_and_kills_worker_descendants(self):
        name = 'test.' + uuid.uuid4().hex
        marker = Path(self.tmp.name) / 'pid'
        p = subprocess.run([str(self.binary), '1', BUSYBOX, 'ash', '-c',
            f'yi_lock {name}; (trap "" TERM; echo "$BASHPID" > /dev/null; sleep 30) & echo $! > "{marker}"; wait'], timeout=5)
        self.assertEqual(p.returncode, 124)
        pid = marker.read_text().strip()
        stat = Path('/proc') / pid / 'stat'
        self.assertTrue(not stat.exists() or stat.read_text().split()[2] == 'Z')
        self.assertEqual(subprocess.run([BUSYBOX, 'ash', '-c', f'yi_lock {name}']).returncode, 0)

if __name__ == '__main__':
    unittest.main()
