#!/usr/bin/env python3
"""
Resize iPhone 16 Pro Max screenshots (1290x2796) to one of Apple's
accepted App Store screenshot sizes for the 6.5" iPhone Display gallery.

The 16 Pro Max's native 1290x2796 is technically the "6.7" Display"
size which Apple accepts in the 6.7" gallery. But App Store Connect
ALSO requires at least one screenshot per device size you ever want
to support — for backward compat with iPhone 14 Plus / 13 Pro Max etc.,
you upload the same content at 1284x2778 (6.5" Display).

Aspect ratio is essentially identical (0.4613 vs 0.4622), so a simple
LANCZOS resize with no cropping/letterboxing produces visually
indistinguishable output.

Pulls every .PNG / .png from ~/Downloads/ that's exactly 1290x2796 and
writes resized 1284x2778 copies into ~/Downloads/CloakVPN-screenshots/.
Renames them sequentially (01-, 02-, ...) so they upload in order.
"""
import os
import sys
from PIL import Image
from pathlib import Path

DOWNLOADS = Path.home() / "Downloads"
OUT = DOWNLOADS / "CloakVPN-screenshots"
OUT.mkdir(exist_ok=True)

# Apple's preferred 6.5" iPhone size for App Store gallery.
TARGET_W, TARGET_H = 1284, 2778

# Heuristic: accept any image with iPhone-ish aspect ratio. The phone
# screenshots may have come from a 6.1" / 6.7" / Plus / etc. depending
# on which iPhone took them, all of which have aspect ratios in the
# ~0.46 to ~0.50 range (portrait, ~9:19.5 or ~9:19.6). We then fit
# each into the 1284x2778 frame with letterbox padding using #000000
# black — which matches Cloak VPN's all-black UI background, so the
# pad area is visually invisible (no obvious "video letterbox" bars).
MIN_ASPECT, MAX_ASPECT = 0.40, 0.55

PAD_COLOR = (0, 0, 0)  # matches Cloak VPN's UI background

candidates = sorted(
    p for p in DOWNLOADS.iterdir()
    if p.suffix.lower() in (".png", ".jpg", ".jpeg") and not p.name.startswith(".")
       and (p.name.upper().startswith("IMG_") or p.name.startswith("Screenshot"))
)

n = 0
for src in candidates:
    try:
        im = Image.open(src).convert("RGB")
    except Exception:
        continue
    w, h = im.size
    aspect = w / h
    if not (MIN_ASPECT < aspect < MAX_ASPECT):
        # Not a portrait phone screenshot
        continue

    # Scale-to-fit: compute the largest scale where the image still
    # fits inside TARGET_W x TARGET_H.
    scale = min(TARGET_W / w, TARGET_H / h)
    scaled_w = int(w * scale)
    scaled_h = int(h * scale)
    scaled = im.resize((scaled_w, scaled_h), Image.LANCZOS)

    # Letterbox onto a TARGET_W x TARGET_H canvas of PAD_COLOR.
    canvas = Image.new("RGB", (TARGET_W, TARGET_H), PAD_COLOR)
    canvas.paste(scaled,
                 ((TARGET_W - scaled_w) // 2,
                  (TARGET_H - scaled_h) // 2))

    n += 1
    out_name = f"{n:02d}-{src.stem}.png"
    out_path = OUT / out_name
    canvas.save(out_path, "PNG", optimize=True)
    pad_top = (TARGET_H - scaled_h) // 2
    pad_side = (TARGET_W - scaled_w) // 2
    print(f"  {src.name} ({w}x{h}) -> scaled {scaled_w}x{scaled_h}"
          f" letterbox+{pad_top}px top/bottom +{pad_side}px sides"
          f" -> {out_name}")

if n == 0:
    print(f"No iPhone-shaped screenshots found in {DOWNLOADS}.")
    print("Looking for portrait images named IMG_*.png/jpg with aspect 0.40-0.55.")
    sys.exit(1)

print(f"\nDone. {n} screenshot(s) resized to {OUT}/")
print(f"Drop them into App Store Connect -> 6.5\" Display gallery.")
