# Flash core for y623 and y28ga

This primary firmware profile places the local camera services in internal flash so
an SD card is optional at boot. The builder creates offline images and experimental SD installers. It does
not connect to a camera or write an MTD device. The installer stages U-Boot
update names on the camera only after model checks and verified backups.
A manually installed y28ga camera passed a physical cold boot without SD,
router Wi-Fi, SSH, HTTP and RTSP video checks on 2026-11-02. On 2026-11-04, a
revision 6 y623 installation with SD on partition 1 passed installed rootfs/home
hash checks, router Wi-Fi, SSH, HTTP, 2304x1296 H.264/AAC streaming and a 640x360
motion-grid snapshot. Its settings/SSH keys matched the internal fallback and
writable flash retained 220 KiB free. A subsequent physical cold boot with SD
removed passed the same network, web, stream and grid-snapshot checks. Settings
were served from internal JFFS2, the no-card broker patch was active, and writable
flash retained 216 KiB free. The complete release/recovery matrix remains pending.

The y623 hotspot has also been confirmed working by the user. Controlled
bad-password tests activated automatic recovery after 193 seconds during runtime
and 235 seconds from boot, then returned to router Wi-Fi with saved credentials
unchanged. Default hotspot names now use `cam-MODEL-MACSUFFIX` on both models;
explicitly configured names are preserved.

## Features and storage

| Available without SD | Requires optional SD payload or data |
| --- | --- |
| Vendor capture/encoder with the existing audited local-motion patches | Alternate RTSP server |
| Standard RTSP, audio, low-resolution motion-grid snapshots, ONVIF/discovery | Recording, thumbnails, time lapse, FTP upload, full-resolution/watermarked snapshots |
| SSH, HTTP configuration UI, BusyBox FTP | MQTT programs, Python, rsync, proxychains |
| Local motion events, night vision, hotspot/reset controls | NanoTTS, its voice data, saved audio files |

The internal snapshot decoder handles low-resolution H.264 reference images for
the motion-mask grid. The full snapshot decoder, including HEVC and watermarks,
is stored under `yi-hack-optional/bin/imggrabber` on SD, together with its watermark
assets. Normal SD firmware retains the full snapshot program. Low-resolution
requests temporarily enable the low video encoder if needed and restore the
configured stream/recording policy after capture, including decoder failures.
Capture has a ten-second process deadline. No snapshot daemon runs continuously.
The build tests real H.264-to-JPEG decoding and the camera frame-buffer layout
for both models under QEMU; the internal grid image works without SD.

The existing hotspot firmware/driver restrictions still apply. This profile does
not change them. The rear-button hotspot override defaults to enabled on audited firmware.
Both profiles default to hotspot recovery after a primary Wi-Fi outage. The WiFi
page can select maintenance-network recovery instead. Network transitions and
vendor station callbacks share a non-blocking kernel-owned lock; bounded workers
release it on exit or termination. The watchdog keeps checking services while
they run. An interrupted hotspot transition restores primary Wi-Fi on its next
pass, and queued manual/button requests take priority over automatic recovery.

Read-only code lives at `/home/yi-hack` in the home SquashFS. A bind mount exposes
it at `/tmp/sd/yi-hack` to preserve existing executable paths and interpreters.
This mount exists even without a card; it does not indicate SD presence.
`storage.sh` recognizes only the actual FAT MMC mount at `/tmp/sd`.

Writable configuration lives at `/tmp/sd/yi-hack-config` when a usable card is
present, or `/backup/yi-hack-config` on JFFS2 otherwise. The selected directory is
bound over the core's `etc`. Old SD `yi-hack/etc` is migrated on first boot with
the card. Code from that old tree is not overlaid or executed. An uninitializable
or read-only card is unmounted and the internal configuration is used.

Startup reuses an existing `/tmp` tmpfs and an already mounted data card. This
preserves the install dispatcher's early SD mount instead of hiding it under a
second tmpfs. An empty FAT32 card is initialized from the saved internal settings;
it does not need a `yi-hack` program directory. Explicit startup failures are
saved in `/backup/flash-core-last-error` for inspection after the next successful
boot; kernel hangs or sudden power loss may not leave that message.

With a card present, a bounded worker copies changed settings and SSH keys to
the internal fallback at boot and on the watchdog's auxiliary pass (about every
30 seconds). Unchanged files do not cause flash writes. Each file is replaced
atomically; the entire set is not a transaction. The copy accepts at most 32
regular files, 64 KiB per file and 128 KiB total. Removed files are retired.
Configuration changes made without SD write directly to the internal fallback.
Large custom images and audio assets are not mirrored to flash.

Boot once with the existing configuration card and allow a watchdog pass before
powering down and removing it. This preserves settings and SSH host identity.
Without that step the image uses generic defaults and the camera's existing
vendor Wi-Fi provisioning. The installer preserves bootloader, environment and manufacturing partitions.
An explicit router provisioning file updates the existing Wi-Fi configuration;
without that file the saved vendor provisioning is retained.

No-card operation means **booting without a card**, not seamless hot removal.
Removing a mounted card can break live configuration/data access until reboot.
Kernel tasks stuck in uninterruptible storage I/O cannot be repaired by a shell
timeout; the existing guards address ordinary user-space stalls.

On a no-card boot, `flash_dispatch.sh` checks the complete audited broker hash
and creates a 61–72 KiB RAM copy with only the SD-removal reboot call replaced
by an ARM NOP. The vendor's initial saved SD status can otherwise disagree with
its first card-identity poll and cause an endless reboot loop. The subsequent
status update still runs. Boots with a card use the untouched broker; card
insertion and unrelated reboot/reset requests retain their original paths.
Both model patches are checked against the pinned original binaries by tests.
The reset-button override accepts these exact additional broker hashes.

Recording services and scheduled data jobs skip when no SD mount exists. The
watchdog continues to other services instead of repeatedly attempting recorder
startup. Missing optional RTSP backends fall back to standard RTSP; absent MQTT
programs are not restarted. FTP uses BusyBox when pure-ftpd is absent, including
status and watchdog checks. Debug logs are disabled without SD. Speaker uploads
use their existing bounded RAM path when no real SD mount exists.

## Flash budget

Both audited layouts have rootfs `0x120000`, home `0x340000`, and backup
`0x130000` bytes. Rootfs/home use XZ SquashFS with 256 KiB blocks. The existing backup partition uses little-endian JFFS2 with 4 KiB physical
erase blocks. Installation must retain this filesystem and apply individual
files; the generated JFFS2 size estimate is not a flashable backup image.

The builder installs the verified RMM and recorder patches into the home image,
replaces disabled vendor cloud executables with the audited no-op, and removes
the unused 7za executable. Only after installing the exact y623 RMM patch does
it remove the unused AI model. Required vendor libraries remain in place.
The FIFO-compatible ALSA library replaces the existing rootfs ALSA file instead
of occupying flash twice. Both vendor and replacement ALSA hashes are checked.

Local revision 4 candidates with hostapd in read-only home on 2026-11-04:

| Model | Rootfs image / spare | Home image / spare | Backup estimate / spare |
| --- | --- | --- | --- |
| y623 | 1,110,016 / 69,632 B | 3,362,816 / 45,056 B | 908,448 / 336,736 B |
| y28ga | 1,110,016 / 69,632 B | 3,178,496 / 229,376 B | 916,744 / 328,440 B |

Sizes can vary with the compiled payload and build tools. `report.json` gives
exact bytes and SHA-256 for each build. The builder refuses
over-budget images and reserves at least 128 KiB in backup before runtime
configuration updates. Free SquashFS space cannot be used as writable storage. Revision 4 stores hostapd in read-only home on both models. The previous y623
layout staged it in backup, which left only 16 KiB writable space on the tested
device and correctly failed the reserve check. Uncommitted staging failures now
restore reclaimed helpers, retire installer hooks, and reboot the prior firmware. Immutable default assets and the vendor
DHCP hook are stored once in home and linked from backup. Obsolete vendor
update helpers are omitted.

The host mkfs.jffs2 rounds the requested 4 KiB erase size up to its 8 KiB
minimum, as does the bundled recovery tool. Generated nodes can cross physical
erase boundaries, so that image must not be written to this camera. The report
records this geometry and flags the image as non-flashable. Published packages
exclude it and instead include `backup-updates.tar.gz` with only the bootstrap.
Hostapd resides in read-only home on both models. Bootstrap updates must be applied to the existing filesystem
without replacing device-specific data. The backup figures above are estimates
from the host tool; writable headroom must also be checked on the device.

## Build and check

GitHub Actions builds this primary profile on manual runs and `3.*` tags. It
reuses the shared compiled payload and uploads
`yi-hack-Allwinner-v2X-flash-core` for both models. No legacy SD-dependent
firmware is built or uploaded by Actions. The flash-core artifact contains
three archives per model: the Windows-friendly
`flash-core-MODEL-VERSION-EXPERIMENTAL-sd-installer-r8.zip`, `flash-core-MODEL-VERSION-EXPERIMENTAL-sd-installer.tar.gz`
and `flash-core-MODEL-VERSION-EXPERIMENTAL-images.tar.gz`, plus `SHA256SUMS`
and a size/headroom summary. The SD installer contains a Factory entry point,
staged U-Boot images, generic settings, original rootfs/home recovery images,
and optional SD programs. The raw archive retains its non-installer notice.
Both report `hardware_validated: false`; only the SD package is installable.

Online firmware flashing has been removed. The maintenance page reads firmware
status locally and disables upload flashing on flash-core. The old uploader
replaces the SD payload and bootstrap; it cannot update the internal rootfs/home
images. Direct requests are rejected before reading an upload body or changing
files. Revision 8 adds a clean SD reinstall over flash-core, resetting user settings
and entering an open hotspot. Older bootstraps need the one-time SSH preparation
command in the [README](../README.md#clean-reinstall-over-flash-core). Web uploads
remain unsupported; physical validation of clean reinstalls is pending.

Follow the [README installation steps](../README.md#flash-core-installation-experimental).
Use an MBR card with one primary FAT32 partition. y623 requires FAT32 on partition
1; revision 6 checks the actual mounted device before changing persistent state.
Whole-device FAT32 cards are rejected with an explanatory result and the previous
startup is retained. y28ga continues to accept either layout.

The captured y623 updater first selects `mmc 0` (default partition 1), then uses
`0.0` as its fallback. The dot selects a hardware partition, so it still looks for
filesystem partition 1 and cannot read a whole-device FAT volume. The y28ga updater
instead tries `0:0` (the whole device) first, then `0`. This explains why a card
can boot the Linux SD firmware yet fail to install y623 flash-core. Reinstalling
vendor rootfs/home or changing Wi-Fi settings cannot correct that card layout.
`scripts/check_vendor_sd_layout.c` reproduces both models' exact selection branches
and filesystem probing using synthetic boot sectors or a private FAT32 boot-sector
capture under QEMU. Hardware reads are replaced; deliberately refusing the image
buffer allocation stops execution before image loading or flash writes. Compile
it with the same options as the header checker below, then run:

```sh
qemu-arm-static check-vendor-sd-layout /private/y623-mtdblock0.bin
qemu-arm-static check-vendor-sd-layout /private/y28ga-mtdblock0.bin
```

The installer verifies the complete audited stock rootfs/home filesystem prefixes
(ignoring unused erase padding), firmware, 4 KiB MTD
layout, checksums and SD space before saving all eight partitions plus original
writable files to a private recovery directory. Only explicitly listed obsolete
updater helpers are reclaimed. It retains the actual backup JFFS2 filesystem,
loads generic settings plus optional Wi-Fi/hotspot input, and requires at least
128 KiB writable reserve plus activation space. y623 also uses the existing
hash-gated VE kernel helper; unknown kernels are refused.

A small internal dispatcher resumes the pending installation after U-Boot
updates rootfs/home. Stock rcS leaves `/tmp` on read-only SquashFS; the dispatcher
mounts a 32 MiB tmpfs before creating `/tmp/sd` or mounting the card. The image
also includes an empty `/tmp/sd` mountpoint so an older pending dispatcher can
reach a verified repair card. Install/recovery transitions flush writes and use
the native BusyBox `reboot -f`, avoiding a dependency on vendor PID 1 shutdown.
The ARM checker now exercises the mountpoint against read-only rootfs before
supplying tmpfs; installer tests enforce tmpfs-before-directory ordering.
Revision 3 also corrects the U-Boot image name: rootfs and home must use
`xiaoyi-rootfs` and `xiaoyi-home`, respectively, with ARM filesystem type 7.
The captured y28ga updater rejects the previous rootfs image labeled as home.
Its version comparison uses the data CRC at header offset 24, not the timestamp.
Recovery images contain the complete stock SquashFS prefix without unused raw
partition padding, keeping the 64-byte envelope inside the partition budget.

`scripts/check_vendor_sd_header.c` can additionally execute the exact captured
y28ga or y623 header-validation function under QEMU against generated images. It gates
the U-Boot code CRC, maps only userspace memory, and replaces libc/environment
calls; it does not invoke a flash-write or reboot function. The private U-Boot
dump is a local input and is never included in a release. The audited y28ga
function is at `0x4a01b51c`, loaded from a TOC1 item at dump offset `0x18c00`;
the y623 function is at `0x4a01b4bc`, from offset `0x19c00`.
Both models accept the generated rootfs/home headers and reject incorrect names
or corrupt payloads. This checks validation logic, not hardware SD detection or
actual flash writes. Build the harness with the ARM compiler
using `-mthumb -march=armv7-a -static` and linker group
`-Wl,--start-group -lc -lgcc_eh -lgcc -Wl,--end-group`, then run:

```sh
qemu-arm-static check-vendor-sd-header /private/y28ga-mtdblock0.bin rootfs_y28ga 2
qemu-arm-static check-vendor-sd-header /private/y28ga-mtdblock0.bin home_y28ga 3
qemu-arm-static check-vendor-sd-header /private/y623-mtdblock0.bin rootfs_y623 2
qemu-arm-static check-vendor-sd-header /private/y623-mtdblock0.bin home_y623 3
```
 Partial updates are accepted only if each partition still
matches its exact original or the exact new image prefix. Both new image hashes
and the internal bootstrap must match before the SD install triggers are retired.
Finalization is idempotent across interrupted trigger retirement. A committed
journal also recovers an interrupted dispatcher rename. Update staging stops
after three unsuccessful attempts. Revision 5 automatically invokes verified
recovery when both original filesystems are unchanged, restores the previous
startup, and reboots with the failure recorded on SD. Identity and backup checks
still apply; partially installed filesystems require explicit recovery. Normal
boots after a successful installation use the internal bootstrap without SD.

Each package's `RECOVERY.txt` explains copying its inactive stock images to the
model's U-Boot update names and creating `flash-core-recovery/RESTORE`. After both
original partitions match, the dispatcher verifies this camera's manufacturing
identity and recovery manifest, restores original startup and reclaimed updater
files, and retires update/install triggers. The y623 compatible kernel patch and
requested Wi-Fi credentials remain. Never flash the saved raw backup JFFS2 image.
The automatic fresh-camera install/recovery cycle has simulation coverage but
still needs physical testing on both models, particularly y623 writable headroom.
Interrupted kernel writes or a broken U-Boot/SD path may require UART recovery.

The checked-in [base inputs](../scripts/vendor-images/flash-core/README.md) contain
only pinned read-only rootfs/home partitions and allowlisted vendor Wi-Fi support
files. The build does not connect to a camera or consume a private backup image.
Archive and per-file SHA-256 values are verified before extraction. Only the
finished packages directory is uploaded; raw inputs and extracted staging trees
are excluded. The workflow checks budgets and ARM loaders before uploading.

The same packaging path can be run locally after compiling `build/yi-hack`:

```sh
python3 scripts/pack_flash_core_all.py \
  --payload build/yi-hack \
  --toolchain /opt/yi/toolchain-sunxi-musl/toolchain/bin \
  --host-busybox /tools/patched-host-busybox \
  --qemu /usr/bin/qemu-arm-static --mkfs-jffs2 /usr/sbin/mkfs.jffs2 \
  --output out/flash-core
```

For individual candidate builds with your own audited base trees:

Use the exact audited vendor trees: y623 `12.0.51.01_202303091901` or y28ga
`9.0.20.06_202007061841`. Extract rootfs/home with unsquashfs and backup with a
JFFS2 extractor. Preserve recovery copies of the original raw partitions.
Backup trees/images can contain private device data; keep them outside the repo.
The y623 encoder-statistics motion backend also needs the separately audited
VE-debugfs kernel patch already used by the normal profile.

Build the shared ARM payload with the repository's toolchain and current
BusyBox patches/configuration, including `service_guard` and the ONVIF binary.
Compile the web UI with `bash src/www/compile.www`. Build the exact no-op from
`scripts/vendor-ablation/noop.S` with that toolchain. The packer validates its
hash. A host BusyBox is needed to run the existing binary patch helpers.

```sh
python3 scripts/pack_flash_core.py y623 \
  --rootfs /private/y623/rootfs --home /private/y623/home \
  --backup /private/y623/backup --payload /build/yi-hack \
  --web src/www/_install/www --noop /build/noop \
  --host-busybox /tools/busybox --mkfs-jffs2 /tools/mkfs.jffs2 \
  --output /private/y623/flash-core

YI_TEST_BUSYBOX=/tools/patched-host-busybox python3 scripts/test_flash_core.py
python3 scripts/check_flash_core.py /private/y623/flash-core \
  --qemu /tools/qemu-arm-static
```

Repeat with the y28ga vendor trees. The output contains `rootfs.squashfs`,
`home.squashfs`, a **non-flashable** `backup.jffs2` size estimate, extracted
staging trees, `report.json`, and
`sd-optional/yi-hack-optional`. Optional executables/libraries have explicit
links to `/tmp/sd/yi-hack-optional`. If using optional NanoTTS, place its voice
data under `yi-hack-optional/usr/share/pico/lang` on SD.

The packer checks firmware/RMM/ALSA hashes and resolves core ELF interpreters
and linked dependencies without SD. The ARM checker uses bubblewrap and QEMU
to verify image hashes, required applets, shell syntax, the lock builtin,
compressed defaults, optional-program absence, and program loaders.
It does not emulate the sensor, Wi-Fi driver, GPIO, or encoder peripherals.

The raw-image archives are development inputs; use the separate SD installer
for a fresh vendor camera. The existing SD upload/upgrade CGIs are disabled in this profile because replacing an SD
tree cannot update a flash core. The new installer/recovery path requires
physical tests before release: cold boot with and without
SD, Wi-Fi and SSH, sustained audio/video, ONVIF, motion, hotspot/reset, settings
save/reboot, and recovery from optional-service failure. Do not mix model images
or copy a private backup image to another camera.
