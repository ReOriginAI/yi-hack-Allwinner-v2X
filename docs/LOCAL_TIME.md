# Camera and recording time

Configurations now offers 22 common timezone presets and a Custom timezone
option. Presets include their daylight saving rules where applicable; an
existing custom POSIX rule is retained when the page loads and saves.
The preset rules were checked against
[IANA tzdata 2026e](https://data.iana.org/time-zones/releases/tzdata2026e.tar.gz).

Both live cameras (`192.168.1.150` y623 and `192.168.1.199` y28ga) are configured
with US Eastern (`EST5EDT,M3.2.0,M11.1.0`), the time overlay enabled, and
**Events → Recording time → Local time** selected.

The configured timezone controls the Home/status clock and video overlay.
The recording setting controls new SD folder and file names:

| Recording time | New recording names |
| --- | --- |
| Local time | Configured camera timezone, with automatic daylight saving time |
| GMT | UTC |
| Autodetect | Local time when the overlay is enabled; UTC otherwise |

Saving timezone, recording-time or overlay settings applies the overlay and
restarts an already running native recorder so subsequent files use the new
policy. RTSP, ONVIF, backchannel and TTS are not restarted. Existing completed
recordings retain their names. The Events pages use the saved configuration
directly instead of relying on the web server's startup timezone.

The system clock, filesystem timestamp epochs, MP4 creation fields and
`yi_motion` Unix timestamps remain UTC. A local filename is a wall-clock label
for the same instant, rather than a change to the clock or video timestamps.
For example, `2026-10-11 02:38 UTC` is `2026-10-10 22:38 EDT`.

## Implementation

`script/time_config.sh` supplies one timezone policy for the recorder and web
clock. The recorder uses the full POSIX rule rather than a fixed GMT offset,
so it follows daylight saving changes. `update_osd_tz.sh` refreshes the overlay
offset every minute while enabled, preserving other cron jobs. Its signed
offset calculation includes the minutes for fractional timezones.

The y623 firmware-12 overlay update previously selected the next model's table
entry and silently skipped the change. Firmware-specific adjacent entries are
now used only by the models that actually have them; y623 uses `0x570`, and
y28ga firmware 9 uses `0x4e0`.

The audited y28ga recorder adds the shared OSD offset to the recording's start
time before formatting its final filename. The recorder-local metadata library
undoes that addition at the filename's `localtime_r` call (return address
`0x12678` in these non-PIE vendor ELFs), then libc applies the configured timezone
once. The model/MD5 gates are the same as the
[motion metadata implementation](MOTION_METADATA.md). This does not modify the
vendor binary, media, UTC metadata or other calendar calls. The four-byte offset
is sampled at file opening and retained on that recording thread, including
when a clip closes across a daylight saving change.

## Validation

Validated on 2026-10-11:

- Both Home clocks and captured RTSP overlays showed the same Eastern date and
  time. At `02:31 UTC`, both overlays showed `10 October, 22:31`.
- Browser checks passed on both cameras for the preset selection, all 22
  presets, and showing/hiding the Custom field. A simulated existing custom
  rule remained intact without changing the camera's saved settings.
- New native recordings used folder `2026Y10M10D22H`:
  - y623: `W438M14S45.mp4`, MP4 creation `2026-10-11T02:38:14Z`.
  - y28ga: `38M20S40.mp4`, MP4 creation `2026-10-11T02:38:19Z`.
- Both recordings retained audio/video playback and contained motion START and
  STOP events whose UTC times and clip offsets matched the original MP4 epoch.
  The y623 retains both native H.264 tracks and AAC; y28ga retains main H.264
  and AAC. Native filename and MP4 creation fields have their vendor precision.
- Host regressions passed for local midnight, both Eastern DST transitions,
  signed half/quarter-hour offsets, recorder policy independent of the parent
  timezone, cron preservation, applying changes once, and model-specific OSD
  offsets. Metadata tests also cover the y28ga filename correction and a clip
  spanning an OSD offset change.

Repeat the host checks with:

```sh
python3 scripts/test_time_config.py
python3 scripts/test_rtsp_config.py
TZ=EST5EDT,M3.2.0,M11.1.0 python3 scripts/test_record_metadata.py
```

## Backup

Each camera retains `/tmp/sd/yi-hack/.local-time-backup-20261011/` with the
previous files/configuration in `original.tgz`, the previous cron file in
`crontab.previous`, and the previous recorder library in
`record_metadata.previous.so`. `update.tgz` contains the deployed update.
`mmap.previous` is diagnostic evidence of the prior overlay state; it should
not be restored wholesale over live shared state.

For rollback, stop the recorder and use the current `set_tz_offset` to restore
the previous offset before restoring the archived files, previous library and
cron file; the old y623 helper skipped firmware-12 offset writes. The captured
y623 offset was 28,800 seconds, and the y28ga offset was zero. Both prior
configurations had `TIME_OSD=no`; the previous y28ga timezone was blank with
automatic/UTC recording. Restore that overlay option and restart the recorder.
