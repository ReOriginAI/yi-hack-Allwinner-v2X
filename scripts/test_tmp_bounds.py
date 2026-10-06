#!/usr/bin/env python3
"""Exercise bounded logs, config archive validation and request cleanup."""
import io
import os
from pathlib import Path
import signal
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "src/static/static/yi-hack/script"

with tempfile.TemporaryDirectory(prefix="yi-tmp-bounds-") as tmp:
    tmp = Path(tmp)
    logfile = tmp / "optional.log"
    for i in range(80):
        subprocess.run(["sh", str(SCRIPTS / "bounded_log.sh"), str(logfile),
                        f"{i:04d} " + "x" * 1200], check=True)
    subprocess.run(["sh", str(SCRIPTS / "bounded_log.sh"), str(logfile),
                    "x" * 100000], check=True)
    assert logfile.stat().st_size <= 65536
    assert not list(tmp.glob("*.new")) and not list(tmp.glob("*.lock.d"))

    prefix = tmp / "prefix"
    (prefix / "etc").mkdir(parents=True)
    for name in ("system.conf", "camera.conf"):
        (prefix / "etc" / name).write_text("unchanged")
    env = {**os.environ, "YI_HACK_PREFIX": str(prefix)}

    def restore(case, entries, success):
        stage = tmp / case
        stage.mkdir()
        archive = stage / "input.tar.bz2"
        with tarfile.open(archive, "w:bz2", format=tarfile.USTAR_FORMAT) as tar:
            for name, data, kind in entries:
                info = tarfile.TarInfo(name)
                if kind == "link":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                    tar.addfile(info)
                elif kind == "dir":
                    info.type = tarfile.DIRTYPE
                    tar.addfile(info)
                else:
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
        r = subprocess.run(["sh", str(SCRIPTS / "restore_config.sh"),
                            str(archive), str(stage)], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert (r.returncode == 0) == success, (case, r.returncode)
        assert (prefix / "etc/system.conf").read_text() == "unchanged"

    valid = [("system.conf", b"SWITCH_ON=yes\n", "file"),
             ("camera.conf", b"LED=yes\n", "file")]
    restore("valid", valid, True)
    restore("traversal", valid + [("../escape.conf", b"x", "file")], False)
    restore("link", [("system.conf", b"", "link"), valid[1]], False)
    restore("directory", valid + [("dir", b"", "dir")], False)
    restore("unknown", valid + [("unknown.conf", b"x", "file")], False)
    restore("missing", valid[:1], False)
    restore("bomb", [("system.conf", b"x" * 2000000, "file"), valid[1]], False)

    # Run the actual request lifecycle with isolated paths and a mount-check stub.
    helper = (SCRIPTS / "config_work.sh").read_text().replace(
        "CONFIG_LOCK=/tmp/yi-config-work.lock.d", f"CONFIG_LOCK={tmp}/lock.d")
    local_helper = tmp / "config_work.sh"
    local_helper.write_text(helper)
    bindir = tmp / "bin"
    bindir.mkdir()
    awk = bindir / "awk"
    awk.write_text("#!/bin/sh\nexit 0\n")
    awk.chmod(0o755)
    ready = tmp / "ready"
    command = f'. "{local_helper}"; config_work_begin || exit 9; echo ready > "{ready}"; read WAIT'
    proc = subprocess.Popen(["sh", "-c", command], env={
        **env, "PATH": str(bindir) + ":" + os.environ["PATH"]},
        stdin=subprocess.PIPE)
    import time
    for _ in range(100):
        if ready.exists():
            break
        time.sleep(.01)
    assert ready.exists()
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=3)
    assert not (prefix / ".config-work").exists()
    assert not (tmp / "lock.d").exists()

print("PASS: byte cap, archive validation, compressed bomb rejection, signal cleanup")
