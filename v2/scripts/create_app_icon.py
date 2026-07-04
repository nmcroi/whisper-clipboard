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

    python3 scripts/create_app_icon.py --ios
    # -> WhisperClipboardiOS/.../AppIcon.appiconset/AppIcon-1024.png (full-bleed)

The `--ios` mode reuses the exact same full-bleed master render. iOS masks the
icon into its own rounded rect and rejects any alpha at the edges, so we write a
single flattened, opaque 1024×1024 RGB PNG (no pre-rounded corners) straight
into the appiconset. A single-size universal 1024 icon is a valid asset for
iOS 17+ (Xcode fills every derived size from it).

Requires Pillow (`pip install pillow`) and macOS `iconutil` (preinstalled).
"""
from __future__ import annotations

import argparse
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


# iOS AppIcon.appiconset: single-size universal 1024 icon (valid for iOS 17+).
IOS_ICON_FILENAME = "AppIcon-1024.png"
IOS_CONTENTS_JSON = """{
  "images" : [
    {
      "filename" : "%s",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""" % IOS_ICON_FILENAME


def write_ios_icon(master_path: Path, appiconset_dir: Path) -> None:
    """Writes the full-bleed 1024 PNG + Contents.json into the iOS appiconset.

    iOS applies its own rounded-rect mask and rejects alpha at the edges, so the
    master (already opaque, full-bleed RGB) is flattened onto an opaque canvas
    and saved without an alpha channel.
    """
    appiconset_dir.mkdir(parents=True, exist_ok=True)

    master = Image.open(master_path).convert("RGB")
    if master.size != (SIZE, SIZE):
        master = master.resize((SIZE, SIZE), Image.LANCZOS)
    # Belt-and-suspenders: composite onto an opaque black background so no stray
    # alpha survives, then save as pure RGB (no alpha channel at all).
    canvas = Image.new("RGB", (SIZE, SIZE), BG)
    canvas.paste(master, (0, 0))
    canvas.save(appiconset_dir / IOS_ICON_FILENAME, "PNG")

    (appiconset_dir / "Contents.json").write_text(IOS_CONTENTS_JSON)


def build_macos(v2_root: Path, master_path: Path, build_dir: Path) -> None:
    iconset_dir = build_dir / "AppIcon.iconset"
    icns_path = v2_root / "WhisperClipboard" / "Resources" / "AppIcon.icns"

    print(f"Building iconset → {iconset_dir}")
    build_iconset(master_path, iconset_dir)

    print(f"Compiling icns → {icns_path}")
    icns_path.parent.mkdir(parents=True, exist_ok=True)
    compile_icns(iconset_dir, icns_path)


def build_ios(v2_root: Path, master_path: Path) -> None:
    appiconset_dir = (
        v2_root / "WhisperClipboardiOS" / "Resources" / "Assets.xcassets"
        / "AppIcon.appiconset"
    )
    print(f"Writing iOS full-bleed icon → {appiconset_dir / IOS_ICON_FILENAME}")
    write_ios_icon(master_path, appiconset_dir)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Whisper Clipboard app icons.")
    parser.add_argument(
        "--ios",
        action="store_true",
        help="Also write the full-bleed iOS icon into the iOS AppIcon.appiconset.",
    )
    parser.add_argument(
        "--ios-only",
        action="store_true",
        help="Only write the iOS icon (skip the macOS .icns).",
    )
    args = parser.parse_args()

    v2_root = Path(__file__).resolve().parent.parent
    build_dir = v2_root / "scripts" / ".icon-build"
    build_dir.mkdir(parents=True, exist_ok=True)

    master_path = build_dir / "app-icon-1024.png"

    print(f"Rendering master → {master_path}")
    render_master(master_path)

    if not args.ios_only:
        build_macos(v2_root, master_path, build_dir)
    if args.ios or args.ios_only:
        build_ios(v2_root, master_path)

    print("Done.")


if __name__ == "__main__":
    sys.exit(main())
