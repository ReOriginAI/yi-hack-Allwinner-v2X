# Open hotspot and rear-button recovery

The shared payload supports y623 and y28ga using their installed wpa_supplicant
2.6/nl80211 driver and packaged BusyBox DHCP server. No hostapd, DNS daemon,
Internet forwarding or second permanent WiFi monitor is added.

## Use

On the WiFi page, configure the hotspot name/channel and save. A blank name uses
`yi-MODEL-MACSUFFIX`. Start Open Hotspot queues a transition; the current WiFi
connection drops once the watchdog handles it. Join the open network and browse
to `http://192.168.10.1` (append a custom HTTP port if configured). There is no
WiFi password. Camera HTTP/SSH authentication remains unchanged.

Return to Primary WiFi queues restoration of the original primary profile and
DHCP/static-IP policy. Primary flash credentials are never erased by this path.
The AP is local camera access only; phones may report no Internet access.

Start in hotspot mode after reboot persists the AP boot preference. Without
that option, a button/manual hotspot is temporary and reboot returns to the
normal station startup. Defaults keep normal station boot and the vendor reset
button behavior. Settings are `WIFI_HOTSPOT_BOOT`, `WIFI_HOTSPOT_SSID`,
`WIFI_HOTSPOT_CHANNEL` (1-11, default 6), and `WIFI_RESET_HOTSPOT`.

## Button override

Enable Use rear reset button for hotspot, save, and reboot with the matching
new bootstrap/payload. Check Current reset button behavior: it must report that
the override is active before relying on the pin button for hotspot entry.
A saved preference alone does not mean the running vendor broker was updated.

When armed, a continuous five-second active-low press emits one hotspot request;
release rearms it. Short pressed samples are hidden from the vendor's physical
reset loop, so they cannot accumulate into that loop's factory-reset action.
This does not override bootloader/electrical recovery or every software reset.
The existing explicit software factory-reset path remains available.

The hook is part of ipc_multiplex.so, already preloaded in dispatch. The launcher
requires the matching model and full dispatch MD5; the constructor independently
checks the exact three instructions surrounding the poll. It only filters ioctl
0x700e from the audited return address on /dev/cpld_periph. Other devices,
callers, ioctl errors, reset commands and IPC routing pass through unchanged.
There is no vendor binary text modification or GPIO ownership transfer.

| Model | dispatch MD5 | Poll return address | GPIO |
| --- | --- | --- | --- |
| y623 | 033ff9e7091c72ab2209eaac74ad802e | 0x19b54 | 144, active low |
| y28ga | c6ae77baf1821023c2138cf46bb793ec | 0x1864c | 144, active low |

The hook writes an atomic request in /tmp after the hold and returns immediately.
It never waits for a WiFi transition inside the vendor polling loop. The armed
marker is published only after a matching device poll is observed and is checked
against the running broker executable/library by the UI. Failed reads interrupt
the hold timer; clock failure still hides pressed samples from factory reset.
Unknown firmware is ineligible for button override; the save API rejects enabling
it and the launcher retains original behavior.

## Ownership and recovery

hotspot.sh, primary recovery and maintenance handoff share wifi-recovery socket
ownership. AP starting/active/stopping states suppress station recovery checks,
including the worker's own check after it acquires ownership. WiFi scanning
also takes that ownership and is skipped while the AP is active. Media checks and
other watchdog work continue. AP requests are serviced even with RTSP disabled.

An AP transition is bounded by service_guard at 45 seconds. Pending work survives
a worker interruption; a pending rollback resumes before replaying its failed
start. A newer explicit request is retained separately from in-flight work.
Failed AP startup attempts restore primary WiFi without editing its credentials.
Missing prerequisites are checked before disturbing the current network.
The watchdog checks AP/DHCP process ownership and can restart missing AP helpers;
it does not infer radio/client progress merely from process presence.

Only wlan0 is configured, without an explicit wlan0 down/up cycle. wpa_supplicant
handles the required interface-mode switch internally. DHCP is restricted to
wlan0, with 16 leases at 192.168.10.100-150 and the camera at 192.168.10.1.
Starting the AP replaces the station connection; simultaneous AP+station is not
implemented. AP config/state/leases/requests live in RAM. No flash credential
rewrite is used for entering/leaving the hotspot.

## Validation and deployment limits

Read-only native probes on y623 192.168.1.150 and y28ga 192.168.1.199 confirmed:

- RTL8189FS, with AP advertised in nl80211 GET_WIPHY supported interface types;
- vendor wpa_supplicant reporting AP mode capability;
- GPIO 144 named reset_btn and ioctl 0x700e returning 1 while released;
- both full dispatch hashes and exact reset-poll instruction signatures above.

Host tests use the actual patched ash, fake radio/DHCP processes and the native
reset filter. They cover both model paths, open/hex-encoded SSIDs, channel and
JSON validation, POST-only transitions, unknown-firmware rejection, primary
preservation, shared recovery contention, failed AP rollback, interrupted
rollback, and one-event-per-hold/reset rearming. Filter tests reject unrelated
callers/devices/commands and mutated instruction signatures. Build gates require
the added BusyBox applets. The bootstrap manifest binds the new runtime helpers
and updated preload to the release.

No live camera WiFi transition, client association or physical pin press was
performed. No new firmware was installed or full production firmware package built. Those end-to-end tests still need a
controlled installation/recovery window; capability probes and simulated tests
are not proof of successful radio operation or physical-button behavior.

Ship the entire rebuilt firmware, including matching Factory/local_init.sh,
ipc_multiplex.so, BusyBox, service_guard and hotspot scripts. Copying only the
UI/scripts cannot arm the boot-time hook. Remaining kernel-uninterruptible I/O
and driver faults can still require the existing reboot recovery.

Configuration reference: upstream [wpa_supplicant example configuration](https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf)
and [Linux Wireless documentation](https://wireless.docs.kernel.org/en/latest/en/users/documentation/wpa_supplicant.html).
