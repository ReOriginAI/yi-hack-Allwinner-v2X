#!/usr/bin/env python3
"""Exercise Standard RTSP negotiation and silent PCMU talkback on a live camera.

Use --tts-url to also check the shared speaker lock and silent offline TTS.
Use --ssh to check that the Standard server opens the speaker FIFO only on data.
This verifies packet delivery and lock lifecycle, not physical speaker acoustics.
"""
import argparse
import json
import re
import socket
import struct
import subprocess
import threading
import time
import urllib.request


class Client:
    def __init__(self, host, port):
        deadline = time.monotonic() + 10
        while True:
            try:
                self.sock = socket.create_connection((host, port), 5)
                break
            except ConnectionRefusedError:
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.1)
        self.sock.settimeout(10)
        self.pending = b""
        self.seq = 0

    def close(self):
        self.sock.close()

    def need(self, size):
        while len(self.pending) < size:
            block = self.sock.recv(65536)
            if not block:
                raise EOFError("RTSP connection closed")
            self.pending += block

    def request(self, method, target, headers=None, code=200):
        self.seq += 1
        fields = {"CSeq": str(self.seq), **(headers or {})}
        request = method + " " + target + " RTSP/1.0\r\n"
        request += "".join(k + ": " + v + "\r\n" for k, v in fields.items()) + "\r\n"
        self.sock.sendall(request.encode())
        while True:
            self.need(1)
            if self.pending[:1] == b"$":
                self.need(4)
                size = 4 + struct.unpack("!H", self.pending[2:4])[0]
                self.need(size)
                self.pending = self.pending[size:]
                continue
            while b"\r\n\r\n" not in self.pending:
                self.need(len(self.pending) + 1)
            head, self.pending = self.pending.split(b"\r\n\r\n", 1)
            lines = head.decode().split("\r\n")
            assert int(lines[0].split()[1]) == code, lines[0]
            result = dict((k.lower(), v.strip()) for k, v in
                          (line.split(":", 1) for line in lines[1:]))
            assert result["cseq"] == str(self.seq), result
            size = int(result.get("content-length", "0"))
            self.need(size)
            body, self.pending = self.pending[:size], self.pending[size:]
            return result, body.decode()


def speaker_fds(target):
    command = ('for p in /proc/[0-9]*; do n=$(cat "$p/comm" 2>/dev/null); '
               'case "$n" in rRTSPServer*) ls -l "$p/fd" 2>/dev/null;; esac; done')
    return subprocess.check_output(["ssh", "-o", "BatchMode=yes", target, command], text=True)


def tts(url):
    request = urllib.request.Request(url, data=b"Test", method="POST",
                                     headers={"Content-Type": "text/plain"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def run(args):
    url = f"rtsp://{args.host}:{args.port}/{args.stream}"
    require = {"Require": "www.onvif.org/ver20/backchannel"}
    client = Client(args.host, args.port)
    udp = rtcp = None
    try:
        # A viewer after a talker must not inherit the talker's SDP.
        for headers, suffix, wanted in [({}, "", False), (require, "", True),
                ({}, "?backchannel=1", True), (require, "?backchannel=0", False),
                ({"rEqUiRe": "other, www.onvif.org/ver20/backchannel"}, "", True),
                ({}, "", False)]:
            _, sdp = client.request("DESCRIBE", url + suffix,
                                   {"Accept": "application/sdp", **headers})
            assert ("a=sendonly" in sdp) == wanted, sdp
            assert "m=video" in sdp, sdp
            if wanted:
                assert "PCMU/8000" in sdp, sdp
        print("PASS: ordinary/ONVIF/query SDP, query override, repeated DESCRIBE", flush=True)
        if args.ssh:
            assert "/tmp/audio_in_fifo" not in speaker_fds(args.ssh)

        headers, sdp = client.request("DESCRIBE", url + "?backchannel=1")
        tracks = [track for track in re.split(r"(?m)^m=", sdp)
                  if "a=sendonly" in track and "PCMU/8000" in track]
        assert len(tracks) == 1, sdp
        control = re.search(r"a=control:([^\r\n]+)", tracks[0]).group(1)
        track_url = headers["content-base"] + control
        client.request("SETUP", track_url, code=461)  # Missing Transport
        transport = "RTP/AVP/TCP;unicast;interleaved=0-1"
        if args.transport == "udp":
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            rtcp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            for port in range(12000, 12200, 2):
                try:
                    udp.bind(("", port))
                except OSError:
                    continue
                rtcp.bind(("", port + 1))
                break
            else:
                raise RuntimeError("No free local RTP port")
            transport = f"RTP/AVP;unicast;client_port={port}-{port + 1}"
        headers, _ = client.request("SETUP", track_url, {"Transport": transport})
        session = headers["session"].split(";")[0]
        # Repeated SETUP exercises upstream stream-token cleanup.
        headers, _ = client.request("SETUP", track_url,
                        {"Session": session, "Transport": transport})
        if udp:
            server_port = int(re.search(r"server_port=(\d+)", headers["transport"]).group(1))
        else:
            channel = int(re.search(r"interleaved=(\d+)", headers["transport"]).group(1))
        if args.ssh:
            assert "/tmp/audio_in_fifo" not in speaker_fds(args.ssh)
        client.request("PLAY", url + "?backchannel=1", {"Session": session})

        done = threading.Event()
        errors = []

        def send_silence():
            try:
                n = 0
                while not done.is_set():
                    packet = struct.pack("!BBHII", 0x80, 0, n & 65535,
                                         (n * 160) & 0xffffffff, 0x59694861) + b"\xff" * 160
                    if udp:
                        udp.sendto(packet, (args.host, server_port))
                    else:
                        client.sock.sendall(b"$" + bytes([channel]) + struct.pack("!H", len(packet)) + packet)
                    n += 1
                    done.wait(.02)
            except Exception as error:
                errors.append(error)

        sender = threading.Thread(target=send_silence)
        sender.start()
        try:
            time.sleep(.6)
            if args.ssh:
                assert "/tmp/audio_in_fifo" in speaker_fds(args.ssh), "No Standard FIFO writer"
            if args.tts_url:
                result = tts(args.tts_url)
                assert result["error"] in (True, "true"), result
                assert "busy" in result.get("description", "").lower(), result
        finally:
            done.set()
            sender.join()
        assert not errors, errors
        client.request("TEARDOWN", url + "?backchannel=1", {"Session": session})
        if args.ssh:
            assert "/tmp/audio_in_fifo" not in speaker_fds(args.ssh)
        if args.tts_url:
            result = tts(args.tts_url)
            assert result["error"] in (False, "false"), result
        print(f"PASS: repeat SETUP, {args.transport.upper()} PCMU delivery, TEARDOWN and speaker release", flush=True)
        if args.tts_url:
            print("PASS: TTS busy during talkback, silent offline TTS after teardown", flush=True)
    finally:
        client.close()
        if udp:
            udp.close()
        if rtcp:
            rtcp.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("--port", type=int, default=554)
    parser.add_argument("--stream", default="ch0_0.h264")
    parser.add_argument("--transport", choices=("tcp", "udp"), default="tcp")
    parser.add_argument("--ssh", help="SSH target, e.g. root@192.168.1.150")
    parser.add_argument("--tts-url", help="TTS URL with volume=0 for a silent test")
    run(parser.parse_args())
