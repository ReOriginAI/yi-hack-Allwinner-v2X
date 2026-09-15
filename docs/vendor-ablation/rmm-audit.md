# `rmm` cloud/network audit

Scope correction: the hashes below identify the already motion-lite-patched
captures, not the untouched flash originals. Direct ELF call-site findings
do not close the audit of transitive media libraries or rare-event child
execution. The y623 live syscall test was unavailable in this audit pass.
See [performance results](performance.md) for subsequent tests and limitations.

This audit covers the exact binaries captured from the two supported cameras.

| Model | Firmware | MD5 | SHA256 |
|---|---|---|---|
| y623 | `12.0.51.01_202303091901` | `b8782526e55d4b7ac95060ebcbe7ed18` | `71093f001b071dfd7e50b238d336099da59f507fb4e2e0126d71371bdce2ac6c` |
| y28ga | `9.0.20.06_202007061841` | `c83016101b3bc9b669139b6b56cbb4d0` | `56a754ff3a7e9bd420b6df19d2192d3aaf529c3011136cdc7ff2ec6b8d4bfac7` |

## ELF and library surface

`rmm` is a large dynamically linked ARM executable. Both versions depend on
the vendor media/audio/hardware libraries (`libasound`, `libnetcommon`, NNA
and Yi media/CNN libraries); y28ga additionally uses the Allwinner Cdx/Ion
stack. These libraries are part of the media substrate and are not replaced
speculatively.

The direct networking-looking imports are limited to `socket` and `sendto`.
Neither binary imports `connect`, `recvfrom`, `getaddrinfo`, `gethostbyname`,
HTTP, TLS, or DNS resolver functions. Both import POSIX message-queue calls
and shared-memory support for local media IPC.

The only `socket` call sites are the diagnostic/log packet path (y623
`0x110c64`; y28ga `0x103f78`). The call arguments are `AF_UNIX` (`1`),
`SOCK_DGRAM` (`2`), protocol `0`; the resulting descriptor is passed to
`sendto` with a local logging address structure. This is not an IPv4/IPv6
transport. The call-site code is retained because it is part of local logging
and does not create a WAN-capable socket.

## Cloud API contract

Both binaries contain the Yi sync-time format and executable strings:

```text
https
http://%s
/home/app/cloudAPI
%s -c 136 -url %s/v2/ipc/sync_time
```

They also contain cloud event/image labels such as `send cloud image`,
`send_cloud_motion_detect_msg`, and `send_cloud_pic_index_msg`. This proves
that the retained `rmm` has vendor cloud-era call sites. The call is
high-level: it invokes the `/home/app/cloudAPI` command and parses the local
`code`/`time` response for clock synchronization. It is not a reason to keep
the original cloud implementation.

y623 also contains a separate QR-disarm cloud-event command (command 13 in
the same command family). It is outside the local media contract and is
covered by the stub's deterministic failure for every command other than
`-c 136`.

The active yi-hack path now replaces `/home/app/cloudAPI` with the tiny
compatibility implementation. Only command `-c 136` returns the deterministic
local-time response required by `rmm`; all other commands fail without opening
a socket. The former `cloudAPI_real` is not an operational fallback.

## Other process execution

`rmm` imports `system`, `popen`, and (y623) `execl`. Static strings around
these call sites include local Wi-Fi/interface, driver, audio, and diagnostic
commands. Cloud sync and the y623 QR-disarm command above are identified
cloud-specific external calls. y28ga also contains an mdnsResponder launch
string; that executable is absent on both cameras. The bootstrap masks the known unsafe SD/vendor execution
hooks before `rmm` starts.

## Live evidence

On y28ga, `rmm` was traced in place for eight seconds with ARM `strace` using
`-e socket,connect,sendto,execve`. No calls were observed. Its open file
descriptors were `/ipc_dispatch`, `/ipc_rmm`, camera/audio devices, FIFOs,
DMA buffers, and one unnamed local datagram socket (inode matched
`/proc/net/unix`; no matching TCP/UDP inode). `/proc/net/tcp` and
`/proc/net/udp` contained sockets owned by local services, but none mapped to
the `rmm` descriptor set.

The same retained `rmm` process stayed alive while main/sub H264, AAC, and
speaker backchannel tests passed. The cloud API compatibility command was
tested on both cameras: `-c 136` returned code `20000` and status 0;
unsupported commands returned status 1.

## Decision

Do not broadly patch or replace `rmm`. Its media/hardware code and vendor
libraries are required for local operation. The direct socket path is
AF_UNIX-only; the cloud risk is the high-level `/home/app/cloudAPI` command
and cloud event generation. That boundary is already removed by the active
stub and bootstrap masking. A future `rmm` binary patch would require an
exact-hash, model-specific proof that a particular event producer has no
local consumer; current evidence does not justify such surgery.
