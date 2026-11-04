#!/usr/bin/env python3
"""Fetch checksum-pinned snapshot sources, with bounded retries and atomic cache writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

MANIFEST = Path(__file__).resolve().parents[1] / 'src/snapshot/sources.json'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def fetch(destination, archives):
    allowed = {archive['sha256'] for archive in archives}
    if destination.is_file() and digest(destination) in allowed:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    for archive in archives:
        for url in archive['urls']:
            fd, name = tempfile.mkstemp(prefix=destination.name + '.', suffix='.part', dir=destination.parent)
            os.close(fd)
            partial = Path(name)
            try:
                print('Fetching ' + url, file=sys.stderr)
                subprocess.run(['wget', '--no-verbose', '--timeout=20', '--tries=2',
                                '--waitretry=2', '--max-redirect=5', '-O', str(partial), url],
                               check=True, timeout=90)
                if digest(partial) != archive['sha256']:
                    print('Source checksum mismatch: ' + url, file=sys.stderr)
                    continue
                os.replace(partial, destination)
                return
            except (subprocess.SubprocessError, OSError) as error:
                print('Source download failed: ' + str(error), file=sys.stderr)
            finally:
                partial.unlink(missing_ok=True)
    # Do not leave an invalid old cache available to another build attempt.
    destination.unlink(missing_ok=True)
    raise RuntimeError('All verified source downloads failed: ' + destination.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('component', choices=('ffmpeg', 'jpeg'))
    parser.add_argument('version')
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    source = json.loads(MANIFEST.read_text())[args.component]
    if source['version'] != args.version:
        parser.error('Makefile version differs from pinned source manifest')
    fetch(args.destination, source['archives'])


if __name__ == '__main__':
    main()
