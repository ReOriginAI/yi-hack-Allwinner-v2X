# y28ga native motion regions and spatial data

Read-only SSH inspection of 192.168.1.199 on 2026-10-14. No detector settings,
production files, capture streams, or recording decisions were changed. The
temporary process-memory reader opened `/proc/1493/mem` read-only; it did not
attach a debugger, stop threads, or invoke the detector.

## Findings

The y28ga has native spatial functionality, through its existing generic IVA
detector. It differs from the y623 encoder-vector publisher described in
[MOTION_MASKING.md](MOTION_MASKING.md).

| Capability | Evidence | Limit |
| --- | --- | --- |
| Input detection rectangle | `rmm` passes a rectangle into `ivaDetectMotion`; its core reads the coordinates during foreground counting | One rectangle, not an arbitrary grid mask; recording behavior needs validation |
| Internal foreground images | Live context contains existing 640×360 byte images with 640-byte row stride | No exported coherent map getter identified |
| Aggregate motion statistics | `ivaGetMotionStats` copies three 32-bit words | These words do not contain spatial locations |
| Existing raw capture input | VI2 is already producing 640×360 NV21M frames at 20 fps | Independent of whether the low-resolution video encoder is running |

No arbitrary exclusion-mask setter or y623-style `GetBinImageData` interface
was identified in the audited binaries. This is a finding about this firmware,
not proof that no other vendor build has those interfaces.

## Audited binaries and native call

- Firmware: `9.0.20.06_202007061841`.
- Live `rmm` MD5: `14aa4ee21e04fb40a3c321fdcd12eef4`.
- Live `libYiHm_L1.so.4.1.9` MD5: `4f8a5e2b22bfe34b5a55d99bc87512ee`.
- `rmm` calls `ivaInitMotionContext` at `0x23ff0` with dimensions 640×360.
- `rmm` calls `ivaDetectMotion` at `0x21394`, passing the existing frame,
  context, rectangle, and a 64-bit time value. The exported Thumb wrapper at
  library ELF address `0x1214c` forwards to the core at `0xe4c0`.

The wrapper queues work to the library's worker thread and waits for completion
when called from another thread. Calling it again from a map reader would add
detector work and could block. A spatial integration should reuse the result of
the existing invocation.

## Rectangle semantics and the recording caveat

`rmm` builds the rectangle at virtual address `0x159fac` from four signed
16-bit configuration fields at configuration offset `0x630`. It scales the X
coordinates to 640 pixels and Y coordinates to 360 pixels. The arithmetic
divides `640 * x` by 1280 and `360 * y` by 720, corresponding to a 1280×720
configuration coordinate space. A zero end coordinate falls back to
the full width/height. The live rectangle was `[0, 0, 640, 360]`, in the order
`[x_start, y_start, x_end, y_end]`.

The core reads these values at `0xeb0e` and uses coordinate comparisons in
its foreground-counting loop, including `0xef04`–`0xef14`. This establishes
that the rectangle is an input region, rather than just an output bounding
box. The subsequent replay established inclusive coordinate comparisons in
the foreground loop. Physical image orientation still needs controlled
spatial validation.

However, the core also counts foreground outside the rectangle. Around `0xebe0`–`0xec22`
and `0xf0c2`–`0xf0de`, it derives result flags from both inside-region and
outside-region counts. `rmm` initially tests the returned value for any nonzero
result at `0x213dc`–`0x21410`. Consequently, simply changing the rectangle is
not yet established as a strict recording exclusion. The downstream flag
handling and outside-only motion must be validated before exposing it as one.

The current `ipc_cmd` interface does not expose these four region coordinates.
This inspection did not send undocumented IPC commands or change that native
configuration.

## Existing map storage and cost implications

A 4 KiB read around the `vi_get_yuv_data` thread's current stack identified
its live 180-byte IVA context. Its descriptors matched the library allocation
code at `0x109a4`–`0x10a2a`:

| Context offset | Width | Height | Row stride | Image bytes |
| ---: | ---: | ---: | ---: | ---: |
| 44 | 640 | 360 | 640 | 230,400 |
| 60 | 640 | 360 | 640 | 230,400 |
| 76 | 640 | 360 | 640 | 230,400 |
| 92 | 640 | 360 | 640 | 230,400 |
| 108 | 640 | 360 | 640 | 230,400 |
| 124 | 642 | 360 | 642 | 231,120 |

These total 1,383,120 bytes (about 1.32 MiB), already allocated by the vendor;
they are not proposed additional RAM. The core uses the offset-76 and offset-92
images for byte-valued foreground processing. A small read of the offset-76
buffer succeeded; its first two border rows were zero at that instant. This
does not validate spatial activity across the whole image.

The library exports the misspelled `ivaGetForgroundPixCount` at `0xcea8`, which
counts a specified byte value inside a rectangle of an image descriptor. Its
existence is useful evidence of native spatial primitives; it is not a getter
that returns the detector's internal image. The core's own image processing is
largely inlined, so interposing that export alone would not implement masking.

Reusing existing foreground processing would avoid a second encoder, video
decoding, a second detector, and potentially a full private NV21 frame copy.
A 20×12 grid of 32-bit counts would have only 960 bytes of counter payload,
but publication, synchronization, and any additional scan still have costs.
No integration CPU or latency measurement was made in the initial inspection.
The earlier full-frame copy benchmark in
[MOTION_ZONES_FEASIBILITY.md](MOTION_ZONES_FEASIBILITY.md) does not measure an
IVA foreground-map implementation.

For arbitrary ignored cells, the next implementation candidate is a bounded
hook at the existing foreground-processing boundary that applies the mask
before the vendor's motion counters/result are updated, or publishes small
grid counts for a separate masked decision. It must preserve native reset,
reference-frame, whole-frame result, and recorder behavior. Reading a changing
process-local image from a second process is not a coherent production API,
and shared capture frames should not be modified in place.

## Validation and cleanup

Live VI statistics showed VI2 at 20 fps with three 356,352-byte capture buffers.
Its error counter was zero; its frame count continued increasing. The low
encoded VI1 path remained inactive. The recorder and event collector retained
PIDs 1692 and 1668; `rmm` retained PID 1493. The temporary inspection reader
was removed from the camera after use. Private disassembly and compact
inspection results are retained under `/tmp/yi-motion-zones-20261014/y28ga/`.

The initial investigation installed no mask. Subsequent implementation and
synthetic native-detector validation are described below; physical
included-versus-ignored recording validation remains outstanding.

## Subsequent native mask implementation

`motion_iva.so` installs a guarded, process-local Thumb branch at the existing
foreground-count boundary (`libYiHm` ELF address `0xebba`). The native loop has
finished its morphology at that point. `r4` contains foreground outside the
vendor rectangle; the replaced instruction loads `fp` with foreground inside
it. The bridge preserves all integer registers, native LR, all 32 VFP registers,
FPSCR, and arithmetic flags, apart from the two intended counts.

The hook counts the existing final foreground image into a 20×12 grid of
32×30-pixel cells. An enabled exclusion mask removes ignored pixels from both
native count categories before the original sensitivity, consecutive-motion,
brightness checks, and result generation continue. It does not alter capture,
the foreground image, reference images, the native rectangle, or classifiers.
Changing an enabled mask resets only the two audited motion confirmation
counters, so evidence from the previous mask cannot carry into the new one.

Every scan checks that its unmasked count equals the sum of the vendor's two
original counts. Invalid geometry or a counter mismatch preserves the original
counts, allowing whole-view recording and reporting the fallback. This guard is
intended to prevent an incorrect spatial interpretation from silently
disabling recordings.

The launcher requires both audited binary hashes above, the y28ga model, and
expected instruction bytes. Unsupported versions retain native recording.
Settings and grid publication use a 1,264-byte shared structure (one 4 KiB tmpfs
page). Grid counts occupy 960 bytes; per-call scratch and the bridge also use
stack. The shared library has its own mapped code/data pages. There is no extra
video-frame buffer, encoder, decoder, classifier, or persistent worker thread.
The native worker scans when masking is enabled, or briefly while the UI
requests live foreground readings. With masking disabled and no live reader,
the scan and publication are skipped.

The final ARM SIMD version averaged **0.7509 ms CPU per processed native sample**
in isolated replay, including the filter body and bounded publication. This
is about **0.094% of one core at 1.25 processed samples/s**, or **1.50% at 20/s**;
these are rate extrapolations, not whole-system measurements. Native processing
cadence depends on sensitivity and night/day settings. Synthetic frame creation
took approximately 35 ms per replay frame and is excluded from this incremental
cost: the live camera already supplies frames. End-to-end physical detection
latency was not measured.

The isolated replay uses the actual vendor library, with human-classifier
initialization/evaluation stubbed in the private test process. It sends no IPC
events and touches no production capture or detector. Results were:

| Synthetic motion and native rectangle | Original / mask disabled | Ignore left half | Ignore all |
| --- | ---: | ---: | ---: |
| Left motion, full rectangle | 9 nonzero results | 0 | 0 |
| Left motion, left rectangle | 9 | 0 | 0 |
| Right motion, left rectangle | 10 | 10 | 0 |

The final SIMD left-mask run checked 39 processed foreground samples with zero
counter mismatches. The scalar release path also passed Ignore all and
disabled-mask restoration. Portable regression tests cover boundaries,
inside/outside counts, malformed controls, writer collisions, changed masks,
counter/geometry fallback, and idle-reader scan suppression. Run
`python3 scripts/test_motion_iva.py` and `python3 scripts/test_motion_tuning.py`.

The UI presents the existing paintable exclusion grid and a live chart of raw
and included foreground percentages. It retains y28ga's native Low/Medium/High
sensitivity controls and hides y623 vector/intra-block controls. New mask
settings default to disabled with all cells included. Video and audio stay
complete; this is a detection mask. y28ga MP4 metadata retains `yi-motion-v1`
event rows; raw foreground counts are diagnostics, not new video metadata.

Installed .199 assets and bootstrap integrity records have recovery copies
under `/tmp/sd/yi-hack/.motion-iva-backup-20261014-v2/` and
`/tmp/sd/yi-hack/.motion-iva-optimized-backup-20261014/`. A failed first install
rolled its assets back because the camera lacks `cmp`; the subsequent installer
used MD5 comparisons and preserved both configuration files byte for byte.

Final live checks confirmed the hook ready with fresh samples and no errors,
the visible exclusion editor and foreground graph, paint/clear and keyboard
editing, malformed-mask rejection, and an Include all enable/disable round trip
through the actual camera API and native worker. All original camera settings
retained their values; that API test added only the four disabled/empty mask
defaults. The native encoder, recorder and event collector stayed running during
those setting changes. Final masking is disabled, with every cell included.

Standard RTSP still advertised 1920×1080 H.264 and 16 kHz AAC, with the configured
G.711 backchannel option. Native night vision reported Automatic, threshold 50,
applied. VI2 continued at 20 fps with zero errors while the low encoded VI1 path
remained inactive. The final bootstrap manifest verified all installed assets.
TTS and audio files were not changed by this update. Temporary device-side
replay and deployment files were removed; recovery copies remain on the SD card.
