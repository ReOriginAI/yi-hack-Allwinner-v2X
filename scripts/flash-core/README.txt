EXPERIMENTAL FLASH-CORE SD INSTALLER — REVISION 8

Model: @MODEL@; exact supported vendor firmware: @HOMEVER@
The automatic installer/recovery path still needs physical validation on both
models. Automated tests do not emulate a complete hardware boot, power loss or
flash peripherals.

1. Start with matching fresh vendor firmware. Prepare an SD card with an MBR
   partition table and one primary FAT32 partition. y623 requires FAT32 on
   partition 1: its vendor updater cannot read FAT32 directly on a whole card
   without a partition table. y28ga supports both layouts. Preserve existing
   files/recovery backups before repartitioning, or use a spare card. Formatting
   only a volume may leave the old partition layout unchanged.
2. Extract this archive's CONTENTS directly to the SD root: Factory/,
   flash-core/, lower_half_init.sh and yi-hack-optional/. Do not copy the
   compressed archive itself or mix the normal SD installer into this card.
3. Create and fill in Factory/configure_wifi.cfg with exactly one pair:
      wifi_ssid=Your router
      wifi_psk=Your router password
   OR:
      hotspot_ssid=Your camera
      hotspot_psk=Your hotspot password
   An explicit hotspot_psk= means no password. Never put both pairs in one file.
   Set this file before flashing a fresh or recovered vendor camera; a missing
   file has been reported to prevent initial installation. See the repository
   README. Already provisioned cameras retain vendor Wi-Fi when no file is given.
4. Power off, insert the card, power on. Allow five minutes and automatic
   reboots. Keep power and the card connected throughout installation.
5. Check hack_result.txt: 'Flash-core images verified' means both flashed
   images were read back successfully. Open the camera UI and check video.
   After it finishes startup, power off before removing the SD card. Core
   services can then boot without SD; recordings and optional programs need SD.

The installer rejects unsupported images/layouts, mixed or damaged packages,
insufficient free space, and existing configuration/install trees. It saves
and verifies all eight partitions and writable startup files under
flash-core-recovery/ BEFORE activating U-Boot updates. Preserve that directory
privately: it contains this camera's identity and saved credentials.

An incompatible y623 SD layout is detected before backups or flash changes.
The installer records the reason, retires its SD triggers, and reboots the
previous startup. Prepare a compatible installation card before trying again.

If staging fails after verified backups but before committing the update, the
installer retires its SD hooks and reboots the prior firmware. The failure
message and backups remain on SD. Preserve them before retrying.

Unsuccessful U-Boot updates stop after three attempts. If both original images
are unchanged, the verified recovery path restores previous startup and reboots
the camera; hack_result.txt records the failure. Partial updates require explicit
recovery. Read RECOVERY.txt before installing. The files under flash-core/images/ and
flash-core/recovery/ are intentionally inactive names; do not rename image
files except for the explicit recovery instructions. No raw backup/JFFS2 image
is flashed. The y623 kernel uses the same verified VE patch as the SD profile.

CLEAN REINSTALL OVER EXISTING FLASH-CORE
Use a clean compatible card and preserve all earlier recovery backups elsewhere.
Extract the matching revision 8 package. Do not fill configure_wifi.cfg: clean
reinstallation deliberately resets user settings and starts an open cam-... hotspot.
New bootstraps recognize flash-core/CLEAN_INSTALL automatically. On older
flash-core, insert the card, boot normally, then run over SSH:
  /bin/sh /tmp/sd/flash-core/install.sh --prepare-clean
It verifies device backups before switching the startup dispatcher and rebooting.
No rootfs/home update names are activated until the following cold boot. Keep
power and SD connected until hack_result.txt reports verified images. Join the
open cam-MODEL-MACSUFFIX hotspot and open http://192.168.10.1/ to configure Wi-Fi.
This resets user settings and keys; factory identity/calibration are preserved.
A configure_wifi.cfg on the card is ignored and retired during clean installation.
Preserve the new flash-core-recovery/ privately. For this path, recovery images
are flash-core-recovery/files/rootfs.restore and home.restore, not the bundled
vendor recovery images. See RECOVERY.txt. Hardware validation remains pending.
