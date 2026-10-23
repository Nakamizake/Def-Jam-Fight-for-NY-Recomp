"""Memory patches that let a saved Beatbox playlist take the songs the PS2 music mod adds.

The game (GNWE69) keeps the Beatbox playlist in one object: the song ids, sorted (the object
finds a song by binary search, 0x8028E62C), and a flags byte for each, in the same order:
(display position << 2) | state, state 0 = locked, 1 = unlocked. A counter holds the next
display position, and the Beatbox lists the unlocked songs by position. The Options save
stores the two arrays as they are but not their size, so a save made with the GameCube's 20
songs comes back with 20 ids and 12 empty entries (-1, sorted last) while the game counts 32:
the Beatbox then repeats songs and never shows the added ones.

The fix runs before every read of a song's state (the object's GetState method, 0x8028DFE4).
When ids are missing it lays the arrays out again in id order, each song keeping its flags,
and unlocks each missing song at the next display position, as the game's own Unlock() does
(0x8028E09C). The songs the player had keep their order and their check marks. GetState is
only reached through the object's vtable, which the port runs through its dispatcher, so the
patched code is the one that runs.

The added code lives in the two copies of the skip list (see ps2_music.py), which the mod
empties anyway: every name in them is overwritten, and the bytes left over are zero.
"""

from __future__ import annotations

import struct

GET_STATE = 0x8028DFE4  # Playlist::GetState(this, &song)
GET_STATE_ENTRY = 0x9421FFE8  # its first instruction, stwu r1,-24(r1)

# Playlist object fields the fix reads.
ITEMS, COUNT, FLAGS, COUNTER = 0x04, 0x08, 0x0C, 0x18
UNLOCKED = 1


# The few PowerPC encodings the code below needs.
def _d_form(opcode: int, rt: int, ra: int, imm: int) -> int:
    return opcode << 26 | rt << 21 | ra << 16 | (imm & 0xFFFF)


def _x_form(rt: int, ra: int, rb: int, xo: int) -> int:
    return 31 << 26 | rt << 21 | ra << 16 | rb << 11 | xo << 1


def lwz(rt: int, ra: int, d: int) -> int: return _d_form(32, rt, ra, d)
def stw(rs: int, ra: int, d: int) -> int: return _d_form(36, rs, ra, d)
def addi(rt: int, ra: int, imm: int) -> int: return _d_form(14, rt, ra, imm)
def li(rt: int, imm: int) -> int: return addi(rt, 0, imm)
def ori(ra: int, rs: int, imm: int) -> int: return _d_form(24, rs, ra, imm)
def cmpwi(ra: int, imm: int) -> int: return _d_form(11, 0, ra, imm)
def cmplw(ra: int, rb: int) -> int: return _x_form(0, ra, rb, 32)
def add(rt: int, ra: int, rb: int) -> int: return _x_form(rt, ra, rb, 266)
def subf(rt: int, ra: int, rb: int) -> int: return _x_form(rt, ra, rb, 40)  # rt = rb - ra
def lwzx(rt: int, ra: int, rb: int) -> int: return _x_form(rt, ra, rb, 23)
def lbzx(rt: int, ra: int, rb: int) -> int: return _x_form(rt, ra, rb, 87)
def stwx(rs: int, ra: int, rb: int) -> int: return _x_form(rs, ra, rb, 151)
def stbx(rs: int, ra: int, rb: int) -> int: return _x_form(rs, ra, rb, 215)
def slwi(ra: int, rs: int, n: int) -> int: return 21 << 26 | rs << 21 | ra << 16 | n << 11 | (31 - n) << 1


def b(here: int, target: int) -> int:
    offset = target - here
    assert -(1 << 25) <= offset < (1 << 25) and offset % 4 == 0
    return 18 << 26 | (offset & 0x03FFFFFC)


def _bc(bo: int, bi: int, here: int, target: int) -> int:
    offset = target - here
    assert -(1 << 15) <= offset < (1 << 15) and offset % 4 == 0
    return 16 << 26 | bo << 21 | bi << 16 | (offset & 0xFFFC)


def blt(here: int, target: int) -> int: return _bc(12, 0, here, target)
def bge(here: int, target: int) -> int: return _bc(4, 0, here, target)
def beq(here: int, target: int) -> int: return _bc(12, 2, here, target)
def bne(here: int, target: int) -> int: return _bc(4, 2, here, target)


def assemble(parts: list[tuple[int, list]]) -> list[bytes]:
    """Assembles (address, items) parts that share labels. Items are a label (str), an
    instruction word (int) or a branch (op, label or address)."""
    labels: dict[str, int] = {}
    for address, items in parts:
        for item in items:
            if isinstance(item, str):
                labels[item] = address
            else:
                address += 4
    code = []
    for address, items in parts:
        words = []
        for item in items:
            if isinstance(item, str):
                continue
            if isinstance(item, tuple):
                op, target = item
                item = op(address, labels[target] if isinstance(target, str) else target)
            words.append(item)
            address += 4
        code.append(struct.pack(f">{len(words)}I", *words))
    return code


# r3 = this and r4 = &song are GetState's arguments and stay as they are; r0, r5-r12 and cr0
# are free at a function's entry. r5 = ids, r6 = count, r12 = flags.
_FIND_GAP = [
    lwz(5, 3, ITEMS), lwz(6, 3, COUNT), cmpwi(6, 0), (beq, "done"),
    slwi(0, 6, 2), add(9, 5, 0), lwz(0, 9, -4), cmplw(0, 6), (blt, "done"),  # last id listed: none missing
    lwz(12, 3, FLAGS), li(7, 0),
    "count_listed",  # r7 = the listed songs: the ids below count, which sort first
    cmplw(7, 6), (bge, "counted"),
    slwi(0, 7, 2), lwzx(0, 5, 0), cmplw(0, 6), (bge, "counted"),
    addi(7, 7, 1), (b, "count_listed"),
    "counted",
    lwz(10, 3, COUNTER), lwz(11, 10, 0),
    subf(0, 7, 6), add(11, 11, 0), stw(11, 10, 0),  # the missing songs take the next positions
    addi(11, 11, -1),  # r11 = position for the highest missing id
    addi(7, 7, -1), addi(8, 6, -1),  # r7 = last listed entry, r8 = id to place (count - 1 down)
    (b, "place"),
]
_REBUILD = [
    "place",  # ids[r8] = r8, with the flags of the listed entry that has it or new ones
    cmpwi(7, 0), (blt, "new_song"),
    slwi(0, 7, 2), lwzx(0, 5, 0), cmplw(0, 8), (bne, "new_song"),
    lbzx(9, 12, 7), addi(7, 7, -1), (b, "store"),
    "new_song",
    slwi(9, 11, 2), ori(9, 9, UNLOCKED), addi(11, 11, -1),
    "store",
    stbx(9, 12, 8), slwi(0, 8, 2), stwx(8, 5, 0),
    addi(8, 8, -1), cmpwi(8, 0), (bge, "place"),
    "done",  # GetState's own first instruction, then the rest of it
    GET_STATE_ENTRY, (b, GET_STATE + 4),
]


def memory_patches(caves: tuple[bytes, bytes], cave_addresses: tuple[int, int]) -> list[tuple[int, bytes, bytes]]:
    """(address, new bytes, bytes expected there) for the hook and the two caves.

    `caves` holds the bytes the two caves hold in the game (the skip lists), at
    `cave_addresses`; the code is split over them.
    """
    first, second = cave_addresses
    code = assemble([(first, _FIND_GAP), (second, _REBUILD)])
    patches = [(GET_STATE, struct.pack(">I", b(GET_STATE, first)), struct.pack(">I", GET_STATE_ENTRY))]
    for address, original, words in zip(cave_addresses, caves, code):
        if len(words) > len(original):
            raise ValueError(f"the code for {address:08X} needs {len(words)} bytes, the cave has {len(original)}")
        patches.append((address, words.ljust(len(original), b"\0"), original))
    return patches
