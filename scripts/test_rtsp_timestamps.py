#!/usr/bin/env python3
"""Check live RTP timestamps through RTCP synchronization and viewer reconnects.

Requires ffprobe. Pass --audio-url to also exercise simultaneous video and
audio-only viewers sharing the Standard server's AAC source.
"""
import argparse
import collections
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
from urllib.parse import urlsplit

from test_standard_rtsp import Client


def check(url, seconds, label):
    target = urlsplit(url)
    ready = Client(target.hostname, target.port or 554)
    ready.close()
    result = subprocess.run([
        "ffprobe", "-v", "error", "-rtsp_transport", "tcp", "-read_intervals",
        "%+" + str(seconds), "-show_entries", "packet=stream_index,pts_time",
        "-of", "json", url,
    ], text=True, capture_output=True, timeout=seconds + 30)
    assert result.returncode == 0, result.stderr
    assert not result.stderr, result.stderr
    tracks = collections.defaultdict(list)
    for packet in json.loads(result.stdout)["packets"]:
        if "pts_time" in packet:
            tracks[packet["stream_index"]].append(float(packet["pts_time"]))
    assert tracks, "No timestamped media packets"
    for index, pts in tracks.items():
        assert len(pts) > 10, (label, index, "Too few packets")
        for old, new in zip(pts, pts[1:]):
            assert new > old, (label, index, "Non-increasing PTS", old, new)
    print("PASS:", label, "monotonic PTS; packet counts",
          {key: len(value) for key, value in tracks.items()}, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--audio-url")
    parser.add_argument("--seconds", type=int, default=12)
    args = parser.parse_args()
    check(args.url, args.seconds, "first viewer")
    check(args.url, args.seconds, "reconnected viewer")
    if args.audio_url:
        with ThreadPoolExecutor(max_workers=2) as pool:
            video = pool.submit(check, args.url, args.seconds, "concurrent video viewer")
            audio = pool.submit(check, args.audio_url, args.seconds, "concurrent audio-only viewer")
            video.result()
            audio.result()
