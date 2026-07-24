#!/usr/bin/env python3
"""Build a multi-resolution Windows icon from the project PNG asset."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parent
DEFAULT_SOURCE = ROOT / "assets/palworld-server-operations.png"
DEFAULT_OUTPUT = ROOT / "assets/palworld-server-operations.ico"
ICON_SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def build_icon(source: Path, output: Path) -> None:
    with Image.open(source) as image:
        rgba = image.convert("RGBA")
        if min(rgba.size) < 128:
            raise ValueError(f"icon source is too small for a Windows icon: {rgba.size}")
        # Clipboard images may lose a few rows even when their intended canvas
        # is square. Preserve the complete artwork and normalize only the canvas.
        if rgba.size != (256, 256):
            rgba = rgba.resize((256, 256), Image.Resampling.LANCZOS)
        output.parent.mkdir(parents=True, exist_ok=True)
        rgba.save(output, format="ICO", sizes=[(size, size) for size in ICON_SIZES])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    build_icon(args.source.resolve(), args.output.resolve())
    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
