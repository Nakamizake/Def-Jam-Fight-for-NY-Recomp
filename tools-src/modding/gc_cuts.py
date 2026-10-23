"""Builds a mod that brings back what the menus switch off on the GameCube.

The front end's screens are Flash movies whose compiled ActionScript (the `.apt` script of each
screen's bundle in screens/screens.viv) runs on every console the game shipped on, and branches
on `_root.g_console` where the consoles differ. On the GameCube, a few of those branches leave
out things whose art, sounds and video are still on the disc:

- **Voice page.** The story mode's Sketch Artist ends with one more page after "Positive ID?":
  what your fighter sounds like, out of six voices (Rough, Street, Clean Cut, Cocky, Smooth,
  Gruff), each with a preview on X. The GameCube skips the page and always gives the first voice;
  its executable also maps all six voices to the first one's speech banks, so the chosen voice
  needs the PlayStation 2's table back too (a memory patch, VOICE_BANKS).
- **Venue map.** Choose Venue draws the city from battle/map.swf, a map about four times as
  detailed as the battle/map_ngc.swf the GameCube loads instead.
- **Trailer.** Extras has a third poster that plays the game's trailer (movies/attract.mad),
  from the posters the PlayStation 2 release uses; the GameCube wall has only Cheats and Intro.
- **Spotlight.** Most menus lay a soft light over the screen that darkens its edges (a clip
  named lightingClip); the GameCube hides it.

Each of those tests reads `if (_root.g_console == "gc")`, which compiles to EA_PushValueOfVar
'_root', EA_GetNamedMember 'g_console', EA_PushConstantByte 'gc', a comparison, BranchIfTrue.
The mod turns a test off by pointing its 'gc' operand (an index into the function's constant
pool) at the 'g_console' entry instead, a string the console name never equals: one byte each.

The port applies this on its own, as one of its fixes (port_fixes.py). On its own, the tool
writes it as an ordinary mod, to switch on in Esc > MODS:

    python -I gc_cuts.py --gc-files extracted\\GNWE69\\files --out userdata\\Load\\Mods\\GCCuts

The game's files are only read.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import pathlib
import struct
import sys

# `python -I` leaves the script's own directory off sys.path; add it back for the sibling modules.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refpack  # noqa: E402
import viv  # noqa: E402

ARCHIVE = "screens/screens.viv"

NAME_OPERAND = 3  # in a test: the 'g_console' operand of EA_GetNamedMember
CONSOLE_OPERAND = 5  # in a test: the 'gc' operand of EA_PushConstantByte


@dataclasses.dataclass(frozen=True)
class ConsoleTest:
    """One `_root.g_console == "gc"` test to turn off, found by its bytes.

    `test` runs from EA_PushValueOfVar '_root' to BranchIfTrue; the operand bytes are the
    function's own constant pool indices, so a test reads differently in every function. Where
    the same bytes guard something else too, `body` picks the test by the first bytes of the
    code it branches over (after BranchIfTrue's 4-byte target, aligned to 4).
    """

    screen: str
    test: str
    count: int = 1
    body: str = ""

    @property
    def script(self) -> str:
        return pathlib.PurePosixPath(self.screen).stem + ".apt"


VOICE_PAGE = [
    # Skips the page (nMenuFocus = 15; keyX()), then forces voice 1 (aMenuIndexes[15] = 0).
    ConsoleTest("screens/story/Sketch.big", "ae2b af86 a287 49 12 9d", count=2),
]
VENUE_MAP = [
    # Loads map_ngc.swf instead of map.swf.
    ConsoleTest("screens/battle/chsVenue.big", "ae60 af88 a289 49 12 9d"),
    # `!= "gc"`: the map clip's blackScreen animation, which map_ngc.swf does not have.
    ConsoleTest("screens/battle/chsVenue.big", "ae60 af88 a289 49 12 12 9d", count=2),
]
TRAILER = [
    # `=== "gc"` loads ngc_posters.swf; without it the wall falls through to ps2_posters.swf.
    ConsoleTest("screens/extras/extras.big", "ae19 af41 a243 66 9d"),
]
SPOTLIGHT = [
    # lightingClip._visible = false
    ConsoleTest("screens/battle/buyrewards.big", "ae00 af10 a211 49 12 9d"),
    ConsoleTest("screens/battle/chooseF2.big", "ae24 af66 a267 49 12 9d", body="a3"),
    ConsoleTest("screens/battle/chooseF3.big", "ae24 af66 a267 49 12 9d", body="a3"),
    ConsoleTest("screens/battle/chsTeam4.big", "ae21 afbe a2bf 49 12 9d"),
    ConsoleTest("screens/battle/chsVenue.big", "ae01 af02 a203 49 12 9d"),
    ConsoleTest("screens/battle/unlockchar.big", "ae0a af34 a235 49 12 9d"),
    ConsoleTest("screens/battle/unlockven.big", "ae0a af37 a238 49 12 9d"),
    ConsoleTest("screens/hiScores/hiScores.big", "ae5e afae a2af 49 12 9d"),
    ConsoleTest("screens/jukebox/beatbox.big", "ae12 afba a2bb 49 12 9d"),
    ConsoleTest("screens/story/Sketch.big", "ae2b afb3 a2b4 49 12 9d"),
    ConsoleTest("screens/story/charDec.big", "ae39 af5e a25f 49 12 9d", body="ae90"),
]
TESTS = VOICE_PAGE + VENUE_MAP + TRAILER + SPOTLIGHT

# The created fighter's speech banks by voice (speech/*/Def_Jam_IP_Characters/<id>), read by the
# fight setup at 0x8002F380 for the voice CreatePlayer.SetVoice stored. The GameCube's table gives
# every voice bank 536; the PlayStation 2's (SLUS_210.04) has one per voice, all on both discs.
VOICE_BANKS_ADDRESS = 0x8029E384
VOICE_BANKS_GC = [536] * 6
VOICE_BANKS = [536, 534, 537, 538, 532, 533]
PATCHES = "patches.txt"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--gc-files", required=True, help="the GameCube game's files folder (extracted disc)")
    parser.add_argument("--out", required=True, help="mod folder to write")
    args = parser.parse_args()
    try:
        build(args.gc_files, args.out)
    except (OSError, ValueError) as error:
        sys.exit(f"gc_cuts: {error}")


def big_entry(data: bytes, screen: str, name: str) -> tuple[int, int]:
    """(offset, size) of a file in a screen's BIGF bundle (BIG header, no "L2xx" marker)."""
    if data[:4] != b"BIGF":
        raise ValueError(f"{screen} is not a BIGF bundle")
    count = struct.unpack_from(">I", data, 8)[0]
    pos = 16
    for _ in range(count):
        offset, size = struct.unpack_from(">II", data, pos)
        end = data.index(b"\0", pos + 8)
        if data[pos + 8:end].decode("latin-1").lower() == name.lower():
            return offset, size
        pos = end + 1
    raise ValueError(f"{screen} has no {name}")


def branch_body(script: bytes, branch: int) -> bytes:
    """The code a BranchIfTrue at `branch` jumps over: after its target, aligned to 4."""
    start = ((branch + 1 + 3) & ~3) + 4
    return script[start:start + 8]


def find_test(script: bytes, test: ConsoleTest) -> list[int]:
    pattern = bytes.fromhex(test.test)
    body = bytes.fromhex(test.body)
    found = []
    start = script.find(pattern)
    while start >= 0:
        if branch_body(script, start + len(pattern) - 1).startswith(body):
            found.append(start)
        start = script.find(pattern, start + 1)
    if len(found) != test.count:
        raise ValueError(f"{test.script} has {len(found)} copies of the console test {test.test} where "
                         f"{test.count} were expected (not the GameCube release GNWE69, or already patched)")
    return found


def patch_screen(screen: str, data: bytes, tests: list[ConsoleTest]) -> bytes:
    """A screen's bundle with its console tests turned off."""
    patched = bytearray(data)
    for test in tests:
        offset, size = big_entry(data, screen, test.script)
        for at in find_test(data[offset:offset + size], test):
            # Found in the original, so a test patched earlier never changes what is found.
            patched[offset + at + CONSOLE_OPERAND] = data[offset + at + NAME_OPERAND]
    return bytes(patched)


def build(gc_files: str, out: str) -> None:
    source = pathlib.Path(gc_files) / ARCHIVE
    archive = viv.read_archive(source)
    by_screen: dict[str, list[ConsoleTest]] = {}
    for test in TESTS:
        by_screen.setdefault(test.screen.lower(), []).append(test)
    names = {entry.name.lower() for entry in archive.entries}
    missing = sorted(set(by_screen) - names)
    if missing:
        raise ValueError(f"{source} has no {', '.join(missing)}")
    files = []
    for entry in archive.entries:
        blob = archive.blob(entry)
        tests = by_screen.get(entry.name.lower())
        if tests:
            packed = refpack.is_compressed(blob)
            screen = patch_screen(entry.name, refpack.decompress(blob) if packed else blob, tests)
            blob = refpack.compress(screen) if packed else screen
        files.append((entry.name, blob))
    target = pathlib.Path(out) / "files" / ARCHIVE
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(viv.build_archive(archive.magic, archive.marker, archive.alignment, files))
    (pathlib.Path(out) / PATCHES).write_text(voice_banks_patch(), encoding="ascii")
    print(f"GameCube cuts restored ({len(by_screen)} screens, voice banks): {target}")


def voice_banks_patch() -> str:
    """The patches.txt line that gives each voice its own speech banks (see VOICE_BANKS)."""
    def words(values: list[int]) -> str:
        return "".join(struct.pack(">I", value).hex().upper() for value in values)
    return ("# The created fighter's speech banks by voice, as on the PlayStation 2\n"
            f"{VOICE_BANKS_ADDRESS:08X} {words(VOICE_BANKS)} {words(VOICE_BANKS_GC)}\n")


if __name__ == "__main__":
    main()
