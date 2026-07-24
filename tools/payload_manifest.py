#!/usr/bin/env python3
"""Single source of truth for Linux installer and SSH operation payloads."""

from __future__ import annotations

from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]


def _install_files() -> list[tuple[Path, str]]:
    values: list[tuple[Path, str]] = []
    for path in sorted((PROJECT_DIR / "install").rglob("*")):
        if not path.is_file() or "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        destination = Path("install") / path.relative_to(PROJECT_DIR / "install")
        values.append((path, destination.as_posix()))
    return values


def _scaffold_files() -> list[tuple[Path, str]]:
    return [
        (PROJECT_DIR / "LICENSE", "scaffold/LICENSE"),
        (PROJECT_DIR / "operate/pal", "scaffold/operate/pal"),
        (PROJECT_DIR / "config/kr/common.env", "scaffold/config/kr/common.env"),
        (
            PROJECT_DIR / "config/kr/server.template.env",
            "scaffold/config/kr/server.template.env",
        ),
        (PROJECT_DIR / "config/en/common.env", "scaffold/config/en/common.env"),
        (
            PROJECT_DIR / "config/en/server.template.env",
            "scaffold/config/en/server.template.env",
        ),
    ]


def linux_installer_files() -> list[tuple[Path, str]]:
    return _install_files() + _scaffold_files()


def ssh_operation_files(operation: str) -> list[tuple[Path, str]]:
    """Return the minimum practical host tools for an SSH operation family."""
    operation = operation.lower()
    install_root = PROJECT_DIR / "install"
    if operation == "setup":
        return _install_files() + _scaffold_files()
    if operation == "test":
        names = (
            "lib.sh",
            "test",
            "scripts/doctor.py",
            "scripts/instances.py",
            "scripts/policy.py",
        )
        return [(install_root / name, f"install/{name}") for name in names]
    if operation == "manage":
        values = [
            (install_root / "Dockerfile", "install/Dockerfile"),
            (install_root / "lib.sh", "install/lib.sh"),
            (install_root / "manager", "install/manager"),
        ]
        values.extend(
            (path, f"install/scripts/{path.name}")
            for path in sorted((install_root / "scripts").glob("*.py"))
        )
        return values
    raise ValueError(f"unknown SSH operation payload: {operation}")


def executable_mode(source: Path) -> int:
    return 0o755 if source.name in {
        "manager",
        "scaffold.sh",
        "setup.sh",
        "test",
        "lib.sh",
        "pal",
    } else 0o644
