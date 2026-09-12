<p align="center">
	<img height="200" src="https://user-images.githubusercontent.com/39277388/96489837-43d26180-1240-11eb-9d0e-5cfa84040fe1.png">
</p>

<p align="center">
	<a target="_blank" href="https://github.com/roleoroleo/yi-hack-Allwinner-v2/releases">
		<img src="https://img.shields.io/github/downloads/roleoroleo/yi-hack-Allwinner-v2/total.svg" alt="Releases Downloads">
	</a>
</p>

yi-hack-Allwinner-v2 is a modification of the firmware for the Allwinner-based Yi Camera platform.
What's the difference between v1 and v2? Allwinner-v2 is not an upgrade for Allwinner, it's a version dedicated to a different "family". Same cpu but different flash layout.

## Table of Contents
- [Table of Contents](#table-of-contents)
- [Installation](#installation)
- [Contributing](#contributing-and-bug-reports)
- [Features](#features)
- [Performance](#performance)
- [Supported cameras](#supported-cameras)
- [Is my cam supported?](#is-my-cam-supported)
- [Home Assistant integration](#home-assistant-integration)
- [Audio library and speaker API](#audio-library-and-speaker-api)
- [Frigate integration](#frigate-integration)
- [Build your own firmware](#build-your-own-firmware)
- [Unbricking](#unbricking)
- [License](#license)
- [Disclaimer](#disclaimer)
- [Donation](#donation)


## Installation

### Backup
It's not easy to brick the cam but it can happen.
So please, make your backup copy: https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Dump-your-backup-firmware-(SD-card)

Anyway, the hack procedure will create a backup for you.

### Install Procedure
If you want to use the original Yi app, please install it and complete the pairing process before installing the hack.

Otherwise, check setep 4.

1. Format an SD Card as FAT32. It's recommended to format the card in the camera using the camera's native format function. If the card is already formatted, remove all the files.
2. Download the latest release from the Releases page.
3. Extract the contents of the archive to the root of your SD card. Your card should appear with this structure:
```
|-- Factory/
|-- yi-hack/
|-- lower_half_init.sh
```
4. (Optional) If you want to set wifi credentials, rename the file Factory/configure_wifi.cfg.ori to Factory/configure_wifi.cfg and edit the file with your username and password.
5. Insert the SD Card and reboot the camera
6. Wait a minute for the camera to update.
7. Check the hack opening the web interface http://IP-CAM (where IP-CAM is the IP address of the cam assigned by your router).
8. Don't remove the microSD card (yes this hack requires a dedicated microSD card).
9. Check the FAQ if you have a problem: https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/FAQ


### Online Update Procedure
1. Go to the "Maintenance" web page
2. Check if a new release is available
3. Click "Upgrade Firmware"
4. Wait for cam reboot


### Manual Update Procedure
Check the wiki: https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Manual-firmware-upgrade


### Optional Utilities 
Several [optional utilities](https://github.com/roleoroleo/yi-hack-utils) are avaiable, some supporting experimental features like text-to-speech.


## Contributing and Bug Reports
See [CONTRIBUTING](CONTRIBUTING.md)

---

## Features
This custom firmware contains features replicated from the [yi-hack-MStar](https://github.com/roleoroleo/yi-hack-MStar) project and similar to the [yi-hack-v4](https://github.com/TheCrypt0/yi-hack-v4) project.

- FEATURES
  - RTSP server - allows a RTSP stream of the video (high and/or low resolution) and audio (thanks to @PieVo for the work on MStar platform).
    - `rtsp://IP-CAM/ch0_0.h264` - high resolution
    - `rtsp://IP-CAM/ch0_1.h264` - low resolution
    - `rtsp://IP-CAM/ch0_2.h264` - audio only
    - When the RTSP implementation is **go2rtc**, `SPEAKER_AUDIO=yes`, and `ONVIF_AUDIO_BC=G711`, bidirectional-audio RTSP endpoints are also available:
      - `rtsp://IP-CAM/ch0_0.h264?backchannel=1` - high resolution + AAC camera audio + G.711 PCMU talkback
      - `rtsp://IP-CAM/ch0_1.h264?backchannel=1` - low resolution + G.711 PCMU talkback
      - The `?backchannel=1` query is interpreted by the camera's go2rtc RTSP server and adds a `PCMU/8000` `sendonly` audio track for talkback. ONVIF automatically advertises these URLs when G.711 backchannel support is enabled.
      - A go2rtc source fragment such as `#backchannel=0` or `#backchannel=1` is a separate client-side option. It controls whether that go2rtc client claims an upstream backchannel and is not part of the camera's RTSP endpoint itself.
  - ONVIF server (with support for stream, snapshot, ptz, presets, events and WS-Discovery) - standardized interfaces for IP cameras.
  - Snapshot service - allows to get a jpg with a web request.
    - http://IP-CAM/cgi-bin/snapshot.sh?res=low&watermark=yes        (select resolution: low or high, and watermark: yes or no)
    - http://IP-CAM/cgi-bin/snapshot.sh                              (default high without watermark)
  - Timelapse feature
  - MQTT events - Motion detection and baby crying detection through mqtt protocol.
  - MQTT configuration
  - TLS support for MQTT
  - Web server - web configuration interface.
  - SSH server - dropbear.
  - Telnet server - busybox.
  - FTP server.
  - FTP push: export mp4 video to an FTP server (thanks to @Catfriend1).
  - Authentication for HTTP, RTSP and ONVIF server.
  - Proxychains-ng - Disabled by default. Useful if the camera is region locked.
  - The possibility to change some camera settings (copied from official app):
    - camera on/off
    - video saving mode
    - detection sensitivity
    - motion detections (it depends on your cam and your plan)
    - baby crying detection
    - status led
    - ir led
    - rotate
    - ...
  - Management of motion detect events and videos through a web page.
  - View recorded video through a web page (thanks to @BenjaminFaal).
  - PTZ support through a web page (if the cam supports it).
  - PTZ presets.
  - The possibility to disable all the cloud features.
  - Swap File on SD.
  - Online firmware upgrade.
  - Load/save/reset configuration.


## Performance

The performance of the cam is not so good (CPU, RAM, etc...). Low ram is the bigger problem.
If you enable all the services you may have some problems.
For example, enabling snapshots may cause frequent reboots.
So, **enable swap file** even if this will waste the sd


## Supported cameras

Currently this project supports only the following cameras:

| Camera | SN prefix | Firmware | File prefix | Remarks |
| --- | --- | --- | --- | --- |
| Yi 1080p Home | BFUS - IFUS - RFUS | 9.0.19* | y21ga | - |
| Yi 1080p Home | BFUS - IFUS - RFUS | 12.1.19* | y21ga | - |
| Yi 1080p Home | IFUS - QFUS - RFUS | 9.0.36* | y211ga | - |
| Yi 1080p Home | IFUS - QFUS - RFUS | 12.0.37* | y211ga | - |
| Yi 1080p Home | IFUS - QFUS - RFUS | 12.1.37* | y211ga | - |
| Yi 1080p Home | QFUS - RFUS | 9.0.35* | y291ga | - |
| Yi 1080p Home | QFUS - RFUS | 12.0.35* | y291ga | - |
| Yi Outdoor 1080p | IFUS - RFUS | 9.0.26* | h30ga | - |
| Yi Outdoor 1080p | IFUS - RFUS | 11.1.26* | h30ga | - |
| Yi 1080p Dome | *FUS | 9.0.05* | r30gb | beta version (check this issue https://github.com/roleoroleo/yi-hack-Allwinner-v2/issues/484) |
| Yi 1080p Dome | *FUS | 12.1.05* | r30gb | beta version (check this issue https://github.com/roleoroleo/yi-hack-Allwinner-v2/issues/484) |
| Yi Dome Guard | YRS | 9.0.05* | r30gb | beta version (check this issue https://github.com/roleoroleo/yi-hack-Allwinner-v2/issues/484) |
| Yi Dome Camera U (Full HD) | BFUS - SFUS | 9.0.22* | h52ga | - |
| Yi Dome Camera U (2K) | BFUS - SFUS | 9.0.21* | h51ga | - |
| Yi Dome U Pro 2K | LFUS | 9.0.27* | h60ga | - |
| Yi Outdoor 1080p | QFUS | 9.0.45* | r40ga | - |
| Yi Home Y4 | IFCN | 9.0.09* | y29ga | - |
| Yi Dome Guard | QFUS | 9.0.46* | r35gb | - |
| Yi Dome Guard | QFUS | 12.1.47* | r35gb | - |
| Yi Dome Guard | YRS | 9.0.46* | r35gb | - |
| Yi Dome Guard | YRS | 12.1.47* | r35gb or r37gb | https://github.com/roleoroleo/yi-hack-Allwinner-v2/issues/1156 |
| Yi Dome Guard | RFUS | 12.1.47* | r35gb or r37gb | https://github.com/roleoroleo/yi-hack-Allwinner-v2/issues/1156 |
| Yi Pro 2K Home | RFUS - YFUS - ZFUS | 12.0.51* | y623 | - |
| Kami mini home | IFUS | 9.0.20* | y28ga | - |
| MIBAO G1 1296p dome | - | 9.0.04* | qg311r | - |
| BLITZWOLF BW-YIC1 | - | 9.0.41* | b091qp | - |
| ESCAM PT202 | - | 9.0.41* | b091qp | https://github.com/roleoroleo/yi-hack-Allwinner-v2/discussions/624#discussioncomment-5816561 |
| YS-QC-02 | - | 9.0.41* | b091qp | https://github.com/roleoroleo/yi-hack_ha_integration/issues/84 |
| Flood Light Camera Outdoor L850Y-US | - | 9.0.41* | b091qp | - |
| Tovendor Mini Smart Home Camera | - | 9.0.41* | b091qp | - |

USE AT YOUR OWN RISK.

**Do not try to use a fw on an unlisted model**

**Do not try to force the fw loading renaming the files**


## Is my cam supported?

If you want to know if your cam is supported, please check the serial number (first 4 letters) and the firmware version.
If both numbers appear in the same row in the table above, your cam is supported.
If not, check the other projects related to Yi cams:
- https://github.com/TheCrypt0/yi-hack-v4 and previous
- https://github.com/alienatedsec/yi-hack-v5
- https://github.com/roleoroleo/yi-hack-MStar
- https://github.com/roleoroleo/yi-hack-Allwinner


## Home Assistant integration
Are you using Home Assistant? Do you want to integrate your cam? Try these custom integrations:
- https://github.com/roleoroleo/yi-hack_ha_integration
- https://github.com/AlexxIT/WebRTC

You can also use the [web services](https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Web-services-description) in Home Assistant -- here's one way to do that. (This example requires the nanotts optional utility to be installed on the camera.) Set up a rest_command in your configuration.yaml to call one of the [web services](https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Web-services-description). 
```
rest_command:
  camera_announce:
    url: http://[camera address]/cgi-bin/speak.sh?lang={{language}}&voldb={{volume}}
    method: POST
    payload: "{{message}}"
```
Create an automation and use yaml in the action to send data to the web service. 
```
service: rest_command.camera_announce
data:
  language: en-US
  message: "All your base are belong to us."
  volume: '-8'
``` 


## Audio library and speaker API

The camera can play prerecorded audio through the speaker without browser microphone capture, Web Audio, or a secure HTTPS context. The web interface exposes an **Audio Library** page at:

```text
http://IP-CAM/?page=audio
```

The page can upload clips to the SD card, list stored clips, select playback gain, play a clip, and delete clips.

Supported audio formats are:

- `.pcm` - raw signed PCM16LE, 16 kHz, 16-bit, mono
- `.wav` - uncompressed PCM WAV, 16 kHz, 16-bit, mono

Compressed formats such as MP3 or AAC are intentionally not decoded on the camera. Convert them before uploading.

### Endpoint reference

#### RTSP / ONVIF media endpoints

| Endpoint | Direction | Notes |
| --- | --- | --- |
| `rtsp://IP-CAM/ch0_0.h264` | camera -> client | High-resolution H.264; includes AAC camera audio when enabled |
| `rtsp://IP-CAM/ch0_1.h264` | camera -> client | Low-resolution H.264 |
| `rtsp://IP-CAM/ch0_2.h264` | camera -> client | Audio-only endpoint where supported by the selected RTSP server |
| `rtsp://IP-CAM/ch0_0.h264?backchannel=1` | bidirectional | High-resolution H.264 + AAC camera audio + `PCMU/8000` speaker backchannel |
| `rtsp://IP-CAM/ch0_1.h264?backchannel=1` | bidirectional | Low-resolution H.264 + `PCMU/8000` speaker backchannel |

The bidirectional URLs are available when the camera uses **go2rtc** as its RTSP server, speaker audio is enabled, and the ONVIF audio backchannel is set to `G711`. ONVIF automatically advertises the `?backchannel=1` URLs in this configuration.

`?backchannel=1` is part of the **camera RTSP URL** and tells the camera-side go2rtc RTSP server to expose a `PCMU/8000` `sendonly` track. A go2rtc fragment such as `#backchannel=0` is a different, client-side option and is not part of the camera endpoint.

#### HTTP audio endpoints

| Method | Endpoint | Request body | Behavior |
| --- | --- | --- | --- |
| `GET` | `/cgi-bin/audio_library.sh?action=list` | none | List stored audio clips and sizes |
| `POST` | `/cgi-bin/audio_library.sh?action=upload` | one `multipart/form-data` file | Validate and store a `.pcm` or compatible `.wav` file in `/tmp/sd/audio/` |
| `POST` | `/cgi-bin/audio_library.sh?action=play&voldb=0` | clip basename as plain text | Synchronously play a stored clip and report success or speaker-busy failure |
| `POST` | `/cgi-bin/audio_library.sh?action=delete` | clip basename as plain text | Delete a stored clip |
| `POST` | `/cgi-bin/speaker.sh?voldb=0` | raw PCM/WAV body or one `multipart/form-data` file | Immediate one-shot playback without adding the clip to the library |
| `POST` | `/cgi-bin/speaker_file.sh?voldb=0` | clip basename as plain text | Backward-compatible stored-file playback endpoint |

`audio_library.sh?action=play` and `speaker_file.sh` use `voldb` as the playback gain in dB. `speaker.sh` accepts either `voldb=<dB>` or its legacy `vol=<multiplier>` parameter.

Examples:

```sh
# Upload a reusable clip.
curl -F 'file=@doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=upload'

# List the library.
curl 'http://IP-CAM/cgi-bin/audio_library.sh?action=list'

# Play the stored clip at +6 dB.
curl -X POST --data-binary 'doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=play&voldb=6'

# Delete the stored clip.
curl -X POST --data-binary 'doorbell.wav' \
  'http://IP-CAM/cgi-bin/audio_library.sh?action=delete'

# Play a file immediately without storing it in the library.
curl -F 'file=@doorbell.wav' \
  'http://IP-CAM/cgi-bin/speaker.sh?voldb=0'
```

Typical JSON responses:

```json
{"error":false,"description":"Uploaded","name":"doorbell.wav","size":96044}
```

```json
{"error":false,"files":[{"name":"doorbell.wav","size":96044}]}
```

```json
{"error":false,"description":"Played","name":"doorbell.wav"}
```

If the RTSP/ONVIF backchannel or another HTTP playback request currently owns the speaker semaphore, synchronous playback fails cleanly instead of mixing two writers into the speaker FIFO:

```json
{"error":true,"description":"Speaker busy or unavailable"}
```

### Storage, limits, and playback behavior

Stored library files live in `/tmp/sd/audio/` on the mounted SD card and survive camera reboots. The library refuses requests if `/tmp/sd` is not mounted rather than silently storing files in RAM.

Library uploads are limited to 8 MiB. Filenames are sanitized to simple basenames and only `.pcm` and `.wav` extensions are accepted; callers cannot supply an arbitrary filesystem path. WAV files are parsed and must actually contain uncompressed PCM16LE, 16 kHz, 16-bit, mono audio.

`/cgi-bin/audio_library.sh?action=play` is synchronous: it returns `Played` only after the clip has been sent through the playback pipeline, and it can report a busy speaker immediately.

`/cgi-bin/speaker.sh` preserves the older one-shot behavior. When the SD card is mounted it stages the upload on the SD card, starts playback asynchronously, and returns:

```json
{"error":false,"description":"Queued"}
```

Because that endpoint returns before asynchronous playback finishes, automation clients that need a definitive playback result should prefer the persistent library `play` endpoint.

All HTTP playback paths now use the same speaker pipeline and semaphore as go2rtc talkback:

```text
WAV/PCM file
    -> speaker decode
    -> pcmvol
    -> speaker stream pcm
    -> /tmp/audio_in_fifo
    -> camera speaker
```

This prevents stored-file playback, immediate HTTP playback, Frigate talk, and direct ONVIF/RTSP talk from writing to the speaker simultaneously. The stored-file HTTP playback path has been audibly verified on the Kami mini home (`y28ga`).

Because the Audio Library uses prerecorded file upload rather than a browser microphone, it works over ordinary HTTP and does not require `getUserMedia()`, Web Audio, or HTTPS. The camera web interface should still be restricted to a trusted LAN/VPN and should not be exposed directly to the public internet.

## Frigate integration

Frigate can consume the RTSP streams directly, but using Frigate's bundled go2rtc is recommended for live audio, WebRTC, RTSP restreaming, and bidirectional audio.

The normal receive-only camera streams are:

- `rtsp://IP-CAM/ch0_0.h264` - high resolution, with AAC audio when enabled
- `rtsp://IP-CAM/ch0_1.h264` - low resolution
- `rtsp://IP-CAM/ch0_2.h264` - audio only where supported by the selected RTSP server

When camera-side go2rtc talkback is enabled, the bidirectional endpoints are:

- `rtsp://IP-CAM/ch0_0.h264?backchannel=1`
- `rtsp://IP-CAM/ch0_1.h264?backchannel=1`

The `?backchannel=1` query makes the camera's go2rtc RTSP server expose a G.711 mu-law (`PCMU/8000`) `sendonly` track. Frigate/go2rtc can write microphone audio to that track, which the firmware converts to the 16 kHz PCM format used by the camera speaker.

### Canonical Frigate configuration with bidirectional audio

The recommended setup keeps Frigate's permanent recording and detection connections **receive-only** so the camera speaker backchannel remains free for another direct ONVIF/RTSP client such as OpenIPC. A separate talk-capable stream is available for Frigate WebRTC only when bidirectional audio is needed.

Set the camera to:

- RTSP server: `go2rtc`
- RTSP stream: `both`
- RTSP audio: `aac`
- Speaker audio: enabled
- ONVIF: enabled
- ONVIF profile: `both`
- ONVIF audio backchannel: `G711`

With these settings, ONVIF advertises the talk-capable RTSP URI with `?backchannel=1`, and the camera-side go2rtc server exposes a `PCMU/8000` `sendonly` track on that URI.

Replace `IP-CAM` with the camera address and `FRIGATE-IP` with the LAN address of the Frigate host.

```yaml
go2rtc:
  streams:
    # High-resolution stream for recording and normal live viewing.
    # Disable upstream backchannel ownership so Frigate does not reserve
    # the camera speaker while this permanent stream is connected.
    yi_camera:
      - "rtsp://IP-CAM/ch0_0.h264#backchannel=0"

    # Low-resolution stream for object detection. This is already encoded by
    # the camera firmware; h264grabber reads it from the shared video buffer.
    yi_camera_sub:
      - "rtsp://IP-CAM/ch0_1.h264#backchannel=0"

    # Dedicated bidirectional stream. The camera-side ?backchannel=1 query
    # exposes PCMU/8000 talkback. Frigate-side #backchannel=1 is unnecessary
    # because go2rtc enables upstream backchannel negotiation by default.
    yi_camera_twoway:
      - "rtsp://IP-CAM/ch0_0.h264?backchannel=1"

      # The camera microphone is AAC. Add Opus on the Frigate host for WebRTC
      # instead of transcoding on the resource-constrained camera.
      - "ffmpeg:yi_camera_twoway#audio=opus"

  webrtc:
    candidates:
      - FRIGATE-IP:8555
      - stun:8555

cameras:
  yi_camera:
    ffmpeg:
      output_args:
        record: preset-record-generic-audio-copy
      inputs:
        # High-resolution local go2rtc restream for recording.
        - path: rtsp://127.0.0.1:8554/yi_camera
          input_args: preset-rtsp-restream
          roles:
            - record

        # Low-resolution local go2rtc restream for object detection.
        - path: rtsp://127.0.0.1:8554/yi_camera_sub
          input_args: preset-rtsp-restream
          roles:
            - detect

    detect:
      width: 640
      height: 360
      fps: 5

    live:
      streams:
        Main: yi_camera
        Two-way talk: yi_camera_twoway
        Low bandwidth: yi_camera_sub

    # ONVIF remains useful for PTZ/control/events. Frigate still needs the
    # RTSP sources above because its ONVIF section does not auto-create
    # go2rtc media sources.
    onvif:
      host: IP-CAM
      port: 80
      user: ""
      password: ""
```

There are two different backchannel controls in this setup:

- `?backchannel=1` is part of the **camera RTSP URL**. It tells this firmware's camera-side go2rtc RTSP server to advertise the `PCMU/8000` talkback track.
- `#backchannel=0` is a **Frigate/go2rtc client option**. It deliberately prevents the permanent high- and low-resolution Frigate sources from opening the camera output channel.

No Frigate-side `#backchannel=1` is required on `yi_camera_twoway`; go2rtc enables RTSP backchannel negotiation by default when the source has no overriding go2rtc fragment.

This layout keeps the normal path simple while leaving the speaker available to direct ONVIF clients:

```text
                                  +--> Frigate record / normal live
Yi/Kami high --> camera go2rtc ---+
                 #backchannel=0

Yi/Kami low  --> camera go2rtc ------> Frigate detect
                 #backchannel=0

Yi/Kami high <-> camera go2rtc <----> Frigate WebRTC talk
                 ?backchannel=1          (only when this stream is used)

Direct ONVIF client <-----------------> camera go2rtc / speaker
```

#### Why use the low-resolution stream for detection?

`h264grabber` does not encode video. It memory-maps the camera firmware's shared circular video buffer and copies already-encoded high- or low-resolution frames into go2rtc. Therefore, requesting `ch0_1.h264` does **not** create another software H.264 encoder on the camera.

Using the low-resolution stream for detection is generally the better system-wide tradeoff:

- Frigate decodes 640x360 instead of 1080p/2K for every detection frame.
- Less encoded video is sent over Wi-Fi for the detection path.
- The camera does incur a small extra cost for a second `h264grabber` reader, go2rtc producer, socket, and packet copies because high and low are distinct streams.
- Camera-side go2rtc can fan out multiple consumers of the **same** stream, but it cannot merge high and low into one producer because they are different encoded streams.

If the camera is extremely memory/CPU constrained and the Frigate host has strong hardware decoding, using only the high-resolution stream and downscaling on the Frigate host can reduce the camera to one permanent RTSP producer. Otherwise, high-for-recording plus low-for-detection is the recommended balance.

If RTSP authentication is enabled on the camera:

```yaml
go2rtc:
  streams:
    yi_camera:
      - "rtsp://user:password@IP-CAM/ch0_0.h264#backchannel=0"
    yi_camera_sub:
      - "rtsp://user:password@IP-CAM/ch0_1.h264#backchannel=0"
    yi_camera_twoway:
      - "rtsp://user:password@IP-CAM/ch0_0.h264?backchannel=1"
      - "ffmpeg:yi_camera_twoway#audio=opus"
```

URL-encode special characters in the username or password before placing them in a go2rtc URL.

Frigate two-way talk uses WebRTC. Access Frigate through HTTPS, and for a Docker bridge-network installation expose port `8555` over both TCP and UDP:

```yaml
services:
  frigate:
    ports:
      - "8555:8555/tcp"
      - "8555:8555/udp"
```

Port `8971` is Frigate's normal HTTPS UI port. Port `8554` is only required externally if another application needs Frigate's RTSP restream; Frigate itself uses `127.0.0.1:8554` internally.

Current Frigate documentation for the relevant behavior:

- https://docs.frigate.video/configuration/restream/
- https://docs.frigate.video/configuration/live/

### Minimal direct RTSP configuration

If Frigate live audio and talkback are not needed, Frigate can connect directly to the camera. Use the low-resolution stream for detection to reduce decode load:

```yaml
cameras:
  yi_camera:
    ffmpeg:
      inputs:
        - path: rtsp://IP-CAM/ch0_1.h264
          roles:
            - detect
```

For recording as well, add the high-resolution stream:

```yaml
cameras:
  yi_camera:
    ffmpeg:
      inputs:
        - path: rtsp://IP-CAM/ch0_1.h264
          roles:
            - detect
        - path: rtsp://IP-CAM/ch0_0.h264
          roles:
            - record
```

### PTZ through ONVIF

For models with PTZ support, enable the ONVIF server in the camera web interface and add an `onvif` section to the Frigate camera configuration. The ONVIF port is the camera HTTP port, usually `80` unless you changed it.

```yaml
cameras:
  yi_ptz_camera:
    ffmpeg:
      inputs:
        - path: rtsp://IP-CAM/ch0_1.h264
          roles:
            - detect
    onvif:
      host: IP-CAM
      port: 80
      user: ""
      password: ""
```

If ONVIF authentication is enabled, replace the empty strings with the camera credentials. If ONVIF authentication is disabled, keep `user: ""` and `password: ""`; some Frigate versions expect these keys even when the camera allows anonymous ONVIF access.

Frigate shows PTZ controls only when its ONVIF connection succeeds and the camera model exposes PTZ commands. Not all supported cameras have PTZ hardware.

### Notes

- These cameras have limited CPU and RAM. Prefer doing AAC-to-Opus conversion on the Frigate host rather than on the camera.
- Normal Frigate viewing/recording sources should use `#backchannel=0`; reserve the `?backchannel=1` endpoint for the dedicated two-way stream.
- The two-way stream can temporarily add another RTSP session while it is in use. The camera-side go2rtc server fans out the already encoded video; it does not create another H.264 encoder for each client.
- Snapshots and several simultaneous direct streams may increase memory pressure. Enable the swap file if the camera becomes unstable.

## Telegram Control System

A complete remote surveillance and control system: control your camera, receive automatic alerts, and communicate bidirectionally — all through a Telegram bot.
Features
	- On-demand snapshot and video recording via Telegram commands
	- Automatic motion alerts with photo
	- Automatic sound alerts with snapshot + 15s audio clip
	- Bidirectional voice intercom — speak through Telegram, hear through the camera speaker
	- Blue LED control — turn on/off remotely
	- Infrared control — turn on/off remotely
	- Silent mode — suppress notifications without stopping the watchers
	- System status — IP, uptime, memory, process PIDs
	- Remote reboot
[Get scripts here](https://github.com/tingolinchi/yi-home-telegram).

## Build your own firmware

If you want to build your own firmware, clone this git and compile using a linux machine. Quick explanation:

1. Download and install the SDK as described [here](https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Build-your-own-firmware)
2. Clone this git: `git clone https://github.com/roleoroleo/yi-hack-Allwinner-v2`
3. Init modules: `git submodule update --init`
4. Compile: `./scripts/compile.sh`
5. Pack the firmware: `./scripts/pack_fw.all.sh`

Instead of installing the SDK on your host machine, there's also the option to use a [`devcontainer`](https://code.visualstudio.com/docs/remote/containers) from within [Visual Studio Code](https://code.visualstudio.com/). Please ensure you have the [`Remote - Containers`](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension installed for this to work.


## Unbricking

If your camera doesn't start, no panic. This hack is not a permanent change, remove your SD card and the cam will come back to the original state.
If the camera still won't start, try the "Unbrick the cam" procedure https://github.com/roleoroleo/yi-hack-Allwinner-v2/wiki/Unbrick-the-cam.

----

## License
[MIT](https://choosealicense.com/licenses/mit/)

## DISCLAIMER
**NOBODY BUT YOU IS RESPONSIBLE FOR ANY USE OR DAMAGE THIS SOFTWARE MAY CAUSE. THIS IS INTENDED FOR EDUCATIONAL PURPOSES ONLY. USE AT YOUR OWN RISK.**

## Donation
If you like this project, you can buy roleo a beer :)

Click [here](https://www.paypal.com/cgi-bin/webscr?cmd=_donations&business=JBYXDMR24FW7U&currency_code=EUR&source=url) or use the below QR code to donate via PayPal
<p align="center">
  <img src="https://github.com/roleoroleo/yi-hack-Allwinner-v2/assets/39277388/37ff6496-0903-4633-b203-9569b28e0f1c"/>
</p>
