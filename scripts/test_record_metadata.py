#!/usr/bin/env python3
"""Verify recorder-local MP4 metadata using an actual preload and ffprobe.

Runs on the host; its IPC queue and recordings live in an isolated test folder.
Requires a C compiler, ffmpeg and ffprobe. No camera or vendor process is used.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/ipc_cmd/ipc_cmd"


def run(args, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError("Command failed: " + " ".join(map(str, args)) + "\n" + result.stderr)
    return result


def atoms(data):
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack_from(">I4s", data, offset)
        assert size >= 8 and offset + size <= len(data)
        yield kind, offset, data[offset:offset + size]
        offset += size
    assert offset == len(data)


def probe(path):
    result = run(["ffprobe", "-v", "error", "-show_entries",
                  "format_tags:stream=codec_name,codec_type", "-of", "json", str(path)])
    assert not result.stderr, result.stderr
    return json.loads(result.stdout)


def verify_recorder_warmup(temp):
    """A paused y28ga subencoder must supply headers through recorder init."""
    service = (ROOT / "src/static/static/yi-hack/script/service.sh").read_text()
    start = service.index("                MP4_WAIT=0\n")
    warmup = service[start:service.index("                # On timeout", start)]
    prefix = temp / "warmup"
    (prefix / "script").mkdir(parents=True)
    policy = prefix / "script/rtsp_stream_venc.sh"
    policy.write_text('#!/bin/sh\nprintf "policy %s\\n" "$1" >> "$TEST_WARMUP_LOG"\n')
    policy.chmod(0o755)
    log = prefix / "log"
    harness = '''
MP4_PID=$$
TEST_POLLS=0
sleep() {
    printf 'sleep %s\n' "$1" >> "$TEST_WARMUP_LOG"
    [ "$1" != 0.1 ] || TEST_POLLS=$((TEST_POLLS+1))
    return 0
}
awk() {
    if [ "$TEST_THREAD_MODE" = ready ] && [ "$TEST_POLLS" -ge 3 ]; then
        printf '2\n'
    else
        printf '1\n'
    fi
}
get_config() { printf 'high\n'; }
'''
    for mode in ("ready", "stalled"):
        log.write_text("")
        env = {**os.environ, "YI_HACK_PREFIX": str(prefix),
               "TEST_WARMUP_LOG": str(log), "TEST_THREAD_MODE": mode}
        run(["sh", "-c", harness + warmup], env=env)
        lines = log.read_text().splitlines()
        if mode == "ready":
            # No open video is needed while idle; allow the second header pass.
            assert lines == ["sleep 0.1"] * 3 + ["sleep 2", "policy high"], lines
        else:
            # A stalled init must be bounded and retain its working input.
            assert lines == ["sleep 0.1"] * 100, lines
    print("PASS: y28ga idle startup restores encoder policy after init; timeout preserves input")


with tempfile.TemporaryDirectory(prefix="yi-record-metadata-") as folder:
    temp = Path(folder)
    verify_recorder_warmup(temp)
    library, driver, unit = temp / "metadata.so", temp / "driver", temp / "unit"
    flags = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Os"]
    run(flags + ["-shared", "-fPIC", "-pthread", str(SOURCE / "record_metadata.c"),
                 str(SOURCE / "motion_metadata_events.c"),
                 "-ldl", "-lrt", "-o", str(library)])
    consumer = temp / "ipc2file-test.o"
    run(["cc", "-Os", "-Dmain=ipc2file_main", "-c", str(SOURCE / "ipc2file.c"), "-o", str(consumer)])
    run(flags + [str(SOURCE / "test_record_metadata_driver.c"), str(consumer),
                 str(SOURCE / "motion_metadata_events.c"), "-lrt", "-o", str(driver)])
    run(flags + ["-pthread", str(SOURCE / "test_record_metadata.c"), "-ldl", "-lrt", "-o", str(unit)])
    print(run([str(unit)]).stdout.strip())
    source = temp / "source.mp4"
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=size=64x64:rate=5",
         "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "30", "-c:v",
         "libx264", "-threads", "1", "-c:a", "aac", "-metadata", "creation_time=" + now,
         str(source)])
    original = source.read_bytes()
    original_mdat = next(body for kind, _, body in atoms(original) if kind == b"mdat")
    original_moov = next(body for kind, _, body in atoms(original) if kind == b"moov")
    original_tracks = [body for kind, _, body in atoms(original_moov[8:]) if kind == b"trak"]
    for model in ("y623", "y28ga"):
        record = temp / model
        record.mkdir()
        env = {**os.environ, "LD_PRELOAD": str(library), "YI_RECORD_ROOT": str(record),
               "YI_MOTION_EVENTS": str(record / "events"),
               "YI_RECORD_METADATA_MODEL": model}
        run([str(driver), str(record), str(source), "events"], env=env)
        output = record / "tmp.mp4.tmp"
        result = probe(output)
        metadata = json.loads(result["format"]["tags"]["yi_motion"])
        assert metadata["schema"] == "yi-motion-v1" and metadata["model"] == model
        assert metadata["history_available"], metadata
        transitions = [event for event in metadata["events"] if event[3] == "transition"]
        assert [event[2] for event in transitions][-2:] == [1, 0], metadata
        assert len(transitions) in (2, 3), metadata
        for offset, unix_ms, state, kind in metadata["events"]:
            assert unix_ms == metadata["video_start_unix_ms"] + offset
            assert 0 <= offset <= metadata["duration_ms"] and state in (0, 1)
            assert kind in ("sample", "transition")
        modified = output.read_bytes()
        assert next(body for kind, _, body in atoms(modified) if kind == b"mdat") == original_mdat
        moov = next(body for kind, _, body in atoms(modified) if kind == b"moov")
        assert [body for kind, _, body in atoms(moov[8:]) if kind == b"trak"] == original_tracks
        run(["ffmpeg", "-v", "error", "-i", str(output), "-t", "1", "-f", "null", "-"])
        # Opening an already completed video must not change or reannotate it.
        before = hashlib.sha256(modified).hexdigest()
        fd = os.open(output, os.O_RDWR)
        os.close(fd)
        assert hashlib.sha256(output.read_bytes()).hexdigest() == before
        print("PASS:", model, "embedded event timestamps, ffprobe, decode, unchanged mdat and tracks")
        run([str(driver), str(record), str(source), "no-space"], env=env)
        assert output.read_bytes() == original
        print("PASS:", model, "metadata write failure leaves original playable MP4")
        invalid = temp / "invalid.mp4"
        invalid.write_bytes(original[:-16])
        run([str(driver), str(record), str(invalid), "empty"], env=env)
        assert output.read_bytes() == invalid.read_bytes()
        print("PASS:", model, "unfinished container skipped")
