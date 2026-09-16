# `dispatch` audit

Status: evidence and implementation notes for the audited y623 and y28ga firmware builds. This is not a claim that every dormant branch has been reverse engineered.

## Exact binaries

| Model | Firmware | MD5 | SHA256 |
| --- | --- | --- | --- |
| y623 | `12.0.51.01_202303091901` | `033ff9e7091c72ab2209eaac74ad802e` | `898dd3a458a8ac2960f7f8fe2624a06c4c3ae70e2e422a27dc0cb08c2ca91376` |
| y28ga | `9.0.20.06_202007061841` | `c6ae77baf1821023c2138cf46bb793ec` | `bec0325cfad09e105c538a16f94bc71e0afc05f8df548aa313dd0c6c4bf16846` |

Both are stripped ARM EABI executables dynamically linked only against `libgcc_s.so.1` and libc. Neither links a TLS, HTTP, DNS resolver, cloud, or P2P library.

## What must remain

`dispatch` is not merely a Yi cloud launcher. It owns local state and hardware coordination used by retained camera functionality. Observed/static responsibilities include:

- POSIX message queues for `rmm`, recording and command routing.
- `/tmp/mmap.info` shared state consumed by retained processes.
- Wi-Fi state, DHCP/reconnect orchestration and interface state.
- SD-card state and CID monitoring.
- hardware/device configuration and backup-region synchronization.
- CPLD/SSP access, PTZ-related state on applicable models, and Ethernet link-state checks.
- reset/reboot/recovery actions.

Replacing the binary without first reproducing these protocols would be speculative and high risk.

## Direct network capability

The imported network-looking API surface was followed to its callers.

### Local logger

The `sendto()` path constructs an `AF_UNIX` datagram address and sends to `/tmp/logsock`. It is local logging, not WAN telemetry. The same pattern exists in both audited builds.

### Ethernet link query

The `AF_INET`/`SOCK_DGRAM` socket is used as an ioctl handle. The y28ga path issues ioctl `0x8946` (`SIOCETHTOOL`) with ethtool command `10` (`ETHTOOL_GLINK`) to read Ethernet link state. It is not used as a UDP transport in that path.

### Regional server strings

`choose_server()` copies static region-specific API/log server strings into shared configuration. The function does not resolve DNS or connect to the selected host. Yi URL strings therefore prove retained cloud-era configuration semantics, but not a network client in `dispatch` itself.

### Live syscall samples

A captured `strace -f` sample of the running y28ga `dispatch` process and all of its threads found no direct `AF_INET`/`AF_INET6` transport call. The child network activity was `wpa_cli -i wlan0 status`, which used local Wi-Fi control rather than Yi WAN transport. Before optimization the same loop also launched `/bin/sh` plus `cat /sys/block/mmcblk0/device/cid` for local storage identity.

After the audited preload optimization was activated from a **clean boot**, a six-second y28ga exec trace contained 12 `execve()` calls: six `/bin/sh -c "wpa_cli -i wlan0 status"` launches plus six `wpa_cli` helpers. CID command/`cat` launches were zero. The exact CID `popen()` call is now serviced with a direct local file read; all other `popen()` commands delegate to libc.

A six-second post-boot y623 exec trace contained eight `execve()` calls, all four shell/`wpa_cli` pairs. CID launches were zero on that model as well; y623 had not exhibited the CID shell-poll path in the earlier baseline sample.

These steady-state traces are strong evidence that the retained broker is not itself a WAN client, but they are not proof that every rare event branch is network-free.

## Indirect process execution

`dispatch` does execute commands through `system()`, `popen()`, and, on y623, an `execl("/bin/sh", "sh", "-c", command, NULL)` helper. Most resolved fixed commands are local maintenance operations such as interface reset, Wi-Fi module reload, reboot, cache dropping, RTC handling, and local helper scripts.

Two legacy SD execution hooks are relevant to recovery and installation:

### y623 root-telnet hook

The y623 startup path calls `access("/tmp/sd/telnetd", 0)`. If the file exists it executes:

```text
/tmp/sd/telnetd -l sh &
```

This can expose a root shell listener, so it should only be placed on an SD card deliberately. ReOriginAI no longer bind-masks this hook; the project goal is cloud ablation and practical local recovery rather than preventing an owner-controlled SD from starting recovery tools.

### Factory-script hook on both models

Both audited binaries contain reachable `system()` calls for:

```text
/tmp/sd/Factory/factory_test.sh &
```

ReOriginAI now handles a complete `Factory/` release earlier in `/backup/init.sh`: the matching Factory installer validates the package, updates the persistent bootstrap, retires the trigger to `Factory.done/`, and reboots before normal `dispatch` startup. The bootstrap still masks the archived Yi `cloudAPI_real` helper, while Factory and SD recovery hooks remain available.

`/home/app/script/start_lua.sh` is another fixed `system()` target in both families; it was already masked by the internal bootstrap.

## Cloud/P2P-era IPC

The audited binaries create cloud-era queues even when the corresponding daemons are absent.

- y623: `/ipc_dispatch`, `/ipc_rmm`, `/ipc_cloud`, `/ipc_p2p`, `/ipc_rcd`, `/ipc_dispatch_worker`.
- y28ga additionally creates `/ipc_rtmp` and `/ipc_mdns`.

On both live cameras the retained vendor cloud-era queues were empty in sampled steady state. No retained vendor `cloud` or `p2p_tnp` process exists. These queues are compatibility plumbing, not evidence of live Internet communication.

They are deliberately **not** patched out. P2P-named message families include local control semantics, and the main dispatch switch updates local hardware/media state before forwarding. A queue name or message ID alone is not a safe binary-patch boundary.

## yi-hack multiplex overhead

The `LD_PRELOAD` library `ipc_multiplex.so` is separate from the vendor binary. The historical implementation created `/ipc_dispatch_1` through `_9` and copied every intercepted dispatch record to all nine queues even though the normal persistent consumer is `ipc2file` on queue 2.

Normal operation now creates and mirrors to **queue 2 only**. `IPC_MULTIPLEX_ALL=1` set before `dispatch` starts restores the historical 1-9 diagnostic fan-out for manual `ipc_read` / `ipc_notify` use. The interposer also no longer mirrors failed receives, preserves receive errno, initializes thread-safely, and treats a failed mirror sink as non-fatal to the vendor broker.

Clean-boot validation on both cameras showed only:

```text
/ipc_dispatch
/ipc_dispatch_2
/ipc_dispatch_worker
```

for the dispatch/yi-hack event path; `_1` and `_3` through `_9` were absent and queue 2 was being drained by `ipc2file`. Vendor queues such as `/ipc_rmm` and `/ipc_p2p` remain untouched.

The deployed stripped preload library MD5 is `2ac18a9a8229f11b90c5d3e3371dcfb9`.

## Process churn

The remaining steady-state process churn is the vendor Wi-Fi status poll. Post-boot traces show repeated:

```text
/bin/sh -c "wpa_cli -i wlan0 status"
/home/base/tools/wpa_cli -i wlan0 status
```

The y28ga CID poll no longer spawns `/bin/sh` and `cat`; its exact audited `popen()` command is served by `dispatch_poll.c` via direct `fopen()` of `/sys/block/mmcblk0/device/cid`. No polling interval, cache, or state-machine behavior was changed.

Replacing the Wi-Fi shell poll may still be worthwhile, but it needs a separate caller-contract test because it parses command output and participates in reconnect behavior.

## Persistent clean-boot validation

On 2026-09-15 the optimized preload and SD-execution masks were installed persistently and activated by normal boot on both audited test units, rather than by killing/restarting `dispatch`.

### y28ga `.197`

- firmware `9.0.20.06_202007061841`;
- active bootstrap MD5 `e005e4deb3a410d98a1e5ef0714a4e5b`;
- preload MD5 `2ac18a9a8229f11b90c5d3e3371dcfb9`;
- `dispatch` returned around 616 KiB RSS, five threads;
- `rmm`, `ipc2file`, go2rtc and ONVIF returned;
- no vendor cloud/P2P/upload process was present;
- main RTSP passed H.264 + AAC and substream passed H.264;
- no OOM event appeared in the post-boot check.

### y623 `.149`

- firmware `12.0.51.01_202303091901`;
- active bootstrap MD5 `f21ec1856e62962d4530e133a10ab83d`;
- preload MD5 `2ac18a9a8229f11b90c5d3e3371dcfb9`;
- `dispatch` returned around 580 KiB RSS, four threads;
- `rmm`, motion, go2rtc, `ipc2file`, ONVIF and stream/audio grabbers returned;
- main RTSP passed H.264 + AAC and substream passed H.264;
- non-moving `ipc_cmd -m STOP` sent through `/ipc_dispatch` returned 0, the queue drained, and `dispatch`/`rmm` remained alive;
- no OOM event appeared in the post-boot check.

`ipc_cmd -g` and `-u` are not useful y623 broker-health tests: the current helper's `read_ptz()` hard-codes `/dev/ssp`, while this y623 exposes `/dev/cpld_periph`. Their failure is therefore a helper/model mismatch, not evidence that the queue optimization broke `dispatch`.

The previous y623 service stall occurred only during a **hot restart of `dispatch`**. That is now treated as an invalid activation method because the vendor broker owns shared state and hardware resources. The same preload library passed when activated by controlled boot.

## JFFS2 note

Both test cameras had very little `/backup` free space before deployment. A first y28ga fixed-offset update at 4 KiB free returned ENOSPC after changing one byte of the boot file. Reboot was withheld, the exact previous bootstrap was restored byte-for-byte after reclaiming space from already-disabled firmware-upgrade payloads, and its original MD5 plus `sh -n` were revalidated before retrying.

The earlier live deployment used a now-retired fixed-offset in-place patch tool because `/backup` had almost no JFFS2 headroom. Current releases do not use that patch path: the complete SD Factory installer preserves the previous init and any reclaimed updater files to SD, verifies at least 128 KiB of `/backup` headroom, stages the new bootstrap, and atomically renames it into place. Exact incident/recovery bytes remain only in ignored evidence and the original backup archives.

## Current conclusion

For these exact firmware builds, `dispatch` should remain the local broker. Static analysis plus live tracing account for its direct networking primitives as local Unix logging, Wi-Fi control through child tools, and interface/link-state ioctls. No direct Yi WAN transport has been identified in `dispatch`.

`scripts/vendor-ablation/dispatch-audit.sh` reproduces the hash guard and read-only ELF/string/import inventory. It refuses unknown model or binary hashes, so it cannot silently bless a different firmware family.

The appropriate reductions are around the vendor broker rather than inside its routing switch: cloud/P2P/upload executables stay masked, Factory is handled explicitly as the supported install/recovery path before normal startup, yi-hack event mirroring is reduced to the one active consumer, and the exact local CID shell poll is short-circuited without altering vendor message semantics.

## `do_mq_process` routing switch map

The main receive loop begins at `0x165c4` (y623) / `0x1457c` (y28ga). It receives 512-byte records from `/ipc_dispatch`; the 16-bit message ID is at `record + 8`, while word 0 is a destination bitmask. After the ID-specific state update, the loop forwards the record with the checked `mq_send` wrapper (`0x1a7f4` / `0x1c304`).

The queue handle slots below are decoded from the exact literal-pool pointers passed to the common `mq_open` wrapper. Offsets are from each model's dispatch global context pointer:

| Mask | y623 destination | y28ga destination | Classification |
|---:|---|---|---|
| `0x02` | `+0x04` `/ipc_rmm` | `+0x04` `/ipc_rmm` | local media/hardware |
| `0x04` | `+0x08` `/ipc_cloud` | `+0x08` `/ipc_cloud` | cloud-era consumer |
| `0x08` | `+0x0c` `/ipc_p2p` | `+0x0c` `/ipc_p2p` | P2P-era consumer |
| `0x10` | `+0x14` `/ipc_rcd` | `+0x14` `/ipc_rcd` | recording |
| `0x20` | not selected here | `+0x10` `/ipc_rtmp` | RTMP-era consumer |
| `0x100` | not selected here | `+0x18` `/ipc_mdns` | discovery |

Both models receive from `/ipc_dispatch` at context offset 0. The worker is at `+0x18` on y623 and `+0x1c` on y28ga. The earlier table shifted queue names by one slot; this correction follows the initialization literal pointers and the actual forwarding loads. No routing change has been applied to a vendor binary.

The switch compares many IDs (y623 includes `0x72, 0x76, 0x7a, 0x7c, 0x7d, 0x7f, 0x88, 0x8c, 0x8e, 0x8f, 0x91, 0x95, 0x97, 0x9b, 0xa3, 0xa5, 0xa6, 0xa8, 0xe2, 0xe4, 0xe5, 0xe7, 0xec, 0xee, 0xef, 0xf1, 0xf3, 0xf5, 0xf9, 0xfd, 0x101, 0x102, 0x1036, 0x103a, 0x103c, 0x1041, 0x104, 0x5000, and `0x5004`; y28ga has a different set beginning `0x76, 0x78, 0x7a, 0x7e, 0x90, 0x98, 0x9a, 0x9c, 0xe1, 0xea, 0xee, 0xf0, 0xf3`). These branches update local timestamps, encoder/recording state, hardware controls, and reset/configuration state as well as forwarding records.

Consequently, an ID is not a cloud selector by itself. The cloud/P2P/RTMP distinction is carried by the sender's mask and downstream consumer. No branch can be safely replaced with an unconditional return until the producer protocol and consumer behavior for that exact `(model, firmware hash, ID, mask)` tuple are observed. Dispatch remains retained; the process-level ablation of cloud/P2P/upload executables is the safe boundary.

## Remaining work

1. Trace rare-event paths on both models during controlled Wi-Fi reconnect, SD hotplug, Ethernet link change where applicable, and reset/reboot—not only steady state.
2. Map observed `(message ID, destination mask)` tuples to their producers and local effects before considering any further queue or binary reduction.
3. Exercise recording and applicable PTZ/control paths under trace without relying on the y623 `/dev/ssp`-specific `ipc_cmd -g/-u` helper.
4. Determine whether the remaining Wi-Fi `wpa_cli` shell polling can be replaced with a direct local query while preserving reconnect semantics.
5. Continue auditing retained `rmm`/media rare-event launch paths before making any broader no-WAN claim for the complete vendor dependency graph.
