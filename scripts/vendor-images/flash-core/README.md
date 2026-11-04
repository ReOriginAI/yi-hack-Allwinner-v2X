# Pinned flash-core base inputs

`bases.tar.xz` supplies the vendor filesystems required by CI. Its archive SHA-256
and the exact member allowlist, sizes and SHA-256 hashes are in `manifest.json`.
`scripts/pack_flash_core_all.py` checks the archive, verifies every member, rejects
extra/duplicate/link/traversal entries, then extracts it. No camera connection,
credential or external firmware download is needed during CI packaging.

| Model | Vendor home version |
| --- | --- |
| y623 | `12.0.51.01_202303091901` |
| y28ga | `9.0.20.06_202007061841` |

Each model contains the unmodified read-only rootfs and home partition images,
plus a generic `backup/` skeleton made only from:

- `ko/8189fs.ko` (plus `ko/icplus.ko` on y28ga);
- `tools/wpa_supplicant` and `tools/default.script`;
- the stock `wifidhcp.sh`, `ethdhcp.sh` and `wificonnect.sh` scripts.

The files were taken from the audited vendor partition captures, not from active
SD configuration or recordings. No raw backup partition, old init, `back.bin`,
MTD7 Wi-Fi credentials, environment, manufacturing data, user SSH keys or yi-hack
configuration is included. The skeleton gets a newly rendered bootstrap and
generic defaults during the build. Read-only rootfs/home hashes are pinned so
another firmware revision cannot silently become a build input.

The archive uses sorted regular members, fixed timestamps, root ownership and
normalized permissions. SHA-256 checks make the reviewed inputs independent of
the build machine. The source archive is about 7.3 MiB. It is a build input, not
a camera recovery package and must not be copied to SD expecting installation.

To inspect the member list without extraction:

```sh
tar tJf scripts/vendor-images/flash-core/bases.tar.xz
python3 scripts/test_flash_core_build.py
```

Use the images only with the matching model. Physical flash/cold-boot validation
and an installation/rollback procedure remain necessary before deployment.

## Ready SD recovery packages

Do not put `bases.tar.xz` itself on SD. Run
`python3 scripts/pack_vendor_recovery.py --output out/vendor-recovery` to generate
model-specific, ready-to-extract ZIPs with checked U-Boot headers, a temporary
rescue rootfs, original vendor filesystems and bootstrap repair. The build uses
only the pinned generic inputs above; private identity/configuration dumps are
never release inputs. See the root README for startup/kernel limitations and
physical validation status. GitHub Actions publishes these separately as
`yi-hack-Allwinner-v2X-vendor-recovery`.
