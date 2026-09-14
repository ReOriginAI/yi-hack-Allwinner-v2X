# rsync for yi-hack

This module builds rsync 3.5.0 for the Allwinner ARM-musl cameras.

The user-supplied `rsync-prebuilt.tgz` is retained for reference, but is not installed because that binary has a runtime dependency on `libcrypto.so.1.1`, which is not present on tested older firmware (y28ga 9.0.20.06).

The firmware build instead compiles the official rsync 3.5.0 release with OpenSSL, xxhash, zstd, lz4, iconv, and rolling-checksum SIMD disabled. The resulting binary uses rsync's bundled zlib/popt and internal MD4/MD5 implementations and depends only on musl libc and `libgcc_s.so.1`.

Official source: https://download.samba.org/pub/rsync/src/rsync-3.5.0.tar.gz

Source SHA-256: `c7ffd1ef653e99540f661e47cb00b7f9cad1ee6b972399b16f93d672656e0d33`
