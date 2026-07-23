#!/usr/bin/env python3
"""Build Unduck.icns from assets/icon-source.png.

Run after replacing the source art. Needs Pillow: pip3 install --user Pillow

The source is a square rendering with a white surround and a baked-in drop shadow.
Neither belongs in a macOS icon: the system draws its own shadow, and any leftover
white shows as a halo against a dark Dock. So the tile is cut out by colour
saturation, masked to a squircle inset by a few pixels to drop the antialiased
fringe, and centred on the 1024 canvas at Apple's 824-point content size.
"""
import subprocess, sys
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
SRC = ROOT / "assets" / "icon-source.png"
OUT = ROOT / "assets" / "Unduck.icns"
CANVAS, CONTENT, INSET = 1024, 824, 3

src = Image.open(SRC).convert("RGBA")
px = src.load()

# Locate the coloured tile. A whiteness test cannot separate tile from shadow,
# because the shadow is pale grey; requiring real saturation can.
xs, ys = [], []
for y in range(0, src.height, 2):
    for x in range(0, src.width, 2):
        p = px[x, y]
        if max(p[:3]) - min(p[:3]) > 30:
            xs.append(x); ys.append(y)
left, top = min(xs), min(ys)
size = min(max(xs) - left + 1, max(ys) - top + 1)

tile = src.crop((left, top, left + size, top + size)).resize((CONTENT, CONTENT), Image.LANCZOS)
mask = Image.new("L", (CONTENT, CONTENT), 0)
ImageDraw.Draw(mask).rounded_rectangle(
    (INSET, INSET, CONTENT - 1 - INSET, CONTENT - 1 - INSET),
    radius=int(CONTENT * 0.2237), fill=255)
tile.putalpha(mask)

icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
icon.paste(tile, ((CANVAS - CONTENT) // 2,) * 2, tile)
icon.save(ROOT / "assets" / "icon-1024.png")

iconset = ROOT / "build" / "Unduck.iconset"
subprocess.run(["rm", "-rf", str(iconset)], check=True)
iconset.mkdir(parents=True)
for pt in (16, 32, 128, 256, 512):
    icon.resize((pt, pt), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}.png")
    icon.resize((pt * 2, pt * 2), Image.LANCZOS).save(iconset / f"icon_{pt}x{pt}@2x.png")

subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT)], check=True)
print(f"built: {OUT.relative_to(ROOT)}")
