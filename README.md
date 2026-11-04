# yi-hack-Allwinner-v2X

Local RTSP/ONVIF streaming, two-way audio, offline text-to-speech, and motion
detection for **Yi Pro 2K (y623)** and **Kami 1080p (y28ga)**, without the vendor cloud.

## Flash-core installation (experimental)

Flash-core is the primary firmware for both supported models. It boots from
internal flash and retains saved settings without a card. SD adds recordings,
configuration storage and optional programs.
Experimental package notices remain until the complete fresh-install/recovery
matrix has passed.

| Camera | Archive target | Supported vendor firmware |
| --- | --- | --- |
| Yi Pro 2K Home | `y623` | `12.0.51.01_202303091901` |
| Kami 1080p | `y28ga` | `9.0.20.06_202007061841` |

GitHub Actions builds only **yi-hack-Allwinner-v2X-flash-core** for both models
on manual runs and `3.*` tags.

Revision 6 installation on y623 has passed installed-image verification, router
Wi-Fi, SSH, web UI, H.264/AAC streaming and motion-grid snapshot checks, including
a physical cold boot without SD. A manually installed y28ga has also passed
no-SD boot and network/video checks. **The full installation/recovery matrix on
both models is still pending.** These installers support fresh vendor firmware from the table above and a
[clean reinstall over flash-core](#clean-reinstall-over-flash-core).

1. Download the flash-core artifact from a successful Actions run and extract
   its ZIP on your computer. On Linux, verify its archives with
   `sha256sum -c SHA256SUMS` from that directory.
2. Choose **`flash-core-y623-VERSION-EXPERIMENTAL-sd-installer-r8.zip`** for Yi
   Pro 2K, or **`flash-core-y28ga-VERSION-EXPERIMENTAL-sd-installer-r8.zip`**
   for Kami 1080p. The matching `.tar.gz` contains the same installer. No prior
   SD-dependent yi-hack installation is needed.
3. Prepare a card with an **MBR partition table and one primary FAT32 partition**,
   then extract the chosen archive's **contents directly onto that partition**.
   **y623 requires FAT32 on partition 1.** FAT32 directly on the whole card,
   without a partition table, works in Linux but its vendor updater cannot read
   it. Revision 6 checks this before changing flash. Use a spare card or back up
   existing files before repartitioning; formatting only an existing volume may
   leave the incompatible layout unchanged. y28ga supports either FAT32 layout.
   The card root should contain `Factory/`, `flash-core/`, `lower_half_init.sh`
   and `yi-hack-optional/`. Copying the compressed archive itself does not work.
4. **Create and fill in `Factory/configure_wifi.cfg` before flashing**, using
   exactly one router or hotspot pair below. This is a required step in the
   fresh-camera installation procedure: flashing was reported not to complete
   when the Wi-Fi configuration file was missing. Do not rely on the hotspot
   fallback to complete the initial flash.
5. Read the card's **`RECOVERY.txt`**, then power off the camera, insert the
   card and power on. Allow five minutes and automatic reboots. Keep power and
   the card connected throughout installation.
6. Check `hack_result.txt` for **“Flash-core images verified”**, open the web UI
   and check video. Once startup finishes, power off before removing SD. The
   camera can then boot independently; an empty FAT32 card can later hold recordings.

The installer checks the exact vendor images and flash layout, verifies the
package, and saves verified device backups in `flash-core-recovery/` before
staging updates. Preserve that folder privately for this camera. If it fails,
read `hack_result.txt` and `RECOVERY.txt`; do not force another model's files.
Recovery restores stock rootfs/home and startup while retaining identity and
requested Wi-Fi settings; the compatible y623 kernel patch is retained.
If three update attempts leave both original images unchanged, revision 5
automatically restores the previous startup and records the failure on SD.
Partial updates still require the explicit recovery procedure.

If an earlier experimental installer stops at **“Flash-core staged”** and
`flash-core-recovery/update-attempts` stays at `1` after a power cycle, preserve
that installation card and its backups. The first installer had an early SD
mountpoint bug; it needs the matching staged-install boot repair, rather than
re-extracting a full installer over the pending installation.

Choose the **`-sd-installer-r8.zip`** or **`-sd-installer.tar.gz`** archive. The separate `-images.tar.gz`
archives are raw development inputs and do not install by copying them onto SD.
See [flash-core storage, build and validation details](docs/FLASH_CORE.md).

## Wi-Fi configuration file

Create **`Factory/configure_wifi.cfg`** on the SD card, using exactly **one**
of these pairs. Both models accept the same format. Set it before powering on
to flash; the example file ending in `.ori` is only a template. The active file
must be named **`configure_wifi.cfg`**, without `.ori` or `.txt` after it.

To join your router:

```ini
wifi_ssid=My AP 2.4GHz
wifi_psk=MyWifiPassword
```

To start the camera's hotspot instead:

```ini
hotspot_ssid=My Camera
hotspot_psk=CameraPassword
```

Use `hotspot_psk=` with nothing after `=` for a passwordless hotspot. Otherwise,
use 8–63 printable ASCII characters. Hotspot names must fit in 32 UTF-8 bytes.
A hotspot import selects hotspot boot and keeps saved router credentials for
**Return to Primary WiFi**. A router import selects router Wi-Fi on boot and
keeps the saved hotspot settings.

**Do not include both pairs, even with blank values.** Mixed pairs, repeated
keys, unknown fields, missing fields and invalid values are rejected without
changing saved settings. Commented examples are ignored. You can also copy and edit
`Factory/configure_wifi.cfg.ori` from the installation archive.

- Use a 2.4 GHz network and UTF-8/plain text.
- Keep the key names exactly as shown, without spaces around `=` or quotes around
  values. Spaces inside the SSID or password are preserved.
- Values are literal data; do not wrap them in quotes. For router credentials,
  avoid backslashes and double quotes as required by the vendor firmware.
- Keep the file at most 4 KiB. Unix LF, Windows CRLF, classic CR line endings,
  and an optional UTF-8 BOM are accepted. UTF-16 and invisible formatting characters are rejected.

After installation, change networks or configure a maintenance network on the
**WiFi Configuration** page; Wi-Fi changes take effect after reboot. The file
also works for recovery; a successfully applied request is renamed to
`configure_wifi.cfg.applied`. On installed firmware an invalid request is renamed
`configure_wifi.cfg.rejected`, and the camera continues with its saved settings.
During a fresh installation, invalid settings stop installation and are reported
in `hack_result.txt`.

On the **WiFi Configuration** page, choose the connection recovery behavior:

- **Start camera hotspot** (default): after the outage grace period and reconnect
  attempts, start the camera's hotspot using its configured SSID and password.
  Join it and open `http://192.168.10.1/` (or your configured web port).
- **Join maintenance WiFi**: switch to the configured backup network. If that
  connection also fails six watchdog checks, reboot and retry the primary network.

The grace period defaults to 180 seconds and accepts 30–3600 seconds. Recovery
works with RTSP disabled. The recovery network stays selected until reboot or
**Return to Primary WiFi**; it does not repeatedly switch between networks.
The rear button still clears the hotspot password and requests an open hotspot.

With the default grace period, allow startup time plus three minutes. A y623
bad-password boot test activated its hotspot about 3 minutes 55 seconds after
power-on. Unless you set another name, look for `cam-y623-…` or `cam-y28ga-…` in
your phone's Wi-Fi list. Join that network before opening `192.168.10.1`;
the camera's previous router address is unavailable while it serves the hotspot.

On already installed firmware, a boot without the Wi-Fi file keeps existing
Wi-Fi credentials. If no router Wi-Fi password is saved, it can start an open
hotspot for setup at `http://192.168.10.1/`. This fallback does not replace the
configuration-file step for the initial flash. If flashing did not finish,
check `hack_result.txt` before treating the camera as installed.

To recover, power off the camera, put its SD card in your computer, and create
`Factory/configure_wifi.cfg` with one complete pair shown above. If installation
already renamed `Factory/` to `Factory.done/`, create a **new `Factory/` folder containing
just the configuration file**; leave `Factory.done/` alone. Reinsert the card
and power on. The camera applies the credentials without reinstalling firmware.
For router mode, find its IP in your router's client list. For hotspot mode, join
the configured hotspot and open `http://192.168.10.1/`.

Both cameras support a hotspot at `192.168.10.1`, controlled from that page.
Set an optional WPA2 password (8–63 printable ASCII characters); leaving the
password field blank keeps the saved password. Select **Remove hotspot password**
to make it open. Stop and start the hotspot after saving to apply changes.

On supported firmware the rear-button hotspot override is enabled by default.
Confirm it shows as active after installing/rebooting. Holding the button for
five seconds clears the saved hotspot password and starts an open hotspot.
Router credentials and camera login are unchanged. See [hotspot setup](docs/HOTSPOT.md).

## Set time without internet

Open **Configurations → Offline clock** and select **Use browser time**, or enter
an exact date/time and select **Set manual time**. Entries use your browser's
timezone; the camera's timezone setting controls its display and recordings.
Applying manual time disables NTP synchronization. You can instead use your
router or another local NTP server by entering its IP under **NTP Server**.

After power loss the saved manual time is only an estimate; set it again for
accurate time. The camera cannot account for time spent without power.
The authenticated `GET /cgi-bin/clock.sh` reads the clock;
`POST /cgi-bin/clock.sh` with `{"epoch":1793635200}` sets Unix seconds.
See [time settings](docs/LOCAL_TIME.md).

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
before using its URL. Standard is the default. Camera-side go2rtc has been removed to reduce RAM use.

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

## Legacy SD-dependent installation

The older SD-dependent profile is available through the [manual legacy build steps](docs/REFERENCE.md#building); GitHub Actions no longer packages it. Match the model and vendor firmware listed above.



1. Build the legacy package locally, or use a matching archived legacy release.
2. Extract **only your model's** `.tgz` / `.tar.gz` onto a **FAT32** microSD card.
   Copy the contents, not the archive or its enclosing folder.
3. **Before flashing, create and fill in `Factory/configure_wifi.cfg`** as shown
   above. Do not skip this step on a fresh or recovered vendor camera.
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
│   └── configure_wifi.cfg   # fill in before flashing; copy/edit the .ori template
└── yi-hack/
    ├── bin/
    ├── etc/
    └── ...
```

**Keep the SD card installed during normal use.** Successful installation writes
`hack_result.txt` and renames `Factory/` to `Factory.done/`. Check `hack_result.txt`
if installation fails. Do not rename another model's firmware to force installation.


## Clean reinstall over flash-core

Revision 8 supports installing newer flash-core over an older flash-core while
**resetting user settings and keys**. Factory identity and calibration stay intact.
This path still needs physical validation on both models.

1. Preserve your old recovery card/backups. Extract your model's revision 8
   installer to a **clean compatible FAT32 card** (y623: MBR partition 1).
2. Leave `Factory/configure_wifi.cfg` unset. Clean reinstalls ignore that file
   and start in hotspot setup mode, even if router credentials were previously saved.
3. Insert the card and reboot. Revision 8 bootstraps recognize the included
   `flash-core/CLEAN_INSTALL` request. **Older flash-core needs this one-time
   SSH command after booting with the card inserted:**

   ```sh
   /bin/sh /tmp/sd/flash-core/install.sh --prepare-clean
   ```

4. Keep power and SD connected through the automatic reboots. Wait for
   `hack_result.txt` to report **Flash-core images verified**.
5. Join the open **`cam-MODEL-MACSUFFIX`** hotspot and open
   **http://192.168.10.1/** to configure your router Wi-Fi and hotspot password.

The installer verifies backups before changing startup, then stages images for
U-Boot. Preserve the new `flash-core-recovery/` privately. For a clean reinstall,
its `files/rootfs.restore` and `files/home.restore` restore the previous flash-core;
use the package's `RECOVERY.txt`, rather than its bundled vendor recovery images.
Web upload flashing remains disabled; this is an SD installation path.

## Updates, recovery, and further documentation

Use the clean reinstall procedure above to replace an existing flash-core.
Preserve this camera's recovery backups and follow its matching `RECOVERY.txt`
if recovery is needed. **Online firmware flashing has been removed.**
The WebUI reports the installed version without contacting GitHub. Upload flashing
works only with the legacy SD-dependent profile and is disabled on flash-core;
flash-core installers cannot be uploaded through that path. Formatting the card does not
restore stock firmware; internal bootstrap changes remain. Keep recovery backups
and follow the [recovery instructions](unbrick/README.md) when needed.

- [Detailed API, Home Assistant / Frigate examples, hardware, and build reference](docs/REFERENCE.md)
- [Standard RTSP validation](docs/STANDARD_RTSP_VALIDATION.md)
- [Motion tuning](docs/MOTION_TUNING.md), [recording lookback](docs/RECORDING_PREROLL.md), and [event metadata](docs/MOTION_METADATA.md)
- [Night vision](docs/NIGHTVISION.md) and [time settings](docs/LOCAL_TIME.md)
- [Flash-core storage, build and validation details](docs/FLASH_CORE.md)

Based on `roleoroleo/yi-hack-Allwinner-v2` and related yi-hack projects. Original
authorship is retained in source headers and repository history. See [LICENSE](LICENSE).
