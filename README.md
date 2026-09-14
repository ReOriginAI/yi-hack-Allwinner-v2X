# yi-hack-Allwinner-v2X 3.7.0

Custom local-first yi-hack variant focused on **Yi Pro 2K (`y623`)** and **Yi 1080p (`y28ga`)**.

This project is derived from `yi-hack-Allwinner-v2` and keeps the upstream structure and attribution, but the 3.7.x branch intentionally narrows the supported build/release targets to the two camera families that have been tested directly. The focus is low RAM usage, local RTSP/ONVIF operation, two-way audio, local text-to-speech, and local motion detection without the vendor cloud/AI stack.

Other upstream `sysroot/` and `sdhack/` directories remain in the repository as reference material, but **they are not supported or built by default** by this custom variant.

## Supported targets

| Camera family | Build target | Tested firmware family | Main stream | Motion backend |
| --- | --- | --- | --- | --- |
| Yi Pro 2K Home | `y623` | 12.0.51-class | 2304x1296 H.264 | Low-RAM encoder-statistics `motiond` |
| Yi 1080p | `y28ga` | 9.0.20-class / older y28ga layout | 1920x1080 H.264 | Generic firmware IVA motion with AI classifiers removed |

The `y28ga` target is the older 1080p hardware/firmware family also associated with Kami Mini-derived hardware. The 3.7.x runtime work was validated on a Yi 1080p unit using this firmware layout.

**Do not rename firmware files to force installation on another model.**

## Hardware notes

The two targets are unusually close internally, which is why most of the local-first optimizations can be shared.

### Common hardware characteristics

Both tested families use:

- Allwinner `sun8iw19` platform
- ARM Cortex-A7 CPU
- about 60 MB of physical RAM (`60912 kB` reported on the tested cameras)
- Allwinner VIN/V4L2 capture stack
- Cedar hardware video encoder path
- `/dev/video0` through `/dev/video3` style video devices
- hardware-produced high- and low-resolution H.264 streams

### Yi Pro 2K — `y623`

The tested Yi Pro 2K hardware uses a `gc3003_mipi` sensor path and produces a 2304x1296 main stream plus a 640x360 low stream.

Its firmware exposes encoder motion statistics under `/sys/kernel/debug/mpp/ve`. The 3.7.x build uses those statistics for the low-RAM `motiond` service, so the raw VI2 analysis path and vendor AI/YUV analysis work can be removed more aggressively.

### Yi 1080p — `y28ga`

The tested Yi 1080p hardware uses a `sp2305_mipi` sensor path and produces a 1920x1080 main stream plus a 640x360 low stream.

The older y28ga firmware does **not** expose the same `mpp/ve` encoder-statistics interface. Instead, 3.7.x keeps the firmware's lightweight 640x360 VI2 analysis feed and generic `ivaDetectMotion()` path while disabling the expensive human/vehicle/animal classifier, face/NNA processing, and PTZ tracking work.

The y28ga `rmm` optimization is generated from the camera's own known stock binary and is hash-checked before use. The stock flash binary is not overwritten; the verified optimized copy is bind-mounted for the current boot. Unknown `rmm` builds are refused and fall back to stock.

On the tested Yi 1080p unit this reduced `rmm` from roughly **32.6 MB RSS to 28.7 MB RSS**, with an additional small ION reduction, while retaining RTSP, audio, VI2, and generic motion.

## What is different in this custom variant

Version 3.7.0 includes the model-specific work developed for these two platforms:

- vendor cloud/P2P execution disabled for the local-only configuration
- WebUI cloud controls replaced by local-only/disabled behavior
- human, vehicle, animal, face/NNA, and motion-tracking AI paths disabled where applicable
- model-aware local motion service
  - `y623`: encoder-statistics `motiond`
  - `y28ga`: lightweight firmware IVA motion events
- duplicate motion/IPC/recording processes prevented
- `mqttv4` is not started when `MQTT=no`
- go2rtc RTSP and ONVIF Profile T audio-backchannel support
- local speaker serialization so HTTP playback and RTSP/ONVIF talkback do not write the speaker simultaneously
- offline NanoTTS
- persistent SD-card Audio Library
- `rsync`
- current WebUI motion status (`idle`, `motion`, `disabled`, `unavailable`)

## Installation

Installation remains SD-card based. Make a backup of the original camera firmware first.

1. Format a microSD card as FAT32.
2. Download the archive for the **exact** target: `y623` or `y28ga`.
3. Extract the archive to the SD-card root.
4. Configure Wi-Fi in `Factory/configure_wifi.cfg` if necessary.
5. Insert the card and reboot the camera.
6. Open `http://IP-CAM/` after the camera returns online.
7. Keep the microSD card installed; this hack uses it as part of the runtime filesystem.

This project is derived from the upstream installation model documented by `roleoroleo/yi-hack-Allwinner-v2`.

## Core services

### RTSP

| Endpoint | Description |
| --- | --- |
| `rtsp://IP-CAM/ch0_0.h264` | High-resolution H.264; AAC camera audio when enabled |
| `rtsp://IP-CAM/ch0_1.h264` | Low-resolution H.264 |
| `rtsp://IP-CAM/ch0_2.h264` | Audio-only stream where supported by the selected RTSP implementation |
| `rtsp://IP-CAM/ch0_0.h264?backchannel=1` | Compatibility URL that explicitly requests speaker backchannel |
| `rtsp://IP-CAM/ch0_1.h264?backchannel=1` | Low-resolution compatibility backchannel URL |

With camera-side **go2rtc**, `SPEAKER_AUDIO=yes`, and ONVIF audio backchannel set to `G711`, ONVIF-aware clients use the normal query-free RTSP URI and send:

```text
Require: www.onvif.org/ver20/backchannel
```

The camera then exposes a `PCMU/8000` `sendonly` backchannel for that RTSP session. Normal viewers that do not request backchannel continue to receive only the camera-facing media tracks.

### Snapshot

```text
GET /cgi-bin/snapshot.sh
GET /cgi-bin/snapshot.sh?res=low&watermark=yes
```

`res` can select the available high/low stream and `watermark` controls the firmware watermark where supported.

## HTTP API

The WebUI uses the same CGI endpoints documented below. Keep the camera HTTP interface on a trusted LAN/VPN; these endpoints are not intended to be exposed directly to the public internet.

### Text-to-speech

Canonical endpoint:

```text
POST /cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0
Content-Type: text/plain; charset=UTF-8

Text to speak
```

NanoTTS runs completely on the camera and sends PCM16LE/16 kHz/mono audio through the same serialized speaker path used by stored clips and two-way audio.

Supported values:

| Parameter | Values |
| --- | --- |
| `voice` | `en-US`, `en-GB`, `de-DE`, `es-ES`, `fr-FR`, `it-IT` |
| `speed` | `0.2` through `5.0` |
| `pitch` | `0.5` through `2.0` |
| `volume` | `0.0` through `5.0` |

The spoken text is limited to 1024 characters. The CGI request-body limit is 4096 bytes.

Example:

```sh
curl -H 'Content-Type: text/plain; charset=UTF-8' \
  --data-binary 'Motion detected at the front door' \
  'http://IP-CAM/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0'
```

Success response:

```json
{"error":false,"description":"Spoken"}
```

The endpoint also accepts an `application/x-www-form-urlencoded` browser fallback with `text`, `voice`, `speed`, `pitch`, and `volume` fields.

`/cgi-bin/speak.sh` remains only as a legacy compatibility endpoint. New integrations should use `/cgi-bin/tts.sh`.

### Audio Library

The WebUI Audio page is:

```text
http://IP-CAM/?page=audio
```

Stored audio lives in `/tmp/sd/audio/` and survives camera reboots. Supported formats are:

- raw signed PCM16LE, 16 kHz, 16-bit, mono (`.pcm`)
- uncompressed PCM WAV, 16 kHz, 16-bit, mono (`.wav`)

Uploads are limited to 8 MiB. MP3/AAC decoding is intentionally not included in the on-camera playback path.

| Method | Endpoint | Request body | Description |
| --- | --- | --- | --- |
| `GET` | `/cgi-bin/audio_library.sh?action=list` | none | List stored clips and sizes |
| `POST` | `/cgi-bin/audio_library.sh?action=upload` | one `multipart/form-data` file | Validate and store `.pcm`/`.wav` on the SD card |
| `POST` | `/cgi-bin/audio_library.sh?action=play&voldb=0` | clip basename as plain text | Synchronously play a stored clip |
| `POST` | `/cgi-bin/audio_library.sh?action=delete` | clip basename as plain text | Delete a stored clip |

Examples:

```sh
curl -F 'file=@doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=upload'

curl 'http://IP-CAM/cgi-bin/audio_library.sh?action=list'

curl -X POST --data-binary 'doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=play&voldb=6'

curl -X POST --data-binary 'doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=delete'
```

Typical responses:

```json
{"error":false,"description":"Uploaded","name":"doorbell.wav","size":96044}
```

```json
{"error":false,"files":[{"name":"doorbell.wav","size":96044}]}
```

```json
{"error":false,"description":"Played","name":"doorbell.wav"}
```

Stored playback includes trailing PCM silence so the camera's speaker path drains before the hardware amplifier is switched off; this avoids clipping the end of clips on the tested hardware.

### Immediate speaker playback

```text
POST /cgi-bin/speaker.sh?voldb=0
```

The request body may be raw PCM/WAV data or a multipart file upload. `speaker.sh` accepts `voldb=<dB>` and the legacy `vol=<multiplier>` parameter.

When SD storage is available this compatibility endpoint queues playback asynchronously and normally returns:

```json
{"error":false,"description":"Queued"}
```

For automation that requires a definitive completion result, upload to the Audio Library and use `audio_library.sh?action=play` instead.

Legacy stored-file compatibility endpoint:

```text
POST /cgi-bin/speaker_file.sh?voldb=0
```

with the stored clip basename as the plain-text body.

### Motion status

```text
GET /cgi-bin/motion_status.sh
```

Example y28ga response:

```json
{"error":false,"model":"y28ga","backend":"ipc-events","backend_label":"Generic firmware IVA motion","status":"started","state":"idle","sensitivity":5,"sensitivity_supported":true,"sd_backup":"yes"}
```

The important fields are:

- `backend`: model-specific detector implementation
- `status`: service process/runtime status
- `state`: `idle`, `motion`, `disabled`, or `unavailable`
- `sensitivity`: configured 1-10 value
- `sd_backup`: whether local motion recording is enabled

For `y623`, the backend uses H.264 encoder statistics. For `y28ga`, only the generic firmware IVA `motion_alarm` event is consumed; legacy human/vehicle/animal classifier files are not treated as motion.

### Configuration/runtime endpoints

These are primarily WebUI endpoints and should be used carefully by automation clients:

| Endpoint | Purpose |
| --- | --- |
| `/cgi-bin/get_configs.sh` | Read configuration groups |
| `/cgi-bin/set_configs.sh` | Persist configuration changes |
| `/cgi-bin/camera_settings.sh` | Apply camera settings/runtime changes after configuration is saved |
| `/cgi-bin/status.json` | General camera/service status JSON |
| `/cgi-bin/ptz.sh` | PTZ controls on hardware that exposes PTZ |
| `/cgi-bin/preset.sh` | PTZ preset operations |
| `/cgi-bin/record.sh` | Recording control |
| `/cgi-bin/service.sh` | Service control used by the WebUI |
| `/cgi-bin/reboot.sh` | Reboot camera |

The Camera Settings WebUI intentionally persists configuration through `set_configs.sh` first and then applies runtime state through `camera_settings.sh`.

## Motion detection architecture

### `y623` Yi Pro 2K

The Yi Pro firmware exposes motion-related encoder statistics. `motiond` reads those statistics rather than running the vendor AI stack. This allows the more aggressive Yi Pro `rmm`/VI optimizations and avoids retaining the raw AI analysis pipeline solely for motion detection.

### `y28ga` Yi 1080p

The older y28ga firmware needs the VI2 640x360 raw analysis path for generic `ivaDetectMotion()`. Version 3.7.0 therefore keeps that lightweight path but removes/stubs the expensive classifier and tracking work.

The old firmware names its publication gate "AI Motion Detection" internally. Testing showed that this same gate must be enabled for **generic IVA motion publication** even after the AI classifiers have been removed. The 3.7.x `motion_service.sh` owns that gate; it is enabled only while local motion is enabled and all human/vehicle/animal/face/tracking controls remain forced off.

## Audio serialization

Local playback paths share the same speaker pipeline:

```text
NanoTTS / WAV / PCM / RTSP backchannel
                |
                v
        speaker stream pcm
                |
                v
       /tmp/audio_in_fifo
                |
                v
          camera speaker
```

The `speaker` helper uses a semaphore so TTS, stored clips, immediate HTTP playback, Frigate talk, and direct ONVIF/RTSP talkback do not write the FIFO concurrently.

## Home Assistant example

Use the canonical TTS endpoint:

```yaml
rest_command:
  camera_announce:
    url: "http://IP-CAM/cgi-bin/tts.sh?voice=en-US&speed=1.0&pitch=1.0&volume=1.0"
    method: POST
    content_type: "text/plain; charset=UTF-8"
    payload: "{{ message }}"
```

Then call it with:

```yaml
service: rest_command.camera_announce
data:
  message: "Motion detected at the front door"
```

## Frigate / go2rtc

A practical configuration is to keep permanent recording/detection streams receive-only so they do not reserve the speaker backchannel, and use a separate normal RTSP source for talkback when needed.

```yaml
go2rtc:
  streams:
    yi_camera:
      - "rtsp://IP-CAM/ch0_0.h264#backchannel=0"
    yi_camera_sub:
      - "rtsp://IP-CAM/ch0_1.h264#backchannel=0"
    yi_camera_twoway:
      - "rtsp://IP-CAM/ch0_0.h264"
      - "ffmpeg:yi_camera_twoway#audio=opus"
```

The camera already provides encoded high/low H.264. `h264grabber` reads the shared encoded buffers; it does not start a software encoder for every RTSP client.

## Building

### Default local build

The common firmware payload is compiled once:

```sh
./scripts/compile.sh
```

Then package both supported targets:

```sh
sudo ./scripts/pack_fw.all.sh
```

`pack_fw.all.sh` intentionally packages only:

```text
y623
y28ga
```

To package one target explicitly:

```sh
sudo ./scripts/pack_fw.sh y623
sudo ./scripts/pack_fw.sh y28ga
```

Other upstream model names are rejected by `scripts/common.sh` in this custom branch even if their historical sysroot directories still exist.

### GitHub Actions

`.github/workflows/build.yaml` uses an explicit two-target matrix:

```text
y623
y28ga
```

Each job builds the shared payload and packages only its assigned target. Artifacts are uploaded separately as `firmware-y623` and `firmware-y28ga`.

The workflow can be started manually and also runs for `3.*` version tags.

## Versioning

The current custom-variant version is:

```text
3.7.0
```

`VERSION` is embedded in packaged firmware by `scripts/pack_fw.sh`. Non-tagged local builds append the current short Git commit hash; a release tagged exactly `3.7.0` is packaged as `3.7.0` without the development suffix.

## Safety and rollback

This firmware runs from the SD-card-based yi-hack layout. The y28ga optimized `rmm` mechanism additionally preserves the stock `/home/app/rmm` binary and uses a verified bind-mounted copy at runtime. If the known stock hash is not recognized, the patch is refused rather than modifying an unknown binary.

Always keep a backup and use firmware for the exact target only.

## Upstream attribution

This custom variant is based on the work in:

- `roleoroleo/yi-hack-Allwinner-v2`
- related yi-hack projects including `yi-hack-MStar` and `yi-hack-v4`

See the repository history and source headers for original authorship and licensing details.

## License

See [LICENSE](LICENSE).

## Disclaimer

Use at your own risk. Camera firmware modification can make a device temporarily unavailable and may require SD-card recovery or restoration of the original firmware.
