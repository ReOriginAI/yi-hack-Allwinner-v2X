# Manual night vision and automatic threshold

Open **Camera Settings** and choose a night-vision mode, then **Save**:

- **Automatic** uses the camera's light sensor, with an adjustable threshold.
- **Night on** holds monochrome night mode, IR-cut filter and infrared light.
- **Night off (day/color)** holds color day mode and turns infrared light off.

The automatic threshold accepts integers from **1 to 100**. **50** preserves
the original firmware thresholds. Higher values enter night mode at brighter
light levels; lower values require darker conditions. The camera retains its
native hysteresis, delay and other light-quality checks. The displayed light
level is the firmware's measurement, not a calibrated lux reading. The threshold
is retained while using either manual mode.

Settings take effect without restarting RTSP or the recorder and persist across
reboots. The page reports the camera's committed day/night state and whether a
new setting is still applying. `NIGHTVISION_MODE=auto|on|off` and
`NIGHTVISION_THRESHOLD=1..100` are stored in `etc/camera.conf`. The legacy `IR`
setting remains compatible: `IR=no` selects Off and `IR=yes` selects Automatic
when a client supplies only that old setting.

## Implementation and compatibility

`nightvision.so` runs inside the existing `rmm` process and wraps its native
night-vision control loop and that loop's light measurement. Manual requests
still use the firmware's complete ISP, IR-cut, IR LED and encoder transition;
y28ga retains its native IVA transition as well. An explicit manual change also
clears the firmware's automatic-fluctuation lockout counter. Automatic mode
retains its existing counter and delay behavior.

The launcher checks the exact optimized `rmm` hash before loading the library:

| Model | Audited optimized `rmm` MD5 |
| --- | --- |
| y623 | `eb9d532e71d0d8697d22d0775b744b40` |
| y28ga | `14aa4ee21e04fb40a3c321fdcd12eef4` |

The library additionally checks executable identity, the selected model and
the original two ARM call instructions before patching private process memory.
It does not write the vendor binary or manipulate GPIOs from another process.
Unknown firmware keeps its native behavior and reports these controls as
unavailable.

The controller uses a **48-byte** shared tmpfs structure and bounded atomic
updates; the camera kernels do not implement `flock`. The native reader never
waits for a writer. There is one **4 KiB** ARM call bridge, small library mappings
and two private instruction pages. No daemon, extra thread, raw frame buffer or
polling process is added. Status uses the Camera Settings page's existing timer.

The ARM payloads built during validation are `nightvision.so` **5,800 bytes**
and `nightvisionctl` **5,024 bytes**. Build with `src/ipc_cmd/compile.ipc_cmd`;
both files are included in the normal firmware payload. The boot manifest and
required-file list include the new launcher, library and controller.

## Validation and recovery

`python3 scripts/test_nightvision.py` covers the original setting, automatic
hysteresis for both models, manual extremes, invalid values, atomic controller
updates, applied-state reporting, configuration migration, legacy IR clients
and runtime failures. Existing RTSP, time and recorder-metadata regressions
also remain applicable.

Live checks on 2026-10-11 passed on both `192.168.1.150` (y623) and
`192.168.1.199` (y28ga):

- Both booted with the final library and controller, with all startup checksums
  verified. y28ga also retained a saved threshold of 75 through a reboot.
- Manual On produced monochrome RTSP frames; Off produced color frames. The
  committed native state and the page's status agreed on both cameras.
- Automatic thresholds 25, 75 and 50 produced the expected light measurements.
  At raw level 180, y623 reported effective levels 360, 120 and 180 respectively.
- Saving through the actual web page enabled the threshold in Automatic mode
  and disabled it in manual modes. RMM, RTSP and recorder process identities
  remained unchanged during the switches; no night-vision process was added.
- Main H.264 plus 16 kHz mono AAC, PCMU backchannel negotiation/data/teardown,
  speaker locking and silent offline TTS passed after the reboots on both.
- Fresh SD clips retained playable audio/video and embedded START/STOP metadata:
  y623 `W419M10S50.mp4` and y28ga `25M32S28.mp4`, both in local-time folder
  `2026Y10M10D23H`. The latter retained its main-only H.264/AAC track layout.
- Both were returned to **Automatic, threshold 50**, preserving their Eastern
  local-time and recording settings. The y623's new motion clip also completed
  the [scheduled FTP upload check](FTP_VALIDATION.md).

Live installations retain original files and configuration under
`/tmp/sd/yi-hack/.nightvision-backup-20261011/`. The update uses atomic file
replacement so an active library mapping remains valid until reboot. When
restoring an older startup file, update its entry in `/backup/init.sh` to the
restored file's checksum before rebooting: this local-only bootstrap verifies
its SD startup payload. Its archived pre-update bootstrap may contain older
checksums from previous feature updates and should not be restored blindly.
