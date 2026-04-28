"""
Generate iOS-ready CloakVPN app icons — hood only, with per-tier
background tints.

  - Basic (primary AppIcon): dark textured background sampled from
    the source PNG corners (matches the brand's standard dark matte).
  - Pro   (alternate icon):  deep emerald flat background that ties to
    CloakDesign.brandGreen (RGB 31,189,92 darkened to ~10% brightness).
    Gold-on-emerald reads as "premium tier of the same brand."

Hood detection: identifies the top-most gold-pixel cluster (the hood)
by finding the vertical gap between hood and wordmark, then extracts
just that cluster as an alpha-masked overlay so we can composite it
onto an arbitrary background color.
"""
from PIL import Image
import os

SRC_DIR = "/sessions/loving-confident-dirac/mnt/cloak-vpn/.icon-source"
OUT_DIR = "/sessions/loving-confident-dirac/mnt/outputs/cloak-icons"
os.makedirs(OUT_DIR, exist_ok=True)

GOLD_THRESHOLD = 200
ROW_GOLD_MIN = 5
MARGIN_FRAC = 0.05
TARGET_FILL = 0.92
TARGET_SIZE = 1024

# Pro icon background — deep emerald derived from CloakDesign.brandGreen
# (RGB 31,189,92) at ~12% brightness. Same dark luminance as the Basic
# icon background so the home-screen weight feels balanced; just
# different hue.
PRO_BG = (10, 38, 22)


def hood_overlay(im):
    """Crop the source to just the hood (top-most gold cluster), then
    convert to RGBA with the dark background pixels alpha-stripped so
    the hood can be composited onto any color."""
    if im.mode != "RGB":
        im = im.convert("RGB")
    px = im.load()
    w, h = im.size

    # Per-row gold-pixel count
    row_counts = []
    for y in range(h):
        c = 0
        for x in range(w):
            r, g, _ = px[x, y]
            if (r + g) > GOLD_THRESHOLD:
                c += 1
        row_counts.append(c)

    # First contiguous "live" run of rows = the hood
    in_run = False
    run_start = None
    runs = []
    for y, c in enumerate(row_counts):
        live = c >= ROW_GOLD_MIN
        if live and not in_run:
            run_start = y
            in_run = True
        elif not live and in_run:
            runs.append((run_start, y - 1))
            in_run = False
    if in_run:
        runs.append((run_start, len(row_counts) - 1))

    hood_top, hood_bottom = runs[0]
    min_x, max_x = w, 0
    for y in range(hood_top, hood_bottom + 1):
        for x in range(w):
            r, g, _ = px[x, y]
            if (r + g) > GOLD_THRESHOLD:
                if x < min_x: min_x = x
                if x > max_x: max_x = x

    hood_h = hood_bottom - hood_top
    hood_w = max_x - min_x
    margin = int(max(hood_h, hood_w) * MARGIN_FRAC)
    bbox = (
        max(0, min_x - margin),
        max(0, hood_top - margin),
        min(w, max_x + margin + 1),
        min(h, hood_bottom + margin + 1),
    )

    hood = im.crop(bbox).convert("RGBA")
    px2 = hood.load()
    hw, hh = hood.size
    for y in range(hh):
        for x in range(hw):
            r, g, b, _ = px2[x, y]
            # Dark background pixels become fully transparent; brighter
            # (gold) pixels stay opaque. Smooth ramp at the boundary
            # for a clean anti-aliased edge.
            sum_rg = r + g
            if sum_rg < 120:
                px2[x, y] = (r, g, b, 0)
            elif sum_rg < 240:
                alpha = int((sum_rg - 120) * 255 / 120)
                px2[x, y] = (r, g, b, alpha)
            else:
                px2[x, y] = (r, g, b, 255)
    return hood


def composite(hood_rgba, bg_color, target_size=TARGET_SIZE, fill=TARGET_FILL):
    w, h = hood_rgba.size
    target_short = target_size * fill
    scale = target_short / min(w, h)
    new_w, new_h = int(w * scale), int(h * scale)
    scaled = hood_rgba.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGB", (target_size, target_size), bg_color)
    canvas.paste(scaled, ((target_size - new_w) // 2,
                          (target_size - new_h) // 2),
                 mask=scaled)
    return canvas


def export(src_filename, out_basename, sizes, bg_color=None):
    src = os.path.join(SRC_DIR, src_filename)
    im = Image.open(src)
    hood = hood_overlay(im)
    if bg_color is None:
        bg_color = im.convert("RGB").getpixel((0, 0))
    print(f"  {src_filename}: hood {hood.size}, bg={bg_color}")
    base = composite(hood, bg_color)
    for size in sizes:
        scaled = base.resize((size, size), Image.LANCZOS) if size != TARGET_SIZE else base
        out = os.path.join(OUT_DIR, f"{out_basename}_{size}.png")
        scaled.save(out, "PNG", optimize=True)
        print(f"    wrote {out} ({os.path.getsize(out)} bytes)")


print("== Basic — dark textured bg ==")
export("CloakVPN.png", "AppIcon", [1024], bg_color=None)
print("== Pro — deep emerald bg ==")
export("CloakVPN_PRO.png", "CloakProIcon", [60, 120, 180, 1024], bg_color=PRO_BG)
print("Done.")
