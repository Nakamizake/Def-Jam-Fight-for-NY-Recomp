"""Builds a mod that brings back the voice choice of the story mode's Sketch Artist.

When you create your fighter, the Sketch Artist's last page, after "Positive ID?", asks what he
sounded like: six voices (Rough, Street, Clean Cut, Cocky, Smooth, Gruff), each with a preview
on X. The page is still in the GameCube release, complete with its art and its preview lines,
but the screen's script skips it on the GameCube only:

    if (_root.g_console == "gc") { nMenuFocus = 15; keyX(); }   // past the voice page
    ...
    if (_root.g_console == "gc") aMenuIndexes[15] = 0;           // always the first voice
    CreatePlayer.SetVoice(aMenuIndexes[15] + 1);

The mod rebuilds screens/screens.viv with those two tests comparing against "g_console" instead
of "gc", a string the console name never equals: one byte each in Sketch.apt, the screen's
compiled ActionScript (`EA_PushConstantByte`, the index into the function's constant pool).

The port applies this on its own, as one of its fixes (port_fixes.py). On its own, the tool
writes it as an ordinary mod, to switch on in Esc > MODS:

    python -I voice_select.py --gc-files extracted\\GNWE69\\files --out userdata\\Load\\Mods\\VoiceSelect

The game's files are only read.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import struct
import sys

# `python -I` leaves the script's own directory off sys.path; add it back for the sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refpack  # noqa: E402
import viv  # noqa: E402

ARCHIVE = "screens/screens.viv"
SCREEN = "screens/story/Sketch.big"
SCRIPT = "Sketch.apt"

# `if (_root.g_console == "gc")` in Sketch.apt: EA_PushValueOfVar '_root', EA_GetNamedMember
# 'g_console', EA_PushConstantByte 'gc', Equals2, Not, BranchIfTrue. In that function's constant
# pool 0x86 is 'g_console' and 0x87 'gc'.
CONSOLE_TEST = bytes.fromhex("ae2b af86 a287 49 12 9d")
GC_OPERAND = 5  # offset of the 'gc' index in CONSOLE_TEST
G_CONSOLE = 0x86
TESTS = 2  # the voice page has two of them, and nothing else in the script compares this way


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--gc-files", required=True, help="the GameCube game's files folder (extracted disc)")
    parser.add_argument("--out", required=True, help="mod folder to write")
    args = parser.parse_args()
    try:
        build(args.gc_files, args.out)
    except (OSError, ValueError) as error:
        sys.exit(f"voice_select: {error}")


def big_entry(data: bytes, name: str) -> tuple[int, int]:
    """(offset, size) of a file in a screen's BIGF bundle (BIG header, no "L2xx" marker)."""
    if data[:4] != b"BIGF":
        raise ValueError(f"{SCREEN} is not a BIGF bundle")
    count = struct.unpack_from(">I", data, 8)[0]
    pos = 16
    for _ in range(count):
        offset, size = struct.unpack_from(">II", data, pos)
        end = data.index(b"\0", pos + 8)
        if data[pos + 8:end].decode("latin-1").lower() == name.lower():
            return offset, size
        pos = end + 1
    raise ValueError(f"{SCREEN} has no {name}")


def patch_screen(screen: bytes) -> bytes:
    """Sketch.big with both console tests turned off."""
    offset, size = big_entry(screen, SCRIPT)
    script = screen[offset:offset + size]
    found = []
    start = script.find(CONSOLE_TEST)
    while start >= 0:
        found.append(start)
        start = script.find(CONSOLE_TEST, start + 1)
    if len(found) != TESTS:
        raise ValueError(f"{SCRIPT} has {len(found)} console tests where {TESTS} were expected "
                         "(not the GameCube release GNWE69, or already patched)")
    patched = bytearray(screen)
    for at in found:
        patched[offset + at + GC_OPERAND] = G_CONSOLE
    return bytes(patched)


def build(gc_files: str, out: str) -> None:
    source = pathlib.Path(gc_files) / ARCHIVE
    archive = viv.read_archive(source)
    if not any(entry.name.lower() == SCREEN.lower() for entry in archive.entries):
        raise ValueError(f"{source} has no {SCREEN}")
    files = []
    for entry in archive.entries:
        blob = archive.blob(entry)
        if entry.name.lower() == SCREEN.lower():
            packed = refpack.is_compressed(blob)
            screen = patch_screen(refpack.decompress(blob) if packed else blob)
            blob = refpack.compress(screen) if packed else screen
        files.append((entry.name, blob))
    target = pathlib.Path(out) / "files" / ARCHIVE
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(viv.build_archive(archive.magic, archive.marker, archive.alignment, files))
    print(f"voice page restored: {target}")


if __name__ == "__main__":
    main()
