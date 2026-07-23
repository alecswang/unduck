#!/usr/bin/env python3
"""Draw the DMG window background: assets/dmg-background.png

Rendered at 2x (1280x800) and tagged 144 dpi so Finder maps it to a 640x400 window
and it stays sharp on a Retina display. Needs Pillow.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).parent
W, H, S = 640, 400, 2           # points, then scale
ICON_Y = 200                    # centre line the two icons sit on
APP_X, DEST_X = 170, 470

BG_TOP, BG_BOTTOM = (222, 241, 255), (188, 224, 253)
NAVY, MUTED = (23, 43, 84), (96, 122, 158)

def font(name, size):
    for path in (f"/System/Library/Fonts/Supplemental/{name}.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()

im = Image.new("RGB", (W * S, H * S), BG_TOP)
d = ImageDraw.Draw(im)

# Vertical gradient, drawn by hand because Pillow has no gradient primitive.
for y in range(H * S):
    t = y / (H * S)
    d.line([(0, y), (W * S, y)],
           fill=tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))

title = font("Arial Bold", 21 * S)
sub = font("Arial", 13 * S)

d.text((W * S / 2, 52 * S), "Drag Unduck into Applications",
       font=title, fill=NAVY, anchor="mm")

# The arrow. Finder draws the two icons; this only has to connect them, so it stops
# short of both to avoid colliding with the icon labels.
y = ICON_Y * S
x0, x1 = (APP_X + 78) * S, (DEST_X - 78) * S
d.line([(x0, y), (x1 - 16 * S, y)], fill=NAVY, width=5 * S)
d.polygon([(x1, y), (x1 - 20 * S, y - 13 * S), (x1 - 20 * S, y + 13 * S)], fill=NAVY)

d.text((W * S / 2, 340 * S),
       "Blocked by macOS? That is expected. See the install notes:",
       font=sub, fill=MUTED, anchor="mm")
d.text((W * S / 2, 360 * S), "github.com/alecswang/unduck",
       font=sub, fill=MUTED, anchor="mm")

out = ROOT / "assets" / "dmg-background.png"
im.save(out, dpi=(72 * S, 72 * S))
print(f"built: {out.relative_to(ROOT)}  ({W*S}x{H*S} @ {72*S}dpi -> {W}x{H} pt)")
