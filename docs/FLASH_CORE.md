# Flash core for y623 and y28ga

This experimental profile places the local camera services in internal flash so
an SD card is optional at boot. The builder creates offline candidates only. It
does not connect to a camera, write an MTD device, or create SD auto-flash names.
Physical cold-boot validation has not been performed for these images.

## Features and storage

| Available without SD | Requires optional SD payload or data |
| --- | --- |
| Vendor capture/encoder with the existing audited local-motion patches | go2rtc and alternate RTSP server |
| Standard RTSP, audio, snapshots, ONVIF/discovery | Recording, thumbnails, time lapse, FTP upload |
| SSH, HTTP configuration UI, BusyBox FTP | MQTT programs, Python, rsync, proxychains |
| Local motion events, night vision, hotspot/reset controls | NanoTTS, its voice data, saved audio files |

The existing hotspot firmware/driver restrictions still apply. This profile does
not change them. It does not enable the rear-button override by default.

Read-only code lives at `/home/yi-hack` in the home SquashFS. A bind mount exposes
it at `/tmp/sd/yi-hack` to preserve existing executable paths and interpreters.
This mount exists even without a card; it does not indicate SD presence.
`storage.sh` recognizes only the actual FAT MMC mount at `/tmp/sd`.

Writable configuration lives at `/tmp/sd/yi-hack-config` when a usable card is
present, or `/backup/yi-hack-config` on JFFS2 otherwise. The selected directory is
bound over the core's `etc`. Old SD `yi-hack/etc` is migrated on first boot with
the card. Code from that old tree is not overlaid or executed. An uninitializable
or read-only card is unmounted and the internal configuration is used.

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
vendor Wi-Fi provisioning. These candidates do not modify the provisioning,
bootloader, environment, or manufacturing partitions.

No-card operation means **booting without a card**, not seamless hot removal.
Removing a mounted card can break live configuration/data access until reboot.
Kernel tasks stuck in uninterruptible storage I/O cannot be repaired by a shell
timeout; the existing guards address ordinary user-space stalls.

Recording services and scheduled data jobs skip when no SD mount exists. The
watchdog continues to other services instead of repeatedly attempting recorder
startup. Missing optional RTSP backends fall back to standard RTSP; absent MQTT
programs are not restarted. FTP uses BusyBox when pure-ftpd is absent, including
status and watchdog checks. Debug logs are disabled without SD. Speaker uploads
use their existing bounded RAM path when no real SD mount exists.

## Flash budget

Both audited layouts have rootfs `0x120000`, home `0x340000`, and backup
`0x130000` bytes. Rootfs/home use XZ SquashFS with 256 KiB blocks. Backup uses
little-endian JFFS2 with 4 KiB erase blocks, matching `unbrick/create.jffs2`.

The builder installs the verified RMM and recorder patches into the home image,
replaces disabled vendor cloud executables with the audited no-op, and removes
the unused 7za executable. Only after installing the exact y623 RMM patch does
it remove the unused AI model. Required vendor libraries remain in place.
The FIFO-compatible ALSA library replaces the existing rootfs ALSA file instead
of occupying flash twice. Both vendor and replacement ALSA hashes are checked.

Measured candidates on 2026-11-02:

| Model | Rootfs image / spare | Home image / spare | Backup image / spare |
| --- | --- | --- | --- |
| y623 | 1,110,016 / 69,632 B | 3,297,280 / 110,592 B | 920,216 / 324,968 B |
| y28ga | 1,110,016 / 69,632 B | 3,112,960 / 294,912 B | 928,264 / 316,920 B |

`report.json` gives exact bytes and SHA-256 for each build. The builder refuses
over-budget images and reserves at least 128 KiB in backup before runtime
configuration updates. Free SquashFS space cannot be used as writable storage.

## Build and check

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
`home.squashfs`, `backup.jffs2`, extracted staging trees, `report.json`, and
`sd-optional/yi-hack-optional`. Optional executables/libraries have explicit
links to `/tmp/sd/yi-hack-optional`. If using optional NanoTTS, place its voice
data under `yi-hack-optional/usr/share/pico/lang` on SD.

The packer checks firmware/RMM/ALSA hashes and resolves core ELF interpreters
and linked dependencies without SD. The ARM checker uses bubblewrap and QEMU
to verify image hashes, required applets, shell syntax, the lock builtin,
compressed defaults, optional-program absence, and program loaders.
It does not emulate the sensor, Wi-Fi driver, GPIO, or encoder peripherals.

These are raw partition candidates, not U-Boot recovery archives. The existing
SD upload/upgrade CGIs are disabled in this profile because replacing an SD
tree cannot update a flash core. A model-aware flashing/rollback procedure and
physical tests are still required before release: cold boot with and without
SD, Wi-Fi and SSH, sustained audio/video, ONVIF, motion, hotspot/reset, settings
save/reboot, and recovery from optional-service failure. Do not mix model images
or copy a private backup image to another camera.
