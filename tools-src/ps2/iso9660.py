"""Read-only access to the files of an ISO9660 disc image (such as a PlayStation 2 game disc).

    disc = Iso9660("game.iso")
    names = disc.paths()               # "/ASSETS/V2BG.VIV", ... (as stored, without ";1")
    data = disc.read("/ASSETS/V2BG.VIV")

Only the primary volume descriptor is read; files are looked up case-insensitively.
"""

from __future__ import annotations

import struct

SECTOR = 2048


class Iso9660:
    def __init__(self, path: str):
        self._file = open(path, "rb")
        descriptor = self._read(16, SECTOR)
        if descriptor[1:6] != b"CD001":
            raise ValueError(f"{path}: not an ISO9660 image")
        root = descriptor[156:156 + 34]
        self._files: dict[str, tuple[str, int, int]] = {}  # upper-case path -> (path, sector, size)
        self._walk(struct.unpack_from("<I", root, 2)[0], struct.unpack_from("<I", root, 10)[0], "")

    def __enter__(self) -> "Iso9660":
        return self

    def __exit__(self, *_) -> None:
        self._file.close()

    def _read(self, sector: int, size: int) -> bytes:
        self._file.seek(sector * SECTOR)
        return self._file.read(size)

    def _walk(self, sector: int, size: int, prefix: str) -> None:
        records = self._read(sector, size)
        pos = 0
        while pos < len(records):
            length = records[pos]
            if length == 0:  # records never cross a sector boundary: skip to the next sector
                pos = (pos // SECTOR + 1) * SECTOR
                continue
            record = records[pos:pos + length]
            pos += length
            name = record[33:33 + record[32]]
            if name in (b"\x00", b"\x01"):  # "." and ".."
                continue
            path = prefix + "/" + name.decode("ascii", "replace").split(";")[0]
            extent, data_size = struct.unpack_from("<I", record, 2)[0], struct.unpack_from("<I", record, 10)[0]
            if record[25] & 2:
                self._walk(extent, data_size, path)
            else:
                self._files[path.upper()] = (path, extent, data_size)

    def paths(self) -> list[str]:
        return sorted(path for path, _, _ in self._files.values())

    def read(self, path: str) -> bytes:
        _, sector, size = self._files[path.upper()]
        return self._read(sector, size)
