"""EA shape files (.gsh on GameCube, .ssh on PlayStation 2): the texture containers of
Def Jam: Fight for NY.

A shape file is a header ("SHPG" big-endian / "SHPS" little-endian, size, image count, platform
tag) and a directory of (4-character tag, offset) entries. Each entry is a chain of blocks: the
image itself first (type, 3-byte offset to the next block, width, height, ...), then its palette
and some metadata. Both releases use colour-indexed images with the same tags in the same order,
so an image is matched across them by file name and tag.

GameCube images are GX textures, stored exactly as the GPU reads them: C4 or C8 in 8x8 / 8x4
texel tiles with an RGB5A3 palette. PlayStation 2 images are linear 4- or 8-bit indices
(low nibble first) with a 32-bit RGBA palette whose alpha runs 0-128; 256-colour palettes are
stored in the GS's CSM1 order, where entries 8-15 and 16-23 of every 32 trade places.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

# Block types
GC_C4, GC_C8 = 0x18, 0x19
PS2_I4, PS2_I8 = 0x01, 0x02
PS2_PALETTE = 0x21
GC_PALETTES = (0x2A, 0x32, 0x33)

GX_FORMAT = {GC_C4: 8, GC_C8: 9}  # Dolphin's TextureFormat numbers (C4, C8)


@dataclass
class Image:
    tag: str
    kind: int
    width: int
    height: int
    pixels: bytes
    palette: bytes  # raw palette block payload, b"" if none

    @property
    def bits(self) -> int:
        return 4 if self.kind in (GC_C4, PS2_I4) else 8


def _blocks(shape: bytes, offset: int, byteorder: str):
    while True:
        size = int.from_bytes(shape[offset + 1:offset + 4], byteorder)
        end = offset + size if size else len(shape)
        yield shape[offset], shape[offset:offset + 16], shape[offset + 16:end]
        if not size:
            return
        offset += size


def read_shape(shape: bytes) -> list[Image]:
    """Every image of a decompressed shape file, either platform."""
    if shape[:4] not in (b"SHPG", b"SHPS"):
        raise ValueError(f"not a shape file (magic {shape[:4]!r})")
    big = shape[:4] == b"SHPG"
    byteorder, prefix = ("big", ">") if big else ("little", "<")
    palettes = GC_PALETTES if big else (PS2_PALETTE,)
    images = []
    for index in range(struct.unpack_from(prefix + "I", shape, 8)[0]):
        tag = shape[16 + index * 8:20 + index * 8].decode("latin-1")
        offset = struct.unpack_from(prefix + "I", shape, 20 + index * 8)[0]
        chain = list(_blocks(shape, offset, byteorder))
        kind, header, payload = chain[0]
        width, height = struct.unpack_from(prefix + "HH", header, 4)
        palette = next((block[2] for block in chain[1:] if block[0] in palettes), b"")
        images.append(Image(tag, kind, width, height, payload, palette))
    return images


# ------------------------------------------------------------------------------- GameCube

def gc_supported(image: Image) -> bool:
    return image.kind in GX_FORMAT and len(image.pixels) >= gc_size(image)


def _tile(image: Image) -> tuple[int, int]:
    return 8, (8 if image.bits == 4 else 4)


def _align(value: int, step: int) -> int:
    return (value + step - 1) // step * step


def gc_size(image: Image) -> int:
    """Bytes of texels, over whole tiles (what the GPU reads and Dolphin hashes)."""
    tile_w, tile_h = _tile(image)
    return _align(image.width, tile_w) * _align(image.height, tile_h) * image.bits // 8


def gc_index(image: Image, x: int, y: int) -> int:
    """Palette index of texel (x, y) of a tiled C4/C8 image."""
    tile_w, tile_h = _tile(image)
    tiles_per_row = _align(image.width, tile_w) // tile_w
    tile = (y // tile_h) * tiles_per_row + x // tile_w
    texel = tile * tile_w * tile_h + (y % tile_h) * tile_w + x % tile_w
    if image.bits == 8:
        return image.pixels[texel]
    byte = image.pixels[texel >> 1]
    return byte & 15 if texel & 1 else byte >> 4


def gc_rgba(image: Image, x: int, y: int) -> tuple[int, int, int, int]:
    index = gc_index(image, x, y)
    if index * 2 + 2 > len(image.palette):  # palettes may stop after the last colour used
        return 0, 0, 0, 0
    value = struct.unpack_from(">H", image.palette, index * 2)[0]
    if value & 0x8000:  # RGB5A3, opaque: 5 bits per channel
        return (*(((value >> s) & 31) * 255 // 31 for s in (10, 5, 0)), 255)
    # 3-bit alpha, 4 bits per channel
    return (*(((value >> s) & 15) * 17 for s in (8, 4, 0)), ((value >> 12) & 7) * 255 // 7)


# --------------------------------------------------------------------------- PlayStation 2

def ps2_supported(image: Image) -> bool:
    return (image.kind in (PS2_I4, PS2_I8) and len(image.palette) >= 4
            and len(image.pixels) >= image.width * image.height * image.bits // 8)


def ps2_palette(image: Image) -> list[tuple[int, int, int, int]]:
    """The palette in index order, alpha scaled to 0-255. Palettes may stop after the last colour
    used; the missing entries come out transparent black."""
    count = 16 if image.kind == PS2_I4 else 256
    colours = []
    for index in range(count):
        stored = index ^ 0x18 if count == 256 and (index & 0x18) in (0x08, 0x10) else index
        entry = image.palette[stored * 4:stored * 4 + 4]
        r, g, b, a = entry if len(entry) == 4 else (0, 0, 0, 0)
        colours.append((r, g, b, min(255, a * 2)))
    return colours


def ps2_index(image: Image, x: int, y: int) -> int:
    texel = y * image.width + x
    if image.bits == 8:
        return image.pixels[texel]
    byte = image.pixels[texel >> 1]
    return byte >> 4 if texel & 1 else byte & 15


def ps2_rows(image: Image) -> list[bytes]:
    """Index rows packed the way PNG wants them (high nibble first for 4-bit)."""
    stride = image.width * image.bits // 8
    data = image.pixels[:stride * image.height]
    if image.bits == 4:
        data = data.translate(_SWAP_NIBBLES)
    return [data[y * stride:(y + 1) * stride] for y in range(image.height)]


_SWAP_NIBBLES = bytes(((b & 15) << 4) | (b >> 4) for b in range(256))
