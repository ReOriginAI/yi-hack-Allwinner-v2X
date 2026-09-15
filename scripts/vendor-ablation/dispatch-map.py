#!/usr/bin/env python3
"""Print the message-ID comparisons and forwarding masks in audited dispatch ELFs.

This is intentionally read-only and only accepts the two captured disassemblies.
It does not attempt to assign cloud semantics to an ID: the mask is a field in
the received record and the queue slot layout differs between firmware families.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2] / "build/vendor-ablation"
TARGETS = {
    "y623": ("y623/elf/home_app_dispatch.disasm", 0x166B8, 0x17000),
    "y28ga": ("y28ga/elf/home_app_dispatch.disasm", 0x14668, 0x15000),
}

for model, (rel, lo, hi) in TARGETS.items():
    path = ROOT / rel
    print(f"[{model}] {path}")
    ids = []
    for line in path.read_text().splitlines():
        m = re.match(r"\s*([0-9a-f]+):.*cmp\s+r3, #([0-9]+)", line)
        if m and lo <= int(m.group(1), 16) < hi:
            ids.append((int(m.group(1), 16), int(m.group(2))))
    print("raw r3 comparison constants (includes payload checks; incomplete ID map):",
          " ".join(f"0x{i:x}" for _, i in ids))
    if model == "y623":
        slots = {0x02: "/ipc_rmm", 0x04: "/ipc_cloud", 0x08: "/ipc_p2p", 0x10: "/ipc_rcd"}
    else:
        slots = {0x02: "/ipc_rmm", 0x04: "/ipc_cloud", 0x08: "/ipc_p2p", 0x10: "/ipc_rcd", 0x20: "/ipc_rtmp", 0x100: "/ipc_mdns"}
    print("mask destinations:", ", ".join(f"0x{k:x}->{v}" for k, v in slots.items()))
