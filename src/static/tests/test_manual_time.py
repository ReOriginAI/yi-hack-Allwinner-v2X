#!/usr/bin/env python3
"""Offline clock API and boot restore; the host clock and NTP are never touched."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = ROOT / 'src/static/static/yi-hack/script'
BUSYBOX = os.environ.get('YI_TEST_BUSYBOX', 'busybox')


class ManualTimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='yi-clock-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('etc', 'script', 'bin', 'www/cgi-bin'):
            (self.root / name).mkdir(parents=True)
        for name in ('manual_time.sh', 'service_lock.sh'):
            shutil.copy2(SCRIPTS / name, self.root / 'script' / name)
        shutil.copy2(ROOT / 'src/www/httpd/cgi-bin/clock.sh', self.root / 'www/cgi-bin/clock.sh')
        (self.root / 'bin/busybox').symlink_to(shutil.which(BUSYBOX))
        self.conf = self.root / 'etc/system.conf'
        self.conf.write_text('NTPD=yes\nMANUAL_TIME_EPOCH=\nTIMEZONE=EST5EDT\nPASSWORD=fixture-secret\n')
        self.state, self.log = self.root / 'clock', self.root / 'calls'
        self.state.write_text('1577836800\n')
        commands = {
            'date': '''#!/bin/sh
if [ "$2" = -s ]; then
    echo "date $3" >> "$TEST_LOG"
    [ "${TEST_DATE_FAIL:-no}" != yes ] || exit 1
    printf '%s\\n' "${3#@}" > "$TEST_CLOCK"
elif [ "$2" = +%s ]; then
    cat "$TEST_CLOCK"
else
    /usr/bin/date -u -d "@$(cat "$TEST_CLOCK")" "$2"
fi
''',
            'killall': '#!/bin/sh\necho "killall $*" >> "$TEST_LOG"\n',
            'service_guard': '#!/bin/sh\nshift\nexec "$@"\n',
        }
        for name, code in commands.items():
            path = self.root / 'bin' / name
            path.write_text(code)
            path.chmod(0o755)
        osd = self.root / 'script/update_osd_tz.sh'
        osd.write_text('#!/bin/sh\necho osd >> "$TEST_LOG"\n')
        osd.chmod(0o755)
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), TEST_CLOCK=str(self.state),
                        TEST_LOG=str(self.log), PATH=str(self.root / 'bin') + ':' + os.environ['PATH'])

    def api(self, method='GET', payload=None, body=None, length=None, **env):
        if body is None:
            body = '' if payload is None else json.dumps(payload)
        result = subprocess.run([BUSYBOX, 'ash', str(self.root / 'www/cgi-bin/clock.sh')],
            input=body, text=True, capture_output=True, timeout=5,
            env=dict(self.env, REQUEST_METHOD=method, CONTENT_LENGTH=str(len(body) if length is None else length), **env))
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout.split('\n\n', 1)[1])

    def restore(self):
        subprocess.run([BUSYBOX, 'ash', str(self.root / 'script/manual_time.sh'), 'restore'],
                       env=self.env, check=True, timeout=5)

    def test_get_reads_without_changing_clock_or_settings(self):
        before = self.conf.read_bytes()
        data = self.api()
        self.assertEqual(data['epoch'], 1577836800)
        self.assertTrue(data['ntp_enabled'])
        self.assertEqual(data['utc'], '2020-01-01T00:00:00Z')
        self.assertEqual(self.conf.read_bytes(), before)
        self.assertFalse(self.log.exists())

    def test_manual_set_disables_ntp_saves_floor_and_preserves_other_settings(self):
        data = self.api('POST', {'epoch': 1793635200})
        self.assertFalse(data['error'])
        self.assertEqual(data['epoch'], 1793635200)
        self.assertFalse(data['ntp_enabled'])
        self.assertIn('MANUAL_TIME_EPOCH=1793635200\n', self.conf.read_text())
        self.assertIn('PASSWORD=fixture-secret\n', self.conf.read_text())
        self.assertEqual(self.conf.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.log.read_text().splitlines(), ['killall ntpd', 'date @1793635200', 'osd'])
        self.assertFalse(list((self.root / 'etc').glob('*.clock.*')))

    def test_invalid_input_never_changes_settings_or_clock(self):
        before = self.conf.read_bytes()
        for body in ('not-json', '{}', '[]', '{"epoch":"1793635200"}',
                     '{"epoch":1793635200.1}', '{"epoch":1577836799}',
                     '{"epoch":2145916800}', '{"epoch":1e99}'):
            with self.subTest(body=body):
                self.assertTrue(self.api('POST', body=body)['error'])
                self.assertEqual(self.conf.read_bytes(), before)
                self.assertFalse(self.log.exists())
        for method, length in [('DELETE', 0), ('POST', 513), ('POST', -1), ('POST', 'bad')]:
            self.assertTrue(self.api(method, body='{}', length=length)['error'])
        self.assertEqual(self.conf.read_bytes(), before)

    def test_boot_restore_is_a_floor_and_is_ignored_when_ntp_is_enabled(self):
        self.conf.write_text('NTPD=yes\nMANUAL_TIME_EPOCH=1793635200\n')
        self.restore()
        self.assertFalse(self.log.exists())
        self.conf.write_text('NTPD=no\nMANUAL_TIME_EPOCH=1793635200\n')
        self.restore()
        self.assertEqual(self.state.read_text().strip(), '1793635200')
        self.state.write_text('1793635300\n')
        self.restore()
        self.assertEqual(self.state.read_text().strip(), '1793635300')
        self.assertEqual(self.log.read_text().splitlines(), ['date @1793635200', 'osd'])

    def test_clock_failure_is_reported_to_the_client(self):
        self.assertTrue(self.api('POST', {'epoch': 1793635200}, TEST_DATE_FAIL='yes')['error'])
        self.assertEqual(self.state.read_text().strip(), '1577836800')


if __name__ == '__main__':
    unittest.main()
