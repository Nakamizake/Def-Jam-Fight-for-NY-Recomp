"""XXH64, the hash Dolphin names custom textures after (pure Python, standard library only).

    xxh64(b"")  == 0xEF46DB3751D8E999
"""

from __future__ import annotations

import struct

_MASK = (1 << 64) - 1
_P1 = 11400714785074694791
_P2 = 14029467366897019727
_P3 = 1609587929392839161
_P4 = 9650029242287828579
_P5 = 2870177450012600261


def _rotl(value: int, bits: int) -> int:
    return ((value << bits) | (value >> (64 - bits))) & _MASK


def _round(acc: int, lane: int) -> int:
    acc = (acc + lane * _P2) & _MASK
    return (_rotl(acc, 31) * _P1) & _MASK


def _merge(acc: int, value: int) -> int:
    acc ^= _round(0, value)
    return (acc * _P1 + _P4) & _MASK


def xxh64(data: bytes, seed: int = 0) -> int:
    length = len(data)
    pos = 0
    if length >= 32:
        v1, v2, v3, v4 = (seed + _P1 + _P2) & _MASK, (seed + _P2) & _MASK, seed, (seed - _P1) & _MASK
        stripes = length // 32
        lanes = struct.unpack_from(f"<{stripes * 4}Q", data)
        for i in range(0, stripes * 4, 4):
            v1 = _round(v1, lanes[i])
            v2 = _round(v2, lanes[i + 1])
            v3 = _round(v3, lanes[i + 2])
            v4 = _round(v4, lanes[i + 3])
        pos = stripes * 32
        acc = (_rotl(v1, 1) + _rotl(v2, 7) + _rotl(v3, 12) + _rotl(v4, 18)) & _MASK
        for v in (v1, v2, v3, v4):
            acc = _merge(acc, v)
    else:
        acc = (seed + _P5) & _MASK
    acc = (acc + length) & _MASK
    while pos + 8 <= length:
        acc ^= _round(0, struct.unpack_from("<Q", data, pos)[0])
        acc = (_rotl(acc, 27) * _P1 + _P4) & _MASK
        pos += 8
    if pos + 4 <= length:
        acc ^= (struct.unpack_from("<I", data, pos)[0] * _P1) & _MASK
        acc = (_rotl(acc, 23) * _P2 + _P3) & _MASK
        pos += 4
    while pos < length:
        acc ^= (data[pos] * _P5) & _MASK
        acc = (_rotl(acc, 11) * _P1) & _MASK
        pos += 1
    acc ^= acc >> 33
    acc = (acc * _P2) & _MASK
    acc ^= acc >> 29
    acc = (acc * _P3) & _MASK
    acc ^= acc >> 32
    return acc
