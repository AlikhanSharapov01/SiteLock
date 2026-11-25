#!/usr/bin/env python3
"""Draws the SiteLock app icon and writes Resources/AppIcon.icns (+ a 1024 px PNG preview).

Only needed to change the icon; the build uses the committed AppIcon.icns.
Requires Pillow (pip install pillow).  Usage: python3 scripts/make-icon.py [preview.png]
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersampling factor for smooth edges
N = 1024 * S
TOP, BOTTOM = (99, 102, 241), (30, 58, 138)  # indigo -> deep blue
WHITE = (255, 255, 255, 255)


def px(v):
    return int(v * S)


def gradient(size, top, bottom):
    grad = Image.new("RGBA", (1, size))
    for y in range(size):
        t = y / (size - 1)
        grad.putpixel((0, y), tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    return grad.resize((size, size))


def draw_icon():
    icon = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # macOS icon grid: 824 px rounded square centred in 1024, soft shadow below.
    box = (px(100), px(100), px(924), px(924))
    radius = px(185)
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + px(12), box[2], box[3] + px(12)), radius, fill=(0, 0, 0, 90))
    icon.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(px(14))))

    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    icon.paste(gradient(N, TOP, BOTTOM), (0, 0), mask)

    d = ImageDraw.Draw(icon)
    # Padlock shackle.
    sw = px(64)
    d.arc((px(352), px(232), px(672), px(552)), 180, 360, fill=WHITE, width=sw)
    d.rectangle((px(352), px(392), px(352) + sw, px(500)), fill=WHITE)
    d.rectangle((px(672) - sw, px(392), px(672), px(500)), fill=WHITE)
    # Padlock body.
    body = (px(292), px(470), px(732), px(800))
    d.rounded_rectangle(body, px(56), fill=WHITE)

    # Globe on the body, in the background colour.
    cx, cy, r = px(512), px(635), px(112)
    lw = px(18)
    globe = tuple(int((a + b) / 2) for a, b in zip(TOP, BOTTOM)) + (255,)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=globe, width=lw)
    d.ellipse((cx - r * 0.45, cy - r, cx + r * 0.45, cy + r), outline=globe, width=lw)
    inner = r - lw / 2  # keep line ends inside the outline
    for dy in (-0.5, 0, 0.5):
        half = (inner ** 2 - (r * dy) ** 2) ** 0.5
        d.line((cx - half, cy + r * dy, cx + half, cy + r * dy), fill=globe, width=lw)

    return icon.resize((1024, 1024), Image.LANCZOS)


def main():
    root = Path(__file__).resolve().parent.parent
    icon = draw_icon()
    icon.save(root / "Resources" / "AppIcon.icns")
    if len(sys.argv) > 1:
        icon.save(sys.argv[1])


if __name__ == "__main__":
    main()
