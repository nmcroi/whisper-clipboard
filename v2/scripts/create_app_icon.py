#!/usr/bin/env python3
"""Generates the Whisper Clipboard v2 app icon.

Motif: a yellow ring with a yellow rounded square centered inside it (a
stop/record glyph), on a near-black background — matching the app's dark
theme (Theme.swift: #0E0E10 background, #FFD60A accent).

Renders a full-bleed 1024x1024 PNG master (macOS 26 masks the icon into its
rounded-rect canvas itself, so no rounding is baked in here), then builds an
.iconset and compiles it to AppIcon.icns via `iconutil`.

Usage:
    python3 scripts/create_app_icon.py
    # -> WhisperClipboard/Resources/AppIcon.icns

Requires Pillow (`pip install pillow`) and macOS `iconutil` (preinstalled).
"""
from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

# Theme.swift tokens.
BG = (0x0E, 0x0E, 0x10)
BG_LIFT = (0x1C, 0x1C, 0x20)  # subtle radial lift toward center
YELLOW = (0xFF, 0xD6, 0x0A)

SIZE = 1024
SUPERSAMPLE = 4  # render big, downsample for clean anti-aliasing
CANVAS = SIZE * SUPERSAMPLE


def radial_background(size: int) -> Image.Image:
    """Near-black background with a very subtle radial lift toward the center."""
    img = Image.new("RGB", (size, size), BG)
    px = img.load()
    cx, cy = size / 2, size / 2
    max_dist = math.hypot(cx, cy)
    # Sample on a coarse grid and let resize smooth it — full-resolution
    # per-pixel loops on a 4096x4096 canvas are needlessly slow.
    grid = 64
    small = Image.new("RGB", (grid, grid))
    spx = small.load()
    for gy in range(grid):
        for gx in range(grid):
            x = (gx + 0.5) / grid * size
            y = (gy + 0.5) / grid * size
            dist = math.hypot(x - cx, y - cy) / max_dist
            t = max(0.0, 1.0 - dist * 1.35)  # falls off well before the edges
            t = t * t  # ease the lift so it stays subtle
            r = int(BG[0] + (BG_LIFT[0] - BG[0]) * t)
            g = int(BG[1] + (BG_LIFT[1] - BG[1]) * t)
            b = int(BG[2] + (BG_LIFT[2] - BG[2]) * t)
            spx[gx, gy] = (r, g, b)
    img = small.resize((size, size), Image.BICUBIC)
    return img


def draw_motif(img: Image.Image) -> None:
    size = img.size[0]
    draw = ImageDraw.Draw(img)
    cx = cy = size / 2

    # Ring: ~62% diameter, stroke ~7% of width.
    ring_diameter = size * 0.62
    ring_radius = ring_diameter / 2
    stroke = size * 0.07
    bbox = [cx - ring_radius, cy - ring_radius, cx + ring_radius, cy + ring_radius]
    draw.ellipse(bbox, outline=YELLOW, width=int(stroke))

    # Centered rounded square: ~26% of width, inside the ring.
    square_side = size * 0.26
    half = square_side / 2
    corner_radius = square_side * 0.28
    sq_bbox = [cx - half, cy - half, cx + half, cy + half]
    draw.rounded_rectangle(sq_bbox, radius=corner_radius, fill=YELLOW)


def render_master(path: Path) -> None:
    img = radial_background(CANVAS)
    draw_motif(img)
    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    # A whisper of sharpening after the big downsample keeps ring/square
    # edges crisp instead of slightly soft.
    img = img.filter(ImageFilter.UnsharpMask(radius=2, percent=60, threshold=2))
    img.save(path, "PNG")


ICONSET_SIZES = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]


def build_iconset(master_path: Path, iconset_dir: Path) -> None:
    if iconset_dir.exists():
        for f in iconset_dir.glob("*.png"):
            f.unlink()
    iconset_dir.mkdir(parents=True, exist_ok=True)

    master = Image.open(master_path).convert("RGB")
    for base, scale in ICONSET_SIZES:
        px = base * scale
        resized = master.resize((px, px), Image.LANCZOS)
        suffix = f"icon_{base}x{base}" + ("@2x" if scale == 2 else "")
        resized.save(iconset_dir / f"{suffix}.png", "PNG")


def compile_icns(iconset_dir: Path, icns_path: Path) -> None:
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)],
        check=True,
    )


def main() -> None:
    v2_root = Path(__file__).resolve().parent.parent
    build_dir = v2_root / "scripts" / ".icon-build"
    build_dir.mkdir(parents=True, exist_ok=True)

    master_path = build_dir / "app-icon-1024.png"
    iconset_dir = build_dir / "AppIcon.iconset"
    icns_path = v2_root / "WhisperClipboard" / "Resources" / "AppIcon.icns"

    print(f"Rendering master → {master_path}")
    render_master(master_path)

    print(f"Building iconset → {iconset_dir}")
    build_iconset(master_path, iconset_dir)

    print(f"Compiling icns → {icns_path}")
    icns_path.parent.mkdir(parents=True, exist_ok=True)
    compile_icns(iconset_dir, icns_path)

    print("Done.")


if __name__ == "__main__":
    sys.exit(main())
