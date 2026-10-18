"""Generate NodeRadar's own textures and sound into Media/ (never hand-edit the outputs).

    python Tools/make_media.py

The sonar alert (docs/PLAN.md, "New nodes and the alert"): white shapes with
the shape in alpha, tinted in game (green for herbs, gold for ore) and drawn
additively, so they glow on any minimap skin with no square around them.

  SonarRing   a thin ring with a soft halo, scaled out from the node
  SonarGlow   a round soft glow that stays on the node a moment
  Sonar.ogg   the sonar sound (#13): a ping with two fading echoes and a short
              tail, synthesised here and encoded by ffmpeg (libvorbis); only
              this script needs ffmpeg, the .ogg is committed

Plain Python otherwise: 32-bit uncompressed TGA, top-left origin.
"""

import math
import os
import shutil
import struct
import subprocess
import tempfile
import wave

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


RATE = 44100


def ping(t):
    """One ping at time t (s): a bright attack, a ringing decay, a slight drop in pitch."""
    if t < 0:
        return 0.0
    attack = min(1.0, t / 0.004)
    decay = math.exp(-t / 0.28)
    f = 1250.0 * (1.0 - 0.03 * min(1.0, t / 0.6))
    phase = 2 * math.pi * f * t
    return attack * decay * (math.sin(phase) + 0.18 * math.sin(2 * phase) + 0.06 * math.sin(3.01 * phase))


def sonar_samples():
    """The ping, two softer echoes (as if back from the node), and a short tail."""
    length = 1.8
    out = []
    for i in range(int(RATE * length)):
        t = i / RATE
        v = ping(t) + 0.32 * ping(t - 0.34) + 0.11 * ping(t - 0.68)
        out.append(v)
    # The tail: a few feedback delays, mixed in quietly.
    for delay, gain in ((0.043, 0.30), (0.067, 0.24), (0.089, 0.18)):
        d = int(RATE * delay)
        tail = [0.0] * len(out)
        for i in range(d, len(out)):
            tail[i] = out[i - d] * gain + tail[i - d] * gain
        out = [a + 0.5 * b for a, b in zip(out, tail)]
    # Fade the last 0.2 s, then normalise to -6 dBFS.
    fade = int(RATE * 0.2)
    for k in range(fade):
        out[-fade + k] *= 1 - k / fade
    peak = max(abs(v) for v in out)
    return [v / peak * 0.5 for v in out]


def write_sonar():
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        print("skipped Sonar.ogg: ffmpeg not found")
        return
    path = os.path.join(MEDIA, "Sonar.ogg")
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "sonar.wav")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in sonar_samples()))
        subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis", "-q:a", "5",
                        "-map_metadata", "-1", path], check=True)
    print("wrote", os.path.relpath(path, ROOT))


def main():
    os.makedirs(MEDIA, exist_ok=True)
    for name, fn in (("SonarRing", ring), ("SonarGlow", glow)):
        path = os.path.join(MEDIA, name + ".tga")
        write_tga(path, field(fn))
        print("wrote", os.path.relpath(path, ROOT))
    write_sonar()


if __name__ == "__main__":
    main()
