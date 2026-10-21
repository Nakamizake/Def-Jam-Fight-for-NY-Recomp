"""Lists, extracts and rebuilds the .viv archives of Def Jam: Fight for NY (EA BIG format).

A .viv is an EA BIG archive: "BIGF" or "BIG4", the archive size (little-endian), the entry
count and header size (big-endian), one (offset, size, name) entry per file, an 8-byte "L2xx"
marker, then the files, each aligned. Most entries are RefPack-compressed (see refpack.py).

extract writes every file decompressed, plus `_viv.json`, which records the archive's layout
and each file's hash. pack rebuilds an archive from such a folder: a file whose contents are
unchanged keeps its original bytes (no recompression), a changed one is compressed again if it
was compressed before, and files not in the original are added at the end, stored as they are.

    python -I viv.py list   files/assets/icrowd.viv
    python -I viv.py extract files/assets/icrowd.viv work/icrowd
    python -I viv.py pack   work/icrowd mods/MyMod/files/assets/icrowd.viv

Put the rebuilt archive in a mod (Load/Mods/<name>/files/<same path>), never over the game's own.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import struct
import sys
from dataclasses import dataclass

# `python -I` leaves the script's own directory off sys.path; add it back for the sibling module.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refpack  # noqa: E402

MANIFEST = "_viv.json"
MAGICS = (b"BIGF", b"BIG4")


@dataclass
class Entry:
    name: str
    offset: int
    size: int


@dataclass
class Archive:
    magic: bytes
    marker: bytes  # the 8 bytes after the entry table ("L231" + 4 bytes)
    alignment: int
    entries: list[Entry]
    data: bytes

    def blob(self, entry: Entry) -> bytes:
        return self.data[entry.offset:entry.offset + entry.size]


def read_archive(path: pathlib.Path) -> Archive:
    return parse_archive(path.read_bytes(), str(path))


def parse_archive(data: bytes, path: str = "archive") -> Archive:
    """An archive already in memory (`path` only names it in errors)."""
    magic = data[:4]
    if magic not in MAGICS:
        raise ValueError(f"{path}: not a BIG archive (magic {magic!r})")
    count, header_size = struct.unpack_from(">II", data, 8)
    pos = 16
    entries = []
    for _ in range(count):
        offset, size = struct.unpack_from(">II", data, pos)
        end = data.index(b"\0", pos + 8)
        entries.append(Entry(data[pos + 8:end].decode("latin-1"), offset, size))
        pos = end + 1
    marker = data[pos:pos + 8]
    if header_size != pos + 8:
        raise ValueError(f"{path}: header size {header_size}, entry table ends at {pos + 8}")
    # The largest power of two (up to 2048) every file starts on.
    alignment = 2048
    for entry in entries:
        while entry.offset % alignment:
            alignment //= 2
    return Archive(magic, marker, alignment, entries, data)


def align(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def build_archive(magic: bytes, marker: bytes, alignment: int, files: list[tuple[str, bytes]]) -> bytes:
    names = [name.encode("latin-1") for name, _ in files]
    header_size = 16 + sum(8 + len(name) + 1 for name in names) + len(marker)
    offsets = []
    pos = align(header_size, alignment)
    for _, blob in files:
        offsets.append(pos)
        pos = align(pos + len(blob), alignment)
    total = offsets[-1] + len(files[-1][1]) if files else header_size
    out = bytearray(total)
    out[0:4] = magic
    struct.pack_into("<I", out, 4, total)
    struct.pack_into(">II", out, 8, len(files), header_size)
    pos = 16
    for name, offset, (_, blob) in zip(names, offsets, files):
        struct.pack_into(">II", out, pos, offset, len(blob))
        out[pos + 8:pos + 8 + len(name)] = name
        pos += 8 + len(name) + 1
    out[pos:pos + len(marker)] = marker
    for offset, (_, blob) in zip(offsets, files):
        out[offset:offset + len(blob)] = blob
    return bytes(out)


def safe_path(root: pathlib.Path, name: str) -> pathlib.Path:
    """Where an entry goes when extracted; refuses names that would leave the folder."""
    target = (root / name.replace("\\", "/")).resolve()
    if root.resolve() not in target.parents:
        raise ValueError(f"entry name escapes the output folder: {name!r}")
    return target


def cmd_list(args: argparse.Namespace) -> None:
    archive = read_archive(pathlib.Path(args.archive))
    print(f"{archive.magic.decode()}  {len(archive.entries)} files  marker {archive.marker!r}  "
          f"alignment {archive.alignment}")
    for entry in archive.entries:
        blob = archive.blob(entry)
        packed = refpack.is_compressed(blob)
        unpacked = refpack.decompressed_size(blob) if packed else entry.size
        print(f"{entry.size:10}  {unpacked:10}  {'refpack' if packed else '       '}  {entry.name}")


def cmd_extract(args: argparse.Namespace) -> None:
    source = pathlib.Path(args.archive)
    archive = read_archive(source)
    out = pathlib.Path(args.folder)
    out.mkdir(parents=True, exist_ok=True)
    records = []
    for entry in archive.entries:
        blob = archive.blob(entry)
        packed = refpack.is_compressed(blob) and not args.raw
        contents = refpack.decompress(blob) if packed else blob
        target = safe_path(out, entry.name)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
        records.append({"name": entry.name, "compressed": packed,
                        "sha1": hashlib.sha1(contents).hexdigest()})
    manifest = {"source": str(source.resolve()), "magic": archive.magic.decode(),
                "marker": archive.marker.hex(), "alignment": archive.alignment, "files": records}
    (out / MANIFEST).write_text(json.dumps(manifest, indent=1), encoding="utf-8")
    print(f"extracted {len(records)} files to {out}")


def cmd_pack(args: argparse.Namespace) -> None:
    folder = pathlib.Path(args.folder)
    # utf-8-sig: editors on Windows (Notepad, PowerShell) may add a byte-order mark.
    manifest = json.loads((folder / MANIFEST).read_text(encoding="utf-8-sig"))
    original = read_archive(pathlib.Path(args.original or manifest["source"]))
    originals = {entry.name: original.blob(entry) for entry in original.entries}
    files: list[tuple[str, bytes]] = []
    known = set()
    changed = 0
    for record in manifest["files"]:
        name = record["name"]
        known.add(name)
        contents = safe_path(folder, name).read_bytes()
        if hashlib.sha1(contents).hexdigest() == record["sha1"] and name in originals:
            files.append((name, originals[name]))
            continue
        changed += 1
        files.append((name, refpack.compress(contents) if record["compressed"] else contents))
    added = 0
    for path in sorted(p for p in folder.rglob("*") if p.is_file() and p.name != MANIFEST):
        name = path.relative_to(folder).as_posix()
        if name not in known:
            files.append((name, path.read_bytes()))
            added += 1
    data = build_archive(manifest["magic"].encode(), bytes.fromhex(manifest["marker"]),
                         manifest["alignment"], files)
    target = pathlib.Path(args.archive)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    print(f"wrote {target}: {len(files)} files ({changed} changed, {added} added), {len(data)} bytes")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("list", help="list the files in an archive")
    p.add_argument("archive")
    p.set_defaults(run=cmd_list)
    p = commands.add_parser("extract", help="extract an archive to a folder, decompressed")
    p.add_argument("archive")
    p.add_argument("folder")
    p.add_argument("--raw", action="store_true", help="keep RefPack entries compressed")
    p.set_defaults(run=cmd_extract)
    p = commands.add_parser("pack", help="rebuild an archive from an extracted folder")
    p.add_argument("folder")
    p.add_argument("archive", help="the archive to write")
    p.add_argument("--original", help="the archive it was extracted from, if it has moved")
    p.set_defaults(run=cmd_pack)
    args = parser.parse_args()
    try:
        args.run(args)
    except (OSError, ValueError) as error:
        sys.exit(f"viv: {error}")


if __name__ == "__main__":
    main()
