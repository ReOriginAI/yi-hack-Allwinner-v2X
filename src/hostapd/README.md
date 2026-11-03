# Camera AP daemon

The vendor supplicant on the audited cameras has AP support compiled out, despite
advertising the driver's AP capability. The shared payload builds hostapd for
hotspot operation and keeps the vendor supplicant for normal station Wi-Fi.

Sources downloaded and verified by `init.hostapd`:

- [hostapd 2.11](https://w1.fi/releases/hostapd-2.11.tar.gz), SHA-256
  `2b3facb632fd4f65e32f4bf82a76b4b72c501f995a4f62e330219fe7aed1747a`.
- [OpenWrt libnl-tiny](https://github.com/openwrt/libnl-tiny), commit
  `40493a655d8caa2ccf5206dde1e733abe2920432`, archive SHA-256
  `a3f0456006b72352f0ccc9a653eb2428a03bc3ff3c6987a858b0c060ac19b181`.

Build with the firmware's musl toolchain, CMake, make and Python:

```sh
bash src/hostapd/init.hostapd
YI_TOOLCHAIN_BIN=/opt/yi/toolchain-sunxi-musl/toolchain/bin \
  bash src/hostapd/compile.hostapd
```

The size profile includes nl80211, open/WPA2-PSK, internal AES/SHA/MD5 and the
control interface. Enterprise TLS, RADIUS, accounting and VLAN support are omitted.
Thumb-2, LTO, section collection and stripped symbols reduce hostapd from about
531 KiB to 254 KiB and hostapd_cli to 25 KiB. Netlink is linked statically so the
camera's older libnl-tiny ABI is not a dependency. libc/libgcc remain dynamic.

Verbose stdout debugging is compiled out. Control status and AP events remain
available. The small header patch fixes the missing no-op for CLOSE_LOG in this
upstream configuration. For a diagnostic build, remove CONFIG_NO_STDOUT_DEBUG;
that larger binary must be measured again before flash packaging.

The firmware compiler discovers this module automatically. Flash packaging puts
the daemon in backup on y623 and home on y28ga, retaining at least 128 KiB backup
headroom. Complete flash images remain experimental pending physical cold boot.
See [hotspot validation](../../docs/HOTSPOT.md).
