#!/usr/bin/env python3
"""Single-port gateway for Palworld REST and Linux supervisor actions."""

from __future__ import annotations

import base64
import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import sqlite3
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlsplit

from common import (
    DATA_DIR,
    STATUS_FILE,
    api_request,
    queue_command,
    read_json,
    restore_progress_file,
    restore_result_file,
)
from world_backup import list_world_backups, reported_world_guid, validate_backup_name
from resource_metrics import ResourceUsageMonitor


API_PREFIX = "/v1/manager"
PALWORLD_API_PREFIX = "/v1/api"
VERIFY_PATH = "/v1/manager/verify"
PRODUCT_ID = "palworld-docker-manager"
PROTOCOL_VERSION = 1
ACCESS_TOKEN_HEADER = "X-Palworld-Manager-Token"
ACCESS_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{32,128}")
VERIFY_CHALLENGE_RE = re.compile(r"[a-f0-9]{64}")
ACTION_MAP = {
    "start": "start",
    "restart": "restart",
    "shutdown": "shutdown",
}
MAX_MANAGER_BODY_BYTES = 4096
MAX_PROXY_BODY_BYTES = 1024 * 1024
MAX_WAIT_SECONDS = 3600
RESTORE_STREAM_TIMEOUT_SECONDS = 3600
RESTORE_JOB_CLEANUP_TIMEOUT_SECONDS = 24 * 60 * 60
MAX_LOG_MESSAGE_CHARS = 2000
MAX_LOG_LINES = 5000
MAX_LOG_SCAN_LINES = 50000
MAX_LOG_SCAN_BYTES_PER_FILE = 4 * 1024 * 1024
MAX_HTTP_WORKERS = 16
HTTP_SOCKET_TIMEOUT_SECONDS = 15
HTTP_HEADER_DEADLINE_SECONDS = 15
HTTP_BODY_DEADLINE_SECONDS = 15
VALID_LOG_SOURCES = {"all", "game", "manager", "api", "update", "restore"}


class RequestReadDeadlineExpired(Exception):
    """Raised after an absolute request-input deadline closes the connection."""


def parse_basic_auth(value: str | None) -> tuple[str, str] | None:
    if not value or not value.startswith("Basic "):
        return None
    try:
        decoded = base64.b64decode(value[6:].strip(), validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return None
    if ":" not in decoded:
        return None
    return tuple(decoded.split(":", 1))  # type: ignore[return-value]


def credentials_match(value: str | None, username: str, password: str) -> bool:
    supplied = parse_basic_auth(value)
    if supplied is None:
        return False
    return hmac.compare_digest(supplied[0], username) and hmac.compare_digest(
        supplied[1], password
    )


def validate_access_token(value: str) -> str:
    token = value.strip()
    if not ACCESS_TOKEN_RE.fullmatch(token):
        raise ValueError("API_ACCESS_TOKEN must contain 32-128 URL-safe characters")
    return token


def access_token_matches(value: str | None, expected: str) -> bool:
    return bool(value) and hmac.compare_digest(value, expected)


def verification_proof(access_token: str, challenge: str) -> str:
    if not VERIFY_CHALLENGE_RE.fullmatch(challenge):
        raise ValueError("challenge must be 64 lowercase hexadecimal characters")
    message = f"{PRODUCT_ID}:{PROTOCOL_VERSION}:{challenge}".encode("utf-8")
    return hmac.new(access_token.encode("utf-8"), message, hashlib.sha256).hexdigest()


def action_from_path(path: str) -> str | None:
    clean_path = urlsplit(path).path.rstrip("/")
    prefix = f"{API_PREFIX}/"
    if not clean_path.startswith(prefix):
        return None
    return ACTION_MAP.get(clean_path[len(prefix) :])


def is_palworld_api_path(path: str) -> bool:
    clean_path = urlsplit(path).path.rstrip("/")
    return clean_path == PALWORLD_API_PREFIX or clean_path.startswith(
        f"{PALWORLD_API_PREFIX}/"
    )


def parse_waittime(payload: Any, default: int = 60) -> int:
    if payload is None:
        return default
    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object")
    value = payload.get("waittime", default)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("waittime must be an integer")
    if not 0 <= value <= MAX_WAIT_SECONDS:
        raise ValueError(f"waittime must be between 0 and {MAX_WAIT_SECONDS}")
    return value


def proxy_log_arguments(body: bytes) -> str:
    """Return selected, escaped REST arguments without logging credentials or player IDs."""
    if not body:
        return ""
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return ""
    if not isinstance(payload, dict):
        return ""
    fields: list[str] = []
    if "waittime" in payload:
        fields.append(
            "waittime="
            + json.dumps(payload["waittime"], ensure_ascii=False, separators=(",", ":"))
        )
    if "message" in payload:
        message = payload["message"]
        if isinstance(message, str) and len(message) > MAX_LOG_MESSAGE_CHARS:
            message = message[:MAX_LOG_MESSAGE_CHARS] + "…[truncated]"
        fields.append(
            "message=" + json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        )
    return " " + " ".join(fields) if fields else ""


def runtime_log_path() -> Path:
    return Path(os.getenv("RUNTIME_LOG_FILE", str(DATA_DIR / "logs/runtime.log")))


def tail_text_lines(
    path: Path,
    line_count: int,
    *,
    max_bytes: int = MAX_LOG_SCAN_BYTES_PER_FILE,
) -> list[str]:
    """Read only the end of a text log instead of loading the complete file."""
    if line_count <= 0 or not path.is_file():
        return []
    size = path.stat().st_size
    start = max(0, size - max_bytes)
    with path.open("rb") as handle:
        handle.seek(start)
        raw = handle.read()
    if start > 0:
        first_newline = raw.find(b"\n")
        raw = raw[first_newline + 1 :] if first_newline >= 0 else b""
    return raw.decode("utf-8", errors="replace").splitlines()[-line_count:]


def read_runtime_logs(line_count: int, source: str = "all") -> dict[str, Any]:
    if not 1 <= line_count <= MAX_LOG_LINES:
        raise ValueError(f"lines must be between 1 and {MAX_LOG_LINES}")
    if source not in VALID_LOG_SOURCES:
        raise ValueError(
            "source must be one of " + ", ".join(sorted(VALID_LOG_SOURCES))
        )

    path = runtime_log_path()
    try:
        backup_count = min(20, max(0, int(os.getenv("RUNTIME_LOG_BACKUP_COUNT", "5"))))
    except ValueError:
        backup_count = 5
    candidates = [path] + [path.with_name(f"{path.name}.{index}") for index in range(1, backup_count + 1)]
    scan_count = min(MAX_LOG_SCAN_LINES, max(line_count, line_count * 10))
    collected: list[str] = []
    scanned_files: list[str] = []
    marker = None if source == "all" else f"[{source}]"
    for candidate in candidates:
        if not candidate.is_file():
            continue
        scanned_files.append(candidate.name)
        values = tail_text_lines(candidate, scan_count)
        if marker is not None:
            values = [line for line in values if marker in line]
        collected = values + collected
        if len(collected) >= line_count:
            break
    selected = collected[-line_count:]
    return {
        "source": source,
        "requested_lines": line_count,
        "returned_lines": len(selected),
        "log_file": str(path),
        "scanned_files": scanned_files,
        "lines": selected,
    }


class ManagementHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(
        self,
        address: tuple[str, int],
        username: str,
        password: str,
        access_token: str,
        logger: Callable[[str], None],
        resource_monitor: ResourceUsageMonitor | None = None,
    ) -> None:
        self.api_username = username
        self.api_password = password
        self.access_token = validate_access_token(access_token)
        self.logger = logger
        self.resource_monitor = resource_monitor
        self.restore_lock = threading.Lock()
        self._request_slots = threading.BoundedSemaphore(MAX_HTTP_WORKERS)
        super().__init__(address, ManagementRequestHandler)

    def get_request(self) -> tuple[Any, Any]:
        request, client_address = super().get_request()
        request.settimeout(HTTP_SOCKET_TIMEOUT_SECONDS)
        return request, client_address

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._request_slots.acquire(blocking=False):
            try:
                request.sendall(
                    b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Connection: close\r\nContent-Length: 0\r\n\r\n"
                )
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()

    def server_close(self) -> None:
        if self.resource_monitor is not None:
            self.resource_monitor.stop()
        super().server_close()

    def release_restore_when_finished(self, job_id: str) -> None:
        """Keep the single-restore lock after a client disconnects."""
        progress_path = restore_progress_file(job_id)
        result_path = restore_result_file(job_id)

        def monitor() -> None:
            deadline = time.monotonic() + RESTORE_JOB_CLEANUP_TIMEOUT_SECONDS
            try:
                while time.monotonic() < deadline:
                    if result_path.exists():
                        progress_path.unlink(missing_ok=True)
                        result_path.unlink(missing_ok=True)
                        return
                    time.sleep(0.5)
            finally:
                self.restore_lock.release()

        threading.Thread(
            target=monitor,
            name=f"restore-cleanup-{job_id[:8]}",
            daemon=True,
        ).start()


class ManagementRequestHandler(BaseHTTPRequestHandler):
    server: ManagementHttpServer
    protocol_version = "HTTP/1.1"

    def setup(self) -> None:
        self._read_deadline_lock = threading.Lock()
        self._read_deadline_timer: threading.Timer | None = None
        self._read_deadline_generation = 0
        self._read_deadline_expired = threading.Event()
        super().setup()
        self._arm_read_deadline(HTTP_HEADER_DEADLINE_SECONDS)

    def _arm_read_deadline(self, seconds: float) -> None:
        """Bound a request-input phase independently of per-socket idle timeouts."""
        with self._read_deadline_lock:
            previous = self._read_deadline_timer
            self._read_deadline_generation += 1
            generation = self._read_deadline_generation
            self._read_deadline_expired.clear()
            timer = threading.Timer(
                seconds,
                self._expire_request_read,
                args=(generation,),
            )
            timer.daemon = True
            self._read_deadline_timer = timer
        if previous is not None:
            previous.cancel()
        timer.start()

    def _cancel_read_deadline(self) -> None:
        with self._read_deadline_lock:
            self._read_deadline_generation += 1
            timer = self._read_deadline_timer
            self._read_deadline_timer = None
        if timer is not None:
            timer.cancel()

    def _expire_request_read(self, generation: int) -> None:
        with self._read_deadline_lock:
            if (
                generation != self._read_deadline_generation
                or self._read_deadline_timer is None
            ):
                return
            self._read_deadline_timer = None
            self._read_deadline_expired.set()
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def handle(self) -> None:
        try:
            super().handle()
        except OSError:
            # Closing a socket from the deadline thread wakes blocked reads with
            # an OS-specific exception on some platforms (notably Windows).
            if not self._read_deadline_expired.is_set():
                raise

    def parse_request(self) -> bool:
        try:
            return super().parse_request()
        finally:
            # One request per TCP connection keeps idle keep-alive clients from
            # retaining a bounded worker slot. Response streaming is unaffected.
            self.close_connection = True
            self._cancel_read_deadline()

    def send_response_only(self, code: int, message: str | None = None) -> None:
        self._response_status_code = int(code)
        super().send_response_only(code, message)

    def end_headers(self) -> None:
        if getattr(self, "_response_status_code", 200) >= 200:
            self.send_header("Connection", "close")
        super().end_headers()

    def finish(self) -> None:
        self._cancel_read_deadline()
        super().finish()

    def send_json(self, status: int | HTTPStatus, body: dict[str, Any]) -> None:
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def authenticated(self) -> bool:
        if not credentials_match(
            self.headers.get("Authorization"),
            self.server.api_username,
            self.server.api_password,
        ):
            self.server.logger("gateway request rejected: invalid Basic credentials")
            self.send_response(HTTPStatus.UNAUTHORIZED)
            self.send_header("WWW-Authenticate", 'Basic realm="Palworld Manager"')
            payload = b'{"error":"valid Basic credentials required"}'
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
            return False
        if access_token_matches(
            self.headers.get(ACCESS_TOKEN_HEADER), self.server.access_token
        ):
            return True
        self.server.logger("gateway request rejected: missing or invalid API access token")
        self.send_response(HTTPStatus.FORBIDDEN)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        payload = b'{"error":"valid API access token required"}'
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)
        return False

    def write_chunk(self, value: dict[str, Any]) -> None:
        payload = (json.dumps(value, ensure_ascii=False) + "\n").encode("utf-8")
        self.wfile.write(f"{len(payload):X}\r\n".encode("ascii"))
        self.wfile.write(payload)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def stream_restore(self, job_id: str) -> bool:
        progress_path = restore_progress_file(job_id)
        result_path = restore_result_file(job_id)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        offset = 0
        completed = False
        deadline = time.monotonic() + RESTORE_STREAM_TIMEOUT_SECONDS
        try:
            self.write_chunk(
                {
                    "type": "log",
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                    "level": "info",
                    "message": f"restore command queued: job={job_id}",
                }
            )
            while time.monotonic() < deadline:
                if progress_path.exists():
                    with progress_path.open("rb") as handle:
                        handle.seek(offset)
                        while True:
                            line = handle.readline()
                            if not line:
                                break
                            try:
                                event = json.loads(line.decode("utf-8"))
                            except (UnicodeDecodeError, json.JSONDecodeError):
                                continue
                            if isinstance(event, dict):
                                self.write_chunk(event)
                        offset = handle.tell()
                result = read_json(result_path)
                if isinstance(result, dict):
                    self.write_chunk(result)
                    completed = True
                    break
                time.sleep(0.25)
            if not completed:
                self.write_chunk(
                    {
                        "type": "result",
                        "success": False,
                        "message": "restore stream timed out; inspect runtime.log for server-side progress",
                    }
                )
        except (BrokenPipeError, ConnectionResetError, OSError):
            completed = False
        finally:
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            if completed:
                progress_path.unlink(missing_ok=True)
                result_path.unlink(missing_ok=True)
        return completed

    def read_body(self, limit: int) -> bytes:
        raw_length = self.headers.get("Content-Length", "0")
        content_length = int(raw_length)
        if not 0 <= content_length <= limit:
            raise ValueError(f"request body must not exceed {limit} bytes")
        if not content_length:
            return b""
        self._arm_read_deadline(HTTP_BODY_DEADLINE_SECONDS)
        try:
            try:
                body = self.rfile.read(content_length)
            except OSError:
                if self._read_deadline_expired.is_set():
                    raise RequestReadDeadlineExpired from None
                raise
            if self._read_deadline_expired.is_set():
                raise RequestReadDeadlineExpired
        finally:
            self._cancel_read_deadline()
        if len(body) != content_length:
            raise ValueError("request body ended before Content-Length was reached")
        return body

    def proxy_palworld_request(self) -> None:
        connection: http.client.HTTPConnection | None = None
        body = b""
        clean_path = urlsplit(self.path).path
        try:
            body = self.read_body(MAX_PROXY_BODY_BYTES)
            log_arguments = proxy_log_arguments(body)
            rest_port = int(os.getenv("PAL_SETTING_RESTAPIPort", "8212"))
            if not 1 <= rest_port <= 65535:
                raise ValueError("PAL_SETTING_RESTAPIPort must be between 1 and 65535")
            headers = {
                "Accept": self.headers.get("Accept", "application/json"),
                "Authorization": self.headers.get("Authorization", ""),
            }
            content_type = self.headers.get("Content-Type")
            if content_type:
                headers["Content-Type"] = content_type
            connection = http.client.HTTPConnection("127.0.0.1", rest_port, timeout=15)
            connection.request(
                self.command,
                self.path,
                body=body if body else None,
                headers=headers,
            )
            response = connection.getresponse()
            payload = response.read()
            self.server.logger(
                f"official REST {self.command} {clean_path} status={response.status}"
                f"{log_arguments}"
            )
            self.send_response(response.status, response.reason)
            self.send_header(
                "Content-Type",
                response.getheader("Content-Type", "application/json; charset=utf-8"),
            )
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if payload:
                self.wfile.write(payload)
        except RequestReadDeadlineExpired:
            self.server.logger(
                f"official REST {self.command} {clean_path} rejected: "
                "body deadline exceeded"
            )
        except ValueError as error:
            self.server.logger(
                f"official REST {self.command} {clean_path} status=400"
                f"{proxy_log_arguments(body)}"
            )
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
        except (OSError, http.client.HTTPException) as error:
            self.server.logger(
                f"official REST {self.command} {clean_path} status=502"
                f"{proxy_log_arguments(body)}"
            )
            self.send_json(
                HTTPStatus.BAD_GATEWAY,
                {"error": f"Palworld REST API unavailable: {error}"},
            )
        finally:
            if connection is not None:
                connection.close()

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self.authenticated():
            return
        clean_path = urlsplit(self.path).path.rstrip("/")
        if clean_path == VERIFY_PATH:
            try:
                query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
                challenge = query.get("challenge", [""])[-1].strip()
                proof = verification_proof(self.server.access_token, challenge)
                self.send_json(
                    HTTPStatus.OK,
                    {
                        "product": PRODUCT_ID,
                        "protocol": PROTOCOL_VERSION,
                        "token_verified": True,
                        "instance": os.getenv("INSTANCE_NAME", "unknown"),
                        "challenge": challenge,
                        "proof": proof,
                    },
                )
            except ValueError as error:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return
        if is_palworld_api_path(self.path):
            self.proxy_palworld_request()
            return
        if clean_path == f"{API_PREFIX}/logs":
            try:
                query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
                raw_lines = query.get("lines", ["500"])[-1]
                if not raw_lines.isdigit():
                    raise ValueError("lines must be an integer")
                source = query.get("source", ["all"])[-1].strip().lower()
                payload = read_runtime_logs(int(raw_lines), source)
                self.server.logger(
                    "management runtime log tail completed: "
                    f"source={source}, lines={payload['returned_lines']}"
                )
                self.send_json(HTTPStatus.OK, payload)
            except (OSError, ValueError) as error:
                self.server.logger(f"management runtime log tail failed: {error}")
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return
        if clean_path == f"{API_PREFIX}/resources/current":
            if self.server.resource_monitor is None:
                self.send_json(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    {"error": "resource usage monitor unavailable"},
                )
                return
            payload = self.server.resource_monitor.current()
            if payload is None:
                self.send_json(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    {"error": "resource usage sample is not ready"},
                )
                return
            self.send_json(HTTPStatus.OK, payload)
            return
        if clean_path == f"{API_PREFIX}/resources/history":
            if self.server.resource_monitor is None:
                self.send_json(
                    HTTPStatus.SERVICE_UNAVAILABLE,
                    {"error": "resource usage monitor unavailable"},
                )
                return
            try:
                query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
                raw_seconds = query.get("seconds", ["604800"])[-1]
                raw_points = query.get("points", ["600"])[-1]
                if not raw_seconds.isdigit() or not raw_points.isdigit():
                    raise ValueError("seconds and points must be integers")
                payload = self.server.resource_monitor.history(
                    int(raw_seconds), int(raw_points)
                )
                self.send_json(HTTPStatus.OK, payload)
            except ValueError as error:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            except (OSError, sqlite3.Error) as error:
                self.server.logger(f"resource usage history failed: {error}")
                self.send_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"error": "resource usage history unavailable"},
                )
            return
        if clean_path == f"{API_PREFIX}/backups":
            try:
                preferred_guid = None
                status = read_json(STATUS_FILE)
                if isinstance(status, dict) and status.get("game") == "running":
                    try:
                        info = api_request("info", timeout=2.0)
                        preferred_guid = reported_world_guid(info if isinstance(info, dict) else None)
                    except (OSError, RuntimeError, ValueError) as error:
                        self.server.logger(
                            f"management backup list active-world lookup warning: {error}"
                        )
                payload = list_world_backups(preferred_guid=preferred_guid)
                self.server.logger(
                    "management backup list completed: "
                    f"world={payload['world_guid']}, count={len(payload['backups'])}"
                )
                self.send_json(HTTPStatus.OK, payload)
            except (OSError, RuntimeError, ValueError) as error:
                self.server.logger(f"management backup list failed: {error}")
                self.send_json(HTTPStatus.CONFLICT, {"error": str(error)})
            return
        if clean_path != f"{API_PREFIX}/status":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "endpoint not found"})
            return
        status = read_json(STATUS_FILE)
        if not isinstance(status, dict):
            self.send_json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "status unavailable"})
            return
        self.send_json(HTTPStatus.OK, status)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if not self.authenticated():
            return
        if is_palworld_api_path(self.path):
            self.proxy_palworld_request()
            return
        clean_path = urlsplit(self.path).path.rstrip("/")
        if clean_path == f"{API_PREFIX}/restore":
            if not self.server.restore_lock.acquire(blocking=False):
                self.send_json(HTTPStatus.CONFLICT, {"error": "another restore is already running"})
                return
            release_in_handler = True
            try:
                try:
                    raw = self.read_body(MAX_MANAGER_BODY_BYTES)
                    payload = json.loads(raw.decode("utf-8")) if raw else {}
                    if not isinstance(payload, dict):
                        raise ValueError("JSON body must be an object")
                    backup_name = str(payload.get("backup", ""))
                    validate_backup_name(backup_name)
                    waittime = parse_waittime(payload)
                except RequestReadDeadlineExpired:
                    self.server.logger(
                        "management restore request rejected: body deadline exceeded"
                    )
                    return
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
                    self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
                    return
                job_id = uuid.uuid4().hex
                command_path = queue_command(
                    "restore",
                    waittime,
                    source="management-api",
                    parameters={"backup": backup_name, "job_id": job_id},
                )
                self.server.logger(
                    f"management API accepted synchronous restore backup={backup_name}, "
                    f"waittime={waittime}s, job={job_id}, command={command_path.name}"
                )
                completed = self.stream_restore(job_id)
                if not completed:
                    self.server.release_restore_when_finished(job_id)
                    release_in_handler = False
            finally:
                if release_in_handler:
                    self.server.restore_lock.release()
            return
        action = action_from_path(self.path)
        if action is None:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "endpoint not found"})
            return
        try:
            raw = self.read_body(MAX_MANAGER_BODY_BYTES)
            payload = json.loads(raw.decode("utf-8")) if raw else None
            waittime = None if action == "start" else parse_waittime(payload)
        except RequestReadDeadlineExpired:
            self.server.logger(
                f"management API rejected action={action}: body deadline exceeded"
            )
            return
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return

        command_path = queue_command(action, waittime, source="management-api")
        wait_description = "not-applicable" if waittime is None else f"{waittime}s"
        self.server.logger(
            f"management API accepted action={action}, waittime={wait_description}, "
            f"command={command_path.name}"
        )
        response: dict[str, Any] = {
            "accepted": True,
            "action": action,
            "message": "Linux supervisor will continue this action in the container.",
        }
        if waittime is not None:
            response["waittime"] = waittime
        self.send_json(HTTPStatus.ACCEPTED, response)

    def log_message(self, _format: str, *_args: Any) -> None:
        return


def start_management_api(
    logger: Callable[[str], None],
) -> tuple[ManagementHttpServer, threading.Thread]:
    port = int(os.getenv("MANAGER_API_PORT", "18080"))
    if not 1 <= port <= 65535:
        raise ValueError(f"MANAGER_API_PORT must be between 1 and 65535: {port}")
    username = os.getenv("API_USERNAME", "admin")
    password = os.getenv("PAL_SETTING_AdminPassword", "")
    access_token = os.getenv("API_ACCESS_TOKEN", "")
    if not username or not password:
        raise ValueError("management API requires API_USERNAME and PAL_SETTING_AdminPassword")
    validate_access_token(access_token)
    resource_monitor = ResourceUsageMonitor(logger)
    server = ManagementHttpServer(
        ("0.0.0.0", port),
        username,
        password,
        access_token,
        logger,
        resource_monitor,
    )
    resource_monitor.start()
    thread = threading.Thread(target=server.serve_forever, name="management-api", daemon=True)
    thread.start()
    logger(f"management API listening on TCP {port}")
    return server, thread
