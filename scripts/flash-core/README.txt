EXPERIMENTAL FLASH-CORE SD INSTALLER — REVISION 3

Model: @MODEL@; exact supported vendor firmware: @HOMEVER@
The automatic installer/recovery path still needs physical validation on both
models. Automated tests do not emulate U-Boot, power loss or flash peripherals.

1. Start with matching fresh vendor firmware and a clean FAT32 SD card.
2. Extract this archive's CONTENTS directly to the SD root: Factory/,
   flash-core/, lower_half_init.sh and yi-hack-optional/. Do not copy the
   compressed archive itself or mix the normal SD installer into this card.
3. Optionally create Factory/configure_wifi.cfg with exactly one pair:
      wifi_ssid=Your router
      wifi_psk=Your router password
   OR:
      hotspot_ssid=Your camera
      hotspot_psk=Your hotspot password
   An explicit hotspot_psk= means no password. Never put both pairs in one file.
   Existing vendor Wi-Fi is retained if no file is supplied; an unprovisioned
   camera falls back to an open hotspot. See the repository README.
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

Unsuccessful U-Boot updates stop after three attempts; consult hack_result.txt
and RECOVERY.txt. Read RECOVERY.txt before installing. The files under flash-core/images/ and
flash-core/recovery/ are intentionally inactive names; do not rename image
files except for the explicit recovery instructions. No raw backup/JFFS2 image
is flashed. The y623 kernel uses the same verified VE patch as the SD profile.
