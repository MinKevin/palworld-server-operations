#!/usr/bin/env python3
"""Discover and atomically import an existing Palworld Saved directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

import instances
import manager


WORLD_GUID_RE = re.compile(r"^[0-9A-Fa-f]{32}$")
SERVER_NAME_RE = re.compile(r"^server[1-9][0-9]*$")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
DEDICATED_SERVER_RE = re.compile(
    r'(?im)^\s*DedicatedServerName\s*=\s*"?([0-9A-Fa-f]{32})"?\s*$'
)
PORT_ARGUMENT_RE = re.compile(r"(?:^|\s)-port(?:=|\s+)([0-9]{1,5})(?:\s|$)", re.I)
PALSERVER_EXECUTABLE_RE = re.compile(
    r"^PalServer(?:\.sh|-Linux(?:-Test)?(?:-Cmd)?)?$",
    re.I,
)
MIN_IMPORT_RESERVE_BYTES = 256 * 1024 * 1024
MAX_DISCOVERED_WORLDS = 200
SOURCE_PORT_RELEASE_TIMEOUT_SECONDS = 30.0
UNMAPPED_IMPORT_HEADER = (
    "# ==================== Imported settings not in this template ===================="
)
PROJECT_TEMPLATE_EXTENSION_HEADER = (
    "# ==================== Preserved project template extensions ===================="
)
SKIPPED_SCAN_DIRECTORIES = {
    ".cache",
    ".git",
    ".npm",
    "node_modules",
    "proc",
    "sys",
}


def json_print(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True))


def resolved_directory(value: str, label: str) -> Path:
    path = Path(value).expanduser().resolve(strict=True)
    if not path.is_dir() or path.is_symlink():
        raise ValueError(f"{label} must be a regular directory: {path}")
    if path == Path(path.anchor):
        raise ValueError(f"{label} cannot be a filesystem root: {path}")
    return path


def ensure_direct_child(parent: Path, child: Path, label: str) -> None:
    if child.parent != parent:
        raise ValueError(f"{label} escaped its expected parent: {child}")


def reject_symlinks(root: Path) -> None:
    if root.is_symlink():
        raise ValueError(f"symbolic links are not allowed in imported data: {root}")
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in (*directories, *files):
            path = current_path / name
            if path.is_symlink():
                raise ValueError(f"symbolic links are not allowed in imported data: {path}")


def tree_manifest(root: Path) -> dict[str, tuple[int, str]]:
    reject_symlinks(root)
    result: dict[str, tuple[int, str]] = {}
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if not path.is_file():
            continue
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        result[path.relative_to(root).as_posix()] = (path.stat().st_size, digest.hexdigest())
    return result


def manifest_size(manifest: dict[str, tuple[int, str]]) -> int:
    return sum(size for size, _digest in manifest.values())


def read_text(path: Path | None) -> str:
    if path is None or not path.is_file() or path.is_symlink():
        return ""
    return path.read_text(encoding="utf-8-sig", errors="replace")


def config_file(saved: Path, name: str) -> Path | None:
    candidates = (
        saved / "Config/LinuxServer" / name,
        saved / "Config/WindowsServer" / name,
    )
    return next((path for path in candidates if path.is_file() and not path.is_symlink()), None)


def parse_option_settings(content: str) -> dict[str, str]:
    if not content.strip():
        return {}
    try:
        _prefix, body, _suffix = manager.find_option_settings(content)
        return dict(manager.parse_settings_body(body))
    except ValueError:
        return {}


def decode_ini_value(value: str) -> str:
    normalized = value.strip()
    if len(normalized) >= 2 and normalized[0] == normalized[-1] == '"':
        body = normalized[1:-1]
        return body.replace(r'\"', '"').replace(r"\\", "\\")
    if not normalized:
        # Preserve an unquoted empty Unreal value (Key=) distinctly from "".
        return "raw:"
    if normalized.startswith(("(", "[", "{")):
        return f"raw:{normalized}"
    if (
        normalized
        and normalized.lower() not in {"true", "false"}
        and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", normalized)
    ):
        # Bare identifiers are Unreal enum/literal values, not quoted strings.
        return f"raw:{normalized}"
    return normalized


def template_env_keys(content: str) -> set[str]:
    """Return active and documented/commented ENV assignment keys."""
    keys: set[str] = set()
    for line in content.splitlines():
        match = re.match(
            r"^\s*(?:#\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*=",
            line,
        )
        if match:
            keys.add(match.group(1))
    return keys


def template_env_assignments(content: str) -> dict[str, tuple[bool, str]]:
    """Return the effective active/commented assignment for each template key."""
    assignments: dict[str, tuple[bool, str]] = {}
    for line in content.splitlines():
        match = re.match(
            r"^\s*(?P<comment>#\s*)?(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=(?P<value>.*)$",
            line,
        )
        if not match:
            continue
        key = match.group("key")
        active = match.group("comment") is None
        # An active assignment takes precedence over a documented example.
        # If a malformed template repeats an active key, retain its last value,
        # matching the way ENV files are otherwise interpreted.
        if active or key not in assignments:
            assignments[key] = (active, match.group("value"))
    return assignments


def merge_current_import_template(
    project_content: str,
    current_content: str,
) -> str:
    """Use the current layout while preserving the project's template choices.

    Existing projects deliberately retain ``server.template.env`` across Setup
    runs.  Import still needs the current documented setting layout, so generate
    the target ENV from the bundled template and overlay every active/commented
    assignment from the project's retained template.  Project-only extension
    keys are preserved separately rather than discarded.
    """
    project_assignments = template_env_assignments(project_content)
    current_keys = template_env_keys(current_content)
    merged_lines: list[str] = []
    for line in current_content.splitlines():
        match = re.match(
            r"^\s*(?:#\s*)?(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=.*$",
            line,
        )
        if not match or match.group("key") not in project_assignments:
            merged_lines.append(line)
            continue
        key = match.group("key")
        active, value = project_assignments[key]
        merged_lines.append(f"{'' if active else '# '}{key}={value}")

    extension_keys: list[str] = []
    seen: set[str] = set()
    for line in project_content.splitlines():
        match = re.match(
            r"^\s*(?:#\s*)?(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*=.*$",
            line,
        )
        if not match:
            continue
        key = match.group("key")
        if key not in current_keys and key not in seen:
            extension_keys.append(key)
            seen.add(key)
    if extension_keys:
        merged_lines.extend(
            [
                "",
                PROJECT_TEMPLATE_EXTENSION_HEADER,
                "# Retained from this managed project's existing server template.",
            ]
        )
        for key in extension_keys:
            active, value = project_assignments[key]
            merged_lines.append(f"{'' if active else '# '}{key}={value}")
    return "\n".join(merged_lines).rstrip() + "\n"


def current_import_template(project_template: Path) -> str:
    """Load the bundled current template, falling back to the project copy."""
    language = os.getenv("PALWORLD_ENV_LANGUAGE", "en").strip().lower()
    if language not in {"en", "ko"}:
        language = "en"
    template_language = "kr" if language == "ko" else "en"
    candidates: list[Path] = []
    explicit = os.getenv("PALWORLD_SERVER_TEMPLATE_SOURCE", "").strip()
    if explicit:
        candidates.append(Path(explicit))
    install_directory = os.getenv("PALWORLD_INSTALL_DIR", "").strip()
    if install_directory:
        candidates.append(
            Path(install_directory).parent
            / "scaffold"
            / "config"
            / template_language
            / "server.template.env"
        )
    payload_root = Path(__file__).resolve().parents[2]
    candidates.extend(
        [
            payload_root
            / "scaffold"
            / "config"
            / template_language
            / "server.template.env",
            payload_root / "config" / template_language / "server.template.env",
        ]
    )
    for candidate in candidates:
        if candidate.is_file() and not candidate.is_symlink():
            return candidate.read_text(encoding="utf-8-sig")
    return project_template.read_text(encoding="utf-8-sig")


def sync_project_server_template(project: Path) -> dict[str, Any]:
    """Merge the bundled kr/en template into an existing managed project.

    Assignment state and values from the retained project template win.  A
    content-addressed backup keeps custom comments recoverable before the
    standardized current layout is written atomically.
    """
    template = project / "config/server.template.env"
    if not template.is_file() or template.is_symlink():
        raise FileNotFoundError(f"server template is unavailable: {template}")
    existing = template.read_text(encoding="utf-8-sig")
    current = current_import_template(template)
    merged = merge_current_import_template(existing, current)
    if existing.replace("\r\n", "\n").rstrip() == merged.rstrip():
        return {"updated": False, "path": str(template), "backup": ""}

    existing_stat = template.stat()
    digest = hashlib.sha256(existing.encode("utf-8")).hexdigest()[:16]
    runtime_directory = project / "runtime"
    if runtime_directory.is_symlink():
        raise ValueError(f"runtime directory must not be a symlink: {runtime_directory}")
    runtime_was_created = not runtime_directory.exists()
    runtime_directory.mkdir(parents=True, exist_ok=True)
    backup_directory = runtime_directory / "template-backups"
    if backup_directory.is_symlink():
        raise ValueError(
            f"template backup directory must not be a symlink: {backup_directory}"
        )
    backup_directory.mkdir(parents=True, exist_ok=True)
    backup_directory.chmod(0o700)
    if hasattr(os, "chown"):
        try:
            if runtime_was_created:
                os.chown(
                    runtime_directory,
                    existing_stat.st_uid,
                    existing_stat.st_gid,
                )
            os.chown(
                backup_directory,
                existing_stat.st_uid,
                existing_stat.st_gid,
            )
        except (AttributeError, PermissionError):
            pass
    backup = backup_directory / f"server.template.env.{digest}.bak"
    if backup.is_symlink():
        raise ValueError(f"template backup must not be a symlink: {backup}")
    if backup.exists():
        if not backup.is_file():
            raise ValueError(f"template backup must be a regular file: {backup}")
        retained = backup.read_text(encoding="utf-8-sig")
        if retained.replace("\r\n", "\n").rstrip() != existing.replace(
            "\r\n", "\n"
        ).rstrip():
            raise ValueError(f"template backup content does not match its name: {backup}")
    else:
        instances.write_atomic(backup, existing)
        backup.chmod(0o600)
        if hasattr(os, "chown"):
            try:
                os.chown(backup, existing_stat.st_uid, existing_stat.st_gid)
            except (AttributeError, PermissionError):
                pass
    instances.write_atomic(template, merged)
    return {"updated": True, "path": str(template), "backup": str(backup)}


def set_template_env_value(content: str, key: str, value: str) -> tuple[str, bool]:
    """Replace an active or documented/commented template assignment in place."""
    replacement = f"{key}={value}"
    active = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
    if active.search(content):
        return active.sub(lambda _match: replacement, content, count=1), True
    documented = re.compile(rf"(?m)^\s*#\s*{re.escape(key)}\s*=.*$")
    if documented.search(content):
        return documented.sub(lambda _match: replacement, content, count=1), True
    return content, False


def append_unmapped_import_settings(
    content: str,
    settings: list[tuple[str, str]],
) -> str:
    if not settings:
        return content
    lines = [
        UNMAPPED_IMPORT_HEADER,
        "# Preserved from PalWorldSettings.ini because this project version does not document them yet.",
        "# Review these values after upgrading Palworld Server Operations.",
    ]
    lines.extend(f"PAL_SETTING_{key}={value}" for key, value in settings)
    return content.rstrip() + "\n\n" + "\n".join(lines) + "\n"


def setting_string(settings: dict[str, str], key: str) -> str:
    value = decode_ini_value(settings.get(key, ""))
    return value[4:] if value.startswith("raw:") else value


def parse_port(value: str | int | None) -> int | None:
    text = "" if value is None else str(value).strip()
    return int(text) if text.isdigit() and 1 <= int(text) <= 65535 else None


def is_palserver_process(arguments: list[str]) -> bool:
    """Match an actual PalServer executable argument, not a path mentioning PalServer."""
    return any(PALSERVER_EXECUTABLE_RE.fullmatch(Path(argument).name) for argument in arguments)


def configured_world_guid(saved: Path) -> str | None:
    content = read_text(config_file(saved, "GameUserSettings.ini"))
    match = DEDICATED_SERVER_RE.search(content)
    return match.group(1).upper() if match else None


def validate_world(saved: Path, guid: str) -> Path:
    guid = guid.upper()
    if not WORLD_GUID_RE.fullmatch(guid):
        raise ValueError(f"invalid Palworld world GUID: {guid!r}")
    world = saved / "SaveGames/0" / guid
    if not world.is_dir() or world.is_symlink():
        # Linux paths are case-sensitive, but existing servers occasionally use
        # lowercase GUID directory names. Resolve the matching direct child.
        root = saved / "SaveGames/0"
        if root.is_dir() and not root.is_symlink():
            world = next(
                (
                    child
                    for child in root.iterdir()
                    if child.is_dir()
                    and not child.is_symlink()
                    and child.name.upper() == guid
                ),
                world,
            )
    if not (world / "Level.sav").is_file() or not (world / "LevelMeta.sav").is_file():
        raise FileNotFoundError(
            f"selected world is incomplete; Level.sav and LevelMeta.sav are required: {world}"
        )
    reject_symlinks(world)
    return world


def process_records(game_root: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    proc = Path("/proc")
    if not proc.is_dir():
        return records
    expected = str(game_root)
    for item in proc.iterdir():
        if not item.name.isdigit():
            continue
        if int(item.name) == os.getpid():
            continue
        try:
            raw = (item / "cmdline").read_bytes()
            arguments = [part.decode("utf-8", errors="replace") for part in raw.split(b"\0") if part]
            command = " ".join(arguments)
            if not is_palserver_process(arguments):
                continue
            cwd = str((item / "cwd").resolve(strict=True))
        except (FileNotFoundError, PermissionError, OSError):
            continue
        if expected not in command and not (cwd == expected or cwd.startswith(expected + os.sep)):
            continue
        port_match = PORT_ARGUMENT_RE.search(command)
        cgroup = read_text(item / "cgroup")
        service_match = re.search(r"(?m)([A-Za-z0-9_.@-]+\.service)(?:$|/)", cgroup)
        container_match = re.search(r"(?i)(?:docker[-/]|cri-containerd[-/])([0-9a-f]{12,64})", cgroup)
        source_type = "process"
        control_id = item.name
        if container_match:
            source_type = "docker"
            control_id = container_match.group(1)
            try:
                inspected = subprocess.run(
                    ["docker", "inspect", "--format", "{{.Name}}", control_id],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    timeout=10,
                    check=False,
                )
                if inspected.returncode == 0 and inspected.stdout.strip():
                    control_id = inspected.stdout.strip().lstrip("/")
            except (OSError, subprocess.TimeoutExpired):
                pass
        elif service_match:
            source_type = "systemd"
            control_id = service_match.group(1)
        records.append(
            {
                "pid": int(item.name),
                "type": source_type,
                "control_id": control_id,
                "game_port": parse_port(port_match.group(1)) if port_match else None,
                "community_server": "-publiclobby" in arguments,
                "command": command[:1000],
            }
        )
    return records


def docker_records(saved: Path) -> list[dict[str, Any]]:
    """Identify running containers that bind the selected Pal/Saved directory."""
    try:
        result = subprocess.run(
            ["docker", "ps", "--quiet"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if result.returncode != 0:
        return []
    records: list[dict[str, Any]] = []
    saved_resolved = saved.resolve()
    for container_id in result.stdout.split():
        try:
            inspected = subprocess.run(
                ["docker", "inspect", container_id],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=15,
                check=False,
            )
            if inspected.returncode != 0:
                continue
            details = json.loads(inspected.stdout)[0]
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError, IndexError, KeyError):
            continue
        matched = False
        for mount in details.get("Mounts", []):
            source = mount.get("Source")
            destination = str(mount.get("Destination", ""))
            if not source or not destination.endswith("/Pal/Saved"):
                continue
            try:
                matched = Path(source).resolve() == saved_resolved
            except OSError:
                matched = False
            if matched:
                break
        if not matched:
            continue
        config = details.get("Config", {})
        arguments = [*(config.get("Entrypoint") or []), *(config.get("Cmd") or [])]
        command = " ".join(str(value) for value in arguments)
        port_match = PORT_ARGUMENT_RE.search(command)
        bindings = details.get("HostConfig", {}).get("PortBindings", {}) or {}
        if port_match is None:
            udp_ports = sorted(
                int(key.split("/", 1)[0])
                for key in bindings
                if re.fullmatch(r"[0-9]{1,5}/udp", key)
            )
            detected_port = udp_ports[0] if len(udp_ports) == 1 else None
        else:
            detected_port = parse_port(port_match.group(1))
        records.append(
            {
                "pid": int(details.get("State", {}).get("Pid", 0) or 0),
                "type": "docker",
                "control_id": str(details.get("Name", container_id)).lstrip("/"),
                "game_port": detected_port,
                "community_server": "-publiclobby" in arguments,
                "command": command[:1000],
            }
        )
    return records


def runtime_records(saved: Path) -> list[dict[str, Any]]:
    docker = docker_records(saved)
    if docker:
        return docker
    return process_records(saved.parent.parent)


def scan_worlds(root: Path, project: Path | None = None) -> list[dict[str, Any]]:
    project_text = str(project) if project else ""
    rows: list[dict[str, Any]] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        filtered: list[str] = []
        for name in directories:
            candidate = current_path / name
            if candidate.is_symlink() or name in SKIPPED_SCAN_DIRECTORIES:
                continue
            candidate_text = str(candidate)
            if project_text and (candidate_text == project_text or candidate_text.startswith(project_text + os.sep)):
                continue
            filtered.append(name)
        directories[:] = filtered
        if "Level.sav" not in files:
            continue
        world = current_path
        try:
            if (
                not WORLD_GUID_RE.fullmatch(world.name)
                or world.parent.name != "0"
                or world.parent.parent.name != "SaveGames"
                or world.parent.parent.parent.name != "Saved"
                or world.parent.parent.parent.parent.name != "Pal"
            ):
                continue
            saved = world.parents[2]
            validate_world(saved, world.name)
            level = world / "Level.sav"
            settings_path = config_file(saved, "PalWorldSettings.ini")
            source_settings = parse_option_settings(read_text(settings_path))
            rest_port = parse_port(setting_string(source_settings, "RESTAPIPort"))
            game_root = saved.parent.parent
            processes = runtime_records(saved)
            game_ports = sorted(
                {record["game_port"] for record in processes if record.get("game_port") is not None}
            )
            game_port = game_ports[0] if len(game_ports) == 1 else None
            active_guid = configured_world_guid(saved)
            players = world / "Players"
            player_count = (
                len([path for path in players.iterdir() if path.is_file() and not path.is_symlink()])
                if players.is_dir() and not players.is_symlink()
                else 0
            )
            rows.append(
                {
                    "pal_directory": str(saved.parent),
                    "saved_directory": str(saved),
                    "world_directory": str(world),
                    "world_guid": world.name.upper(),
                    "active": active_guid == world.name.upper(),
                    "level_modified_epoch": level.stat().st_mtime,
                    "level_modified_at": datetime.fromtimestamp(level.stat().st_mtime).astimezone().isoformat(
                        timespec="seconds"
                    ),
                    "level_size_bytes": level.stat().st_size,
                    "player_count": player_count,
                    "server_name": setting_string(source_settings, "ServerName"),
                    "game_port": game_port,
                    "rest_api_port": rest_port,
                    "running": bool(processes),
                    "source_type": processes[0]["type"] if len(processes) == 1 else ("multiple" if processes else "unknown"),
                    "control_id": processes[0]["control_id"] if len(processes) == 1 else "",
                    "processes": processes,
                    "world_option_present": (world / "WorldOption.sav").is_file(),
                    "palworld_settings_path": str(settings_path) if settings_path else "",
                }
            )
        except (FileNotFoundError, PermissionError, ValueError, OSError):
            continue
        if len(rows) >= MAX_DISCOVERED_WORLDS:
            break
    rows.sort(key=lambda item: (item["level_modified_epoch"], item["world_guid"]), reverse=True)
    return rows


def common_update_summary(common: dict[str, str]) -> str:
    enabled = common.get("AUTO_UPDATE_ENABLED", "true").strip().lower() in {
        "1",
        "true",
        "yes",
        "y",
        "on",
    }
    state = "Enabled" if enabled else "Disabled"
    interval = common.get("UPDATE_CHECK_INTERVAL", "15m")
    warning = common.get("UPDATE_WARNING_SECONDS", "60s")
    return f"{state} · Every {interval} · Warning {warning}"


def project_port_reservations(
    project: Path,
) -> tuple[dict[int, str], dict[int, str]]:
    """Return ports reserved by managed servers for each transport/role."""
    common = instances.load_env(project / "config/common.env")
    manager_port = instances.parse_port(
        common.get("MANAGER_API_PORT", "18080"), "MANAGER_API_PORT"
    )
    game_reserved: dict[int, str] = {}
    rest_reserved: dict[int, str] = {
        manager_port: f"REST API TCP {manager_port} conflicts with MANAGER_API_PORT"
    }
    for path in sorted((project / "config").glob("server[1-9]*.env")):
        if not SERVER_NAME_RE.fullmatch(path.stem) or path.is_symlink():
            continue
        configured = instances.load_env(path)
        default_game, default_rest = instances.default_ports(path.stem, common)
        configured_game = instances.parse_port(
            configured.get("SERVER_PORT", str(default_game)),
            f"{path.stem}.SERVER_PORT",
        )
        configured_rest = instances.parse_port(
            configured.get("PAL_SETTING_RESTAPIPort", str(default_rest)),
            f"{path.stem}.PAL_SETTING_RESTAPIPort",
        )
        game_reserved[configured_game] = (
            f"game UDP {configured_game} is already assigned to {path.stem}"
        )
        rest_reserved[configured_rest] = (
            f"REST API TCP {configured_rest} is already assigned to {path.stem}"
        )
    return game_reserved, rest_reserved


def project_port_conflicts(
    project: Path,
    game_port: int | None,
    rest_port: int | None,
) -> tuple[list[str], list[str], set[int], set[int]]:
    game_reserved, rest_reserved = project_port_reservations(project)
    game_conflicts: list[str] = []
    rest_conflicts: list[str] = []
    if game_port is not None and game_port in game_reserved:
        game_conflicts.append(game_reserved[game_port])
    if rest_port is not None and rest_port in rest_reserved:
        rest_conflicts.append(rest_reserved[rest_port])
    if game_port is not None and rest_port is not None and game_port == rest_port:
        rest_conflicts.append("game UDP and REST API TCP ports must be different")
    return (
        game_conflicts,
        rest_conflicts,
        set(game_reserved),
        set(rest_reserved),
    )


def validate_project_ports(
    project: Path,
    game_port: int | None,
    rest_port: int | None,
) -> None:
    """Reject conflicts with managed configs before the source is stopped."""
    game_conflicts, rest_conflicts, _game_reserved, _rest_reserved = (
        project_port_conflicts(project, game_port, rest_port)
    )
    conflicts = [*game_conflicts, *rest_conflicts]
    if conflicts:
        raise ValueError("; ".join(conflicts))


def review_item(
    item_id: str,
    status: str,
    source_key: str,
    env_keys: tuple[str, ...],
    value: str,
    description: str,
    *,
    editable: bool = True,
    required: bool = False,
    scope: str = "server.env",
    value_type: str | None = None,
    reserved_values: Iterable[int | str] = (),
) -> dict[str, Any]:
    if status not in {"FAILED", "BLOCKED", "UNMAPPED", "REVIEW", "AUTO"}:
        raise ValueError(f"invalid import review status: {status}")
    normalized = str(value)
    if value_type is None:
        value_type = "boolean" if normalized.lower() in {"true", "false"} else "text"
    return {
        "id": item_id,
        "status": status,
        "source_key": source_key,
        "env_keys": list(env_keys),
        "value": normalized,
        "value_type": value_type,
        "editable": editable,
        "required": required,
        "scope": scope,
        "description": description,
        "reserved_values": [str(value) for value in reserved_values],
    }


def build_target_env(
    project: Path,
    server: str,
    source_settings: dict[str, str],
    *,
    world_guid: str,
    game_port: int | None,
    rest_port: int | None,
    rest_api_expose: bool,
    community_server: bool,
) -> tuple[str, list[dict[str, Any]]]:
    if not SERVER_NAME_RE.fullmatch(server):
        raise ValueError(f"invalid target server name: {server}")
    if not WORLD_GUID_RE.fullmatch(world_guid):
        raise ValueError(f"invalid Palworld world GUID: {world_guid!r}")
    game_conflicts, rest_conflicts, game_reserved, rest_reserved = (
        project_port_conflicts(project, game_port, rest_port)
    )
    template = project / "config/server.template.env"
    if not template.is_file() or template.is_symlink():
        raise FileNotFoundError(f"server template is unavailable: {template}")
    project_template_content = template.read_text(encoding="utf-8-sig")
    content = merge_current_import_template(
        project_template_content,
        current_import_template(template),
    )
    documented_keys = template_env_keys(content)
    invalid_settings: list[tuple[str, str]] = []
    mapped_settings: list[tuple[str, str, bool]] = []
    unmapped_settings: list[tuple[str, str]] = []
    for key, raw_value in source_settings.items():
        if not ENV_KEY_RE.fullmatch(key):
            invalid_settings.append((key, raw_value))
            continue
        decoded = decode_ini_value(raw_value)
        env_key = f"PAL_SETTING_{key}"
        matched = env_key in documented_keys
        mapped_settings.append((key, decoded, matched))
        if matched:
            content, replaced = set_template_env_value(content, env_key, decoded)
            if not replaced:
                raise ValueError(f"known project template key could not be updated: {env_key}")
        else:
            unmapped_settings.append((key, decoded))

    admin_password = setting_string(source_settings, "AdminPassword")
    generated_password = False
    if not admin_password:
        admin_password = secrets.token_urlsafe(24)
        generated_password = True
    values = {
        "SERVER_PORT": "" if game_port is None else str(game_port),
        "PAL_SETTING_PublicPort": "" if game_port is None else str(game_port),
        "PAL_SETTING_RESTAPIPort": "" if rest_port is None else str(rest_port),
        "PAL_SETTING_RESTAPIEnabled": "True",
        "PAL_SETTING_AdminPassword": admin_password,
        "REST_API_EXPOSE": "true" if rest_api_expose else "false",
        "COMMUNITY_SERVER": "true" if community_server else "false",
        "API_ACCESS_TOKEN": secrets.token_urlsafe(32),
    }
    for key, value in values.items():
        content, replaced = set_template_env_value(content, key, value)
        if not replaced:
            raise ValueError(f"server template is missing required import key: {key}")
    content = append_unmapped_import_settings(content, unmapped_settings)
    parsed = instances.load_env(project / "config/common.env")
    generated_values: dict[str, str] = {}
    for line in content.splitlines():
        if not line.strip() or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        generated_values[key.strip()] = value.strip()
    active_window = generated_values.get("ACTIVE_WINDOW", "always")
    restart_times = generated_values.get("RESTART_TIMES", "")
    auto_update_enabled = parsed.get("AUTO_UPDATE_ENABLED", "true").strip().lower() in {
        "1", "true", "yes", "y", "on"
    }
    game_review_problems = (
        ["The game UDP port could not be detected from a running source process."]
        if game_port is None
        else []
    ) + game_conflicts
    rest_review_problems = (
        ["The REST API TCP port could not be read from PalWorldSettings.ini."]
        if rest_port is None
        else []
    ) + rest_conflicts
    review: list[dict[str, Any]] = [
        review_item(
            "game-port",
            "BLOCKED" if game_review_problems else "REVIEW",
            "-port / PublicPort",
            ("SERVER_PORT", "PAL_SETTING_PublicPort"),
            "" if game_port is None else str(game_port),
            " ".join(game_review_problems)
            if game_review_problems
            else "The game UDP port was detected from the selected source process. Its current listener is expected and does not block review; confirm the value before importing.",
            required=True,
            reserved_values=game_reserved,
        ),
        review_item(
            "rest-port",
            "BLOCKED" if rest_review_problems else "REVIEW",
            "RESTAPIPort",
            ("PAL_SETTING_RESTAPIPort",),
            "" if rest_port is None else str(rest_port),
            " ".join(rest_review_problems)
            if rest_review_problems
            else "Confirm the REST API TCP port from PalWorldSettings.ini. Its current source listener does not block review.",
            required=True,
            reserved_values=rest_reserved,
        ),
        review_item(
            "rest-exposure",
            "REVIEW",
            "REST API external access",
            ("REST_API_EXPOSE",),
            "True" if rest_api_expose else "False",
            "True is recommended for these Windows apps. Protect the port with a firewall, VPN, or TLS gateway.",
        ),
        review_item(
            "community-server",
            "REVIEW",
            "-publiclobby",
            ("COMMUNITY_SERVER",),
            "True" if community_server else "False",
            "The detected launch option is used as the initial value.",
        ),
        review_item(
            "rest-api-enabled",
            "REVIEW",
            "RESTAPIEnabled",
            ("PAL_SETTING_RESTAPIEnabled",),
            "True",
            "The integrated management API requires the official Palworld REST API, so this value remains True.",
            editable=False,
        ),
        review_item(
            "active-window",
            "REVIEW",
            "",
            ("ACTIVE_WINDOW",),
            active_window,
            "always runs 24/7. HH:MM-HH:MM limits automatic operation and may cross midnight, for example 14:00-02:00.",
        ),
        review_item(
            "restart-times",
            "REVIEW",
            "",
            ("RESTART_TIMES",),
            restart_times,
            "Scheduled restart times use the timezone in Common Settings. Separate multiple values with commas.",
        ),
        review_item(
            "automatic-updates",
            "REVIEW",
            "AUTO_UPDATE_ENABLED",
            (),
            "True" if auto_update_enabled else "False",
            f"Current Common Settings: {common_update_summary(parsed)}. Fine-tune the interval and warning in Common Settings.",
            editable=False,
            scope="common.env",
        ),
    ]

    special_source_keys = {"PublicPort", "RESTAPIPort", "RESTAPIEnabled"}
    for key, value, matched in mapped_settings:
        if key in special_source_keys:
            continue
        description = (
            "Imported into its known project-template position. Change the value and synchronize it only when needed."
            if matched
            else "This source setting is not present in the current project template. It is preserved in the dedicated template-external settings section."
        )
        if key == "AdminPassword" and generated_password:
            description = "The source administrator password was empty, so a new value was generated."
        review.append(
            review_item(
                f"pal-setting-{key}",
                "AUTO" if matched else "UNMAPPED",
                key,
                (f"PAL_SETTING_{key}",),
                admin_password if key == "AdminPassword" else value,
                description,
            )
        )
    review.extend(
        [
            review_item(
                "world-guid",
                "AUTO",
                "DedicatedServerName",
                (),
                world_guid.upper(),
                "GameUserSettings.ini will point to the selected existing world directory.",
                editable=False,
                scope="GameUserSettings.ini",
            ),
            review_item(
                "api-token",
                "AUTO",
                "",
                ("API_ACCESS_TOKEN",),
                generated_values.get("API_ACCESS_TOKEN", ""),
                "A new project-specific token is generated for the imported server.",
            ),
        ]
    )
    for key, raw_value in invalid_settings:
        review.append(
            review_item(
                f"unmapped-{len(review)}",
                "FAILED",
                key,
                (),
                raw_value,
                "This source key cannot be represented safely as an environment-variable name. Import is blocked to avoid silently dropping it.",
                editable=False,
                scope="unmapped",
            )
        )
    status_order = {"FAILED": 0, "BLOCKED": 1, "UNMAPPED": 2, "REVIEW": 3, "AUTO": 4}
    review.sort(key=lambda item: status_order[item["status"]])
    return content.rstrip() + "\n", review


def patch_world_guid(content: str, guid: str) -> str:
    line = f"DedicatedServerName={guid}"
    if DEDICATED_SERVER_RE.search(content):
        return DEDICATED_SERVER_RE.sub(line, content, count=1).rstrip() + "\n"
    if content.strip():
        return content.rstrip() + "\n" + line + "\n"
    return "[/Script/Pal.PalGameLocalSettings]\n" + line + "\n"


def port_in_use(port: int) -> bool:
    try:
        result = subprocess.run(
            ["ss", "-H", "-lntu"],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    pattern = re.compile(rf"(?:^|[\[\]:.]){port}(?:\s|$)")
    return any(pattern.search(line) for line in result.stdout.splitlines())


def wait_for_ports_released(
    ports: Iterable[int],
    *,
    timeout_seconds: float = SOURCE_PORT_RELEASE_TIMEOUT_SECONDS,
    poll_seconds: float = 0.5,
) -> list[int]:
    """Wait for listeners owned by the stopped source to release their ports."""
    selected = tuple(dict.fromkeys(int(port) for port in ports))
    deadline = time.monotonic() + timeout_seconds
    while True:
        busy = [port for port in selected if port_in_use(port)]
        if not busy or time.monotonic() >= deadline:
            return busy
        time.sleep(poll_seconds)


def stop_source(saved: Path, source_type: str, control_id: str) -> dict[str, Any]:
    processes = runtime_records(saved)
    matching = [record for record in processes if source_type == record["type"] and control_id == str(record["control_id"])]
    if not processes:
        return {"stopped": True, "message": "Source server is already stopped.", "remaining": []}
    if (
        source_type == "docker"
        and matching
        and re.fullmatch(r"[A-Za-z0-9_.-]+", control_id)
    ):
        command = ["docker", "stop", "--time", "120", control_id]
    elif (
        source_type == "systemd"
        and matching
        and re.fullmatch(r"[A-Za-z0-9_.@-]+\.service", control_id)
    ):
        command = ["systemctl", "stop", control_id]
    elif source_type == "process" and control_id.isdigit() and matching:
        os.kill(int(control_id), signal.SIGTERM)
        command = []
    else:
        return {
            "stopped": False,
            "message": "The source process could not be identified safely. Stop it manually, then continue.",
            "remaining": processes,
        }
    if command:
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=150, check=False)
        if result.returncode != 0:
            return {
                "stopped": False,
                "message": (result.stderr or result.stdout or "Graceful stop failed.").strip(),
                "remaining": runtime_records(saved),
            }
    deadline = time.monotonic() + 125
    while time.monotonic() < deadline:
        remaining = runtime_records(saved)
        if not remaining:
            return {"stopped": True, "message": "Source server stopped gracefully.", "remaining": []}
        time.sleep(1)
    return {"stopped": False, "message": "The source server did not stop within 125 seconds.", "remaining": runtime_records(saved)}


def import_saved(
    project: Path,
    source_saved: Path,
    guid: str,
    server: str,
    env_file: Path,
    game_port: int,
    rest_port: int,
) -> dict[str, Any]:
    if getattr(os, "geteuid", lambda: 0)() != 0:
        raise PermissionError("Import commit requires root privileges.")
    if not SERVER_NAME_RE.fullmatch(server):
        raise ValueError(f"invalid target server name: {server}")
    source_saved = resolved_directory(str(source_saved), "source Saved directory")
    world = validate_world(source_saved, guid)
    project = project.resolve(strict=True)
    if source_saved == project or project in source_saved.parents or source_saved in project.parents:
        raise ValueError("source Saved directory and managed project must not contain each other")
    if not env_file.is_file() or env_file.is_symlink():
        raise FileNotFoundError(f"generated target env is unavailable: {env_file}")
    target_values = instances.load_env(env_file)
    target_game_port = instances.parse_port(
        target_values.get("SERVER_PORT", ""), "generated SERVER_PORT"
    )
    target_rest_port = instances.parse_port(
        target_values.get("PAL_SETTING_RESTAPIPort", ""),
        "generated PAL_SETTING_RESTAPIPort",
    )
    if target_game_port != game_port or target_rest_port != rest_port:
        raise ValueError("generated env ports do not match the confirmed import ports")
    if target_values.get("PAL_SETTING_RESTAPIEnabled", "").strip().lower() != "true":
        raise ValueError("generated PAL_SETTING_RESTAPIEnabled must remain True")
    instances.parse_bool(
        target_values.get("REST_API_EXPOSE", ""), "generated REST_API_EXPOSE"
    )
    token = target_values.get("API_ACCESS_TOKEN", "")
    if not instances.ACCESS_TOKEN_RE.fullmatch(token):
        raise ValueError("generated API_ACCESS_TOKEN is missing or invalid")
    validate_project_ports(project, game_port, rest_port)
    if runtime_records(source_saved):
        raise RuntimeError("source server is still running; stop it before continuing")
    busy_ports = wait_for_ports_released((game_port, rest_port))
    if busy_ports:
        raise RuntimeError(
            "the source server stopped, but its ports are still listening after "
            f"{SOURCE_PORT_RELEASE_TIMEOUT_SECONDS:g} seconds: "
            f"{', '.join(str(port) for port in busy_ports)}; "
            "wait for the original process or container network to release them, then retry"
        )
    time.sleep(2)
    first_state = (world / "Level.sav").stat()
    time.sleep(1)
    second_state = (world / "Level.sav").stat()
    if (first_state.st_size, first_state.st_mtime_ns) != (second_state.st_size, second_state.st_mtime_ns):
        raise RuntimeError("Level.sav is still changing; wait for the source server to finish stopping")

    target_config = project / "config" / f"{server}.env"
    target_data = project / "data" / server
    ensure_direct_child(project / "config", target_config, "target config")
    ensure_direct_child(project / "data", target_data, "target data")
    if target_config.exists() or target_data.exists():
        raise FileExistsError(f"target {server} already has config or data; import requires an unused server number")
    if subprocess.run(
        ["docker", "container", "inspect", f"palworld-{server}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode == 0:
        raise FileExistsError(f"target container already exists: palworld-{server}")
    source_manifest = tree_manifest(source_saved)
    source_bytes = manifest_size(source_manifest)
    free_bytes = shutil.disk_usage(project).free
    reserve = max(MIN_IMPORT_RESERVE_BYTES, source_bytes // 10)
    if free_bytes < source_bytes + reserve:
        raise OSError(
            f"insufficient free space for safe import: free={free_bytes}, required={source_bytes + reserve}"
        )

    data_root = project / "data"
    data_root.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{server}.import-", dir=data_root))
    committed = False
    try:
        staged_saved = staging / "saved"
        shutil.copytree(source_saved, staged_saved)
        copied_world = validate_world(staged_saved, guid)
        target_game_user = staged_saved / "Config/LinuxServer/GameUserSettings.ini"
        source_game_user = config_file(staged_saved, "GameUserSettings.ini")
        original_game_user = read_text(source_game_user)
        target_game_user.parent.mkdir(parents=True, exist_ok=True)
        target_game_user.write_text(patch_world_guid(original_game_user, guid.upper()), encoding="utf-8", newline="\n")
        if source_game_user and source_game_user != target_game_user:
            source_game_user.unlink(missing_ok=True)
        (staging / "logs").mkdir()
        staged_manifest = tree_manifest(staged_saved)
        expected_manifest = dict(source_manifest)
        # GameUserSettings.ini is intentionally normalized, so compare every
        # other copied file byte-for-byte and validate this file separately.
        for relative in tuple(expected_manifest):
            if relative.endswith("/GameUserSettings.ini"):
                expected_manifest.pop(relative)
        for relative in tuple(staged_manifest):
            if relative.endswith("/GameUserSettings.ini"):
                staged_manifest.pop(relative)
        if expected_manifest != staged_manifest:
            raise IOError("import copy verification failed: source and staged SHA-256 manifests differ")
        if configured_world_guid(staged_saved) != guid.upper():
            raise IOError("staged GameUserSettings.ini does not select the imported world GUID")
        if not copied_world.is_dir():
            raise IOError("staged world disappeared during import verification")

        config_temporary = project / "config" / f".{server}.env.import-{secrets.token_hex(8)}"
        shutil.copy2(env_file, config_temporary)
        config_temporary.chmod(0o600)
        data_committed = False
        config_committed = False
        try:
            os.replace(staging, target_data)
            data_committed = True
            os.replace(config_temporary, target_config)
            config_committed = True
            committed = True
        except Exception:
            # Remove only paths this transaction successfully moved into place.
            # A concurrent/external creator must never be mistaken for a partial
            # import merely because it appeared after the initial preflight.
            if config_committed and target_config.exists():
                target_config.unlink()
            if data_committed and target_data.exists():
                shutil.rmtree(target_data, ignore_errors=True)
            raise
        finally:
            if config_temporary.exists():
                config_temporary.unlink()

        uid = int(os.getenv("SUDO_UID", str(project.stat().st_uid)))
        gid = int(os.getenv("SUDO_GID", str(project.stat().st_gid)))
        if hasattr(os, "chown"):
            os.chown(target_config, uid, gid)
        metadata_root = project / "backups" / server / "import"
        metadata_root.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().astimezone().strftime("%Y.%m.%d-%H.%M.%S")
        metadata = {
            "version": 1,
            "server": server,
            "source_saved_directory": str(source_saved),
            "world_guid": guid.upper(),
            "file_count": len(source_manifest),
            "size_bytes": source_bytes,
            "game_port": game_port,
            "rest_api_port": rest_port,
            "world_option_preserved": (world / "WorldOption.sav").is_file(),
            "imported_at": datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        (metadata_root / f"{stamp}.json").write_text(
            json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
            newline="\n",
        )
        return metadata
    finally:
        if not committed and staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    subparsers = parser.add_subparsers(dest="command", required=True)
    discover = subparsers.add_parser("discover", allow_abbrev=False)
    discover.add_argument("--root", required=True)
    discover.add_argument("--project")

    inspect = subparsers.add_parser("inspect", allow_abbrev=False)
    inspect.add_argument("--project", required=True)
    inspect.add_argument("--saved", required=True)
    inspect.add_argument("--world-guid", required=True)
    inspect.add_argument("--server", required=True)
    inspect.add_argument("--game-port", type=int)
    inspect.add_argument("--rest-port", type=int)
    inspect.add_argument("--rest-api-expose", choices=("true", "false"), default="true")
    inspect.add_argument("--community-server", choices=("true", "false"), default="false")

    validate_ports = subparsers.add_parser("validate-ports", allow_abbrev=False)
    validate_ports.add_argument("--project", required=True)
    validate_ports.add_argument("--game-port", required=True, type=int)
    validate_ports.add_argument("--rest-port", required=True, type=int)

    stop = subparsers.add_parser("stop", allow_abbrev=False)
    stop.add_argument("--saved", required=True)
    stop.add_argument("--source-type", required=True, choices=("docker", "systemd", "process", "unknown", "multiple"))
    stop.add_argument("--control-id", default="")

    commit = subparsers.add_parser("commit", allow_abbrev=False)
    commit.add_argument("--project", required=True)
    commit.add_argument("--saved", required=True)
    commit.add_argument("--world-guid", required=True)
    commit.add_argument("--server", required=True)
    commit.add_argument("--env-file", required=True)
    commit.add_argument("--game-port", required=True, type=int)
    commit.add_argument("--rest-port", required=True, type=int)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "discover":
        root = resolved_directory(args.root, "scan root")
        project = Path(args.project).expanduser().resolve() if args.project else None
        json_print({"root": str(root), "worlds": scan_worlds(root, project)})
        return 0
    if args.command == "inspect":
        project = resolved_directory(args.project, "managed project")
        template_sync = sync_project_server_template(project)
        saved = resolved_directory(args.saved, "source Saved directory")
        world = validate_world(saved, args.world_guid)
        source_ini_path = config_file(saved, "PalWorldSettings.ini")
        source_ini = read_text(source_ini_path)
        source_settings = parse_option_settings(source_ini)
        if not source_settings:
            raise ValueError("PalWorldSettings.ini does not contain readable OptionSettings")
        rest_port = (
            args.rest_port
            if args.rest_port is not None
            else parse_port(setting_string(source_settings, "RESTAPIPort"))
        )
        game_port = (
            instances.parse_port(args.game_port, "source game port")
            if args.game_port is not None
            else None
        )
        if rest_port is not None:
            rest_port = instances.parse_port(rest_port, "source REST API port")
        target_env, review = build_target_env(
            project,
            args.server,
            source_settings,
            world_guid=world.name.upper(),
            game_port=game_port,
            rest_port=rest_port,
            rest_api_expose=args.rest_api_expose == "true",
            community_server=args.community_server == "true",
        )
        json_print(
            {
                "server": args.server,
                "source_ini_path": str(source_ini_path) if source_ini_path else "",
                "source_ini": source_ini,
                "target_env": target_env,
                "review": review,
                "world_guid": world.name.upper(),
                "world_option_present": (world / "WorldOption.sav").is_file(),
                "game_port": game_port,
                "rest_api_port": rest_port,
                "template_sync": template_sync,
            }
        )
        return 0
    if args.command == "validate-ports":
        project = resolved_directory(args.project, "managed project")
        game_port = instances.parse_port(args.game_port, "source game port")
        rest_port = instances.parse_port(args.rest_port, "source REST API port")
        validate_project_ports(project, game_port, rest_port)
        json_print({"valid": True, "game_port": game_port, "rest_api_port": rest_port})
        return 0
    if args.command == "stop":
        saved = resolved_directory(args.saved, "source Saved directory")
        json_print(stop_source(saved, args.source_type, args.control_id))
        return 0
    if args.command == "commit":
        metadata = import_saved(
            resolved_directory(args.project, "managed project"),
            Path(args.saved),
            args.world_guid,
            args.server,
            Path(args.env_file).resolve(strict=True),
            instances.parse_port(args.game_port, "source game port"),
            instances.parse_port(args.rest_port, "source REST API port"),
        )
        json_print(metadata)
        return 0
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        json_print({"error": str(error), "type": type(error).__name__})
        raise SystemExit(1)
