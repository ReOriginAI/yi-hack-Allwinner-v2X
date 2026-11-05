#!/usr/bin/env python3
"""Check SFTP v3 negotiation and file I/O against an isolated ARM server command."""
import argparse
import selectors
import struct
import subprocess
import tempfile


def string(data):
    return struct.pack('>I', len(data)) + data


def check(command):
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def read(count):
            data = b''
            while len(data) < count:
                if not selector.select(timeout=5):
                    raise RuntimeError('SFTP reply timed out')
                # Unbuffered reads prevent a buffered packet body hiding from select().
                import os
                chunk = os.read(process.stdout.fileno(), count - len(data))
                if not chunk:
                    raise RuntimeError('SFTP server exited before replying')
                data += chunk
            return data

        def request(packet):
            process.stdin.write(struct.pack('>I', len(packet)) + packet)
            process.stdin.flush()
            size, = struct.unpack('>I', read(4))
            if not 1 <= size <= 1048576:
                raise RuntimeError('invalid SFTP packet size')
            return read(size)

        def status(packet, identifier):
            reply = request(packet)
            assert reply[:9] == struct.pack('>BII', 101, identifier, 0), reply

        try:
            version = request(struct.pack('>BI', 1, 3))
            assert version[:5] == struct.pack('>BI', 2, 3), version
            path = b'/tmp/sftp-image-check'
            opened = request(struct.pack('>BI', 3, 1) + string(path) + struct.pack('>II', 27, 0))
            assert opened[:5] == struct.pack('>BI', 102, 1), opened
            length, = struct.unpack('>I', opened[5:9])
            handle = opened[9:9 + length]
            payload = b'camera SFTP read/write check\n'
            status(struct.pack('>BI', 6, 2) + string(handle) + struct.pack('>Q', 0) + string(payload), 2)
            reply = request(struct.pack('>BI', 5, 3) + string(handle) + struct.pack('>QI', 0, 4096))
            assert reply == struct.pack('>BI', 103, 3) + string(payload), reply
            status(struct.pack('>BI', 4, 4) + string(handle), 4)
            status(struct.pack('>BI', 13, 5) + string(path), 5)
            process.stdin.close()
            assert process.wait(timeout=5) == 0
        except Exception as error:
            errors.seek(0)
            raise RuntimeError(str(error) + '\n' + errors.read().decode(errors='replace')) from error
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            if not process.stdin.closed:
                process.stdin.close()
    print('PASS: SFTP v3 file create/write/read/close/remove without SD')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.command:
        parser.error('an isolated server command is required')
    check(args.command)
