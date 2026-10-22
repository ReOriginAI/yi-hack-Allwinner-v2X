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


def verify_recorder_encoder_policy(temp):
    """Recording must retain sub/fast input after restoring three video tracks."""
    policy = ROOT / "src/static/static/yi-hack/script/rtsp_stream_venc.sh"
    prefix = temp / "encoder-policy"
    for sub in ("etc", "mock"):
        (prefix / sub).mkdir(parents=True)
    log = prefix / "log"
    stubs = {
        "md5sum": '#!/bin/sh\nprintf "%s  %s\\n" "$TEST_RMM_MD5" "$1"\n',
        "ps": '#!/bin/sh\n[ "$TEST_RECORDER_RUNNING" != yes ] || printf "90 root 100 S ./mp4record\\n"\n',
        "ipc_cmd": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_ENCODER_LOG"\n',
    }
    for name, body in stubs.items():
        stub = prefix / "mock" / name
        stub.write_text(body)
        stub.chmod(0o755)
    profiles = {
        "y623": "eb9d532e71d0d8697d22d0775b744b40",
        "y28ga": "14aa4ee21e04fb40a3c321fdcd12eef4",
    }
    # stream, recorder running, local recording, motion recording, expected VENC1
    cases = (
        ("high", "yes", "no", "no", "on"),
        ("high", "no", "yes", "no", "on"),
        ("high", "no", "no", "yes", "on"),
        ("high", "no", "no", "no", "off"),
        ("low", "no", "no", "no", "on"),
        ("both", "no", "no", "no", "on"),
    )
    for model, digest in profiles.items():
        for stream, running, local, motion, expected in cases:
            (prefix / "etc/system.conf").write_text("REC_WITHOUT_CLOUD=" + local + "\n")
            (prefix / "etc/camera.conf").write_text(
                "MOTION_DETECTION=" + motion + "\nSAVE_VIDEO_ON_MOTION=" + motion + "\n")
            log.write_text("")
            env = {**os.environ, "YI_HACK_PREFIX": str(prefix),
                   "MODEL_SUFFIX": model, "TEST_RMM_MD5": digest,
                   "TEST_RECORDER_RUNNING": running, "TEST_ENCODER_LOG": str(log),
                   "YI_HACK_IPC_CMD": str(prefix / "mock/ipc_cmd"),
                   "RMM_PATH": str(prefix / "rmm"),
                   "PATH": str(prefix / "mock") + ":" + os.environ["PATH"]}
            run(["sh", str(policy), stream], env=env)
            assert log.read_text().splitlines() == ["-V " + expected], (model, stream, running, local, motion)
    print("PASS: recording retains subencoder input; idle high-only streaming may pause it")


with tempfile.TemporaryDirectory(prefix="yi-record-metadata-") as folder:
    temp = Path(folder)
    verify_recorder_encoder_policy(temp)
    library, driver, unit = temp / "metadata.so", temp / "driver", temp / "unit"
    flags = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-Os"]
    run(flags + ["-shared", "-fPIC", "-pthread", str(SOURCE / "record_metadata.c"),
                 str(SOURCE / "motion_metadata_events.c"), str(SOURCE / "motion_metadata_levels.c"),
                 "-ldl", "-lrt", "-o", str(library)])
    consumer = temp / "ipc2file-test.o"
    run(["cc", "-Os", "-Dmain=ipc2file_main", "-c", str(SOURCE / "ipc2file.c"), "-o", str(consumer)])
    run(flags + [str(SOURCE / "test_record_metadata_driver.c"), str(consumer),
                 str(SOURCE / "motion_metadata_events.c"), str(SOURCE / "motion_metadata_levels.c"),
                 "-lrt", "-o", str(driver)])
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
               "YI_MOTION_LEVELS": str(record / "levels"),
               "YI_RECORD_METADATA_MODEL": model}
        run([str(driver), str(record), str(source), "events"], env=env)
        output = record / "tmp.mp4.tmp"
        result = probe(output)
        metadata = json.loads(result["format"]["tags"]["yi_motion"])
        if model == "y623":
            assert set(metadata) == {"schema", "data"}, metadata
            assert metadata["schema"] == ["unix_ms", "Scene", "Move", "MovingLevel", "BinImgRatio", "MovingTh"]
            assert len(metadata["data"]) == 2, metadata
            assert [row[1:] for row in metadata["data"]] == [[2, 4, 2, 3.25, 20], [2, 4, 3, 8.5, 20]]
            assert all(len(row)==6 and row[0]>0 for row in metadata["data"])
        else:
            assert metadata["schema"] == "yi-motion-v1" and metadata["model"] == model
            assert metadata["history_available"], metadata
            transitions = [event for event in metadata["events"] if event[3] == "transition"]
            assert [event[2] for event in transitions][-2:] == [1, 0], metadata
            assert len(transitions) in (2, 3), metadata
            assert "levels" not in metadata, metadata
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
