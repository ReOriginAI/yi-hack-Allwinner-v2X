# Motion exclusion zones: feasibility investigation

The subsequent .150 implementation and validation are documented in
[MOTION_MASKING.md](MOTION_MASKING.md). Measurements below describe the earlier
process-memory probes, rather than the implemented encoder-owner snapshot path.
The subsequent .199 native rectangle and foreground-buffer investigation is
documented in [MOTION_Y28GA_NATIVE.md](MOTION_Y28GA_NATIVE.md).

Read-only inspection of the live .150 and .199 devices on 2026-10-14, plus
resource probes. The user selected resource measurements only, so spatial
layout and detection behavior were not tested with controlled motion. No
detector settings, production binaries, or recording decisions were changed.

## y623 at .150

The captured `rmm` matches the live executable, MD5
`eb9d532e71d0d8697d22d0775b744b40`. Its encoder contains the binary-image interface:

- `AW_MPI_VENC_EnableBinImage`: entry at `0x680ec`, component setting
  `0x7f00213f`, ultimately encoder parameter `0x50d`.
- `AW_MPI_VENC_GetBinImageData`: entry at `0x681d4`, component query
  `0x7f002140`, ultimately encoder parameter `0x50e`.
- The component query prepares a capacity/buffer argument and calls
  `VideoEncGetParameter` at `0x991ec`.
- The `0x50e` wrapper surrounds the codec callback with VE-operation hooks.
  Those hooks mean a getter call cannot yet be assumed to be wait-free.
- The H.264 `0x50e` branch at `0xa4600` checks caller capacity. The successful
  branch at `0xa4b9c` performs a cache-maintenance callback, copies the existing
  encoder buffer with `memcpy`, and returns the copied byte count. That branch
  has no video decoding, frame conversion, or allocation.

The related block-buffer allocation at `0xa8cac` uses an aligned macroblock
width, macroblock height, and eight bytes per macroblock row entry. For a
2304×1296 frame this gives `144 * 81 * 8 = 93,312` bytes. Live read-only inspection
of `/proc/<rmm_pid>/mem` confirmed both channels already have this buffer
allocated and its enable flag set to one:

| Channel | Coded dimensions | Macroblocks | Existing block-buffer bytes |
| --- | --- | --- | ---: |
| Main, 0 | 2304×1296 | 144×81 | 93,312 |
| Substream, 1 | 640×368 (padded height) | 40×23 | 7,360 |

Fresh substream block data depends on VENC1 continuing to encode frames. An
allocated buffer alone is insufficient if the encoder is stopped. On the
measured .150, VENC1 was already running while `RTSP_STREAM=high`: the current
`rtsp_stream_venc.sh` recording-compatibility policy keeps it enabled when
`mp4record` is running. The probe did not enable it. The incremental CPU figures
below exclude the cost of running VENC1; they apply to reusing an already active
encoder. If VENC1 would otherwise be stopped, its additional encoding cost must
be measured before choosing this approach. The .199 main-only recorder has a
separate policy that can stop VENC1, so the same assumption does not apply there.

The block buffer packs motion vectors, an intra flag, and texture information
in eight bytes per macroblock; it is not a simple binary motion mask. The native
analysis loop extracts four signed residual vector pairs, signed base vectors,
and the high-byte texture value. The correspondence between these values and
the vendor SAD-based `BinImgRatio` has not been established. The probe counts
vector magnitudes using an illustrative threshold, with the left half excluded;
that count is not a replacement for the vendor motion score. Sub-block spatial
ordering, intra-block treatment, and suitable detection thresholds need testing.

The live encoder context was resolved through the existing channel list, rather
than hard-coded heap addresses. The prototype is specific to the audited binary
and requires an executable hash check before running. It neither calls the SDK
nor attaches a debugger, writes target memory, or starts another capture stream.

The current `/sys/kernel/debug/mpp/ve` exports aggregate scene/motion summaries
and histograms, not spatial block data. `motiond` cannot recover locations from
those summaries. A spatial implementation would need access to the encoder's
process-local context, then publish a bounded snapshot or masked score in RAM.
Keeping synchronous encoder calls outside `motiond`'s sampling loop would avoid
turning a slow getter into a detector stall.

Live VI statistics also show a 640×360 NV21M VI2 stream, despite the fork's
bypassed analytics routines. Bypassing the analytics setup/consumer therefore
does not prove every raw VI2 producer was stopped. Re-enabling PilotAI is not
required by the proposed encoder-statistics approach.

## y28ga at .199

SSH inspection confirmed the live `rmm` MD5
`14aa4ee21e04fb40a3c321fdcd12eef4`, matching the retained motion-lite binary.
Its MPP debug directory contains VI statistics but no VE statistics node.

VI2 already supplies the generic IVA path with 640×360 NV21M frames. The driver
reports three 356,352-byte buffers; the nominal unpadded NV21 image is 345,600
bytes. Any buffer manipulation must respect the actual plane strides and padding.

The live `libYiHm_L1.so.4.1.9` exports `ivaDetectMotion`,
`ivaInitMotionContext`, `ivaResetDetectMotion`, `ivaSetSensitivityLevel`,
`ivaAbsdiff`, and `ivaGetMotionStats`. The existing `rmm` calls `ivaDetectMotion`
through its PLT at `0x21394`, passing an existing frame pointer. The exported
`ivaGetMotionStats` at `0xe2bc` copies three 32-bit words from library state;
it does not return a pixel/block map. No equivalent `GetBinImageData` interface
was identified in this older executable.

An alternative candidate is to mask an existing difference buffer within IVA,
or pass a reusable private copy of its existing input with excluded areas held
constant. This could reuse the capture stream already running. The IVA context,
reference-frame behavior, input layout, and any other consumers must be checked
before applying such a change. Modifying shared capture frames in place would
not be an appropriate detection-only mask.

## Isolated copy cost

A small ARM executable copied synthetic buffers 500 times at a lower scheduling
priority. `CLOCK_PROCESS_CPUTIME_ID` measured CPU time, not end-to-end detector
latency. Both devices continued running their existing services.

| Device | Bytes copied per iteration | Mean CPU time | Estimated CPU at 10 copies/s | At 20 copies/s |
| --- | ---: | ---: | ---: | ---: |
| .150 | 93,312 | 70.944 µs | 0.0709% of one core | 0.1419% |
| .199 | 345,600 | 580.906 µs | 0.5809% of one core | 1.1618% |

These numbers cover copying only. They exclude map generation, VE locking,
cache maintenance, mask computation, buffer publication, and vendor detection
work.

## Read-only acquisition and mask measurements

`experiments/motion_block_probe_y623.c` reads the existing .150 buffer twice,
checks an encoder frame counter before and after the reads, compares the copies,
then filters vector data only when both checks pass. Each run took 100 samples
with a 100 ms sleep between samples, at nice level 15. CPU cost includes memory
reads, consistency checks, and filtering; the CPU percentage extrapolates to
exactly ten attempts per second. Wall time includes scheduling delays.

| Probe | Mean CPU / attempt | CPU at 10 Hz | Mean wall time | Maximum wall time | Consistent / fresh reads | Snapshot scratch |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| .150 main buffer | 2.018 ms | 2.018% of one core | 6.547 ms | 126.710 ms | 50 / 100 | 182.25 KiB |
| .150 substream buffer | 0.298 ms | 0.298% | 0.728 ms | 12.245 ms | 97 / 100 | 14.375 KiB |

There were no failed memory reads. Every accepted sample had a different frame
counter from the previously accepted sample. The main-buffer cost includes
filtering on only half of the attempts: reading averaged 0.875 ms CPU, while
the checks/filtering averaged 1.134 ms across all attempts. Do not interpret its
2.018% result as the cost of ten fully filtered main-stream samples per second.
The separate substream probe process had 496 KiB resident memory, of which
44 KiB was anonymous memory. Its total includes executable/shared-library
pages; the 14.375 KiB snapshot scratch figure is not total process RAM.

These checks detect overlapping updates but do not guarantee an atomic snapshot
of a DMA/encoder buffer. The observed rejected reads and wall-time tails make
this process-memory interface unsuitable as a synchronous production detector
input. A production implementation should publish a bounded, coherent snapshot
from the encoder owner and have a separate worker consume the latest snapshot.
The existing low-resolution buffer is the first candidate because its measured
resource cost is much smaller. Do not make `motiond` wait for acquisition.

On .199, `experiments/motion_input_mask_bench.c` copied 356,352 synthetic bytes
and filled the left half of a nominal 640×360 NV21 image with constant luma and
chroma values. Its 100 attempts, also separated by 100 ms at nice level 15,
averaged **1.300 ms CPU (1.300% of one core at 10 Hz)**, with **3.576 ms mean
wall time** and **77.383 ms maximum wall time**. A private destination would
require **348 KiB**; the benchmark also allocated a source to stand in for the
existing camera frame. This was not an IVA integration test. Actual plane
strides, buffer access, reference-frame handling, and detector behavior remain
unverified. A difference-buffer mask might avoid the full copy, but no safe
hook for that has been established.

Resource cost appears manageable for the substream-buffer approach on .150 and
the private-frame approach on .199. These measurements do not establish correct
exclusion zones, production snapshot overhead, or end-to-end detection latency.
Measurements and disassembly notes are kept privately under
`/tmp/yi-motion-zones-20261014/`.
The encoder, native recorder, and event collector retained their original PIDs
on both cameras after the probes. Temporary device-side probe executables were
removed after measurement.

The remaining validation is coherent buffer publication and controlled spatial
motion testing on .150, plus a safe existing-frame or difference-buffer hook on
.199. Raw vendor metadata should remain raw, with any masked detection score
identified separately.
