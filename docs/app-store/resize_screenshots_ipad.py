#!/usr/bin/env python3
"""
Take the 5 iPhone-sized App Store screenshots in
~/Downloads/CloakVPN-screenshots/ (1284 x 2778) and reformat them
for the iPad 12.9" / 13" gallery on App Store Connect.

Apple's accepted sizes for iPad 12.9" / 13":
  2048 x 2732  (12.9" portrait — widest support, oldest gen iPad Pro)
  2732 x 2048  (12.9" landscape)
  2064 x 2752  (13" portrait — M4 iPad Pro)
  2752 x 2064  (13" landscape)

We pick 2048 x 2732 (12.9" portrait) since it's accepted everywhere
and matches the existing portrait-mode iPhone screenshots' orientation.

Approach: scale each iPhone screenshot to fit the target HEIGHT
(2732), then center on a 2048 x 2732 black canvas. The iPhone
screenshot ends up centered with ~393 px of black on each side. Since
the app's UI background IS black, the letterbox is visually
near-invisible — the iPhone content sits centered in an iPad-sized
frame as if it were running letterboxed on an iPad.

This is the standard Apple-accepted approach for iPhone-only apps
that also need to populate the iPad gallery.
"""
import sys
from pathlib import Path
from PIL import Image

SRC_DIR = Path.home() / "Downloads" / "CloakVPN-screenshots"
OUT_DIR = Path.home() / "Downloads" / "CloakVPN-screenshots-ipad"
OUT_DIR.mkdir(exist_ok=True)

TARGET_W, TARGET_H = 2048, 2732
PAD_COLOR = (0, 0, 0)  # matches Cloak VPN's all-black UI

candidates = sorted(p for p in SRC_DIR.glob("*.png"))
if not candidates:
    print(f"No PNGs found in {SRC_DIR}.")
    print("Run resize_screenshots.py first to generate the iPhone-sized PNGs.")
    sys.exit(1)

n = 0
for src in candidates:
    im = Image.open(src).convert("RGB")
    w, h = im.size

    # Scale to fit the target HEIGHT (the iPhone screenshot's aspect
    # is taller than the iPad's, so height is the constraining
    # dimension). Image stays portrait, gets centered horizontally.
    scale = TARGET_H / h
    scaled_w = int(w * scale)
    scaled_h = TARGET_H
    if scaled_w > TARGET_W:
        # Edge case — if the iPhone screenshot were wider proportionally
        # than the iPad, fit to width instead. (Doesn't happen with our
        # current 1284x2778 source, but defensive.)
        scale = TARGET_W / w
        scaled_w = TARGET_W
        scaled_h = int(h * scale)

    scaled = im.resize((scaled_w, scaled_h), Image.LANCZOS)
    canvas = Image.new("RGB", (TARGET_W, TARGET_H), PAD_COLOR)
    canvas.paste(scaled,
                 ((TARGET_W - scaled_w) // 2,
                  (TARGET_H - scaled_h) // 2))

    n += 1
    out_name = f"{n:02d}-ipad-{src.stem.split('-', 1)[-1] if '-' in src.stem else src.stem}.png"
    out_path = OUT_DIR / out_name
    canvas.save(out_path, "PNG", optimize=True)
    print(f"  {src.name} ({w}x{h}) -> scaled {scaled_w}x{scaled_h}"
          f" + letterbox -> {out_name}")

print(f"\nDone. {n} iPad screenshot(s) written to {OUT_DIR}/")
print(f"Drop them into App Store Connect -> 12.9\" iPad Display gallery.")
