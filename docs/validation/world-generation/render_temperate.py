#!/usr/bin/env python3
"""Render generation-map's actual temperate exports with Pillow only.

Example:
  python3 render_temperate.py /private/tmp/validation/overview.ppm \
      --output /private/tmp/validation/temperate-terrain.png

Reads PREFIX.temperate.{json,height.pgm,forest.pgm}; never samples or synthesizes
terrain. Isometric mesh vertices are a stated subset of the actual PGM samples.
"""

import argparse
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


BACKGROUND = "#f7f5ef"
INK = "#302f2b"
MUTED = "#69685f"
ORANGE = "#c76b29"
BLUE = "#397fa2"
FOREST = "#39784f"
CLASS_NAMES = ["Flatland", "Rolling hills", "Hilly terrain"]
COS30 = math.sqrt(3) / 2


def font(size):
    for candidate in [
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ]:
        try:
            return ImageFont.truetype(candidate, size)
        except OSError:
            pass
    return ImageFont.load_default(size=size)


def span_label(blocks):
    return f"{blocks:,} m" if blocks < 1000 else f"{blocks / 1000:.2f} km"


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def height_color(height, sea, color_range):
    if height < sea:
        return (65, 113, 146)
    t = max(0, min(1, (height - sea) / color_range))
    return mix((231, 223, 192), (128, 101, 80), t)


def shaded(color, slope_x, slope_y):
    # Light uses physical block gradients, never screen-space exaggeration.
    nx, ny, nz = -slope_x, -slope_y, 1.0
    norm = math.sqrt(nx * nx + ny * ny + nz * nz)
    light = (-0.45 * nx - 0.55 * ny + 0.704 * nz) / norm
    multiplier = 0.68 + 0.40 * max(0, light)
    return tuple(max(0, min(255, round(v * multiplier))) for v in color)


def load_exports(prefix):
    meta_path = Path(str(prefix) + ".temperate.json")
    meta = json.loads(meta_path.read_text())
    # Pillow's PGM decoder rescales 16-bit maxval=world_depth-1 to 65535.
    # Read the exported bytes directly so a stored height of 520 stays 520.
    magic, dimensions, maximum, pixels = Path(str(prefix) + ".temperate.height.pgm").read_bytes().split(b"\n", 3)
    if magic != b"P5":
        raise ValueError("Expected binary actual-height PGM")
    dimensions = tuple(map(int, dimensions.split()))
    maximum = int(maximum)
    bytes_per_pixel = 2 if maximum > 255 else 1
    if len(pixels) != math.prod(dimensions) * bytes_per_pixel:
        raise ValueError("Truncated height PGM")
    heights = Image.frombytes("I;16B" if bytes_per_pixel == 2 else "L", dimensions, pixels).convert("I")
    forest = Image.open(str(prefix) + ".temperate.forest.pgm")
    forest.load()
    side = meta["top_down_tile_pixels"]
    expected = (side * len(meta["tiles"]), side)
    if heights.size != expected or forest.size != expected:
        raise ValueError("PGM dimensions disagree with metadata")
    tiles = []
    for index, info in enumerate(meta["tiles"]):
        crop = (index * side, 0, (index + 1) * side, side)
        tile_heights = heights.crop(crop)
        tile_forest = forest.crop(crop)
        if info["center"] is not None:
            if tile_heights.getextrema() != (info["min_height"], info["max_height"]):
                raise ValueError("Actual PGM height range disagrees with metadata")
            if tile_forest.tobytes().count(255) != info["sampled_forest_columns"]:
                raise ValueError("Actual forest mask disagrees with metadata")
            for axis in ["horizontal_profile", "vertical_profile"]:
                profile = info[axis]
                if len(profile["terrain_heights"]) != info["extent_blocks"]:
                    raise ValueError("Expected one-block profiles spanning each window")
                arrays = [v for k, v in profile.items() if k not in ["origin", "step_blocks"]]
                if len({len(v) for v in arrays}) != 1:
                    raise ValueError("Profile columns have different lengths")
                if "weights_q16" in profile and not all(sum(w) == 65536 for w in profile["weights_q16"]):
                    raise ValueError("Invalid selector weights")
        tiles.append((info, tile_heights, tile_forest))
    return meta, tiles


def draw_isometric(canvas, box, heights, info, sea, color_range, ve, base_y):
    x0, y0, width, height = box
    draw = ImageDraw.Draw(canvas)
    if info["center"] is None:
        draw.text((x0 + 100, y0 + 150), "No suitable sample", font=font(20), fill=MUTED)
        return
    side = heights.width
    extent = info["extent_blocks"]
    block_step = extent / side
    ground_scale = (width - 24) / (2 * COS30 * extent)
    origin_x = x0 + width / 2
    origin_y = y0 + base_y

    def project(wx, wy, z):
        return (
            origin_x + (wx - wy) * COS30 * ground_scale,
            origin_y + (wx + wy) * 0.5 * ground_scale - (z - sea) * ground_scale * ve,
        )

    # The outlined plane is sea level, not a fabricated terrain surface.
    plane = [project(0, 0, sea), project(extent, 0, sea), project(extent, extent, sea), project(0, extent, sea)]
    draw.polygon(plane, fill="#e8e5dc", outline="#b8b7ad")
    indices = list(range(0, side, 4))
    if indices[-1] != side - 1:
        indices.append(side - 1)
    cells = [(ix, iy) for iy in range(len(indices) - 1) for ix in range(len(indices) - 1)]
    cells.sort(key=lambda pair: pair[0] + pair[1])
    for ix, iy in cells:
        ax, bx = indices[ix : ix + 2]
        ay, by = indices[iy : iy + 2]
        z00, z10 = heights.getpixel((ax, ay)), heights.getpixel((bx, ay))
        z11, z01 = heights.getpixel((bx, by)), heights.getpixel((ax, by))
        corners = [(ax, ay, z00), (bx, ay, z10), (bx, by, z11), (ax, by, z01)]
        points = [project((x + 0.5) * block_step, (y + 0.5) * block_step, z) for x, y, z in corners]
        slope_x = ((z10 + z11) - (z00 + z01)) / (2 * (bx - ax) * block_step)
        slope_y = ((z01 + z11) - (z00 + z10)) / (2 * (by - ay) * block_step)
        average = (z00 + z10 + z11 + z01) / 4
        draw.polygon(points, fill=shaded(height_color(average, sea, color_range), slope_x, slope_y))


def forest_view(heights, forest, extent, sea, color_range):
    side = heights.width
    step = extent / side
    result = Image.new("RGB", heights.size)
    pixels = result.load()
    for y in range(side):
        for x in range(side):
            height = heights.getpixel((x, y))
            xa, xb = max(0, x - 1), min(side - 1, x + 1)
            ya, yb = max(0, y - 1), min(side - 1, y + 1)
            dx = (heights.getpixel((xb, y)) - heights.getpixel((xa, y))) / max(1, (xb - xa) * step)
            dy = (heights.getpixel((x, yb)) - heights.getpixel((x, ya))) / max(1, (yb - ya) * step)
            base = height_color(height, sea, color_range)
            if forest.getpixel((x, y)) == 255:
                base = mix((49, 111, 65), (102, 143, 82), max(0, min(1, (height - sea) / color_range)))
            pixels[x, y] = shaded(base, dx, dy)
    return result


def draw_profiles(canvas, box, info, sea, zmax):
    draw = ImageDraw.Draw(canvas)
    x, y, width, height = box
    if info["center"] is None:
        return
    hs = info["horizontal_profile"]["terrain_heights"]
    vs = info["vertical_profile"]["terrain_heights"]
    x_span = len(hs) - 1
    x0, x1 = x + 35, x + width - 8
    y0, y1 = y, y + height
    graph_width = x1 - x0
    for offset in range(0, zmax + 1, max(5, math.ceil(zmax / 4 / 5) * 5)):
        yy = y1 - offset / zmax * height
        draw.line((x0, yy, x1, yy), fill="#d9d6cc", width=1)
        draw.text((x, yy - 8), f"+{offset}", font=font(13), fill=MUTED)
    draw.line((x0, y0, x0, y1, x1, y1), fill="#a9aa9f", width=1)
    for axis, color in [("horizontal_profile", ORANGE), ("vertical_profile", BLUE)]:
        profile = info[axis]
        points = [(x0 + i / x_span * graph_width, y1 - (z - sea) / zmax * height) for i, z in enumerate(profile["terrain_heights"])]
        draw.line(points, fill=color, width=2)
    # Every one-block vegetation observation participates in each forest bar.
    for row, axis in enumerate(["horizontal_profile", "vertical_profile"]):
        yy = y1 + 19 + row * 7
        draw.line((x0, yy, x1, yy), fill="#d8d3c3", width=4)
        profile = info[axis]
        for i, vegetation in enumerate(profile["vegetation"]):
            if vegetation == "forest":
                xx = x0 + i / x_span * graph_width
                draw.line((xx, yy, x0 + min(x_span, i + 1) / x_span * graph_width, yy), fill=FOREST, width=4)
    draw.text((x0, y1 + 36), "0", font=font(13), fill=MUTED)
    end = span_label(x_span)
    draw.text((x1 - draw.textlength(end, font=font(13)), y1 + 36), end, font=font(13), fill=MUTED)
    max_step = max(abs(b - a) for values in [hs, vs] for a, b in zip(values, values[1:]))
    ve = (height / zmax) / (graph_width / x_span)
    draw.text((x0, y1 + 58), f"H relief {max(hs)-min(hs)} m · V relief {max(vs)-min(vs)} m · max step {max_step} m", font=font(13), fill=INK)
    draw.text((x0, y1 + 78), f"Profile vertical exaggeration {ve:.1f}×", font=font(13), fill=MUTED)


def render(prefix, output, requested_ve):
    meta, tiles = load_exports(prefix)
    depth = meta["dimensions_blocks"][2]
    sea = depth // 2
    expected_relief = 80 * min(depth, 1024) / 1024
    observed = max([max(t[0][axis]["terrain_heights"]) - sea for t in tiles if t[0]["center"] is not None for axis in ["horizontal_profile", "vertical_profile"]] or [0])
    color_range = max(10, math.ceil(max(expected_relief, observed) / 10) * 10)
    width, height = 1500, 1300
    canvas = Image.new("RGB", (width, height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)

    def text(x, y, message, size=17, color=INK):
        draw.text((x, y), message, font=font(size), fill=color)

    text(30, 20, "Temperate landforms: actual terrain and forest", 29)
    text(30, 62, f'Seed {meta["seed"]} · World {meta["dimensions_blocks"][0]:,} × {meta["dimensions_blocks"][1]:,} × {depth:,} blocks · Sea level {sea} · 1 block = 1 m', 17)
    text(30, 88, "Window spans are labeled. Heights, vegetation and profiles come from the final generated world.", 16, MUTED)
    column_x = [30, 525, 1020]
    column_width = 450
    iso_y, iso_height = 153, 340
    ground_span_pixels = (column_width - 24) / COS30 / 2
    max_q = max([(t[0]["max_height"] - sea) * (column_width - 24) / (2 * COS30 * t[0]["extent_blocks"]) for t in tiles if t[0]["center"] is not None] or [1])
    ve = min(requested_ve, max(0.1, (iso_height - 24 - ground_span_pixels) / max(1, max_q)))
    base_y = 12 + max_q * ve
    for index, ((info, heights, forest), x) in enumerate(zip(tiles, column_x)):
        text(x, 122, CLASS_NAMES[index], 23)
        draw_isometric(canvas, (x, iso_y, column_width, iso_height), heights, info, sea, color_range, ve, base_y)
        extent = info["extent_blocks"]
        text(x, 500, f"Window {span_label(extent)} × {span_label(extent)}", 18)
        if info["center"] is None:
            text(x, 529, "Unavailable; no fabricated replacement", 15, MUTED)
            continue
        target = info["sampled_landforms"][index] / info["sampled_columns"] * 100
        text(x, 529, f'Actual heights {info["min_height"]}–{info["max_height"]} · relief {info["max_height"]-info["min_height"]} m · {target:.1f}% target class', 15)
        center = info["center"]
        text(x, 553, f'Center ({center[0]:,}, {center[1]:,}) · {extent / heights.width:g} m / raw pixel', 14, MUTED)
        view = forest_view(heights, forest, extent, sea, color_range)
        view = view.resize((256, 256), Image.Resampling.NEAREST)
        map_x, map_y = x + 96, 608
        canvas.paste(view, (map_x, map_y))
        draw.rectangle((map_x, map_y, map_x + 255, map_y + 255), outline="#bbb7aa")
        mid = 127.5
        draw.line((map_x, map_y + mid, map_x + 255, map_y + mid), fill=ORANGE, width=2)
        draw.line((map_x + mid, map_y, map_x + mid, map_y + 255), fill=BLUE, width=2)
        text(map_x + 260, map_y + 119, "H", 14, ORANGE)
        text(map_x + 133, map_y + 5, "V", 14, BLUE)
        forest_percent = info["sampled_forest_columns"] / info["sampled_columns"] * 100
        climate_min = info.get("min_temperate_terrain", 0) / 65535 * 100
        climate_max = info.get("max_temperate_terrain", 0) / 65535 * 100
        text(x, 880, f'Forest {forest_percent:.1f}% · water {info["sampled_water_columns"]:,} · mountain {info["sampled_mountain_columns"]:,}', 15)
        text(x, 904, f'Climate influence {climate_min:.0f}–{climate_max:.0f}% · {info["sampled_columns"]:,} actual samples', 14, MUTED)
        draw_profiles(canvas, (x, 986, column_width, 180), info, sea, color_range)

    text(30, 578, "Top-down forest overlay", 20)
    text(800, 578, "Green = actual forest · orange H / blue V = exact midlines", 15, MUTED)
    text(30, 946, "Actual one-block profiles", 20)
    text(400, 950, "Shared vertical axis: metres above sea level · H orange / V blue · green bars = forest along each midline", 15, MUTED)
    text(30, 1263, f'Surfaces: shared height colors +0–{color_range} m, {ve:.1f}× vertical exaggeration; actual PGM vertices every 4 raw pixels. Profiles draw every block.', 14, MUTED)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, optimize=True)
    print(f"Wrote {output} ({width}×{height}); surface VE={ve:.3f}; shared profile range sea+0..{color_range}")
    print(f"Sources: {prefix}.temperate.{{json,height.pgm,forest.pgm}}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prefix", type=Path, help="Original generation-map output path, e.g. overview.ppm")
    parser.add_argument("--output", type=Path, help="PNG output path (default: beside PREFIX)")
    parser.add_argument("--surface-ve", type=float, default=6.0, help="Requested surface vertical exaggeration; reduced to avoid clipping")
    args = parser.parse_args()
    if args.surface_ve <= 0:
        parser.error("--surface-ve must be positive")
    render(args.prefix, args.output or args.prefix.parent / "temperate-terrain.png", args.surface_ve)


if __name__ == "__main__":
    main()
