"""Convert the alert sounds downloaded from Pixabay into Media/*.ogg (#13).

    python Tools/import_sounds.py <folder with the downloads>

The owner's picks (2026-10-18), Pixabay Content License (README, "Sounds"):
shipped inside the addon, never as a pack of their own. The downloads aren't in
the repository; the .ogg files are. Each is trimmed of its trailing silence,
made mono, brought to the same loudness (mean -20 dB, peaks under -1 dB) and
encoded with ffmpeg (libvorbis).
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MEDIA = os.path.join(ROOT, "Media")

# Pixabay file -> (our file, seconds kept or None for all)
SOUNDS = {
    "freesound_community-sonar-ping-95840.mp3": ("Sonar.ogg", 1.6),
    "49053354-radar-ping-306440.mp3": ("RadarBlip.ogg", None),
    "dragon-studio-deepsea-sonar-386156.mp3": ("DeepSea.ogg", None),
    "universfield-clear-bell-chime-487898.mp3": ("BellChime.ogg", 1.2),
    "universfield-new-notification-016-350210.mp3": ("Notification.ogg", 0.65),
    "vadim_makes_sound-sci-fi-hud-notification-ping-547867.mp3": ("HudPing.ogg", 1.1),
}
MEAN, PEAK = -20.0, -1.0


def levels(ffmpeg, path):
    out = subprocess.run([ffmpeg, "-hide_banner", "-nostats", "-i", path, "-af", "volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    mean = float(re.search(r"mean_volume: (-?[\d.]+) dB", out).group(1))
    peak = float(re.search(r"max_volume: (-?[\d.]+) dB", out).group(1))
    return mean, peak


def main(folder):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("ffmpeg not found")
    os.makedirs(MEDIA, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, (out, keep) in SOUNDS.items():
            src = os.path.join(folder, name)
            wav = os.path.join(tmp, out + ".wav")
            trim = ["-af", f"atrim=0:{keep},afade=t=out:st={keep - 0.2}:d=0.2"] if keep else []
            subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", src, *trim, "-ac", "1", "-ar", "44100", wav],
                           check=True)
            mean, peak = levels(ffmpeg, wav)
            gain = min(MEAN - mean, PEAK - peak)
            subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", wav, "-af", f"volume={gain:.1f}dB",
                            "-c:a", "libvorbis", "-q:a", "5", "-map_metadata", "-1", os.path.join(MEDIA, out)],
                           check=True)
            print(f"wrote Media/{out} ({gain:+.1f} dB)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
