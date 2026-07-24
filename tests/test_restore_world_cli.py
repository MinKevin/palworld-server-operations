from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import restore_world  # noqa: E402


class RestoreWorldCliTests(unittest.TestCase):
    def test_parser_supports_non_interactive_list_and_restore(self) -> None:
        listed = restore_world.build_parser().parse_args(
            ["--server", "server1", "--list-json"]
        )
        self.assertTrue(listed.list_json)
        restored = restore_world.build_parser().parse_args(
            [
                "--server",
                "server1",
                "--backup",
                "2026.07.17-02.45.46",
                "--yes",
            ]
        )
        self.assertEqual(restored.backup, "2026.07.17-02.45.46")
        self.assertTrue(restored.yes)

    def test_parser_rejects_abbreviated_target_options(self) -> None:
        with self.assertRaises(SystemExit):
            restore_world.build_parser().parse_args(
                ["--serv", "server1", "--list-json"]
            )

    def test_connection_settings_are_loaded_without_password_in_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            (project / "config").mkdir()
            (project / "config/common.env").write_text(
                "API_USERNAME=admin\n", encoding="utf-8"
            )
            (project / "config/server2.env").write_text(
                "PAL_SETTING_RESTAPIPort=8222\n"
                "PAL_SETTING_AdminPassword=secret-value\n"
                "API_ACCESS_TOKEN=test_access_token_0123456789abcdef\n",
                encoding="utf-8",
            )
            self.assertEqual(
                restore_world.connection_settings(project, "server2"),
                (
                    "127.0.0.1",
                    8222,
                    "admin",
                    "secret-value",
                    "test_access_token_0123456789abcdef",
                ),
            )

    def test_choose_backup_supports_q_and_number(self) -> None:
        payload = {
            "world_guid": "A" * 32,
            "backups": [
                {
                    "name": "2026.07.17-02.45.46",
                    "kind": "world-backup",
                    "file_count": 3,
                    "size_bytes": 100,
                }
            ],
        }
        with mock.patch("builtins.input", return_value="1"), mock.patch(
            "sys.stdout", new_callable=io.StringIO
        ):
            self.assertEqual(
                restore_world.choose_backup(payload), "2026.07.17-02.45.46"
            )
        with mock.patch("builtins.input", return_value="q"), mock.patch(
            "sys.stdout", new_callable=io.StringIO
        ):
            self.assertIsNone(restore_world.choose_backup(payload))

    def test_restore_stream_prints_progress_and_result(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                if (
                    self.headers.get("X-Palworld-Manager-Token")
                    != "test_access_token_0123456789abcdef"
                ):
                    self.send_error(403)
                    return
                body = (
                    json.dumps(
                        {
                            "type": "log",
                            "timestamp": "2026-07-17T02:45:46+09:00",
                            "level": "info",
                            "message": "copying backup",
                        }
                    )
                    + "\n"
                    + json.dumps(
                        {"type": "result", "success": True, "message": "world restored"}
                    )
                    + "\n"
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ndjson")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        output = io.StringIO()
        try:
            with mock.patch("sys.stdout", output):
                success = restore_world.stream_restore(
                    f"http://127.0.0.1:{server.server_address[1]}",
                    "admin",
                    "password",
                    "test_access_token_0123456789abcdef",
                    "2026.07.17-02.45.46",
                    0,
                )
            self.assertTrue(success)
            self.assertIn("copying backup", output.getvalue())
            self.assertIn("복원 완료", output.getvalue())
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_interactive_restore_uses_short_server_confirmation(self) -> None:
        payload = {
            "world_guid": "A" * 32,
            "backups": [{"name": "2026.07.17-02.45.46"}],
        }
        arguments = [
            "restore_world.py",
            "--project",
            "/tmp/project",
            "--server",
            "server2",
        ]
        with mock.patch.object(sys, "argv", arguments), mock.patch.object(
            restore_world,
            "connection_settings",
            return_value=("127.0.0.1", 8222, "admin", "password", "T" * 32),
        ), mock.patch.object(restore_world, "list_backups", return_value=payload), mock.patch.object(
            restore_world, "choose_backup", return_value="2026.07.17-02.45.46"
        ), mock.patch("builtins.input", return_value="RESTORE server2") as entered, mock.patch.object(
            restore_world, "stream_restore", return_value=True
        ) as restored, mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(restore_world.main(), 0)
        self.assertIn("RESTORE server2", entered.call_args.args[0])
        restored.assert_called_once()

        with mock.patch.object(sys, "argv", arguments), mock.patch.object(
            restore_world,
            "connection_settings",
            return_value=("127.0.0.1", 8222, "admin", "password", "T" * 32),
        ), mock.patch.object(restore_world, "list_backups", return_value=payload), mock.patch.object(
            restore_world, "choose_backup", return_value="2026.07.17-02.45.46"
        ), mock.patch("builtins.input", return_value="RESTORE server2 2026.07.17-02.45.46"), mock.patch.object(
            restore_world, "stream_restore", return_value=True
        ) as old_phrase_restore, mock.patch("sys.stdout", new_callable=io.StringIO):
            self.assertEqual(restore_world.main(), 0)
        old_phrase_restore.assert_not_called()


if __name__ == "__main__":
    unittest.main()
