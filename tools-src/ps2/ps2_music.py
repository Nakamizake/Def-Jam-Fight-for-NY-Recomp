"""Builds a music mod for the GameCube release from the PlayStation 2 release's music.

The PlayStation 2 disc has the soundtrack at a higher sample rate (36000 Hz against 22050) and
13 songs the GameCube release left out. This tool converts that music to the GameCube's formats
(see ea_audio.py and mpf.py) and writes a mod with the game's five music archives rebuilt:

- every song both discs have plays the PS2 recording; its loading-screen and overlay sound
  banks stay the GameCube ones (the game holds those in buffers sized for them, and they are
  the same sounds);
- the PS2-only songs are added, their banks resampled to the GameCube rate so they fit;
- patches.txt lets the jukebox list them: the GameCube executable skips 12 of them by name, and
  the patch blanks those names (each one only if it is still there, unchanged).

    python -I ps2_music.py --gc-files extracted\\GNWE69\\files --ps2 DefJamPs2.iso \\
        --out userdata\\Load\\Mods\\PS2Music

Switch the mod on in Esc > MODS; it applies from the next start. Both discs are only read.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import pathlib
import sys
import time

# `python -I` leaves the script's own directory off sys.path; add it and the modding tools.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_HERE, os.path.join(os.path.dirname(_HERE), "modding")]
import ea_audio  # noqa: E402
import mpf  # noqa: E402
import viv  # noqa: E402
from ps2disc import Ps2Disc  # noqa: E402

ARCHIVES = [f"audio/music{i}.viv" for i in range(5)]

# Where the GameCube executable (GNWE69) keeps the names of the songs its jukebox skips: the
# list the code at 0x800063DC compares each song with. Blanking a name's first byte makes it
# match no song.
SKIPPED_SONGS = {
    0x80297D54: "arewecuttin", 0x80297D60: "getintoit", 0x80297D6C: "getitnow",
    0x80297D78: "ricache", 0x80297D80: "mamasaid", 0x80297D8C: "nuffrespect",
    0x80297D98: "pump", 0x80297DA0: "poppalarge", 0x80297DAC: "seizetheday",
    0x80297DB8: "hitem", 0x80297DC0: "nwa", 0x80297DC4: "minitrack2",
}


def song_of(name: str) -> str:
    """'music/<song>/<file>' -> '<song>'; '' for the archives' other files."""
    parts = name.split("/")
    return parts[1] if len(parts) == 3 else ""


def convert_entry(name: str, ps2: bytes) -> bytes:
    """One PS2 music file in GameCube form (runs in a worker process)."""
    if name.endswith("/tune.mpf"):
        return mpf.to_gamecube(ps2)
    if name.endswith("/main.mus"):
        return ea_audio.stream_to_gamecube(ps2)
    return ea_audio.bank_to_gamecube(ps2, rate_divisor=3)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--gc-files", required=True, help="the GameCube game's files folder (extracted disc)")
    parser.add_argument("--ps2", required=True, help="the PlayStation 2 disc image (.iso) or a copy of its files")
    parser.add_argument("--out", required=True, help="mod folder to write")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()
    try:
        build(args.gc_files, args.ps2, args.out, args.jobs)
    except (OSError, ValueError) as error:
        sys.exit(f"ps2_music: {error}")


def build(gc_files: str, ps2_source: str, out: str, jobs: int) -> None:
    started = time.monotonic()
    gc_root = pathlib.Path(gc_files)
    disc = Ps2Disc(ps2_source)

    # Every PS2 music file by its GameCube-style name, and the archive it is in.
    ps2: dict[str, tuple[int, bytes]] = {}
    for index, archive in enumerate(ARCHIVES):
        path = disc.find(archive)
        if not path:
            raise ValueError(f"{ps2_source} does not look like Def Jam: Fight for NY for PlayStation 2 "
                             f"(no {archive.upper()} on it)")
        contents = viv.parse_archive(disc.read(path), path)
        for entry in contents.entries:
            ps2[entry.name.replace("\\", "/").lower()] = (index, contents.blob(entry))

    gc = [viv.read_archive(gc_root / archive) for archive in ARCHIVES]
    gc_songs = {song_of(e.name) for a in gc for e in a.entries} - {""}
    ps2_songs = {song_of(n) for n in ps2} - {""}
    new_songs = sorted(ps2_songs - gc_songs)

    # What to convert: the PS2 recording of every shared song (its banks stay the GameCube
    # ones) and all of each new song.
    jobs_list = [name for name in ps2 if song_of(name) in gc_songs and name.endswith(("/main.mus", "/tune.mpf"))]
    jobs_list += [name for name in ps2 if song_of(name) in new_songs]
    print(f"{len(gc_songs & ps2_songs)} songs on both discs, {len(new_songs)} only on PS2: {', '.join(new_songs)}")
    converted: dict[str, bytes] = {}
    with concurrent.futures.ProcessPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(convert_entry, name, ps2[name][1]): name for name in jobs_list}
        for done, future in enumerate(concurrent.futures.as_completed(futures), 1):
            converted[futures[future]] = future.result()
            if done % 20 == 0 or done == len(futures):
                print(f"  converted {done}/{len(futures)} files", flush=True)

    audio = pathlib.Path(out) / "files" / "audio"
    audio.mkdir(parents=True, exist_ok=True)
    size = 0
    for index, (archive, original) in enumerate(zip(ARCHIVES, gc)):
        files = [(e.name, converted.get(e.name, original.blob(e))) for e in original.entries]
        added = sorted(n for n in converted if song_of(n) in new_songs and ps2[n][0] == index)
        files += [(name, converted[name]) for name in added]
        data = viv.build_archive(original.magic, original.marker, original.alignment, files)
        (audio / pathlib.PurePosixPath(archive).name).write_bytes(data)
        size += len(data)
        print(f"  {archive}: {len({song_of(n) for n in added})} songs added")

    lines = ["# Lets the jukebox list the songs the GameCube release left out (written by ps2_music.py).",
             "# <address> <new bytes> <bytes expected there>"]
    for address, song in SKIPPED_SONGS.items():
        if song in new_songs:
            name = song.encode()
            lines.append(f"{address:08X} {(b'\0' + name[1:]).hex().upper()} {name.hex().upper()}  # {song}")
    (pathlib.Path(out) / "patches.txt").write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"{len(gc_songs | ps2_songs)} songs, {size / 2**20:.0f} MiB, in {out} ({time.monotonic() - started:.0f} s)")


if __name__ == "__main__":
    main()
