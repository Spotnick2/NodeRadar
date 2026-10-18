"""Generate NodeRadar's own textures into Media/ (never hand-edit the outputs).

    python Tools/make_media.py

The sonar alert (docs/PLAN.md, "New nodes and the alert"): white shapes with
the shape in alpha, tinted in game (green for herbs, gold for ore) and drawn
additively, so they glow on any minimap skin with no square around them.

  SonarRing   a thin ring with a soft halo, scaled out from the node
  SonarGlow   a round soft glow that stays on the node a moment

Plain Python, no dependencies: 32-bit uncompressed TGA, top-left origin.
"""

import math
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "Media")
SIZE = 64


def write_tga(path, alpha):
    """White pixels, the shape in alpha (a SIZE x SIZE list of rows, 0..1)."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 0x28)
    body = bytearray()
    for row in alpha:
        for a in row:
            body += bytes((255, 255, 255, max(0, min(255, int(round(a * 255))))))
    with open(path, "wb") as fh:
        fh.write(header + bytes(body))


def field(fn):
    """fn(distance from the centre in pixels) -> alpha, sampled 4x4 per pixel."""
    c = SIZE / 2
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            total = 0.0
            for sy in range(4):
                for sx in range(4):
                    dx = x + (sx + 0.5) / 4 - c
                    dy = y + (sy + 0.5) / 4 - c
                    total += fn(math.hypot(dx, dy))
            row.append(total / 16)
        rows.append(row)
    return rows


def ring(d):
    radius, core = 27.0, 1.6
    edge = max(0.0, 1.0 - max(0.0, abs(d - radius) - core))            # the crisp line
    halo = 0.35 * math.exp(-((d - radius) / 3.5) ** 2)                 # its soft light
    return min(1.0, edge + halo) if d < SIZE / 2 else 0.0


def glow(d):
    return math.exp(-(d / 11.0) ** 2) if d < SIZE / 2 else 0.0


def main():
    os.makedirs(MEDIA, exist_ok=True)
    for name, fn in (("SonarRing", ring), ("SonarGlow", glow)):
        path = os.path.join(MEDIA, name + ".tga")
        write_tga(path, field(fn))
        print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
