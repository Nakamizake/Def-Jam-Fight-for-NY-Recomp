"""The PlayStation 2 disc's files, read from the disc image or from a folder they were copied to."""

from __future__ import annotations

import os
import pathlib

import iso9660


class Ps2Disc:
    """`find` gives a file's path on the disc (any case), `read` its contents."""

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
