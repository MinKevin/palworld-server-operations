#!/usr/bin/env python3
"""Discover Palworld backups and safely replace the active world payload."""

from __future__ import annotations

import os
import re
import hashlib
import json
import shutil
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any


GAME_DIR = Path(os.getenv("DATA_DIR", "/palworld")) / "server"
SAVEGAMES_ROOT = GAME_DIR / "Pal/Saved/SaveGames/0"
GAME_USER_SETTINGS = GAME_DIR / "Pal/Saved/Config/LinuxServer/GameUserSettings.ini"
PLAYERS_DIRECTORY = "Players"
CORE_PAYLOAD_NAMES = ("LevelMeta.sav", "Level.sav")
# Kept for callers that need the minimum portable world payload.  Backup and
# restore operations use payload_names() so optional game files such as
# WorldOption.sav are preserved without recursively copying the game's backup
# directory.
PAYLOAD_NAMES = (PLAYERS_DIRECTORY, *CORE_PAYLOAD_NAMES)
EXCLUDED_PAYLOAD_NAMES = {"backup"}
TRANSACTION_PREFIXES = (".restore-",)
COMMITTED_RESTORE_PREFIX = ".restore-committed-"
MIN_RESTORE_RESERVE_BYTES = 64 * 1024 * 1024
WORLD_GUID_RE = re.compile(r"^[0-9A-Fa-f]{32}$")
BACKUP_NAME_RE = re.compile(
    r"^(?P<deleted>deleted_)?(?P<timestamp>\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2})(?:-(?P<suffix>\d{2}))?$"
)


def validate_backup_name(name: str) -> re.Match[str]:
    match = BACKUP_NAME_RE.fullmatch(name) if isinstance(name, str) else None
    if match is None:
        raise ValueError("backup name must use YYYY.MM.DD-HH.MM.SS or deleted_YYYY.MM.DD-HH.MM.SS")
    return match


def _assert_no_symlinks(path: Path) -> None:
    if path.is_symlink():
        raise ValueError(f"symbolic links are not allowed in world data: {path}")
    if path.is_dir():
        for child in path.rglob("*"):
            if child.is_symlink():
                raise ValueError(f"symbolic links are not allowed in world data: {child}")


def payload_names(path: Path) -> tuple[str, ...]:
    """Return every live world item, excluding backups and transaction state."""
    names: list[str] = []
    for child in path.iterdir():
        if child.name in EXCLUDED_PAYLOAD_NAMES or child.name.startswith(TRANSACTION_PREFIXES):
            continue
        names.append(child.name)
    return tuple(sorted(names, key=lambda value: (value != PLAYERS_DIRECTORY, value.lower(), value)))


def validate_payload(path: Path) -> None:
    players = path / "Players"
    level_meta = path / "LevelMeta.sav"
    level = path / "Level.sav"
    if not level_meta.is_file() or not level.is_file():
        raise FileNotFoundError(
            f"world payload is incomplete: {path} (LevelMeta.sav and Level.sav required)"
        )
    # A new world has no Players directory until the first player joins. Treat
    # that as an empty player set, while still rejecting an invalid file/symlink.
    if players.exists() or players.is_symlink():
        if players.is_symlink() or not players.is_dir():
            raise ValueError(f"Players must be a regular directory when present: {players}")
        _assert_no_symlinks(players)
    for name in payload_names(path):
        _assert_no_symlinks(path / name)


def payload_statistics(path: Path) -> tuple[int, int]:
    validate_payload(path)
    file_count = 0
    size_bytes = 0
    for name in payload_names(path):
        item = path / name
        if item.is_file():
            file_count += 1
            size_bytes += item.stat().st_size
            continue
        for child in item.rglob("*"):
            if child.is_file():
                file_count += 1
                size_bytes += child.stat().st_size
    return file_count, size_bytes


def payload_manifest(path: Path) -> dict[str, tuple[int, str]]:
    """Return a content manifest used to verify restore copies byte-for-byte."""
    validate_payload(path)
    files: list[Path] = []
    for name in payload_names(path):
        item = path / name
        if item.is_file():
            files.append(item)
        else:
            files.extend(sorted(child for child in item.rglob("*") if child.is_file()))

    manifest: dict[str, tuple[int, str]] = {}
    for item in files:
        digest = hashlib.sha256()
        with item.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        manifest[item.relative_to(path).as_posix()] = (item.stat().st_size, digest.hexdigest())
    return manifest


def _configured_world_guid(settings_file: Path | None) -> str | None:
    if settings_file is None or not settings_file.is_file():
        return None
    try:
        content = settings_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    match = re.search(
        r'(?im)^\s*DedicatedServerName\s*=\s*"?([0-9A-Fa-f]{32})"?\s*$',
        content,
    )
    return match.group(1).upper() if match else None


def reported_world_guid(info: dict[str, Any] | None) -> str | None:
    """Extract Pocketpair's worldGuid field without depending on JSON key casing."""
    if not info:
        return None
    for key, value in info.items():
        if (
            key.lower().replace("_", "") == "worldguid"
            and isinstance(value, str)
            and WORLD_GUID_RE.fullmatch(value)
        ):
            return value.upper()
    return None


def discover_world_directory(
    savegames_root: Path | None = None,
    preferred_guid: str | None = None,
    settings_file: Path | None = None,
) -> Path:
    root = savegames_root or SAVEGAMES_ROOT
    if not root.is_dir():
        raise FileNotFoundError(f"SaveGames root is unavailable: {root}")

    if preferred_guid:
        preferred_guid = preferred_guid.strip().upper()
        if not WORLD_GUID_RE.fullmatch(preferred_guid):
            raise ValueError(f"invalid Palworld world GUID: {preferred_guid}")

    candidates: list[Path] = []
    for child in root.iterdir():
        if (
            not child.is_dir()
            or child.is_symlink()
            or not WORLD_GUID_RE.fullmatch(child.name)
        ):
            continue
        try:
            validate_payload(child)
        except (FileNotFoundError, ValueError, OSError):
            continue
        candidates.append(child)

    candidate_by_guid = {path.name.upper(): path for path in candidates}
    if preferred_guid:
        if preferred_guid in candidate_by_guid:
            return candidate_by_guid[preferred_guid]
        raise FileNotFoundError(
            f"active Palworld world {preferred_guid} is unavailable or incomplete below {root}"
        )

    effective_settings = settings_file
    if effective_settings is None and savegames_root is None:
        effective_settings = GAME_USER_SETTINGS
    configured_guid = _configured_world_guid(effective_settings)
    if configured_guid and configured_guid in candidate_by_guid:
        return candidate_by_guid[configured_guid]

    if not candidates:
        raise FileNotFoundError(f"no complete Palworld world was found below {root}")
    if len(candidates) > 1:
        names = ", ".join(sorted(path.name for path in candidates))
        raise RuntimeError(f"multiple Palworld worlds were found; refusing to guess: {names}")
    return candidates[0]


def backup_root(world_directory: Path) -> Path:
    return world_directory / "backup/world"


def safe_backup_root(world_directory: Path) -> Path:
    if world_directory.is_symlink():
        raise ValueError(f"symbolic world directories are not allowed: {world_directory}")
    backup_directory_path = world_directory / "backup"
    root = backup_root(world_directory)
    for path in (backup_directory_path, root):
        if path.is_symlink():
            raise ValueError(f"symbolic backup directories are not allowed: {path}")
    return root


def backup_directory(world_directory: Path, name: str) -> Path:
    validate_backup_name(name)
    root = safe_backup_root(world_directory)
    candidate = root / name
    if candidate.parent != root:
        raise ValueError("backup path escaped the world backup directory")
    if candidate.is_symlink():
        raise ValueError(f"symbolic backup directories are not allowed: {candidate}")
    validate_payload(candidate)
    return candidate


def list_world_backups(
    savegames_root: Path | None = None,
    preferred_guid: str | None = None,
    settings_file: Path | None = None,
) -> dict[str, Any]:
    world = discover_world_directory(savegames_root, preferred_guid, settings_file)
    root = safe_backup_root(world)
    backups: list[dict[str, Any]] = []
    if root.is_dir():
        for child in root.iterdir():
            if not child.is_dir() or child.is_symlink():
                continue
            match = BACKUP_NAME_RE.fullmatch(child.name)
            if match is None:
                continue
            try:
                file_count, size_bytes = payload_statistics(child)
            except (FileNotFoundError, ValueError, OSError):
                continue
            timestamp = datetime.strptime(match.group("timestamp"), "%Y.%m.%d-%H.%M.%S")
            backups.append(
                {
                    "name": child.name,
                    "kind": "pre-restore" if match.group("deleted") else "world-backup",
                    "created_at": timestamp.isoformat(timespec="seconds"),
                    "file_count": file_count,
                    "size_bytes": size_bytes,
                }
            )
    backups.sort(key=lambda item: (item["created_at"], item["name"]), reverse=True)
    return {
        "world_guid": world.name,
        "backup_root": str(root),
        "backups": backups,
    }


def copy_payload(source: Path, destination: Path) -> None:
    validate_payload(source)
    source_manifest = payload_manifest(source)
    destination.mkdir(parents=True, exist_ok=False)
    for name in payload_names(source):
        item = source / name
        target = destination / name
        if item.is_dir():
            shutil.copytree(item, target)
        else:
            shutil.copy2(item, target)
    if not (destination / PLAYERS_DIRECTORY).exists():
        # Restore always installs a canonical empty directory. This ensures an
        # empty backup removes players from the current world instead of keeping
        # stale player saves.
        (destination / PLAYERS_DIRECTORY).mkdir()
    destination_manifest = payload_manifest(destination)
    if source_manifest != destination_manifest:
        raise IOError(
            "copied world verification failed: source and destination SHA-256 manifests differ"
        )


def ensure_restore_disk_space(world_directory: Path, selected_backup: Path) -> dict[str, int]:
    """Fail before shutdown if snapshot plus staging space is not safely available."""
    _current_files, current_bytes = payload_statistics(world_directory)
    _backup_files, backup_bytes = payload_statistics(selected_backup)
    copy_bytes = current_bytes + backup_bytes
    reserve_bytes = max(MIN_RESTORE_RESERVE_BYTES, copy_bytes // 10)
    required_bytes = copy_bytes + reserve_bytes
    free_bytes = shutil.disk_usage(world_directory).free
    if free_bytes < required_bytes:
        raise OSError(
            "insufficient free space for safe restore: "
            f"free={free_bytes}, required={required_bytes} "
            f"(copies={copy_bytes}, reserve={reserve_bytes})"
        )
    return {
        "current_bytes": current_bytes,
        "backup_bytes": backup_bytes,
        "copy_bytes": copy_bytes,
        "reserve_bytes": reserve_bytes,
        "required_bytes": required_bytes,
        "free_bytes": free_bytes,
    }


def create_deleted_snapshot(
    world_directory: Path,
    now: datetime | None = None,
) -> Path:
    validate_payload(world_directory)
    root = safe_backup_root(world_directory)
    root.mkdir(parents=True, exist_ok=True)
    safe_backup_root(world_directory)
    timestamp = (now or datetime.now().astimezone()).strftime("%Y.%m.%d-%H.%M.%S")
    target = root / f"deleted_{timestamp}"
    suffix = 1
    while target.exists():
        target = root / f"deleted_{timestamp}-{suffix:02d}"
        suffix += 1
    temporary = root / f".deleted-{uuid.uuid4().hex}"
    try:
        copy_payload(world_directory, temporary)
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)
    return target


def stage_backup(world_directory: Path, name: str) -> Path:
    source = backup_directory(world_directory, name)
    root = safe_backup_root(world_directory)
    temporary = root / f".restore-stage-{uuid.uuid4().hex}"
    try:
        copy_payload(source, temporary)
        return temporary
    except Exception:
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)
        raise


def _remove_path(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def recover_interrupted_restores(savegames_root: Path | None = None) -> list[str]:
    root = savegames_root or SAVEGAMES_ROOT
    recovered: list[str] = []
    if not root.is_dir():
        return recovered
    for world in (
        path
        for path in root.iterdir()
        if path.is_dir()
        and not path.is_symlink()
        and WORLD_GUID_RE.fullmatch(path.name)
    ):
        old_directories = sorted(world.glob(".restore-old-*"))
        for old_payload in old_directories:
            # The old directory is the commit marker. If it survived a
            # process/container interruption, restore the complete old
            # payload rather than guessing whether optional new files were
            # all installed. Keep the marker until validation succeeds so a
            # failed recovery can safely resume on the next startup.
            old_names = set(payload_names(old_payload))
            current_names = set(payload_names(world))
            state_path = old_payload / ".restore-state.json"
            state: dict[str, Any] = {}
            if state_path.is_file() and not state_path.is_symlink():
                try:
                    state = json.loads(state_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError, TypeError):
                    state = {}
            original_names = {
                str(name) for name in state.get("old_names", []) if isinstance(name, str)
            }
            installed_names = {
                str(name) for name in state.get("new_names", []) if isinstance(name, str)
            }
            for name in sorted(current_names | old_names):
                current = world / name
                previous = old_payload / name
                if not previous.exists():
                    # A previous rollback may already have restored an old
                    # item. A new-only optional item must be removed.
                    if (
                        name in installed_names
                        and name not in original_names
                        and (current.exists() or current.is_symlink())
                    ):
                        _remove_path(current)
                    continue
                if current.exists() or current.is_symlink():
                    _remove_path(current)
                os.replace(previous, current)
            validate_payload(world)
            recovered.append(str(world))
            if old_payload.exists():
                shutil.rmtree(old_payload)
        # A validated new payload is committed by atomically renaming its old
        # rollback marker before cleanup. An interruption while deleting that
        # renamed directory must never be mistaken for an incomplete swap and
        # roll only part of the old payload back over the new world.
        for committed_payload in sorted(world.glob(f"{COMMITTED_RESTORE_PREFIX}*")):
            _remove_path(committed_payload)
        world_backup_root = safe_backup_root(world)
        if world_backup_root.is_dir():
            for temporary in (
                *world_backup_root.glob(".restore-stage-*"),
                *world_backup_root.glob(".deleted-*"),
            ):
                if temporary.is_dir():
                    shutil.rmtree(temporary, ignore_errors=True)
    return recovered


def replace_world_payload(world_directory: Path, staged_payload: Path) -> None:
    validate_payload(world_directory)
    validate_payload(staged_payload)
    old_payload = world_directory / f".restore-old-{uuid.uuid4().hex}"
    committed_payload = world_directory / f"{COMMITTED_RESTORE_PREFIX}{uuid.uuid4().hex}"
    old_payload.mkdir()
    moved_old: list[str] = []
    installed_new: list[str] = []
    replacement_complete = False
    rollback_complete = False
    try:
        old_names = payload_names(world_directory)
        new_names = payload_names(staged_payload)
        (old_payload / ".restore-state.json").write_text(
            json.dumps(
                {"version": 1, "old_names": list(old_names), "new_names": list(new_names)},
                ensure_ascii=False,
                sort_keys=True,
            )
            + "\n",
            encoding="utf-8",
        )
        for name in old_names:
            source = world_directory / name
            os.replace(source, old_payload / name)
            moved_old.append(name)
        for name in new_names:
            os.replace(staged_payload / name, world_directory / name)
            installed_new.append(name)
        validate_payload(world_directory)
        # This rename is the transaction commit point. Before it, startup
        # recovery rolls the complete old payload back. After it, startup keeps
        # the already validated new payload and only removes cleanup residue.
        os.replace(old_payload, committed_payload)
        replacement_complete = True
    except Exception as original_error:
        rollback_errors: list[str] = []
        for name in reversed(installed_new):
            try:
                _remove_path(world_directory / name)
            except OSError as error:
                rollback_errors.append(f"remove new {name}: {error}")
        for name in reversed(moved_old):
            source = old_payload / name
            if not source.exists():
                continue
            try:
                current = world_directory / name
                if current.exists() or current.is_symlink():
                    _remove_path(current)
                os.replace(source, current)
            except OSError as error:
                rollback_errors.append(f"restore old {name}: {error}")
        if not rollback_errors:
            validate_payload(world_directory)
            rollback_complete = True
            raise
        raise RuntimeError(
            f"world replacement failed ({original_error}); partial rollback preserved at "
            f"{old_payload}: {'; '.join(rollback_errors)}"
        ) from original_error
    finally:
        if staged_payload.exists():
            shutil.rmtree(staged_payload, ignore_errors=True)
        if old_payload.exists() and rollback_complete:
            shutil.rmtree(old_payload, ignore_errors=True)
        if committed_payload.exists() and replacement_complete:
            shutil.rmtree(committed_payload, ignore_errors=True)
