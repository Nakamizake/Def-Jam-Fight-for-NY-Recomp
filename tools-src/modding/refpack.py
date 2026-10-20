"""EA RefPack (QFS) compression, as used for most entries of Def Jam: Fight for NY's .viv archives.

A RefPack stream is a small header (flags, magic 0xFB, the decompressed size) followed by
commands, each copying some literal bytes from the stream and then some bytes from earlier in
the output. `decompress` reads every variant of the header; `compress` writes the plain one
(3-byte size, or 4-byte past 16 MiB) with a greedy LZ77 search.

    data = refpack.decompress(blob)
    blob = refpack.compress(data)
"""

from __future__ import annotations

MAGIC = 0xFB
MAX_OFFSET = 131072  # longest back reference a command can express
MAX_LENGTH = 1028  # longest copy a command can express
MIN_LENGTH = 3


def is_compressed(blob: bytes) -> bool:
    """Whether the blob starts with a RefPack header."""
    return len(blob) >= 5 and blob[1] == MAGIC and (blob[0] & 0x3E) == 0x10


def decompressed_size(blob: bytes) -> int:
    flags = blob[0]
    width = 4 if flags & 0x80 else 3
    pos = 2 + (width if flags & 0x01 else 0)  # skip the optional compressed size
    return int.from_bytes(blob[pos:pos + width], "big")


def decompress(blob: bytes) -> bytes:
    if not is_compressed(blob):
        raise ValueError("not a RefPack stream")
    flags = blob[0]
    width = 4 if flags & 0x80 else 3
    pos = 2 + (width if flags & 0x01 else 0)
    size = int.from_bytes(blob[pos:pos + width], "big")
    pos += width
    out = bytearray()
    while pos < len(blob):
        b0 = blob[pos]
        if b0 < 0x80:  # 2-byte command
            b1 = blob[pos + 1]
            literal = b0 & 0x03
            length = ((b0 & 0x1C) >> 2) + 3
            offset = ((b0 & 0x60) << 3) + b1 + 1
            pos += 2
        elif b0 < 0xC0:  # 3-byte command
            b1, b2 = blob[pos + 1], blob[pos + 2]
            literal = b1 >> 6
            length = (b0 & 0x3F) + 4
            offset = ((b1 & 0x3F) << 8) + b2 + 1
            pos += 3
        elif b0 < 0xE0:  # 4-byte command
            b1, b2, b3 = blob[pos + 1], blob[pos + 2], blob[pos + 3]
            literal = b0 & 0x03
            length = ((b0 & 0x0C) << 6) + b3 + 5
            offset = ((b0 & 0x10) << 12) + (b1 << 8) + b2 + 1
            pos += 4
        elif b0 < 0xFC:  # literals only
            literal = ((b0 & 0x1F) << 2) + 4
            length = 0
            offset = 0
            pos += 1
        else:  # end of stream, with up to three last literals
            literal = b0 & 0x03
            out += blob[pos + 1:pos + 1 + literal]
            break
        out += blob[pos:pos + literal]
        pos += literal
        start = len(out) - offset
        if length and start < 0:
            raise ValueError("RefPack back reference before the start of the output")
        for i in range(length):  # byte by byte: a copy may overlap what it is writing
            out.append(out[start + i])
    if len(out) != size:
        raise ValueError(f"RefPack stream decoded to {len(out)} bytes, header says {size}")
    return bytes(out)


def _emit_literals(out: bytearray, data: bytes, start: int, end: int) -> int:
    """Writes literal-only commands for data[start:end] down to fewer than 4 bytes; returns
    where the remaining (0-3) literals start, for the next command to carry."""
    while end - start >= 4:
        run = min((end - start) & ~3, 112)
        out.append(0xE0 + (run >> 2) - 1)
        out += data[start:start + run]
        start += run
    return start


def _emit_match(out: bytearray, literals: bytes, length: int, offset: int) -> None:
    lit = len(literals)
    off = offset - 1
    if length <= 10 and offset <= 1024:
        out += bytes([((off >> 3) & 0x60) | ((length - 3) << 2) | lit, off & 0xFF])
    elif length <= 67 and offset <= 16384:
        out += bytes([0x80 | (length - 4), (lit << 6) | (off >> 8), off & 0xFF])
    else:
        n = length - 5
        out += bytes([0xC0 | ((off >> 12) & 0x10) | ((n >> 6) & 0x0C) | lit,
                      (off >> 8) & 0xFF, off & 0xFF, n & 0xFF])
    out += literals


def compress(data: bytes) -> bytes:
    size = len(data)
    if size >= 1 << 24:
        out = bytearray([0x90, MAGIC]) + size.to_bytes(4, "big")
    else:
        out = bytearray([0x10, MAGIC]) + size.to_bytes(3, "big")
    # Greedy LZ77 over a hash of the next three bytes, remembering a few recent positions each.
    chains: dict[bytes, list[int]] = {}
    pos = 0
    literal_start = 0
    while pos + MIN_LENGTH <= size:
        key = data[pos:pos + 3]
        best_length = best_offset = 0
        candidates = chains.get(key)
        if candidates:
            limit = min(MAX_LENGTH, size - pos)
            for candidate in reversed(candidates):
                offset = pos - candidate
                if offset > MAX_OFFSET:
                    break
                length = 3
                while length < limit and data[candidate + length] == data[pos + length]:
                    length += 1
                # A 4-byte command is needed past 16 KiB, so a short match there costs too much.
                if length > best_length and (length >= 5 or offset <= 16384) and (length >= 4 or offset <= 1024):
                    best_length, best_offset = length, offset
                    if length == limit:
                        break
        if best_length:
            literal_start = _emit_literals(out, data, literal_start, pos)
            _emit_match(out, data[literal_start:pos], best_length, best_offset)
            end = pos + best_length
            while pos < end:
                chains.setdefault(data[pos:pos + 3], []).append(pos)
                if len(chains[data[pos:pos + 3]]) > 16:
                    del chains[data[pos:pos + 3]][0]
                pos += 1
            literal_start = pos
        else:
            chain = chains.setdefault(key, [])
            chain.append(pos)
            if len(chain) > 16:
                del chain[0]
            pos += 1
    literal_start = _emit_literals(out, data, literal_start, size)
    out.append(0xFC | (size - literal_start))
    out += data[literal_start:size]
    return bytes(out)
