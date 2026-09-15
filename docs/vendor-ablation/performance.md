# Resource optimization: implementation and test results

## Implemented candidates

* `ipc_multiplex.so` creates and forwards to queue 2 only by default. This is
  the normal `ipc2file` consumer. Set `IPC_MULTIPLEX_ALL=1` in dispatch's
  environment **before dispatch starts** to restore all nine diagnostic
  queues for `ipc_read` / `ipc_notify`. Changing the environment of a running
  broker does not reconfigure it. Existing diagnostic queues are not unlinked
  automatically; a clean boot removes the old queues. Queue 2 keeps its
  original 64-message capacity and 512-byte message limit.
* Failed receives are no longer mirrored. Mirroring preserves receive errno,
  initializes once across threads, and does not terminate dispatch when a
  mirror queue cannot be opened. A failed sink is logged and omitted for that
  process lifetime. Main vendor queue handling continues.
* The exact `popen("cat /sys/block/mmcblk0/device/cid 2>/dev/null", "r")`
  contract is implemented with `fopen`/`fread`/`fclose`. `pclose` returns a
  wait status. Other commands/modes, open failure, or exhausted tracking slots
  delegate to libc. No cache or reduced polling frequency is introduced.
  This supports the audited caller's read/close behavior, not general pipe
  semantics (for example `fileno()`/`poll()` on a child pipe).

No vendor instruction bytes or cloud-routing IDs are changed.

## Evidence and corrections

The earlier performance answer overstated RAM savings: mqueue `QSIZE` is
bytes, not message count. Eight unused mirrors with 580/900 bytes each held
about 4.5/7.0 KiB of message payload, plus kernel bookkeeping. Their removal
eliminates eight send attempts per received dispatch record (nine becomes one),
but this does not imply an 89% whole-camera CPU saving. No reliable total CPU
percentage or RAM delta has been established. File-backed RSS is not
automatically private or unreclaimable, and the earlier estimate of 0.5 MiB
for `ipc_multiplex.so` was not supported by per-mapping measurements.

## Validation on 2026-09-15

Host contract tests pass for normal and diagnostic fan-out, full/missing sink,
failed/interrupted receive, and errno preservation. The exact CID interposer
also passes direct-CID, delegated-command, and nonzero shell-exit tests. The ARM
preload library builds with `-Wall -Wextra -Werror` against the existing musl
Lindenis toolchain. The deployed stripped library MD5 is
`2ac18a9a8229f11b90c5d3e3371dcfb9`.

### y28ga test unit

A persistent clean-boot deployment passed on firmware
`9.0.20.06_202007061841`; this was not a hot `dispatch` restart.

* Active bootstrap MD5 after the low-space in-place update:
  `e005e4deb3a410d98a1e5ef0714a4e5b`.
* After reboot the only yi-hack mirror queue is `/ipc_dispatch_2`; queues 1 and
  3-9 are absent. Vendor `/ipc_dispatch` and `/ipc_dispatch_worker` remain, as
  do vendor compatibility queues such as `/ipc_cloud` and `/ipc_p2p`.
* `dispatch` returned at about 616 KiB RSS / 360 KiB data with five threads;
  `rmm`, `ipc2file`, go2rtc and ONVIF also returned. No vendor `cloud`,
  `p2p_tnp`, `oss`, `rtmp`, or `watch_process` process was present.
* Main RTSP passed as H.264 video + AAC audio; substream passed as H.264 video.
* A six-second post-boot exec trace contained 12 `execve()` calls: six shell
  launches plus six `wpa_cli` launches. CID shell launches were **zero**. The
  previous y28ga trace had a CID shell plus `cat` child on each poll, so the
  interposer removes that process pair while leaving Wi-Fi polling unchanged.
* `/home/app/cloudAPI -c 136` returned the local time response and unsupported
  command `999` failed closed. No OOM event appeared in `dmesg` during the
  post-boot checks.

### y623 test unit

A persistent clean-boot deployment also passed on firmware
`12.0.51.01_202303091901`; again, no live broker restart was used.

* Active bootstrap MD5 after the low-space in-place update:
  `f21ec1856e62962d4530e133a10ab83d`.
* After reboot the only yi-hack mirror queue is `/ipc_dispatch_2`; queues 1 and
  3-9 are absent. `dispatch` returned at about 580 KiB RSS / 344 KiB data with
  four threads, and `rmm`, motion, go2rtc, `ipc2file`, ONVIF and the H.264/audio
  grabbers returned normally.
* Main RTSP passed as H.264 video + AAC audio; substream passed as H.264 video.
* A six-second exec trace contained eight `execve()` calls, all belonging to
  four `wpa_cli` shell/helper pairs. CID shell launches were zero; y623 did not
  exhibit the y28ga CID-poll command before this change either.
* A non-moving `ipc_cmd -m STOP` sent through `/ipc_dispatch` returned 0; the
  dispatch queue was drained immediately and `dispatch`/`rmm` remained alive.
  `ipc_cmd -g/-u` are not valid health checks on this model because that helper
  hard-codes `/dev/ssp`, while the tested y623 exposes `/dev/cpld_periph`.
* The local `cloudAPI` time command passed and no OOM event appeared in the
  post-boot checks.

These clean-boot results supersede the earlier failed y623 **live restart**
experiment. That earlier stall demonstrated that restarting the vendor broker
in place is unsafe because it reinitializes shared vendor state; it did not
recur when the same preload library was activated from the normal boot path.

## JFFS2 deployment safety and recovery

The test cameras began with extremely little `/backup` JFFS2 headroom:
approximately 4 KiB on y28ga and 16 KiB on y623. JFFS2 can reject a tiny inode
update even when `df` reports several free blocks because it also needs
GC/erase-block reserve space.

During the first y28ga low-space trial, a 206-byte fixed-offset update returned
ENOSPC after changing one byte in `/backup/init.sh`. The SD library had not
been switched and the manifest hash was still old, so the running camera stayed
operational; reboot was deliberately withheld. The exact pre-change init was
already stored on the host. After reclaiming space, that single byte was
restored and the complete original bootstrap MD5
`1ff18ac542d93bc890a3e313cb901703` and `sh -n` both matched again before a
second installation was attempted.

Space was reclaimed only from firmware-update machinery that the local-only
bootstrap already disables. Exact originals were preserved in the captured
`backup.tar` archives, and direct recovery copies for the test incident live
under ignored `build/vendor-ablation/deploy-20260915/` evidence. On y28ga the
removed disabled paths included the upgrade/extpkg entry points and
`rsa_pub_dec`; on y623 the disabled `upgrade.sh`, `extpkg.sh`, and their sole
`rsa_pub_dec` helper were likewise preserved and removed. `rsa_pub_dec` MD5 is
`8dfa7388b38d978a85c2ffee7c843c8d` on both audited backup images. Wi-Fi data,
calibration/configuration data, and retained camera payloads were not removed.

After cleanup, `/backup` had roughly 224 KiB free on y28ga and 228 KiB on y623,
and both verified in-place updates completed. `install-performance.py` now
checks JFFS2 space **before any remote write** and refuses installation below
128 KiB free. It also:

* requires the exact known old multiplex-library hash;
* validates the audited local-only bootstrap shape;
* stores exact before/after bootstrap and library bytes on the host;
* verifies BusyBox fixed-offset `dd` behavior in `/tmp`, not flash;
* stages and hashes the new SD library;
* writes structural bootstrap ranges before changing the library;
* switches the SD library, then commits its 32-byte manifest hash last;
* verifies full bootstrap/library hashes and `sh -n`; and
* never reboots automatically.

The active test cameras use a same-size in-place bootstrap update because that
minimizes JFFS2 churn. `scripts/vendor-ablation/bootstrap.sh.in` contains the
same behavior in readable form for newly rendered boots.

## Fresh-package integration

The firmware packer now renders that readable bootstrap into
`Factory/local_init.sh` from the **actual packaged `yi-hack` payload**. It
rebuilds the tested 344-byte ARM no-op from `noop.S` using the Lindenis
assembler/linker and requires MD5 `b92bc72d8b7019ec751c36235e92fba5`
before rendering. The generated bootstrap is syntax-checked during packaging.
The packer copies only `build/yi-hack`; ignored `build/vendor-ablation`
recovery/evidence data is neither deleted by a normal compile nor eligible to
enter a firmware archive.

For y623 and y28ga, the packaged `Factory/config.sh` is now an exact-firmware,
fail-closed migration installer rather than the historical telnet installer.
The audited predecessor `/backup/init.sh` hashes are explicitly treated as
**legacy yi-hack** hashes, not pristine vendor hashes. A pristine predecessor is
accepted only if applying the historical installer transform to a temporary RAM
copy reproduces the exact audited legacy hash. Unknown init or updater hashes
are rejected before internal boot files are changed.

Before the first JFFS2 deletion, the installer writes the MTD recovery dump,
home version, predecessor init, and every updater file that may be reclaimed to
SD and verifies the individual recovery copies. Optional Wi-Fi configuration is
also handled before deletion; if credentials change, the existing helper may
perform its intentional preliminary reboot while the original boot files remain
intact. Only on the resumed/same boot are exact audited updater files removed,
then the installer requires at least 128 KiB free on `/backup`, stages and
syntax/hash-checks the generated init under a new name, and renames it into
place. The Factory trigger is retired only after final verification.

These package-path changes are designed from the same hashes and JFFS2 failure
evidence used in the live migration, but the **new fresh/legacy Factory install
path has not yet been physically exercised as a first install**. Archive,
syntax, hash, and host tests are not a substitute for that regression. The
physical SD-removed cold-boot test also remains outstanding.

## Additional cloud review

The y28ga `rmm` strings include a `/home/app/mdnsResponder` launch hook. That
executable is absent on both test cameras, and no such launch appeared in the
steady-state dispatch traces. mDNS is local discovery; the name is not proof
of Yi WAN behavior. No speculative no-op was added. Existing `cloudAPI` time
and QR-disarm calls remain constrained by the local compatibility stub. Loaded
media libraries and rare-event branches still need analysis before claiming
the entire `rmm` dependency graph has no WAN-capable path.

The dispatch destination table was corrected during review: bits 2/4/8/16
address rmm/cloud/p2p/recording; y28ga adds bit 32 for RTMP and 256 for mDNS.
This correction changed documentation only, never vendor routing.

## Current deployment status

The optimization is active after clean reboot on both audited test devices:
the audited y623 and y28ga test units. Queue fan-out, CID polling, RTSP/audio,
local compatibility services, and retained vendor broker processes have been
rechecked. The earlier live-restart limitation remains important: future
regression tests should activate `dispatch` preload changes only at controlled
boot, not by killing/restarting the running broker.

Raw traces, exact recovery bytes, and environment captures stay under ignored
`build/vendor-ablation/` paths because some captures can contain private device
state and must not be committed.
