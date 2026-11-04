# Hotspot and rear-button recovery

The shared payload supports y623 and y28ga using packaged hostapd 2.11 with
nl80211 and BusyBox DHCP. The vendor wpa_supplicant remains responsible for
station WiFi: its binary reports driver AP capability but contains the compiled
stub "AP mode support not included in the build". It cannot run this hotspot.
No DNS daemon, Internet forwarding or permanent extra WiFi monitor is added.

## Use

On the WiFi page, configure the hotspot name/channel and save. A blank name uses
`cam-MODEL-MACSUFFIX` (for example, `cam-y623-340a2f`). Set an optional 8–63 printable ASCII character WPA2
password. A blank password field keeps the saved value; Remove hotspot password
explicitly clears it. Start Hotspot queues a transition; the current WiFi
connection drops once the watchdog handles it. Join the hotspot network and browse
to `http://192.168.10.1` (append a custom HTTP port if configured). With no saved password the network is open; otherwise it uses WPA2-PSK/CCMP.
Camera HTTP/SSH authentication remains unchanged. Save settings, then stop/start
the hotspot to apply a changed password. Status reports only whether a password
is set, never the password itself.

Return to Primary WiFi queues restoration of the original primary profile and
DHCP/static-IP policy. Primary flash credentials are never erased by this path.
The AP is local camera access only; phones may report no Internet access.

Start in hotspot mode after reboot persists the AP boot preference. Without
that option, a button/manual hotspot is temporary and reboot returns to the
normal station startup. Without saved router credentials (the provisioning partition password is empty
or erased), and without an SD Factory/configure_wifi.cfg request, startup queues
an open hotspot for provisioning. This repeats until router credentials are
saved. An unreadable/short provisioning read does not trigger this fallback.
The rear-button override defaults to enabled on audited firmware; existing
explicit disabled preferences are preserved. Settings are `WIFI_HOTSPOT_BOOT`, `WIFI_HOTSPOT_SSID`,
`WIFI_HOTSPOT_CHANNEL` (1-11, default 6), `WIFI_HOTSPOT_PASSWORD`, and
`WIFI_RESET_HOTSPOT`.

## Import hotspot settings from SD

Create `Factory/configure_wifi.cfg` with exactly one complete pair:

```ini
hotspot_ssid=My Camera
hotspot_psk=CameraPassword
```

An explicit empty `hotspot_psk=` selects an open network. A nonempty password
must be 8–63 printable ASCII characters; the SSID must be 1–32 UTF-8 bytes.
Do not add `wifi_ssid` or `wifi_psk` to the same file, even as blank fields.
Those two names select router provisioning instead and disable hotspot boot.
Commented examples are ignored, but duplicate or incomplete pairs are rejected.

Hotspot imports update the saved hotspot settings and enable hotspot boot,
without reading/writing the vendor router provisioning partition. Explicit
hotspot settings take precedence over the unprovisioned first-start fallback,
so a selected password is not cleared on a fresh camera. The rear button still
clears the hotspot password when deliberately held after the override is armed.
Saved router credentials remain available for switching back.

After applying the file, installed firmware renames it to
`configure_wifi.cfg.applied`. An invalid file becomes
`configure_wifi.cfg.rejected` and saved settings remain active. First installation
instead reports configuration errors in `hack_result.txt` until corrected.
Use a new `Factory/` directory containing only this file when `Factory.done/`
already exists. Flash-core mirrors imported settings to its internal fallback
so they also apply when subsequently booted without SD.

## Button override

Use rear reset button for hotspot defaults to enabled. Install/reboot with the matching
new bootstrap/payload. Check Current reset button behavior: it must report that
the override is active before relying on the pin button for hotspot entry.
A saved preference alone does not mean the running vendor broker was updated.
The watchdog enables interception after startup initializes the local services,
even when router Wi-Fi is unavailable; a further
30-second settling period and a released-button sample precede hotspot holds.
During startup the button retains vendor behavior. Wait for the UI to report
the override active before pressing it.

When armed, a continuous five-second active-low press emits one open-hotspot request;
the worker persistently clears the hotspot password before starting the AP.
Router credentials and camera login are not cleared;
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

The vendor broker also runs station recovery independently of the shell
watchdog. The bootstrap wraps its `wificonnect.sh`, `killwifi.sh` and
`wifidhcp.sh` entry points in both vendor script directories. During AP startup,
operation and rollback these wrappers return without touching the radio. Outside
those states they run the preserved originals with unchanged arguments. Explicit
AP rollback uses the core DHCP helper directly, so it can still restore station
connectivity while the vendor entry points are gated.

Readiness requires both hostapd `state=ENABLED` and the driver's actual
`Mode:Master`, checked with a bounded ioctl command. If hostapd and DHCP remain
alive but the radio leaves AP mode, the next watchdog pass restores router Wi-Fi
instead of retaining a false active status.

Only wlan0 is configured, without an explicit wlan0 down/up cycle. hostapd handles the required interface-mode switch. DHCP is restricted to
wlan0, with 16 leases at 192.168.10.100-150 and the camera at 192.168.10.1.
Starting the AP replaces the station connection; simultaneous AP+station is not
implemented. AP config/state/leases/requests live in RAM. No router credential rewrite is used for entering/leaving the hotspot. The
button worker clears the saved hotspot password, serialized with WiFi API saves.

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

Initial live probes on y28ga 192.168.1.203 reproduced the vendor supplicant failure.
With hostapd, the controller reached active, hostapd reported AP-ENABLED and
state=ENABLED, wlan0 had 192.168.10.1, and BusyBox udhcpd ran. A scheduled
rollback restored the original station connection and DHCP lease. The optimized
build also reached ENABLED with WPA-PSK/CCMP configured. At that stage, client
association, a physical pin press and persistent deployment had not been
validated. The subsequent no-SD deployment and client test are recorded below;
y623 hardware validation remains pending.

Ship the entire rebuilt firmware, including matching Factory/local_init.sh,
ipc_multiplex.so, BusyBox, service_guard and hotspot scripts. Copying only the
UI/scripts cannot arm the boot-time hook. Remaining kernel-uninterruptible I/O
and driver faults can still require the existing reboot recovery.

The size profile uses Thumb-2, LTO, internal WPA2 cryptography and no verbose
stdout debugging; hostapd control/status remain enabled. See the pinned
[build inputs and size notes](../src/hostapd/README.md).

Configuration reference: upstream [wpa_supplicant example configuration](https://w1.fi/cgit/hostap/plain/wpa_supplicant/wpa_supplicant.conf)
and [Linux Wireless documentation](https://wireless.docs.kernel.org/en/latest/en/users/documentation/wpa_supplicant.html).

On 2026-11-03, a no-SD y28ga test on `.203` reproduced an independent vendor
supplicant changing the radio from Master back to Managed while hostapd still
reported ENABLED. Guarding the vendor station entry points kept the radio in
Master mode. The user then saw the temporary `yi-203-test` open network, joined
it and loaded the camera page at `192.168.10.1`. Temporary test settings lived
in RAM and did not replace the saved hotspot name/password. WPA2/CCMP daemon
configuration was also exercised; a password-protected client association and a
physical rear-button hold remain separate hardware checks.

After that fix, `.203` returned to router Wi-Fi and passed another reboot with
no SD card. The guarded vendor entry points and radio-mode checks were present
after reboot; HTTP/clock controls and a fresh RTSP video stream also passed.
