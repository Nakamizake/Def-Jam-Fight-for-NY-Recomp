"""Compare a guest memory dump against the original main.dol to find self-modified code.

The runtime reports chunks whose code no longer hashes like the recompiled module
("SMC: chunk [...] hash mismatch"). Dump that range while the game runs
(scripts/bench.ps1 -DumpAddress ... -DumpSize ...) and run this to list every
32-bit word that differs from the executable on disc.

Usage:
    python -I diff_dol_memory.py main.dol mem-8028B4A0.bin 0x8028B4A0
"""

from __future__ import annotations

import argparse
import struct
import sys

TEXT_SECTIONS = 7
DATA_SECTIONS = 11


def load_sections(dol: bytes) -> list[tuple[int, int, int]]:
    """Returns (file_offset, address, size) for every non-empty DOL section."""
    count = TEXT_SECTIONS + DATA_SECTIONS
    offsets = struct.unpack_from(f">{count}I", dol, 0x00)
    addresses = struct.unpack_from(f">{count}I", dol, 0x48)
    sizes = struct.unpack_from(f">{count}I", dol, 0x90)
    return [(o, a, s) for o, a, s in zip(offsets, addresses, sizes) if s]


def dol_word(dol: bytes, sections: list[tuple[int, int, int]], address: int) -> int | None:
    for offset, base, size in sections:
        if base <= address < base + size:
            return struct.unpack_from(">I", dol, offset + address - base)[0]
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("dol")
    parser.add_argument("dump")
    parser.add_argument("address", type=lambda value: int(value, 0))
    args = parser.parse_args()

    dol = open(args.dol, "rb").read()
    dump = open(args.dump, "rb").read()
    sections = load_sections(dol)

    differences = 0
    for index in range(0, len(dump) - 3, 4):
        address = args.address + index
        live = struct.unpack_from(">I", dump, index)[0]
        original = dol_word(dol, sections, address)
        if original is not None and original != live:
            differences += 1
            print(f"0x{address:08X}: dol=0x{original:08X}  live=0x{live:08X}")
    print(f"{differences} differing words in {len(dump)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
