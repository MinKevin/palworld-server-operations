#!/usr/bin/env python3
"""Safely back up and reset one host-mounted Palworld Saved directory."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any


SERVER_RE = re.compile(r"server[1-9][0-9]*$")
WORLD_GUID_RE = re.compile(r"[0-9A-Fa-f]{32}$")
PALWORLD_UID = int(os.getenv("PALWORLD_UID", "1000"))
PALWORLD_GID = int(os.getenv("PALWORLD_GID", "1000"))
FREE_SPACE_RESERVE = 256 * 1024 * 1024


@dataclass(frozen=True)
class ResetPaths:
    project: Path
    server: str
    container: str
    config: Path
    data: Path
    saved: Path
    logs: Path
    savegames: Path
    backup_root: Path


@dataclass(frozen=True)
class TreeSummary:
    files: int
    bytes: int
    sha256: str


class StorageCommitError(RuntimeError):
    """Raised after the old data directory has started being removed."""

    def __init__(self, backup: Path, message: str) -> None:
        super().__init__(message)
        self.backup = backup


class InstanceLock:
    """Prevent two host-side reset processes from handling one server at once."""

    def __init__(self, paths: ResetPaths) -> None:
        self.path = paths.project / "runtime" / f"reset-{paths.server}.lock"
        self.handle: Any = None

    def __enter__(self) -> "InstanceLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = self.path.open("a+", encoding="utf-8")
        if os.name != "nt":
            import fcntl

            try:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                self.handle.close()
                raise RuntimeError(f"이미 진행 중인 초기화가 있습니다: {self.path}") from error
        self.handle.seek(0)
        self.handle.truncate()
        self.handle.write(f"pid={os.getpid()}\n")
        self.handle.flush()
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        if self.handle is not None:
            self.handle.close()


def log(message: str) -> None:
    print(f"[{datetime.now().astimezone().isoformat(timespec='seconds')}] {message}", flush=True)


def validate_server(server: str) -> str:
    if not SERVER_RE.fullmatch(server):
        raise ValueError(f"서버 이름 형식 오류: {server!r} (예: server1)")
    return server


def _ensure_direct_child(parent: Path, child: Path) -> None:
    if child.parent != parent:
        raise RuntimeError(f"경로 안전 검사 실패: {child}")


def build_paths(project: Path, server: str) -> ResetPaths:
    server = validate_server(server)
    project = project.expanduser().resolve(strict=True)
    if project == Path(project.anchor):
        raise RuntimeError("프로젝트 루트에는 초기화를 실행할 수 없습니다.")

    config_dir = project / "config"
    data_root = project / "data"
    backup_base = project / "backups"
    data = data_root / server
    backup_root = backup_base / server
    _ensure_direct_child(data_root, data)
    _ensure_direct_child(backup_base, backup_root)

    for path in (config_dir, data_root, data):
        if path.is_symlink():
            raise RuntimeError(f"심볼릭 링크 경로에는 초기화를 실행하지 않습니다: {path}")

    config = config_dir / f"{server}.env"
    if not config.is_file() or config.is_symlink():
        raise RuntimeError(f"서버 환경 파일을 찾을 수 없거나 안전하지 않습니다: {config}")
    if not data.is_dir():
        raise RuntimeError(f"서버 데이터 디렉터리를 찾을 수 없습니다: {data}")

    return ResetPaths(
        project=project,
        server=server,
        container=f"palworld-{server}",
        config=config,
        data=data,
        saved=data / "saved",
        logs=data / "logs",
        savegames=data / "saved" / "SaveGames" / "0",
        backup_root=backup_root,
    )


def reject_symlinks(root: Path) -> None:
    if not root.exists():
        return
    if root.is_symlink():
        raise RuntimeError(f"백업 원본에 심볼릭 링크가 있습니다: {root}")
    for current, directory_names, file_names in os.walk(root, followlinks=False):
        current_path = Path(current)
        for name in (*directory_names, *file_names):
            path = current_path / name
            if path.is_symlink():
                raise RuntimeError(f"백업 원본에 심볼릭 링크가 있습니다: {path}")


def _file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def tree_manifest(root: Path) -> dict[str, tuple[int, str]]:
    if not root.exists():
        return {}
    result: dict[str, tuple[int, str]] = {}
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if path.is_symlink():
            raise RuntimeError(f"검증 대상에 심볼릭 링크가 있습니다: {path}")
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            result[relative] = (path.stat().st_size, _file_digest(path))
    return result


def summarize_manifest(manifest: dict[str, tuple[int, str]]) -> TreeSummary:
    aggregate = hashlib.sha256()
    total_bytes = 0
    for relative, (size, digest) in sorted(manifest.items()):
        aggregate.update(relative.encode("utf-8"))
        aggregate.update(b"\0")
        aggregate.update(str(size).encode("ascii"))
        aggregate.update(b"\0")
        aggregate.update(digest.encode("ascii"))
        aggregate.update(b"\n")
        total_bytes += size
    return TreeSummary(len(manifest), total_bytes, aggregate.hexdigest())


def world_guids(savegames: Path) -> list[str]:
    if not savegames.is_dir():
        return []
    return sorted(
        path.name.upper()
        for path in savegames.iterdir()
        if path.is_dir() and not path.is_symlink() and WORLD_GUID_RE.fullmatch(path.name)
    )


def unique_backup_path(root: Path, timestamp: str) -> tuple[Path, Path]:
    base_name = f"reset_{timestamp}"
    final = root / base_name
    suffix = 2
    while final.exists():
        final = root / f"{base_name}_{suffix}"
        suffix += 1
    partial = root / f".{final.name}.partial-{os.getpid()}"
    if partial.exists():
        raise RuntimeError(f"임시 백업 경로가 이미 존재합니다: {partial}")
    return partial, final


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    existing_stat = path.stat() if path.exists() else None
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    with temporary.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    os.chmod(temporary, 0o600)
    if existing_stat is not None and hasattr(os, "chown") and os.name != "nt":
        os.chown(temporary, existing_stat.st_uid, existing_stat.st_gid)
    os.replace(temporary, path)


def directory_size(path: Path) -> int:
    if not path.exists():
        return 0
    total = 0
    for current, _directory_names, file_names in os.walk(path, followlinks=False):
        current_path = Path(current)
        for name in file_names:
            file_path = current_path / name
            if file_path.is_symlink():
                raise RuntimeError(f"백업 원본에 심볼릭 링크가 있습니다: {file_path}")
            total += file_path.stat().st_size
    return total


def backup_owner() -> tuple[int, int]:
    default_uid = os.getuid() if hasattr(os, "getuid") else 0
    default_gid = os.getgid() if hasattr(os, "getgid") else 0
    try:
        return int(os.getenv("SUDO_UID", str(default_uid))), int(
            os.getenv("SUDO_GID", str(default_gid))
        )
    except ValueError as error:
        raise RuntimeError("SUDO_UID/SUDO_GID 값이 올바르지 않습니다.") from error


def ensure_backup_space(paths: ResetPaths) -> int:
    required = directory_size(paths.savegames) + directory_size(paths.logs) + paths.config.stat().st_size
    paths.backup_root.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(paths.backup_root.parent, 0o700)
    free = shutil.disk_usage(paths.backup_root.parent).free
    if free < required + FREE_SPACE_RESERVE:
        raise RuntimeError(
            "백업 공간 부족: "
            f"필요 {required + FREE_SPACE_RESERVE:,} bytes, 사용 가능 {free:,} bytes"
        )
    return required


def _copy_tree_or_empty(source: Path, destination: Path) -> None:
    if source.is_dir():
        shutil.copytree(source, destination, copy_function=shutil.copy2)
    else:
        destination.mkdir(parents=True, mode=0o700)


def _chown_tree(root: Path, uid: int, gid: int) -> None:
    if not hasattr(os, "chown") or os.name == "nt":
        return
    for current, directory_names, file_names in os.walk(root):
        current_path = Path(current)
        os.chown(current_path, uid, gid)
        for name in (*directory_names, *file_names):
            os.chown(current_path / name, uid, gid)


def backup_and_clear(
    paths: ResetPaths,
    *,
    reported_guid: str | None = None,
    timestamp: str | None = None,
) -> tuple[Path, dict[str, Any]]:
    """Create a verified backup, then replace data/serverN with empty bind directories."""
    reject_symlinks(paths.savegames)
    reject_symlinks(paths.logs)
    required_bytes = ensure_backup_space(paths)
    timestamp = timestamp or datetime.now().astimezone().strftime("%Y.%m.%d-%H.%M.%S")
    partial, final = unique_backup_path(paths.backup_root, timestamp)
    guids = world_guids(paths.savegames)
    normalized_reported = reported_guid.upper() if reported_guid else None
    old_guid = normalized_reported if normalized_reported in guids else (guids[0] if len(guids) == 1 else normalized_reported)

    paths.backup_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(paths.backup_root, 0o700)
    owner_uid, owner_gid = backup_owner()
    if hasattr(os, "chown") and os.name != "nt":
        os.chown(paths.backup_root.parent, owner_uid, owner_gid)
        os.chown(paths.backup_root, owner_uid, owner_gid)
    partial.mkdir(mode=0o700)
    deletion_started = False
    try:
        log(f"{paths.server}: 월드 백업 복사 중")
        _copy_tree_or_empty(paths.savegames, partial / "world")
        log(f"{paths.server}: 런타임 로그 백업 복사 중")
        _copy_tree_or_empty(paths.logs, partial / "logs")
        (partial / "config").mkdir(mode=0o700)
        shutil.copy2(paths.config, partial / "config" / paths.config.name)
        os.chmod(partial / "config" / paths.config.name, 0o600)

        source_world = tree_manifest(paths.savegames)
        source_logs = tree_manifest(paths.logs)
        copied_world = tree_manifest(partial / "world")
        copied_logs = tree_manifest(partial / "logs")
        if source_world != copied_world or source_logs != copied_logs:
            raise RuntimeError("백업 SHA-256 검증에 실패했습니다. 원본 데이터는 삭제하지 않았습니다.")
        if _file_digest(paths.config) != _file_digest(partial / "config" / paths.config.name):
            raise RuntimeError("환경 파일 백업 SHA-256 검증에 실패했습니다. 원본 데이터는 삭제하지 않았습니다.")

        world_summary = summarize_manifest(copied_world)
        logs_summary = summarize_manifest(copied_logs)
        metadata: dict[str, Any] = {
            "schema": 1,
            "operation": "world-reset",
            "server": paths.server,
            "created_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            "status": "backup-verified",
            "old_world_guid": old_guid,
            "world_guids": guids,
            "new_world_guid": None,
            "same_guid": None,
            "contents": {
                "world": {
                    "files": world_summary.files,
                    "bytes": world_summary.bytes,
                    "sha256": world_summary.sha256,
                },
                "logs": {
                    "files": logs_summary.files,
                    "bytes": logs_summary.bytes,
                    "sha256": logs_summary.sha256,
                },
                "config": f"config/{paths.config.name}",
            },
            "space_preflight_bytes": required_bytes,
        }
        atomic_write_json(partial / "metadata.json", metadata)
        os.replace(partial, final)
        _chown_tree(final, owner_uid, owner_gid)
        os.chmod(final, 0o700)
        log(f"{paths.server}: 백업 검증 완료: {final}")

        # The target is an exact, validated data/serverN directory and is not a
        # symlink. Deletion happens only after the backup has been finalized.
        if paths.data.parent != paths.project / "data" or paths.data.is_symlink():
            raise RuntimeError(f"삭제 직전 경로 안전 검사 실패: {paths.data}")
        deletion_started = True
        shutil.rmtree(paths.data)
        (paths.data / "saved").mkdir(parents=True, mode=0o700)
        (paths.data / "logs").mkdir(mode=0o700)
        _chown_tree(paths.data, PALWORLD_UID, PALWORLD_GID)
        os.chmod(paths.data, 0o700)
        return final, metadata
    except Exception as error:
        if deletion_started:
            raise StorageCommitError(
                final,
                f"백업은 완료됐지만 새 data 디렉터리 준비 중 실패했습니다: {error}",
            ) from error
        # A finalized backup is intentionally retained. A partial backup is also
        # retained for diagnosis; live data is untouched until finalization.
        if partial.exists():
            failed = paths.backup_root / f"{partial.name}.failed"
            if not failed.exists():
                os.replace(partial, failed)
                log(f"부분 백업 보존: {failed}")
        raise


def run_command(command: list[str], *, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=None,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=timeout,
    )


def docker_json(container: str, command: str) -> dict[str, Any] | None:
    try:
        result = run_command(["docker", "exec", container, "palctl", command], timeout=15)
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0:
        return None
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def container_exists(container: str) -> bool:
    return run_command(["docker", "container", "inspect", container], timeout=15).returncode == 0


def container_running(container: str) -> bool:
    result = run_command(
        ["docker", "inspect", "--format", "{{.State.Running}}", container], timeout=15
    )
    return result.returncode == 0 and result.stdout.strip().lower() == "true"


def reported_world_guid(info: dict[str, Any] | None) -> str | None:
    if not info:
        return None
    for key, value in info.items():
        if key.lower() == "worldguid" and isinstance(value, str) and WORLD_GUID_RE.fullmatch(value):
            return value.upper()
    return None


def wait_for_stopped(container: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    last_state = "unknown"
    while time.monotonic() < deadline:
        status = docker_json(container, "status")
        if status:
            last_state = str(status.get("game", "unknown"))
            if last_state == "stopped":
                return
        time.sleep(2)
    raise RuntimeError(f"안전 종료 확인 시간 초과 (마지막 상태: {last_state})")


def safely_stop_container(paths: ResetPaths, waittime: int) -> tuple[bool, bool, str | None]:
    was_running = container_running(paths.container)
    was_game_running = False
    guid = None
    if not was_running:
        return was_running, was_game_running, guid

    status = docker_json(paths.container, "status")
    if not status:
        raise RuntimeError("컨테이너 관리 상태를 확인할 수 없어 초기화를 중단합니다.")
    game_state = str(status.get("game", "unknown"))
    if game_state in {"installing", "updating", "restoring", "stopping"}:
        raise RuntimeError(f"서버가 {game_state} 상태입니다. 작업 완료 후 다시 시도하세요.")
    was_game_running = game_state == "running"
    guid = reported_world_guid(docker_json(paths.container, "info"))

    if was_game_running:
        log(f"{paths.server}: 플레이어 공지·저장 후 안전 종료를 요청합니다. 대기 {waittime}초")
        result = run_command(
            ["docker", "exec", paths.container, "palctl", "reset-stop", "--wait", str(waittime)],
            timeout=15,
        )
        if result.returncode != 0:
            # Compatibility path for a container created by an older installer.
            log(f"{paths.server}: 기존 이미지 호환 종료 명령으로 전환합니다.")
            result = run_command(
                ["docker", "exec", paths.container, "palctl", "shutdown", "--wait", str(waittime)],
                timeout=15,
            )
        if result.returncode != 0:
            raise RuntimeError(f"안전 종료 요청 실패: {(result.stderr or result.stdout).strip()}")
        wait_for_stopped(paths.container, waittime + 120)

    log(f"{paths.server}: bind mount를 고정하기 위해 컨테이너를 정지합니다.")
    stopped = run_command(["docker", "stop", "--time", "30", paths.container], timeout=60)
    if stopped.returncode != 0:
        raise RuntimeError(f"컨테이너 정지 실패: {(stopped.stderr or stopped.stdout).strip()}")
    if container_running(paths.container):
        raise RuntimeError("컨테이너가 완전히 정지되지 않아 초기화를 중단합니다.")
    return was_running, was_game_running, guid


def start_new_world(paths: ResetPaths, timeout: int) -> str:
    log(f"{paths.server}: 컨테이너와 새 월드를 시작합니다.")
    started = run_command(["docker", "start", paths.container], timeout=60)
    if started.returncode != 0:
        raise RuntimeError(f"컨테이너 시작 실패: {(started.stderr or started.stdout).strip()}")

    queued = run_command(["docker", "exec", paths.container, "palctl", "start"], timeout=30)
    if queued.returncode != 0:
        raise RuntimeError(f"새 월드 시작 요청 실패: {(queued.stderr or queued.stdout).strip()}")

    deadline = time.monotonic() + timeout
    next_progress = 0.0
    guid: str | None = None
    while time.monotonic() < deadline:
        guid = reported_world_guid(docker_json(paths.container, "info"))
        if guid:
            break
        now = time.monotonic()
        if now >= next_progress:
            remaining = max(0, int(deadline - now))
            log(f"{paths.server}: 새 월드 준비 대기 중... 남은 시간 {remaining}초")
            next_progress = now + 15
        if not container_running(paths.container):
            raise RuntimeError("새 월드 시작 중 컨테이너가 종료되었습니다.")
        time.sleep(3)
    if not guid:
        raise RuntimeError("새 월드 REST API 준비 시간을 초과했습니다.")

    run_command(["docker", "exec", paths.container, "palctl", "save"], timeout=30)
    save_dir = paths.savegames / guid
    save_deadline = time.monotonic() + 120
    while time.monotonic() < save_deadline:
        if paths.savegames.is_dir():
            matching = next(
                (
                    candidate
                    for candidate in paths.savegames.iterdir()
                    if candidate.is_dir() and candidate.name.upper() == guid
                ),
                None,
            )
            if matching is not None:
                save_dir = matching
        if (save_dir / "Level.sav").is_file() and (save_dir / "LevelMeta.sav").is_file():
            return guid
        time.sleep(2)
    raise RuntimeError(f"새 월드 핵심 저장 파일을 확인하지 못했습니다: {save_dir}")


def update_metadata(backup: Path, **values: Any) -> None:
    metadata_path = backup / "metadata.json"
    with metadata_path.open("r", encoding="utf-8") as handle:
        metadata = json.load(handle)
    metadata.update(values)
    atomic_write_json(metadata_path, metadata)


def recover_precommit_container(paths: ResetPaths, was_running: bool, was_game_running: bool) -> None:
    if not was_running:
        return
    log(f"{paths.server}: 데이터 삭제 전 실패하여 기존 컨테이너 상태를 복구합니다.")
    if not container_running(paths.container):
        run_command(["docker", "start", paths.container], timeout=60)
    if was_game_running:
        run_command(["docker", "exec", paths.container, "palctl", "start"], timeout=30)


def _reset_world_locked(paths: ResetPaths, waittime: int, startup_timeout: int) -> Path:
    if not container_exists(paths.container):
        raise RuntimeError(f"설치된 컨테이너를 찾을 수 없습니다: {paths.container}")

    # Reject unsafe paths and insufficient disk space before taking an active
    # server offline. Both checks are repeated after the container is stopped.
    reject_symlinks(paths.savegames)
    reject_symlinks(paths.logs)
    ensure_backup_space(paths)

    was_running = container_running(paths.container)
    initial_status = docker_json(paths.container, "status") if was_running else None
    was_game_running = bool(initial_status and initial_status.get("game") == "running")
    backup: Path | None = None
    storage_committed = False
    try:
        was_running, was_game_running, api_guid = safely_stop_container(paths, waittime)
        try:
            backup, metadata = backup_and_clear(paths, reported_guid=api_guid)
        except StorageCommitError as error:
            storage_committed = True
            backup = error.backup
            try:
                update_metadata(
                    backup,
                    status="data-recreation-failed",
                    failed_at=datetime.now().astimezone().isoformat(timespec="seconds"),
                    error=str(error),
                )
            except OSError:
                pass
            raise
        storage_committed = True
        try:
            new_guid = start_new_world(paths, startup_timeout)
        except Exception as error:
            update_metadata(
                backup,
                status="new-world-start-failed",
                failed_at=datetime.now().astimezone().isoformat(timespec="seconds"),
                error=str(error),
            )
            raise
        old_guid = metadata.get("old_world_guid")
        update_metadata(
            backup,
            status="completed",
            completed_at=datetime.now().astimezone().isoformat(timespec="seconds"),
            new_world_guid=new_guid,
            same_guid=bool(old_guid and old_guid == new_guid),
        )
        log(f"{paths.server}: 새 월드 생성 완료")
        log(f"이전 GUID: {old_guid or '확인 불가'}")
        log(f"새 GUID: {new_guid}")
        if old_guid == new_guid:
            log("GUID는 같지만 기존 data 디렉터리 제거 후 핵심 저장 파일이 새로 생성된 것을 확인했습니다.")
        log(f"백업 위치: {backup}")
        return backup
    except Exception:
        if not storage_committed:
            recover_precommit_container(paths, was_running, was_game_running)
        raise


def reset_world(project: Path, server: str, waittime: int, startup_timeout: int) -> Path:
    paths = build_paths(project, server)
    with InstanceLock(paths):
        return _reset_world_locked(paths, waittime, startup_timeout)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="팰월드 서버 월드 초기화", allow_abbrev=False
    )
    parser.add_argument("--server", required=True)
    parser.add_argument("--project", type=Path, default=Path(os.getenv("PALWORLD_PROJECT_DIR", ".")))
    parser.add_argument("--wait", type=int, default=60, help="플레이어 종료 공지 대기 시간")
    parser.add_argument("--startup-timeout", type=int, default=1200)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        print("오류: 월드 초기화는 관리자 권한이 필요합니다.", file=sys.stderr)
        return 1
    if args.wait < 0 or args.startup_timeout < 1:
        print("오류: 대기 시간은 0 이상, 시작 제한 시간은 1 이상이어야 합니다.", file=sys.stderr)
        return 2
    try:
        reset_world(args.project, args.server, args.wait, args.startup_timeout)
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
