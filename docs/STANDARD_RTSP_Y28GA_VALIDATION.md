# Standard RTSP on y28ga

Validated and installed on 2026-10-11 on `root@192.168.1.199`, a y28ga running
firmware `3.8.0-c7c6ada`. It now uses `RTSP_ALT=standard` on port 554. Comparison
with the saved configuration confirmed that only `RTSP_ALT` changed; high-only
streaming, AAC, G.711 talkback, speaker audio, ONVIF and WSDD remain enabled.

The same optimized LIVE555 `2026.09.23` ARM executable and updated UI/CGI/TTS
files from the [y623 implementation](STANDARD_RTSP_VALIDATION.md) were installed.
All ten installed files were compared with the update archive. The server is
290,092 bytes, versus the previously installed 452,668-byte executable.
Its SHA-256 is `fed608c0c091a1dce577b4128b1af122596f344c522c06331e4317127ce262de`.

## Validation

- High H.264 at 1920×1080, low H.264 at 640×360, and native AAC at 16 kHz mono
  were verified. Both video endpoints carry AAC under Standard.
- Twelve-second timestamp checks passed for first, reconnected and concurrent
  video/audio-only viewers, with strictly increasing packet PTS and no ffprobe
  errors. Video runs collected 197–201 packets; AAC runs collected 185–188.
- TCP and UDP PCMU backchannel delivery, ordinary/ONVIF/query SDP negotiation,
  repeated DESCRIBE/SETUP, query override, FIFO lifecycle and TEARDOWN passed.
- TTS reported busy during talkback and succeeded after teardown.
- High and low streams, TCP/UDP backchannels and TTS passed with `ONVIF=no`.
  The camera was then restored to high-only streaming with ONVIF enabled.
- The served home and configuration pages expose the new endpoints and place
  the backchannel control in Configurations. The audio control page is present.
- Final process checks found one Standard server and one watchdog, with ONVIF
  notification and WSDD running, and no go2rtc or h264grabber processes.

This deployment exposed a watchdog restart race: a stopped watchdog may still
appear in `ps` while its shell waits for a sleep to finish. RTSP startup now
always checks again after the existing 30-second delay. The watchdog's singleton
lock prevents duplicate instances. A host regression tests both an exiting old
process and a healthy watchdog; all eight configuration/watchdog tests passed.
The corrected script is included in this device's update archive.

Audio tests used silent PCMU packets and zero-volume TTS. Physical speaker
acoustics were not assessed.

The main live checks can be repeated with:

```sh
python3 scripts/test_rtsp_timestamps.py \
  rtsp://192.168.1.199:554/ch0_0.h264 \
  --audio-url rtsp://192.168.1.199:554/ch0_2.h264 --seconds 12
python3 scripts/test_standard_rtsp.py 192.168.1.199 \
  --ssh root@192.168.1.199 \
  --tts-url 'http://192.168.1.199/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=0'
```

Add `--transport udp` to the second command for UDP talkback.

## Endpoints

| Purpose | URL |
| --- | --- |
| Home | `http://192.168.1.199/` |
| High video + AAC | `rtsp://192.168.1.199:554/ch0_0.h264` |
| High with speaker backchannel | `rtsp://192.168.1.199:554/ch0_0.h264?backchannel=1` |
| Audio only | `rtsp://192.168.1.199:554/ch0_2.h264` |
| TTS, POST a text/plain body | `http://192.168.1.199/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0` |
| Audio library | `http://192.168.1.199/cgi-bin/audio_library.sh?action=list` |
| Audio controls | `http://192.168.1.199/?page=audio` |

## Backup and rollback

The camera's pre-change files and configuration are saved in
`/tmp/sd/yi-hack/.standard-backup-20261011/original.tgz`. The installed update is
stored alongside it as `update.tgz`, with SHA-256
`cf065d514ff2bee3ed66f5a0e328fa66ca0bcc363e2b46ebc70f3966bc640b59`.

To restore the pre-change files and configuration:

```sh
ssh root@192.168.1.199 '
  /tmp/sd/yi-hack/script/service.sh rtsp stop
  tar -xzf /tmp/sd/yi-hack/.standard-backup-20261011/original.tgz -C /tmp/sd/yi-hack
  /tmp/sd/yi-hack/script/service.sh rtsp start
  /tmp/sd/yi-hack/script/service.sh onvif stop
  /tmp/sd/yi-hack/script/service.sh onvif start
  sync
'
```
