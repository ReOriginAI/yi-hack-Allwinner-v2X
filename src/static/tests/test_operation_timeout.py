#!/usr/bin/env python3
"""Exercise timeouts with BusyBox ash and real stalled local FTP connections."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1] / 'static/yi-hack/script'


class OperationTimeoutTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ftp-timeout-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'bin').mkdir()
        (self.root / 'bin/busybox').symlink_to(shutil.which('busybox'))
        self.env = dict(os.environ, YI_HACK_PREFIX=str(self.root), ROOT=str(self.root))

    def run_shell(self, body, stdin=None):
        return subprocess.run(['busybox', 'ash', '-c',
            '. "$1"; logAdd() { echo "$*" >> "$ROOT/log"; }; ' + body,
            'test', str(SCRIPTS / 'operation_timeout.sh')], env=self.env,
            input=stdin, text=True, capture_output=True, timeout=8)

    def test_preserves_stdin_and_exit_status(self):
        result = self.run_shell('runWithTimeout 2 cat', 'FTP commands\r\n')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'FTP commands\n')
        result = self.run_shell("runWithTimeout 2 sh -c 'exit 7'")
        self.assertEqual(result.returncode, 7)

    def test_kills_command_even_if_it_ignores_term(self):
        result = self.run_shell('runWithTimeout 1 busybox ash -c \'echo $$ > "$ROOT/pid"; trap "" TERM; exec sleep 30\'')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(Path('/proc/' + (self.root / 'pid').read_text().strip()).exists())
        self.assertIn('timed out', (self.root / 'log').read_text())

    def test_stalled_ftp_greeting_does_not_block_next_upload(self):
        # The first server accepts TCP but never sends an FTP greeting.
        # The production queue must retain that clip and continue to the next.
        with socket.socket() as server:
            server.bind(('127.0.0.1', 0))
            server.listen()
            port = server.getsockname()[1]
            disconnected = threading.Event()

            def peer():
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(6)
                    if conn.recv(1) == b'':
                        disconnected.set()

            worker = threading.Thread(target=peer, daemon=True)
            worker.start()
            record = self.root / 'record'
            record.mkdir()
            (record / 'stuck.mp4').write_text('stuck')
            (record / 'healthy.mp4').write_text('healthy')
            body = r'''
. "$ROOT/queue.sh"
FOLDER_TO_WATCH="$ROOT/record"
FOLDER_MINDEPTH=1
FILE_WATCH_PATTERN='*.mp4'
get_config() {
    case "$1" in
    FTP_FILE_DELETE_AFTER_UPLOAD) echo yes;;
    FTP_HOST) echo local-test;;
    esac
}
sync() { :; }
uploadToFtp() {
    case "$2" in
    */stuck.mp4) runWithTimeout 1 busybox ftpput -P PORT 127.0.0.1 remote "$2";;
    *) return 0;;
    esac
}
checkFiles
'''.replace('PORT', str(port))
            shutil.copyfile(SCRIPTS / 'ftppush_queue.sh', self.root / 'queue.sh')
            started = time.monotonic()
            result = self.run_shell(body)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(time.monotonic() - started, 5)
            worker.join(2)
            self.assertTrue(disconnected.is_set())
            self.assertTrue((record / 'stuck.mp4').exists())
            self.assertFalse((record / 'stuck.mp4.ftp-uploaded').exists())
            self.assertFalse((record / 'healthy.mp4').exists())

    def test_stalled_ftp_final_reply_is_bounded(self):
        with socket.socket() as control, socket.socket() as data:
            control.bind(('127.0.0.1', 0))
            control.listen()
            data.bind(('127.0.0.1', 0))
            data.listen()
            payload = []
            disconnected = threading.Event()
            def peer():
                conn, _ = control.accept()
                with conn:
                    conn.settimeout(6)
                    reader = conn.makefile('rb')
                    conn.sendall(b'220 test\r\n')
                    while True:
                        line = reader.readline()
                        if not line:
                            disconnected.set()
                            break
                        verb = line.split()[0]
                        if verb == b'USER':
                            reply = b'230 logged in\r\n'
                        elif verb == b'TYPE':
                            reply = b'200 binary\r\n'
                        elif verb == b'EPSV':
                            reply = ('229 Entering Extended Passive Mode (|||%d|)\r\n' % data.getsockname()[1]).encode()
                        elif verb == b'PASV':
                            port = data.getsockname()[1]
                            reply = ('227 Entering Passive Mode (127,0,0,1,%d,%d)\r\n' % (port // 256, port % 256)).encode()
                        elif verb == b'STOR':
                            conn.sendall(b'150 send data\r\n')
                            stream, _ = data.accept()
                            with stream:
                                stream.settimeout(6)
                                chunks = []
                                while chunk := stream.recv(4096):
                                    chunks.append(chunk)
                                payload.append(b''.join(chunks))
                            # Deliberately withhold the final 226 response.
                            continue
                        else:
                            reply = b'200 OK\r\n'
                        conn.sendall(reply)
            worker = threading.Thread(target=peer, daemon=True)
            worker.start()
            clip = self.root / 'clip.mp4'
            clip.write_bytes(b'video')
            result = self.run_shell(f'runWithTimeout 1 busybox ftpput -P {control.getsockname()[1]} 127.0.0.1 remote "$ROOT/clip.mp4"')
            self.assertNotEqual(result.returncode, 0)
            worker.join(2)
            self.assertEqual(payload, [b'video'])
            self.assertTrue(disconnected.is_set())

    def test_cleanup_stops_after_failed_removal(self):
        # Both cleanup loops used to retry the same undeletable path forever.
        for kind in ('avi', 'directory'):
            with self.subTest(kind=kind):
                record = self.root / 'record'
                record.mkdir(exist_ok=True)
                if kind == 'avi':
                    directory = record / 'timelapse'
                    directory.mkdir()
                    for i in range(11):
                        (directory / f'{i}.avi').touch()
                else:
                    (record / 'old-hour').mkdir()
                source = (SCRIPTS / 'clean_records.sh').read_text()
                source = source.replace('/tmp/sd/record', str(record))
                body = 'rm() { return 1; }; df() { echo "mmc 100 100 0 100% /tmp/sd"; }; set -- 10; ' + source
                result = self.run_shell(body)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('stopping cleanup', result.stderr)
                shutil.rmtree(record)

    def test_partial_timelapse_capture_is_never_uploaded(self):
        main = (SCRIPTS / 'time_lapse.sh').read_text().split(
            'logAdd "[INFO] === STARTING TIME_LAPSE.SH ==="', 1)[1]
        main = main.replace('/tmp/sd/record', str(self.root / 'record'))
        for model in ('y623', 'y28ga'):
            with self.subTest(model=model):
                body = r''' 
FOLDER_TO_SAVE="$ROOT/images"
get_config() { case "$1" in SNAPSHOT_LOW) echo no;; TIMEZONE) echo UTC;; esac; }
runWithTimeout() { echo partial-jpeg; return 137; }
uploadToFtp() { touch "$ROOT/upload-called"; }
set -- yes
''' + 'MODEL_SUFFIX=' + model + '; ' + main
                self.assertEqual(self.run_shell(body).returncode, 1)
                self.assertFalse((self.root / 'upload-called').exists())
                self.assertEqual(list((self.root / 'images').glob('*.jpg')), [])

    def test_stalled_established_nc_connection_is_bounded(self):
        with socket.socket() as server:
            server.bind(('127.0.0.1', 0))
            server.listen()
            port = server.getsockname()[1]
            received = []
            def peer():
                conn, _ = server.accept()
                with conn:
                    conn.settimeout(6)
                    received.append(conn.recv(1024))
                    while conn.recv(1024):
                        pass
            worker = threading.Thread(target=peer, daemon=True)
            worker.start()
            result = self.run_shell(f"(printf 'USER test\\r\\n'; sleep 2) | runWithTimeout 1 busybox nc -w 5 127.0.0.1 {port}")
            self.assertNotEqual(result.returncode, 0)
            worker.join(2)
            self.assertEqual(received, [b'USER test\r\n'])


if __name__ == '__main__':
    unittest.main()
