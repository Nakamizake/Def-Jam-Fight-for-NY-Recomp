"""Minimal writer for colour-indexed PNG files (standard library only).

The Python bundled with the installed game (llvm-mingw's) has no zlib module. Without it the
image data is stored in uncompressed deflate blocks: a valid PNG, just larger.
"""

from __future__ import annotations

import binascii
import itertools
import struct

try:
    import zlib
except ImportError:
    zlib = None


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data))


def _stored_zlib(data: bytes) -> bytes:
    """A zlib stream of `data` in stored (uncompressed) deflate blocks."""
    out = bytearray(b"\x78\x01")
    block = 65535
    for start in range(0, max(len(data), 1), block):
        piece = data[start:start + block]
        final = start + block >= len(data)
        out += struct.pack("<BHH", final, len(piece), len(piece) ^ 0xFFFF) + piece
    # Adler-32: s1 runs 1 + the bytes so far, s2 is the sum of every s1.
    s1 = (1 + sum(data)) % 65521
    s2 = (len(data) + sum(itertools.accumulate(data))) % 65521
    return bytes(out) + struct.pack(">I", (s2 << 16) | s1)


def _compress(data: bytes) -> bytes:
    return zlib.compress(data, 9) if zlib else _stored_zlib(data)


def indexed_png(width: int, height: int, bits: int, rows: list[bytes],
                palette: list[tuple[int, int, int, int]]) -> bytes:
    """A PNG of `rows` (already packed at `bits` per pixel) with an RGBA palette."""
    header = struct.pack(">IIBBBBB", width, height, bits, 3, 0, 0, 0)
    plte = b"".join(bytes(colour[:3]) for colour in palette)
    alpha = bytes(colour[3] for colour in palette).rstrip(b"\xff")
    raw = b"".join(b"\0" + row for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header) + _chunk(b"PLTE", plte)
            + (_chunk(b"tRNS", alpha) if alpha else b"") + _chunk(b"IDAT", _compress(raw))
            + _chunk(b"IEND", b""))
