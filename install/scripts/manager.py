#!/usr/bin/env python3
"""Install, configure, schedule, and supervise one Palworld server container."""

from __future__ import annotations

import json
import os
import queue
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from collections import OrderedDict
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterator, TextIO

try:
    import fcntl as _fcntl
except ImportError:  # pragma: no cover - Windows-only local regression tests.
    _fcntl = None

from common import (
    COMMANDS_DIR,
    DATA_DIR,
    MANAGER_DIR,
    POLICY_FILE,
    RESTORE_JOBS_DIR,
    STATUS_FILE,
    append_restore_event,
    api_request,
    atomic_write_json,
    atomic_write_text,
    parse_bool,
    read_json,
    restore_result_file,
)
from management_api import start_management_api
from policy import POLICY_OVERRIDES, PolicyFileError, read_policy_file as read_policy_path
from world_backup import (
    backup_directory,
    create_deleted_snapshot,
    discover_world_directory,
    ensure_restore_disk_space,
    payload_statistics,
    recover_interrupted_restores,
    reported_world_guid,
    replace_world_payload,
    stage_backup,
)


APP_ID = os.getenv("STEAM_APP_ID", "2394010")
GAME_DIR = DATA_DIR / "server"
DEFAULT_CONFIG = GAME_DIR / "DefaultPalWorldSettings.ini"
SERVER_CONFIG = GAME_DIR / "Pal/Saved/Config/LinuxServer/PalWorldSettings.ini"
SERVER_SCRIPT = GAME_DIR / "PalServer.sh"
APP_MANIFEST = GAME_DIR / "steamapps" / f"appmanifest_{APP_ID}.acf"
UPDATE_LOCK_FILE = Path(
    os.getenv("UPDATE_LOCK_FILE", "/palworld/update-lock/steam-update.lock")
)
UPDATE_LOCK_RETRY_SECONDS = 15.0
STEAM_BUILD_CACHE_SECONDS = 60.0
STEAM_APP_INFO_TIMEOUT_SECONDS = 90.0
STATUS_WRITE_ERROR_LOG_INTERVAL_SECONDS = 60.0
SCHEDULED_RESTART_MIN_UPTIME = 60.0
STEAMCMD_STALLED_EXIT_CODE = 124
STEAMCMD_LOW_FREE_SPACE_BYTES = 12 * 1024**3
FINAL_SHUTDOWN_MESSAGE = "서버가 종료됩니다."
FINAL_RESTART_MESSAGE = "서버가 재시작됩니다."
FINAL_UPDATE_MESSAGE = "서버 업데이트를 위해 재시작됩니다."
FINAL_RESTORE_MESSAGE = "서버 복원을 위해 종료됩니다."
FINAL_RESET_MESSAGE = "서버 초기화를 위해 종료됩니다."
FINAL_SCHEDULE_MESSAGE = "운영 시간이 종료되어 서버가 종료됩니다."
FINAL_TEST_MESSAGE = "서버 검사가 완료되어 다시 정지됩니다."

STRING_SETTINGS = {
    "AdminPassword",
    "BanListURL",
    "PublicIP",
    "Region",
    "ServerDescription",
    "ServerName",
    "ServerPassword",
}

def read_policy_file(path: Path | None = None) -> dict[str, Any]:
    """Read the configured policy through the shared strict validator."""
    return read_policy_path(path if path is not None else POLICY_FILE)


_RUNTIME_LOG_LOCK = threading.Lock()
_LOG_STDOUT_LOCK = threading.Lock()
_RUNTIME_LOG_FAILURE_REPORTED = False
_RUNTIME_LOG_HANDLE: TextIO | None = None
_RUNTIME_LOG_HANDLE_PATH: Path | None = None
_RUNTIME_LOG_HANDLE_MAX_BYTES: int | None = None
_RUNTIME_LOG_HANDLE_BACKUP_COUNT: int | None = None
_RUNTIME_LOG_SIZE_BYTES = 0
_RUNTIME_LOG_SESSIONS = 0


@dataclass(frozen=True)
class UpdateLockState:
    acquired: bool
    error: str | None = None


@contextmanager
def shared_update_lock(*, blocking: bool) -> Iterator[UpdateLockState]:
    """Coordinate SteamCMD and restart work across every server container on one host."""
    handle: Any = None
    acquired = False
    try:
        try:
            if not UPDATE_LOCK_FILE.parent.is_dir():
                raise FileNotFoundError(
                    f"shared host update lock mount is missing: {UPDATE_LOCK_FILE.parent}"
                )
            handle = UPDATE_LOCK_FILE.open("a+b")
        except OSError as error:
            yield UpdateLockState(False, f"shared host update lock is unavailable: {error}")
            return
        if _fcntl is None:
            # The production image is Linux. Keeping local Windows tests usable is
            # preferable to pretending that a process-local lock coordinates hosts.
            acquired = True
        else:
            operation = _fcntl.LOCK_EX
            if not blocking:
                operation |= _fcntl.LOCK_NB
            try:
                _fcntl.flock(handle.fileno(), operation)
                acquired = True
            except BlockingIOError:
                acquired = False
            except OSError as error:
                yield UpdateLockState(False, f"shared host update lock failed: {error}")
                return
        yield UpdateLockState(acquired)
    finally:
        if handle is not None:
            if acquired and _fcntl is not None:
                try:
                    _fcntl.flock(handle.fileno(), _fcntl.LOCK_UN)
                except OSError as error:
                    log(f"shared host update lock release warning: {error}")
            try:
                handle.close()
            except OSError as error:
                log(f"shared host update lock close warning: {error}")


def _runtime_log_path() -> Path:
    return Path(os.getenv("RUNTIME_LOG_FILE", str(DATA_DIR / "logs/runtime.log")))


def _runtime_log_limits() -> tuple[int, int]:
    try:
        max_bytes = max(1, int(os.getenv("RUNTIME_LOG_MAX_SIZE_MB", "20"))) * 1024 * 1024
        backup_count = max(1, int(os.getenv("RUNTIME_LOG_BACKUP_COUNT", "5")))
    except ValueError:
        max_bytes, backup_count = 20 * 1024 * 1024, 5
    return max_bytes, backup_count


def _rotate_runtime_log(path: Path, backup_count: int) -> None:
    oldest = path.with_name(f"{path.name}.{backup_count}")
    oldest.unlink(missing_ok=True)
    for index in range(backup_count - 1, 0, -1):
        source = path.with_name(f"{path.name}.{index}")
        if source.exists():
            os.replace(source, path.with_name(f"{path.name}.{index + 1}"))
    if path.exists():
        os.replace(path, path.with_name(f"{path.name}.1"))


def _close_runtime_log_unlocked() -> None:
    global _RUNTIME_LOG_HANDLE, _RUNTIME_LOG_HANDLE_PATH
    global _RUNTIME_LOG_HANDLE_MAX_BYTES, _RUNTIME_LOG_HANDLE_BACKUP_COUNT
    global _RUNTIME_LOG_SIZE_BYTES
    handle = _RUNTIME_LOG_HANDLE
    _RUNTIME_LOG_HANDLE = None
    _RUNTIME_LOG_HANDLE_PATH = None
    _RUNTIME_LOG_HANDLE_MAX_BYTES = None
    _RUNTIME_LOG_HANDLE_BACKUP_COUNT = None
    _RUNTIME_LOG_SIZE_BYTES = 0
    if handle is not None:
        handle.close()


def close_runtime_log() -> None:
    """Flush and close the shared runtime log handle, if one is active."""
    with _RUNTIME_LOG_LOCK:
        _close_runtime_log_unlocked()


def _open_runtime_log_file(path: Path) -> TextIO:
    return path.open("a", encoding="utf-8", buffering=64 * 1024, newline="\n")


def _ensure_runtime_log_open(path: Path, max_bytes: int, backup_count: int) -> None:
    global _RUNTIME_LOG_HANDLE, _RUNTIME_LOG_HANDLE_PATH
    global _RUNTIME_LOG_HANDLE_MAX_BYTES, _RUNTIME_LOG_HANDLE_BACKUP_COUNT
    global _RUNTIME_LOG_SIZE_BYTES
    if (
        _RUNTIME_LOG_HANDLE is not None
        and _RUNTIME_LOG_HANDLE_PATH == path
        and _RUNTIME_LOG_HANDLE_MAX_BYTES == max_bytes
        and _RUNTIME_LOG_HANDLE_BACKUP_COUNT == backup_count
    ):
        return

    _close_runtime_log_unlocked()
    path.parent.mkdir(parents=True, exist_ok=True)
    _RUNTIME_LOG_SIZE_BYTES = path.stat().st_size if path.exists() else 0
    _RUNTIME_LOG_HANDLE = _open_runtime_log_file(path)
    _RUNTIME_LOG_HANDLE_PATH = path
    _RUNTIME_LOG_HANDLE_MAX_BYTES = max_bytes
    _RUNTIME_LOG_HANDLE_BACKUP_COUNT = backup_count


@contextmanager
def _runtime_log_session() -> Iterator[None]:
    """Keep one shared buffered handle open while a high-volume stream is relayed."""
    global _RUNTIME_LOG_SESSIONS
    with _RUNTIME_LOG_LOCK:
        _RUNTIME_LOG_SESSIONS += 1
    try:
        yield
    finally:
        with _RUNTIME_LOG_LOCK:
            _RUNTIME_LOG_SESSIONS = max(0, _RUNTIME_LOG_SESSIONS - 1)
            if _RUNTIME_LOG_SESSIONS == 0:
                _close_runtime_log_unlocked()


def _write_runtime_log_lines(lines: list[str] | tuple[str, ...]) -> None:
    global _RUNTIME_LOG_FAILURE_REPORTED, _RUNTIME_LOG_SIZE_BYTES
    if not lines:
        return
    if os.name == "nt" and "RUNTIME_LOG_FILE" not in os.environ:
        return
    path = _runtime_log_path()
    max_bytes, backup_count = _runtime_log_limits()
    try:
        with _RUNTIME_LOG_LOCK:
            _ensure_runtime_log_open(path, max_bytes, backup_count)
            for line in lines:
                encoded_size = len((line + "\n").encode("utf-8"))
                if _RUNTIME_LOG_SIZE_BYTES + encoded_size > max_bytes:
                    _close_runtime_log_unlocked()
                    _rotate_runtime_log(path, backup_count)
                    _ensure_runtime_log_open(path, max_bytes, backup_count)
                assert _RUNTIME_LOG_HANDLE is not None
                _RUNTIME_LOG_HANDLE.write(line + "\n")
                _RUNTIME_LOG_SIZE_BYTES += encoded_size
            assert _RUNTIME_LOG_HANDLE is not None
            _RUNTIME_LOG_HANDLE.flush()
            if _RUNTIME_LOG_SESSIONS == 0:
                _close_runtime_log_unlocked()
        _RUNTIME_LOG_FAILURE_REPORTED = False
    except OSError as error:
        with _RUNTIME_LOG_LOCK:
            try:
                _close_runtime_log_unlocked()
            except OSError:
                pass
        if not _RUNTIME_LOG_FAILURE_REPORTED:
            _RUNTIME_LOG_FAILURE_REPORTED = True
            print(f"runtime log file unavailable: {error}", file=sys.stderr, flush=True)


def _write_runtime_log(line: str) -> None:
    _write_runtime_log_lines((line,))


def _write_stdout_lines(lines: list[str] | tuple[str, ...]) -> None:
    if not lines:
        return
    with _LOG_STDOUT_LOCK:
        sys.stdout.write("\n".join(lines) + "\n")
        sys.stdout.flush()


def log(message: str, *, source: str = "manager") -> str:
    timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
    normalized_source = re.sub(r"[^a-z0-9_-]", "-", source.lower()).strip("-") or "manager"
    line = f"[{timestamp}] [{normalized_source}] {message}"
    _write_stdout_lines((line,))
    _write_runtime_log(line)
    return line


_GAME_LOG_QUEUE_SIZE = 512
_GAME_LOG_BATCH_SIZE = 64
_GAME_LOG_LINE_MAX_CHARS = 16 * 1024
_GAME_LOG_SINK_JOIN_SECONDS = 2.0
_GAME_LOG_EOF = object()


@dataclass(frozen=True, slots=True)
class _GameLogRecord:
    timestamp: str
    message: str
    restore_job_id: str | None


def _read_bounded_game_line(stream: TextIO) -> str | None:
    """Read one logical game line without allowing an unbounded allocation."""
    read_limit = _GAME_LOG_LINE_MAX_CHARS + 2
    raw_line = stream.readline(read_limit)
    if raw_line == "":
        return None

    complete = raw_line.endswith("\n")
    content = raw_line.rstrip("\r\n") if complete else raw_line
    if len(content) <= _GAME_LOG_LINE_MAX_CHARS and (complete or len(raw_line) < read_limit):
        return content

    prefix = content[:_GAME_LOG_LINE_MAX_CHARS]
    discarded = max(0, len(content) - _GAME_LOG_LINE_MAX_CHARS)
    while not complete:
        remainder = stream.readline(read_limit)
        if remainder == "":
            break
        complete = remainder.endswith("\n")
        discarded += len(remainder.rstrip("\r\n") if complete else remainder)
    return f"{prefix} ... [truncated {discarded} additional characters]"


class _GameLogRelay:
    """Drain game stdout promptly and relay it through a bounded asynchronous sink."""

    def __init__(self, name: str) -> None:
        self._records: queue.Queue[_GameLogRecord | object] = queue.Queue(
            maxsize=_GAME_LOG_QUEUE_SIZE
        )
        self._reader_done = threading.Event()
        self._dropped_lock = threading.Lock()
        self._dropped_total = 0
        self._dropped_by_restore_job: dict[str, int] = {}
        self._sink = threading.Thread(
            target=self._run_sink,
            name=f"{name}-game-log-sink",
            daemon=True,
        )

    def start(self) -> None:
        self._sink.start()

    def submit(self, message: str, restore_job_id: str | None) -> None:
        record = _GameLogRecord(
            timestamp=datetime.now().astimezone().isoformat(timespec="seconds"),
            message=message,
            restore_job_id=restore_job_id,
        )
        try:
            self._records.put_nowait(record)
        except queue.Full:
            with self._dropped_lock:
                self._dropped_total += 1
                if restore_job_id:
                    self._dropped_by_restore_job[restore_job_id] = (
                        self._dropped_by_restore_job.get(restore_job_id, 0) + 1
                    )

    def finish(self) -> bool:
        self._reader_done.set()
        try:
            self._records.put(_GAME_LOG_EOF, timeout=0.05)
        except queue.Full:
            pass
        self._sink.join(timeout=_GAME_LOG_SINK_JOIN_SECONDS)
        return not self._sink.is_alive()

    def _take_dropped(self) -> tuple[int, dict[str, int]]:
        with self._dropped_lock:
            total = self._dropped_total
            by_job = self._dropped_by_restore_job
            self._dropped_total = 0
            self._dropped_by_restore_job = {}
        return total, by_job

    @staticmethod
    def _append_restore_record(record: _GameLogRecord, *, level: str = "game") -> None:
        if not record.restore_job_id:
            return
        try:
            append_restore_event(
                record.restore_job_id,
                {
                    "type": "log",
                    "timestamp": record.timestamp,
                    "level": level,
                    "message": record.message,
                },
            )
        except OSError:
            pass

    def _emit_records(self, records: list[_GameLogRecord]) -> None:
        rendered = [f"[{record.timestamp}] [game] {record.message}" for record in records]
        _write_stdout_lines(rendered)
        _write_runtime_log_lines(rendered)
        for record in records:
            self._append_restore_record(record)

    def _emit_dropped_notice(self) -> None:
        total, by_job = self._take_dropped()
        if total == 0:
            return
        timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
        message = (
            f"game log relay dropped {total} lines because its bounded queue was full; "
            "game stdout continued to drain"
        )
        rendered = f"[{timestamp}] [manager] {message}"
        _write_stdout_lines((rendered,))
        _write_runtime_log_lines((rendered,))
        for job_id, count in by_job.items():
            self._append_restore_record(
                _GameLogRecord(
                    timestamp,
                    f"game log relay dropped {count} lines while this restore was active",
                    job_id,
                ),
                level="warning",
            )

    def _run_sink(self) -> None:
        stop_requested = False
        try:
            with _runtime_log_session():
                while not stop_requested:
                    batch: list[_GameLogRecord] = []
                    try:
                        item = self._records.get(timeout=0.1)
                    except queue.Empty:
                        if self._reader_done.is_set():
                            stop_requested = True
                        self._emit_dropped_notice()
                        continue

                    if item is _GAME_LOG_EOF:
                        stop_requested = True
                    else:
                        assert isinstance(item, _GameLogRecord)
                        batch.append(item)

                    while not stop_requested and len(batch) < _GAME_LOG_BATCH_SIZE:
                        try:
                            item = self._records.get_nowait()
                        except queue.Empty:
                            break
                        if item is _GAME_LOG_EOF:
                            stop_requested = True
                            break
                        assert isinstance(item, _GameLogRecord)
                        batch.append(item)

                    if batch:
                        self._emit_records(batch)
                    if self._records.empty():
                        self._emit_dropped_notice()
                self._emit_dropped_notice()
        except Exception as error:
            print(f"game log sink unavailable: {error}", file=sys.stderr, flush=True)


def parse_duration(value: str | None) -> float:
    if value is None or not value.strip() or value.strip().lower() in {"0", "off", "none", "disabled"}:
        return 0.0
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*", value, re.IGNORECASE)
    if not match:
        raise ValueError(f"invalid duration {value!r}; use values such as 30s, 6h, or 1d")
    number = float(match.group(1))
    multiplier = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2).lower()]
    return number * multiplier


def format_waittime(seconds: int) -> str:
    seconds = max(0, int(seconds))
    if seconds >= 60 and seconds % 60 == 0:
        return f"{seconds // 60}분"
    return f"{seconds}초"


def render_timed_message(template: str, seconds: int) -> str:
    return template.replace("{time}", format_waittime(seconds)).replace("{seconds}", str(seconds))


def parse_clock(value: str) -> int:
    match = re.fullmatch(r"\s*(\d{1,2}):(\d{2})\s*", value)
    if not match:
        raise ValueError(f"invalid time {value!r}; expected HH:MM")
    hour, minute = int(match.group(1)), int(match.group(2))
    if hour > 23 or minute > 59:
        raise ValueError(f"invalid time {value!r}; expected 00:00 through 23:59")
    return hour * 60 + minute


def parse_active_window(value: str | None) -> tuple[int, int] | None:
    if value is None or value.strip().lower() in {"", "always", "24h", "all"}:
        return None
    parts = value.split("-", 1)
    if len(parts) != 2:
        raise ValueError("ACTIVE_WINDOW must be 'always' or 'HH:MM-HH:MM'")
    return parse_clock(parts[0]), parse_clock(parts[1])


def is_in_active_window(now: datetime, window: tuple[int, int] | None) -> bool:
    if window is None:
        return True
    start, end = window
    if start == end:
        return True
    current = now.hour * 60 + now.minute
    if start < end:
        return start <= current < end
    return current >= start or current < end


def has_scheduled_window(window: tuple[int, int] | None) -> bool:
    return window is not None and window[0] != window[1]


def next_clock_occurrence(now: datetime, minute_of_day: int) -> datetime:
    candidate = now.replace(
        hour=minute_of_day // 60,
        minute=minute_of_day % 60,
        second=0,
        microsecond=0,
    )
    if candidate <= now:
        candidate += timedelta(days=1)
    return candidate


def next_active_window_start(
    now: datetime, window: tuple[int, int] | None
) -> datetime | None:
    if not has_scheduled_window(window):
        return None
    assert window is not None
    return next_clock_occurrence(now, window[0])


def next_active_window_end(
    now: datetime, window: tuple[int, int] | None
) -> datetime | None:
    if not has_scheduled_window(window):
        return None
    assert window is not None
    return next_clock_occurrence(now, window[1])


def start_policy_for_request(
    now: datetime, window: tuple[int, int] | None
) -> tuple[str, datetime | None]:
    if not has_scheduled_window(window) or is_in_active_window(now, window):
        return "auto", None
    return "started", next_active_window_end(now, window)


def shutdown_policy_for_request(
    now: datetime, window: tuple[int, int] | None
) -> tuple[str, datetime | None]:
    resume_at = next_active_window_start(now, window)
    return "stopped", resume_at


def parse_restart_times(value: str | None) -> tuple[int, ...]:
    if value is None or not value.strip() or value.strip().lower() in {"off", "none", "disabled"}:
        return ()
    return tuple(sorted({parse_clock(item) for item in value.split(",") if item.strip()}))


def scheduled_restart_allowed(
    inside_active_window: bool,
    game_running: bool,
    uptime_seconds: float | None,
) -> bool:
    """Only restart inside the active window after the game has settled."""
    return (
        inside_active_window
        and game_running
        and uptime_seconds is not None
        and uptime_seconds >= SCHEDULED_RESTART_MIN_UPTIME
    )


def restart_delay_after_exit(exit_code: int | None, crash_delay: float) -> float:
    """A clean external REST shutdown is a managed restart, not a crash."""
    return 0.0 if exit_code == 0 else crash_delay


def split_top_level(value: str, delimiter: str = ",") -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    quoted = False
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quoted:
            escaped = True
            continue
        if character == '"':
            quoted = not quoted
            continue
        if quoted:
            continue
        if character in "([{" :
            depth += 1
        elif character in ")]}":
            depth -= 1
        elif character == delimiter and depth == 0:
            parts.append(value[start:index].strip())
            start = index + 1
    parts.append(value[start:].strip())
    return [part for part in parts if part]


def find_option_settings(content: str) -> tuple[str, str, str]:
    marker = "OptionSettings="
    marker_index = content.find(marker)
    if marker_index < 0:
        raise ValueError("OptionSettings was not found in DefaultPalWorldSettings.ini")
    open_index = content.find("(", marker_index + len(marker))
    if open_index < 0:
        raise ValueError("OptionSettings opening parenthesis was not found")

    depth = 1
    quoted = False
    escaped = False
    for index in range(open_index + 1, len(content)):
        character = content[index]
        if escaped:
            escaped = False
            continue
        if character == "\\" and quoted:
            escaped = True
            continue
        if character == '"':
            quoted = not quoted
            continue
        if quoted:
            continue
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                return content[: open_index + 1], content[open_index + 1 : index], content[index:]
    raise ValueError("OptionSettings closing parenthesis was not found")


def parse_settings_body(body: str) -> OrderedDict[str, str]:
    settings: OrderedDict[str, str] = OrderedDict()
    for item in split_top_level(body):
        if "=" not in item:
            raise ValueError(f"invalid Palworld setting: {item!r}")
        key, value = item.split("=", 1)
        settings[key.strip()] = value.strip()
    return settings


def quote_ini_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def encode_setting(key: str, value: str, default: str | None) -> str:
    if value.startswith("raw:"):
        return value[4:]
    normalized = value.strip()
    if default is not None:
        default = default.strip()
        if default.startswith('"') and default.endswith('"'):
            return quote_ini_string(value)
        if default.lower() in {"true", "false"}:
            return "True" if parse_bool(value) else "False"
        if re.fullmatch(r"[-+]?\d+(?:\.\d+)?", default):
            if not re.fullmatch(r"[-+]?\d+(?:\.\d+)?", normalized):
                raise ValueError(f"{key} requires a number, got {value!r}")
            return normalized
        if default.startswith("(") and default.endswith(")"):
            return normalized if normalized.startswith("(") else f"({normalized})"

    if key in STRING_SETTINGS:
        return quote_ini_string(value)
    if normalized.lower() in {"true", "false", "yes", "no", "on", "off", "1", "0"}:
        return "True" if parse_bool(normalized) else "False"
    if re.fullmatch(r"[-+]?\d+(?:\.\d+)?", normalized):
        return normalized
    if normalized.startswith(("(", "[", "{")):
        return normalized
    return quote_ini_string(value)


def render_settings(content: str, overrides: dict[str, str]) -> str:
    prefix, body, suffix = find_option_settings(content)
    settings = parse_settings_body(body)
    for key, value in overrides.items():
        settings[key] = encode_setting(key, value, settings.get(key))
    rendered = ",".join(f"{key}={value}" for key, value in settings.items())
    return f"{prefix}{rendered}{suffix}"


def collect_overrides(environment: dict[str, str] | os._Environ[str]) -> dict[str, str]:
    prefix = "PAL_SETTING_"
    return {
        key[len(prefix) :]: value
        for key, value in environment.items()
        if key.startswith(prefix) and len(key) > len(prefix)
    }


def missing_required_game_files(required_files: tuple[Path, ...] | None = None) -> tuple[Path, ...]:
    """Return files that must exist before configuration and startup can continue."""
    files = required_files or (SERVER_SCRIPT, DEFAULT_CONFIG)
    return tuple(path for path in files if not path.is_file())


def install_requires_validation(
    validate_on_update: bool,
    missing_files: tuple[Path, ...],
) -> bool:
    """Always validate an incomplete installation, regardless of the update preference."""
    return validate_on_update or bool(missing_files)


def build_steamcmd_command(
    steamcmd: str,
    *,
    validate: bool,
    beta: str = "",
) -> list[str]:
    """Build a SteamCMD command with the install directory set before login."""
    command = [
        steamcmd,
        "+force_install_dir",
        str(GAME_DIR),
        "+login",
        "anonymous",
        "+app_update",
        APP_ID,
    ]
    if beta:
        command.extend(["-beta", beta])
    if validate:
        command.append("validate")
    command.append("+quit")
    return command


def parse_installed_build_id(content: str) -> int:
    match = re.search(r'"buildid"\s*"(\d+)"', content, re.IGNORECASE)
    if not match or int(match.group(1)) <= 0:
        raise ValueError("Steam app manifest does not contain a valid buildid")
    return int(match.group(1))


def installed_build_id(manifest: Path | None = None) -> int:
    candidates = (
        (manifest,)
        if manifest is not None
        else (
            APP_MANIFEST,
            GAME_DIR / f"appmanifest_{APP_ID}.acf",
            Path.home() / f"Steam/steamapps/appmanifest_{APP_ID}.acf",
            Path.home() / f".local/share/Steam/steamapps/appmanifest_{APP_ID}.acf",
        )
    )
    errors: list[str] = []
    for candidate in candidates:
        try:
            return parse_installed_build_id(candidate.read_text(encoding="utf-8", errors="replace"))
        except (OSError, ValueError) as error:
            errors.append(f"{candidate}: {error}")
    raise RuntimeError("Steam app manifest is unavailable or invalid: " + "; ".join(errors))


_KEYVALUES_TOKEN_RE = re.compile(r'"((?:\\.|[^"\\])*)"|([{}])')


def build_steamcmd_app_info_command(steamcmd: str) -> list[str]:
    """Build the authoritative public-build metadata query for this Steam app."""
    return [
        steamcmd,
        "+login",
        "anonymous",
        "+app_info_update",
        "1",
        "+app_info_print",
        APP_ID,
        "+quit",
    ]


def _parse_keyvalues_object(tokens: list[str], index: int) -> tuple[dict[str, Any], int]:
    if index >= len(tokens) or tokens[index] != "{":
        raise ValueError("Steam app info is missing an opening object")
    index += 1
    parsed: dict[str, Any] = {}
    while index < len(tokens):
        if tokens[index] == "}":
            return parsed, index + 1
        key = tokens[index]
        if key == "{":
            raise ValueError("Steam app info contains an unexpected object")
        index += 1
        if index >= len(tokens):
            break
        if tokens[index] == "{":
            value, index = _parse_keyvalues_object(tokens, index)
        elif tokens[index] == "}":
            raise ValueError(f"Steam app info is missing a value for {key!r}")
        else:
            value = tokens[index]
            index += 1
        parsed[key] = value
    raise ValueError("Steam app info object is incomplete")


def parse_available_build_id(content: str, branch: str = "public") -> int:
    """Read one branch BuildID from SteamCMD ``app_info_print`` output."""
    app_line = re.search(
        rf'(?m)^[\t ]*"{re.escape(APP_ID)}"[\t ]*\r?$',
        content,
    )
    if not app_line:
        raise ValueError(f"Steam app info does not contain app {APP_ID}")
    tokens = [
        match.group(1) if match.group(1) is not None else str(match.group(2))
        for match in _KEYVALUES_TOKEN_RE.finditer(content, app_line.start())
    ]
    if len(tokens) < 2 or tokens[0] != APP_ID:
        raise ValueError(f"Steam app info does not start with app {APP_ID}")
    app, _next_index = _parse_keyvalues_object(tokens, 1)
    try:
        build_text = app["depots"]["branches"][branch]["buildid"]
        build_id = int(str(build_text))
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError(
            f"Steam app info does not contain a valid buildid for branch {branch!r}"
        ) from error
    if build_id <= 0:
        raise ValueError(
            f"Steam app info contains a non-positive buildid for branch {branch!r}"
        )
    return build_id


def steam_build_cache_file() -> Path:
    return UPDATE_LOCK_FILE.parent / f"steam-app-{APP_ID}-build.json"


def _read_cached_available_build(
    branch: str,
    *,
    max_age: float,
    now: float | None = None,
) -> int | None:
    try:
        payload = json.loads(steam_build_cache_file().read_text(encoding="utf-8"))
        checked_epoch = float(payload["checked_epoch"])
        build_id = int(payload["build_id"])
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
    current_epoch = time.time() if now is None else now
    age = current_epoch - checked_epoch
    if (
        payload.get("app_id") != APP_ID
        or payload.get("branch") != branch
        or build_id <= 0
        or age < 0
        or age > max_age
    ):
        return None
    return build_id


def _write_cached_available_build(branch: str, build_id: int) -> None:
    atomic_write_json(
        steam_build_cache_file(),
        {
            "app_id": APP_ID,
            "branch": branch,
            "build_id": build_id,
            "checked_epoch": time.time(),
        },
    )


def query_available_build_id(
    branch: str = "public",
    *,
    timeout: float = STEAM_APP_INFO_TIMEOUT_SECONDS,
) -> int:
    """Ask SteamCMD for the branch BuildID without touching installed game files."""
    steamcmd = os.getenv("STEAMCMD_BIN") or shutil.which("steamcmd") or "/usr/bin/steamcmd"
    command = build_steamcmd_app_info_command(steamcmd)
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=max(10.0, timeout),
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"SteamCMD app-info query failed: {error}") from error
    if result.returncode != 0:
        detail = " | ".join(result.stdout.strip().splitlines()[-3:])
        raise RuntimeError(
            f"SteamCMD app-info query exited with code {result.returncode}"
            + (f": {detail[:500]}" if detail else "")
        )
    try:
        return parse_available_build_id(result.stdout, branch)
    except ValueError as error:
        raise RuntimeError(str(error)) from error


def available_build_id(
    branch: str = "public",
    *,
    force_refresh: bool = False,
    cache_seconds: float = STEAM_BUILD_CACHE_SECONDS,
    timeout: float = STEAM_APP_INFO_TIMEOUT_SECONDS,
) -> int:
    """Return one host-cached Steam BuildID and avoid per-container query storms."""
    if not force_refresh:
        cached = _read_cached_available_build(branch, max_age=max(0.0, cache_seconds))
        if cached is not None:
            return cached

    with shared_update_lock(blocking=False) as lock_state:
        if not lock_state.acquired:
            if lock_state.error is not None:
                raise RuntimeError(lock_state.error)
            raise RuntimeError("another Palworld server is using the shared Steam update lock")
        if not force_refresh:
            cached = _read_cached_available_build(branch, max_age=max(0.0, cache_seconds))
            if cached is not None:
                return cached
        build_id = query_available_build_id(branch, timeout=timeout)
        _write_cached_available_build(branch, build_id)
        return build_id


def check_steam_update(
    version: int,
    timeout: float = STEAM_APP_INFO_TIMEOUT_SECONDS,
    *,
    force_refresh: bool = False,
) -> tuple[bool, int]:
    branch = os.getenv("STEAM_BETA", "").strip() or "public"
    required_build = available_build_id(
        branch,
        force_refresh=force_refresh,
        timeout=timeout,
    )
    return version == required_build, required_build


_LOGGED_COMMAND_EOF = object()
_STEAMCMD_UPDATE_STATE_RE = re.compile(
    r"Update state \([^)]*\) ([^,]+), progress: ([0-9.]+) \(([0-9]+) / ([0-9]+)\)",
    re.IGNORECASE,
)
_STEAMCMD_BOOTSTRAP_RE = re.compile(r"\[\s*([0-9]{1,3})%\]\s+(.+)")
_STEAMCMD_APP_STATE_ERROR_RE = re.compile(
    r"Error!\s+App\s+'[^']+'\s+state\s+is\s+(0x[0-9a-f]+)\s+after update job",
    re.IGNORECASE,
)


def steamcmd_progress_signature(line: str) -> tuple[object, ...] | None:
    """Return a stable signature only for measurable SteamCMD progress."""
    update = _STEAMCMD_UPDATE_STATE_RE.search(line)
    if update:
        return (
            "update",
            update.group(1).strip().lower(),
            update.group(2),
            int(update.group(3)),
            int(update.group(4)),
        )
    bootstrap = _STEAMCMD_BOOTSTRAP_RE.search(line)
    if bootstrap:
        return ("bootstrap", int(bootstrap.group(1)), bootstrap.group(2).strip())
    if "Success! App" in line:
        return ("complete",)
    return None


def steamcmd_error_diagnostic(line: str) -> str | None:
    """Explain opaque SteamCMD application-state failures without overclaiming a cause."""
    match = _STEAMCMD_APP_STATE_ERROR_RE.search(line)
    if not match:
        return None
    state = match.group(1).lower()
    if state == "0x202":
        return (
            "SteamCMD reported app state 0x202. This commonly accompanies insufficient "
            "Docker-volume space, a write failure, or stale app metadata; storage details "
            "are logged above and the operation will retry in a new SteamCMD session."
        )
    return f"SteamCMD reported application state {state}; the operation will retry."


def _stop_logged_process(process: subprocess.Popen[str]) -> None:
    """Stop one hung command and its process group without affecting the container."""
    try:
        if os.name == "nt":
            process.terminate()
        else:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
        return
    except (OSError, ProcessLookupError, subprocess.TimeoutExpired):
        pass
    try:
        if os.name == "nt":
            process.kill()
        else:
            os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def run_logged_command(
    command: list[str],
    *,
    source: str,
    progress_timeout: float | None = None,
) -> int:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        start_new_session=os.name != "nt",
    )
    if process.stdout is None:
        return process.wait()

    records: queue.Queue[str | object] = queue.Queue()

    def read_output() -> None:
        try:
            for raw_line in process.stdout:
                records.put(raw_line)
        finally:
            process.stdout.close()
            records.put(_LOGGED_COMMAND_EOF)

    reader = threading.Thread(
        target=read_output,
        name="steamcmd-output",
        daemon=True,
    )
    reader.start()
    last_progress_at = time.monotonic()
    last_signature: tuple[object, ...] | None = None
    saw_progress = False
    timed_out = False
    while True:
        try:
            record = records.get(timeout=0.5)
        except queue.Empty:
            if process.poll() is not None and not reader.is_alive():
                break
            if (
                progress_timeout is not None
                and time.monotonic() - last_progress_at >= progress_timeout
            ):
                timed_out = True
                break
            continue
        if record is _LOGGED_COMMAND_EOF:
            break
        line = str(record).rstrip("\r\n")
        if not line:
            continue
        log(line, source=source)
        diagnostic = steamcmd_error_diagnostic(line)
        if diagnostic:
            log(diagnostic, source=source)
        now = time.monotonic()
        signature = steamcmd_progress_signature(line)
        if signature is not None:
            if not saw_progress or signature != last_signature:
                last_progress_at = now
                last_signature = signature
                saw_progress = True
        elif not saw_progress:
            # Login and app-info preparation do not report byte counters yet,
            # but new output still proves that SteamCMD is advancing.
            last_progress_at = now

    if timed_out:
        assert progress_timeout is not None
        log(
            "SteamCMD made no measurable progress for "
            f"{progress_timeout:g}s; stopping this attempt so it can be retried",
            source=source,
        )
        _stop_logged_process(process)
        reader.join(timeout=5)
        return STEAMCMD_STALLED_EXIT_CODE
    reader.join(timeout=5)
    return process.wait()


def install_or_update(*, force_update: bool = False, update_lock_held: bool = False) -> None:
    should_update = force_update or parse_bool(os.getenv("UPDATE_ON_START"), True)
    missing_before = missing_required_game_files()
    if not missing_before and not should_update:
        log("UPDATE_ON_START=false; existing game files will be used")
        return

    if missing_before and not should_update:
        log("required game files are missing; UPDATE_ON_START=false is ignored for automatic repair")

    if should_update and not force_update and not missing_before:
        try:
            current_build = installed_build_id()
            up_to_date, required_build = check_steam_update(current_build)
        except (RuntimeError, ValueError) as error:
            # A Steam metadata outage must not turn a healthy installed server
            # into a container restart loop. Runtime checks will retry later.
            log(
                "Steam startup update check warning; existing game files will be used "
                f"and the supervisor will retry later: {error}"
            )
            return
        if up_to_date:
            log(f"Steam startup build check: installed build {current_build} is current")
            return
        log(
            f"Steam startup update detected: installed build={current_build}, "
            f"available build={required_build}"
        )

    steamcmd = os.getenv("STEAMCMD_BIN") or shutil.which("steamcmd") or "/usr/bin/steamcmd"
    beta = os.getenv("STEAM_BETA", "").strip()
    validate = install_requires_validation(
        parse_bool(os.getenv("VALIDATE_ON_UPDATE"), False),
        missing_before,
    )
    command = build_steamcmd_command(steamcmd, validate=validate, beta=beta)

    def run_update() -> None:
        GAME_DIR.mkdir(parents=True, exist_ok=True)
        storage = shutil.disk_usage(GAME_DIR)
        log(
            "SteamCMD storage preflight: "
            f"free={storage.free / 1024**3:.2f} GiB, "
            f"used={storage.used / 1024**3:.2f} GiB, "
            f"total={storage.total / 1024**3:.2f} GiB"
        )
        if missing_before and storage.free < STEAMCMD_LOW_FREE_SPACE_BYTES:
            log(
                "warning: less than 12 GiB is free on the game-files volume; "
                "a first installation may remain at reconfiguring 0/0 or fail "
                "until enough Docker storage is available"
            )
        if missing_before:
            missing_names = ", ".join(str(path.relative_to(GAME_DIR)) for path in missing_before)
            log(f"required game files are missing ({missing_names}); SteamCMD validation enabled")
        log(f"SteamCMD install target: {GAME_DIR}")
        action = "forced update" if force_update else "installing/updating"
        log(f"{action} Palworld dedicated server (Steam app {APP_ID})")
        progress_timeout = max(
            60.0,
            parse_duration(os.getenv("STEAMCMD_PROGRESS_TIMEOUT", "5m")),
        )
        attempts = 3
        for attempt in range(1, attempts + 1):
            log(f"SteamCMD attempt {attempt}/{attempts}")
            return_code = run_logged_command(
                command,
                source="update",
                progress_timeout=progress_timeout,
            )
            missing_after = missing_required_game_files() if return_code == 0 else ()
            if return_code == 0 and not missing_after:
                return

            if missing_after:
                missing_names = ", ".join(
                    str(path.relative_to(GAME_DIR)) for path in missing_after
                )
                if attempt == attempts:
                    raise FileNotFoundError(
                        "SteamCMD completed successfully, but required game files are still missing: "
                        f"{missing_names}"
                    )
                log(
                    "SteamCMD completed but required game files are still missing "
                    f"({missing_names}); retrying validation ({attempt}/{attempts - 1})"
                )
                time.sleep(5)
                continue
            if return_code == STEAMCMD_STALLED_EXIT_CODE and attempt == attempts:
                raise TimeoutError(
                    "SteamCMD made no measurable progress for "
                    f"{progress_timeout:g}s in each of {attempts} attempts; "
                    "check Docker-volume free space and the container's Steam network access"
                )
            if attempt == attempts:
                raise subprocess.CalledProcessError(return_code, command)
            if return_code == STEAMCMD_STALLED_EXIT_CODE:
                log(
                    "SteamCMD progress stalled; retrying with a new SteamCMD session "
                    f"({attempt}/{attempts - 1})"
                )
            else:
                log(
                    f"SteamCMD failed with exit code {return_code}; "
                    f"retrying ({attempt}/{attempts - 1})"
                )
            time.sleep(5)

    if update_lock_held:
        run_update()
        return

    # Startup downloads share the same host lock. No game process exists yet,
    # so waiting here is safe and avoids saturating disk/network with SteamCMD.
    with shared_update_lock(blocking=False) as lock_state:
        if lock_state.acquired:
            run_update()
            return
        if lock_state.error is not None:
            raise RuntimeError(lock_state.error)
    log("another Palworld server is updating; waiting for the shared host update lock")
    with shared_update_lock(blocking=True) as lock_state:
        if not lock_state.acquired:
            raise RuntimeError(
                lock_state.error or "shared host update lock could not be acquired"
            )
        run_update()


def ensure_steamclient() -> None:
    destination = Path.home() / ".steam/sdk64/steamclient.so"
    if destination.exists():
        return
    executable = shutil.which("steamcmd")
    candidates = [
        Path.home() / ".local/share/Steam/steamcmd/linux64/steamclient.so",
        Path.home() / ".steam/steam/steamcmd/linux64/steamclient.so",
        Path("/root/.local/share/Steam/steamcmd/linux64/steamclient.so"),
        Path("/root/.steam/steam/steamcmd/linux64/steamclient.so"),
        Path("/home/steam/.local/share/Steam/steamcmd/linux64/steamclient.so"),
        Path("/home/steam/.steam/steam/steamcmd/linux64/steamclient.so"),
    ]
    if executable:
        candidates.insert(0, Path(executable).resolve().parent / "linux64/steamclient.so")
    source = next((candidate for candidate in candidates if candidate.exists()), None)
    if source:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        log(f"installed Steam SDK compatibility library at {destination}")


def write_server_config() -> None:
    if not DEFAULT_CONFIG.exists():
        raise FileNotFoundError(f"Palworld default config is missing: {DEFAULT_CONFIG}")
    content = DEFAULT_CONFIG.read_text(encoding="utf-8-sig")
    overrides = collect_overrides(os.environ)
    SERVER_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    atomic_write_text(SERVER_CONFIG, render_settings(content, overrides), mode=0o600)
    log(f"wrote {len(overrides)} Docker-managed settings to {SERVER_CONFIG}")


def prepare_game_files() -> None:
    ensure_steamclient()
    write_server_config()
    SERVER_SCRIPT.chmod(SERVER_SCRIPT.stat().st_mode | 0o111)


class Supervisor:
    def __init__(self) -> None:
        self.instance = os.getenv("INSTANCE_NAME", "palworld")
        self.active_window_text = os.getenv("ACTIVE_WINDOW", "always")
        self.active_window = parse_active_window(self.active_window_text)
        self.restart_times = parse_restart_times(os.getenv("RESTART_TIMES", ""))
        self.crash_delay = parse_duration(os.getenv("CRASH_RESTART_DELAY", "10s"))
        self.shutdown_wait = max(
            0, int(parse_duration(os.getenv("SHUTDOWN_WAIT", "30s")))
        )
        self.restart_warning_seconds = max(
            0, int(parse_duration(os.getenv("RESTART_WARNING_SECONDS", "60s")))
        )
        self.restart_warning_message = os.getenv(
            "RESTART_WARNING_MESSAGE",
            "{time} 뒤 서버가 재시작됩니다.",
        )
        self.restart_countdown_message = os.getenv(
            "RESTART_COUNTDOWN_MESSAGE",
            "서버 재시작까지 {seconds}초",
        )
        self.shutdown_warning_seconds = max(
            0, int(parse_duration(os.getenv("SHUTDOWN_WARNING_SECONDS", "60s")))
        )
        self.shutdown_warning_message = os.getenv(
            "SHUTDOWN_WARNING_MESSAGE",
            "{time} 뒤 서버가 종료됩니다.",
        )
        self.shutdown_countdown_message = os.getenv(
            "SHUTDOWN_COUNTDOWN_MESSAGE",
            "서버 종료까지 {seconds}초",
        )
        self.auto_update_enabled = parse_bool(os.getenv("AUTO_UPDATE_ENABLED"), True)
        self.auto_update_disabled_reason: str | None = None
        self.update_check_interval = max(60.0, parse_duration(os.getenv("UPDATE_CHECK_INTERVAL", "15m")))
        self.update_retry_interval = max(60.0, parse_duration(os.getenv("UPDATE_RETRY_INTERVAL", "5m")))
        self.update_warning_seconds = max(
            0, int(parse_duration(os.getenv("UPDATE_WARNING_SECONDS", "60s")))
        )
        self.update_warning_message = os.getenv(
            "UPDATE_WARNING_MESSAGE",
            "업데이트를 위해 {time} 뒤 서버가 재시작됩니다.",
        )
        self.proc: subprocess.Popen[Any] | None = None
        self.game_log_thread: threading.Thread | None = None
        self.active_restore_job_id: str | None = None
        self.phase = "initializing"
        self.reason = "startup"
        self.last_started_monotonic: float | None = None
        self.next_start_monotonic = 0.0
        self.last_restart_slot: str | None = None
        self.game_exit_count = 0
        self.last_exit_code: int | None = None
        self.terminate_requested = False
        self.update_in_progress = False
        self.update_blocked = False
        self.update_waiting_for_lock: str | None = None
        self.update_waiting_for_lock_waittime: int | None = None
        self.update_waiting_for_restart_announcement = False
        self.next_update_check_monotonic = time.monotonic() + self.update_check_interval
        self.installed_build: int | None = None
        self.available_build: int | None = None
        self.last_update_check_at: str | None = None
        self.last_update_at: str | None = None
        self.last_update_error: str | None = None
        self.last_prestart_update_check_monotonic = 0.0
        self.policy_error: str | None = None
        self.policy_write_error: str | None = None
        self.status_write_error: str | None = None
        self.next_status_write_error_log_monotonic = 0.0
        # Test sessions deliberately stay in memory. If the supervisor or
        # container restarts during a test, the temporary start override is
        # discarded and the persistent operating policy takes control again.
        self.test_session_deadline_monotonic: float | None = None
        self.test_session_until_epoch: float | None = None

        try:
            self.installed_build = installed_build_id()
        except RuntimeError:
            pass

        MANAGER_DIR.mkdir(parents=True, exist_ok=True)
        COMMANDS_DIR.mkdir(parents=True, exist_ok=True)
        if not POLICY_FILE.exists():
            try:
                atomic_write_json(POLICY_FILE, {"override": "auto"})
            except OSError as error:
                detail = error.strerror or error.__class__.__name__
                message = self.mark_policy_error(
                    f"operating policy file could not be initialized: {detail[:120]}"
                )
                self.policy_write_error = message

    def mark_policy_error(self, message: str) -> str:
        bounded = message[:500]
        previous_error = getattr(self, "policy_error", None)
        self.policy_error = bounded
        self.reason = f"persistent operating policy requires repair: {bounded}"
        if bounded != previous_error:
            log(f"persistent operating policy blocked automatic actions: {bounded}")
        return bounded

    def clear_policy_error(self, *, clear_write_error: bool = False) -> None:
        write_error = getattr(self, "policy_write_error", None)
        if write_error is not None and not clear_write_error:
            self.policy_error = write_error
            return
        previous_error = getattr(self, "policy_error", None)
        self.policy_error = None
        if clear_write_error:
            self.policy_write_error = None
        if previous_error is not None:
            log("persistent operating policy recovered; normal scheduling is available")

    def policy_record(self, now: datetime | None = None) -> dict[str, Any]:
        current = now or datetime.now().astimezone()
        try:
            record = read_policy_file()
        except PolicyFileError as error:
            message = self.mark_policy_error(str(error))
            return {"override": "invalid", "error": message}

        write_error = getattr(self, "policy_write_error", None)
        if write_error is not None:
            self.policy_error = write_error
            return {"override": "invalid", "error": write_error}

        value = str(record["override"])
        until_epoch = record.get("until_epoch")
        if value != "auto" and until_epoch is not None:
            if current.timestamp() >= float(until_epoch):
                if self.set_policy("auto"):
                    return {"override": "auto"}
                return {"override": "invalid", "error": self.policy_error or "write failed"}
        self.clear_policy_error()
        return record

    def policy(self, now: datetime | None = None) -> str:
        return str(self.policy_record(now).get("override", "auto"))

    def set_policy(self, value: str, *, until: datetime | None = None) -> bool:
        if value not in POLICY_OVERRIDES:
            raise ValueError(f"unsupported supervisor policy: {value!r}")
        if value == "auto" and until is not None:
            raise ValueError("automatic policy cannot have an expiration")
        if until is not None and (until.tzinfo is None or until.utcoffset() is None):
            raise ValueError("policy expiration must include a UTC offset")
        record: dict[str, Any] = {"override": value, "updated_at": time.time()}
        if value != "auto" and until is not None:
            record["until_epoch"] = until.timestamp()
            record["until_at"] = until.isoformat(timespec="seconds")
        try:
            atomic_write_json(POLICY_FILE, record)
        except OSError as error:
            detail = error.strerror or error.__class__.__name__
            message = self.mark_policy_error(
                f"operating policy write failed: {detail[:120]}"
            )
            self.policy_write_error = message
            return False
        self.clear_policy_error(clear_write_error=True)
        return True

    def test_session_active(self) -> bool:
        deadline = getattr(self, "test_session_deadline_monotonic", None)
        if deadline is None:
            return False
        if time.monotonic() < deadline:
            return True
        self.test_session_deadline_monotonic = None
        self.test_session_until_epoch = None
        log("temporary test session expired; persistent operating policy restored")
        return False

    def begin_test_session(self, duration: int) -> None:
        duration = min(7200, max(60, int(duration)))
        self.test_session_deadline_monotonic = time.monotonic() + duration
        self.test_session_until_epoch = time.time() + duration
        self.reason = "temporary test session requested"
        log(
            f"temporary test session started for up to {duration}s; "
            "persistent operating policy is unchanged"
        )

    def finish_test_session(self) -> None:
        was_active = self.test_session_active()
        self.test_session_deadline_monotonic = None
        self.test_session_until_epoch = None
        if was_active:
            log("temporary test session finished; restoring persistent operating policy")

        desired, desired_reason = self.desired_state(datetime.now().astimezone())
        if not desired and self.proc is not None and self.proc.poll() is None:
            self.stop_server(
                f"temporary test completed; {desired_reason}",
                waittime=1,
                final_message=FINAL_TEST_MESSAGE,
                require_graceful=True,
            )
        self.reason = desired_reason

    def desired_state(
        self,
        now: datetime,
        policy_record: dict[str, Any] | None = None,
    ) -> tuple[bool, str]:
        record = policy_record if policy_record is not None else self.policy_record(now)
        policy = str(record.get("override", "auto"))
        if policy == "invalid":
            process = getattr(self, "proc", None)
            running = process is not None and process.poll() is None
            disposition = "existing game remains running" if running else "automatic start is blocked"
            return (
                running,
                f"persistent operating policy unavailable; {disposition}: "
                f"{record.get('error', 'invalid')}",
            )
        if self.test_session_active():
            return True, "temporary test session"
        if policy == "started":
            return True, "manual override"
        if policy == "stopped":
            return False, "manual override"
        active = is_in_active_window(now, self.active_window)
        return active, "inside active window" if active else "outside active window"

    def status(self) -> dict[str, Any]:
        now = datetime.now().astimezone()
        policy_record = self.policy_record(now)
        desired, desired_reason = self.desired_state(now, policy_record)
        test_session_active = self.test_session_active()
        running = self.proc is not None and self.proc.poll() is None
        uptime = (
            max(0.0, time.monotonic() - self.last_started_monotonic)
            if running and self.last_started_monotonic is not None
            else None
        )
        return {
            "instance": self.instance,
            "manager": "running",
            "game": "running" if running else self.phase,
            "pid": self.proc.pid if running and self.proc else None,
            "game_uptime_seconds": int(uptime) if uptime is not None else None,
            "game_exit_count": self.game_exit_count,
            "last_exit_code": self.last_exit_code,
            "desired_running": desired,
            "desired_reason": desired_reason,
            "policy": policy_record.get("override", "invalid"),
            "policy_until": policy_record.get("until_at"),
            "policy_valid": self.policy_error is None,
            "policy_error": self.policy_error,
            "test_session_active": test_session_active,
            "test_session_until": (
                datetime.fromtimestamp(self.test_session_until_epoch).astimezone().isoformat(
                    timespec="seconds"
                )
                if test_session_active and self.test_session_until_epoch is not None
                else None
            ),
            "active_window": self.active_window_text,
            "restart_times": [f"{value // 60:02d}:{value % 60:02d}" for value in self.restart_times],
            "management_api_port": int(os.getenv("MANAGER_API_PORT", "18080")),
            "automatic_updates": self.auto_update_enabled,
            "automatic_updates_disabled_reason": self.auto_update_disabled_reason,
            "installed_build_id": self.installed_build,
            "available_build_id": self.available_build,
            "last_update_check_at": self.last_update_check_at,
            "last_update_at": self.last_update_at,
            "last_update_error": self.last_update_error,
            "update_waiting_for_host_lock": self.update_waiting_for_lock is not None,
            "next_update_check_seconds": (
                max(0, int(self.next_update_check_monotonic - time.monotonic()))
                if self.auto_update_enabled
                or self.update_blocked
                or self.update_waiting_for_lock is not None
                else None
            ),
            "reason": self.reason,
            "updated_at": now.isoformat(timespec="seconds"),
            "updated_epoch": time.time(),
        }

    def write_status(self) -> bool:
        """Publish status without turning a reporting failure into game downtime."""
        try:
            atomic_write_json(STATUS_FILE, self.status())
        except OSError as error:
            detail = error.strerror or error.__class__.__name__
            message = f"supervisor status write failed: {detail[:160]}"
            now = time.monotonic()
            previous = getattr(self, "status_write_error", None)
            next_log = getattr(self, "next_status_write_error_log_monotonic", 0.0)
            self.status_write_error = message
            if message != previous or now >= next_log:
                log(f"{message}; the game process will continue and status publication will retry")
                self.next_status_write_error_log_monotonic = (
                    now + STATUS_WRITE_ERROR_LOG_INTERVAL_SECONDS
                )
            return False

        if getattr(self, "status_write_error", None) is not None:
            log("supervisor status publication recovered")
        self.status_write_error = None
        self.next_status_write_error_log_monotonic = 0.0
        return True

    def join_game_log_thread(self, timeout: float = 2.5) -> bool:
        thread = getattr(self, "game_log_thread", None)
        if thread is None:
            return True
        if thread is not threading.current_thread():
            thread.join(timeout=max(0.0, timeout))
        stopped = not thread.is_alive()
        if stopped:
            self.game_log_thread = None
        return stopped

    def disruptive_action_blocked_by_policy(self, action: str) -> bool:
        # Runtime supervisors always have policy_error. The hasattr guard keeps
        # small unit-test supervisors built with __new__ backward compatible.
        if hasattr(self, "policy_error"):
            self.policy_record(datetime.now().astimezone())
        error = getattr(self, "policy_error", None)
        if not error:
            return False
        message = (
            f"{action} blocked until the persistent operating policy is repaired: {error}"
        )
        self.reason = message
        if getattr(self, "proc", None) is None:
            self.phase = "policy-blocked"
        log(message)
        return True

    def relay_game_output(self, process: subprocess.Popen[Any]) -> None:
        if process.stdout is None:
            return
        relay = _GameLogRelay(getattr(self, "instance", "palworld"))
        relay.start()
        try:
            while True:
                line = _read_bounded_game_line(process.stdout)
                if line is None:
                    break
                if line:
                    relay.submit(line, self.active_restore_job_id)
        finally:
            process.stdout.close()
            if not relay.finish():
                print(
                    "game log sink did not stop within the bounded shutdown wait",
                    file=sys.stderr,
                    flush=True,
                )

    def update_required_before_game_start(
        self,
        reason: str,
        *,
        waittime: int,
        restart_announcement: bool,
        force_refresh: bool,
    ) -> bool:
        """Check the authoritative branch BuildID before stopping or starting a game."""
        self.last_update_check_at = datetime.now().astimezone().isoformat(timespec="seconds")
        self.last_prestart_update_check_monotonic = time.monotonic()
        try:
            current_build = installed_build_id()
        except RuntimeError as error:
            log(
                "installed Steam build cannot be verified before game start; "
                f"SteamCMD repair is required: {error}"
            )
            self.perform_update(
                f"pre-start repair: {reason}",
                waittime=waittime,
                restart_announcement=restart_announcement,
            )
            return True

        try:
            up_to_date, required_build = check_steam_update(
                current_build,
                force_refresh=force_refresh,
            )
        except (RuntimeError, ValueError) as error:
            # Availability wins when Steam's metadata service is temporarily
            # unavailable. The running build is preserved and runtime checks retry.
            self.installed_build = current_build
            self.last_update_error = str(error)
            self.next_update_check_monotonic = (
                time.monotonic() + min(60.0, self.update_retry_interval)
            )
            log(
                "Steam pre-start update check warning; starting the intact installed "
                f"build and retrying later: {error}"
            )
            return False

        self.installed_build = current_build
        self.available_build = None if up_to_date else required_build
        self.last_update_error = None
        if up_to_date:
            log(f"Steam pre-start build check: installed build {current_build} is current")
            return False
        log(
            f"Steam pre-start update detected: installed build={current_build}, "
            f"available build={required_build}"
        )
        self.perform_update(
            f"pre-start update detected: {reason}",
            waittime=waittime,
            restart_announcement=restart_announcement,
        )
        return True

    def start_server(self, reason: str, *, update_before_start: bool = True) -> None:
        if self.proc is not None and self.proc.poll() is None:
            return
        if self.disruptive_action_blocked_by_policy("game start"):
            return
        self.join_game_log_thread()
        if self.update_blocked:
            log("game server start is blocked until the failed update is repaired")
            return
        if update_before_start and parse_bool(os.getenv("UPDATE_ON_START"), True):
            last_check = getattr(self, "last_prestart_update_check_monotonic", 0.0)
            if time.monotonic() - last_check >= 30.0:
                log(f"checking Steam updates before game start ({reason})")
                if self.update_required_before_game_start(
                    reason,
                    waittime=0,
                    restart_announcement=False,
                    force_refresh=False,
                ):
                    return
        command = [str(SERVER_SCRIPT), f"-port={os.getenv('SERVER_PORT', '8211')}"]
        if parse_bool(os.getenv("COMMUNITY_SERVER"), False):
            command.append("-publiclobby")
        extra_args = os.getenv("SERVER_ARGS", "").strip()
        if extra_args:
            command.extend(shlex.split(extra_args))

        self.phase = "starting"
        self.reason = reason
        self.write_status()
        log(f"starting game server ({reason}): {shlex.join(command)}")
        self.proc = subprocess.Popen(
            command,
            cwd=GAME_DIR,
            start_new_session=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        self.game_log_thread = threading.Thread(
            target=self.relay_game_output,
            args=(self.proc,),
            name=f"{self.instance}-game-log",
            daemon=True,
        )
        self.game_log_thread.start()
        self.last_started_monotonic = time.monotonic()
        self.next_start_monotonic = 0.0
        self.phase = "running"

    def signal_process_group(self, sig: signal.Signals) -> None:
        if self.proc is None or self.proc.poll() is not None:
            return
        try:
            os.killpg(self.proc.pid, sig)
        except ProcessLookupError:
            pass

    def wait_for_exit(self, seconds: float) -> bool:
        if self.proc is None:
            return True
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                return True
            time.sleep(0.5)
        return self.proc.poll() is not None

    def stop_server(
        self,
        reason: str,
        waittime: int | None = None,
        force: bool = False,
        message: str | None = None,
        countdown_message: str | None = None,
        final_message: str | None = None,
        require_graceful: bool = False,
        final_action: str = "shutdown",
    ) -> bool:
        if final_action not in {"shutdown", "stop"}:
            raise ValueError(f"unsupported final REST action: {final_action!r}")
        if self.proc is None or self.proc.poll() is not None:
            self.proc = None
            self.join_game_log_thread()
            self.last_started_monotonic = None
            self.phase = "stopped"
            self.reason = reason
            return True

        waittime = self.shutdown_wait if waittime is None else max(0, waittime)
        self.phase = "stopping"
        self.reason = reason
        self.write_status()
        log(f"stopping game server ({reason})")

        api_requested = False
        shutdown_waittime = waittime
        if parse_bool(os.getenv("PAL_SETTING_RESTAPIEnabled"), False):
            try:
                if force:
                    api_request("stop", method="POST", timeout=5)
                else:
                    if message and waittime > 0:
                        remaining_waittime = waittime
                        try:
                            api_request(
                                "announce",
                                method="POST",
                                body={"message": message},
                                timeout=5,
                            )
                            log(
                                f"shutdown warning sent; waiting {waittime}s before save and "
                                f"{final_action}"
                            )
                            if countdown_message:
                                countdown_start = min(10, waittime)
                                lead_time = waittime - countdown_start
                                if lead_time > 0:
                                    if self.wait_for_exit(lead_time):
                                        api_requested = True
                                    remaining_waittime = countdown_start
                                if not api_requested:
                                    for seconds_left in range(countdown_start, 0, -1):
                                        remaining_waittime = seconds_left
                                        api_request(
                                            "announce",
                                            method="POST",
                                            body={
                                                "message": countdown_message.replace(
                                                    "{seconds}", str(seconds_left)
                                                )
                                            },
                                            timeout=5,
                                        )
                                        if self.wait_for_exit(1):
                                            api_requested = True
                                            break
                                        remaining_waittime = seconds_left - 1
                            else:
                                if self.wait_for_exit(waittime):
                                    api_requested = True
                                remaining_waittime = 0
                            shutdown_waittime = remaining_waittime
                        except RuntimeError as error:
                            shutdown_waittime = remaining_waittime
                            log(
                                "announce/countdown warning; using the REST shutdown countdown "
                                f"for the remaining {shutdown_waittime}s: {error}"
                            )
                    try:
                        if not api_requested:
                            api_request("save", method="POST", timeout=5)
                    except RuntimeError as error:
                        log(f"save request warning: {error}")
                        if require_graceful:
                            self.phase = "running"
                            self.reason = f"{reason} postponed because world save was unavailable"
                            log(f"game server remains running; {reason} postponed to protect world data")
                            return False
                    if not api_requested:
                        if final_action == "stop":
                            api_request("stop", method="POST", timeout=5)
                            shutdown_waittime = 0
                        else:
                            # Pocketpair documents waittime as required. Some server
                            # versions reject 0 even after our own countdown.
                            shutdown_waittime = max(1, shutdown_waittime)
                            shutdown_body: dict[str, Any] = {"waittime": shutdown_waittime}
                            if final_message:
                                shutdown_body["message"] = final_message
                            api_request(
                                "shutdown",
                                method="POST",
                                body=shutdown_body,
                                timeout=5,
                            )
                api_requested = True
            except RuntimeError as error:
                action = f"{reason} will be postponed" if require_graceful else "falling back to process signal"
                log(f"REST API shutdown unavailable; {action}: {error}")

        if api_requested and self.wait_for_exit(shutdown_waittime + 20):
            log("game server stopped cleanly through the REST API")
        else:
            if require_graceful and self.proc is not None and self.proc.poll() is None:
                self.phase = "running"
                self.reason = f"{reason} postponed because graceful shutdown was unavailable"
                log(f"game server remains running; {reason} postponed until a graceful shutdown is available")
                return False
            self.signal_process_group(signal.SIGTERM)
            if not self.wait_for_exit(20):
                log("game server did not stop after SIGTERM; sending SIGKILL")
                self.signal_process_group(signal.SIGKILL)
                self.wait_for_exit(5)

        self.proc = None
        self.join_game_log_thread()
        self.last_started_monotonic = None
        self.phase = "stopped"
        self.reason = reason
        return True

    def shutdown_server(
        self,
        reason: str,
        waittime: int | None = None,
        *,
        final_action: str = "shutdown",
        final_message: str = FINAL_SHUTDOWN_MESSAGE,
    ) -> bool:
        waittime = self.shutdown_warning_seconds if waittime is None else max(0, waittime)
        warning = render_timed_message(self.shutdown_warning_message, waittime)
        return self.stop_server(
            reason,
            waittime=waittime,
            message=warning,
            countdown_message=self.shutdown_countdown_message,
            final_message=final_message,
            require_graceful=True,
            final_action=final_action,
        )

    def restart_server(self, reason: str, waittime: int | None = None) -> bool:
        if self.disruptive_action_blocked_by_policy("game restart"):
            return False
        waittime = self.restart_warning_seconds if waittime is None else max(0, waittime)
        if parse_bool(os.getenv("UPDATE_ON_START"), True):
            if self.update_required_before_game_start(
                reason,
                waittime=waittime,
                restart_announcement=True,
                force_refresh=True,
            ):
                return True
        warning = render_timed_message(self.restart_warning_message, waittime)
        stopped = self.stop_server(
            reason,
            waittime=waittime,
            message=warning,
            countdown_message=self.restart_countdown_message,
            final_message=FINAL_RESTART_MESSAGE,
            require_graceful=True,
        )
        if stopped:
            desired, desired_reason = self.desired_state(datetime.now().astimezone())
            if desired:
                self.start_server(reason, update_before_start=False)
            else:
                self.phase = "stopped"
                self.reason = desired_reason
        return stopped

    def perform_update(
        self,
        reason: str,
        waittime: int | None = None,
        *,
        restart_announcement: bool = False,
    ) -> None:
        if self.disruptive_action_blocked_by_policy("server update"):
            self.update_waiting_for_lock = None
            self.update_waiting_for_lock_waittime = None
            self.update_waiting_for_restart_announcement = False
            self.last_update_error = self.reason
            return
        if self.update_in_progress:
            return
        waittime = self.update_warning_seconds if waittime is None else max(0, waittime)
        with shared_update_lock(blocking=False) as lock_state:
            if not lock_state.acquired:
                self.update_waiting_for_lock = reason
                self.update_waiting_for_lock_waittime = waittime
                self.update_waiting_for_restart_announcement = restart_announcement
                self.next_update_check_monotonic = (
                    time.monotonic() + UPDATE_LOCK_RETRY_SECONDS
                )
                if lock_state.error is not None:
                    self.last_update_error = lock_state.error
                    log(
                        f"{lock_state.error}; {self.instance} game state is preserved and will retry in "
                        f"{UPDATE_LOCK_RETRY_SECONDS:g}s"
                    )
                else:
                    log(
                        "another Palworld server owns the shared host update lock; "
                        f"{self.instance} game state is preserved and will retry in "
                        f"{UPDATE_LOCK_RETRY_SECONDS:g}s"
                    )
                self.write_status()
                return

            # The host lock is deliberately acquired before player warnings and
            # shutdown. It remains held through SteamCMD and the game restart, so
            # another server can never be stopped merely to wait for this one.
            self.update_waiting_for_lock = None
            self.update_waiting_for_lock_waittime = None
            self.update_waiting_for_restart_announcement = False
            self.update_in_progress = True
            try:
                if self.proc is not None and self.proc.poll() is None:
                    warning_template = (
                        self.restart_warning_message
                        if restart_announcement
                        else self.update_warning_message
                    )
                    warning = render_timed_message(warning_template, waittime)
                    if not self.stop_server(
                        reason,
                        waittime=waittime,
                        message=warning,
                        countdown_message=self.restart_countdown_message,
                        final_message=(
                            FINAL_RESTART_MESSAGE
                            if restart_announcement
                            else FINAL_UPDATE_MESSAGE
                        ),
                        require_graceful=True,
                    ):
                        self.last_update_error = "graceful shutdown unavailable; update postponed"
                        self.next_update_check_monotonic = (
                            time.monotonic() + self.update_retry_interval
                        )
                        return
                if self.terminate_requested:
                    self.phase = "stopped"
                    self.reason = "container stopping"
                    return

                self.phase = "updating"
                self.reason = reason
                self.write_status()
                log(f"starting SteamCMD update ({reason})")
                install_or_update(force_update=True, update_lock_held=True)
                prepare_game_files()

                try:
                    self.installed_build = installed_build_id()
                except RuntimeError as error:
                    self.installed_build = None
                    log(f"update completed, but installed build ID could not be read: {error}")
                self.available_build = None
                self.last_update_at = datetime.now().astimezone().isoformat(timespec="seconds")
                self.last_update_error = None
                self.update_blocked = False
                self.last_prestart_update_check_monotonic = time.monotonic()
                if self.installed_build is not None:
                    branch = os.getenv("STEAM_BETA", "").strip() or "public"
                    try:
                        _write_cached_available_build(branch, self.installed_build)
                    except OSError as error:
                        log(f"Steam build cache could not be updated: {error}")
                self.next_update_check_monotonic = time.monotonic() + self.update_check_interval
                self.phase = "stopped"
                self.reason = "update completed"
                log(f"SteamCMD update completed; installed build={self.installed_build}")

                desired, desired_reason = self.desired_state(datetime.now().astimezone())
                if desired:
                    self.start_server(
                        f"update completed; {desired_reason}",
                        update_before_start=False,
                    )
            except Exception as error:
                self.update_blocked = True
                self.phase = "update-failed"
                self.reason = f"update failed: {error}"
                self.last_update_error = str(error)
                self.next_update_check_monotonic = time.monotonic() + self.update_retry_interval
                log(
                    f"SteamCMD update failed; game remains stopped and repair will retry in "
                    f"{self.update_retry_interval:g}s: {error}"
                )
            finally:
                self.update_in_progress = False
                self.write_status()

    def check_automatic_update(self) -> None:
        if getattr(self, "policy_error", None):
            if self.update_waiting_for_lock is not None:
                self.last_update_error = (
                    "pending update cancelled because the persistent operating policy "
                    "requires repair"
                )
                self.update_waiting_for_lock = None
                self.update_waiting_for_lock_waittime = None
                self.update_waiting_for_restart_announcement = False
            return
        if self.update_in_progress or time.monotonic() < self.next_update_check_monotonic:
            return
        if self.update_waiting_for_lock is not None:
            self.perform_update(
                self.update_waiting_for_lock,
                waittime=self.update_waiting_for_lock_waittime,
                restart_announcement=getattr(
                    self,
                    "update_waiting_for_restart_announcement",
                    False,
                ),
            )
            return
        if self.update_blocked:
            self.perform_update("retrying failed update", waittime=0)
            return
        if not self.auto_update_enabled:
            return

        self.next_update_check_monotonic = time.monotonic() + self.update_check_interval
        self.last_update_check_at = datetime.now().astimezone().isoformat(timespec="seconds")
        try:
            current_build = installed_build_id()
            up_to_date, required_build = check_steam_update(current_build)
            self.installed_build = current_build
            self.available_build = None if up_to_date else required_build
            self.last_update_error = None
            if up_to_date:
                log(f"Steam build check: installed build {current_build} is current")
                return
            log(
                f"Steam update detected: installed build={current_build}, "
                f"required build={required_build if required_build is not None else 'unknown'}"
            )
            self.perform_update("automatic update detected")
        except (RuntimeError, ValueError) as error:
            self.last_update_error = str(error)
            self.next_update_check_monotonic = (
                time.monotonic() + min(60.0, self.update_retry_interval)
            )
            log(f"Steam update check warning; game continues running: {error}")

    def apply_start_request_policy(self, now: datetime) -> bool:
        policy, until = start_policy_for_request(now, self.active_window)
        if not self.set_policy(policy, until=until):
            return False
        if until is None:
            log("manual start requested; automatic operating schedule is active")
        else:
            log(
                "manual start requested outside the active window; "
                f"server will run now and automatic schedule resumes at {until.isoformat(timespec='seconds')}"
            )
        return True

    def apply_shutdown_request_policy(self, now: datetime) -> bool:
        policy, until = shutdown_policy_for_request(now, self.active_window)
        if not self.set_policy(policy, until=until):
            return False
        if until is None:
            log("manual shutdown override remains until the next start request")
        else:
            log(
                "manual shutdown override active; automatic schedule resumes at "
                f"{until.isoformat(timespec='seconds')}"
            )
        return True

    @staticmethod
    def restore_event(job_id: str, message: str, *, level: str = "info") -> None:
        timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
        append_restore_event(
            job_id,
            {
                "type": "log",
                "timestamp": timestamp,
                "level": level,
                "message": message,
            },
        )
        log(message, source="restore")

    def perform_restore(self, job_id: str, backup_name: str, waittime: int) -> None:
        if self.disruptive_action_blocked_by_policy("world restore"):
            message = self.reason
            timestamp = datetime.now().astimezone().isoformat(timespec="seconds")
            try:
                try:
                    append_restore_event(
                        job_id,
                        {
                            "type": "log",
                            "timestamp": timestamp,
                            "level": "error",
                            "message": message,
                        },
                    )
                except OSError:
                    pass
                atomic_write_json(
                    restore_result_file(job_id),
                    {
                        "type": "result",
                        "success": False,
                        "message": message,
                        "completed_at": timestamp,
                    },
                )
            finally:
                self.write_status()
            return
        was_running = self.proc is not None and self.proc.poll() is None
        self.active_restore_job_id = job_id
        success = False
        result_message = "world restore failed"
        world_directory: Path | None = None
        RESTORE_JOBS_DIR.mkdir(parents=True, exist_ok=True)
        try:
            self.restore_event(job_id, f"restore request accepted: backup={backup_name}")
            preferred_guid = None
            if was_running:
                try:
                    info = api_request("info", timeout=3.0)
                    preferred_guid = reported_world_guid(info if isinstance(info, dict) else None)
                except (OSError, RuntimeError, ValueError) as error:
                    self.restore_event(
                        job_id,
                        f"active-world REST lookup unavailable; using local settings: {error}",
                        level="warning",
                    )
            world_directory = discover_world_directory(preferred_guid=preferred_guid)
            self.restore_event(job_id, f"world directory discovered: {world_directory}")
            selected = backup_directory(world_directory, backup_name)
            file_count, size_bytes = payload_statistics(selected)
            self.restore_event(
                job_id,
                f"selected backup validated: path={selected}, files={file_count}, bytes={size_bytes}",
            )
            space = ensure_restore_disk_space(world_directory, selected)
            self.restore_event(
                job_id,
                "restore disk preflight passed: "
                f"free={space['free_bytes']}, required={space['required_bytes']} "
                f"(current={space['current_bytes']}, selected={space['backup_bytes']}, "
                f"reserve={space['reserve_bytes']})",
            )

            if was_running:
                self.restore_event(
                    job_id,
                    f"safe shutdown started; player warning and save wait={waittime}s",
                )
                if not self.shutdown_server(
                    "world restore requested",
                    waittime=waittime,
                    final_message=FINAL_RESTORE_MESSAGE,
                ):
                    raise RuntimeError("safe shutdown failed; active world was not modified")
                self.restore_event(job_id, "game server stopped cleanly")
            else:
                self.restore_event(job_id, "game server was already stopped")

            self.phase = "restoring"
            self.reason = f"restoring backup {backup_name}"
            self.write_status()
            self.restore_event(job_id, "preserving the current world before replacement")
            deleted_snapshot = create_deleted_snapshot(world_directory)
            self.restore_event(
                job_id,
                f"current world preserved: {deleted_snapshot}",
            )

            self.restore_event(job_id, "copying and verifying the selected backup")
            staged = stage_backup(world_directory, backup_name)
            self.restore_event(job_id, f"restore staging verified: {staged}")
            self.restore_event(job_id, "replacing Players, LevelMeta.sav, and Level.sav")
            replace_world_payload(world_directory, staged)
            restored_files, restored_bytes = payload_statistics(world_directory)
            self.restore_event(
                job_id,
                f"world payload replacement completed: files={restored_files}, bytes={restored_bytes}",
            )

            desired, desired_reason = self.desired_state(datetime.now().astimezone())
            if was_running and desired and not self.terminate_requested:
                self.restore_event(job_id, "starting the game server with the restored world")
                self.start_server(f"world restore completed: {backup_name}")
                self.restore_event(job_id, "game server start requested; waiting for REST API readiness")
                deadline = time.monotonic() + 120
                next_notice = time.monotonic() + 10
                while time.monotonic() < deadline:
                    if self.proc is None or self.proc.poll() is not None:
                        exit_code = None if self.proc is None else self.proc.returncode
                        raise RuntimeError(f"restored game server exited during startup: {exit_code}")
                    try:
                        api_request("info", timeout=2)
                        self.restore_event(job_id, "restored game server REST API is ready")
                        break
                    except RuntimeError:
                        if time.monotonic() >= next_notice:
                            self.restore_event(job_id, "waiting for the restored game server to become ready")
                            next_notice = time.monotonic() + 10
                        time.sleep(1)
                else:
                    raise RuntimeError("restored game server did not become ready within 120 seconds")
            elif was_running:
                self.restore_event(
                    job_id,
                    f"restore completed while schedule is stopped; server remains stopped ({desired_reason})",
                )
            else:
                self.restore_event(job_id, "restore completed; server remains stopped as it was before restore")

            success = True
            result_message = f"world restored from {backup_name}"
            self.phase = "running" if self.proc is not None and self.proc.poll() is None else "stopped"
            self.reason = result_message
            self.restore_event(job_id, result_message)
        except Exception as error:
            result_message = str(error)
            self.phase = "restore-failed"
            self.reason = f"world restore failed: {error}"
            try:
                self.restore_event(job_id, f"world restore failed: {error}", level="error")
            except OSError:
                log(f"world restore failed and progress log is unavailable: {error}", source="restore")
            if was_running and (self.proc is None or self.proc.poll() is not None):
                try:
                    desired, _desired_reason = self.desired_state(datetime.now().astimezone())
                    if desired and not self.terminate_requested and world_directory is not None:
                        payload_statistics(world_directory)
                        self.start_server("recovering after failed world restore")
                        self.restore_event(job_id, "game server restarted after restore failure")
                except Exception as restart_error:
                    try:
                        self.restore_event(
                            job_id,
                            f"game server restart after restore failure also failed: {restart_error}",
                            level="error",
                        )
                    except OSError:
                        pass
        finally:
            self.active_restore_job_id = None
            atomic_write_json(
                restore_result_file(job_id),
                {
                    "type": "result",
                    "success": success,
                    "message": result_message,
                    "completed_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                },
            )
            self.write_status()

    def process_commands(self) -> None:
        for path in sorted(COMMANDS_DIR.glob("*.json")):
            command = read_json(path, {})
            try:
                action = command.get("action")
                default_waittime = (
                    self.restart_warning_seconds
                    if action == "restart"
                    else self.shutdown_warning_seconds
                )
                waittime = int(command.get("waittime", default_waittime))
                if action == "start":
                    if self.apply_start_request_policy(datetime.now().astimezone()):
                        self.reason = "manual start requested"
                elif action in {"stop", "shutdown"}:
                    if self.shutdown_server("manual safe shutdown requested", waittime=waittime):
                        self.apply_shutdown_request_policy(datetime.now().astimezone())
                elif action == "safe-stop":
                    if self.shutdown_server(
                        "manual safe stop requested",
                        waittime=waittime,
                        final_action="stop",
                    ):
                        self.apply_shutdown_request_policy(datetime.now().astimezone())
                elif action == "force-stop":
                    if self.set_policy("stopped"):
                        self.stop_server("manual force-stop requested", waittime=0, force=True)
                elif action == "restart":
                    if not self.disruptive_action_blocked_by_policy("game restart"):
                        if self.apply_start_request_policy(datetime.now().astimezone()):
                            self.restart_server("manual restart requested", waittime=waittime)
                elif action == "update":
                    update_wait = int(command.get("waittime", self.update_warning_seconds))
                    self.perform_update("manual update requested", waittime=update_wait)
                elif action == "restore":
                    self.perform_restore(
                        str(command.get("job_id", "")),
                        str(command.get("backup", "")),
                        waittime,
                    )
                elif action == "reset-stop":
                    if self.disruptive_action_blocked_by_policy("world reset"):
                        continue
                    if self.shutdown_server(
                        "world reset requested",
                        waittime=waittime,
                        final_message=FINAL_RESET_MESSAGE,
                    ):
                        # The host-side reset tool stops the container immediately
                        # after this state is observed. Keep the game stopped in the
                        # meantime so a schedule boundary cannot restart it while
                        # its bind-mounted Saved data is being backed up.
                        if self.set_policy("stopped"):
                            self.reason = "world reset prepared"
                elif action == "test-start":
                    if not self.disruptive_action_blocked_by_policy("temporary test start"):
                        self.begin_test_session(int(command.get("duration", 1800)))
                elif action == "test-finish":
                    self.finish_test_session()
                elif action == "auto":
                    if self.set_policy("auto"):
                        self.reason = "automatic schedule restored"
                else:
                    log(f"ignoring unknown control action: {action!r}")
            finally:
                path.unlink(missing_ok=True)

    def scheduled_restart_due(self, now: datetime) -> str | None:
        current_minute = now.hour * 60 + now.minute
        if current_minute in self.restart_times:
            slot = f"{now.date().isoformat()}-{current_minute}"
            if self.last_restart_slot != slot:
                self.last_restart_slot = slot
                return f"scheduled clock restart at {now:%H:%M}"
        return None

    def reconcile_game_state(
        self,
        desired: bool,
        desired_reason: str,
        game_running: bool,
    ) -> None:
        if self.policy_error:
            # A damaged policy is not authority to stop active players. Hold the
            # current process state and require an explicit policy repair.
            self.phase = "running" if game_running else "policy-blocked"
            self.reason = desired_reason
        elif (
            desired
            and self.proc is None
            and not self.update_blocked
            and time.monotonic() >= self.next_start_monotonic
        ):
            self.start_server(desired_reason)
        elif not desired and self.proc is not None:
            self.stop_server(desired_reason, final_message=FINAL_SCHEDULE_MESSAGE)
        elif not desired and not self.update_blocked:
            self.phase = "stopped"
            self.reason = desired_reason

    def run(self) -> None:
        log(
            f"supervisor ready: instance={self.instance}, active_window={self.active_window_text}, "
            f"restart_times={os.getenv('RESTART_TIMES', '') or 'off'}, "
            f"automatic_updates={'on' if self.auto_update_enabled else 'off'}"
        )
        if self.auto_update_disabled_reason:
            log(self.auto_update_disabled_reason)
        while not self.terminate_requested:
            # Validate the persistent policy before accepting queued disruptive
            # work. A corrupt policy never stops an already-running game, but it
            # must block new starts, restarts, updates, restores, and test starts.
            self.policy_record(datetime.now().astimezone())
            self.process_commands()
            now = datetime.now().astimezone()
            desired, desired_reason = self.desired_state(now)
            inside_active_window = is_in_active_window(now, self.active_window)

            if self.proc is not None and self.proc.poll() is not None:
                exit_code = self.proc.returncode
                self.proc = None
                self.join_game_log_thread()
                self.last_started_monotonic = None
                self.last_exit_code = exit_code
                if desired:
                    restart_delay = restart_delay_after_exit(exit_code, self.crash_delay)
                    if exit_code == 0:
                        self.game_exit_count = 0
                        self.phase = "restart-wait"
                        self.reason = "game process stopped cleanly; managed restart"
                        log("game process stopped cleanly; restarting now")
                    else:
                        self.game_exit_count += 1
                        self.phase = "crash-wait"
                        self.reason = f"game process exited with code {exit_code}"
                        log(f"game process exited with code {exit_code}; restarting in {restart_delay:g}s")
                    self.next_start_monotonic = time.monotonic() + restart_delay
                else:
                    self.phase = "stopped"
                    self.reason = desired_reason

            self.check_automatic_update()

            # An update and its player warning can span several minutes; refresh the
            # schedule decision before deciding whether the game should be running.
            now = datetime.now().astimezone()
            desired, desired_reason = self.desired_state(now)
            inside_active_window = is_in_active_window(now, self.active_window)

            game_running = self.proc is not None and self.proc.poll() is None
            uptime = (
                time.monotonic() - self.last_started_monotonic
                if game_running and self.last_started_monotonic is not None
                else None
            )
            if (
                not self.policy_error
                and scheduled_restart_allowed(inside_active_window, game_running, uptime)
            ):
                restart_reason = self.scheduled_restart_due(now)
                if restart_reason:
                    self.restart_server(restart_reason)

            self.reconcile_game_state(desired, desired_reason, game_running)

            self.write_status()
            time.sleep(1)

        self.stop_server("container stopping", final_message=FINAL_SHUTDOWN_MESSAGE)
        self.write_status()
        log("supervisor stopped")


def main() -> int:
    try:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            raise RuntimeError("Palworld container must run as a non-root user")
        MANAGER_DIR.mkdir(parents=True, exist_ok=True)
        supervisor = Supervisor()
        policy_record = supervisor.policy_record(datetime.now().astimezone())
        if policy_record.get("override") == "invalid":
            supervisor.phase = "policy-blocked"
            supervisor.reason = (
                "startup preparation blocked until the persistent operating policy is repaired: "
                f"{supervisor.policy_error or 'invalid policy'}"
            )
            supervisor.write_status()
            log(supervisor.reason)
        else:
            # Write a minimal pre-install status so that doctor.py's
            # wait_for_supervisor_status stays in the waiting loop and
            # shows SteamCMD installation progress instead of passing
            # through immediately.  The full supervisor status (including
            # policy and desired_running) is written after installation.
            supervisor.phase = "updating"
            supervisor.reason = "installing or updating game files"
            atomic_write_json(STATUS_FILE, {
                "manager": "running",
                "game": "updating",
                "reason": "installing or updating game files",
                "updated_epoch": time.time(),
                "updated_at": datetime.now().astimezone().isoformat(
                    timespec="seconds"
                ),
            })
            install_or_update()
            prepare_game_files()
            supervisor.installed_build = installed_build_id()
            supervisor.last_prestart_update_check_monotonic = time.monotonic()

        for recovered_world in recover_interrupted_restores():
            log(f"recovered interrupted world restore before server startup: {recovered_world}", source="restore")

        management_server, management_thread = start_management_api(
            lambda message: log(message, source="api")
        )

        def request_termination(signum: int, _frame: Any) -> None:
            log(f"received signal {signum}; requesting graceful shutdown")
            supervisor.terminate_requested = True

        signal.signal(signal.SIGTERM, request_termination)
        signal.signal(signal.SIGINT, request_termination)
        try:
            supervisor.run()
        finally:
            management_server.shutdown()
            management_server.server_close()
            management_thread.join(timeout=5)
        return 0
    except Exception as error:  # The container restart policy will retry fatal startup errors.
        log(f"fatal error: {error}")
        try:
            atomic_write_json(
                STATUS_FILE,
                {
                    "manager": "failed",
                    "game": "stopped",
                    "reason": str(error),
                    "updated_epoch": time.time(),
                    "updated_at": datetime.now().astimezone().isoformat(timespec="seconds"),
                },
            )
        except OSError:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main())
