"""Generate NodeRadar's own textures into Media/ (never hand-edit the outputs).

    python Tools/make_media.py

The sonar alert (docs/PLAN.md, "New nodes and the alert"): white shapes with
the shape in alpha, tinted in game (green for herbs, gold for ore) and drawn
additively, so they glow on any minimap skin with no square around them.

  SonarRing   a thin ring with a soft halo, scaled out from the node
  SonarGlow   a round soft glow that stays on the node a moment

The compass (#29, docs/PLAN.md, "The ring, refined"): layers drawn bottom to
top, all centred on the disc. Sizes are the files'; "display" is how big each
is drawn at the medium size (the disc 52 units across). Painted art can replace
any file at the same size and layout.

  CompassShadow  128 x 128, display 65 (1.25 x the disc), nudged down 2 units.
                 Black; alpha 0.5 inside radius 44 px (the disc), fading to 0
                 at the edge.
  CompassLens    128 x 128, display 52. A dark translucent disc to radius
                 58 px (inside the rim): RGB about 0.04, alpha 0.62 at the
                 centre to 0.75 near the edge; a faint white inner boundary
                 (alpha 0.22, 1.5 px) at 37 px, the icon's edge (0.58 x the disc).
  CompassRim     128 x 128, display 52. A ring from 56 to 63.5 px (about 1/16
                 of the diameter), greyscale: white along the top, dark grey
                 along the bottom, alpha 0.95 at the top to 0.7 at the bottom.
                 Tinted in game by vertex colour: pearl, or a muted bronze.
  CompassArc     128 x 128, display 52. A white highlight on the rim's band,
                 centred at 12 o'clock, 25 degrees wide with soft ends. Turned
                 with the arrow around the disc's centre.
  CompassArrow   64 x 64, display 16. A solid white triangle with a 3 px dark
                 outline inside its bounds, flat base down, apex up, no stem:
                 the apex at (32, 8), the base from (17, 52) to (47, 52) (30 px
                 wide, #50: 44 read sideways at a slant). So the
                 apex is 24 px above the centre (0.375 of the size) and the base
                 20 px below (0.3125). Never tinted.
  CompassPill    128 x 64, the capsule from (2, 12) to (126, 52) (124 x 40),
                 drawn cropped to it at 56 x 18. Fill RGB 0.04, alpha 0.68; a
                 2 px subdued grey outline (0.55, alpha 0.55).

The yellow frame (#50, docs/PLAN.md, "A yellow frame"):

  IconRing       64 x 64, display 1.3 x the minimap icon (15.6 at medium). A
                 white band from radius 24.5 to 31.5 px (its inner edge the
                 icon's), a 1.5 px dark edge on both sides inside those bounds.
                 Tinted in game the tracking dots' yellow (the white takes it,
                 the dark edges stay dark).

The marker in the world (#61, docs/PLAN.md, "A marker in the world"):

  MarkerStar     64 x 64, display 22 at scale 1. A four-pointed star: thin
                 rays along both axes tapering to the edge, a bright core and a
                 soft halo, white with the shape in alpha. Tinted teal in game
                 and drawn additively; its glow is SonarGlow, tinted too.

The sounds come from Tools/import_sounds.py.

Plain Python, no dependencies: 32-bit uncompressed TGA (RGB and 8-bit alpha),
top-left origin, power-of-two sides.
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


# ---------------------------------------------------------------------------
# The compass: colour and alpha, any power-of-two size
# ---------------------------------------------------------------------------

def write_rgba(path, w, h, fn):
    """fn(x, y) -> (r, g, b, a), 0..1, sampled 4x4 per pixel; the colour is
    averaged by alpha, so soft edges keep their colour (no dark fringe)."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    body = bytearray()
    for y in range(h):
        for x in range(w):
            r = g = b = a = 0.0
            for sy in range(4):
                for sx in range(4):
                    pr, pg, pb, pa = fn(x + (sx + 0.5) / 4, y + (sy + 0.5) / 4)
                    r, g, b, a = r + pr * pa, g + pg * pa, b + pb * pa, a + pa
            if a > 0:
                r, g, b = r / a, g / a, b / a
            a = a / 16

            def byte(v):
                return max(0, min(255, int(round(v * 255))))
            body += bytes((byte(b), byte(g), byte(r), byte(a)))           # TGA is BGRA
    with open(path, "wb") as fh:
        fh.write(header + bytes(body))


def smooth(e0, e1, v):
    t = max(0.0, min(1.0, (v - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def polar(x, y, c=64.0):
    """Distance from the centre, and how far toward the top: 1 at 12 o'clock, 0 at 6."""
    dx, dy = x - c, y - c
    d = math.hypot(dx, dy)
    top = 0.5 - 0.5 * (dy / d) if d > 0 else 0.5
    return d, top, math.atan2(dx, -dy)                                   # angle 0 at the top


def compass_shadow(x, y):
    d = polar(x, y)[0]
    return 0.0, 0.0, 0.0, 0.5 * (1.0 - smooth(44.0, 63.5, d))


def compass_lens(x, y):
    d = polar(x, y)[0]
    body = (0.62 + 0.13 * smooth(0.0, 58.0, d)) * (1.0 - smooth(57.0, 59.0, d))
    edge = 0.22 * max(0.0, 1.0 - abs(d - 37.0) / 0.75)                 # the icon's boundary
    if edge > 0 and edge >= body * 0.2:
        a = min(1.0, body + edge)
        mix = edge / a
        v = 0.04 + (1.0 - 0.04) * mix
        return v, v, v, a
    return 0.04, 0.045, 0.05, body


def compass_rim(x, y):
    d, top, _ = polar(x, y)
    band = smooth(55.0, 56.5, d) * (1.0 - smooth(62.5, 63.8, d))
    lum = 0.30 + 0.70 * top ** 1.5                                     # bright above, dark below
    return lum, lum, lum, band * (0.70 + 0.25 * top)


def compass_arc(x, y):
    d, _, ang = polar(x, y)
    band = smooth(54.5, 56.5, d) * (1.0 - smooth(62.5, 64.0, d))
    half = math.radians(12.5)
    t = abs(ang) / half
    along = max(0.0, math.cos(min(1.0, t) * math.pi / 2)) if t < 1 else 0.0
    return 1.0, 1.0, 1.0, band * along


def _edge(px, py, ax, ay, bx, by):
    """Signed distance from p to the line a->b: positive on the inside of a triangle listed
    clockwise on screen (y down)."""
    ex, ey = bx - ax, by - ay
    return ((py - ay) * ex - (px - ax) * ey) / math.hypot(ex, ey)


def compass_arrow(x, y):
    apex, left, right = (32.0, 8.0), (17.0, 52.0), (47.0, 52.0)
    inside = min(_edge(x, y, *apex, *right), _edge(x, y, *right, *left), _edge(x, y, *left, *apex))
    if inside <= 0:
        return 0.0, 0.0, 0.0, 0.0
    if inside < 3.0:
        return 0.05, 0.05, 0.06, 0.85                                  # the fine dark outline
    return 1.0, 1.0, 1.0, 1.0


def compass_pill(x, y):
    left, top, right, bottom = 2.0, 12.0, 126.0, 52.0
    r = (bottom - top) / 2
    cy = (top + bottom) / 2
    cx = min(max(x, left + r), right - r)
    d = math.hypot(x - cx, y - cy)                                     # from the capsule's spine
    inside = r - d
    if inside <= 0:
        return 0.0, 0.0, 0.0, 0.0
    if inside < 2.0:
        return 0.55, 0.55, 0.55, 0.55
    return 0.04, 0.04, 0.045, 0.68


def icon_ring(x, y):
    d = polar(x, y, 32.0)[0]
    a = smooth(24.0, 25.0, d) * (1.0 - smooth(31.0, 32.0, d))
    if a <= 0:
        return 0.0, 0.0, 0.0, 0.0
    v = smooth(25.5, 26.5, d) * (1.0 - smooth(29.5, 30.5, d))          # white, dark at both edges
    v = 0.08 + 0.92 * v
    return v, v, v, a


def marker_star(x, y):
    dx, dy = x - 32.0, y - 32.0
    d = math.hypot(dx, dy)

    def ray(along, across):
        taper = max(0.0, 1.0 - abs(along) / 30.0)
        return math.exp(-(across / (0.6 + 1.4 * taper)) ** 2) * taper ** 1.6

    a = max(ray(dx, dy), ray(dy, dx))
    a += math.exp(-(d / 3.5) ** 2) + 0.3 * math.exp(-(d / 9.0) ** 2)
    return 1.0, 1.0, 1.0, min(1.0, a)


def main():
    os.makedirs(MEDIA, exist_ok=True)
    for name, fn in (("SonarRing", ring), ("SonarGlow", glow)):
        path = os.path.join(MEDIA, name + ".tga")
        write_tga(path, field(fn))
        print("wrote", os.path.relpath(path, ROOT))
    for name, w, h, fn in (("CompassShadow", 128, 128, compass_shadow), ("CompassLens", 128, 128, compass_lens),
                           ("CompassRim", 128, 128, compass_rim), ("CompassArc", 128, 128, compass_arc),
                           ("CompassArrow", 64, 64, compass_arrow), ("CompassPill", 128, 64, compass_pill),
                           ("IconRing", 64, 64, icon_ring), ("MarkerStar", 64, 64, marker_star)):
        path = os.path.join(MEDIA, name + ".tga")
        write_rgba(path, w, h, fn)
        print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    main()
