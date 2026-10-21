"""EA audio files of Def Jam: Fight for NY, from the PlayStation 2 byte order to the GameCube one.

Both releases store their music as EA-XA ADPCM: 15-byte frames of 28 samples, one stream of
frames per channel. The frames are the same bytes on both consoles; what differs is around them.

- Streams (main.mus): one or more SCHl streams, each a run of blocks (an 8-byte tag + size,
  the size always little-endian). SCHl holds a PT header (tagged values, platform byte 5 on
  PS2, 6 on GameCube); SCCl the block count; SCDl a block's sample count, one offset per
  channel, and per channel two 16-bit history samples before its frames. Those numbers are in
  each console's byte order.
- Sound banks (loading0.mus, overlay0.mus): "BNKl"/"BNKb", a header and a table of offsets to
  one PT header per sound, then the sounds' frames, channel after channel (PT tags 0x88, 0x89:
  where each channel starts). The GameCube keeps these banks in a fixed-size buffer sized for
  its own files, which are at two thirds of the PS2 sample rate, so a PS2 bank has to be
  resampled to the GameCube rate (24000 -> 16000 Hz) and encoded again to fit.

The PS2 PT headers also carry tag 0x80 (version 2: EA-XA with optional raw PCM frames). None
of these files has a raw frame, and the GameCube files never carry the tag, so it is dropped.
"""

from __future__ import annotations

import math
import struct

COEF1 = (0, 240, 460, 392)
COEF2 = (0, 0, -208, -220)
FRAME_BYTES = 15
FRAME_SAMPLES = 28
PLATFORM_GAMECUBE = 6


# ----------------------------------------------------------------------------- PT headers

def _pt_tags(buf, pos: int) -> list[tuple[int, int, int]]:
    """(tag, value position, value length) for each value of the PT header at pos."""
    if buf[pos:pos + 2] != b"PT":
        raise ValueError(f"no PT header at {pos:#x}")
    tags = []
    j = pos + 4
    while j < len(buf):
        tag = buf[j]
        if tag in (0xFC, 0xFD, 0xFE):
            j += 1
            continue
        if tag == 0xFF:
            return tags
        size = buf[j + 1]
        tags.append((tag, j + 2, size))
        j += 2 + size
    raise ValueError(f"PT header at {pos:#x} has no end")


def pt_values(buf, pos: int) -> dict[int, int]:
    return {tag: int.from_bytes(buf[at:at + size], "big") for tag, at, size in _pt_tags(buf, pos)}


def _set_pt_value(buf: bytearray, pos: int, tag: int, value: int) -> None:
    for t, at, size in _pt_tags(buf, pos):
        if t == tag:
            buf[at:at + size] = value.to_bytes(size, "big")
            return
    raise ValueError(f"PT header at {pos:#x} has no tag {tag:#x}")


def _pt_to_gamecube(buf: bytearray, pos: int, end: int) -> None:
    """Platform byte to GameCube and tag 0x80 dropped, the header's end padded with zeros so
    nothing after it moves (`end`: where the space for the header ends)."""
    buf[pos + 2] = PLATFORM_GAMECUBE
    for tag, at, size in _pt_tags(buf, pos):
        if tag == 0x80:
            del buf[at - 2:at + size]
            buf[end - 2 - size:end - 2 - size] = bytes(2 + size)
            return


def _swap(buf: bytearray, pos: int, size: int) -> None:
    buf[pos:pos + size] = buf[pos:pos + size][::-1]


# ----------------------------------------------------------------------------- streams

def stream_to_gamecube(data: bytes) -> bytes:
    """A PS2 main.mus (SCHl streams) in GameCube byte order; the audio frames are untouched."""
    buf = bytearray(data)
    pos = 0
    channels = 1
    while pos + 8 <= len(buf):
        tag = bytes(buf[pos:pos + 4])
        if tag == b"\0\0\0\0":  # padding between streams
            pos += 4
            continue
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        if size < 8:
            raise ValueError(f"block {tag!r} at {pos:#x} has size {size}")
        if tag == b"SCHl":
            _pt_to_gamecube(buf, pos + 8, pos + size)
            channels = pt_values(buf, pos + 8).get(0x82, 1)
        elif tag == b"SCCl":
            _swap(buf, pos + 8, 4)
        elif tag == b"SCDl":
            _swap(buf, pos + 8, 4)
            first = pos + 12 + 4 * channels
            for c in range(channels):
                _swap(buf, pos + 12 + 4 * c, 4)
                start = first + struct.unpack_from(">I", buf, pos + 12 + 4 * c)[0]
                _swap(buf, start, 2)
                _swap(buf, start + 2, 2)
        elif tag != b"SCEl":
            raise ValueError(f"unknown block {tag!r} at {pos:#x}")
        pos += size
    return bytes(buf)


# ----------------------------------------------------------------------------- banks

def _bank_sounds(buf, endian: str) -> list[int]:
    """Where each sound's PT header starts."""
    count = struct.unpack_from(endian + "H", buf, 6)[0]
    starts = []
    for k in range(count):
        rel = struct.unpack_from(endian + "I", buf, 0x14 + 4 * k)[0]
        if rel:
            starts.append(0x14 + 4 * k + rel)
    return starts


def bank_to_gamecube(data: bytes, rate_divisor: int = 1) -> bytes:
    """A PS2 sound bank (BNKl) as a GameCube one (BNKb). With rate_divisor 1 the frames are
    kept; otherwise each sound is decoded, resampled to 2/3 of its rate and encoded again
    (only 2/3 is supported: the PS2 rates are all 1.5 times the GameCube ones)."""
    if data[:4] != b"BNKl":
        raise ValueError("not a PS2 sound bank")
    buf = bytearray(data)
    starts = _bank_sounds(buf, "<")
    buf[3:4] = b"b"
    _swap(buf, 6, 2)
    for pos in (8, 12, 16):
        _swap(buf, pos, 4)
    for k in range(struct.unpack_from(">H", buf, 6)[0]):
        _swap(buf, 0x14 + 4 * k, 4)
    data_start = min(pt_values(buf, s)[0x88] for s in starts)
    for i, start in enumerate(starts):
        _pt_to_gamecube(buf, start, starts[i + 1] if i + 1 < len(starts) else data_start)
    if rate_divisor == 1:
        return bytes(buf)
    if rate_divisor != 3:
        raise ValueError("only a 2/3 resample is supported")
    return _rebuild_bank(buf, starts, data_start)


def _rebuild_bank(buf: bytearray, starts: list[int], data_start: int) -> bytes:
    """Re-encodes every sound at 2/3 of its rate, laid out as the GameCube banks are: each
    sound's first channel 4 bytes past a 32-byte boundary, channels 4 bytes apart."""
    head = buf[:data_start]
    body = bytearray()
    for start in starts:
        tags = pt_values(buf, start)
        channels = tags.get(0x82, 1)
        count = tags[0x85]
        frames = (count + FRAME_SAMPLES - 1) // FRAME_SAMPLES
        new = None
        for c in range(channels):
            pcm = decode(buf, tags[0x88 + c], frames)[:count]
            pcm = resample_two_thirds(pcm)
            new = len(pcm)
            if c == 0:
                pos = data_start + len(body)
                pad = (-(pos - 4)) % 32
                body += bytes(pad)
            _set_pt_value(head, start, 0x88 + c, data_start + len(body))
            body += encode(pcm) + bytes(4)
        _set_pt_value(head, start, 0x85, new)
        _set_pt_value(head, start, 0x84, tags[0x84] * 2 // 3)
    out = head + body
    struct.pack_into(">I", out, 8, len(out))
    return bytes(out)


# ----------------------------------------------------------------------------- EA-XA

def decode(data, pos: int, frames: int, h1: int = 0, h2: int = 0) -> list[int]:
    out = []
    for _ in range(frames):
        info = data[pos]
        if info >> 4 > 3:
            raise ValueError(f"not an EA-XA frame at {pos:#x}")
        c1, c2, shift = COEF1[info >> 4], COEF2[info >> 4], (info & 15) + 8
        for i in range(FRAME_SAMPLES):
            nib = (data[pos + 1 + i // 2] >> (0 if i & 1 else 4)) & 15
            s = ((nib - 16 if nib & 8 else nib) << 28 >> shift) + c1 * h1 + c2 * h2 >> 8
            s = -32768 if s < -32768 else 32767 if s > 32767 else s
            out.append(s)
            h2, h1 = h1, s
        pos += FRAME_BYTES
    return out


def encode(pcm: list[int]) -> bytes:
    """EA-XA frames for 16-bit samples (silence-padded to whole frames), choosing for each
    frame the predictor and shift with the smallest error, decoded exactly as the console does."""
    pcm = list(pcm) + [0] * (-len(pcm) % FRAME_SAMPLES)
    out = bytearray()
    h1 = h2 = 0
    for f in range(0, len(pcm), FRAME_SAMPLES):
        block = pcm[f:f + FRAME_SAMPLES]
        best = None
        for c in range(4):
            c1, c2 = COEF1[c], COEF2[c]
            # The largest prediction residual (open loop) gives the shift to start from.
            p1, p2, peak = h1, h2, 0
            for s in block:
                peak = max(peak, abs(s * 256 - c1 * p1 - c2 * p2))
                p2, p1 = p1, s
            r = 12 - max(0, math.ceil(math.log2(peak / 256 / 7 + 1e-9))) if peak else 12
            for shift in {max(0, min(12, r)), max(0, min(12, r - 1))}:
                trial = _encode_frame(block, c, shift, h1, h2)
                if best is None or trial[0] < best[0]:
                    best = trial
        _, frame, h1, h2 = best
        out += frame
    return bytes(out)


def _encode_frame(block, c, shift, h1, h2):
    c1, c2 = COEF1[c], COEF2[c]
    step = 1 << (20 - shift)
    nibbles = []
    err = 0
    for s in block:
        pred = c1 * h1 + c2 * h2
        nib = round((s * 256 - pred) / step)
        nib = -8 if nib < -8 else 7 if nib > 7 else nib
        out = (nib * step + pred) >> 8
        out = -32768 if out < -32768 else 32767 if out > 32767 else out
        err += (out - s) * (out - s)
        nibbles.append(nib & 15)
        h2, h1 = h1, out
    frame = bytes([c << 4 | shift]) + bytes(nibbles[i] << 4 | nibbles[i + 1] for i in range(0, 28, 2))
    return err, frame, h1, h2


# ----------------------------------------------------------------------------- resampling

def _kernel(phase: float, half: int = 24, cutoff: float = 0.29) -> list[float]:
    """Windowed-sinc taps at input positions phase-half+1 .. phase+half (cutoff in cycles per
    input sample: 0.29 of 24 kHz keeps up to 7 kHz, under the 8 kHz Nyquist of 16 kHz)."""
    taps = []
    for k in range(-half + 1, half + 1):
        x = k - phase
        sinc = 2 * cutoff if x == 0 else math.sin(2 * math.pi * cutoff * x) / (math.pi * x)
        window = 0.42 + 0.5 * math.cos(math.pi * x / half) + 0.08 * math.cos(2 * math.pi * x / half)
        taps.append(sinc * window)
    return taps


_KERNELS = (_kernel(0.0), _kernel(0.5))


def resample_two_thirds(pcm: list[int]) -> list[int]:
    """Output sample n is the input at position 1.5 n."""
    padded = [0] * 24 + list(pcm) + [0] * 25
    out = []
    for n in range(len(pcm) * 2 // 3):
        base = (3 * n) // 2 + 1  # padded index of the first tap
        taps = _KERNELS[n & 1]
        acc = 0.0
        for i, t in enumerate(taps):
            acc += t * padded[base + i]
        v = int(round(acc))
        out.append(-32768 if v < -32768 else 32767 if v > 32767 else v)
    return out
