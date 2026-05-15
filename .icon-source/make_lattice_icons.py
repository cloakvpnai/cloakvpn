"""
Generate iOS-ready Lattice VPN app icons from Lattice.png.

Source: 832x1248 portrait. Top ~67% is the lattice-shield graphic;
bottom ~33% is the wordmark "LATTICE" + a margin. iOS app icons must
NOT include the app name as text (springboard label below the icon
adds it automatically), so we crop to just the shield.

  - Basic (primary AppIcon): deep navy background matching the source
    logo's gradient. The lattice-shield sits centered.
  - Pro   (alternate icon):  same shield, same navy background, plus
    a thicker amber outer ring (replaces the gold ring on the Cloak
    Pro variant) — keeps the "Pro" tier visually distinguishable
    while staying aligned with the new brand palette.

Detection logic: the wordmark is roughly centered horizontally and sits
in the bottom third with text-shaped gold/white pixels. We crop the
SHIELD region by:
  1. Finding the bbox of bright (non-background) pixels.
  2. Looking for a vertical gap (mostly-dark rows) between the shield
     cluster and the wordmark cluster — same approach as the original
     Cloak hood/text detector.
  3. Keeping only the top cluster (the shield).
"""
from PIL import Image, ImageDraw
import os

SRC_DIR = "/sessions/loving-confident-dirac/mnt/cloak-vpn/.icon-source"
OUT_DIR = "/sessions/loving-confident-dirac/mnt/outputs/lattice-icons"
os.makedirs(OUT_DIR, exist_ok=True)

# Heuristic: pixel is "bright" if its luminance is meaningfully above
# the dark navy background. The logo's mint nodes peak at G ≈ 220, the
# amber nodes at R ≈ 255, the lattice strokes at G ≈ 180. The navy
# background is ~RGB(20, 38, 60). Threshold catches everything that's
# part of the design without including background noise.
BRIGHT_THRESHOLD = 280   # R + G + B threshold for "this pixel is the design"
ROW_BRIGHT_MIN = 15      # row counts as "live" if it has at least this many bright px
MARGIN_FRAC = 0.06       # 6% breathing room around the cropped shield
TARGET_FILL = 0.88       # shield fills this much of the icon canvas (slightly less
                          # than the 0.92 Cloak fill because the shield outline goes
                          # all the way to its edges, no need for tighter zoom)
TARGET_SIZE = 1024

# Background — sampled from the source (deep navy gradient). Pure RGB
# (10, 22, 40) is close to the center of the gradient.
BASIC_BG = (10, 22, 40)
PRO_BG = (10, 22, 40)

# Pro accent ring — amber, matches the source logo's amber accent nodes.
PRO_RING_COLOR = (255, 179, 71)   # #FFB347
PRO_RING_INSET_FRAC = 0.07
PRO_RING_THICKNESS_FRAC = 0.038
PRO_RING_CORNER_FRAC = 0.18


def shield_overlay(im):
    """Crop the source to just the lattice-shield (top cluster, above the
    LATTICE wordmark) and return an RGBA image with the navy background
    alpha-stripped so the shield can be composited onto any color."""
    if im.mode != "RGB":
        im = im.convert("RGB")
    px = im.load()
    w, h = im.size

    # Per-row bright-pixel count
    row_counts = []
    for y in range(h):
        c = 0
        for x in range(w):
            r, g, b = px[x, y]
            if (r + g + b) > BRIGHT_THRESHOLD:
                c += 1
        row_counts.append(c)

    # First contiguous "live" run of rows = the shield.
    # Second run = the wordmark. Take only the first.
    in_run = False
    run_start = None
    runs = []
    for y, c in enumerate(row_counts):
        live = c >= ROW_BRIGHT_MIN
        if live and not in_run:
            run_start = y
            in_run = True
        elif not live and in_run:
            runs.append((run_start, y - 1))
            in_run = False
    if in_run:
        runs.append((run_start, len(row_counts) - 1))

    if not runs:
        raise RuntimeError("No bright clusters detected in source")

    # The shield is the largest run (the wordmark text rows have fewer
    # bright pixels per row than the dense lattice-grid rows). Take the
    # FIRST run since the shield is at the top of the image.
    shield_top, shield_bottom = runs[0]

    # Horizontal extent of the shield rows
    min_x, max_x = w, 0
    for y in range(shield_top, shield_bottom + 1):
        for x in range(w):
            r, g, b = px[x, y]
            if (r + g + b) > BRIGHT_THRESHOLD:
                if x < min_x: min_x = x
                if x > max_x: max_x = x

    shield_h = shield_bottom - shield_top
    shield_w = max_x - min_x
    margin = int(max(shield_h, shield_w) * MARGIN_FRAC)
    bbox = (
        max(0, min_x - margin),
        max(0, shield_top - margin),
        min(w, max_x + margin + 1),
        min(h, shield_bottom + margin + 1),
    )

    shield = im.crop(bbox).convert("RGBA")
    px2 = shield.load()
    sw, sh = shield.size
    for y in range(sh):
        for x in range(sw):
            r, g, b, _ = px2[x, y]
            sum_rgb = r + g + b
            # Alpha-strip the navy background; keep design pixels opaque.
            # Smooth transition between threshold and full-opacity for
            # anti-aliased edges.
            if sum_rgb < 200:
                px2[x, y] = (r, g, b, 0)
            elif sum_rgb < 320:
                alpha = int((sum_rgb - 200) * 255 / 120)
                px2[x, y] = (r, g, b, alpha)
            else:
                px2[x, y] = (r, g, b, 255)
    return shield


def composite(shield_rgba, bg_color, target_size=TARGET_SIZE,
              fill=TARGET_FILL, gold_ring=False):
    w, h = shield_rgba.size
    target_short = target_size * fill
    scale = target_short / min(w, h)
    new_w, new_h = int(w * scale), int(h * scale)
    scaled = shield_rgba.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGB", (target_size, target_size), bg_color)
    canvas.paste(scaled,
                 ((target_size - new_w) // 2,
                  (target_size - new_h) // 2),
                 mask=scaled)
    if gold_ring:
        draw = ImageDraw.Draw(canvas)
        inset = int(target_size * PRO_RING_INSET_FRAC)
        thick = int(target_size * PRO_RING_THICKNESS_FRAC)
        radius = int(target_size * PRO_RING_CORNER_FRAC)
        draw.rounded_rectangle(
            (inset, inset, target_size - inset, target_size - inset),
            radius=radius,
            outline=PRO_RING_COLOR,
            width=thick,
        )
    return canvas


def export(out_basename, sizes, bg_color, gold_ring=False):
    src = os.path.join(SRC_DIR, "Lattice.png")
    im = Image.open(src)
    shield = shield_overlay(im)
    print(f"  shield bbox: {shield.size}, bg={bg_color}, ring={gold_ring}")
    base = composite(shield, bg_color, gold_ring=gold_ring)
    for size in sizes:
        scaled = base.resize((size, size), Image.LANCZOS) if size != TARGET_SIZE else base
        out = os.path.join(OUT_DIR, f"{out_basename}_{size}.png")
        scaled.save(out, "PNG", optimize=True)
        print(f"    wrote {out} ({os.path.getsize(out)} bytes)")


print("== Basic — navy bg, no ring ==")
export("AppIcon", [1024], BASIC_BG, gold_ring=False)
print("== Pro — navy bg + amber ring ==")
export("LatticeProIcon", [60, 120, 180, 1024], PRO_BG, gold_ring=True)
print("Done.")
