# Vendor ablation — work in progress

This is an implementation and evidence log, **not a completed privacy certification**.
The physical SD-removed cold-boot test is unperformed: the owner prefers not to
use a ladder. SSH-controlled simulations cannot substitute for that test.

## Recovery baseline (captured before any local-only persistent modification)

Cameras: y623 test unit, firmware `12.0.51.01_202303091901`;
y28ga test unit, firmware `9.0.20.06_202007061841`.
The host's ignored `build/vendor-ablation/<model>/` contains `backup.tar`
(complete internal /backup), `vendor.tar` (home, scripts and boot files),
`originals.tar` (unoverlaid flash rmm/cloudAPI), `sd-before.tar`, baseline
process/network captures and disassembly. These contain proprietary/private
material and must not be committed. Hash inventories are in the adjacent directory.

`/home` is SquashFS, read-only. `/backup` is JFFS2 on mtdblock4 (1216 KiB),
initially with 20 KiB free on y623 and 4 KiB on y28ga. `/etc/init.d/S02app`
mounts both partitions and invokes `/backup/init.sh` only if present. It has
no stock-init alternative. No rootfs/kernel flash write is part of this work.

The archived `/backup/init.sh` from each test camera is the **previous yi-hack
installer result**, not a pristine vendor init: it contains the historical
telnet append and SD/home/backup lower-half selector. The new first-install
guard therefore calls those hashes `EXPECTED_LEGACY_INIT_MD5`. A pristine
predecessor is accepted only when applying the historical installer transform
in `/tmp` reproduces the exact audited legacy hash; this check never writes the
candidate to flash.

### Restore procedure

With an authorized serial shell (or SSH if local services still work), recover
the exact pre-local-only `backup/init.sh` from the host archive for **that
camera**, copy to `/backup/init.sh.restore`, verify its recorded SHA256/MD5 and
`sh -n`, `chmod 755`, then `mv /backup/init.sh.restore /backup/init.sh` and
`sync`. Restore changed SD files from `sd-before.tar` if needed. Reboot clears
all volatile bind mounts. Restoring the predecessor yi-hack init intentionally
restores its telnet/lower-half behavior and permits the vendor startup paths it
previously exposed; this is a manual recovery action, never an automatic
rollback. Do not write another model's backup image or overwrite device
configuration. If internal storage cannot stage a verified file, stop; do not
truncate the active boot file or erase a flash partition to make room.

## Boot dependency graph

```text
kernel → /sbin/init → /etc/init.d/rcS → S01udev + S02app
S02app → mount /home + /backup → /backup/init.sh
predecessor init → tmpfs/mqueue/SD + update/OTA recovery + telnet
                 → SD lower_half OR home lower_half OR backup lower_half
stock lower_half → Wi-Fi + sensor drivers + network interfaces
                 → optional property/factory/debug/log-tools
                 → dispatch → rmm → mp4record
                 → cloud + p2p_tnp + oss + rtmp + watch_process
local bootstrap → internal masks → checked SD → drivers → dispatch → system.sh
no SD / bad startup hashes → masks installed, no vendor applications/network
```

## Initial findings

`dispatch`, `rmm`, and `mp4record` were running on both cameras. No cloud,
P2P or upload daemon was running. All three retained processes had a single
Unix datagram socket; their inodes matched `/proc/net/unix`, not tcp/udp.
This snapshot is not proof that short-lived Internet attempts never occur.

`dispatch` is mixed-purpose: creates `/tmp/mmap.info`, POSIX queues
`/ipc_dispatch`, `/ipc_rmm`, `/ipc_cloud`, `/ipc_p2p`, `/ipc_rcd` and a worker
queue; reads hardware/device configuration; manages Wi-Fi reconnect/DHCP,
SD state and configuration; forwards camera commands. The open
`ipc_multiplex.so` copies messages to additional local queues for yi-hack.
It also contains factory/reset/cloud-related message handling and launch hooks.
Its only direct dependencies are libc and libgcc, not a cloud networking library.
Replacing it before documenting these protocols would be speculative.

`rmm` produces shared encoded media and accesses camera/audio hardware.
`rmm` calls `/home/app/cloudAPI -c 136 -url .../v2/ipc/sync_time`, parsing
`code` and millisecond Unix `time`. y623 also contains command 13 (QR disarm).
The local compatibility API supplies only the time contract from the local
clock; all other commands fail with status 1 and no output. It performs no
network access. Configured NTP remains yi-hack's responsibility.

The detailed `rmm` ELF/import/string/disassembly and live syscall audit is in
[`docs/vendor-ablation/rmm-audit.md`](vendor-ablation/rmm-audit.md). Its direct
socket path is AF_UNIX logging; the cloud boundary is the high-level
`cloudAPI` command, already replaced by the local-only compatibility stub.

## Implementation status

Repository cloud-enable startup branch and real-cloud wrapper fallback removed.
`DISABLE_CLOUD` remains an ignored/migrated compatibility key, defaulting to yes.
The replacement boot template embeds all primary cloud masks internally;
no original lower-half script is sourced. No new rmm/dispatch binary patch
has been applied. Existing motion-lite rmm patches are separate work.

The firmware packer now renders `Factory/local_init.sh` from the **actual
packaged payload** and the exact 344-byte no-op ELF used in the live tests. The
no-op is rebuilt from `scripts/vendor-ablation/noop.S` with `ld -N`; its expected
MD5 is `b92bc72d8b7019ec751c36235e92fba5`. Packaging aborts if that binary is not
reproduced exactly or if the generated bootstrap fails `sh -n`.

For y623 and y28ga, `Factory/config.sh` no longer creates the historical telnet
bootstrap. Before changing JFFS2 it verifies the exact model/firmware, validates
the predecessor init as described above, and hash-checks every updater component
that may be reclaimed. It preserves the MTD blocks, predecessor init, homever,
and each reclaimed file on SD, then removes only the audited update-chain files,
requires at least 128 KiB free on `/backup`, stages the generated init under a
new name, verifies its hash and syntax, and renames it into place. Any unknown
hash or failed precondition leaves the Factory trigger present and exits before
vendor lower-half startup can continue on that boot.

The manually deployed hardened bootstrap and dispatch preload have passed clean
boot on both test cameras. The newly integrated **fresh/legacy Factory install
path itself still requires a physical first-install regression test**; source or
package checks must not be described as that physical test. Further dependency
analysis and the SD-removed cold-boot test also remain outstanding.
