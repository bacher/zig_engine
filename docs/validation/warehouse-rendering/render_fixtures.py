#!/usr/bin/env python3
"""Assemble production GPU readbacks exported by the packed renderer tests.

Requires Pillow. Usage: python3 render_fixtures.py /tmp/warehouse-packed-render
"""
import argparse
from pathlib import Path

from PIL import Image, ImageDraw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("readbacks", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    names = [
        "cube_oblique", "road_oblique", "cargo_pallet_oblique",
        "marker_oblique", "stopped_oblique", "packaging_front",
        "packaging_inside", "packaging_top", "pallet_top", "cargo_pallet_top",
    ]
    for suffix, title in [("", "coverage"), ("-content", "content")]:
        if not (args.readbacks / f"{names[0]}-finite{suffix}.ppm").exists():
            continue
        canvas = Image.new("RGB", (1400, 610), (238, 240, 244))
        draw = ImageDraw.Draw(canvas)
        for i, name in enumerate(names):
            image = Image.open(args.readbacks / f"{name}-finite{suffix}.ppm")
            image = image.resize((256, 256), Image.Resampling.NEAREST)
            x, y = i % 5 * 280 + 12, i // 5 * 305 + 34
            canvas.paste(image, (x, y))
            draw.text((x, y - 24), name.replace("stopped", "disabled column").replace("_", " "), fill=(20, 25, 30))
        output = args.output / f"packed-{title}.png"
        canvas.save(output)
        print(output)


if __name__ == "__main__":
    main()
