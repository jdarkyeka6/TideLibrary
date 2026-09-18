#!/usr/bin/env python3
from pathlib import Path
import math
import struct
import zlib

SIZE = 1024
OUT = Path("TideLibrary/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")

def chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

def pixel(x: int, y: int) -> tuple[int, int, int]:
    t = y / (SIZE - 1)
    r = int(7 + 7 * t)
    g = int(25 + 36 * t)
    b = int(48 + 70 * t)

    # Three overlapping photo cards.
    cards = [
        (220, 254, 676, 710, -0.08),
        (285, 220, 741, 676, 0.07),
        (250, 282, 706, 738, 0.0),
    ]

    for i, (x0, y0, x1, y1, rot) in enumerate(cards):
        cx = (x0 + x1) / 2
        cy = (y0 + y1) / 2
        dx = x - cx
        dy = y - cy
        c = math.cos(-rot)
        s = math.sin(-rot)
        rx = dx * c - dy * s + cx
        ry = dx * s + dy * c + cy

        if x0 <= rx <= x1 and y0 <= ry <= y1:
            border = 26
            if rx < x0 + border or rx > x1 - border or ry < y0 + border or ry > y1 - border:
                return (244, 248, 252)

            if i == 2:
                # Ocean horizon in the front card.
                if ry < 500:
                    return (72, 159, 210)
                if ry < 555:
                    return (230, 194, 109)
                return (18, 104, 152)
            return (25 + i * 8, 102 + i * 10, 151 + i * 12)

    # Small cloud badge.
    circles = [(676, 670, 74), (738, 650, 92), (806, 682, 64)]
    if any(math.hypot(x - cx, y - cy) <= radius for cx, cy, radius in circles):
        return (245, 249, 253)
    if 642 <= x <= 852 and 670 <= y <= 744:
        return (245, 249, 253)

    return (r, g, b)

raw = bytearray()
for y in range(SIZE):
    raw.append(0)
    for x in range(SIZE):
        raw.extend(pixel(x, y))

png = bytearray(b"\x89PNG\r\n\x1a\n")
png.extend(chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)))
png.extend(chunk(b"IDAT", zlib.compress(bytes(raw), level=9)))
png.extend(chunk(b"IEND", b""))

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_bytes(png)
print(f"Generated {OUT} ({len(png)} bytes)")
