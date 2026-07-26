"""Generate Electron app icons from the selected square artwork.

Run from the repository root:

    uv run --with pillow python scripts/generate_app_icons.py
"""

from __future__ import annotations

import platform
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = ROOT / "assets" / "icons"
SOURCE = ICON_DIR / "attendance-ledger-icon-v3.png"
MASTER = ICON_DIR / "attendance-ledger-icon.png"
WINDOWS_ICON = ICON_DIR / "attendance-ledger.ico"
MACOS_ICON = ICON_DIR / "attendance-ledger.icns"
PNG_DIR = ICON_DIR / "png"

PNG_SIZES = (16, 32, 48, 64, 128, 256, 512, 1024)
ICO_SIZES = ((16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256))
ICONSET_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def render_master() -> Image.Image:
    artwork = Image.open(SOURCE).convert("RGBA")
    artwork = artwork.resize((1024, 1024), Image.Resampling.LANCZOS)

    # The generated artwork already contains a rounded tile. Replacing its
    # white canvas with a matching antialiased mask keeps app-icon corners
    # transparent on Windows and avoids a white square in macOS Finder.
    scale = 4
    mask = Image.new("L", (1024 * scale, 1024 * scale), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (0, 0, 1024 * scale - 1, 1024 * scale - 1),
        radius=180 * scale,
        fill=255,
    )
    mask = mask.resize((1024, 1024), Image.Resampling.LANCZOS)
    artwork.putalpha(mask)
    return artwork


def save_macos_icon(master: Image.Image) -> None:
    if platform.system() == "Darwin":
        with tempfile.TemporaryDirectory(suffix=".iconset") as temporary_directory:
            iconset = Path(temporary_directory) / "attendance-ledger.iconset"
            iconset.mkdir()
            for filename, size in ICONSET_SIZES.items():
                master.resize((size, size), Image.Resampling.LANCZOS).save(iconset / filename)
            subprocess.run(
                ["iconutil", "-c", "icns", str(iconset), "-o", str(MACOS_ICON)],
                check=True,
            )
        return

    images = [
        master.resize((size, size), Image.Resampling.LANCZOS)
        for size in (16, 32, 64, 128, 256, 512, 1024)
    ]
    images[0].save(MACOS_ICON, format="ICNS", append_images=images[1:])


def main() -> None:
    PNG_DIR.mkdir(parents=True, exist_ok=True)
    master = render_master()
    master.save(MASTER, optimize=True)

    for size in PNG_SIZES:
        master.resize((size, size), Image.Resampling.LANCZOS).save(
            PNG_DIR / f"attendance-ledger-{size}.png",
            optimize=True,
        )

    master.save(WINDOWS_ICON, format="ICO", sizes=ICO_SIZES)
    save_macos_icon(master)


if __name__ == "__main__":
    main()
