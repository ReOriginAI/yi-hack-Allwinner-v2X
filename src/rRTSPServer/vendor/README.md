# LIVE555 source archive

`live.2026.09.23.tar.gz` is the unmodified archive downloaded from
`https://download.live555.com/live.2026.09.23.tar.gz` on 2026-10-10 and used to
build the Standard RTSP server validated on y623 and y28ga.

SHA-256: `22da8a0e12219f049051052317ff3774eaae888e6f94fd7be746bc236ad0d7eb`.

The upstream download directory removes older releases. Bundling this archive
keeps clean builds independent of that retention policy and avoids silently
upgrading a camera dependency. `init.rRTSPServer` verifies its checksum before
any dependency download or removal of an existing build, then applies the
repository's camera patches after extraction.

The archive contains the upstream license notices and `COPYING` files. See
[LIVE555 licensing](https://www.live555.com/liveMedia/#license) for upstream
licensing information. The bundled archive itself is not patched.
