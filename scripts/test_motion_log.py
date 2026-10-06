#!/usr/bin/env python3
"""Run from any directory: python3 scripts/test_motion_log.py."""
import pathlib
import subprocess
import tempfile

logger = pathlib.Path(__file__).resolve().parents[1] / "src/static/static/yi-hack/script/motion_log.sh"
with tempfile.TemporaryDirectory() as d:
    log = pathlib.Path(d) / "motiond.log"
    lines = [f"{i:06d} " + "x" * 90 for i in range(20000)]
    subprocess.run(["sh", str(logger), str(log)], input="\n".join(lines) + "\n",
                   text=True, check=True)
    backup = pathlib.Path(str(log) + ".1")
    assert 0 < log.stat().st_size <= 65536
    assert 0 < backup.stat().st_size <= 65536
    current = log.read_text().splitlines()
    previous = backup.read_text().splitlines()
    assert current[-1] == lines[-1]
    assert int(previous[-1].split()[0]) + 1 == int(current[0].split()[0])
    assert len(list(pathlib.Path(d).iterdir())) == 2
    saved_backup = backup.read_bytes()
    subprocess.run(["sh", str(logger), str(log)], input="restarted\n",
                   text=True, check=True)
    assert log.read_text() == "restarted\n"
    assert backup.read_bytes() == saved_backup
    subprocess.run(["sh", str(logger), str(log)], input="z" * 100000 + "\nend\n",
                   text=True, check=True)
    assert log.read_text() == "end\n"
    assert backup.stat().st_size == 65536
print("PASS: repeated rotation, 64 KiB bounds, ordered backup, restart, oversized line")
