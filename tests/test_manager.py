from __future__ import annotations

import io
import os
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import manager  # noqa: E402
import palctl  # noqa: E402


class RuntimeLogTests(unittest.TestCase):
    def tearDown(self) -> None:
        manager.close_runtime_log()

    def test_runtime_log_records_timestamp_and_source(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            with mock.patch.dict(
                os.environ,
                {
                    "RUNTIME_LOG_FILE": str(path),
                    "RUNTIME_LOG_MAX_SIZE_MB": "1",
                    "RUNTIME_LOG_BACKUP_COUNT": "2",
                },
            ):
                line = manager.log("server output", source="game")
            self.assertIn("[game] server output", line)
            self.assertIn("+", line.split("]", 1)[0])
            self.assertEqual(path.read_text(encoding="utf-8").strip(), line)

    def test_game_relay_reuses_one_buffered_runtime_log_handle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            supervisor = manager.Supervisor.__new__(manager.Supervisor)
            supervisor.instance = "server1"
            supervisor.active_restore_job_id = None
            process = mock.Mock()
            process.stdout = io.StringIO("first line\nsecond line\n")
            captured_stdout = io.StringIO()

            with mock.patch.dict(
                os.environ,
                {"RUNTIME_LOG_FILE": str(path)},
            ), mock.patch.object(
                manager,
                "_open_runtime_log_file",
                wraps=manager._open_runtime_log_file,
            ) as opened, mock.patch.object(sys, "stdout", captured_stdout):
                supervisor.relay_game_output(process)

            self.assertEqual(opened.call_count, 1)
            self.assertIn("[game] first line", captured_stdout.getvalue())
            self.assertIn("[game] second line", captured_stdout.getvalue())
            stored = path.read_text(encoding="utf-8")
            self.assertIn("[game] first line", stored)
            self.assertIn("[game] second line", stored)
            self.assertTrue(process.stdout.closed)

    def test_bounded_game_line_truncates_and_drains_one_logical_line(self) -> None:
        stream = io.StringIO("abcdefghijk\nnext\n")
        with mock.patch.object(manager, "_GAME_LOG_LINE_MAX_CHARS", 8):
            first = manager._read_bounded_game_line(stream)
            second = manager._read_bounded_game_line(stream)

        self.assertEqual(first, "abcdefgh ... [truncated 3 additional characters]")
        self.assertEqual(second, "next")
        self.assertIsNone(manager._read_bounded_game_line(stream))

    def test_runtime_log_batch_reuses_handle_and_preserves_rotation_bounds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            lines = [f"{index:02d}-" + ("x" * 50) for index in range(10)]
            with mock.patch.dict(
                os.environ,
                {"RUNTIME_LOG_FILE": str(path)},
            ), mock.patch.object(
                manager, "_runtime_log_limits", return_value=(120, 2)
            ), mock.patch.object(
                manager,
                "_open_runtime_log_file",
                wraps=manager._open_runtime_log_file,
            ) as opened, manager._runtime_log_session():
                manager._write_runtime_log_lines(lines)

            self.assertEqual(opened.call_count, 5)
            retained = [path, path.with_name("runtime.log.1"), path.with_name("runtime.log.2")]
            self.assertTrue(all(candidate.exists() for candidate in retained))
            self.assertTrue(all(candidate.stat().st_size <= 120 for candidate in retained))
            self.assertFalse(path.with_name("runtime.log.3").exists())
            self.assertIn("08-", path.read_text(encoding="utf-8"))
            self.assertIn("09-", path.read_text(encoding="utf-8"))

    def test_runtime_log_batch_flushes_once_after_all_buffered_writes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            handle = mock.Mock()
            with mock.patch.dict(
                os.environ,
                {"RUNTIME_LOG_FILE": str(path)},
            ), mock.patch.object(
                manager, "_runtime_log_limits", return_value=(1024 * 1024, 2)
            ), mock.patch.object(
                manager, "_open_runtime_log_file", return_value=handle
            ), manager._runtime_log_session():
                manager._write_runtime_log_lines(["one", "two", "three"])

            self.assertEqual(handle.write.call_count, 3)
            handle.flush.assert_called_once_with()
            handle.close.assert_called_once_with()

    def test_runtime_log_session_serializes_concurrent_batches(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.log"
            expected = {f"worker-{worker}-{index}" for worker in range(4) for index in range(25)}

            def write(worker: int) -> None:
                manager._write_runtime_log_lines(
                    [f"worker-{worker}-{index}" for index in range(25)]
                )

            with mock.patch.dict(
                os.environ,
                {"RUNTIME_LOG_FILE": str(path)},
            ), mock.patch.object(
                manager, "_runtime_log_limits", return_value=(1024 * 1024, 2)
            ), manager._runtime_log_session():
                threads = [threading.Thread(target=write, args=(worker,)) for worker in range(4)]
                for thread in threads:
                    thread.start()
                for thread in threads:
                    thread.join(timeout=2)
                self.assertTrue(all(not thread.is_alive() for thread in threads))

            self.assertEqual(set(path.read_text(encoding="utf-8").splitlines()), expected)

    def test_full_game_log_queue_aggregates_drops_by_restore_job(self) -> None:
        with mock.patch.object(manager, "_GAME_LOG_QUEUE_SIZE", 1):
            relay = manager._GameLogRelay("server1")
        relay.submit("kept", "job-a")
        relay.submit("dropped-a", "job-a")
        relay.submit("dropped-b", "job-b")

        total, by_job = relay._take_dropped()

        self.assertEqual(total, 2)
        self.assertEqual(by_job, {"job-a": 1, "job-b": 1})

    def test_slow_game_log_sink_does_not_block_the_stdout_reader_path(self) -> None:
        entered_sink = threading.Event()
        release_sink = threading.Event()
        with mock.patch.object(manager, "_GAME_LOG_QUEUE_SIZE", 2):
            relay = manager._GameLogRelay("server1")
        original_emit = relay._emit_records

        def slow_emit(records: list[manager._GameLogRecord]) -> None:
            entered_sink.set()
            release_sink.wait(timeout=2)
            original_emit(records)

        def produce_burst() -> None:
            for index in range(1000):
                relay.submit(f"burst-{index}", None)

        with mock.patch.object(manager, "_write_stdout_lines"), mock.patch.object(
            manager, "_write_runtime_log_lines"
        ), mock.patch.object(manager, "append_restore_event"), mock.patch.object(
            relay, "_emit_records", side_effect=slow_emit
        ):
            relay.start()
            relay.submit("first", None)
            self.assertTrue(entered_sink.wait(timeout=0.5))

            producer = threading.Thread(target=produce_burst)
            producer.start()
            producer.join(timeout=0.5)

            self.assertFalse(producer.is_alive())
            with relay._dropped_lock:
                self.assertGreater(relay._dropped_total, 0)
            release_sink.set()
            self.assertTrue(relay.finish())

    def test_restore_job_is_captured_before_async_game_log_sink(self) -> None:
        relay = manager._GameLogRelay("server1")
        with mock.patch.object(manager, "_write_stdout_lines"), mock.patch.object(
            manager, "_write_runtime_log_lines"
        ), mock.patch.object(manager, "append_restore_event") as append:
            relay.start()
            relay.submit("restore output", "job-a")
            self.assertTrue(relay.finish())

        append.assert_called_once()
        self.assertEqual(append.call_args.args[0], "job-a")
        self.assertEqual(append.call_args.args[1]["message"], "restore output")


class PolicyFileTests(unittest.TestCase):
    def test_policy_reader_accepts_a_valid_timed_manual_policy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.json"
            until = datetime(2026, 1, 2, 14, 0, tzinfo=timezone.utc)
            path.write_text(
                manager.json.dumps(
                    {
                        "override": "stopped",
                        "until_epoch": until.timestamp(),
                        "until_at": until.isoformat(timespec="seconds"),
                    }
                ),
                encoding="utf-8",
            )

            record = manager.read_policy_file(path)

        self.assertEqual(record["override"], "stopped")
        self.assertEqual(record["until_epoch"], until.timestamp())

    def test_policy_reader_rejects_corrupt_ambiguous_and_mismatched_json(self) -> None:
        invalid_records = (
            "{",
            "[]",
            '{"override":"stopped","override":"auto"}',
            '{"override":"unexpected"}',
            '{"override":"auto","until_epoch":1,"until_at":"1970-01-01T00:00:01+00:00"}',
            '{"override":"stopped","until_at":"2026-01-01T00:00:00+00:00"}',
            '{"override":"stopped","until_epoch":1,"until_at":"2026-01-01T00:00:00"}',
            '{"override":"stopped","until_epoch":1,"until_at":"2026-01-01T00:00:00+00:00"}',
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.json"
            for content in invalid_records:
                with self.subTest(content=content):
                    path.write_text(content, encoding="utf-8")
                    with self.assertRaises(manager.PolicyFileError):
                        manager.read_policy_file(path)

    def test_policy_reader_reports_unreadable_existing_file(self) -> None:
        path = Path("policy.json")
        with mock.patch.object(Path, "open", side_effect=PermissionError("access denied")):
            with self.assertRaisesRegex(manager.PolicyFileError, "unreadable"):
                manager.read_policy_file(path)

    def test_policy_reader_enforces_the_limit_in_utf8_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.json"
            path.write_bytes(("가" * 22000).encode("utf-8"))
            self.assertGreater(path.stat().st_size, 64 * 1024)
            with self.assertRaisesRegex(manager.PolicyFileError, "64 KiB"):
                manager.read_policy_file(path)

    def test_corrupt_policy_fails_closed_and_is_exposed_in_status(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy/policy.json"
            with (
                mock.patch.object(manager, "MANAGER_DIR", root / "manager"),
                mock.patch.object(manager, "COMMANDS_DIR", root / "manager/commands"),
                mock.patch.object(manager, "POLICY_FILE", policy),
            ):
                supervisor = manager.Supervisor()
                policy.write_text("{not-json", encoding="utf-8")
                supervisor.test_session_deadline_monotonic = manager.time.monotonic() + 60

                status = supervisor.status()

            self.assertFalse(status["desired_running"])
            self.assertEqual(status["policy"], "invalid")
            self.assertFalse(status["policy_valid"])
            self.assertIn("JSON is invalid", status["policy_error"])
            self.assertIn("policy unavailable", status["desired_reason"])
            self.assertTrue(status["test_session_active"])

    def test_shutdown_wait_accepts_the_common_duration_syntax(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (
                mock.patch.dict(manager.os.environ, {"SHUTDOWN_WAIT": "90s"}, clear=False),
                mock.patch.object(manager, "MANAGER_DIR", root / "manager"),
                mock.patch.object(manager, "COMMANDS_DIR", root / "manager/commands"),
                mock.patch.object(manager, "POLICY_FILE", root / "policy/policy.json"),
            ):
                supervisor = manager.Supervisor()
        self.assertEqual(supervisor.shutdown_wait, 90)

    def test_explicit_policy_write_recovers_a_corrupt_file_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy/policy.json"
            with (
                mock.patch.object(manager, "MANAGER_DIR", root / "manager"),
                mock.patch.object(manager, "COMMANDS_DIR", root / "manager/commands"),
                mock.patch.object(manager, "POLICY_FILE", policy),
            ):
                supervisor = manager.Supervisor()
                policy.write_text("null", encoding="utf-8")
                self.assertFalse(supervisor.status()["policy_valid"])

                supervisor.set_policy("stopped")
                recovered = supervisor.status()

            self.assertTrue(recovered["policy_valid"])
            self.assertIsNone(recovered["policy_error"])
            self.assertEqual(recovered["policy"], "stopped")
            self.assertFalse(recovered["desired_running"])
            self.assertEqual(manager.read_policy_file(policy)["override"], "stopped")

    def test_palctl_health_rejects_a_policy_error(self) -> None:
        status = {
            "manager": "running",
            "game": "stopped",
            "updated_epoch": 1000,
            "policy_error": "invalid policy",
        }
        self.assertFalse(palctl.healthy_supervisor_status(status, now=1001))
        status["policy_error"] = None
        self.assertTrue(palctl.healthy_supervisor_status(status, now=1001))

    def test_invalid_policy_preserves_a_running_game_and_blocks_disruptive_actions(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.policy_error = "operating policy JSON is invalid"
        supervisor.phase = "running"
        supervisor.reason = "running"
        supervisor.test_session_deadline_monotonic = None
        supervisor.test_session_until_epoch = None
        supervisor.stop_server = mock.Mock()
        supervisor.start_server = mock.Mock()
        supervisor.policy_record = mock.Mock(
            return_value={"override": "invalid", "error": supervisor.policy_error}
        )

        desired, reason = supervisor.desired_state(datetime.now(timezone.utc))
        supervisor.reconcile_game_state(False, reason, game_running=True)

        self.assertTrue(desired)
        self.assertIn("existing game remains running", reason)
        self.assertEqual(supervisor.phase, "running")
        supervisor.stop_server.assert_not_called()
        supervisor.start_server.assert_not_called()

        self.assertFalse(supervisor.restart_server("scheduled restart"))
        supervisor.stop_server.assert_not_called()

    def test_invalid_policy_cancels_pending_and_new_updates_before_lock_or_shutdown(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.policy_error = "operating policy JSON is invalid"
        supervisor.phase = "running"
        supervisor.reason = "running"
        supervisor.policy_record = mock.Mock(
            return_value={"override": "invalid", "error": supervisor.policy_error}
        )
        supervisor.update_waiting_for_lock = "manual update requested"
        supervisor.update_waiting_for_lock_waittime = 0
        supervisor.last_update_error = None
        supervisor.perform_update = mock.Mock(wraps=supervisor.perform_update)

        with mock.patch.object(manager, "shared_update_lock") as update_lock:
            supervisor.perform_update("manual update requested", waittime=0)

        update_lock.assert_not_called()
        self.assertIsNone(supervisor.update_waiting_for_lock)
        self.assertIn("policy", supervisor.last_update_error)

        supervisor.update_waiting_for_lock = "automatic update detected"
        supervisor.perform_update.reset_mock()
        supervisor.check_automatic_update()
        supervisor.perform_update.assert_not_called()
        self.assertIsNone(supervisor.update_waiting_for_lock)

    def test_invalid_policy_returns_an_immediate_failed_restore_result(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.policy_error = "operating policy JSON is invalid"
        supervisor.phase = "running"
        supervisor.reason = "running"
        supervisor.policy_record = mock.Mock(
            return_value={"override": "invalid", "error": supervisor.policy_error}
        )
        supervisor.write_status = mock.Mock()
        result_path = Path("blocked-restore.result.json")

        with mock.patch.object(manager, "append_restore_event") as append, mock.patch.object(
            manager, "restore_result_file", return_value=result_path
        ), mock.patch.object(manager, "atomic_write_json") as write_result:
            supervisor.perform_restore(
                "00000000-0000-0000-0000-000000000001",
                "backup-name",
                0,
            )

        append.assert_called_once()
        write_result.assert_called_once()
        payload = write_result.call_args.args[1]
        self.assertFalse(payload["success"])
        self.assertIn("world restore blocked", payload["message"])
        supervisor.write_status.assert_called_once()

    def test_expired_policy_write_failure_is_latched_without_stopping_the_game(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "policy.json"
            expired = datetime(2026, 1, 1, tzinfo=timezone.utc)
            path.write_text(
                manager.json.dumps(
                    {
                        "override": "stopped",
                        "until_epoch": expired.timestamp(),
                        "until_at": expired.isoformat(timespec="seconds"),
                    }
                ),
                encoding="utf-8",
            )
            supervisor = manager.Supervisor.__new__(manager.Supervisor)
            supervisor.proc = mock.Mock()
            supervisor.proc.poll.return_value = None
            supervisor.policy_error = None
            supervisor.policy_write_error = None
            supervisor.reason = "running"
            supervisor.test_session_deadline_monotonic = None
            supervisor.test_session_until_epoch = None
            with mock.patch.object(manager, "POLICY_FILE", path), mock.patch.object(
                manager,
                "atomic_write_json",
                side_effect=OSError(28, "No space left on device"),
            ):
                record = supervisor.policy_record(
                    datetime(2026, 1, 2, tzinfo=timezone.utc)
                )
                desired, reason = supervisor.desired_state(
                    datetime(2026, 1, 2, tzinfo=timezone.utc), record
                )

            self.assertEqual(record["override"], "invalid")
            self.assertTrue(desired)
            self.assertIn("existing game remains running", reason)
            self.assertIn("write failed", supervisor.policy_error)
            self.assertEqual(supervisor.policy_write_error, supervisor.policy_error)

    def test_failed_policy_write_rejects_force_stop_until_an_explicit_retry_succeeds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            policy = root / "policy.json"
            policy.write_text('{"override":"auto"}', encoding="utf-8")
            supervisor = manager.Supervisor.__new__(manager.Supervisor)
            supervisor.restart_warning_seconds = 60
            supervisor.shutdown_warning_seconds = 60
            supervisor.policy_error = None
            supervisor.policy_write_error = None
            supervisor.reason = "running"
            supervisor.stop_server = mock.Mock()
            manager.atomic_write_json(root / "commands/force.json", {"action": "force-stop"})

            with mock.patch.object(manager, "COMMANDS_DIR", root / "commands"), mock.patch.object(
                manager, "POLICY_FILE", policy
            ), mock.patch.object(
                manager,
                "atomic_write_json",
                side_effect=OSError(30, "Read-only file system"),
            ):
                supervisor.process_commands()

            supervisor.stop_server.assert_not_called()
            self.assertIn("write failed", supervisor.policy_error)
            self.assertIsNotNone(supervisor.policy_write_error)

            with mock.patch.object(manager, "POLICY_FILE", policy):
                self.assertTrue(supervisor.set_policy("stopped"))
            self.assertIsNone(supervisor.policy_error)
            self.assertIsNone(supervisor.policy_write_error)
            self.assertEqual(manager.read_policy_file(policy)["override"], "stopped")

    def test_invalid_policy_safe_stop_does_not_persist_stopped_after_graceful_failure(self) -> None:
        for action in ("shutdown", "safe-stop"):
            with self.subTest(action=action), tempfile.TemporaryDirectory() as directory:
                supervisor = manager.Supervisor.__new__(manager.Supervisor)
                supervisor.restart_warning_seconds = 60
                supervisor.shutdown_warning_seconds = 60
                supervisor.policy_error = "operating policy JSON is invalid"
                supervisor.shutdown_server = mock.Mock(return_value=False)
                supervisor.set_policy = mock.Mock()
                command_dir = Path(directory)
                manager.atomic_write_json(command_dir / f"{action}.json", {"action": action})

                with mock.patch.object(manager, "COMMANDS_DIR", command_dir):
                    supervisor.process_commands()

                supervisor.shutdown_server.assert_called_once()
                supervisor.set_policy.assert_not_called()


class ScheduleTests(unittest.TestCase):
    def test_always_window(self) -> None:
        self.assertIsNone(manager.parse_active_window("always"))
        self.assertTrue(manager.is_in_active_window(datetime(2026, 1, 1, 3, 0), None))

    def test_same_day_window(self) -> None:
        window = manager.parse_active_window("09:00-18:00")
        self.assertTrue(manager.is_in_active_window(datetime(2026, 1, 1, 9, 0), window))
        self.assertTrue(manager.is_in_active_window(datetime(2026, 1, 1, 17, 59), window))
        self.assertFalse(manager.is_in_active_window(datetime(2026, 1, 1, 18, 0), window))

    def test_overnight_window(self) -> None:
        window = manager.parse_active_window("14:00-02:00")
        self.assertTrue(manager.is_in_active_window(datetime(2026, 1, 1, 14, 0), window))
        self.assertTrue(manager.is_in_active_window(datetime(2026, 1, 2, 1, 59), window))
        self.assertFalse(manager.is_in_active_window(datetime(2026, 1, 2, 2, 0), window))
        self.assertFalse(manager.is_in_active_window(datetime(2026, 1, 2, 13, 59), window))

    def test_shutdown_override_expires_at_the_next_window_start(self) -> None:
        window = manager.parse_active_window("14:00-02:00")
        now = datetime(2026, 1, 2, 1, 30, tzinfo=timezone.utc)
        policy, until = manager.shutdown_policy_for_request(now, window)
        self.assertEqual(policy, "stopped")
        self.assertEqual(until, datetime(2026, 1, 2, 14, 0, tzinfo=timezone.utc))

    def test_start_outside_window_runs_now_until_the_next_window_end(self) -> None:
        window = manager.parse_active_window("14:00-02:00")
        now = datetime(2026, 1, 2, 10, 0, tzinfo=timezone.utc)
        policy, until = manager.start_policy_for_request(now, window)
        self.assertEqual(policy, "started")
        self.assertEqual(until, datetime(2026, 1, 3, 2, 0, tzinfo=timezone.utc))

    def test_start_inside_window_immediately_restores_auto_policy(self) -> None:
        window = manager.parse_active_window("14:00-02:00")
        policy, until = manager.start_policy_for_request(
            datetime(2026, 1, 2, 15, 0, tzinfo=timezone.utc), window
        )
        self.assertEqual((policy, until), ("auto", None))

    def test_always_window_shutdown_waits_for_start_and_start_returns_to_auto(self) -> None:
        now = datetime(2026, 1, 2, 10, 0, tzinfo=timezone.utc)
        self.assertEqual(manager.shutdown_policy_for_request(now, None), ("stopped", None))
        self.assertEqual(manager.start_policy_for_request(now, None), ("auto", None))

    def test_restart_times_are_sorted_and_unique(self) -> None:
        self.assertEqual(manager.parse_restart_times("16:00,04:00,16:00"), (240, 960))

    def test_restart_times_can_be_disabled(self) -> None:
        self.assertEqual(manager.parse_restart_times(""), ())
        self.assertEqual(manager.parse_restart_times("off"), ())

    def test_scheduled_restart_requires_active_window_and_running_server(self) -> None:
        self.assertFalse(manager.scheduled_restart_allowed(False, True, 3600))
        self.assertFalse(manager.scheduled_restart_allowed(True, False, 3600))
        self.assertFalse(manager.scheduled_restart_allowed(True, True, 30))
        self.assertTrue(manager.scheduled_restart_allowed(True, True, 60))

    def test_clean_external_shutdown_restarts_without_crash_delay(self) -> None:
        self.assertEqual(manager.restart_delay_after_exit(0, 10), 0)
        self.assertEqual(manager.restart_delay_after_exit(1, 10), 10)

    def test_duration_units(self) -> None:
        self.assertEqual(manager.parse_duration("10s"), 10)
        self.assertEqual(manager.parse_duration("6h"), 21600)
        self.assertEqual(manager.parse_duration("1d"), 86400)
        self.assertEqual(manager.parse_duration("off"), 0)

    def test_restart_notice_formats_one_minute(self) -> None:
        self.assertEqual(manager.format_waittime(60), "1분")
        self.assertEqual(
            manager.render_timed_message("{time} 뒤 서버가 재시작됩니다.", 60),
            "1분 뒤 서버가 재시작됩니다.",
        )


class TemporaryTestSessionTests(unittest.TestCase):
    def test_status_reads_persistent_policy_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (
                mock.patch.object(manager, "MANAGER_DIR", root / "manager"),
                mock.patch.object(manager, "COMMANDS_DIR", root / "manager/commands"),
                mock.patch.object(manager, "POLICY_FILE", root / "policy/policy.json"),
            ):
                supervisor = manager.Supervisor()
                with mock.patch.object(
                    manager, "read_policy_file", wraps=manager.read_policy_file
                ) as read_policy:
                    status = supervisor.status()

                self.assertEqual(read_policy.call_count, 1)
                self.assertEqual(status["policy"], "auto")

    def test_session_overrides_schedule_without_changing_persistent_policy(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.active_window = manager.parse_active_window("14:00-02:00")
        supervisor.test_session_deadline_monotonic = None
        supervisor.test_session_until_epoch = None
        supervisor.reason = "test"
        now = datetime(2026, 1, 2, 10, 0, tzinfo=timezone.utc)

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "POLICY_FILE", Path(directory) / "policy.json"
        ):
            supervisor.set_policy("stopped")
            supervisor.begin_test_session(600)
            self.assertEqual(
                supervisor.desired_state(now),
                (True, "temporary test session"),
            )
            self.assertEqual(manager.read_json(manager.POLICY_FILE)["override"], "stopped")

            supervisor.proc = None
            supervisor.finish_test_session()
            self.assertEqual(supervisor.desired_state(now), (False, "manual override"))
            self.assertEqual(manager.read_json(manager.POLICY_FILE)["override"], "stopped")

    def test_expired_session_returns_to_schedule(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.active_window = manager.parse_active_window("14:00-02:00")
        supervisor.test_session_deadline_monotonic = 10.0
        supervisor.test_session_until_epoch = 100.0
        now = datetime(2026, 1, 2, 10, 0, tzinfo=timezone.utc)

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "POLICY_FILE", Path(directory) / "policy.json"
        ), mock.patch.object(manager.time, "monotonic", return_value=11.0):
            supervisor.set_policy("auto")
            self.assertEqual(supervisor.desired_state(now), (False, "outside active window"))
            self.assertIsNone(supervisor.test_session_deadline_monotonic)

    def test_internal_palctl_test_start_has_a_duration(self) -> None:
        args = palctl.build_parser().parse_args(["test-start", "--duration", "900"])
        self.assertEqual(args.duration, 900)


class InstallValidationTests(unittest.TestCase):
    def test_steamcmd_sets_install_directory_before_login(self) -> None:
        command = manager.build_steamcmd_command(
            "/usr/bin/steamcmd",
            validate=True,
            beta="experimental",
        )

        self.assertLess(command.index("+force_install_dir"), command.index("+login"))
        self.assertLess(command.index("+login"), command.index("+app_update"))
        self.assertEqual(command[-1], "+quit")
        self.assertIn("validate", command)

    def test_steamcmd_progress_signature_changes_only_with_measurable_progress(self) -> None:
        waiting = "Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)"
        downloading = "Update state (0x61) downloading, progress: 1.25 (100 / 8000)"

        self.assertEqual(
            manager.steamcmd_progress_signature(waiting),
            manager.steamcmd_progress_signature(waiting),
        )
        self.assertNotEqual(
            manager.steamcmd_progress_signature(waiting),
            manager.steamcmd_progress_signature(downloading),
        )
        self.assertIsNone(manager.steamcmd_progress_signature("Waiting for user info...OK"))

    def test_steamcmd_state_0x202_has_actionable_diagnostic(self) -> None:
        diagnostic = manager.steamcmd_error_diagnostic(
            "Error! App '2394010' state is 0x202 after update job."
        )

        self.assertIsNotNone(diagnostic)
        self.assertIn("Docker-volume space", diagnostic or "")
        self.assertIsNone(manager.steamcmd_error_diagnostic("Success! App installed."))

    def test_steam_distribution_access_failures_are_classified(self) -> None:
        self.assertIn(
            "Access Denied",
            manager.steamcmd_distribution_failure(
                "Error! App '2394010' state is 0x6 after update job.",
                "Failed to get manifest request code, 'Access Denied'",
            )
            or "",
        )
        self.assertIn(
            "Missing configuration",
            manager.steamcmd_distribution_failure(
                "ERROR! Failed to install app '2394010' (Missing configuration)"
            )
            or "",
        )

    def test_only_manifest_access_denied_triggers_stale_state_recovery(self) -> None:
        self.assertTrue(
            manager.steamcmd_stale_manifest_access_denied(
                "Error! App '2394010' state is 0x6 after update job.",
                "Failed to get manifest request code, 'Access Denied'",
            )
        )
        self.assertFalse(
            manager.steamcmd_stale_manifest_access_denied(
                "ERROR! Failed to install app '2394010' (Missing configuration)"
            )
        )

    def test_stale_manifest_access_denied_retries_with_current_depot_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "steamapps/appmanifest_2394010.acf"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('"buildid" "100"', encoding="utf-8")
            update_lock = root / "update-lock/steam-update.lock"
            calls = 0

            def run_steamcmd(_command: list[str], **_kwargs: object) -> int:
                nonlocal calls
                calls += 1
                if calls == 1:
                    self.assertTrue(manifest.is_file())
                    return 8
                self.assertFalse(manifest.exists())
                manifest.write_text('"buildid" "200"', encoding="utf-8")
                return 0

            with mock.patch.dict(
                os.environ,
                {"STEAMCMD_BIN": "/usr/bin/steamcmd", "SERVER_INSTANCE": "server1"},
            ), mock.patch.object(manager, "GAME_DIR", root), mock.patch.object(
                manager, "APP_MANIFEST", manifest
            ), mock.patch.object(
                manager, "UPDATE_LOCK_FILE", update_lock
            ), mock.patch.object(
                manager, "POLICY_FILE", root / "policy/policy.json"
            ), mock.patch.object(
                manager, "missing_required_game_files", return_value=()
            ), mock.patch.object(
                manager, "run_logged_command", side_effect=run_steamcmd
            ), mock.patch.object(
                manager, "file_size_or_zero", return_value=0
            ), mock.patch.object(
                manager,
                "read_log_since",
                side_effect=[
                    "Failed to get manifest request code, 'Access Denied'",
                    "",
                ],
            ), mock.patch.object(
                manager.shutil,
                "disk_usage",
                return_value=mock.Mock(
                    free=20 * 1024**3,
                    used=10 * 1024**3,
                    total=30 * 1024**3,
                ),
            ), mock.patch.object(manager.time, "sleep"):
                manager.install_or_update(force_update=True, update_lock_held=True)

            self.assertEqual(calls, 2)
            self.assertEqual(manager.installed_build_id(manifest), 200)
            self.assertFalse(manager.steam_manifest_recovery_path().exists())

    def test_failed_clean_manifest_retry_restores_previous_build_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "steamapps/appmanifest_2394010.acf"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('"buildid" "100"', encoding="utf-8")
            update_lock = root / "update-lock/steam-update.lock"

            with mock.patch.dict(
                os.environ,
                {"STEAMCMD_BIN": "/usr/bin/steamcmd", "SERVER_INSTANCE": "server1"},
            ), mock.patch.object(manager, "GAME_DIR", root), mock.patch.object(
                manager, "APP_MANIFEST", manifest
            ), mock.patch.object(
                manager, "UPDATE_LOCK_FILE", update_lock
            ), mock.patch.object(
                manager, "POLICY_FILE", root / "policy/policy.json"
            ), mock.patch.object(
                manager, "missing_required_game_files", return_value=()
            ), mock.patch.object(
                manager, "run_logged_command", side_effect=[8, 8]
            ) as run_command, mock.patch.object(
                manager, "file_size_or_zero", return_value=0
            ), mock.patch.object(
                manager,
                "read_log_since",
                side_effect=[
                    "Failed to get manifest request code, 'Access Denied'",
                    "ERROR! Failed to install app '2394010' (Missing configuration)",
                ],
            ), mock.patch.object(
                manager.shutil,
                "disk_usage",
                return_value=mock.Mock(
                    free=20 * 1024**3,
                    used=10 * 1024**3,
                    total=30 * 1024**3,
                ),
            ), mock.patch.object(manager.time, "sleep"):
                with self.assertRaises(manager.SteamUpdateDeferredError):
                    manager.install_or_update(force_update=True, update_lock_held=True)

            self.assertEqual(run_command.call_count, 2)
            self.assertEqual(manager.installed_build_id(manifest), 100)
            self.assertFalse(manager.steam_manifest_recovery_path().exists())

    def test_interrupted_manifest_reset_restores_backup_when_current_state_is_incomplete(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "steamapps/appmanifest_2394010.acf"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '"StateFlags" "1026"\n"buildid" "200"',
                encoding="utf-8",
            )
            with mock.patch.object(
                manager, "GAME_DIR", root
            ), mock.patch.object(
                manager, "APP_MANIFEST", manifest
            ), mock.patch.object(
                manager, "POLICY_FILE", root / "policy/policy.json"
            ), mock.patch.object(
                manager, "missing_required_game_files", return_value=()
            ):
                recovery = manager.steam_manifest_recovery_path()
                recovery.parent.mkdir(parents=True)
                recovery.write_text(
                    '"StateFlags" "6"\n"buildid" "100"',
                    encoding="utf-8",
                )
                manager.recover_interrupted_steam_manifest_reset()

            self.assertEqual(manager.installed_build_id(manifest), 100)
            self.assertFalse(recovery.exists())

    def test_interrupted_manifest_reset_keeps_completed_current_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "steamapps/appmanifest_2394010.acf"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(
                '"StateFlags" "4"\n"buildid" "200"',
                encoding="utf-8",
            )
            with mock.patch.object(
                manager, "GAME_DIR", root
            ), mock.patch.object(
                manager, "APP_MANIFEST", manifest
            ), mock.patch.object(
                manager, "POLICY_FILE", root / "policy/policy.json"
            ), mock.patch.object(
                manager, "missing_required_game_files", return_value=()
            ):
                recovery = manager.steam_manifest_recovery_path()
                recovery.parent.mkdir(parents=True)
                recovery.write_text(
                    '"StateFlags" "6"\n"buildid" "100"',
                    encoding="utf-8",
                )
                manager.recover_interrupted_steam_manifest_reset()

            self.assertEqual(manager.installed_build_id(manifest), 200)
            self.assertFalse(recovery.exists())

    def test_known_steam_distribution_failure_is_not_retried_three_times(self) -> None:
        def fail_with_missing_configuration(
            _command: list[str], **kwargs: object
        ) -> int:
            captured = kwargs.get("captured_output")
            assert isinstance(captured, list)
            captured.append("ERROR! Failed to install app '2394010' (Missing configuration)")
            return 8

        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {"STEAMCMD_BIN": "/usr/bin/steamcmd"},
        ), mock.patch.object(manager, "GAME_DIR", Path(directory)), mock.patch.object(
            manager, "missing_required_game_files", return_value=()
        ), mock.patch.object(
            manager, "run_logged_command", side_effect=fail_with_missing_configuration
        ) as run_command:
            with self.assertRaises(manager.SteamUpdateDeferredError):
                manager.install_or_update(force_update=True, update_lock_held=True)

        run_command.assert_called_once()

    def test_logged_command_stops_a_process_with_no_measurable_progress(self) -> None:
        result = manager.run_logged_command(
            [
                sys.executable,
                "-c",
                (
                    "import time; "
                    "print('Update state (0x3) reconfiguring, progress: 0.00 (0 / 0)', flush=True); "
                    "time.sleep(10)"
                ),
            ],
            source="test",
            progress_timeout=0.1,
        )

        self.assertEqual(result, manager.STEAMCMD_STALLED_EXIT_CODE)

    def test_stalled_steamcmd_attempt_is_retried_with_configured_timeout(self) -> None:
        class AcquiredLock:
            def __enter__(self) -> manager.UpdateLockState:
                return manager.UpdateLockState(True)

            def __exit__(self, *_args: object) -> None:
                pass

        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {
                "UPDATE_ON_START": "true",
                "STEAMCMD_BIN": "/usr/bin/steamcmd",
                "STEAMCMD_PROGRESS_TIMEOUT": "2m",
            },
        ), mock.patch.object(manager, "GAME_DIR", Path(directory)), mock.patch.object(
            manager, "missing_required_game_files", return_value=()
        ), mock.patch.object(
            manager, "shared_update_lock", return_value=AcquiredLock()
        ), mock.patch.object(
            manager,
            "run_logged_command",
            side_effect=[manager.STEAMCMD_STALLED_EXIT_CODE, 0],
        ) as run_command, mock.patch.object(manager.time, "sleep"):
            manager.install_or_update(force_update=True)

        self.assertEqual(run_command.call_count, 2)
        self.assertEqual(run_command.call_args_list[0].kwargs["progress_timeout"], 120.0)

    def test_missing_required_file_enables_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server_script = root / "PalServer.sh"
            default_config = root / "DefaultPalWorldSettings.ini"
            server_script.touch()

            missing = manager.missing_required_game_files((server_script, default_config))

            self.assertEqual(missing, (default_config,))
            self.assertTrue(manager.install_requires_validation(False, missing))

    def test_complete_installation_respects_validation_setting(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            required = (root / "PalServer.sh", root / "DefaultPalWorldSettings.ini")
            for path in required:
                path.touch()

            missing = manager.missing_required_game_files(required)

            self.assertEqual(missing, ())
            self.assertFalse(manager.install_requires_validation(False, missing))
            self.assertTrue(manager.install_requires_validation(True, missing))

    def test_installed_build_id_is_read_from_app_manifest(self) -> None:
        content = '"AppState"\n{\n    "appid" "2394010"\n    "buildid" "12345678"\n}\n'
        self.assertEqual(manager.parse_installed_build_id(content), 12345678)
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "appmanifest_2394010.acf"
            manifest.write_text(content, encoding="utf-8")
            self.assertEqual(manager.installed_build_id(manifest), 12345678)

    def test_steamcmd_app_info_reports_public_build(self) -> None:
        output = (
            'Steam Console Client\n'
            '"2394010"\n'
            '{\n'
            '  "depots"\n'
            '  {\n'
            '    "branches"\n'
            '    {\n'
            '      "public"\n'
            '      {\n'
            '        "buildid" "87654321"\n'
            '      }\n'
            '    }\n'
            '  }\n'
            '}\n'
        )
        self.assertEqual(manager.parse_available_build_id(output), 87654321)

    def test_steamcmd_app_info_rejects_missing_branch_build(self) -> None:
        with self.assertRaises(ValueError):
            manager.parse_available_build_id('"2394010"\n{\n"depots" { }\n}\n')

    def test_update_check_compares_installed_and_available_build_ids(self) -> None:
        with mock.patch.object(manager, "available_build_id", return_value=87654321):
            self.assertEqual(
                manager.check_steam_update(12345678),
                (False, 87654321),
            )
            self.assertEqual(
                manager.check_steam_update(87654321),
                (True, 87654321),
            )

    def test_available_build_query_is_shared_through_the_host_cache(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager,
            "UPDATE_LOCK_FILE",
            Path(directory) / "steam-update.lock",
        ), mock.patch.object(
            manager,
            "query_available_build_id",
            return_value=87654321,
        ) as query:
            first = manager.available_build_id(cache_seconds=60)
            second = manager.available_build_id(cache_seconds=60)

        self.assertEqual((first, second), (87654321, 87654321))
        query.assert_called_once_with("public", timeout=manager.STEAM_APP_INFO_TIMEOUT_SECONDS)

    def test_startup_metadata_failure_preserves_complete_installed_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {"UPDATE_ON_START": "true"},
        ), mock.patch.object(manager, "GAME_DIR", Path(directory)), mock.patch.object(
            manager,
            "missing_required_game_files",
            return_value=(),
        ), mock.patch.object(
            manager,
            "installed_build_id",
            return_value=12345678,
        ), mock.patch.object(
            manager,
            "check_steam_update",
            side_effect=RuntimeError("Steam metadata unavailable"),
        ), mock.patch.object(manager, "run_logged_command") as run_command:
            manager.install_or_update()

        run_command.assert_not_called()


class SharedUpdateLockTests(unittest.TestCase):
    def test_nonblocking_shared_lock_reports_another_container_owner(self) -> None:
        class BusyFcntl:
            LOCK_EX = 1
            LOCK_NB = 2
            LOCK_UN = 4

            @staticmethod
            def flock(_descriptor: int, operation: int) -> None:
                if operation & BusyFcntl.LOCK_NB:
                    raise BlockingIOError

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "UPDATE_LOCK_FILE", Path(directory) / "steam-update.lock"
        ), mock.patch.object(manager, "_fcntl", BusyFcntl):
            with manager.shared_update_lock(blocking=False) as lock_state:
                self.assertFalse(lock_state.acquired)
                self.assertIsNone(lock_state.error)

    def test_invalid_shared_lock_path_is_reported_without_raising(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            blocker = Path(directory) / "not-a-directory"
            blocker.write_text("blocked", encoding="utf-8")
            with mock.patch.object(
                manager, "UPDATE_LOCK_FILE", blocker / "steam-update.lock"
            ):
                with manager.shared_update_lock(blocking=False) as lock_state:
                    self.assertFalse(lock_state.acquired)
                    self.assertIn("unavailable", lock_state.error or "")

    def test_startup_steamcmd_waits_for_the_same_shared_lock(self) -> None:
        events: list[str] = []

        class RecordingLock:
            def __init__(self, blocking: bool) -> None:
                self.blocking = blocking

            def __enter__(self) -> manager.UpdateLockState:
                events.append(f"lock:{self.blocking}")
                return manager.UpdateLockState(self.blocking)

            def __exit__(self, *_args: object) -> None:
                pass

        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(
            os.environ,
            {"UPDATE_ON_START": "true", "STEAMCMD_BIN": "/usr/bin/steamcmd"},
        ), mock.patch.object(manager, "GAME_DIR", Path(directory)), mock.patch.object(
            manager, "missing_required_game_files", return_value=()
        ), mock.patch.object(
            manager, "installed_build_id", return_value=1
        ), mock.patch.object(
            manager, "check_steam_update", return_value=(False, 2)
        ), mock.patch.object(
            manager,
            "shared_update_lock",
            side_effect=lambda *, blocking: RecordingLock(blocking),
        ), mock.patch.object(
            manager,
            "run_logged_command",
            side_effect=lambda *_args, **_kwargs: events.append("steamcmd") or 0,
        ):
            manager.install_or_update()

        self.assertEqual(events, ["lock:False", "lock:True", "steamcmd"])

    def test_startup_without_update_work_does_not_take_the_host_lock(self) -> None:
        with mock.patch.dict(os.environ, {"UPDATE_ON_START": "false"}), mock.patch.object(
            manager, "missing_required_game_files", return_value=()
        ), mock.patch.object(manager, "shared_update_lock") as lock:
            manager.install_or_update()

        lock.assert_not_called()

    def test_busy_host_lock_never_stops_the_running_game(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.instance = "server2"
        supervisor.update_in_progress = False
        supervisor.update_warning_seconds = 60
        supervisor.update_retry_interval = 300
        supervisor.proc = mock.Mock()
        supervisor.write_status = mock.Mock()
        lock = mock.MagicMock()
        lock.__enter__.return_value = manager.UpdateLockState(False)

        with mock.patch.object(manager, "shared_update_lock", return_value=lock), mock.patch.object(
            manager.time, "monotonic", return_value=100.0
        ):
            supervisor.perform_update("automatic update detected")

        supervisor.proc.poll.assert_not_called()
        self.assertEqual(supervisor.update_waiting_for_lock, "automatic update detected")
        self.assertEqual(supervisor.update_waiting_for_lock_waittime, 60)
        self.assertEqual(supervisor.next_update_check_monotonic, 115.0)
        supervisor.write_status.assert_called_once_with()

    def test_unavailable_host_lock_never_stops_the_running_game(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.instance = "server2"
        supervisor.update_in_progress = False
        supervisor.update_warning_seconds = 0
        supervisor.update_retry_interval = 300
        supervisor.proc = mock.Mock()
        supervisor.write_status = mock.Mock()
        lock = mock.MagicMock()
        lock.__enter__.return_value = manager.UpdateLockState(False, "permission denied")

        with mock.patch.object(manager, "shared_update_lock", return_value=lock), mock.patch.object(
            manager.time, "monotonic", return_value=100.0
        ):
            supervisor.perform_update("manual update requested", waittime=0)

        supervisor.proc.poll.assert_not_called()
        self.assertEqual(supervisor.last_update_error, "permission denied")
        self.assertEqual(supervisor.update_waiting_for_lock_waittime, 0)

    def test_host_lock_is_held_before_shutdown_through_restart_decision(self) -> None:
        events: list[str] = []

        class RecordingLock:
            def __enter__(self) -> manager.UpdateLockState:
                events.append("lock acquired")
                return manager.UpdateLockState(True)

            def __exit__(self, *_args: object) -> None:
                events.append("lock released")

        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.instance = "server1"
        supervisor.update_in_progress = False
        supervisor.update_waiting_for_lock = "automatic update detected"
        supervisor.update_warning_seconds = 0
        supervisor.update_warning_message = "Restarting in {time}"
        supervisor.restart_countdown_message = "Restarting in {seconds} seconds"
        supervisor.update_retry_interval = 300
        supervisor.update_check_interval = 300
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.terminate_requested = False
        supervisor.phase = "running"
        supervisor.reason = "test"
        supervisor.available_build = 2
        supervisor.last_update_at = None
        supervisor.last_update_error = None
        supervisor.update_blocked = False
        supervisor.next_update_check_monotonic = 0.0
        supervisor.write_status = mock.Mock()
        supervisor.stop_server = mock.Mock(
            side_effect=lambda *_args, **_kwargs: events.append("game stopped") or True
        )
        supervisor.desired_state = mock.Mock(return_value=(False, "outside active window"))
        supervisor.start_server = mock.Mock()

        with mock.patch.object(
            manager, "shared_update_lock", return_value=RecordingLock()
        ), mock.patch.object(
            manager,
            "install_or_update",
            side_effect=lambda **_kwargs: events.append("steamcmd"),
        ) as install, mock.patch.object(
            manager, "prepare_game_files", side_effect=lambda: events.append("prepared")
        ), mock.patch.object(manager, "installed_build_id", return_value=2):
            supervisor.perform_update("automatic update detected", waittime=0)

        self.assertEqual(
            events,
            ["lock acquired", "game stopped", "steamcmd", "prepared", "lock released"],
        )
        install.assert_called_once_with(force_update=True, update_lock_held=True)
        supervisor.start_server.assert_not_called()

    def test_steam_distribution_failure_restarts_the_intact_installed_build(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.instance = "server1"
        supervisor.update_in_progress = False
        supervisor.update_waiting_for_lock = None
        supervisor.update_waiting_for_lock_waittime = None
        supervisor.update_waiting_for_restart_announcement = False
        supervisor.update_warning_seconds = 0
        supervisor.update_warning_message = "Restarting in {time}"
        supervisor.restart_countdown_message = "Restarting in {seconds} seconds"
        supervisor.update_retry_interval = 300
        supervisor.proc = None
        supervisor.terminate_requested = False
        supervisor.phase = "running"
        supervisor.reason = "test"
        supervisor.available_build = 2
        supervisor.installed_build = 1
        supervisor.last_update_error = None
        supervisor.update_blocked = False
        supervisor.next_update_check_monotonic = 0.0
        supervisor.write_status = mock.Mock()
        supervisor.desired_state = mock.Mock(return_value=(True, "inside active window"))
        supervisor.start_server = mock.Mock()
        supervisor.disruptive_action_blocked_by_policy = mock.Mock(return_value=False)
        lock = mock.MagicMock()
        lock.__enter__.return_value = manager.UpdateLockState(True)
        deferred = manager.SteamUpdateDeferredError(
            "Steam manifest access denied",
            return_code=8,
        )

        with mock.patch.object(manager, "shared_update_lock", return_value=lock), mock.patch.object(
            manager, "install_or_update", side_effect=deferred
        ), mock.patch.object(manager, "prepare_game_files"), mock.patch.object(
            manager, "installed_build_id", return_value=1
        ), mock.patch.object(manager.time, "monotonic", return_value=100.0):
            supervisor.perform_update("automatic update detected", waittime=0)

        self.assertFalse(supervisor.update_blocked)
        self.assertEqual(supervisor.last_update_error, "Steam manifest access denied")
        self.assertEqual(
            supervisor.next_update_check_monotonic,
            100.0 + manager.STEAM_DISTRIBUTION_RETRY_SECONDS,
        )
        supervisor.start_server.assert_called_once_with(
            "Steam update deferred; inside active window",
            update_before_start=False,
        )

    def test_manual_update_waiting_for_lock_retries_even_when_auto_update_is_disabled(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.update_in_progress = False
        supervisor.next_update_check_monotonic = 10.0
        supervisor.update_waiting_for_lock = "manual update requested"
        supervisor.update_waiting_for_lock_waittime = 0
        supervisor.update_blocked = False
        supervisor.auto_update_enabled = False
        supervisor.perform_update = mock.Mock()

        with mock.patch.object(manager.time, "monotonic", return_value=20.0):
            supervisor.check_automatic_update()

        supervisor.perform_update.assert_called_once_with(
            "manual update requested",
            waittime=0,
            restart_announcement=False,
        )

    def test_lock_wait_status_is_json_serializable_without_exposing_internal_reason(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with mock.patch.object(manager, "MANAGER_DIR", root / "manager"), mock.patch.object(
                manager, "COMMANDS_DIR", root / "manager/commands"
            ), mock.patch.object(manager, "POLICY_FILE", root / "policy/policy.json"):
                supervisor = manager.Supervisor()
                supervisor.update_waiting_for_lock = "manual update requested"
                supervisor.update_waiting_for_lock_waittime = 0
                payload = supervisor.status()

        self.assertTrue(payload["update_waiting_for_host_lock"])
        self.assertNotIn("manual update requested", manager.json.dumps(payload))


class UpdateControlTests(unittest.TestCase):
    def test_palctl_update_accepts_custom_warning_time(self) -> None:
        args = palctl.build_parser().parse_args(["update", "--wait", "120"])
        self.assertEqual(args.command, "update")
        self.assertEqual(args.wait, 120)

    def test_palctl_restart_defaults_to_sixty_seconds(self) -> None:
        args = palctl.build_parser().parse_args(["restart"])
        self.assertEqual(args.wait, 60)

    def test_palctl_safe_shutdown_and_stop_default_to_sixty_seconds(self) -> None:
        for command in ("stop", "shutdown", "safe-stop"):
            args = palctl.build_parser().parse_args([command])
            self.assertEqual(args.wait, 60)

    def test_palctl_internal_reset_stop_defaults_to_sixty_seconds(self) -> None:
        args = palctl.build_parser().parse_args(["reset-stop"])
        self.assertEqual(args.wait, 60)

    def test_restart_uses_shared_warning_and_countdown(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.restart_warning_seconds = 60
        supervisor.restart_warning_message = "{time} 뒤 서버가 재시작됩니다."
        supervisor.restart_countdown_message = "서버 재시작까지 {seconds}초"
        supervisor.stop_server = mock.Mock(return_value=True)
        supervisor.desired_state = mock.Mock(return_value=(True, "manual override"))
        supervisor.start_server = mock.Mock()

        with mock.patch.dict(os.environ, {"UPDATE_ON_START": "false"}):
            self.assertTrue(supervisor.restart_server("manual restart requested"))
        supervisor.stop_server.assert_called_once_with(
            "manual restart requested",
            waittime=60,
            message="1분 뒤 서버가 재시작됩니다.",
            countdown_message="서버 재시작까지 {seconds}초",
            final_message=manager.FINAL_RESTART_MESSAGE,
            require_graceful=True,
        )
        supervisor.start_server.assert_called_once_with(
            "manual restart requested",
            update_before_start=False,
        )

    def test_restart_checks_steamcmd_when_update_on_start_is_enabled(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.restart_warning_seconds = 60
        supervisor.perform_update = mock.Mock()

        with mock.patch.dict(os.environ, {"UPDATE_ON_START": "true"}):
            self.assertTrue(supervisor.restart_server("manual restart requested"))

        supervisor.perform_update.assert_called_once_with(
            "SteamCMD pre-start check: manual restart requested",
            waittime=60,
            restart_announcement=True,
        )

    def test_advanced_start_runs_steamcmd_before_starting_a_stopped_server(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = None
        supervisor.restart_warning_seconds = 60
        supervisor.perform_update = mock.Mock()

        with mock.patch.dict(os.environ, {"UPDATE_ON_START": "true"}):
            self.assertTrue(
                supervisor.start_or_restart_server(
                    "manual start requested",
                    restart=False,
                    waittime=0,
                )
            )

        supervisor.perform_update.assert_called_once_with(
            "SteamCMD pre-start check: manual start requested",
            waittime=0,
            restart_announcement=False,
        )

    def test_advanced_start_is_idempotent_when_server_is_already_running(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.perform_update = mock.Mock()

        with mock.patch.dict(os.environ, {"UPDATE_ON_START": "true"}):
            self.assertTrue(
                supervisor.start_or_restart_server(
                    "manual start requested",
                    restart=False,
                    waittime=0,
                )
            )

        supervisor.perform_update.assert_not_called()

    def test_pending_prestart_update_cannot_be_bypassed_by_reconcile(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.policy_error = None
        supervisor.proc = None
        supervisor.update_blocked = False
        supervisor.update_waiting_for_lock = "SteamCMD pre-start check: manual start requested"
        supervisor.update_in_progress = False
        supervisor.next_start_monotonic = 0.0
        supervisor.start_server = mock.Mock()

        supervisor.reconcile_game_state(True, "manual override", game_running=False)

        supervisor.start_server.assert_not_called()

    def test_prestart_build_mismatch_runs_update_before_game_launch(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.update_retry_interval = 300
        supervisor.perform_update = mock.Mock()
        supervisor.last_update_error = None
        supervisor.available_build = None
        supervisor.installed_build = None

        with mock.patch.object(
            manager,
            "installed_build_id",
            return_value=12345678,
        ), mock.patch.object(
            manager,
            "check_steam_update",
            return_value=(False, 87654321),
        ):
            required = supervisor.update_required_before_game_start(
                "manual start requested",
                waittime=0,
                restart_announcement=False,
                force_refresh=True,
            )

        self.assertTrue(required)
        self.assertEqual(supervisor.installed_build, 12345678)
        self.assertEqual(supervisor.available_build, 87654321)
        supervisor.perform_update.assert_called_once_with(
            "pre-start update detected: manual start requested",
            waittime=0,
            restart_announcement=False,
        )

    def test_update_stop_announces_then_saves_and_shuts_down(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.shutdown_wait = 30
        supervisor.phase = "running"
        supervisor.reason = "test"
        supervisor.last_started_monotonic = 1.0
        supervisor.write_status = mock.Mock()
        supervisor.wait_for_exit = mock.Mock(side_effect=([False] * 11) + [True])
        supervisor.signal_process_group = mock.Mock()

        with mock.patch.dict("os.environ", {"PAL_SETTING_RESTAPIEnabled": "true"}), mock.patch.object(
            manager, "api_request"
        ) as api:
            supervisor.stop_server(
                "automatic update detected",
                waittime=60,
                message="Restarting in 60 seconds",
                countdown_message="Restarting in {seconds} seconds",
                final_message=manager.FINAL_UPDATE_MESSAGE,
            )

        endpoints = [call.args[0] for call in api.call_args_list]
        self.assertEqual(endpoints, (["announce"] * 11) + ["save", "shutdown"])
        self.assertEqual(api.call_args_list[1].kwargs["body"]["message"], "Restarting in 10 seconds")
        self.assertEqual(api.call_args_list[10].kwargs["body"]["message"], "Restarting in 1 seconds")
        self.assertEqual(api.call_args_list[-1].kwargs["body"]["waittime"], 1)
        self.assertEqual(
            api.call_args_list[-1].kwargs["body"]["message"],
            manager.FINAL_UPDATE_MESSAGE,
        )

    def test_update_is_postponed_when_graceful_shutdown_is_unavailable(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.shutdown_wait = 30
        supervisor.phase = "running"
        supervisor.reason = "test"
        supervisor.last_started_monotonic = 1.0
        supervisor.write_status = mock.Mock()
        supervisor.wait_for_exit = mock.Mock()
        supervisor.signal_process_group = mock.Mock()

        with mock.patch.dict("os.environ", {"PAL_SETTING_RESTAPIEnabled": "false"}):
            stopped = supervisor.stop_server(
                "automatic update detected",
                waittime=60,
                message="Restarting in 60 seconds",
                require_graceful=True,
            )

        self.assertFalse(stopped)
        supervisor.signal_process_group.assert_not_called()
        self.assertEqual(supervisor.phase, "running")

    def test_safe_stop_announces_saves_then_uses_stop_endpoint(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.shutdown_wait = 30
        supervisor.phase = "running"
        supervisor.reason = "test"
        supervisor.last_started_monotonic = 1.0
        supervisor.write_status = mock.Mock()
        supervisor.wait_for_exit = mock.Mock(side_effect=([False] * 11) + [True])
        supervisor.signal_process_group = mock.Mock()

        with mock.patch.dict("os.environ", {"PAL_SETTING_RESTAPIEnabled": "true"}), mock.patch.object(
            manager, "api_request"
        ) as api:
            stopped = supervisor.stop_server(
                "safe stop",
                waittime=60,
                message="Stopping in 60 seconds",
                countdown_message="Stopping in {seconds} seconds",
                require_graceful=True,
                final_action="stop",
            )

        self.assertTrue(stopped)
        endpoints = [call.args[0] for call in api.call_args_list]
        self.assertEqual(endpoints, (["announce"] * 11) + ["save", "stop"])

    def test_safe_shutdown_is_postponed_when_world_save_fails(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = mock.Mock()
        supervisor.proc.poll.return_value = None
        supervisor.shutdown_wait = 30
        supervisor.phase = "running"
        supervisor.reason = "test"
        supervisor.last_started_monotonic = 1.0
        supervisor.write_status = mock.Mock()
        supervisor.wait_for_exit = mock.Mock(side_effect=([False] * 11))
        supervisor.signal_process_group = mock.Mock()

        def request(endpoint: str, **_kwargs: object) -> None:
            if endpoint == "save":
                raise RuntimeError("save unavailable")

        with mock.patch.dict("os.environ", {"PAL_SETTING_RESTAPIEnabled": "true"}), mock.patch.object(
            manager, "api_request", side_effect=request
        ) as api:
            stopped = supervisor.stop_server(
                "safe shutdown",
                waittime=60,
                message="Stopping in 60 seconds",
                countdown_message="Stopping in {seconds} seconds",
                require_graceful=True,
            )

        self.assertFalse(stopped)
        self.assertNotIn("shutdown", [call.args[0] for call in api.call_args_list])
        supervisor.signal_process_group.assert_not_called()
        self.assertEqual(supervisor.phase, "running")

    def test_shutdown_command_keeps_stopped_policy_after_success(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.restart_warning_seconds = 60
        supervisor.shutdown_warning_seconds = 60
        supervisor.active_window = None
        supervisor.shutdown_server = mock.Mock(return_value=True)
        supervisor.set_policy = mock.Mock()

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "COMMANDS_DIR", Path(directory)
        ):
            manager.atomic_write_json(
                Path(directory) / "shutdown.json", {"action": "shutdown", "waittime": 60}
            )
            supervisor.process_commands()

        supervisor.shutdown_server.assert_called_once_with(
            "manual safe shutdown requested", waittime=60
        )
        supervisor.set_policy.assert_called_once_with("stopped", until=None)

    def test_start_command_restores_auto_schedule_policy(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.restart_warning_seconds = 60
        supervisor.shutdown_warning_seconds = 60
        supervisor.active_window = None
        supervisor.set_policy = mock.Mock()
        supervisor.start_or_restart_server = mock.Mock(return_value=True)

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "COMMANDS_DIR", Path(directory)
        ):
            manager.atomic_write_json(Path(directory) / "start.json", {"action": "start"})
            supervisor.process_commands()

        supervisor.set_policy.assert_called_once_with("auto", until=None)
        self.assertEqual(supervisor.reason, "manual start requested")
        supervisor.start_or_restart_server.assert_called_once_with(
            "manual start requested",
            restart=False,
            waittime=0,
        )

    def test_reset_stop_uses_reset_message_and_holds_stopped_policy(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.restart_warning_seconds = 60
        supervisor.shutdown_warning_seconds = 60
        supervisor.shutdown_server = mock.Mock(return_value=True)
        supervisor.set_policy = mock.Mock()

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "COMMANDS_DIR", Path(directory)
        ):
            manager.atomic_write_json(
                Path(directory) / "reset.json", {"action": "reset-stop", "waittime": 60}
            )
            supervisor.process_commands()

        supervisor.shutdown_server.assert_called_once_with(
            "world reset requested",
            waittime=60,
            final_message=manager.FINAL_RESET_MESSAGE,
        )
        supervisor.set_policy.assert_called_once_with("stopped")
        self.assertEqual(supervisor.reason, "world reset prepared")

    def test_expired_temporary_policy_returns_to_auto(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        now = datetime(2026, 1, 2, 14, 0, tzinfo=timezone.utc)
        supervisor.active_window = manager.parse_active_window("14:00-02:00")
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "POLICY_FILE", Path(directory) / "policy.json"
        ):
            supervisor.set_policy("stopped", until=now)
            self.assertEqual(supervisor.desired_state(now), (True, "inside active window"))
            self.assertEqual(manager.read_json(manager.POLICY_FILE)["override"], "auto")

    def test_outside_start_override_expires_at_the_next_window_end(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.active_window = manager.parse_active_window("14:00-02:00")
        started_at = datetime(2026, 1, 2, 10, 0, tzinfo=timezone.utc)
        ends_at = datetime(2026, 1, 3, 2, 0, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "POLICY_FILE", Path(directory) / "policy.json"
        ):
            supervisor.set_policy("started", until=ends_at)
            self.assertEqual(supervisor.desired_state(started_at), (True, "manual override"))
            self.assertEqual(supervisor.desired_state(ends_at), (False, "outside active window"))

    def test_stopping_an_already_stopped_server_is_idempotent(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.proc = None
        supervisor.last_started_monotonic = None
        supervisor.phase = "stopped"
        supervisor.reason = "outside active window"
        self.assertTrue(supervisor.stop_server("manual safe shutdown requested"))
        self.assertEqual(supervisor.phase, "stopped")

    def test_failed_shutdown_does_not_force_stopped_policy(self) -> None:
        supervisor = manager.Supervisor.__new__(manager.Supervisor)
        supervisor.restart_warning_seconds = 60
        supervisor.shutdown_warning_seconds = 60
        supervisor.active_window = None
        supervisor.shutdown_server = mock.Mock(return_value=False)
        supervisor.set_policy = mock.Mock()

        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            manager, "COMMANDS_DIR", Path(directory)
        ):
            manager.atomic_write_json(
                Path(directory) / "shutdown.json", {"action": "shutdown", "waittime": 60}
            )
            supervisor.process_commands()

        supervisor.set_policy.assert_not_called()


class SettingsTests(unittest.TestCase):
    DEFAULT = (
        "[/Script/Pal.PalGameWorldSettings]\n"
        'OptionSettings=(ServerName="Default Palworld Server",ServerPassword="",'
        "ServerPlayerMaxNum=32,RESTAPIEnabled=False,"
        "CrossplayPlatforms=(Steam,Xbox,PS5,Mac))\n"
    )

    def test_nested_commas_are_not_split(self) -> None:
        _, body, _ = manager.find_option_settings(self.DEFAULT)
        settings = manager.parse_settings_body(body)
        self.assertEqual(settings["CrossplayPlatforms"], "(Steam,Xbox,PS5,Mac)")

    def test_render_settings_preserves_types(self) -> None:
        rendered = manager.render_settings(
            self.DEFAULT,
            {
                "ServerName": 'Friends "Only"',
                "ServerPlayerMaxNum": "16",
                "RESTAPIEnabled": "yes",
                "CrossplayPlatforms": "raw:(Steam,Xbox)",
            },
        )
        self.assertIn('ServerName="Friends \\"Only\\""', rendered)
        self.assertIn("ServerPlayerMaxNum=16", rendered)
        self.assertIn("RESTAPIEnabled=True", rendered)
        self.assertIn("CrossplayPlatforms=(Steam,Xbox)", rendered)

    def test_unknown_plain_value_is_quoted(self) -> None:
        rendered = manager.render_settings(self.DEFAULT, {"FutureSetting": "hello world"})
        self.assertIn('FutureSetting="hello world"', rendered)

    def test_invalid_number_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            manager.render_settings(self.DEFAULT, {"ServerPlayerMaxNum": "many"})

    def test_generated_server_config_is_atomic_and_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            default_config = root / "DefaultPalWorldSettings.ini"
            server_config = root / "PalWorldSettings.ini"
            default_config.write_text(self.DEFAULT, encoding="utf-8")

            with mock.patch.object(manager, "DEFAULT_CONFIG", default_config), mock.patch.object(
                manager, "SERVER_CONFIG", server_config
            ), mock.patch.object(
                manager, "collect_overrides", return_value={"ServerPlayerMaxNum": "16"}
            ):
                manager.write_server_config()

            self.assertIn("ServerPlayerMaxNum=16", server_config.read_text(encoding="utf-8"))
            if os.name == "posix":
                self.assertEqual(server_config.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(root.glob(".PalWorldSettings.ini.*")), [])


if __name__ == "__main__":
    unittest.main()
