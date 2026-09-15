# yi-hack-Allwinner-v2X 3.8.0

Custom local-first yi-hack variant focused on **Yi Pro 2K (`y623`)** and **Kami 1080p (`y28ga`)**.

This project is derived from `yi-hack-Allwinner-v2` and keeps the upstream structure and attribution, but the 3.8.x branch intentionally narrows the supported build/release targets to the two camera families that have been tested directly. The focus is low RAM usage, local RTSP/ONVIF operation, two-way audio, local text-to-speech, and local motion detection without the vendor cloud/AI stack.

## Divergent Features for Stability

* In the original `yi-hack-Allwinner-v2` the Yi cams especially Yi Pro 2k (`y623`) are highly unstable and frequently crash due to RAM Out-of-memory and it requires a modern good quality SD card with `Swap File` enabled to mitigate that. An old or bad quality SD card would degrade the performance or make crashes more frequent.    

* This variant was built to work without `Swap File` enabled, thus performance is maintained independent of SD card (performance may be better if quality of SD card is high and `Swap File` is enabled as well).  

* In the original `yi-hack-Allwinner-v2`, Out-of-memory crashes were silent and unrecoverable since the video stream encoders were permanently lost yet the web server and SSH server remained and the only recovery path was through reboot.

* This variant uses the kernel's priority based degradation and watchdog automatic recovery which preserves essential processes like the video stream encoder while ablating non-essential processes to free up memory then restarts the non-essential processes. This means Out-of-memory crashes self-recovers functionality without needing a reboot.

* This variant is optimized on opinionated configs mainly selecting go2rtc as the `RTSP server program`.

Other upstream `sysroot/` and `sdhack/` directories remain in the repository as reference material, but **they are not supported or built by default** by this custom variant.

## Supported targets

| Camera family | Build target | Tested firmware family | Main stream | Motion backend |
| --- | --- | --- | --- | --- |
| Yi Pro 2K Home | `y623` | 12.0.51-class | 2304x1296 H.264 | Low-RAM encoder-statistics `motiond` |
| Kami 1080p | `y28ga` | 9.0.20-class / older y28ga layout | 1920x1080 H.264 | Generic firmware IVA motion with AI classifiers removed |

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

Its firmware exposes encoder motion statistics under `/sys/kernel/debug/mpp/ve`. The 3.8.x build uses those statistics for the low-RAM `motiond` service, so the raw VI2 analysis path and vendor AI/YUV analysis work can be removed more aggressively.

The y623 `rmm` optimization is generated from the known vendor binary only after a strict MD5 check. It disables the Pilot AI frame path, reduces the unused virtual-channel allocation, removes the raw VI2 analysis setup, and makes the unused `vi_get_yuv_data` feeder return immediately. The verified copy is bind-mounted for the boot; the stock flash binary is never overwritten.

The no-YUV patch generates MD5 `4b7dd522614a92979b795575fd064986`. Previous live testing reported roughly 3–5 CPU percentage points saved while retaining high/low H.264, AAC, local motion, recording, and snapshots. Snapshot comparisons used swap to accommodate their transient memory demand. The generated binary matches that tested artifact; final clean-boot validation of this script integration remains pending. This additional patch applies only to y623.

### Kami 1080p — `y28ga`

The tested Kami 1080p hardware uses a `sp2305_mipi` sensor path and produces a 1920x1080 main stream plus a 640x360 low stream.

The older y28ga firmware does **not** expose the same `mpp/ve` encoder-statistics interface. Instead, 3.8.x keeps the firmware's lightweight 640x360 VI2 analysis feed and generic `ivaDetectMotion()` path while disabling the expensive human/vehicle/animal classifier, face/NNA processing, and PTZ tracking work.

The y28ga `rmm` optimization is generated from the camera's own known stock binary and is hash-checked before use. The stock flash binary is not overwritten; the verified optimized copy is bind-mounted for the current boot. Unknown `rmm` builds are refused and fall back to stock.

On the tested Kami 1080p unit this reduced `rmm` from roughly **32.6 MB RSS to 28.7 MB RSS**, with an additional small ION reduction, while retaining RTSP, audio, VI2, and generic motion.

## What is different in this custom variant

Version 3.8.0 includes the model-specific work developed for these two platforms:

- vendor cloud/P2P execution disabled for the local-only configuration
- `dispatch` is retained as the audited local IPC, Wi-Fi, SD-state and hardware broker; its SD-supplied telnet/factory execution hooks are blocked by the internal local-only bootstrap
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

1. Download the GitHub Actions firmware artifact or release bundle.
2. The bundle contains one `.tgz` for **Yi Pro 2K (`y623`)** and one `.tgz` for **Kami 1080p (`y28ga`)**.
3. Select the archive for the **exact** camera target.
4. Extract that target archive to a FAT32 microSD card as required by the yi-hack SD-card layout.
5. Configure Wi-Fi in `Factory/configure_wifi.cfg` if necessary.
6. Insert the card and reboot the camera.
7. Open `http://IP-CAM/` after the camera returns online.
8. Keep the microSD card installed; this hack uses it as part of the runtime filesystem.

This project is derived from the upstream installation model documented by `roleoroleo/yi-hack-Allwinner-v2`.

## WebUI

Both supported targets use the same current WebUI. Model-specific differences are handled below the UI rather than by maintaining separate pages.

The shared interface includes:

- local motion enable/disable
- motion sensitivity
- live motion backend/runtime state polling
- local SD motion recording control
- Audio Library upload/list/play/delete controls
- per-clip playback gain
- offline TTS controls
- RTSP/ONVIF configuration
- status information identifying this custom variant

The motion backend shown by the UI differs by model:

| Model | WebUI motion backend |
| --- | --- |
| Yi Pro 2K `y623` | `H264 encoder statistics` |
| Kami 1080p `y28ga` | `Generic firmware IVA motion` |

### WiFi configuration and maintenance fallback

The **WiFi Configuration** page manages the normal boot network and an optional maintenance network. Primary WiFi is written through the camera's vendor WiFi configuration mechanism; the maintenance profile is stored in `system.conf` and is only activated after the primary network has remained unavailable for the configured grace period. All WiFi changes take effect after reboot.

The maintenance settings are:

| Setting | Recommended value | Purpose |
| --- | --- | --- |
| `WIFI_MAINTENANCE_ENABLED` | `no` normally; `yes` when remote recovery is useful | Enables one-way failover from the normal network to a recovery network |
| `WIFI_MAINTENANCE_SSID` | Separate recovery SSID | A phone hotspot or other network that is not dependent on the primary AP is ideal |
| `WIFI_MAINTENANCE_PASSWORD` | WPA/WPA2 password, 8-63 characters | Credentials for the maintenance network |
| `WIFI_MAINTENANCE_GRACE` | `180` | Seconds the primary network may be unavailable before failover; accepted range is 30-3600 seconds |

`180` seconds is a good default because it tolerates an ordinary AP/router reboot without immediately abandoning the primary network. Use roughly 60-120 seconds when fast field recovery matters more, or 300-600 seconds on networks where AP/controller maintenance commonly takes several minutes.

Once maintenance takeover succeeds, the camera intentionally stays on the maintenance profile and does **not** poll or retry the primary SSID until the next reboot. The maintenance profile uses DHCP even if the normal network uses a static address, so a DHCP reservation is usually the least surprising way to give the camera a predictable address. If maintenance WiFi itself fails six consecutive recovery attempts, the camera reboots and starts again from the normal primary profile.

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

#### Recommended camera-side settings for Frigate / ONVIF

For a camera primarily used with Frigate, Home Assistant, or another local NVR, the following is a reasonable starting point:

```ini
RTSP=yes
RTSP_ALT=go2rtc
RTSP_STREAM=both
RTSP_AUDIO=aac
RTSP_STI=yes
RTSP_PORT=554
SPEAKER_AUDIO=yes

ONVIF=yes
ONVIF_WSDD=yes
ONVIF_PROFILE=high
ONVIF_NETIF=wlan0
ONVIF_WM_SNAPSHOT=no
ONVIF_AUDIO_BC=G711
ONVIF_ENABLE_MEDIA2=no
ONVIF_FAULT_IF_UNKNOWN=no
ONVIF_FAULT_IF_SET=no
ONVIF_SYNOLOGY_NVR=no
```

The important choices are:

- **`RTSP_ALT=go2rtc`** uses the lightweight camera-side go2rtc server and lazy `h264grabber` producers. `RTSP_STREAM=both` makes both high and low endpoints available, but does not run two permanent software encoders.
- **`RTSP_AUDIO=aac`** is the preferred camera-facing audio format for Frigate recording and browser/MSE playback. It avoids an unnecessary audio transcode on the camera. With `RTSP_STREAM=both`, AAC is attached to the high stream; the low stream remains a good lightweight detection feed.
- **`ONVIF_PROFILE=high`** is the safest default for ONVIF discovery and talkback because the high stream carries AAC. Use `both` only when a client specifically needs the low profile advertised as well; with camera-side go2rtc and `RTSP_STREAM=both`, the low RTSP stream is intentionally video-only.
- **`SPEAKER_AUDIO=yes` + `ONVIF_AUDIO_BC=G711`** enables the patched Profile T backchannel. Camera-side go2rtc presents the speaker path as `PCMU/8000` (`G.711 u-law`), which is widely supported for ONVIF two-way audio.
- **`ONVIF_WSDD=yes`** is useful for discovery. If every client is configured manually by IP, WSDD can be disabled without affecting RTSP itself.
- **`ONVIF_ENABLE_MEDIA2=no`** and the advanced fault/Synology compatibility switches should stay off unless a specific NVR needs them.
- **`ONVIF_WM_SNAPSHOT=no`** keeps ONVIF snapshots clean and avoids the optional software snapshot timestamp/watermark pass. The live H.264 timestamp OSD is separate.

If two-way audio is not needed, set `ONVIF_AUDIO_BC=NONE`; the rest of the streaming recommendations can stay the same.

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

Example Kami 1080p response:

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

### `y28ga` Kami 1080p

The older y28ga firmware needs the VI2 640x360 raw analysis path for generic `ivaDetectMotion()`. Version 3.8.0 therefore keeps that lightweight path but removes/stubs the expensive classifier and tracking work.

The old firmware names its publication gate "AI Motion Detection" internally. Testing showed that this same gate must be enabled for **generic IVA motion publication** even after the AI classifiers have been removed. The 3.8.x `motion_service.sh` owns that gate; it is enabled only while local motion is enabled and all human/vehicle/animal/face/tracking controls remain forced off.

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

Frigate already bundles its own go2rtc. This is separate from the **camera-side go2rtc** selected by `RTSP_ALT=go2rtc`. The camera-side instance exposes the encoded Yi/Kami buffers as RTSP; Frigate's instance should normally open each required camera stream once and then share that local restream with recording, detection, live view, Home Assistant, and audio detection. This minimizes connections and avoids doing any video transcoding on the camera.

For these cameras, a good division of work is:

| Stream | Camera endpoint | Frigate use |
| --- | --- | --- |
| Main | `ch0_0.h264` | High-quality recording, live view, AAC audio, optional audio events |
| Sub | `ch0_1.h264` | Object/motion detection at 640x360 |
| Talk | `ch0_0.h264` without source modifiers | On-demand WebRTC/two-way talk only |

Permanent recording/detection sources should include `#backchannel=0`. Otherwise go2rtc may reserve the camera speaker as soon as it opens the RTSP source. Keep a separate talk source with **no `#` modifiers on its bare `rtsp://` URL** so the backchannel remains available when Frigate actually needs it.

A practical Frigate configuration is:

```yaml
go2rtc:
  streams:
    yi_camera:
      # H.264 + camera-native AAC; no speaker reservation.
      - "rtsp://USER:PASS@IP-CAM/ch0_0.h264#backchannel=0"
      # Optional Opus producer for WebRTC clients. Runs on the Frigate host.
      - "ffmpeg:yi_camera#audio=opus"

    yi_camera_sub:
      - "rtsp://USER:PASS@IP-CAM/ch0_1.h264#backchannel=0"

    yi_camera_twoway:
      # Deliberately no # options here: this is the on-demand talkback source.
      - "rtsp://USER:PASS@IP-CAM/ch0_0.h264"
      - "ffmpeg:yi_camera_twoway#audio=opus"

cameras:
  yi_camera:
    ffmpeg:
      output_args:
        record: preset-record-generic-audio-copy
      inputs:
        - path: rtsp://127.0.0.1:8554/yi_camera
          input_args: preset-rtsp-restream
          roles:
            - record
            # Add this only if Frigate audio-event detection is enabled.
            - audio

        - path: rtsp://127.0.0.1:8554/yi_camera_sub
          input_args: preset-rtsp-restream
          roles:
            - detect

    detect:
      width: 640
      height: 360
      fps: 5

    record:
      enabled: true

    live:
      streams:
        Main: yi_camera
        Sub: yi_camera_sub
        Talk: yi_camera_twoway
```

If Frigate audio-event detection is not being used, remove the `audio` role; that avoids an extra FFmpeg audio-analysis process. AAC should still remain enabled on the camera because it is useful for recordings and MSE live playback. The optional `ffmpeg:...#audio=opus` entries run on the Frigate host and are only there for WebRTC/browser compatibility; they do not make the camera transcode audio.

If RTSP authentication is disabled on the camera, remove `USER:PASS@`. If credentials contain reserved URL characters, URL-encode them before placing them in an RTSP URL.

Frigate's current setup wizard can also discover the camera through ONVIF. The explicit YAML above is useful when you want predictable stream roles and the dedicated no-backchannel/talkback split. For two-way talk in a browser, Frigate must be served from a secure context (HTTPS/authenticated UI) and WebRTC must be reachable; in a normal Frigate deployment that means making the Frigate host go2rtc WebRTC listener on port 8555 reachable over TCP and UDP.

The camera already provides encoded H.264. `h264grabber` reads the shared encoded buffers; neither Frigate nor each RTSP client causes a new software video encoder to be started on the camera.

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
y623   # Yi Pro 2K
y28ga  # Kami 1080p
```

To package one target explicitly:

```sh
sudo ./scripts/pack_fw.sh y623
sudo ./scripts/pack_fw.sh y28ga
```

Other upstream model names are rejected by `scripts/common.sh` in this custom branch even if their historical sysroot directories still exist.

### GitHub Actions

`.github/workflows/build.yaml` uses **one build job** for both supported targets.

The job:

1. checks out the repository and submodules
2. installs the ARM build dependencies/toolchain
3. runs `scripts/compile.sh` **once** to build the shared payload
4. runs `scripts/pack_fw.all.sh` to produce both target archives
5. verifies there is exactly one `.tgz` for `y623` and exactly one `.tgz` for `y28ga`
6. uploads both `.tgz` files in **one GitHub Actions artifact** named `yi-hack-Allwinner-v2X-firmware`

GitHub Actions artifact downloads are ZIP files, so downloading that single artifact produces one ZIP containing the two target `.tgz` files:

```text
yi-hack-Allwinner-v2X-firmware.zip
├── <Yi Pro y623 firmware>.tgz
└── <Kami 1080p y28ga firmware>.tgz
```

The `.tgz` files stay independently installable; select the one matching the camera model.

The WebUI firmware maintenance page supports **Upload & Upgrade** with a local model-matching `.tgz` only. The online updater has been removed from this fork: hardened packages bind the SD payload to a matching internal bootstrap, so upgrades validate and switch both together before a single reboot.

The workflow can be started manually and also runs for `3.*` version tags.

## Versioning

The current custom-variant version is:

```text
3.8.0
```

`VERSION` is embedded in packaged firmware by `scripts/pack_fw.sh`. Non-tagged local builds append the current short Git commit hash; a release tagged exactly `3.8.0` is packaged as `3.8.0` without the development suffix.

## Safety and rollback

### IPC resource optimizations

The IPC mirror now uses queue 2 for normal `ipc2file` operation. Diagnostic
`ipc_read` / `ipc_notify` users can enable the former nine queues by exporting
`IPC_MULTIPLEX_ALL=1` before `dispatch` starts. The same preload library serves
the audited y28ga SD-CID `popen()` command with a direct local file read,
removing its shell/`cat` process pair without changing the polling state machine.

These changes are validated after controlled clean boot on both tested targets
(y623 and y28ga); the earlier y623 stall occurred only when the vendor broker
was hot-restarted, which is no longer used as an activation method. The vendor
`dispatch` binary and its routing IDs remain unchanged. See the
[performance test results](docs/vendor-ablation/performance.md) for the exact
clean-boot checks, JFFS2 deployment safeguards, and recovery evidence.

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
