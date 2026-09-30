#!/usr/bin/env python3
"""
Render MenuRight.icon (Apple Icon Composer project) to a 1024x1024 PNG.

The .icon project is icon.json + Assets/{Vector.svg, Vector-1.svg}.
icon.json declares:
  - background: linear-gradient from cyan to purple, vertical, y in [0, 0.7]
  - one group with 2 layers, each with its own fill, scale, translation-in-points
    - Vector:    fill = extended-srgb(0, 0.53333, 1, 1)         (blue)
                 scale = 7,  translation = (239.04, 176.76)
    - Vector-1:  fill = srgb(0.99314, 0.96853, 1, 1)            (near-white)
                 scale = 7,  translation = (-30.05, -54.76)
  - group scale = 0.9, translation = (0, 0), shadow + translucency

The 1024x1024 base is the macOS app icon canvas. translation-in-points is in
that 1024 coordinate system. scale=7 means the SVG is rendered at 7x its native
viewBox size; the native SVG is rendered at 1024 / 7 = 146.28 "points" wide
(or height, depending on aspect).

We approximate the composer's final transform by:
  1. Render each SVG (which has its own viewBox like 60x69) at a very large
     pixel size (e.g. 2048) on a transparent background.
  2. Recolour: replace the SVG's black fill with the JSON-specified color.
  3. Determine the final on-canvas placement:
       - native svg is 60x69 (Vector) or 103x103 (Vector-1)
       - with scale=7: 420x483 or 721x721
       - icon composer centers the layer on the translation point
       - we treat translation as the center of the layer
       - then apply outer group scale=0.9 around canvas center (512, 512)
  4. Composite onto a 1024x1024 linear gradient background.
"""

import os
import subprocess
import sys
import json
import math
from PIL import Image

ICON_DIR = "/Users/suxin/Suxin/code/app/MenuRight/MenuRight.icon"
ASSETS = os.path.join(ICON_DIR, "Assets")
OUT_PNG = "/tmp/iconrender/icon_1024.png"
RENDER_DIR = "/tmp/iconrender"

os.makedirs(RENDER_DIR, exist_ok=True)

# 1. Parse icon.json
with open(os.path.join(ICON_DIR, "icon.json")) as f:
    spec = json.load(f)

# Extract gradient stops and orientation
gradient = spec["fill"]["linear-gradient"]
# gradient = ["srgb:0.33017,0.91396,0.91008,1.00000", "srgb:0.40926,0.19236,0.78039,1.00000"]
import re
def parse_color(s):
    m = re.match(r"(srgb|extended-srgb):([0-9.\-]+),([0-9.\-]+),([0-9.\-]+),([0-9.\-]+)", s)
    if not m: return None
    return tuple(float(x) for x in m.groups()[1:])

stops = [parse_color(s) for s in gradient]
orient = spec["fill"]["orientation"]
# start = (0.5, 0)  end = (0.5, 0.7)  vertical 0->0.7 of canvas
start = (orient["start"]["x"], orient["start"]["y"])
end = (orient["stop"]["x"], orient["stop"]["y"])

CANVAS = 1024

# 2. Render gradient background
def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))

def gradient_color(t):
    t = max(0.0, min(1.0, t))
    # 2 stops only (would generalize if more)
    return lerp(stops[0], stops[1], t)

bg = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
px = bg.load()
sx, sy = start
ex, ey = end
# Compute gradient axis: t goes 0 at start point, 1 at end point, projected
# onto the line. For the simple case start.y=0, end.y=0.7, treat t = (y - sy*1024) / ((ey-sy)*1024)
# But more general: project (px - start) onto (end - start)
p0 = (sx * CANVAS, sy * CANVAS)
p1 = (ex * CANVAS, ey * CANVAS)
dx = p1[0] - p0[0]
dy = p1[1] - p0[1]
length_sq = dx*dx + dy*dy

for y in range(CANVAS):
    for x in range(CANVAS):
        vx = x - p0[0]
        vy = y - p0[1]
        t = (vx*dx + vy*dy) / length_sq if length_sq > 0 else 0.0
        r, g, b, a = gradient_color(t)
        px[x, y] = (int(r * 255), int(g * 255), int(b * 255), int(a * 255))

bg.save("/tmp/iconrender/bg.png")
print(f"[1/4] background gradient saved: /tmp/iconrender/bg.png")

# 3. Render each SVG via qlmanage at high res
def render_svg_via_qlmanage(svg_path, out_png, size):
    subprocess.run(
        ["qlmanage", "-t", "-s", str(size), "-o", RENDER_DIR, svg_path],
        check=True, capture_output=True
    )
    generated = os.path.join(RENDER_DIR, os.path.basename(svg_path) + ".png")
    if os.path.exists(generated):
        return generated
    raise RuntimeError(f"qlmanage did not produce {generated}")

def recolor(img_path, target_rgba):
    img = Image.open(img_path).convert("RGBA")
    pixels = img.load()
    w, h = img.size
    tr, tg, tb, ta = target_rgba
    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            # if pixel is opaque (or partially) and not transparent, recolor to target
            if a > 0:
                # preserve alpha, replace RGB
                pixels[x, y] = (tr, tg, tb, a)
    return img

# 4. Composite each layer
# Icon composer coordinate system: 1024x1024 canvas. layer.scale is a multiplier.
# We interpret: render the SVG at its natural aspect at a large base size, then
# apply scale, then translate (translation = center of the layer in canvas coords).
# Then apply outer group scale around canvas center.

group = spec["groups"][0]
group_scale = group["position"].get("scale", 1.0)
group_translation = group["position"].get("translation-in-points", [0, 0])

# Step A: render each SVG at a large base size, recolor, and place.
# We'll composite the final result at 1024x1024.

composited = bg.copy()

for layer in group["layers"]:
    name = layer["name"]
    image_name = layer["image-name"]
    fill = layer["fill"]["solid"]
    scale = layer["position"].get("scale", 1.0)
    translation = layer["position"].get("translation-in-points", [0, 0])

    color = parse_color(fill)
    if color is None:
        print(f"  ! unparseable fill for {name}: {fill}")
        continue
    tr, tg, tb, ta = (int(c * 255) for c in color)

    svg_path = os.path.join(ASSETS, image_name)
    # Render at 4096 (high enough for clean placement)
    rendered_path = render_svg_via_qlmanage(svg_path, None, 4096)
    layer_img = recolor(rendered_path, (tr, tg, tb, 255))
    # Move alpha from layer's alpha (which we kept) to fill alpha
    # Apply layer fill alpha by multiplying
    if ta < 255:
        pixels = layer_img.load()
        for y in range(layer_img.size[1]):
            for x in range(layer_img.size[0]):
                r, g, b, a = pixels[x, y]
                pixels[x, y] = (r, g, b, int(a * ta / 255))

    # Determine the SVG's natural aspect ratio from the path viewBox
    # We can read viewBox from the SVG file
    import xml.etree.ElementTree as ET
    tree = ET.parse(svg_path)
    root = tree.getroot()
    vb = root.attrib.get("viewBox", "0 0 100 100").split()
    vb_w, vb_h = float(vb[2]), float(vb[3])

    # The qlmanage render is at size 4096 of the viewBox. So the rendered image is
    # 4096 * vb_w / max(vb_w,vb_h) by 4096 * vb_h / max(vb_w,vb_h). Actually qlmanage
    # fits the SVG into a 4096x4096 box preserving aspect. The rendered image size
    # tells us the actual aspect.
    rw, rh = layer_img.size
    aspect = rw / rh  # = vb_w / vb_h

    # We want to place this layer at the canvas (1024) with its rendered size
    # scaled by `scale` in icon-composer units. icon-composer's `scale=7` means
    # the SVG is shown at 7 * (its natural unit). We need to determine the
    # natural unit. Icon composer treats the SVG as 100x100 by default if no
    # explicit canvas. Let's assume the SVG's viewBox is its natural unit;
    # scale=7 means it's 7 * viewBox. For 1024 canvas, a translation in
    # canvas-points suggests the canvas is 1024 wide.
    #
    # Practical: place each layer so that its center is at (tx, ty) on the
    # 1024x1024 canvas, with on-canvas size = (svg_viewbox_max_dim) * scale.
    # This is a reasonable approximation; visual iteration may be needed.
    tx_canvas = translation[0]
    ty_canvas = translation[1]

    on_canvas_w = max(vb_w, vb_h) * scale
    on_canvas_h = (vb_h / vb_w) * on_canvas_w if vb_w > 0 else on_canvas_w

    # Resize layer to on_canvas_w x on_canvas_h
    target_w = int(on_canvas_w)
    target_h = int(on_canvas_h)
    layer_resized = layer_img.resize((target_w, target_h), Image.LANCZOS)

    # Paste centered at (tx, ty) on the 1024 canvas
    paste_x = int(tx_canvas - target_w / 2)
    paste_y = int(ty_canvas - target_h / 2)

    composited.alpha_composite(layer_resized, (paste_x, paste_y))
    print(f"  - {name}: viewBox {vb_w}x{vb_h}, scale {scale}, translate {translation}, on-canvas {target_w}x{target_h}, paste ({paste_x},{paste_y})")

# 5. Apply outer group scale 0.9 around canvas center (512, 512).
# The shrunk group leaves empty borders; fill those with the original gradient
# background (rather than transparent) so the icon has a full canvas.
if group_scale != 1.0:
    print(f"[group] applying group scale {group_scale} around canvas center")
    new_size = int(CANVAS * group_scale)
    composited_scaled = composited.resize((new_size, new_size), Image.LANCZOS)
    paste = ((CANVAS - new_size) // 2, (CANVAS - new_size) // 2)
    # Re-create the gradient as the base, then composite the scaled group on top
    final = bg.copy()  # bg is the full gradient
    final.alpha_composite(composited_scaled, paste)
    composited = final

# Save
composited.save(OUT_PNG)
print(f"[done] {OUT_PNG}")
