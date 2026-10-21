"""Builds an HD texture pack for the GameCube release from the PlayStation 2 release's textures.

Def Jam: Fight for NY ships the same textures on both consoles, but the PlayStation 2 disc keeps
most of them at twice the width and height: every character texture and about half of each
venue's. This tool pairs every GameCube image with its PlayStation 2 counterpart (same archive,
same shape file, same tag), and writes the larger one as a Dolphin custom texture named after the
GameCube image, so the game shows it in its place. Both discs are only read.

    python -I ps2_textures.py --gc-files extracted\\GNWE69\\files --ps2 DefJamPs2.iso \\
        --out userdata\\Load\\Mods\\PS2Textures

The result is a mod: switch it on in Esc > MODS. Images whose PlayStation 2 version is not
larger are left out (nothing to gain), as are pairs whose pictures do not agree when the larger
one is scaled down, so a mismatch can never put a wrong texture in the game.

Names follow Dolphin: tex1_<w>x<h>_<XXH64 of the GameCube texels>_$_<format>.png, the `$`
standing for any palette (the game builds some palettes at run time).
"""

from __future__ import annotations

import argparse
import concurrent.futures
import os
import pathlib
import sys
import time
from dataclasses import dataclass, field

# `python -I` leaves the script's own directory off sys.path; add it and the modding tools.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [_HERE, os.path.join(os.path.dirname(_HERE), "modding")]
import iso9660  # noqa: E402
import png  # noqa: E402
import refpack  # noqa: E402
import shapes  # noqa: E402
import viv  # noqa: E402
from xxh64 import xxh64  # noqa: E402

SAMPLES = 16  # per axis, for the picture check
MAX_DIFFERENCE = 24.0  # mean per-channel difference of the sampled texels allowed for a pair


@dataclass
class Report:
    archive: str
    written: dict[str, bytes] = field(default_factory=dict)  # Dolphin name -> PNG
    not_larger: int = 0
    unsupported: int = 0
    different: list[str] = field(default_factory=list)


class Ps2Disc:
    """The PlayStation 2 files, from the disc image or from a folder they were copied to."""

    def __init__(self, source: str):
        self._source = source
        self._iso = iso9660.Iso9660(source) if os.path.isfile(source) else None
        if self._iso:
            paths = self._iso.paths()
        else:
            root = pathlib.Path(source)
            paths = ["/" + p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()]
        self._paths = {p.upper(): p for p in paths}

    def find(self, relative: str) -> str | None:
        return self._paths.get("/" + relative.upper())

    def read(self, path: str) -> bytes:
        if self._iso:
            return self._iso.read(path)
        return (pathlib.Path(self._source) / path.lstrip("/")).read_bytes()


def shape_files(archive: viv.Archive, extension: str) -> dict[str, bytes]:
    """Decompressed shape files of an archive, by lower-case name without extension."""
    files = {}
    for entry in archive.entries:
        stem, ext = os.path.splitext(entry.name.lower())
        if ext == extension:
            blob = archive.blob(entry)
            files[stem] = refpack.decompress(blob) if refpack.is_compressed(blob) else blob
    return files


def pictures_agree(gc: shapes.Image, ps2: shapes.Image, ps2_colours) -> bool:
    """Whether both pictures look alike: the mean colour of each cell of a SAMPLES x SAMPLES grid
    is compared, over the cells that are mostly opaque in both (transparent texels may hold any
    colour). Cell means rather than single texels keep fine detail and dithering out of it."""
    scale = ps2.width // gc.width
    cells_x, cells_y = min(SAMPLES, gc.width), min(SAMPLES, gc.height)
    total = 0.0
    compared = 0
    for cy in range(cells_y):
        y0, y1 = cy * gc.height // cells_y, (cy + 1) * gc.height // cells_y
        for cx in range(cells_x):
            x0, x1 = cx * gc.width // cells_x, (cx + 1) * gc.width // cells_x
            want = _cell_mean([shapes.gc_rgba(gc, x, y) for y in range(y0, y1) for x in range(x0, x1)])
            got = _cell_mean([ps2_colours[shapes.ps2_index(ps2, x, y)]
                              for y in range(y0 * scale, y1 * scale) for x in range(x0 * scale, x1 * scale)])
            if want and got:
                total += sum(abs(a - b) for a, b in zip(want, got)) / 3
                compared += 1
    return compared == 0 or total / compared <= MAX_DIFFERENCE


def _cell_mean(colours) -> tuple[float, float, float] | None:
    """Mean RGB of the opaque texels, or None when most of the cell is transparent."""
    opaque = [c for c in colours if c[3] >= 128]
    if len(opaque) * 2 < len(colours):
        return None
    return tuple(sum(c[i] for c in opaque) / len(opaque) for i in range(3))


def pair_archive(gc_path: str, ps2_source: str, ps2_path: str, name: str) -> Report:
    report = Report(name)
    gc_shapes = shape_files(viv.read_archive(pathlib.Path(gc_path)), ".gsh")
    ps2_shapes = shape_files(viv.parse_archive(Ps2Disc(ps2_source).read(ps2_path), ps2_path), ".ssh")
    for stem, gc_shape in gc_shapes.items():
        if stem not in ps2_shapes:
            continue
        ps2_images = {image.tag: image for image in shapes.read_shape(ps2_shapes[stem])}
        for gc in shapes.read_shape(gc_shape):
            ps2 = ps2_images.get(gc.tag)
            if ps2 is None or not shapes.gc_supported(gc) or not shapes.ps2_supported(ps2):
                report.unsupported += 1
                continue
            if ps2.width <= gc.width or ps2.width % gc.width or ps2.height % gc.height \
                    or ps2.width // gc.width != ps2.height // gc.height:
                report.not_larger += 1
                continue
            colours = shapes.ps2_palette(ps2)
            if not pictures_agree(gc, ps2, colours):
                report.different.append(f"{stem}/{gc.tag}")
                continue
            texels = gc.pixels[:shapes.gc_size(gc)]
            dolphin_name = f"tex1_{gc.width}x{gc.height}_{xxh64(texels):016x}_$_{shapes.GX_FORMAT[gc.kind]}"
            if dolphin_name not in report.written:
                report.written[dolphin_name] = png.indexed_png(
                    ps2.width, ps2.height, ps2.bits, shapes.ps2_rows(ps2), colours)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--gc-files", required=True, help="the GameCube game's files folder (extracted disc)")
    parser.add_argument("--ps2", required=True, help="the PlayStation 2 disc image (.iso) or a copy of its files")
    parser.add_argument("--out", required=True, help="mod folder to write (its textures/ folder is replaced)")
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    args = parser.parse_args()

    try:
        build(args)
    except (OSError, ValueError) as error:
        sys.exit(f"ps2_textures: {error}")


def build(args: argparse.Namespace) -> None:
    started = time.monotonic()
    gc_root = pathlib.Path(args.gc_files)
    disc = Ps2Disc(args.ps2)
    pairs = []
    for gc_path in sorted(gc_root.rglob("*.viv")):
        relative = gc_path.relative_to(gc_root).as_posix()
        ps2_path = disc.find(relative)
        if ps2_path:
            pairs.append((str(gc_path), args.ps2, ps2_path, relative))
    print(f"{len(pairs)} archives on both discs")
    if not pairs:
        raise ValueError(f"{args.ps2} does not look like Def Jam: Fight for NY for PlayStation 2 "
                         f"(none of the game's archives are on it)")

    textures = pathlib.Path(args.out) / "textures"
    if textures.exists():
        for old in textures.rglob("*.png"):
            old.unlink()
    written: set[str] = set()
    different: list[str] = []
    totals = {"not larger": 0, "unsupported": 0}
    size = 0
    with concurrent.futures.ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for report in pool.map(pair_archive, *zip(*pairs)):
            folder = textures / pathlib.PurePosixPath(report.archive).with_suffix("")
            new = {n: data for n, data in report.written.items() if n not in written}
            if new:
                folder.mkdir(parents=True, exist_ok=True)
            for dolphin_name, data in new.items():
                (folder / f"{dolphin_name}.png").write_bytes(data)
                size += len(data)
            written.update(new)
            totals["not larger"] += report.not_larger
            totals["unsupported"] += report.unsupported
            different += [f"{report.archive}:{item}" for item in report.different]
            print(f"  {report.archive}: {len(new)} textures")
    print(f"{len(written)} textures, {size / 2**20:.0f} MiB, in {textures} ({time.monotonic() - started:.0f} s)")
    print(f"left out: {totals['not larger']} not larger on PS2, {totals['unsupported']} other formats, "
          f"{len(different)} pictures that differ")
    for item in different[:20]:
        print(f"  differs: {item}")
    if not written:
        raise ValueError("no textures were written")


if __name__ == "__main__":
    main()
