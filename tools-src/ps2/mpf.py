"""EA interactive-music scripts (tune.mpf, "PFDx" version 4), from PS2 to GameCube byte order.

The layout is the one the GameCube loader walks (0x801D7774 in the GameCube executable):

    0x00  header: "PFDx", version 4, ..., 0x0d tracks, 0x0f events, 0x10 routers,
          0x12 u16 node count
    0x20  u16 table: each node's offset / 4
          nodes: 16-byte header + n 4-byte links (n: node word 1, bits 15-19)
          u16 table: each event's offset / 4
          events: 16-byte header + n 16-byte entries (n: event word 3, bits 10-15)
          32-bit words: router and variable tables, the track table and, per track, (stream
          offset / 0x80, length) pairs -- the stream offsets point into main.mus

Every word is the same fields on both consoles, but the GameCube compiler packs a word's fields
from the most significant bit and the PS2 one from the least, which also covers plain 16- and
8-bit fields. FIELDS gives each kind of word's field widths, MSB first. They were worked out by
lining up the 20 songs both discs have: converting each PS2 file with widths learned from the
other 19 gives the GameCube file byte for byte, apart from the stream offsets (the PS2 streams
are at a higher sample rate, so the PS2 offsets are the ones to keep).
"""

from __future__ import annotations

import struct

FIELDS = {
    "header": [32], "header04": [8, 8, 8, 8], "header0c": [8, 8, 8, 8], "header10": [16, 16],
    "u16pair": [16, 16],
    "node0": [16, 5, 6, 1, 4], "node1": [12, 5, 3, 4, 4, 4], "node2": [4, 4, 2, 10, 12],
    "node3": [1, 1, 12, 18],
    "link": [8, 8, 16],
    "event0": [32], "event1": [32], "event2": [32], "event3": [8, 22, 2],
    "entry0": [32], "entry1": [32], "entry2": [24, 8],
    # An event entry's last word depends on its opcode (entry word 2, bits 8-15).
    "entry3/02": [32], "entry3/04": [16, 8, 1, 7], "entry3/06": [8, 7, 1, 16],
    "entry3/08": [8, 24], "entry3/09": [8, 24], "entry3/0a": [16, 8, 8],
    "entry3/0b": [8, 7, 1, 16], "entry3/10": [8, 7, 1, 16],
    "u32": [32],
}


def _gc_bits(word: int, lsb: int, width: int) -> int:
    """Bits [lsb, lsb+width) of a GameCube word, read from a PS2 word."""
    return (word >> (32 - lsb - width)) & ((1 << width) - 1)


def word_kinds(data: bytes) -> dict[int, str]:
    """The kind (a FIELDS key) of every word of a PS2 tune.mpf, by offset."""
    word = lambda pos: struct.unpack_from("<I", data, pos)[0]
    u16 = lambda pos: struct.unpack_from("<H", data, pos)[0]
    s16 = lambda pos: struct.unpack_from("<h", data, pos)[0]
    if data[:4] != b"xDFP" or data[4] != 4:
        raise ValueError("not a PS2 version 4 tune.mpf")
    kinds = {pos: "header" for pos in range(0, 0x20, 4)}
    kinds.update({0x04: "header04", 0x0c: "header0c", 0x10: "header10"})
    nodes, events = u16(0x12), data[0x0f]

    def table(start: int, count: int) -> int:
        for pos in range(start, start + 2 * count, 4):
            kinds[pos] = "u16pair"
        return (start + 2 * count + 3) & ~3

    end = table(0x20, nodes)
    for k in range(nodes):
        node = s16(0x20 + 2 * k) * 4
        links = _gc_bits(word(node + 4), 15, 5)
        for j in range(4):
            kinds[node + 4 * j] = f"node{j}"
        for j in range(links):
            kinds[node + 16 + 4 * j] = "link"
        end = max(end, node + 16 + 4 * links)
    events_table = (end + 3) & ~3
    end = table(events_table, events)
    for k in range(events):
        event = s16(events_table + 2 * k) * 4
        entries = _gc_bits(word(event + 12), 10, 6)
        for j in range(4):
            kinds[event + 4 * j] = f"event{j}"
        for i in range(entries):
            entry = event + 16 + 16 * i
            for j in range(3):
                kinds[entry + 4 * j] = f"entry{j}"
            kinds[entry + 12] = f"entry3/{(word(entry + 8) >> 8) & 0xff:02x}"
        end = max(end, event + 16 + 16 * entries)
    for pos in range((end + 3) & ~3, len(data), 4):
        kinds.setdefault(pos, "u32")
    missing = [pos for pos in range(0, len(data) & ~3, 4) if pos not in kinds]
    if missing or len(data) % 4:
        raise ValueError(f"tune.mpf layout does not cover offset {missing[0] if missing else len(data):#x}")
    return kinds


def to_gamecube(data: bytes) -> bytes:
    """A PS2 tune.mpf in GameCube form (for that song's PS2 main.mus)."""
    kinds = word_kinds(data)
    out = bytearray(len(data))
    for pos, kind in kinds.items():
        widths = FIELDS.get(kind)
        if widths is None:
            raise ValueError(f"tune.mpf word at {pos:#x} is of an unknown kind {kind}")
        word = struct.unpack_from("<I", data, pos)[0]
        if kind == "node3" and word & 2:
            # The GameCube files set this flag wherever the PS2 ones set the next one.
            word |= 1
        value, lsb = 0, 0
        for width in widths:
            value = (value << width) | ((word >> lsb) & ((1 << width) - 1))
            lsb += width
        struct.pack_into(">I", out, pos, value)
    return bytes(out)
