# Motion timestamps in SD recordings

New SD-card MP4 recordings on audited y623 and y28ga recorders contain a
`yi_motion` JSON tag. The recorder writes this tag while finalizing its own open
file, before closing and renaming it. No completed-file job, video remux, encoder,
sidecar, or additional daemon is involved. Live RTSP is unchanged.

The existing `ipc2file` consumer captures generic motion START/STOP events in
a bounded, shared RAM history at `/tmp/yi-motion-events`. This tmpfs file is
shared state, not a video sidecar. The vendor broker translates these events
into recording commands, so observing only the recorder's IPC queue would miss
the motion transitions. Metadata uses the original generic events, including
the alternate firmware START message, and ignores human/vehicle/animal events.
The consumer blocks on its existing queue instead of delaying every event by
500 ms. ONVIF does not need to be enabled for the local motion consumer to run.

The recorder-local `record_metadata.so` reads a snapshot when closing a clip.
It skips media data using MP4 atom sizes, reads small container headers, appends
`moov/udta/meta/ilst/----`, and updates the four-byte `moov` size. Encoded video,
AAC, track tables, and media offsets stay unchanged. This implementation supports
the audited muxers whose finalized `moov` is last in the file; incomplete or
unrecognized layouts are skipped. A failed metadata write attempts to restore
the original size and truncate the metadata tail.

## Reading the tag

Use a host with FFprobe and jq:

```sh
ffprobe -v error -show_entries format_tags=yi_motion -of json recording.mp4 |
    jq '.format.tags.yi_motion | fromjson'
```

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
`source` identifies the camera's motion pipeline: `encoder-stats-ipc` on y623,
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

## Footprint and supported recorders

The history holds at most 512 transitions in 8,240 bytes, shared between the
existing consumer and recorder. Closing a clip uses an approximately 8 KiB
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
filtering, deduplication, clip windows, history overflow, FFprobe JSON readback,
audio/video decoding, unchanged `mdat` and `trak` bytes, reopening completed
files, simulated metadata write failure, incomplete-container handling, and
y28ga idle startup and timeout behavior.
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

The current stripped library, including the local filename correction, is
12,236 bytes, SHA-256
`37e2709af6aa122a7776a33d466b2d3187424d2a52029f9aab46cdf41bec8c1c`.
The updated event consumer is 13,456 bytes, SHA-256
`ff3ad1f177bb5c7fc3c2e2004ca3abb8e493520418734258ec87253bd37eaf4a`.

## Backup and rollback

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
