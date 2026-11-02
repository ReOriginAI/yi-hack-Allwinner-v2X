# yi-hack-Allwinner-v2X

Local RTSP/ONVIF streaming, two-way audio, offline text-to-speech, and motion
detection for **Yi Pro 2K (y623)** and **Kami 1080p (y28ga)**, without the vendor cloud.

## Install on a stock camera

Use the archive matching your camera model and installed vendor firmware:

| Camera | Archive target | Supported vendor firmware |
| --- | --- | --- |
| Yi Pro 2K Home | `y623` | `12.0.51.01_202303091901` |
| Kami 1080p | `y28ga` | `9.0.20.06_202007061841` |

1. Download a [firmware release](https://github.com/ReOriginAI/yi-hack-Allwinner-v2X/releases)
   or [GitHub Actions firmware artifact](https://github.com/ReOriginAI/yi-hack-Allwinner-v2X/actions).
   If the download
   is a ZIP containing two `.tgz` files, unzip it first.
2. Extract **only your model's** `.tgz` / `.tar.gz` onto a **FAT32** microSD card.
   Copy the contents, not the archive or its enclosing folder.
3. For a fresh Wi-Fi setup, create `Factory/configure_wifi.cfg` as shown below.
   Skip this if the camera already has working Wi-Fi.
4. Power off the camera, insert the card, and power it on. Allow installation and
   its automatic reboot to finish before removing power.
5. Find the camera's address in your router's DHCP/client list and open `http://IP-CAM/`.
6. Set the camera login and SSH password in the WebUI. Save the card's `backup/`
   directory somewhere safe; installation preserves recovery copies there.

Before installation, the card root should contain:

```text
SD card/
├── Factory/
│   ├── config.sh
│   ├── local_init.sh
│   └── configure_wifi.cfg   # optional; create from the .ori template
└── yi-hack/
    ├── bin/
    ├── etc/
    └── ...
```

**Keep the SD card installed during normal use.** Successful installation writes
`hack_result.txt` and renames `Factory/` to `Factory.done/`. Check `hack_result.txt`
if installation fails. Do not rename another model's firmware to force installation.

The experimental [flash-core profile](docs/FLASH_CORE.md) is a separate build for
operation without SD. Its raw image candidates are not a drag-and-drop installer
and still require hardware validation.

## Wi-Fi configuration file

Copy `Factory/configure_wifi.cfg.ori` to `Factory/configure_wifi.cfg`, then edit:

```ini
wifi_ssid=My AP 2.4GHz
wifi_psk=MyWifiPassword
```

- Use a 2.4 GHz network and UTF-8/plain text.
- Keep the key names exactly as shown, without spaces around `=` or quotes around
  values. Spaces inside the SSID or password are preserved.
- Follow the template's restrictions: avoid backslashes and double quotes.
- Unix LF, Windows CRLF, classic CR line endings, and an optional UTF-8 BOM are
  accepted. UTF-16 and invisible formatting characters are rejected.

After installation, change networks or configure a maintenance network on the
**WiFi Configuration** page; Wi-Fi changes take effect after reboot. The file
also works for recovery; a successfully applied request is renamed to
`configure_wifi.cfg.applied`.

Both cameras support an open hotspot at `192.168.10.1`, controlled from that
page. The optional rear-reset-button override must be enabled and confirmed
active before using a five-second hold to enter hotspot mode. Hotspot Wi-Fi has
no password; the camera login still applies. See [hotspot setup](docs/HOTSPOT.md).

## RTSP video and camera audio

Replace `IP-CAM` with the camera's address. These URLs use port `554`; add `:PORT`
if you change it. Select **Standard (LIVE555)** in the WebUI.

| URL | Stream |
| --- | --- |
| `rtsp://IP-CAM/ch0_0.h264` | High-resolution video with camera audio when enabled |
| `rtsp://IP-CAM/ch0_1.h264` | Low-resolution video with camera audio when enabled |
| `rtsp://IP-CAM/ch0_2.h264` | Camera audio only, with Standard RTSP |

Enable RTSP, choose `RTSP_AUDIO=aac`, and select `RTSP_STREAM=both` if you need
both video URLs. The fresh-install setting is `high`, so enable the low stream
before using its URL. Standard is the default; go2rtc is optional.

With authentication enabled, use `rtsp://USER:PASS@IP-CAM/ch0_0.h264`.
URL-encode reserved characters in credentials.

## Talk through the camera speaker

In **Configurations**, enable speaker audio and set **RTSP speaker backchannel**
to **G711**:

```ini
SPEAKER_AUDIO=yes
RTSP_BACKCHANNEL=G711
```

Backchannel is disabled by default (`NONE`). A compatible RTSP/ONVIF client must
send microphone audio; opening a URL in an ordinary player does not add a talk button.

| URL | Talkback session |
| --- | --- |
| `rtsp://IP-CAM/ch0_0.h264?backchannel=1` | High stream with speaker backchannel |
| `rtsp://IP-CAM/ch0_1.h264?backchannel=1` | Low stream with speaker backchannel |

The speaker track uses **G.711 μ-law / PCMU, 8 kHz**. ONVIF-aware clients can use
the normal query-free RTSP URLs and request it with
`Require: www.onvif.org/ver20/backchannel`. Backchannel also works with ONVIF
disabled. TTS, stored clips, and talkback share the speaker.

## Service URLs and HTTP API

HTTP examples use port `80`; add your configured port if different. With camera
authentication enabled, add `-u 'USER:PASS'` to the `curl` examples.

| Service | URL / endpoint |
| --- | --- |
| WebUI | `http://IP-CAM/` |
| Audio Library and TTS controls | `http://IP-CAM/?page=audio` |
| ONVIF device service | `http://IP-CAM/onvif/device_service` |
| Snapshot | `GET http://IP-CAM/cgi-bin/snapshot.sh?res=high` |
| Low-resolution snapshot | `GET http://IP-CAM/cgi-bin/snapshot.sh?res=low` |
| Camera/service status | `GET http://IP-CAM/cgi-bin/status.json` |
| Motion status | `GET http://IP-CAM/cgi-bin/motion_status.sh` |
| SSH | `ssh root@IP-CAM` (port 22, when enabled) |
| FTP | `ftp://IP-CAM/` (port 21, when enabled) |

### Text-to-speech

Send the text as the POST body. Speech runs locally on the camera:

```sh
curl -H 'Content-Type: text/plain; charset=UTF-8' \
  --data-binary 'Motion detected at the front door' \
  'http://IP-CAM/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0'
```

| Parameter | Accepted values |
| --- | --- |
| `voice` | `en-US`, `en-GB`, `de-DE`, `es-ES`, `fr-FR`, `it-IT` |
| `speed` | `0.2`–`5.0` |
| `pitch` | `0.5`–`2.0` |
| `volume` | `0.0`–`5.0` |

Text is limited to 1024 characters and the body to 4096 bytes. The selected voice
data must be installed. Success returns `{"error":false,"description":"Spoken"}`;
check the JSON `error` field for failures.

### Upload and play audio clips

Use **PCM WAV or raw PCM: signed 16-bit little-endian, 16 kHz, mono**. Clips are
stored on SD; MP3/AAC playback is not supported. The upload request limit is
8 MiB, including multipart overhead.

```sh
# Upload a clip.
curl -F 'file=@doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=upload'

# List stored clips.
curl 'http://IP-CAM/cgi-bin/audio_library.sh?action=list'

# Play a clip; voldb is gain in decibels.
curl --data-binary 'doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=play&voldb=0'

# Delete a clip.
curl --data-binary 'doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=delete'
```

For immediate playback without adding a library entry:

```sh
curl --data-binary @doorbell.wav \
  'http://IP-CAM/cgi-bin/speaker.sh?voldb=0'
```

Immediate playback can return a queued result before playback finishes. Use the
Audio Library's `play` endpoint when you need a completion result.

## Updates, recovery, and further documentation

Use the WebUI firmware maintenance page for routine upgrades, or prepare a fresh
card with the complete matching release as above. Formatting the card does not
restore stock firmware; internal bootstrap changes remain. Keep recovery backups
and follow the [recovery instructions](unbrick/README.md) when needed.

- [Detailed API, Home Assistant / Frigate examples, hardware, and build reference](docs/REFERENCE.md)
- [Standard RTSP validation](docs/STANDARD_RTSP_VALIDATION.md)
- [Motion tuning](docs/MOTION_TUNING.md), [recording lookback](docs/RECORDING_PREROLL.md), and [event metadata](docs/MOTION_METADATA.md)
- [Night vision](docs/NIGHTVISION.md) and [time settings](docs/LOCAL_TIME.md)
- [Experimental flash core](docs/FLASH_CORE.md)

Based on `roleoroleo/yi-hack-Allwinner-v2` and related yi-hack projects. Original
authorship is retained in source headers and repository history. See [LICENSE](LICENSE).
