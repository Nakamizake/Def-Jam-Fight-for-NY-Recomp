"""Builds mods for the GameCube release out of the PlayStation 2 release: pick what to take.

Each extra becomes a mod of its own in the mods folder, switched on and off in Esc > MODS:

    --textures  PS2Textures  most textures at twice the resolution (ps2_textures.py)
    --music     PS2Music     the soundtrack at the PS2's higher sample rate, plus the 13 songs the
                             GameCube release left out (ps2_music.py)

    python -I ps2_extras.py --gc-files extracted\\GNWE69\\files --ps2 DefJamPs2.iso \\
        --mods userdata\\Load\\Mods --textures --music

The extras are built one after another; one that fails does not stop the others. The exit code
is 0 only if all of them were built. Both discs are only read.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys
from dataclasses import dataclass
from typing import Callable

# `python -I` leaves the script's own directory off sys.path; add it and the modding tools.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_HERE, os.path.join(os.path.dirname(_HERE), "modding")]
import ps2_music  # noqa: E402
import ps2_textures  # noqa: E402


@dataclass(frozen=True)
class Extra:
    option: str  # command-line switch, without the dashes
    mod: str  # the mod folder it is built into
    description: str
    build: Callable[[str, str, str, int], None]  # (gc_files, ps2_source, out, jobs)


EXTRAS = [
    Extra("textures", "PS2Textures", "most textures at twice the resolution", ps2_textures.build),
    Extra("music", "PS2Music", "the soundtrack at the PS2's sample rate, plus its 13 extra songs", ps2_music.build),
]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--gc-files", required=True, help="the GameCube game's files folder (extracted disc)")
    parser.add_argument("--ps2", required=True, help="the PlayStation 2 disc image (.iso) or a copy of its files")
    parser.add_argument("--mods", required=True, help="the mods folder (userdata\\Load\\Mods); each extra is a folder in it")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    for extra in EXTRAS:
        parser.add_argument(f"--{extra.option}", action="store_true", help=f"{extra.mod}: {extra.description}")
    args = parser.parse_args()

    chosen = [extra for extra in EXTRAS if getattr(args, extra.option)]
    if not chosen:
        parser.error("choose at least one extra: " + ", ".join(f"--{extra.option}" for extra in EXTRAS))
    failed = []
    for extra in chosen:
        print(f"== {extra.mod}: {extra.description}", flush=True)
        try:
            extra.build(args.gc_files, args.ps2, str(pathlib.Path(args.mods) / extra.mod), args.jobs)
        except (OSError, ValueError) as error:
            print(f"{extra.mod} failed: {error}", flush=True)
            failed.append(extra.mod)
    if failed:
        sys.exit(f"ps2_extras: not built: {', '.join(failed)}")


if __name__ == "__main__":
    main()
