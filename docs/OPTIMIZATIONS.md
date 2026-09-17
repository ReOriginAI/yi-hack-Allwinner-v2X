# Yi Allwinner v2X Optimization Inventory

This document records the performance, memory, reliability, and local-only optimizations added by the ReOriginAI fork, along with the experiments that are **not** yet part of the firmware. It is intentionally scoped to fork-specific work rather than inherited upstream behavior.

It exists to keep release engineering and future debugging grounded in what the repository actually implements rather than in one-off live-camera experiments.

Current reference state: `95b9b4d` and later.

## Design goals

The supported cameras have a very small Linux memory budget (roughly 60 MiB available to the OS), so the fork is optimized around a few rules:

- Preserve the vendor media core (`rmm`) and Wi-Fi control path.
- Remove vendor/cloud work that is unnecessary for local RTSP/ONVIF use.
- Avoid raw-frame/AI paths when encoded-stream statistics are sufficient.
- Let the kernel make OOM decisions, but teach it which services are essential and which are cheaply restartable.
- Prefer dropping/restarting nonessential services over destabilizing `rmm`.
- Make model-specific binary/kernel patches hash-gated and reproducible.
- Treat y623 and y28ga differently where their media pipelines differ.

## Implemented optimizations

### 1. y623 `rmm` motion-lite patch

Source: `src/static/static/yi-hack/script/prepare_rmm.sh`

For the validated y623 vendor `rmm` build, the runtime patcher applies the following changes:

- Bypasses `vi_algo_process`, removing Pilot AI/model initialization.
- Reduces VIPP1 virtual channels from 3 to 1.
- Skips the unused VI2/raw-analysis setup used by the original vendor analytics path.
- Makes `vi_get_yuv_data` return immediately, removing the unused raw-YUV feeder.
- Disables the static Yi/vendor logo-watermark path while retaining timestamp OSD.

The patch is generated from the known stock executable at boot and is refused for unknown vendor binaries.

Known hashes:

- y623 stock `rmm`: `f8164a1c221ba8c1d4888322a3cf0706`
- y623 patched `rmm`: `b8782526e55d4b7ac95060ebcbe7ed18`

The patched executable is bind-mounted over `/home/app/rmm` before `rmm` is launched.

### 2. y28ga `rmm` motion-lite patch

Source: `src/static/static/yi-hack/script/prepare_rmm.sh`

For the validated y28ga vendor build:

- Reduces VIPP1 virtual channels from 3 to 1.
- Bypasses the face/NNA frame processor.
- Bypasses the PTZ tracking frame processor.
- Disables the static vendor watermark while retaining timestamp OSD.

Unlike y623, VI2 is intentionally retained because the y28ga generic IVA motion path depends on it.

Known hashes:

- y28ga stock `rmm`: `46261d809c58dea5b39f3351e322d710`
- y28ga patched `rmm`: `c83016101b3bc9b669139b6b56cbb4d0`

### 3. y623 VE debugfs kernel allocation patch

Sources:

- `scripts/patch_y623_ve_debugfs.py`
- `src/static/static/yi-hack/script/ensure_y623_ve_kernel.sh`
- `scripts/vendor-images/y623-boot-stock.bin`

The y623 vendor VE debugfs snapshot path originally allocates a 32 KiB order-3 contiguous block using `kmalloc_order(..., 3)`. On these small cameras that can contribute to fragmentation and allocation failures under memory pressure.

The patch changes the two relevant kernel call sites:

- `kmalloc_order` -> `vmalloc`
- `kfree` -> `vfree`

Known boot-image hashes:

- validated stock y623 boot: `2c8abc0f8376bdb55d8464abc6bf14a8`
- vmalloc-patched y623 boot: `26a2e9a432fbe36efe97f0e7cee84dc9`

As of the release-engineering fix in `95b9b4d`, this is part of the normal y623 release contract rather than a one-off live patch:

- `pack_fw.sh` regenerates the patched image from the audited stock image.
- CI verifies the exact generated hash.
- y623 firmware archives carry `Factory/boot-vmalloc.bin`.
- upload/upgrade paths reject a missing or altered boot image.
- the on-camera installer accepts only the known stock or already-patched boot hash.
- `--check` preflight rejects unknown/custom boot images before changing userspace.
- flashing is read-back verified, and a failed write attempts to restore the preserved stock image.
- already-patched cameras are idempotent and are not needlessly rewritten.

This image is y623-only; y28ga is not given this kernel patch.

### 4. Lightweight local y623 motion detection

Sources:

- `src/motiond/`
- `src/static/static/yi-hack/script/motion_service.sh`

The original heavy vendor motion/AI path was replaced for y623 with a small local detector based on H.264/VE encoder statistics rather than raw YUV frames and AI models.

This is one of the changes that made y623 usable with local streaming on its limited RAM budget.

The detector also carries pressure-aware failure handling added during the low-memory stabilization work:

- it checks `/proc/buddyinfo` before opening the VE debugfs snapshot and backs off for 500 ms if the old order-3 reserve test fails;
- failed VE opens/reads are rate-limited for 1 second instead of immediately hammering the debugfs node again;
- a missing/failed sample resets confirmation and quiet-period state rather than being interpreted as evidence about motion;
- the parser and pressure behavior have a dedicated `src/motiond/tests/test_pressure.c` test.

The buddyinfo gate predates the deterministic `vmalloc` kernel patch. On a correctly patched y623 it is now a conservative legacy safeguard rather than a requirement for the VE allocation itself; the kernel no longer needs the original contiguous order-3 block.

Current caveat: `motiond` still polls `/sys/kernel/debug/mpp/ve` at a 100 ms interval by default. Live Frigate testing shows this remains a meaningful CPU/kernel-pressure hotspot even when the vmalloc kernel patch is present. See **Measured findings / not yet implemented** below.

### 5. Minimal embedded go2rtc build

Sources:

- `src/go2rtc/init.go2rtc`
- `src/go2rtc/yi-main.go`

The camera build does not use the full generic go2rtc entry point. It builds a Yi-specific binary containing only the modules needed by this firmware:

- application core
- streams
- RTSP
- exec producers

The build is stripped and cross-compiled specifically for ARMv7. The toolchain is pinned to Go `1.24.0` because newer Go releases produced materially larger embedded binaries during testing.

go2rtc is currently based on `v1.9.14` plus local patches for:

- ONVIF/backchannel interoperability;
- RTSP lifecycle handling: a connection is allowed to register its consumer tracks only once, so repeated `DESCRIBE` requests cannot append duplicate senders/consumer references and leak stream state;
- direct exec-pipe behavior: the Yi build reads producer stdout directly instead of wrapping every exec producer in go2rtc's generic `bufio.NewReaderSize(..., core.BufferSize)` buffer, avoiding an unnecessary per-producer Go-side buffer on a 60 MiB camera.

These patches are recreated on every clean go2rtc source extraction by `src/go2rtc/init.go2rtc`, so they are release behavior rather than dirty-source-tree state.

### 6. `h264grabber` producer I/O and malformed-frame lock fixes

Source: `src/h264grabber/h264grabber/h264grabber.c`

The producer path used by go2rtc also received embedded-specific fixes in `a9f5206`:

- stdout uses an explicit 4096-byte buffer instead of the accidental `sizeof(pointer)` buffer from the old code. This intentionally spends a few KiB per active producer to avoid pathological tiny writes/syscall churn; it is a throughput/latency fix, **not** a RAM-saving claim.
- direct stdout mode flushes after each completed frame so buffered producer data does not add avoidable stream latency.
- the malformed/incomplete-frame path releases the write semaphore before retrying, preventing one bad frame from leaving the producer path locked and stalling later frames.

The live PSS audit later showed that the multiple grabber processes themselves are still a low-priority RAM target because their large frame mapping is shared. See the measured findings below.

### 7. go2rtc soft memory limit

Source: `src/go2rtc/yi-main.go`

The Yi entry point calls:

```go
debug.SetMemoryLimit(12 << 20)
```

This gives the Go runtime a 12 MiB soft managed-memory ceiling while leaving the normal `GOGC=100` policy intact.

It is intentionally a runtime soft limit rather than an RSS hard cap; mappings, stacks, socket buffers, and short-lived non-Go allocations can still push RSS above 12 MiB.

### 8. Singleton service lifecycle and duplicate-process suppression

Key sources:

- `src/static/static/yi-hack/script/service.sh`
- `src/static/static/yi-hack/script/motion_service.sh`
- `src/static/static/yi-hack/script/wd.sh`

A substantial part of the low-memory work was making service startup/recovery idempotent. On these cameras, an accidental second daemon is not harmless: another go2rtc, recorder, or queue consumer can consume the last few MiB or create ambiguous ownership.

Current safeguards include:

- RTSP lifecycle operations are serialized with an atomic `/tmp/rtsp_service.lock.d` because this kernel does not provide a usable `flock` path.
- go2rtc startup accepts an already-healthy single daemon/listen socket, kills stale/duplicate go2rtc instances before starting another, and does not require `h264grabber` to exist while idle because exec producers are lazy.
- the watchdog defines healthy go2rtc as exactly one daemon plus a listening RTSP socket, avoiding the older CPU/producers heuristic that could restart an otherwise healthy idle server.
- y623 motion lifecycle operations use their own atomic lock, stop processes by verified executable identity instead of trusting a stale/recycled pidfile, and collapse duplicate `motiond` instances.
- local motion owns at most one `mp4record` instance and tracks whether motion started it, so stopping motion does not blindly kill a recorder owned by `REC_WITHOUT_CLOUD`.
- the y28ga IPC event path collapses duplicate `ipc2file` queue consumers to one clean owner.

These changes are both reliability and memory optimizations: they prevent duplicate processes from becoming a hidden source of RAM/CPU pressure.

### 9. Dispatch IPC fan-out reduction

Source: `src/ipc_cmd/ipc_cmd/ipc_multiplex.c`

The historical IPC shim mirrored every dispatch message to queues 1 through 9. Normal operation now creates/mirrors only queue 2:

```c
static int first_queue = 2;
static int last_queue = 2;
```

The old nine-queue behavior is available only when explicitly requested for diagnostics with `IPC_MULTIPLEX_ALL=1`.

This removes unused queue payload/bookkeeping and repeated `mq_send` attempts. Testing did **not** establish a large whole-camera CPU or RAM improvement from this change, so it should be considered a cleanup/small-footprint optimization rather than the primary performance win.

Detailed evidence is retained under `docs/vendor-ablation/`.

### 10. Vendor cloud removal / local-only boot

Key sources:

- `src/static/static/yi-hack/script/system.sh`
- `scripts/vendor-ablation/bootstrap.sh.in`
- `src/static/static/yi-hack/bin/cloudAPI`
- `src/static/static/yi-hack/bin/cloudAPI_fake`

The camera no longer launches the original vendor cloud stack during normal operation.

The persistent bootstrap validates the supported vendor firmware and SD payload, overlays the local cloud boundary, starts the required hardware/media pieces, and hands off to yi-hack.

`system.sh` uses the local IPC kick required to keep encoded buffers flowing and intentionally does not launch vendor cloud services.

Benefits include:

- less unnecessary network/cloud work
- fewer vendor background processes
- less accidental coupling between local services and cloud state
- a deterministic local-only boot path

### 11. Kernel-led OOM policy instead of an aggressive userspace reaper

Sources:

- `src/static/static/yi-hack/script/oom_policy.sh`
- `src/static/static/yi-hack/script/wd.sh`

An earlier experiment used a resident `memory_reaper.sh` to react to low-memory conditions. That duplicated work the Linux kernel already performs and itself added complexity/pressure.

The current design lets the kernel select OOM victims and assigns priorities with `oom_score_adj`.

Current important priorities include:

| Process/service | `oom_score_adj` | Intent |
| --- | ---: | --- |
| `rmm` | -1000 | never sacrifice media core |
| `wpa_supplicant` / DHCP | -1000 | preserve network control plane |
| SSH listener | -1000 | preserve recovery access |
| `dispatch` | -900 | strongly protect broker |
| `wd.sh` | -900 | keep recovery supervisor alive |
| `go2rtc` | 250 | expendable before essentials |
| RTSP/h264 producers | 300 | restartable streaming workers |
| `motiond` / `mp4record` | 650 | expendable local services |
| HTTP/ONVIF/discovery helpers | 700-800 | lower priority |
| MQTT helpers | 900 | highly expendable |
| snapshots/ffmpeg/TTS/Python helpers | 1000 | first-choice victims |

The one-shot policy also raises `vm.min_free_kbytes` to at least 384 KiB to keep a modest emergency reserve for the vendor media path.

### 12. Lightweight watchdog recovery

Source: `src/static/static/yi-hack/script/wd.sh`

Because OOM-killed streaming and local services are expendable, the watchdog is responsible for bringing configured services back after the kernel kills them.

The intended pattern is:

1. protect `rmm`, Wi-Fi, SSH, dispatch, and the watchdog;
2. allow expensive/restartable helpers to die first;
3. let the kernel reclaim memory naturally;
4. restart configured services once the system survives the pressure event.

This avoids protecting every process until the media core itself becomes the only remaining victim.

`memory_reaper.sh` still exists only as a compatibility entry point for old startup hooks/upgrades; it immediately `exec`s `oom_policy.sh` and is no longer a resident reaper.

### 13. Static watermark removal without disabling timestamp OSD

Source: `src/static/static/yi-hack/script/prepare_rmm.sh`

Both supported `rmm` patch sets disable the static vendor/Yi logo rendering path directly. The old WebUI toggle and blank-watermark workaround are no longer needed.

Timestamp OSD remains available.

This removes an unnecessary vendor graphics path and simplifies configuration.

### 14. MQTT disabled means MQTT really stays disabled

Source: `src/static/static/yi-hack/script/system.sh`

When MQTT is disabled, the legacy MQTT bridge is explicitly stopped instead of being left resident. Besides saving RAM, this prevents it from mirroring stale vendor detector state back into local camera configuration.

This is especially relevant to y28ga generic local motion.

### 15. Wi-Fi soft reconnect and maintenance failover

Key sources:

- `src/static/static/yi-hack/script/wd.sh`
- `src/static/static/yi-hack/script/wifi_failover.sh`
- `src/static/static/yi-hack/script/configure_wifi.sh`

The maintenance-network work originally added a fallback Wi-Fi profile, then live y623 testing showed that repeatedly taking `wlan0` down and back up can wedge the SDIO Wi-Fi path. The current recovery path therefore prefers a soft reconnect:

- reconfigure/restart `wpa_supplicant` as needed without cycling the interface down;
- renew DHCP after association recovery;
- switch to the maintenance-only profile without a down/up bounce;
- serialize the one-shot failover helper so duplicate recovery attempts do not race;
- reuse the existing watchdog rather than adding another permanently resident recovery daemon.

The parser/installer path was later consolidated and covered by `scripts/test_configure_wifi.sh`, reducing the chance that first-install Wi-Fi configuration and runtime configuration diverge.

This is primarily availability/recovery engineering rather than a large RAM optimization, but it prevents a recovery mechanism from turning a transient network problem into a camera reboot or an unreachable device.

### 16. Atomic firmware upgrades and deterministic model state

Key sources:

- `src/www/httpd/cgi-bin/fw_upload.sh`
- `src/www/httpd/cgi-bin/fw_upgrade.sh`
- `src/www/httpd/cgi-bin/fw_online.sh`
- `sdhack/y623/Factory/config.sh`
- `sdhack/y28ga/Factory/config.sh`

This is primarily reliability engineering, but it protects all of the optimizations above from being silently lost between upgrades.

Current behavior includes:

- staged archive validation before activation
- model/version validation
- bootstrap manifest verification
- atomic yi-hack tree replacement
- preservation of current configuration
- bootstrap rollback copy
- retirement of stale Factory triggers
- ReOriginAI-specific online-release feed
- y623 kernel-state verification/installation as part of the same release contract

The goal is that two cameras reporting the same release no longer differ because one happened to receive a manual kernel or runtime patch in an earlier SSH session.

## Model-specific summary

| Optimization | y623 | y28ga |
| --- | :---: | :---: |
| patched `rmm` | yes | yes |
| VIPP1 channels 3 -> 1 | yes | yes |
| Pilot/AI initialization bypass | yes | model-specific NNA/face bypass |
| raw-YUV feeder bypass | yes | no |
| VI2/raw-analysis removed | yes | no; required for IVA motion |
| PTZ tracking processor bypass | n/a | yes |
| static watermark removed | yes | yes |
| VE debugfs `vmalloc` kernel patch | yes | no |
| local lightweight motion | H.264/VE stats | generic IVA |
| go2rtc direct exec-pipe + RTSP lifecycle guards | yes | yes |
| `h264grabber` producer I/O/lock fixes | yes | yes |
| go2rtc 12 MiB runtime limit | yes | yes |
| singleton RTSP/recorder/queue lifecycle | yes | yes |
| soft Wi-Fi recovery / maintenance failover | yes | yes |
| kernel-led OOM policy | yes | yes |
| local-only cloud-ablation boot | yes | yes |
| reduced dispatch mirror queues | yes | yes |

## Measured findings / not yet implemented

The following items came from live profiling and are **not current firmware features** unless a later commit explicitly implements them.

### A. `motiond` remains expensive under simultaneous Frigate streaming

On a loaded y623 streaming to Frigate, stopping only `motiond` while leaving go2rtc, `mp4record`, and Frigate connections active produced a large recovery in CPU idle time and memory headroom.

This effect remained present on the camera whose VE debugfs kernel was already vmalloc-patched. Therefore it should not be described simply as an order-3 allocation problem.

The likely remaining cost is repeated generation/readout of the VE debug snapshot plus secondary cache/reclaim pressure.

A 500 ms polling experiment reduced system CPU substantially compared with the normal 100 ms interval, but still did not provide as much headroom as disabling local motion.

Possible future work:

- adaptive polling based on load/memory pressure
- longer idle polling interval with short high-frequency bursts after motion evidence
- remove/relax the old order-3 buddyinfo gate on kernels known to be vmalloc-patched
- find a cheaper statistics source than repeatedly opening the VE debugfs snapshot

None of these changes is currently recorded here as implemented.

### B. go2rtc active heap/backpressure can still consume several MiB

Live tests showed an idle go2rtc around the mid-single-digit MiB private-memory range and materially higher private memory while serving Frigate.

Two contributors investigated were:

- per-consumer asynchronous video queues
- kernel TCP send queues when Frigate temporarily drains more slowly than the camera produces

Potential embedded-specific changes considered but **not yet implemented**:

- reduce the video consumer backlog from its current generic default
- bound RTSP socket send buffering more tightly
- prefer dropping stale frames under backpressure rather than retaining a large latency/memory backlog

These require care because overly shallow buffering can increase drops/stutter.

### C. Multiple `h264grabber` processes are not a major private-RAM target

Although several grabbers each show roughly a megabyte of RSS, live PSS inspection showed that most of this is a shared encoded-frame mapping; private memory per grabber is only tens of KiB.

Merging the high/low/audio producer processes solely to save RAM is therefore low priority relative to go2rtc heap/backpressure or motion polling.

### D. Local recording/motion should be considered separately from Frigate workloads

Frigate users may not need the camera to simultaneously perform its own local motion/recording work.

Live ablation showed the local motion path can materially increase pressure under a full dual-stream Frigate workload. `REC_WITHOUT_CLOUD=no` and `MOTION_DETECTION=no` remain sensible low-pressure defaults for a camera whose NVR already performs detection/recording.

This is a deployment recommendation, not an automatic firmware behavior.

## Important non-results

A few things were tested or discussed but should not be credited with gains that were never demonstrated:

- Dispatch queue ablation saves some queue bookkeeping/payload capacity, but no reliable large whole-camera CPU/RAM delta was established.
- The patched y623 VE kernel fixes contiguous allocation behavior, but it does not make `motiond` polling free.
- RSS alone overstates the memory cost of the `h264grabber` processes because they share large mappings.
- `debug.SetMemoryLimit(12 MiB)` is a Go runtime soft limit, not a guaranteed 12 MiB process RSS cap.
- The explicit 4096-byte `h264grabber` stdout buffer is a syscall/latency trade-off; it replaced an accidental pointer-sized buffer and should not be described as a memory reduction.
- The `motiond` buddyinfo/order-3 gate remains in userspace, but on release-correct y623 kernels the VE debugfs allocator is now `vmalloc`; the gate is conservative legacy protection rather than proof that current polling still needs an order-3 block.

## Source/history landmarks

Useful commits in the optimization history include:

- `d75ae06` - major y623 viability / low-memory work
- `d4324ed` - y623 `rmm` patch correction
- `a9f5206` - go2rtc direct-pipe/lifecycle fixes, `h264grabber` producer fixes, motion pressure guards, and singleton service hardening
- `2ee4e90` - VE debugfs patch tooling, maintenance Wi-Fi failover, and additional low-memory work
- `97b7bc1` - permanent vendor-logo removal
- `24148fb` - replace aggressive reaper behavior with kernel-led OOM policy
- `d58fa58` - go2rtc memory limiting
- `c3e7bc8` - hardened local-only boot and dispatch IPC work
- `3932d0c` - soft Wi-Fi reconnect that avoids y623 SDIO down/up wedging
- `899180d` - consolidated/tested Wi-Fi configuration loading
- `95b9b4d` - deterministic y623 VE kernel release integration

For deeper reverse-engineering evidence and benchmarks, see:

- `docs/vendor-ablation.md`
- `docs/vendor-ablation/performance.md`
- `docs/vendor-ablation/rmm-audit.md`
- `docs/vendor-ablation/dispatch-audit.md`
- `docs/vendor-ablation/boot-operations.md`

## Maintenance rule

When adding another optimization, update this file only after the behavior is represented in tracked source/build/install code. Live SSH experiments and proposed changes belong under **Measured findings / not yet implemented** until they become reproducible release behavior.
