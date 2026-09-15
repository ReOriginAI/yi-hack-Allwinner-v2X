#!/usr/bin/env python3
"""Patch the tested y623 vendor boot partition to make VE debugfs allocation non-contiguous.

The 2023 y623 Linux 4.9.118 kernel implements ve_debugfs_open() with:

    kmalloc_order(16388, GFP_KERNEL, 3)

That forces a 32 KiB physically contiguous buddy allocation for a ~16 KiB
debug snapshot. Under fragmentation the open can trigger reclaim/OOM. The
snapshot is not DMA memory, so vmalloc() is sufficient. The matching release
path must use vfree().

This utility is intentionally strict. It only accepts the exact tested y623
uImage layout and verifies the original Thumb BL encodings before patching.
It preserves the complete MTD partition size and all bytes outside the XZ
kernel stream, then recomputes both uImage CRCs.
"""

from __future__ import annotations

import argparse
import hashlib
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

UIMAGE_MAGIC = 0x27051956
UIMAGE_HEADER_SIZE = 64

# Tested y623 boot image from Linux 4.9.118 #45 (2023-03-09).
EXPECTED_PAYLOAD_SIZE = 1_878_024
XZ_OFFSET = 15_273
XZ_SLOT_SIZE = 1_862_684
EXPECTED_IMAGE_SIZE = 3_742_168
VMLINUX_BASE = 0xC0008000

# Direct Thumb-2 BL call sites in the decompressed Image.
# ve_debugfs_release: kfree -> vfree
# ve_debugfs_open:    kmalloc_order -> vmalloc
PATCHES = (
    (0xC018C414, bytes.fromhex("edf66cff"), bytes.fromhex("e6f682fd"), "kfree -> vfree"),
    (0xC018C42C, bytes.fromhex("d9f658fc"), bytes.fromhex("e6f6b4fe"), "kmalloc_order -> vmalloc"),
)


class PatchError(RuntimeError):
    pass


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def run_xz(args: list[str], data: bytes) -> bytes:
    try:
        proc = subprocess.run(
            ["xz", *args],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError as exc:
        raise PatchError("xz is required on the build host") from exc
    if proc.returncode != 0:
        raise PatchError(f"xz failed: {proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def parse_uimage(partition: bytes) -> tuple[bytearray, bytearray, bytes]:
    if len(partition) < UIMAGE_HEADER_SIZE:
        raise PatchError("input is too small to contain a uImage header")

    header = bytearray(partition[:UIMAGE_HEADER_SIZE])
    magic, header_crc, _timestamp, size, _load, _entry, data_crc = struct.unpack(
        ">7I", header[:28]
    )
    if magic != UIMAGE_MAGIC:
        raise PatchError(f"unexpected uImage magic 0x{magic:08x}")
    if size != EXPECTED_PAYLOAD_SIZE:
        raise PatchError(
            f"unexpected y623 uImage payload size {size}; expected {EXPECTED_PAYLOAD_SIZE}"
        )
    if len(partition) < UIMAGE_HEADER_SIZE + size:
        raise PatchError("input partition dump is shorter than the uImage payload")

    header_for_crc = bytearray(header)
    struct.pack_into(">I", header_for_crc, 4, 0)
    actual_header_crc = crc32(header_for_crc)
    if actual_header_crc != header_crc:
        raise PatchError(
            f"uImage header CRC mismatch: have 0x{header_crc:08x}, "
            f"calculated 0x{actual_header_crc:08x}"
        )

    payload = bytearray(partition[UIMAGE_HEADER_SIZE : UIMAGE_HEADER_SIZE + size])
    if crc32(payload) != data_crc:
        raise PatchError(
            f"uImage data CRC mismatch: have 0x{data_crc:08x}, "
            f"calculated 0x{crc32(payload):08x}"
        )

    tail = partition[UIMAGE_HEADER_SIZE + size :]
    return header, payload, tail


def decompress_kernel(payload: bytes) -> bytes:
    end = XZ_OFFSET + XZ_SLOT_SIZE
    if end > len(payload):
        raise PatchError("XZ slot extends beyond the uImage payload")
    image = run_xz(["-dc"], payload[XZ_OFFSET:end])
    if len(image) != EXPECTED_IMAGE_SIZE:
        raise PatchError(
            f"unexpected decompressed Image size {len(image)}; "
            f"expected {EXPECTED_IMAGE_SIZE}"
        )
    return image


def patch_image(image: bytes) -> tuple[bytes, bool]:
    out = bytearray(image)
    states: list[str] = []

    for va, old, new, label in PATCHES:
        off = va - VMLINUX_BASE
        current = bytes(out[off : off + 4])
        if current == old:
            states.append("old")
        elif current == new:
            states.append("new")
        else:
            raise PatchError(
                f"{label} signature mismatch at 0x{va:08x}: "
                f"found {current.hex()}, expected {old.hex()}"
            )

    if all(state == "new" for state in states):
        return image, False
    if any(state == "new" for state in states):
        raise PatchError("kernel has a partially applied VE debugfs patch")

    for va, old, new, label in PATCHES:
        off = va - VMLINUX_BASE
        out[off : off + 4] = new
        print(f"patch 0x{va:08x}: {old.hex()} -> {new.hex()} ({label})")

    return bytes(out), True


def compress_kernel(image: bytes) -> bytes:
    # Keep the vendor's runtime format: ARM BCJ + LZMA2 32 MiB dictionary,
    # CRC32. depth=32 only changes host-side match-search effort and makes the
    # patched stream fit the original fixed zImage slot; decompressor memory
    # and on-device format remain unchanged.
    compressed = run_xz(
        [
            "-c",
            "--threads=1",
            "--check=crc32",
            "--arm",
            "--lzma2=preset=9,depth=32",
        ],
        image,
    )
    if len(compressed) > XZ_SLOT_SIZE:
        raise PatchError(
            f"patched XZ stream is {len(compressed)} bytes, "
            f"{len(compressed) - XZ_SLOT_SIZE} bytes too large"
        )
    padding = XZ_SLOT_SIZE - len(compressed)
    if padding % 4:
        raise PatchError(f"XZ stream padding {padding} is not a multiple of four")
    print(f"compressed kernel: {len(compressed)} bytes; XZ padding: {padding} bytes")
    return compressed + (b"\0" * padding)


def rebuild_uimage(
    original_partition: bytes, header: bytearray, payload: bytearray, tail: bytes, image: bytes
) -> bytes:
    slot = compress_kernel(image)
    before = bytes(payload)
    payload[XZ_OFFSET : XZ_OFFSET + XZ_SLOT_SIZE] = slot

    if payload[:XZ_OFFSET] != before[:XZ_OFFSET]:
        raise PatchError("bytes before the XZ stream changed unexpectedly")
    if payload[XZ_OFFSET + XZ_SLOT_SIZE :] != before[XZ_OFFSET + XZ_SLOT_SIZE :]:
        raise PatchError("bytes after the XZ stream changed unexpectedly")

    struct.pack_into(">I", header, 24, crc32(payload))
    struct.pack_into(">I", header, 4, 0)
    struct.pack_into(">I", header, 4, crc32(header))

    output = bytes(header) + bytes(payload) + tail
    if len(output) != len(original_partition):
        raise PatchError("output partition size changed")

    # Full post-build validation, including an XZ round trip.
    out_header, out_payload, out_tail = parse_uimage(output)
    del out_header
    if out_tail != tail:
        raise PatchError("MTD tail changed unexpectedly")
    roundtrip = decompress_kernel(out_payload)
    if roundtrip != image:
        raise PatchError("patched kernel failed XZ round-trip verification")

    for va, _old, new, label in PATCHES:
        off = va - VMLINUX_BASE
        if roundtrip[off : off + 4] != new:
            raise PatchError(f"post-build verification failed for {label}")

    return output


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Patch the tested y623 boot partition VE debugfs allocation"
    )
    parser.add_argument("input", type=Path, help="full /dev/mtdblock1 dump")
    parser.add_argument("output", type=Path, help="patched full boot-partition image")
    args = parser.parse_args()

    try:
        original = args.input.read_bytes()
        header, payload, tail = parse_uimage(original)
        image = decompress_kernel(payload)
        patched_image, changed = patch_image(image)

        if not changed:
            shutil.copyfile(args.input, args.output)
            print("kernel is already patched; copied input unchanged")
        else:
            output = rebuild_uimage(original, header, payload, tail, patched_image)
            args.output.write_bytes(output)
            print(f"wrote {args.output} ({len(output)} bytes)")
            print(f"sha256 {hashlib.sha256(output).hexdigest()}")

        return 0
    except (OSError, PatchError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
