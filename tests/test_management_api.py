from __future__ import annotations

import base64
import json
import os
import socket
import sqlite3
import sys
import threading
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import management_api  # noqa: E402
import world_backup  # noqa: E402


ACCESS_TOKEN = "test_access_token_0123456789abcdef"


def authenticated_headers(**extra: str) -> dict[str, str]:
    basic = base64.b64encode(b"admin:secret-password").decode("ascii")
    return {
        "Authorization": f"Basic {basic}",
        management_api.ACCESS_TOKEN_HEADER: ACCESS_TOKEN,
        **extra,
    }


def raw_authenticated_request(
    method: str,
    path: str,
    *,
    content_length: int | None = None,
) -> bytes:
    headers = {
        "Host": "127.0.0.1",
        **authenticated_headers(),
    }
    if content_length is not None:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(content_length)
    lines = [f"{method} {path} HTTP/1.1"]
    lines.extend(f"{name}: {value}" for name, value in headers.items())
    return ("\r\n".join(lines) + "\r\n\r\n").encode("ascii")


def receive_until_close(connection: socket.socket, timeout: float = 2.0) -> bytes:
    connection.settimeout(timeout)
    chunks: list[bytes] = []
    while True:
        try:
            chunk = connection.recv(65536)
        except (ConnectionAbortedError, ConnectionResetError):
            break
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


class ManagementApiTests(unittest.TestCase):
    def test_http_gateway_bounds_threads_backlog_and_slow_clients(self) -> None:
        self.assertEqual(management_api.MAX_HTTP_WORKERS, 16)
        self.assertEqual(management_api.HTTP_SOCKET_TIMEOUT_SECONDS, 15)
        self.assertEqual(management_api.HTTP_HEADER_DEADLINE_SECONDS, 15)
        self.assertEqual(management_api.HTTP_BODY_DEADLINE_SECONDS, 15)
        self.assertEqual(management_api.ManagementHttpServer.request_queue_size, 32)
        source = (SCRIPTS / "management_api.py").read_text(encoding="utf-8")
        self.assertIn("threading.BoundedSemaphore(MAX_HTTP_WORKERS)", source)
        self.assertIn("request.settimeout(HTTP_SOCKET_TIMEOUT_SECONDS)", source)
        self.assertIn("503 Service Unavailable", source)

    def test_absolute_header_deadline_closes_a_trickling_client(self) -> None:
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            mock.Mock(),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        connection: socket.socket | None = None
        try:
            with mock.patch.object(
                management_api, "HTTP_HEADER_DEADLINE_SECONDS", 0.12
            ):
                connection = socket.create_connection(server.server_address, timeout=2)
                for value in b"GET /v1/man":
                    try:
                        connection.sendall(bytes((value,)))
                    except OSError:
                        break
                    time.sleep(0.025)
                receive_until_close(connection)
        finally:
            if connection is not None:
                connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_absolute_body_deadline_closes_a_partial_request(self) -> None:
        logger = mock.Mock()
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            logger,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        connection = socket.create_connection(server.server_address, timeout=2)
        try:
            with (
                mock.patch.object(
                    management_api, "HTTP_BODY_DEADLINE_SECONDS", 0.12
                ),
                mock.patch.object(management_api, "queue_command") as queued,
            ):
                connection.sendall(
                    raw_authenticated_request(
                        "POST", "/v1/manager/restart", content_length=100
                    )
                )
                connection.sendall(b"{")
                response = receive_until_close(connection)
            self.assertEqual(response, b"")
            queued.assert_not_called()
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_gateway_processes_only_one_request_per_connection(self) -> None:
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            mock.Mock(),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        connection = socket.create_connection(server.server_address, timeout=2)
        try:
            request = raw_authenticated_request("GET", "/v1/manager/status")
            connection.sendall(request + request)
            response = receive_until_close(connection)
            self.assertEqual(response.count(b"HTTP/1.1 "), 1)
            self.assertIn(b"Connection: close", response)
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_body_deadline_is_cancelled_before_long_restore_streaming(self) -> None:
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            mock.Mock(),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        completion_thread: threading.Thread | None = None
        try:
            with tempfile.TemporaryDirectory() as directory:
                jobs = Path(directory)

                def progress_file(job_id: str) -> Path:
                    return jobs / f"{job_id}.jsonl"

                def result_file(job_id: str) -> Path:
                    return jobs / f"{job_id}.result.json"

                def queue_restore(
                    _action: str,
                    _waittime: int | None,
                    *,
                    source: str,
                    parameters: dict[str, object],
                ) -> Path:
                    self.assertEqual(source, "management-api")
                    job_id = str(parameters["job_id"])

                    def complete_later() -> None:
                        time.sleep(0.25)
                        result_file(job_id).write_text(
                            json.dumps(
                                {
                                    "type": "result",
                                    "success": True,
                                    "message": "world restored",
                                }
                            ),
                            encoding="utf-8",
                        )

                    nonlocal completion_thread
                    completion_thread = threading.Thread(target=complete_later)
                    completion_thread.start()
                    return Path("restore-command.json")

                request = urllib.request.Request(
                    f"http://127.0.0.1:{server.server_address[1]}/v1/manager/restore",
                    data=b'{"backup":"2026.07.17-02.45.46","waittime":0}',
                    method="POST",
                    headers={
                        **authenticated_headers(),
                        "Content-Type": "application/json",
                    },
                )
                with (
                    mock.patch.object(
                        management_api, "HTTP_BODY_DEADLINE_SECONDS", 0.05
                    ),
                    mock.patch.object(
                        management_api,
                        "restore_progress_file",
                        side_effect=progress_file,
                    ),
                    mock.patch.object(
                        management_api,
                        "restore_result_file",
                        side_effect=result_file,
                    ),
                    mock.patch.object(
                        management_api, "queue_command", side_effect=queue_restore
                    ),
                    urllib.request.urlopen(request, timeout=2) as response,
                ):
                    events = [
                        json.loads(line)
                        for line in response.read().decode("utf-8").splitlines()
                    ]
                self.assertEqual(response.status, 200)
                self.assertTrue(events[-1]["success"])
        finally:
            if completion_thread is not None:
                completion_thread.join(timeout=2)
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_status_endpoint_exposes_a_blocking_policy_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            status_path = Path(directory) / "status.json"
            status_path.write_text(
                json.dumps(
                    {
                        "manager": "running",
                        "game": "stopped",
                        "policy": "invalid",
                        "policy_valid": False,
                        "policy_error": "operating policy JSON is invalid",
                        "desired_running": False,
                    }
                ),
                encoding="utf-8",
            )
            server = management_api.ManagementHttpServer(
                ("127.0.0.1", 0),
                "admin",
                "secret-password",
                ACCESS_TOKEN,
                mock.Mock(),
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_address[1]}/v1/manager/status",
                headers=authenticated_headers(),
            )
            try:
                with mock.patch.object(
                    management_api, "STATUS_FILE", status_path
                ), urllib.request.urlopen(request, timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                self.assertEqual(response.status, 200)
                self.assertFalse(payload["policy_valid"])
                self.assertIn("JSON is invalid", payload["policy_error"])
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_authenticated_resource_current_and_history_endpoints(self) -> None:
        monitor = mock.Mock()
        monitor.current.return_value = {
            "sampled_at": 1000.0,
            "host": {"cpu_percent": 12.5},
            "container": {"instance": "server2", "cpu_percent": 5.0},
        }
        monitor.history.return_value = {
            "window_seconds": 3600,
            "retention_seconds": 604800,
            "bucket_seconds": 15,
            "points": [],
        }
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            mock.Mock(),
            monitor,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = f"http://127.0.0.1:{server.server_address[1]}/v1/manager/resources"
        try:
            with urllib.request.urlopen(
                urllib.request.Request(f"{root}/current", headers=authenticated_headers()),
                timeout=2,
            ) as response:
                current = json.loads(response.read().decode("utf-8"))
            with urllib.request.urlopen(
                urllib.request.Request(
                    f"{root}/history?seconds=3600&points=300",
                    headers=authenticated_headers(),
                ),
                timeout=2,
            ) as response:
                history = json.loads(response.read().decode("utf-8"))
            self.assertEqual(current["container"]["instance"], "server2")
            self.assertEqual(history["window_seconds"], 3600)
            monitor.history.assert_called_once_with(3600, 300)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            monitor.stop.assert_called_once_with()

    def test_resource_history_database_failure_returns_bounded_server_error(self) -> None:
        monitor = mock.Mock()
        monitor.history.side_effect = sqlite3.DatabaseError("database path is corrupt")
        logger = mock.Mock()
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            logger,
            monitor,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = (
            f"http://127.0.0.1:{server.server_address[1]}"
            "/v1/manager/resources/history?seconds=3600&points=300"
        )
        try:
            with self.assertRaises(urllib.error.HTTPError) as raised:
                urllib.request.urlopen(
                    urllib.request.Request(url, headers=authenticated_headers()),
                    timeout=2,
                )
            self.assertEqual(raised.exception.code, 500)
            payload = json.loads(raised.exception.read().decode("utf-8"))
            self.assertEqual(payload, {"error": "resource usage history unavailable"})
            logger.assert_any_call(
                "resource usage history failed: database path is corrupt"
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            monitor.stop.assert_called_once_with()

    def test_runtime_log_tail_reads_recent_filtered_lines_across_rotation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            path.with_name("runtime.log.1").write_text(
                "[old] [manager] older manager\n[old] [game] older game\n",
                encoding="utf-8",
            )
            path.write_text(
                "[now] [manager] current manager\n[now] [game] current game\n",
                encoding="utf-8",
            )
            with mock.patch.object(management_api, "runtime_log_path", return_value=path):
                payload = management_api.read_runtime_logs(2, "game")
            self.assertEqual(
                payload["lines"],
                ["[old] [game] older game", "[now] [game] current game"],
            )
            self.assertEqual(payload["returned_lines"], 2)

    def test_authenticated_runtime_log_endpoint_is_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            path.write_text("[now] [api] request complete\n", encoding="utf-8")
            server = management_api.ManagementHttpServer(
                ("127.0.0.1", 0),
                "admin",
                "secret-password",
                ACCESS_TOKEN,
                mock.Mock(),
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_address[1]}/v1/manager/logs?lines=100&source=api",
                headers=authenticated_headers(),
            )
            try:
                with (
                    mock.patch.object(management_api, "runtime_log_path", return_value=path),
                    urllib.request.urlopen(request, timeout=2) as response,
                ):
                    payload = json.loads(response.read().decode("utf-8"))
                self.assertEqual(response.status, 200)
                self.assertEqual(payload["lines"], ["[now] [api] request complete"])
                self.assertEqual(payload["source"], "api")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_backup_endpoint_lists_a_fresh_world_without_players(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory) / "SaveGames/0"
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            backup = world / "backup/world/2026.07.17-02.45.46"
            for path, marker in ((world, "current"), (backup, "backup")):
                path.mkdir(parents=True)
                (path / "LevelMeta.sav").write_text(f"meta-{marker}", encoding="utf-8")
                (path / "Level.sav").write_text(f"level-{marker}", encoding="utf-8")

            logger = mock.Mock()
            server = management_api.ManagementHttpServer(
                ("127.0.0.1", 0),
                "admin",
                "secret-password",
                ACCESS_TOKEN,
                logger,
            )
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            request = urllib.request.Request(
                f"http://127.0.0.1:{server.server_address[1]}/v1/manager/backups",
                headers=authenticated_headers(),
            )
            try:
                with (
                    mock.patch.object(world_backup, "SAVEGAMES_ROOT", savegames),
                    mock.patch.object(
                        management_api,
                        "STATUS_FILE",
                        Path(directory) / "missing-status.json",
                    ),
                    urllib.request.urlopen(request, timeout=2) as response,
                ):
                    payload = json.loads(response.read().decode("utf-8"))
                self.assertEqual(response.status, 200)
                self.assertEqual(payload["world_guid"], world.name)
                self.assertEqual(payload["backups"][0]["file_count"], 2)
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_action_paths_and_waittime_validation(self) -> None:
        self.assertEqual(management_api.action_from_path("/v1/manager/start"), "start")
        self.assertEqual(management_api.action_from_path("/v1/manager/restart"), "restart")
        self.assertEqual(management_api.action_from_path("/v1/manager/shutdown"), "shutdown")
        self.assertIsNone(management_api.action_from_path("/v1/manager/stop"))
        self.assertIsNone(management_api.action_from_path("/v1/api/stop"))
        self.assertTrue(management_api.is_palworld_api_path("/v1/api/info"))
        self.assertFalse(management_api.is_palworld_api_path("/v1/manager/status"))
        self.assertEqual(management_api.parse_waittime({"waittime": 60}), 60)
        with self.assertRaises(ValueError):
            management_api.parse_waittime({"waittime": 3601})

    def test_authenticated_post_queues_linux_command(self) -> None:
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            mock.Mock(),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        request = urllib.request.Request(
            f"http://127.0.0.1:{port}/v1/manager/restart",
            data=b'{"waittime":60}',
            method="POST",
            headers=authenticated_headers(**{"Content-Type": "application/json"}),
        )
        try:
            with mock.patch.object(
                management_api, "queue_command", return_value=Path("command.json")
            ) as queued:
                with urllib.request.urlopen(request, timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 202)
            self.assertEqual(payload["action"], "restart")
            queued.assert_called_once_with("restart", 60, source="management-api")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_start_queues_without_an_unused_waittime(self) -> None:
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            mock.Mock(),
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        request = urllib.request.Request(
            f"http://127.0.0.1:{server.server_address[1]}/v1/manager/start",
            data=b"",
            method="POST",
            headers=authenticated_headers(),
        )
        try:
            with mock.patch.object(
                management_api, "queue_command", return_value=Path("command.json")
            ) as queued:
                with urllib.request.urlopen(request, timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 202)
            self.assertEqual(payload["action"], "start")
            self.assertNotIn("waittime", payload)
            queued.assert_called_once_with("start", None, source="management-api")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_backup_list_and_synchronous_restore_stream(self) -> None:
        gateway_logger = mock.Mock()
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            gateway_logger,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        headers = authenticated_headers()
        backup_payload = {
            "world_guid": "96FBD59D86CB4A0FBCBFC516DD1323F0",
            "backup_root": "/world/backup/world",
            "backups": [
                {
                    "name": "2026.07.17-02.45.46",
                    "kind": "world-backup",
                    "created_at": "2026-07-17T02:45:46",
                    "file_count": 3,
                    "size_bytes": 100,
                }
            ],
        }
        try:
            with mock.patch.object(management_api, "list_world_backups", return_value=backup_payload):
                request = urllib.request.Request(
                    f"http://127.0.0.1:{server.server_address[1]}/v1/manager/backups",
                    headers=headers,
                )
                with urllib.request.urlopen(request, timeout=2) as response:
                    listed = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 200)
            self.assertEqual(listed["backups"][0]["name"], "2026.07.17-02.45.46")
            gateway_logger.assert_any_call(
                "management backup list completed: "
                "world=96FBD59D86CB4A0FBCBFC516DD1323F0, count=1"
            )

            with tempfile.TemporaryDirectory() as directory:
                jobs = Path(directory)

                def progress_file(job_id: str) -> Path:
                    return jobs / f"{job_id}.jsonl"

                def result_file(job_id: str) -> Path:
                    return jobs / f"{job_id}.result.json"

                def queue_restore(
                    action: str,
                    waittime: int | None,
                    *,
                    source: str,
                    parameters: dict[str, object],
                ) -> Path:
                    self.assertEqual(action, "restore")
                    self.assertEqual(waittime, 0)
                    self.assertEqual(source, "management-api")
                    job_id = str(parameters["job_id"])
                    progress_file(job_id).write_text(
                        json.dumps(
                            {
                                "type": "log",
                                "timestamp": "2026-07-17T02:45:46+09:00",
                                "message": "world payload replacement completed",
                            }
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                    result_file(job_id).write_text(
                        json.dumps(
                            {
                                "type": "result",
                                "success": True,
                                "message": "world restored",
                            }
                        ),
                        encoding="utf-8",
                    )
                    return Path("restore-command.json")

                restore_request = urllib.request.Request(
                    f"http://127.0.0.1:{server.server_address[1]}/v1/manager/restore",
                    data=b'{"backup":"2026.07.17-02.45.46","waittime":0}',
                    method="POST",
                    headers={**headers, "Content-Type": "application/json"},
                )
                with (
                    mock.patch.object(management_api, "restore_progress_file", side_effect=progress_file),
                    mock.patch.object(management_api, "restore_result_file", side_effect=result_file),
                    mock.patch.object(management_api, "queue_command", side_effect=queue_restore),
                    urllib.request.urlopen(restore_request, timeout=2) as restore_response,
                ):
                    events = [
                        json.loads(line)
                        for line in restore_response.read().decode("utf-8").splitlines()
                    ]
                self.assertEqual(restore_response.status, 200)
                self.assertTrue(events[-1]["success"])
                self.assertTrue(
                    any(event.get("message") == "world payload replacement completed" for event in events)
                )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_authentication_is_required(self) -> None:
        username = base64.b64encode(b"admin:wrong").decode("ascii")
        self.assertFalse(
            management_api.credentials_match(f"Basic {username}", "admin", "correct")
        )

    def test_gateway_requires_basic_password_and_access_token_and_verifies_challenge(self) -> None:
        logger = mock.Mock()
        server = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            logger,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        challenge = "a" * 64
        url = (
            f"http://127.0.0.1:{server.server_address[1]}"
            f"{management_api.VERIFY_PATH}?challenge={challenge}"
        )
        basic = base64.b64encode(b"admin:secret-password").decode("ascii")
        try:
            for headers, expected_status in (
                ({"Authorization": f"Basic {basic}"}, 403),
                ({management_api.ACCESS_TOKEN_HEADER: ACCESS_TOKEN}, 401),
                (
                    {
                        "Authorization": f"Basic {basic}",
                        management_api.ACCESS_TOKEN_HEADER: "wrong_access_token_0123456789abcdef",
                    },
                    403,
                ),
            ):
                with self.assertRaises(urllib.error.HTTPError) as rejected:
                    urllib.request.urlopen(
                        urllib.request.Request(url, headers=headers), timeout=2
                    )
                self.assertEqual(rejected.exception.code, expected_status)

            with urllib.request.urlopen(
                urllib.request.Request(url, headers=authenticated_headers()), timeout=2
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
            self.assertEqual(response.status, 200)
            self.assertEqual(payload["product"], management_api.PRODUCT_ID)
            self.assertEqual(payload["protocol"], management_api.PROTOCOL_VERSION)
            self.assertTrue(payload["token_verified"])
            self.assertEqual(payload["challenge"], challenge)
            self.assertEqual(
                payload["proof"],
                management_api.verification_proof(ACCESS_TOKEN, challenge),
            )
            logs = "\n".join(
                str(call.args[0]) for call in logger.call_args_list if call.args
            )
            self.assertNotIn(ACCESS_TOKEN, logs)
            self.assertNotIn("secret-password", logs)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_official_api_is_proxied_through_the_same_gateway(self) -> None:
        class FakePalworldHandler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                payload = json.dumps(
                    {
                        "path": self.path,
                        "authorization": self.headers.get("Authorization"),
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                body = self.rfile.read(length).decode("utf-8") if length else ""
                payload = json.dumps({"path": self.path, "body": body}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        palworld = ThreadingHTTPServer(("127.0.0.1", 0), FakePalworldHandler)
        palworld_thread = threading.Thread(target=palworld.serve_forever, daemon=True)
        palworld_thread.start()
        gateway_logger = mock.Mock()
        gateway = management_api.ManagementHttpServer(
            ("127.0.0.1", 0),
            "admin",
            "secret-password",
            ACCESS_TOKEN,
            gateway_logger,
        )
        gateway_thread = threading.Thread(target=gateway.serve_forever, daemon=True)
        gateway_thread.start()
        token = base64.b64encode(b"admin:secret-password").decode("ascii")
        request = urllib.request.Request(
            f"http://127.0.0.1:{gateway.server_address[1]}/v1/api/info?source=gateway",
            headers=authenticated_headers(),
        )
        try:
            with mock.patch.dict(
                os.environ,
                {"PAL_SETTING_RESTAPIPort": str(palworld.server_address[1])},
            ):
                with urllib.request.urlopen(request, timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                post_body = {
                    "waittime": 5,
                    "message": "5초 뒤 종료됩니다.\n다시 접속하세요.",
                }
                post_request = urllib.request.Request(
                    f"http://127.0.0.1:{gateway.server_address[1]}/v1/api/shutdown",
                    data=json.dumps(post_body, ensure_ascii=False).encode("utf-8"),
                    method="POST",
                    headers={
                        **authenticated_headers(),
                        "Content-Type": "application/json",
                    },
                )
                with urllib.request.urlopen(post_request, timeout=2) as post_response:
                    post_payload = json.loads(post_response.read().decode("utf-8"))
            self.assertEqual(response.status, 200)
            self.assertEqual(payload["path"], "/v1/api/info?source=gateway")
            self.assertEqual(payload["authorization"], f"Basic {token}")
            self.assertEqual(post_response.status, 200)
            self.assertEqual(post_payload["path"], "/v1/api/shutdown")
            self.assertEqual(json.loads(post_payload["body"]), post_body)
            gateway_logger.assert_any_call("official REST GET /v1/api/info status=200")
            gateway_logger.assert_any_call(
                'official REST POST /v1/api/shutdown status=200 waittime=5 '
                'message="5초 뒤 종료됩니다.\\n다시 접속하세요."'
            )
        finally:
            gateway.shutdown()
            gateway.server_close()
            gateway_thread.join(timeout=2)
            palworld.shutdown()
            palworld.server_close()
            palworld_thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
