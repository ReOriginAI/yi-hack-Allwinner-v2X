# Motion timestamps in SD recordings

New SD-card MP4 recordings on audited y623 and y28ga recorders contain a
`yi_motion` JSON tag. The recorder writes this tag while finalizing its own open
file, before closing and renaming it. No completed-file job, video remux, encoder,
sidecar, or additional daemon is involved. Live RTSP is unchanged.

The legacy event format uses the existing `ipc2file` consumer to capture generic
motion START/STOP events in a bounded, shared RAM history at `/tmp/yi-motion-events`. This tmpfs file is
shared state, not a video sidecar. The vendor broker translates these events
into recording commands, so observing only the recorder's IPC queue would miss
the motion transitions. Legacy metadata uses the original generic events, including
the alternate firmware START message, and ignores human/vehicle/animal events.
The consumer blocks on its existing queue instead of delaying every event by
500 ms. Recording and both motion backends start this shared consumer before
they need it; ONVIF does not need to be enabled. Stopping ONVIF retains the
consumer while local motion or recording needs it. The existing watchdog
restores a missing consumer or history file without restarting the recorder.

The recorder-local `record_metadata.so` reads a snapshot when closing a clip.
It skips media data using MP4 atom sizes, reads small container headers, appends
`moov/udta/meta/ilst/----`, and updates the four-byte `moov` size. Encoded video,
AAC, track tables, and media offsets stay unchanged. This implementation supports
the audited muxers whose finalized `moov` is last in the file; incomplete or
unrecognized layouts are skipped. A failed metadata write attempts to restore
the original size and truncate the metadata tail.

## Current compact raw format: y623 at .150

The .150 trial now stores just a static column header and arrays of timestamped
vendor readings. New y623 recordings use this format; y28ga at .199 retains
`yi-motion-v1` because its firmware does not expose these encoder statistics.
Previously completed recordings keep their original tags, including the earlier
y623 periodic-level extension.

Use a host with FFprobe and jq to extract the MP4 tag:

```sh
ffprobe -v error -show_entries format_tags=yi_motion -of json recording.mp4 |
    jq '.format.tags.yi_motion | fromjson' > motion.json
```

```json
{
  "schema": ["unix_ms", "Scene", "Move", "MovingLevel", "BinImgRatio", "MovingTh"],
  "data": [
    [1791858420000, 0, 1, 1, 2.10, 20],
    [1791858420200, 0, 2, 2, 4.25, 20],
    [1791858420400, 0, 2, 2, 3.80, 20]
  ]
}
```

Every row has exactly six numbers in the header's order. `unix_ms` is UTC Unix
time in milliseconds, captured with the corresponding detector reading.
Local-time overlays and filenames do not change this timestamp convention.
The other five values come directly from the parsed vendor statistics, without
averaging, scaling, or a derived confidence score.

| Column | Meaning |
| --- | --- |
| `unix_ms` | UTC Unix timestamp in milliseconds |
| `Scene` | Vendor scene/texture grade; documented range 0–2 |
| `Move` | Vendor motion-complexity grade; documented range 0–4 |
| `MovingLevel` | Vendor scene-change intensity grade; documented range 0–3 |
| `BinImgRatio` | Percentage of blocks whose change exceeds the vendor threshold |
| `MovingTh` | Vendor block-change threshold; documented range 10–31 |

The [Allwinner encoder-statistics explanation](https://bbs.aw-ol.com/topic/1627/)
describes these fields. Exact grade boundaries for this camera binary have not
been established. `MovingTh` is separate from the configurable detector start
and stop thresholds; the UI displays its raw value.

Each inactive-to-active trigger starts a burst of **five samples total**, including
the triggering reading: approximately 0, 200, 400, 600, and 800 ms. The detector
then waits one second after the fifth sample and samples once per second while
its motion state remains active. If motion ends earlier, collection stops
immediately; the next trigger starts another burst. Polling and device load can
increase spacing, so parsers should use the actual timestamps. A configured
detector polling interval above 200 ms also limits burst spacing.

Only active-motion readings are included. Preroll, idle readings, and STOP events
do not create rows. The active interval includes the detector's configured quiet
delay. Invalid or unavailable readings are skipped. Rows are filtered to the
clip's MP4 creation-time/duration window. To find an approximate position in the
video, subtract its UTC `creation_time` from `unix_ms / 1000`. The MP4 creation
field has one-second precision; these timestamps are not frame-accurate.

An empty `data` array means no valid retained active readings matched the clip.
A missing or unreadable shared raw buffer causes the recorder to omit the tag.
The compact format intentionally carries no state, availability, truncation,
or STOP markers. Gaps do not prove the camera was idle: an invalid reading,
restart, clock adjustment, or bounded-history overflow can also create a gap.

Export the static header and all rows as CSV:

```sh
jq -r '.schema, .data[] | @csv' motion.json
```

A parser can distinguish formats by the type of `schema`: an array denotes
compact raw rows; the string `yi-motion-v1` denotes the legacy event format.
The Camera Settings page contains this same static format/extraction guide and
a live chart of all five fields. Its three panels use separate scales for the
ratio, grades, and block threshold. UI polling remains every two seconds.

The detector reuses its existing encoder reads. The buffer at
`/tmp/yi-motion-levels` holds 512 samples in 16,432 bytes (five 4 KiB tmpfs pages),
independent of the existing event history. Closing a y623 clip takes a roughly
16 KiB stack snapshot and uses the existing transient 32 KiB JSON allocation.
No new daemon, encoder, remux, or completed-file processing is introduced.
Normal tuning restarts retain pending-clip samples; corrupt history or a detected
clock step resets the buffer. Ring overflow retains the newest 512 readings.

Live validation on .150 used a temporary 0.50% trigger with real vendor readings,
then restored the saved 2.00% trigger, 1.60% release, two confirmations, 3,000 ms
quiet delay, and 100 ms polling. Native `2026Y10M13D02H/W412M16S43.mp4` contains
43 compact rows over 43.200 s. Its first five rows have 201–202 ms spacing;
subsequent rows have 1,004–1,016 ms spacing. The first row matches the detector's
triggering reading. Both H.264 streams and AAC decode successfully. The FTP copy
matches the SD file byte for byte; extraction and CSV commands were exercised.
Camera/system configuration files were retained byte for byte, and all 41 boot
manifest entries passed their checksum checks. The chart and guide were checked
at desktop and 390-pixel phone widths.

An isolated ARM benchmark on .150 on 2026-10-14 measured the existing timestamp
clock read plus raw shared-buffer capture at approximately **1.58 microseconds
of CPU per sample**, averaged over 20,000 iterations. That estimates 0.000158%
of one core at one sample per second, or 0.000790% at five per second. This
measures the timestamp/capture path alone, excluding vendor-statistics reads,
UI telemetry and recorder finalization; it is not an end-to-end motion-latency
benchmark. The benchmark used a separate temporary buffer and did not change
the detector, its settings, or recording state.

## Legacy event format: y28ga and earlier y623 recordings

Example:

```json
{
  "schema": "yi-motion-v1",
  "model": "y28ga",
  "source": "firmware-iva-ipc",
  "video_start_unix_ms": 1791683400000,
  "duration_ms": 60000,
  "video_time_precision_ms": 1000,
  "initial_state": 0,
  "history_available": true,
  "history_truncated": false,
  "event_columns": ["offset_ms", "unix_ms", "state", "kind"],
  "events": [
    [10000, 1791683410000, 1, "transition"],
    [15000, 1791683415000, 0, "transition"]
  ]
}
```

`state` is 1 for motion, 0 for idle, and `initial_state` can be -1 when unknown.
`source` identifies the legacy camera motion pipeline: `encoder-stats-ipc` on y623,
`firmware-iva-ipc` on y28ga. Repeated START messages with the same state are
deduplicated. Rows marked `sample` establish state observed at consumer startup;
they do not claim to identify the original motion start time. Rows marked
`transition` come from received generic motion events.

UTC event times have millisecond resolution at event reception. Relative offsets
use the vendor MP4's creation time and duration. Its creation field has **one-second
resolution**, so the relative video position is approximate within that precision.
The [six-second preroll update](RECORDING_PREROLL.md) sets creation time from
the first recorded keyframe, so these offsets include the buffered footage.
These timestamps are not frame-accurate detector measurements. Detector and IPC
delivery latency still apply, and the camera's clock must be correct.

`history_available=false` marks a missing or unavailable shared snapshot.
`history_truncated=true` marks a clip whose beginning predates the available
history, for example after consumer restart, preroll, or ring overflow. The
initial state is unknown until a retained observation establishes it. A clip
can have no transitions when motion stays active or idle throughout.

For example, `initial_state=-1`, `history_available=false`,
`history_truncated=true`, and `events=[]` mean the clip's motion state is
**unknown**, not idle or active for its full duration. A parser should mark this
clip as missing motion history rather than return zero motion intervals. The
tags cannot reconstruct timestamps that were never captured. The recorder
checks the history file once per clip and remaps it if the collector recreates
it, so a running recorder can recover without reading a stale copy.

## Footprint and supported recorders

The legacy event history holds at most 512 transitions in 8,240 bytes, shared
between the existing consumer and recorder. Closing a y28ga clip uses an approximately 8 KiB
snapshot on the recorder's stack and one transient 32 KiB JSON/atom allocation.
Normal metadata adds a few hundred bytes to a clip. Work occurs at motion
transitions and clip closure; the y28ga filename fix also reads four bytes of
shared OSD state at file opening and retains eight bytes on that thread.
No media bytes are read or copied for metadata.
There is no claimed CPU percentage saving against a previous postprocessor:
neither tested device had one installed.

`service.sh` loads the library only for these model/recorder MD5 combinations:

| Model | Recorder MD5 | Recording tracks |
| --- | --- | --- |
| y623 | `c4ee01f6491b26a37db8d92c59605496` | Vendor high + low H.264, AAC |
| y28ga | `d3aff9fb80bc1d61ec78de281e6e9784` | Stock recorder |
| y28ga | `c541480baa510ad34944e9e763c6b505` | Patched main H.264 + AAC |
| y623 | `06774adfc4368e7dede2ea618a96c2b6` | Six-second preroll, high + low H.264 and AAC |
| y28ga | `0d7a4ca9e73fd75806a6ebb75a8accbc` | Six-second preroll, main H.264 + AAC |

The preload is scoped to `mp4record` and preserves existing preload settings.
Its timezone follows the [camera recording-time selection](LOCAL_TIME.md).
The vendor executable and recording tracks are retained. Existing
completed files are not annotated or rewritten.

The audited main-only y28ga recorder still fetches substream codec headers
during initialization. Restarting it with the subencoder paused could leave it
waiting indefinitely, even without the metadata library. For recorder
`c541480baa510ad34944e9e763c6b505` or `0d7a4ca9e73fd75806a6ebb75a8accbc` with RMM
`14aa4ee21e04fb40a3c321fdcd12eef4`, startup briefly enables the subencoder,
waits up to ten seconds for the recorder's control thread, and allows two
seconds for its second header pass before restoring the configured encoder
policy. This also works while idle without waiting for a recording to begin.
On timeout it leaves the input available so initialization can finish.

## Verification

Run `python3 scripts/test_record_metadata.py`. It compiles the shared library,
the actual `ipc2file` parser, and isolated fixtures. Tests cover generic event
filtering, deduplication, compact raw rows, five-sample trigger bursts, active-only
capture, clip windows, clock steps, history overflow, FFprobe JSON readback,
audio/video decoding, unchanged `mdat` and `trak` bytes, reopening completed
files, simulated metadata write failure, incomplete-container handling, and
y28ga idle startup and timeout behavior.
Run `python3 scripts/test_motion_history_service.py` for collector startup with
ONVIF disabled, idempotent starts, missing-file and duplicate-consumer recovery,
ONVIF stop ownership, watchdog recovery, and nested lifecycle traps. The metadata
tests also verify recovery after a shared file is missing or replaced.
Isolated ARM tests also run without publishing events into the cameras' real
queues.

Installed and validated on 2026-10-11 on both live cameras:

| Camera | Native recording checked | Result |
| --- | --- | --- |
| y623, `192.168.1.150` | `E812M16S44.mp4`, created at `02:12:16Z`, 43.840 s | High 2304×1296 H.264, low 640×360 H.264 and AAC retained; START at +61 ms, STOP at +6088 ms |
| y28ga, `192.168.1.199` | `08M48S12.mp4`, created at `02:08:47Z`, 11.904 s | Main 1920×1080 H.264 and AAC retained; START at +345 ms, STOP at +6351 ms |

These clips contain `history_available=true` and `history_truncated=false`.
FFprobe read back their tags; creation times, durations and event offsets were
checked against the JSON. All recorded audio/video tracks decoded with the
original demuxer time base. Both transition checks used the existing six-second
test-recording IPC command, exercising each camera's real recorder and generic
event path. They verify embedding and timing, rather than physical detector
latency. A separate y623 clip correctly reported active motion without any
transition during its window. A separate y28ga native-container fixture
retained identical media and track bytes after metadata insertion.

### Recovery when ONVIF is disabled

A later sample set of 28 y623 clips in `exampleCam` all had
`initial_state=-1`, `history_available=false`, `history_truncated=true`, and no
events. Live inspection found no collector or history file on .150, despite
its running recorder and encoder detector. ONVIF was disabled; the encoder
backend and recorder had not started the shared collector themselves. This
was a collection failure, not an indication of the duration of motion.

The independent collector lifecycle and reader recovery fix was installed on
both cameras and verified after reboot on 2026-10-11. Existing camera and system
configuration files were retained byte for byte. Fresh native validation:

| Camera | Recording | Motion history |
| --- | --- | --- |
| .150, ONVIF disabled | `2026Y10M11D14H/W443M00S60.mp4` | Available, complete; active throughout, so no transitions. FTP download identical to the SD file. |
| .150, after automatic recovery | `2026Y10M11D14H/W446M00S60.mp4` | Available, complete; the same recorder remapped the recreated history file. |
| .199 | `2026Y10M11D14H/43M53S06.mp4` | Available, complete; test START at +4,920 ms. |
| .199 | `2026Y10M11D14H/44M00S60.mp4` | Available, complete; corresponding STOP at +3,936 ms, 6,016 ms after START. |

All video and audio tracks in the complete recordings decoded using their
original demuxer time bases. Moving .150's history file out of the way exercised
the watchdog's automatic recovery; the recorder and detector PIDs were unchanged.
Stopping and starting .199's ONVIF service retained its collector PID and history.
Clips overlapping an actual history outage or collector startup can still
legitimately report unknown or truncated history. Previously completed clips
were not rewritten and their missing timestamps cannot be recovered from the tag.

Both cameras were returned to normal recorder startup with metadata debugging
disabled. Each has one native recorder, one existing event consumer and the
Standard RTSP server. Final RTSP checks still returned high H.264 and AAC.
At this initial metadata deployment, the vendor executable and both configuration
files matched their pre-metadata copies. The subsequent
[local-time deployment](LOCAL_TIME.md) updates the timezone/overlay selection
and corrects y28ga filename conversion while retaining UTC motion metadata.
The existing backchannel and TTS settings were retained; their live
checks are recorded in [y623](STANDARD_RTSP_VALIDATION.md) and
[y28ga](STANDARD_RTSP_Y28GA_VALIDATION.md).

## Backup and rollback

The .150 compact-format deployment retains its previous files and boot manifest
in `/tmp/sd/yi-hack/.raw-motion-backup-20261013/`. Restore the paired detector and
metadata library together: their shared-buffer versions must match. Restore the
matching web assets and manifest as well. Saved camera/system settings were not
changed by this deployment.

Both cameras retain `/tmp/sd/yi-hack/.motion-metadata-backup-20261011/`.
`original.tgz` contains the previous service script and configuration;
`ipc2file.previous` is the previous event consumer. `recorder.md5` records the
unchanged vendor executable, and `native-validation.log` records the temporary
metadata debug output. No metadata library was installed before this change.

After the later timezone deployment, restore the local-time backup first to
return to this deployment's unchanged timezone settings. To roll back motion
metadata, stop `mp4record`, restore `script/service.sh` from this archive
and `bin/ipc2file` from `ipc2file.previous`, restart the existing event consumer,
remove `lib/record_metadata.so`, then restart the recorder. Configuration
restoration is unnecessary because this change retained those files. With the
old y28ga service script, enable VENC1 before starting its main-only recorder,
allow initialization to finish, then reapply the configured stream policy.
