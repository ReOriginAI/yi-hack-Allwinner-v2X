# Six-second SD recording preroll

The audited y623 and y28ga recorders now seek up to **6,000 ms** back into the
existing encoded frame ring when a new motion recording starts. This changes
both the native comparison and its subtraction, including y623's short-record
path. Merely changing the `movw #3000` instruction leaves the subtraction at
three seconds and does not implement six-second preroll.

Live investigation also found a separate fault on both cameras: the shared
ring's cached latest timestamp was `2311669270` / `2311675859`, while actual
packet timestamps were approximately `690000000`. The vendor producer retains
the cached value when packet timestamps move backwards, so it can freeze after
a backwards clock correction. Using that stale value made the recorder seek
past every retained frame and wait for new video. Increasing the lookback
literal alone would have left this problem intact.

The replacement duration helper reads only the 28-byte retained packet headers
under the recorder's existing semaphore lock and computes the span using their
own clock. It checks lengths, buffer wraparound and millisecond-clock wraparound.
It runs when seeking a new clip; it does not continuously scan, copy video,
allocate a frame queue, or create a daemon. The native first-keyframe hook sets
MP4 creation time to that frame's UTC seconds. y623's recording filename follows
the same frame time, and y28ga retains its existing local-time conversion fix.
Embedded motion offsets therefore account for preroll without postprocessing.

Each model adds a 536-byte ARM extension to an SD copy of its native recorder,
with one additional 4 KiB executable mapping page. Original ELF sections and
addresses stay intact; the read-only vendor filesystem is unchanged. Both
stock and resulting binary hashes are checked. Unknown firmware keeps its
stock recorder. y28ga retains the previously audited main-only muxer and its
bounded subencoder-header warmup.

| Model | Stock recorder MD5 | Current patched recorder MD5 |
| --- | --- | --- |
| y623 | `c4ee01f6491b26a37db8d92c59605496` | `06774adfc4368e7dede2ea618a96c2b6` |
| y28ga | `d3aff9fb80bc1d61ec78de281e6e9784` | `0d7a4ca9e73fd75806a6ebb75a8accbc` |

The earlier y28ga main-only hash `c541480baa510ad34944e9e763c6b505` is also
accepted as an upgrade input. The extension payloads are built by
`src/ipc_cmd/compile.ipc_cmd`; installation uses `prepare_mp4record.sh` and
`check_conf.sh`. Recorder metadata loading and encoder gating recognize the
new hashes. The persistent bootstrap verifies the updated startup scripts and
both extension payloads before starting services.

## Limits and live validation

Six seconds is a requested lookback, not a guaranteed minimum. The existing
encoded rings are 917,504 bytes on y623 and 1,048,576 bytes on y28ga. More complex
motion can raise bitrate and reduce retained time. A clip must start at a
decodable keyframe, which also shortens the available preroll. Observed keyframe
spacing was about 2.69 seconds on y623 and 2.00 seconds on y28ga. No extra video
RAM was allocated to promise a fixed six seconds.

Validated on 2026-10-11:

| Camera | Native MP4 | First frame UTC / local Eastern | START offset | Duration |
| --- | --- | --- | --- | --- |
| `.150`, y623 | `W415M41S19.mp4` | `04:15:41Z` / `00:15:41` | 5,295 ms | 18.624 s |
| `.199`, y28ga | `14M38S22.mp4` | `04:14:38Z` / `00:14:38` | 4,442 ms | 22.016 s |

Both first recorded IDR payloads matched frames independently captured from
live RTSP. First-frame overlays, local filenames and MP4 UTC creation time
agreed. FFprobe read embedded START/STOP transitions with complete history, and
all native H.264/AAC tracks decoded without errors. y623 retained high and low
video plus 16 kHz AAC; y28ga retained main video plus 16 kHz AAC. The y623 file
also uploaded through the existing FTP pipeline and was downloaded intact from
`/FTPfiles/yicamFront/2026Y10M11D00H/W415M41S19.mp4`.

The y28ga check used the camera's six-second test event. The y623 recording
contains a detector START before that test event; repeated STARTs are
deduplicated. Preroll helps retain the beginning of a motion that triggers an
event. A movement that never triggers detection still needs detector tuning.
Motion sensitivity was retained at its current user-selected value (8 on
y623); encoder/keyframe settings and FTP credentials were retained.

Both cameras were rebooted with the updated persistent bootstrap. All 37
startup integrity checks passed, the expected patched recorder was mounted,
and each native recorder had two threads with the metadata preload and
Eastern DST timezone. Standard RTSP negotiation, PCMU backchannel delivery,
speaker release and silent offline TTS passed on both after reboot.

Run `python3 scripts/test_record_preroll.py` for host regressions. After building
the ARM extensions, `--vendor-dir DIR` also verifies real stock or legacy
recorder patch output, executable mapping, idempotency and refusal of unknown
firmware even with a valid cached patch. Vendor binaries are not committed.

## Backup and rollback

Each camera retains `/tmp/sd/yi-hack/.preroll-backup-20261011/` with the previous
recorder, previous bootstrap, the three previous service/patch scripts in
`original.tgz`, and `check_conf.previous.sh`. Updated startup manifests and live
validation results are retained there as well.

Restore the complete startup set and matching bootstrap together. Stop the
recorder while idle, restore the archived scripts and previous `check_conf.sh`,
detach the recorder bind mount, restore the previous bootstrap, and reboot.
The y28ga previous recorder is its main-only build; its original startup helper
will regenerate or reuse that exact image. Restoring one startup script alone
would fail the bootstrap integrity check.
