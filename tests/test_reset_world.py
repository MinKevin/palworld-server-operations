from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import reset_world  # noqa: E402


class ResetStorageTests(unittest.TestCase):
    GUID = "194BD519A0A64194B211F207027544BD"

    def make_project(self, root: Path) -> reset_world.ResetPaths:
        (root / "config").mkdir()
        (root / "config/server1.env").write_text(
            "PAL_SETTING_AdminPassword=secret-value\n", encoding="utf-8"
        )
        world = root / "data/server1/saved/SaveGames/0" / self.GUID
        (world / "Players").mkdir(parents=True)
        (world / "Players/player.sav").write_bytes(b"player")
        (world / "Level.sav").write_bytes(b"level")
        (world / "LevelMeta.sav").write_bytes(b"meta")
        config = root / "data/server1/saved/Config/LinuxServer"
        config.mkdir(parents=True)
        (config / "GameUserSettings.ini").write_text("not-backed-up", encoding="utf-8")
        logs = root / "data/server1/logs"
        logs.mkdir(parents=True)
        (logs / "runtime.log").write_text("runtime event\n", encoding="utf-8")
        return reset_world.build_paths(root, "server1")

    def test_verified_reset_backup_contains_world_logs_and_server_env(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            reset_world, "FREE_SPACE_RESERVE", 0
        ):
            project = Path(directory)
            paths = self.make_project(project)
            backup, metadata = reset_world.backup_and_clear(
                paths,
                reported_guid=self.GUID,
                timestamp="2026.07.17-12.34.56",
            )

            self.assertEqual(
                backup.resolve(),
                (project / "backups/server1/reset_2026.07.17-12.34.56").resolve(),
            )
            self.assertEqual((backup / f"world/{self.GUID}/Level.sav").read_bytes(), b"level")
            self.assertEqual((backup / "logs/runtime.log").read_text(encoding="utf-8"), "runtime event\n")
            self.assertEqual(
                (backup / "config/server1.env").read_text(encoding="utf-8"),
                "PAL_SETTING_AdminPassword=secret-value\n",
            )
            self.assertFalse(any(backup.rglob("GameUserSettings.ini")))
            self.assertEqual(metadata["old_world_guid"], self.GUID)
            stored = json.loads((backup / "metadata.json").read_text(encoding="utf-8"))
            self.assertEqual(stored["status"], "backup-verified")
            self.assertGreater(stored["contents"]["world"]["files"], 0)
            self.assertTrue((project / "data/server1/saved").is_dir())
            self.assertTrue((project / "data/server1/logs").is_dir())
            self.assertEqual(
                {path.name for path in (project / "data/server1").iterdir()},
                {"saved", "logs"},
            )

    def test_copy_failure_does_not_delete_live_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            reset_world, "FREE_SPACE_RESERVE", 0
        ):
            project = Path(directory)
            paths = self.make_project(project)
            with mock.patch.object(reset_world.shutil, "copytree", side_effect=OSError("copy failed")):
                with self.assertRaises(OSError):
                    reset_world.backup_and_clear(paths, timestamp="2026.07.17-12.34.56")

            self.assertEqual(
                (paths.savegames / self.GUID / "Level.sav").read_bytes(), b"level"
            )
            failed = list(paths.backup_root.glob("*.failed"))
            self.assertEqual(len(failed), 1)

    def test_build_paths_rejects_unexpected_server_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                reset_world.build_paths(Path(directory), "../server1")

    def test_parser_rejects_abbreviated_target_options(self) -> None:
        with self.assertRaises(SystemExit):
            reset_world.build_parser().parse_args(["--serv", "server1"])

    def test_reported_guid_is_case_insensitive(self) -> None:
        self.assertEqual(
            reset_world.reported_world_guid({"worldGuid": self.GUID.lower()}), self.GUID
        )

    def test_completed_reset_uses_instance_name_from_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            paths = self.make_project(project)
            backup = project / "backups/server1/reset_test"
            with (
                mock.patch.object(reset_world, "container_exists", return_value=True),
                mock.patch.object(reset_world, "reject_symlinks"),
                mock.patch.object(reset_world, "ensure_backup_space"),
                mock.patch.object(reset_world, "container_running", return_value=False),
                mock.patch.object(
                    reset_world,
                    "safely_stop_container",
                    return_value=(False, False, self.GUID),
                ),
                mock.patch.object(
                    reset_world,
                    "backup_and_clear",
                    return_value=(backup, {"old_world_guid": self.GUID}),
                ),
                mock.patch.object(reset_world, "start_new_world", return_value=self.GUID),
                mock.patch.object(reset_world, "update_metadata"),
                mock.patch.object(reset_world, "log") as log,
            ):
                result = reset_world._reset_world_locked(paths, 60, 1200)

            self.assertEqual(result, backup)
            self.assertIn(
                mock.call("server1: 새 월드 생성 완료"),
                log.call_args_list,
            )


if __name__ == "__main__":
    unittest.main()
