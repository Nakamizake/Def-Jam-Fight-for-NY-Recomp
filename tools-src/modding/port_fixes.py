"""Builds the port's fixes: what the port changes in the game on every boot, made from the disc.

The runtime applies <game>/fixes/ like a game-file mod that is always on and never listed in
MODS (a mod that replaces the same file wins). Nothing in it can ship with the port, since it
is built from the game's own files, so the game build (build-game.ps1) runs this tool:

    python -I port_fixes.py --game extracted\\GNWE69

Fixes:

- what the menus switch off on the GameCube: the Sketch Artist's voice page, the trailer in
  Extras and the menus' spotlight (gc_cuts.py).

The folder is rebuilt from scratch each time; the game's files are only read.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import sys

# `python -I` leaves the script's own directory off sys.path; add it back for the sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gc_cuts  # noqa: E402

FIXES = "fixes"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--game", required=True, help="the extracted game (the folder with files\\ and sys\\)")
    args = parser.parse_args()
    try:
        build(args.game)
    except (OSError, ValueError) as error:
        sys.exit(f"port_fixes: {error}")


def build(game: str) -> None:
    root = pathlib.Path(game)
    files = root / "files"
    if not (files / gc_cuts.ARCHIVE).is_file():
        raise ValueError(f"{root} is not an extracted game (no files\\{gc_cuts.ARCHIVE})")
    out = root / FIXES
    # Built aside and swapped in, so a failure leaves the previous fixes in place.
    staging = root / (FIXES + ".new")
    shutil.rmtree(staging, ignore_errors=True)
    gc_cuts.build(str(files), str(staging))
    shutil.rmtree(out, ignore_errors=True)
    staging.rename(out)
    print(f"port fixes ready in {out}")


if __name__ == "__main__":
    main()
