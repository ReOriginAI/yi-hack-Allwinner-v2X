#!/bin/bash
# Build the real lock builtin for host regression tests, outside the repository.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEST_BUILD=${1:?usage: build_test_busybox.sh OUTPUT_DIRECTORY}
mkdir -p "$TEST_BUILD"
TEST_BUILD=$(cd "$TEST_BUILD" && pwd)
python3 - "$TEST_BUILD" <<'PY'
import hashlib, pathlib, sys, urllib.request, tarfile
root = pathlib.Path(sys.argv[1])
archive = root / 'busybox-1.36.1.tar.bz2'
if not archive.exists():
    urllib.request.urlretrieve('https://busybox.net/downloads/busybox-1.36.1.tar.bz2', archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == 'b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314'
if not (root / 'busybox-1.36.1').exists():
    with tarfile.open(archive) as source:
        source.extractall(root)
PY
cd "$TEST_BUILD/busybox-1.36.1"
if ! grep -q 'static int FAST_FUNC yi_lockcmd' shell/ash.c; then
    patch -p1 < "$REPO_ROOT/src/busybox/yi-lock.patch"
fi
cp "$REPO_ROOT/src/busybox/.config" .config
# TC's obsolete CBQ structures are absent from recent host Linux headers.
sed -i 's/^CONFIG_CROSS_COMPILER_PREFIX=.*/CONFIG_CROSS_COMPILER_PREFIX=""/; s/^CONFIG_EXTRA_CFLAGS=.*/CONFIG_EXTRA_CFLAGS=""/; s/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
make oldconfig </dev/null > "$TEST_BUILD/config.log" 2>&1
make -j"$(nproc)" > "$TEST_BUILD/build.log" 2>&1 || { tail -80 "$TEST_BUILD/build.log"; exit 1; }
printf '%s\n' "$TEST_BUILD/busybox-1.36.1/busybox"
