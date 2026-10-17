"""Adds function names to the native stacks of a diagnostic report.

The runtime writes stall, crash and manual reports (userdata/Diagnostics) with native
frames as `module+0xoffset`, so the game never has to load its PDBs. This resolves them
offline with dbghelp, using the PDB next to each module path listed in the report's
[modules] section, and prints the report with ` -> function` appended to each frame.

Usage:
    python -I resolve_report.py userdata/Diagnostics/stall-20261017-012345.txt
    python -I resolve_report.py report.txt --module gGNWE69_recomp.dll=path/with/pdb.dll
"""

from __future__ import annotations

import argparse
import os
import re
import sys

# `python -I` leaves the script's own directory off sys.path; add it back for the sibling module.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sample_profiler import SymbolResolver  # noqa: E402

FRAME = re.compile(r"(?P<module>[\w.-]+\.(?:dll|exe))\+0x(?P<offset>[0-9a-fA-F]+)")
MODULE_LINE = re.compile(r"^\s+(?P<name>\S+) = (?P<path>.+)$")


def module_paths(lines: list[str], overrides: list[str]) -> dict[str, str]:
    paths: dict[str, str] = {}
    in_modules = False
    for line in lines:
        if line.startswith("["):
            in_modules = line.strip() == "[modules]"
            continue
        match = MODULE_LINE.match(line) if in_modules else None
        if match:
            paths[match["name"].lower()] = match["path"].strip()
    for override in overrides:
        name, _, path = override.partition("=")
        paths[name.lower()] = path
    return paths


def image_size(path: str) -> int:
    """SizeOfImage from the PE optional header (dbghelp needs it to map offsets)."""
    with open(path, "rb") as image:
        header = image.read(4096)
    pe_offset = int.from_bytes(header[0x3C:0x40], "little")
    return int.from_bytes(header[pe_offset + 24 + 56: pe_offset + 24 + 60], "little")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("report", help="report written by the runtime")
    parser.add_argument("--module", action="append", default=[], metavar="NAME=PATH",
                        help="use this file (with a PDB beside it) for a module of the report")
    args = parser.parse_args()

    with open(args.report, encoding="utf-8", errors="replace") as source:
        lines = source.read().splitlines()
    paths = module_paths(lines, args.module)

    resolver = SymbolResolver()
    loaded: dict[str, bool] = {}
    missing: set[str] = set()

    def annotate(match: re.Match) -> str:
        name = match["module"].lower()
        path = paths.get(name)
        if path is None or not os.path.exists(path):
            missing.add(match["module"])
            return match[0]
        if path not in loaded:
            loaded[path] = resolver.load(path, image_size(path))
            if not loaded[path]:
                missing.add(match["module"])
        if not loaded[path]:
            return match[0]
        return f"{match[0]} -> {resolver.name(path, int(match['offset'], 16))}"

    try:
        for line in lines:
            print(FRAME.sub(annotate, line) if line.lstrip().startswith("#") else line)
    finally:
        resolver.close()
    if missing:
        print(f"\n(no PDB for: {', '.join(sorted(missing))})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
