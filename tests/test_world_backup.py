from __future__ import annotations

import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import world_backup  # noqa: E402


def write_payload(path: Path, marker: str, *, include_players: bool = True) -> None:
    path.mkdir(parents=True, exist_ok=True)
    if include_players:
        (path / "Players").mkdir()
        (path / "Players" / "player.sav").write_text(f"player-{marker}", encoding="utf-8")
    (path / "LevelMeta.sav").write_text(f"meta-{marker}", encoding="utf-8")
    (path / "Level.sav").write_text(f"level-{marker}", encoding="utf-8")


class WorldBackupTests(unittest.TestCase):
    def test_lists_only_complete_timestamped_backups(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory) / "SaveGames" / "0"
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            write_payload(world, "current")
            write_payload(world / "backup/world/2026.07.17-02.45.46", "backup")
            write_payload(world / "backup/world/deleted_2026.07.17-01.59.52", "deleted")
            invalid = world / "backup/world/2026.07.17-01.00.00"
            invalid.mkdir(parents=True)
            (invalid / "Level.sav").touch()

            result = world_backup.list_world_backups(savegames)

            self.assertEqual(result["world_guid"], world.name)
            self.assertEqual(
                [item["name"] for item in result["backups"]],
                ["2026.07.17-02.45.46", "deleted_2026.07.17-01.59.52"],
            )
            self.assertEqual(result["backups"][1]["kind"], "pre-restore")

    def test_restore_preserves_current_world_before_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory) / "SaveGames" / "0"
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            write_payload(world, "current")
            backup_name = "2026.07.17-02.45.46"
            write_payload(world / "backup/world" / backup_name, "backup")

            deleted = world_backup.create_deleted_snapshot(
                world,
                datetime(2026, 7, 17, 3, 0, 0, tzinfo=timezone.utc),
            )
            staged = world_backup.stage_backup(world, backup_name)
            world_backup.replace_world_payload(world, staged)

            self.assertEqual(deleted.name, "deleted_2026.07.17-03.00.00")
            self.assertEqual((deleted / "Level.sav").read_text(encoding="utf-8"), "level-current")
            self.assertEqual((world / "Level.sav").read_text(encoding="utf-8"), "level-backup")
            self.assertEqual(
                (world / "Players/player.sav").read_text(encoding="utf-8"),
                "player-backup",
            )
            self.assertTrue((world / "backup/world" / backup_name).is_dir())

    def test_restore_includes_optional_world_files_without_copying_backup_recursively(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory) / "SaveGames" / "0"
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            backup_name = "2026.07.17-02.45.46"
            backup = world / "backup/world" / backup_name
            write_payload(world, "current")
            (world / "WorldOption.sav").write_text("option-current", encoding="utf-8")
            write_payload(backup, "backup")
            (backup / "WorldOption.sav").write_text("option-backup", encoding="utf-8")

            deleted = world_backup.create_deleted_snapshot(
                world,
                datetime(2026, 7, 17, 3, 0, 0, tzinfo=timezone.utc),
            )
            staged = world_backup.stage_backup(world, backup_name)
            self.assertEqual(
                (staged / "WorldOption.sav").read_text(encoding="utf-8"),
                "option-backup",
            )
            self.assertFalse((staged / "backup").exists())

            world_backup.replace_world_payload(world, staged)

            self.assertEqual(
                (world / "WorldOption.sav").read_text(encoding="utf-8"),
                "option-backup",
            )
            self.assertEqual(
                (deleted / "WorldOption.sav").read_text(encoding="utf-8"),
                "option-current",
            )

    def test_rejects_untrusted_backup_names_and_multiple_worlds(self) -> None:
        with self.assertRaises(ValueError):
            world_backup.validate_backup_name("../../world")
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory)
            first = savegames / "11111111111111111111111111111111"
            second = savegames / "22222222222222222222222222222222"
            write_payload(first, "one")
            write_payload(second, "two")
            with self.assertRaises(RuntimeError):
                world_backup.discover_world_directory(savegames)
            self.assertEqual(
                world_backup.discover_world_directory(
                    savegames,
                    preferred_guid=second.name.lower(),
                ),
                second,
            )

            settings = Path(directory) / "GameUserSettings.ini"
            settings.write_text(
                f"[Server]\nDedicatedServerName={first.name}\n",
                encoding="utf-8",
            )
            self.assertEqual(
                world_backup.discover_world_directory(savegames, settings_file=settings),
                first,
            )

    def test_new_world_and_backup_without_players_are_supported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory) / "SaveGames" / "0"
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            backup_name = "2026.07.17-02.45.46"
            backup = world / "backup/world" / backup_name
            write_payload(world, "current", include_players=False)
            write_payload(backup, "backup", include_players=False)

            result = world_backup.list_world_backups(savegames)

            self.assertEqual(result["world_guid"], world.name)
            self.assertEqual([item["name"] for item in result["backups"]], [backup_name])
            self.assertEqual(result["backups"][0]["file_count"], 2)

    def test_restoring_empty_player_set_removes_current_players(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory) / "SaveGames" / "0"
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            backup_name = "2026.07.17-02.45.46"
            backup = world / "backup/world" / backup_name
            write_payload(world, "current")
            write_payload(backup, "backup", include_players=False)

            staged = world_backup.stage_backup(world, backup_name)
            world_backup.replace_world_payload(world, staged)

            self.assertTrue((world / "Players").is_dir())
            self.assertEqual(list((world / "Players").iterdir()), [])
            self.assertEqual((world / "Level.sav").read_text(encoding="utf-8"), "level-backup")

    def test_interrupted_payload_swap_is_recovered_on_startup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory)
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            write_payload(world, "current")
            old_payload = world / ".restore-old-test"
            old_payload.mkdir()
            for name in world_backup.PAYLOAD_NAMES:
                (world / name).replace(old_payload / name)
            (world / "Level.sav").write_text("partial-new", encoding="utf-8")

            recovered = world_backup.recover_interrupted_restores(savegames)

            self.assertEqual(recovered, [str(world)])
            self.assertEqual((world / "Level.sav").read_text(encoding="utf-8"), "level-current")
            self.assertFalse(old_payload.exists())

    def test_interrupted_committed_cleanup_keeps_the_complete_new_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory)
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            staged = savegames / "staged"
            write_payload(world, "current")
            (world / "WorldOption.sav").write_text("option-current", encoding="utf-8")
            write_payload(staged, "backup")
            (staged / "WorldOption.sav").write_text("option-backup", encoding="utf-8")
            real_rmtree = world_backup.shutil.rmtree

            def interrupt_committed_cleanup(path: Path, *args: object, **kwargs: object) -> None:
                path = Path(path)
                if path.name.startswith(world_backup.COMMITTED_RESTORE_PREFIX):
                    # Simulate termination after cleanup removed only one old
                    # item. The active new payload must remain authoritative.
                    old_level = path / "Level.sav"
                    if old_level.exists():
                        old_level.unlink()
                    return
                real_rmtree(path, *args, **kwargs)

            with mock.patch.object(
                world_backup.shutil,
                "rmtree",
                side_effect=interrupt_committed_cleanup,
            ):
                world_backup.replace_world_payload(world, staged)

            committed = list(
                world.glob(f"{world_backup.COMMITTED_RESTORE_PREFIX}*")
            )
            self.assertEqual(len(committed), 1)
            self.assertEqual((world / "Level.sav").read_text(encoding="utf-8"), "level-backup")

            recovered = world_backup.recover_interrupted_restores(savegames)

            self.assertEqual(recovered, [])
            self.assertEqual((world / "Level.sav").read_text(encoding="utf-8"), "level-backup")
            self.assertEqual(
                (world / "LevelMeta.sav").read_text(encoding="utf-8"),
                "meta-backup",
            )
            self.assertEqual(
                (world / "WorldOption.sav").read_text(encoding="utf-8"),
                "option-backup",
            )
            self.assertFalse(committed[0].exists())

    def test_partial_rollback_recovery_keeps_items_already_restored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory)
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            write_payload(world, "current")
            old_payload = world / ".restore-old-test"
            old_payload.mkdir()
            (world / "Level.sav").replace(old_payload / "Level.sav")

            recovered = world_backup.recover_interrupted_restores(savegames)

            self.assertEqual(recovered, [str(world)])
            self.assertEqual((world / "Players/player.sav").read_text(encoding="utf-8"), "player-current")
            self.assertEqual((world / "LevelMeta.sav").read_text(encoding="utf-8"), "meta-current")
            self.assertEqual((world / "Level.sav").read_text(encoding="utf-8"), "level-current")

    def test_failed_startup_recovery_preserves_remaining_old_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory)
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            write_payload(world, "current")
            old_payload = world / ".restore-old-test"
            old_payload.mkdir()
            for name in world_backup.PAYLOAD_NAMES:
                (world / name).replace(old_payload / name)
            (world / "Level.sav").write_text("partial-new", encoding="utf-8")
            real_replace = world_backup.os.replace

            def fail_mid_recovery(source: Path, destination: Path) -> None:
                source = Path(source)
                if source.parent == old_payload and source.name == "LevelMeta.sav":
                    raise OSError("simulated startup recovery failure")
                real_replace(source, destination)

            with mock.patch.object(
                world_backup.os, "replace", side_effect=fail_mid_recovery
            ):
                with self.assertRaisesRegex(
                    OSError, "simulated startup recovery failure"
                ):
                    world_backup.recover_interrupted_restores(savegames)

            self.assertTrue(old_payload.is_dir())
            self.assertTrue((old_payload / "LevelMeta.sav").is_file())
            self.assertEqual(
                (world / "Level.sav").read_text(encoding="utf-8"),
                "level-current",
            )

            recovered = world_backup.recover_interrupted_restores(savegames)

            self.assertEqual(recovered, [str(world)])
            self.assertEqual(
                (world / "LevelMeta.sav").read_text(encoding="utf-8"),
                "meta-current",
            )
            self.assertFalse(old_payload.exists())

    def test_sha256_manifest_detects_same_size_content_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first"
            second = Path(directory) / "second"
            write_payload(first, "aaaa")
            write_payload(second, "bbbb")
            self.assertEqual(world_backup.payload_statistics(first), world_backup.payload_statistics(second))
            self.assertNotEqual(world_backup.payload_manifest(first), world_backup.payload_manifest(second))

    def test_restore_disk_preflight_fails_before_copy_when_space_is_low(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            world = Path(directory) / "world"
            backup = world / "backup/world/2026.07.17-02.45.46"
            write_payload(world, "current")
            write_payload(backup, "backup")
            with mock.patch.object(
                world_backup.shutil,
                "disk_usage",
                return_value=mock.Mock(total=100, used=99, free=1),
            ):
                with self.assertRaisesRegex(OSError, "insufficient free space"):
                    world_backup.ensure_restore_disk_space(world, backup)

    def test_failed_partial_rollback_is_preserved_for_startup_recovery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            savegames = Path(directory)
            world = savegames / "96FBD59D86CB4A0FBCBFC516DD1323F0"
            staged = savegames / "staged"
            write_payload(world, "current")
            write_payload(staged, "backup")
            real_replace = world_backup.os.replace

            def unreliable_replace(source: Path, destination: Path) -> None:
                source = Path(source)
                if source.parent == staged and source.name == "LevelMeta.sav":
                    raise OSError("simulated replacement failure")
                if source.parent.name.startswith(".restore-old-") and source.name == "LevelMeta.sav":
                    raise OSError("simulated rollback failure")
                real_replace(source, destination)

            with mock.patch.object(world_backup.os, "replace", side_effect=unreliable_replace):
                with self.assertRaisesRegex(RuntimeError, "partial rollback preserved"):
                    world_backup.replace_world_payload(world, staged)

            protected = list(world.glob(".restore-old-*"))
            self.assertEqual(len(protected), 1)
            self.assertTrue((protected[0] / "LevelMeta.sav").is_file())

            recovered = world_backup.recover_interrupted_restores(savegames)
            self.assertEqual(recovered, [str(world)])
            self.assertEqual((world / "LevelMeta.sav").read_text(encoding="utf-8"), "meta-current")


if __name__ == "__main__":
    unittest.main()
