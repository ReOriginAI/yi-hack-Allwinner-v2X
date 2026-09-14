# y623 buffer trace — 2026-09-14

Read-only inspection of 192.168.1.150, rmm PID 1436, running binary MD5
`45be10e9be161e4c36e9ce48958abb9f`. The newer no-YUV binary was not deployed.
Both encoder channels remained configured for 20 fps. No capture-buffer counts,
VBV sizes, audio settings, or running processes were changed.

## The 12 MiB is an aggregate, not an unused allocation

`/sys/kernel/debug/ion/clients/1436-1` reports 12,582,912 bytes in sys_user.
The 32 DMA buffers attached to `1c0e000.ve` in
`/sys/kernel/debug/dma_buf/bufinfo` sum to **exactly 12,582,912 bytes**.
This reconciles the ION client total with active video-encoder allocations.
It is not evidence of a separate AI reservation or a reclaimable 12 MiB pool.

Breakdown:

| Encoder allocations | Bytes |
| --- | ---: |
| Two large main-channel buffers (purpose within codec not yet established) | 9,437,184 |
| Main VBV, page rounded | 1,249,280 |
| Substream VBV, page rounded | 311,296 |
| Remaining encoder allocations | 1,585,152 |
| Total | 12,582,912 |

The two large buffers are each 4,718,592 bytes and are mapped by VEncComp.
Do not remove them based on their matching sizes: separate codec working/reference
surfaces can have identical sizes. Their precise codec roles remain unproven.

## VI2 is still allocated and advancing

The VI debug output reports a 640x360 NV21M VI2 stream with three 356,352-byte
frames. Its counter advanced between samples. The ION clients expose each frame
as separate 237,568-byte and 118,784-byte planes: six allocations totaling
**1,069,056 bytes (1.0195 MiB)**. The earlier interpretation that these allocations
were absent was incorrect; the plane split concealed the matching frame size.

The current patch begins at file offset 124076 / virtual address 0x2e4ac.
Disassembly shows VI2 setup is earlier: 0x2e440 loads channel 2 and 0x2e444 calls
the common VI initializer at 0x2bb44. The following call at 0x2e478 reaches the
ISP initialization path at 0x2c1ec. Thus skipping the later block does not skip
the initial VI2 allocation. The no-YUV return stub alone does not alter these
initialization instructions either.

Best next experiment: suppress only unused VI2 allocation/activation while
preserving required ISP initialization and VI0/VI1. Do not blindly return from
the containing initializer. Earlier snapshot success with a disabled YUV feeder
does not prove snapshots work with VI2 entirely absent.

## Encoded-frame wraparound scratch buffers

The grow-only helper at virtual address 0x2739c calls realloc at 0x273f8 when
requested size exceeds capacity. The delivery path calls it at 0x278b4 and
0x27954 to join the two pieces of wrapped encoder output, then memcpy copies
each piece. The nonwrapped branch at 0x279c4 uses the original data pointer.

Derived global arrays, verified by a read-only /proc/1436/mem read:

| Channel | Scratch pointer | Retained capacity |
| --- | --- | ---: |
| Main | 0xb5215010 | 1,197,636 bytes |
| Sub | 0x004b1000 | 80,589 bytes |

Pointers begin at 0x224a00; capacities begin at 0x224a10. Main pointer matches
the 1,172 KiB resident anonymous mapping attributed to venc_get_videos.
The helper does not shrink capacity. Large prior wrapped payloads can therefore
leave resident scratch memory even when current payloads are small.

Candidate: let downstream parsing/publication accept two spans, preserving
encoder-buffer lifetime until publication completes. This could remove the
scratch copy without reducing queue capacity or frame rate. It requires tracing
all downstream consumers, including start-code parsing across the split, and
cannot safely be implemented as a smaller fixed allocation. A less invasive
reclamation policy would need allocator/latency measurements to avoid churn.

## Preserve throughput

Keep all three main capture buffers, configured 20 fps on both streams, and
current VBV capacities during initial experiments. A low instantaneous VBV
occupancy does not establish a safe smaller limit. The large retained scratch
capacity further argues against guessing a small maximum frame size.

Before promoting a patch, compare VI loss-counter deltas and received frame
counts under simultaneous main/sub RTSP, local recording, motion, snapshots,
and audio playback. Test day/night transitions and large keyframes. Exact savings
and absence of frame regressions remain unmeasured for the proposed changes.
