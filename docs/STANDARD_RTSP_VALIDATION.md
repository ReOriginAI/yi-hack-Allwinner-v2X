# Standard RTSP validation

Validated on 2026-10-10 against the y623 camera at `192.168.1.150`.
The subsequent [y28ga deployment and checks](STANDARD_RTSP_Y28GA_VALIDATION.md)
are recorded separately.
The camera now runs `RTSP_ALT=standard` on port 554, with its existing high-only
stream, native AAC audio, G.711 backchannel, speaker audio and ONVIF enabled.
Source, documentation and UI recommend Standard; go2rtc remains selectable.

## Build and fixes

- LIVE555 was updated from `2026.01.12` to
  [`2026.09.23`](https://download.live555.com/changelog.txt). The upstream archive
  SHA-256 is `22da8a0e12219f049051052317ff3774eaae888e6f94fd7be746bc236ad0d7eb`.
- The build uses `-Os` and compiles the required libraries and server. The
  stripped ARM executable is 290,092 bytes, versus 452,668 bytes previously
  installed on the camera, a 35.9% reduction. Its SHA-256 is
  `fed608c0c091a1dce577b4128b1af122596f344c522c06331e4317127ce262de`;
  the installed executable was downloaded and compared with the build output.
- Codec detection waits only for selected streams, with a 15-second bound.
  High-only startup succeeds with the unused low hardware encoder paused.
- Video and AAC share capture timestamps. A camera-specific LIVE555 patch
  preserves this timeline when announcing RTP timestamps, fixing audio jumps
  during RTCP synchronization and reconnects.
- Normal viewers receive forward media. The ONVIF backchannel Require header
  or `?backchannel=1` exposes `PCMU/8000`; `?backchannel=0` overrides the header.
  Repeated SETUP, TEARDOWN and graceful shutdown release reverse media resources.
- The speaker FIFO opens on received audio, uses nonblocking writes, and obeys
  the shared TTS/clip lock. Speaker expiry runs in the event scheduler.
- Backchannel settings moved to Configurations. Saved RTSP settings restart
  the selected engine and refresh enabled ONVIF profiles. The home page exposes
  stream, backchannel, audio-only, TTS POST and audio library/page URLs.

## Checks

The clean ARM build and web asset build completed. JavaScript and shell syntax
checks and `git diff --check` passed.

Host regressions:

```sh
python3 scripts/test_rtsp_config.py
c++ -std=c++11 -Wall -Wextra -I src/rRTSPServer/include \
  scripts/test_rtsp_clock.cpp -o /tmp/yi-standard-clock-test
/tmp/yi-standard-clock-test
```

All seven configuration/link tests passed. Clock tests cover shared audio/video
timestamps, reconnects, interleaving and uint32 millisecond timestamp wrap.

Live regressions on port 554:

```sh
python3 scripts/test_rtsp_timestamps.py \
  rtsp://192.168.1.150:554/ch0_0.h264 \
  --audio-url rtsp://192.168.1.150:554/ch0_2.h264 --seconds 12
python3 scripts/test_standard_rtsp.py 192.168.1.150 \
  --ssh root@192.168.1.150 \
  --tts-url 'http://192.168.1.150/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=0'
python3 scripts/test_standard_rtsp.py 192.168.1.150 --transport udp \
  --ssh root@192.168.1.150 \
  --tts-url 'http://192.168.1.150/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=0'
```

- First, reconnected and concurrent video/audio-only viewers had strictly
  increasing packet PTS and no ffprobe error diagnostics. Each run collected
  more than 180 AAC packets; video runs collected 186–211 packets.
- TCP and UDP PCMU delivery, SDP negotiation, query overrides, repeated
  DESCRIBE/SETUP, FIFO lifecycle and speaker release passed. TTS reported busy
  during talkback and completed after teardown.
- High H.264 at 2304×1296 and low H.264 at 640×360, both with AAC, were tested
  with `RTSP_STREAM=both` and `ONVIF=no`. Talkback and TTS passed with ONVIF off.
  The camera was returned to high-only streaming with ONVIF enabled.
- A temporary server on port 8554 passed Digest authentication with the
  backchannel query and released the speaker on SIGTERM during talkback.
- HTTP checks confirmed the served home links and gzip-compressed configuration
  pages. The backchannel control is present in Configurations and removed from
  the ONVIF settings form.

Audio tests used silent PCMU and zero-volume TTS. They establish delivery and
speaker-lock behavior; physical speaker acoustics were not assessed. Hardware
validation in this record covers this y623 camera.

## Installed endpoints

| Purpose | URL |
| --- | --- |
| Home | `http://192.168.1.150/` |
| High video + AAC | `rtsp://192.168.1.150:554/ch0_0.h264` |
| High with speaker backchannel | `rtsp://192.168.1.150:554/ch0_0.h264?backchannel=1` |
| Audio only | `rtsp://192.168.1.150:554/ch0_2.h264` |
| TTS, POST a text/plain body | `http://192.168.1.150/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0` |
| Audio library | `http://192.168.1.150/cgi-bin/audio_library.sh?action=list` |
| Audio controls | `http://192.168.1.150/?page=audio` |

## Device backup and rollback

The pre-change SD files and configuration are preserved on the camera in
`/tmp/sd/yi-hack/.standard-backup-20261010/original.tgz`. The targeted update
archive is stored alongside it as `update.tgz`. Temporary test servers were
stopped; the installed service runs the verified executable on port 554.

To restore those pre-change files and configuration:

```sh
ssh root@192.168.1.150 '
  /tmp/sd/yi-hack/script/service.sh rtsp stop
  tar -xzf /tmp/sd/yi-hack/.standard-backup-20261010/original.tgz -C /tmp/sd/yi-hack
  /tmp/sd/yi-hack/script/service.sh rtsp start
  /tmp/sd/yi-hack/script/service.sh onvif stop
  /tmp/sd/yi-hack/script/service.sh onvif start
  sync
'
```
