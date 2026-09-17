# Audited vendor boot inputs

`y623-boot-stock.bin` is the exact 1,900,544-byte `boot` (`/dev/mtdblock1`) partition from the supported y623 vendor firmware:

- `homever`: `12.0.51.01_202303091901`
- stock MD5: `2c8abc0f8376bdb55d8464abc6bf14a8`

It is a build input, not the image shipped directly to cameras. `scripts/pack_fw.sh` runs `scripts/patch_y623_ve_debugfs.py` against this exact image and requires the generated release image to have MD5:

- patched MD5: `26a2e9a432fbe36efe97f0e7cee84dc9`

The patch changes the VE debugfs snapshot allocation from `kmalloc_order(..., 3)` / `kfree()` to `vmalloc()` / `vfree()`. The packer, upload validator, upgrade path, and on-device installer all fail closed if these hashes drift.
