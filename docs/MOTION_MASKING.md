# Motion exclusion masks

Camera Settings → Local Motion Detection includes a 20-column, 12-row exclusion
editor on the audited y623 firmware. Paint cells red to ignore them, enable the
mask, and save. Include all clears exclusions; Ignore all excludes the complete
image. The reference snapshot is fetched only on request. Arrow keys and Space
also operate the editor. The green overlay reports recent block activity while
masking is enabled, including activity inside ignored cells.

Masks affect local motion events and their recordings. They do not obscure or
crop RTSP, SD recordings, snapshots, or FTP uploads. The encoder implementation
is installed on .150. The .199 y28ga uses a separate native IVA foreground-count
implementation described in [MOTION_Y28GA_NATIVE.md](MOTION_Y28GA_NATIVE.md);
it shares the exclusion grid but retains its own native sensitivity and timing.

## Scoring and settings

`MOTION_MASK_ENABLED` defaults to `no`. `MOTION_MASK_CELLS` contains exactly
240 `0`/`1` characters, left to right, then top to bottom: `1` ignores a cell.
The mask remains in camera.conf and is applied live through a detector restart.

The spatial score is the percentage of the entire visible 640×360 image covered
by included moving macroblocks. Excluded areas contribute zero. The denominator
does not shrink when regions are excluded, so masking does not increase the
sensitivity of the remaining image. The bottom coded macroblock row contributes
only its eight visible lines; encoder padding is not motion area.

An inter-coded block counts when any of its four packed motion-vector pairs
reaches `MOTION_MASK_VECTOR_PIXELS` (default 1, range 1–16 pixels). The native
packed base/residual vector fields are decoded in quarter-pixel units. For
newly intra-coded blocks, `MOTION_MASK_DIFFERENCE` compares the encoder's first
per-block difference byte against the previous fresh P-frame snapshot (default
12, range 0–255; zero disables this additional test). Reference snapshots more
than 500 ms apart or from different encoder processes are not compared.
Full I frames do not count as scene motion and reset that temporal reference.

Existing start/stop percentages, consecutive-sample confirmation, and quiet
delay apply to the spatial score when masking is enabled. Whole-frame
MovingLevel hints cannot override an exclusion. When masking is disabled, the
existing vendor whole-frame detector remains unchanged. These two scores have
different definitions; tune the spatial thresholds using its live chart.

## Data acquisition and failure behavior

`motion_map.so` loads alongside the existing night-vision library in `rmm`.
The launcher accepts only the audited y623 motion-lite executable MD5
`eb9d532e71d0d8697d22d0775b744b40`. The library additionally verifies its native
cache callback table and relevant call instructions before installing a wrapper
around that table's cache callback. Other models and unknown layouts are untouched.

The wrapper always calls the original cache operation first. Only its existing
substream motion-analysis call at `0xaf6bc` publishes data, after the native
encoder has completed hardware processing and refreshed its SAD and motion-vector
caches. It copies the existing 7,360-byte vector buffer and extracts 920
difference bytes from the existing 5,520-byte SAD buffer. No video is decoded,
new capture stream created, hardware buffers altered, or original encoder
statistics changed.

The shared snapshot `/tmp/yi-motion-map` is 8,328 bytes (12 KiB of tmpfs pages).
Publication uses an odd/even generation counter. The detector tries at most twice
and never waits for the writer. Overlapping publications retain the last coherent
score; duplicate frames do not accumulate extra confirmation samples. Snapshots
older than 500 ms are unavailable. On startup, confirmation waits up to one second
for the first snapshot before allowing fallback. A source that publishes fresh
snapshots but no usable predicted frames for over two seconds also becomes
unavailable; freshness alone does not establish usable motion data.

If the map becomes unavailable, whole-view detection resumes and the UI reports
the fallback explicitly. This favors continuing recording over silently losing
events, but exclusions are not enforced during fallback. Publication is requested
only while masking is enabled; abandoned requests expire after two seconds.
The encoder callback performs no per-frame allocation, filesystem writes, locks,
or diagnostic logging. VENC1 stays running whenever enabled motion detection uses
a mask, including when the recorder is disabled and RTSP selects High.

## Metadata and validation

The `yi_motion` schema and raw vendor values are unchanged. Masking selects the
active intervals and trigger that determine which readings are captured; it does
not substitute the spatial score for `BinImgRatio` in video metadata.

Software tests exercise left/right exclusions through actual detector processes,
signed packed vectors, intra-block changes, padded boundaries, I frames, stale
and duplicate frames, encoder restart references, whole-view fallback, native
cache-call preservation, publisher layout guards, and API rejection/persistence.
Run `python3 scripts/test_motion_mask.py` and `python3 scripts/test_motion_tuning.py`.

Physical left/right motion testing was deferred at the user's request. Spatial
layout follows the audited native row-major macroblock loop; detection performance
with actual excluded subjects still needs that live test.

Installed on .150 on 2026-10-14 with a recovery copy under
`/tmp/sd/yi-hack/.motion-mask-backup-20261014/`. After reboot, an isolated detector
read the actual encoder snapshots with no publication errors (66 ms sample age
in the captured check); it sent no recording IPC. Browser checks verified
painting/clearing, reference snapshot retrieval, malformed-mask rejection, and
save/readback. Existing settings were preserved, with only the four disabled,
empty-mask defaults appended. The Standard RTSP stream still advertised
2304×1296 H.264 and AAC; recording service, night vision, and all boot-manifest
checks passed. At initial installation the mask was disabled until the user
selected areas.

## Frame-type repair, 2026-10-14

The first publisher incorrectly used native type `18` as a predicted-frame test.
The audited encoder's `ae458..ae474` code marks type `18` as a key frame; normal
predicted frames use type `0`. This reversed flag caused every ordinary frame to
receive a zero spatial score even though snapshots were fresh. The initial
software publisher fixture repeated that incorrect type assumption.

The corrected publisher emits protocol version 2 and sets `p_frame` when the
native type is not `18`. The corrected reader also normalizes the reversed flag
in version-1 snapshots, allowing installation while the current encoder keeps
running. It checks the version on each snapshot so a later encoder restart can
switch to the corrected publisher without restarting the reader again.

Regression checks cover native types `0` and `18`, both protocol versions, a
producer upgrade in place, and fresh-but-unusable frame types falling back to
whole-view detection. During repair, masking was temporarily disabled to restore
recording. The user's painted cells and all thresholds were preserved, then the
saved mask was re-enabled after installing the corrected detector. The isolated
live detector observed nonzero activity and motion transitions, including a
1.889% included spatial score. The encoder, recorder, and event collector kept
their PIDs throughout the repair. Recovery assets are under
`/tmp/sd/yi-hack/.motion-mask-repair-backup-20261014/`.
After the saved mask was re-enabled, the user confirmed that environmental
motion produced recordings. The production detector log also showed a new
`MOTION ON ... IPC=START` followed by `MOTION OFF ... IPC=STOP`, with the mask
enabled and no map or delivery error in the final telemetry. A controlled
ignored-area-only test remains separate from this successful included-motion
recording check.
