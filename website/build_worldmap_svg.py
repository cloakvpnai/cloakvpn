#!/usr/bin/env python3
"""
Generate a clean SVG world map for the cloakvpn.ai landing page.

Uses Natural Earth low-res countries with equirectangular projection
(simple linear lat/lon -> x/y) so the embedding HTML can overlay
region markers via straightforward percentage math:

    x = (lon + 180) / 360 * 100  (% of viewBox width)
    y = (90 - lat) / 180 * 100   (% of viewBox height)

Outline-only, no fills, ~25 KB on disk. Saved to website/assets/.
"""
import io
import os
import geopandas as gpd

OUT = "/sessions/loving-confident-dirac/mnt/cloak-vpn/website/assets/world-map.svg"

# Pull the Natural Earth low-res countries shapefile (10 MB ZIP, cached).
url = "https://naturalearth.s3.amazonaws.com/110m_cultural/ne_110m_admin_0_countries.zip"
world = gpd.read_file(url)
# Drop Antarctica — visually heavy at the bottom, no value.
world = world[world.get("NAME", "") != "Antarctica"]

# Build SVG manually for full styling control. ViewBox is 360 x 180
# (lon span x lat span); coordinates are (lon, lat) flipped on Y.
parts = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 360 180" '
         'preserveAspectRatio="xMidYMid slice" '
         'aria-hidden="true">']
parts.append('<g fill="none" stroke="currentColor" stroke-width="0.3" '
             'stroke-linejoin="round" stroke-linecap="round">')

def ring_to_path(coords):
    if not coords:
        return ""
    pts = []
    for i, (lon, lat) in enumerate(coords):
        # Equirectangular: x = lon + 180; y = 90 - lat
        x = lon + 180
        y = 90 - lat
        pts.append(f"{'M' if i == 0 else 'L'}{x:.2f},{y:.2f}")
    pts.append("Z")
    return "".join(pts)

for geom in world.geometry:
    if geom is None or geom.is_empty:
        continue
    if geom.geom_type == "Polygon":
        polys = [geom]
    elif geom.geom_type == "MultiPolygon":
        polys = list(geom.geoms)
    else:
        continue
    for poly in polys:
        d = ring_to_path(list(poly.exterior.coords))
        for interior in poly.interiors:
            d += ring_to_path(list(interior.coords))
        if d:
            parts.append(f'<path d="{d}"/>')

parts.append('</g></svg>')

svg = "\n".join(parts)
with open(OUT, "w") as f:
    f.write(svg)

print(f"wrote {OUT}  ({os.path.getsize(OUT)} bytes)")
