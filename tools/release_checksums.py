#!/usr/bin/env python3
"""Write or verify SHA-256 hashes for the public release artifacts."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "SHA256SUMS.txt"
ARTIFACTS = (
    (
        ROOT / "windows" / "Palworld Server Operations - Admin.exe",
        "Palworld.Server.Operations.-.Admin.exe",
    ),
    (
        ROOT / "windows" / "Palworld Server Operations - Client.exe",
        "Palworld.Server.Operations.-.Client.exe",
    ),
    (ROOT / "PalworldServerInstaller.run", "PalworldServerInstaller.run"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_lines() -> list[str]:
    missing = [
        str(path.relative_to(ROOT))
        for path, _release_name in ARTIFACTS
        if not path.is_file()
    ]
    if missing:
        raise SystemExit("Missing release artifacts: " + ", ".join(missing))
    return [
        f"{sha256(path)}  {release_name}"
        for path, release_name in ARTIFACTS
    ]


def write_manifest(lines: list[str]) -> None:
    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"Updated {MANIFEST.relative_to(ROOT)}")


def verify_manifest(lines: list[str]) -> None:
    if not MANIFEST.is_file():
        raise SystemExit("SHA256SUMS.txt is missing. Run with --write after building.")
    actual = MANIFEST.read_text(encoding="utf-8").splitlines()
    if actual != lines:
        expected = "\n".join(lines)
        current = "\n".join(actual)
        raise SystemExit(
            "SHA256SUMS.txt does not match the release artifacts. "
            "Run tools/release_checksums.py --write after building.\n"
            f"Expected:\n{expected}\nCurrent:\n{current}"
        )
    print("Verified SHA256SUMS.txt against all release artifacts")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write",
        action="store_true",
        help="replace SHA256SUMS.txt with hashes of the current release artifacts",
    )
    args = parser.parse_args()
    lines = expected_lines()
    if args.write:
        write_manifest(lines)
    else:
        verify_manifest(lines)


if __name__ == "__main__":
    main()
