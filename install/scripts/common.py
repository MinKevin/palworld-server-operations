"""Shared in-container helpers for the Palworld supervisor and palctl."""

from __future__ import annotations

import base64
import json
import os
import tempfile
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any


DATA_DIR = Path(os.getenv("DATA_DIR", "/palworld"))
MANAGER_DIR = DATA_DIR / "manager"
STATUS_FILE = MANAGER_DIR / "status.json"
POLICY_FILE = Path(os.getenv("POLICY_FILE", str(MANAGER_DIR / "policy.json")))
COMMANDS_DIR = MANAGER_DIR / "commands"
RESTORE_JOBS_DIR = MANAGER_DIR / "restore-jobs"


def atomic_write_text(path: Path, value: str, *, mode: int = 0o600) -> None:
    """Atomically write sensitive text with restrictive permissions."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        if hasattr(os, "fchmod"):
            os.fchmod(fd, mode)
        else:  # pragma: no cover - Windows-only local regression tests.
            os.chmod(temporary_name, mode)
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(value)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def atomic_write_json(path: Path, value: Any) -> None:
    """Write JSON without exposing a partially-written file to another process."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def read_json(path: Path, default: Any = None) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def queue_command(
    action: str,
    waittime: int | None = None,
    *,
    source: str = "local",
    parameters: dict[str, Any] | None = None,
) -> Path:
    """Atomically queue a supervisor command and return its path."""
    command: dict[str, Any] = {
        "action": action,
        "requested_at": time.time(),
        "source": source,
    }
    if waittime is not None:
        command["waittime"] = waittime
    if parameters:
        reserved = {"action", "requested_at", "source", "waittime"}
        conflict = reserved.intersection(parameters)
        if conflict:
            raise ValueError(f"reserved command fields: {', '.join(sorted(conflict))}")
        command.update(parameters)
    COMMANDS_DIR.mkdir(parents=True, exist_ok=True)
    path = COMMANDS_DIR / f"{time.time_ns()}-{uuid.uuid4().hex}.json"
    atomic_write_json(path, command)
    return path


def valid_job_id(value: str) -> bool:
    try:
        return uuid.UUID(value).hex == value.replace("-", "").lower()
    except (ValueError, AttributeError):
        return False


def restore_progress_file(job_id: str) -> Path:
    if not valid_job_id(job_id):
        raise ValueError("invalid restore job id")
    return RESTORE_JOBS_DIR / f"{job_id}.jsonl"


def restore_result_file(job_id: str) -> Path:
    if not valid_job_id(job_id):
        raise ValueError("invalid restore job id")
    return RESTORE_JOBS_DIR / f"{job_id}.result.json"


def append_restore_event(job_id: str, event: dict[str, Any]) -> None:
    path = restore_progress_file(job_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, ensure_ascii=False) + "\n")
        handle.flush()


def parse_bool(value: str | bool | None, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "y", "on"}:
        return True
    if normalized in {"0", "false", "no", "n", "off"}:
        return False
    raise ValueError(f"boolean value expected, got {value!r}")


def api_base_url() -> str:
    port = os.getenv("PAL_SETTING_RESTAPIPort", "8212")
    return os.getenv("PAL_API_BASE_URL", f"http://127.0.0.1:{port}/v1/api").rstrip("/")


def api_request(
    endpoint: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    timeout: float = 5.0,
) -> Any:
    """Call Pocketpair's local REST API using HTTP Basic authentication."""
    username = os.getenv("API_USERNAME", "admin")
    password = os.getenv("PAL_SETTING_AdminPassword", "")
    token = base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
    payload = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        f"{api_base_url()}/{endpoint.lstrip('/')}",
        data=payload,
        method=method.upper(),
        headers={
            "Accept": "application/json",
            "Authorization": f"Basic {token}",
            **({"Content-Type": "application/json"} if payload is not None else {}),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Palworld API HTTP {error.code}: {detail or error.reason}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Palworld API connection failed: {error.reason}") from error

    if not raw:
        return {"ok": True}
    try:
        return json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError:
        return {"ok": True, "response": raw.decode("utf-8", errors="replace")}
