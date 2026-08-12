from __future__ import annotations

import contextlib
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(SCRIPTS))

import import_existing  # noqa: E402


GUID = "96FBD59D86CB4A0FBCBFC516DD1323F0"


def create_source(root: Path, *, windows_config: bool = False) -> Path:
    saved = root / "Pal/Saved"
    world = saved / "SaveGames/0" / GUID
    (world / "Players").mkdir(parents=True)
    (world / "Players/player.sav").write_bytes(b"player")
    (world / "Level.sav").write_bytes(b"level")
    (world / "LevelMeta.sav").write_bytes(b"meta")
    (world / "WorldOption.sav").write_bytes(b"option")
    backup = world / "backup/world/2026.07.17-02.45.46"
    backup.mkdir(parents=True)
    (backup / "Level.sav").write_bytes(b"old-level")
    (backup / "LevelMeta.sav").write_bytes(b"old-meta")
    platform = "WindowsServer" if windows_config else "LinuxServer"
    config = saved / "Config" / platform
    config.mkdir(parents=True)
    (config / "GameUserSettings.ini").write_text(
        f"[Server]\nDedicatedServerName={GUID}\n",
        encoding="utf-8",
    )
    (config / "PalWorldSettings.ini").write_text(
        "[/Script/Pal.PalGameWorldSettings]\n"
        'OptionSettings=(ServerName="Legacy World",AdminPassword="legacy-secret",'
        "RESTAPIEnabled=False,RESTAPIPort=8222,ExpRate=2.0,CustomStruct=(A=1,B=2))\n",
        encoding="utf-8",
    )
    (saved / "Logs").mkdir()
    (saved / "Logs/legacy.log").write_text("legacy", encoding="utf-8")
    return saved


def create_project(root: Path) -> Path:
    project = root / "palworld-docker"
    (project / "config").mkdir(parents=True)
    (project / "data").mkdir()
    (project / "backups").mkdir()
    repository = Path(__file__).resolve().parents[1]
    shutil.copy2(repository / "config/en/server.template.env", project / "config/server.template.env")
    shutil.copy2(repository / "config/en/common.env", project / "config/common.env")
    return project


class ExistingServerImportTests(unittest.TestCase):
    def test_korean_app_language_loads_the_kr_template_directory(self) -> None:
        repository = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            project_template = Path(directory) / "server.template.env"
            project_template.write_text("SERVER_PORT=1\n", encoding="utf-8")
            with mock.patch.dict(
                import_existing.os.environ,
                {"PALWORLD_ENV_LANGUAGE": "ko"},
                clear=True,
            ):
                loaded = import_existing.current_import_template(project_template)

        expected = (repository / "config/kr/server.template.env").read_text(
            encoding="utf-8-sig"
        )
        self.assertEqual(loaded, expected)

    def test_discovers_valid_world_and_runtime_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            saved = create_source(root / "legacy")
            with mock.patch.object(
                import_existing,
                "runtime_records",
                return_value=[
                    {
                        "pid": 123,
                        "type": "systemd",
                        "control_id": "palworld.service",
                        "game_port": 8211,
                        "community_server": False,
                        "command": "PalServer.sh -port=8211",
                    }
                ],
            ):
                worlds = import_existing.scan_worlds(root)

            self.assertEqual(len(worlds), 1)
            self.assertEqual(worlds[0]["saved_directory"], str(saved))
            self.assertEqual(worlds[0]["world_guid"], GUID)
            self.assertTrue(worlds[0]["active"])
            self.assertTrue(worlds[0]["world_option_present"])
            self.assertEqual(worlds[0]["server_name"], "Legacy World")
            self.assertEqual(worlds[0]["game_port"], 8211)
            self.assertEqual(worlds[0]["rest_api_port"], 8222)

    def test_generates_reviewable_env_and_preserves_project_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = create_project(root)
            saved = create_source(root / "legacy")
            source = import_existing.parse_option_settings(
                import_existing.read_text(import_existing.config_file(saved, "PalWorldSettings.ini"))
            )

            content, review = import_existing.build_target_env(
                project,
                "server1",
                source,
                world_guid=GUID,
                game_port=8211,
                rest_port=8222,
                rest_api_expose=True,
                community_server=False,
            )

            self.assertIn("ACTIVE_WINDOW=always", content)
            self.assertIn("RESTART_TIMES=04:00", content)
            self.assertIn("SERVER_PORT=8211", content)
            self.assertIn("PAL_SETTING_RESTAPIPort=8222", content)
            self.assertIn("PAL_SETTING_RESTAPIEnabled=True", content)
            self.assertIn("PAL_SETTING_ServerName=Legacy World", content)
            self.assertIn("PAL_SETTING_PublicPort=8211", content)
            self.assertIn("PAL_SETTING_CustomStruct=raw:(A=1,B=2)", content)
            self.assertIn(import_existing.UNMAPPED_IMPORT_HEADER, content)
            self.assertFalse(content.startswith("PAL_SETTING_"))
            fallback = content.split(import_existing.UNMAPPED_IMPORT_HEADER, 1)[1]
            self.assertIn("PAL_SETTING_CustomStruct=raw:(A=1,B=2)", fallback)
            self.assertNotIn("PAL_SETTING_ExpRate", fallback)
            review_by_id = {item["id"]: item for item in review}
            self.assertEqual(review_by_id["game-port"]["status"], "REVIEW")
            self.assertEqual(review_by_id["active-window"]["status"], "REVIEW")
            self.assertIn("14:00-02:00", review_by_id["active-window"]["description"])
            self.assertIn("Fine-tune", review_by_id["automatic-updates"]["description"])
            self.assertEqual(review_by_id["community-server"]["status"], "REVIEW")
            self.assertEqual(review_by_id["pal-setting-ServerName"]["value"], "Legacy World")
            self.assertEqual(review_by_id["pal-setting-CustomStruct"]["value"], "raw:(A=1,B=2)")
            self.assertEqual(review_by_id["pal-setting-CustomStruct"]["status"], "UNMAPPED")

    def test_missing_detected_game_port_is_blocked_for_review(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = create_project(root)
            saved = create_source(root / "legacy")
            source = import_existing.parse_option_settings(
                import_existing.read_text(
                    import_existing.config_file(saved, "PalWorldSettings.ini")
                )
            )

            content, review = import_existing.build_target_env(
                project,
                "server1",
                source,
                world_guid=GUID,
                game_port=None,
                rest_port=8222,
                rest_api_expose=True,
                community_server=False,
            )

            review_by_id = {item["id"]: item for item in review}
            self.assertEqual(review[0]["id"], "game-port")
            self.assertEqual(review_by_id["game-port"]["status"], "BLOCKED")
            self.assertEqual(review_by_id["game-port"]["value"], "")
            self.assertIn("SERVER_PORT=\n", content)

    def test_running_source_listener_does_not_block_settings_review(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = create_project(root)
            saved = create_source(root / "legacy")
            source = import_existing.parse_option_settings(
                import_existing.read_text(
                    import_existing.config_file(saved, "PalWorldSettings.ini")
                )
            )
            with mock.patch.object(
                import_existing,
                "port_in_use",
                side_effect=AssertionError("review must not probe live listeners"),
            ):
                _content, review = import_existing.build_target_env(
                    project,
                    "server1",
                    source,
                    world_guid=GUID,
                    game_port=8211,
                    rest_port=8222,
                    rest_api_expose=True,
                    community_server=False,
                )

        review_by_id = {item["id"]: item for item in review}
        self.assertEqual(review_by_id["game-port"]["status"], "REVIEW")
        self.assertEqual(review_by_id["rest-port"]["status"], "REVIEW")

    def test_current_settings_shapes_are_mapped_individually(self) -> None:
        content = (
            "[/Script/Pal.PalGameWorldSettings]\n"
            'OptionSettings=(Difficulty=None,RandomizerSeed="",bIsRandomizerPalLevelRandom=False,'
            "ExpRate=2.500000,RESTAPIEnabled=True,RESTAPIPort=45112,"
            "CrossplayPlatforms=(Steam,Xbox,PS5,Mac),DenyTechnologyList=,"
            'AdditionalDropItemWhenPlayerKillingInPvPMode="PlayerDropItem",'
            "BuildingNameDisplayCacheTTLSeconds=60)\n"
        )
        settings = import_existing.parse_option_settings(content)

        self.assertEqual(settings["ExpRate"], "2.500000")
        self.assertEqual(settings["CrossplayPlatforms"], "(Steam,Xbox,PS5,Mac)")
        self.assertEqual(settings["DenyTechnologyList"], "")
        self.assertEqual(settings["BuildingNameDisplayCacheTTLSeconds"], "60")
        self.assertEqual(len(settings), 10)

    def test_full_current_palworld_settings_are_preserved_in_env_and_review(self) -> None:
        settings = import_existing.parse_option_settings(
            (FIXTURES / "current_palworld_settings.ini").read_text(encoding="utf-8")
        )

        self.assertEqual(len(settings), 119)
        self.assertEqual(settings["ExpRate"], "2.500000")
        self.assertEqual(settings["CrossplayPlatforms"], "(Steam,Xbox,PS5,Mac)")
        self.assertEqual(settings["DenyTechnologyList"], "")
        self.assertEqual(settings["BuildingNameDisplayCacheTTLSeconds"], "60")

        with tempfile.TemporaryDirectory() as directory:
            project = create_project(Path(directory))
            content, review = import_existing.build_target_env(
                project,
                "server1",
                settings,
                world_guid=GUID,
                game_port=None,
                rest_port=45112,
                rest_api_expose=True,
                community_server=False,
            )

        self.assertIn("PAL_SETTING_ExpRate=2.500000", content)
        self.assertIn(
            "PAL_SETTING_CrossplayPlatforms=raw:(Steam,Xbox,PS5,Mac)", content
        )
        self.assertIn("PAL_SETTING_DenyTechnologyList=raw:", content)
        self.assertIn("PAL_SETTING_BuildingNameDisplayCacheTTLSeconds=60", content)
        self.assertIn("PAL_SETTING_Difficulty=raw:None", content)
        self.assertIn("PAL_SETTING_DeathPenalty=raw:Item", content)
        self.assertIn("PAL_SETTING_LogFormatType=raw:Text", content)
        self.assertNotIn(import_existing.UNMAPPED_IMPORT_HEADER, content)
        self.assertNotIn("# PAL_SETTING_RandomizerSeed=", content)
        generated_env = {
            key.strip(): value.strip()
            for line in content.splitlines()
            if line.strip() and not line.lstrip().startswith("#") and "=" in line
            for key, value in [line.split("=", 1)]
        }
        # The review intentionally leaves an undetected game port BLOCKED.
        # Simulate the required UI synchronization before rendering settings.
        generated_env["PAL_SETTING_PublicPort"] = "45111"
        rendered = import_existing.manager.render_settings(
            (FIXTURES / "current_palworld_settings.ini").read_text(encoding="utf-8"),
            import_existing.manager.collect_overrides(generated_env),
        )
        self.assertIn("Difficulty=None", rendered)
        self.assertIn("DeathPenalty=Item", rendered)
        self.assertIn("LogFormatType=Text", rendered)
        self.assertIn("DenyTechnologyList=,", rendered)
        self.assertNotIn('Difficulty="None"', rendered)
        self.assertNotIn('DeathPenalty="Item"', rendered)
        self.assertNotIn('DenyTechnologyList=""', rendered)
        review_by_id = {item["id"]: item for item in review}
        self.assertEqual({item["status"] for item in review}, {"BLOCKED", "REVIEW", "AUTO"})
        self.assertEqual(review[0]["status"], "BLOCKED")
        self.assertEqual(review_by_id["rest-exposure"]["status"], "REVIEW")
        self.assertEqual(review_by_id["pal-setting-ExpRate"]["status"], "AUTO")
        self.assertEqual(
            review_by_id["pal-setting-CrossplayPlatforms"]["value"],
            "raw:(Steam,Xbox,PS5,Mac)",
        )
        auto_source_keys = {
            item["source_key"] for item in review if item["status"] == "AUTO"
        }
        self.assertTrue(
            set(settings).difference({"PublicPort", "RESTAPIPort", "RESTAPIEnabled"})
            <= auto_source_keys
        )

    def test_import_uses_current_layout_when_project_template_is_older(self) -> None:
        settings = import_existing.parse_option_settings(
            (FIXTURES / "current_palworld_settings.ini").read_text(encoding="utf-8")
        )
        previously_missing = {
            "Difficulty",
            "BuildObjectHpRate",
            "bEnablePlayerToPlayerDamage",
            "bEnableFriendlyFire",
            "bActiveUNKO",
            "bEnableAimAssistPad",
            "bEnableAimAssistKeyboard",
            "DropItemMaxNum",
            "DropItemMaxNum_UNKO",
            "DropItemAliveMaxHours",
            "WorkSpeedRate",
            "AutoSaveSpan",
            "bIsMultiplay",
            "bCanPickupOtherGuildDeathPenaltyDrop",
            "bEnableNonLoginPenalty",
            "bEnableDefenseOtherGuildPlayer",
            "CoopPlayerMaxNum",
            "Region",
            "bUseAuth",
            "BanListURL",
            "EnablePredatorBossPal",
            "PlayerDataPalStorageUpdateCheckTickInterval",
            "AutoTransferMasterCheckIntervalSeconds",
            "AutoTransferMasterThresholdDays",
            "MaxGuildsPerFrame",
            "BuildingNameDisplayCacheTTLSeconds",
        }
        with tempfile.TemporaryDirectory() as directory:
            project = create_project(Path(directory))
            template = project / "config/server.template.env"
            old_lines = []
            for line in template.read_text(encoding="utf-8").splitlines():
                if line.startswith("ACTIVE_WINDOW="):
                    old_lines.append("ACTIVE_WINDOW=18:00-02:00")
                    continue
                match = re.match(
                    r"^\s*(?:#\s*)?PAL_SETTING_([A-Za-z_][A-Za-z0-9_]*)\s*=",
                    line,
                )
                if match and match.group(1) in previously_missing:
                    continue
                old_lines.append(line)
            old_lines.extend(
                [
                    "",
                    "# Local project extension",
                    "PAL_SETTING_LocalProjectExtension=raw:Enabled",
                ]
            )
            template.write_text("\n".join(old_lines) + "\n", encoding="utf-8")

            sync = import_existing.sync_project_server_template(project)
            self.assertTrue(sync["updated"])
            self.assertTrue(Path(sync["backup"]).is_file())
            synced_template = template.read_text(encoding="utf-8")
            self.assertIn("PAL_SETTING_Difficulty=raw:None", synced_template)
            self.assertEqual(synced_template.count("ACTIVE_WINDOW=18:00-02:00"), 1)
            self.assertIn("ACTIVE_WINDOW=18:00-02:00", synced_template)
            self.assertIn(
                "PAL_SETTING_LocalProjectExtension=raw:Enabled", synced_template
            )
            self.assertFalse(
                import_existing.sync_project_server_template(project)["updated"]
            )

            content, review = import_existing.build_target_env(
                project,
                "server1",
                settings,
                world_guid=GUID,
                game_port=45111,
                rest_port=45112,
                rest_api_expose=True,
                community_server=False,
            )

        fallback = (
            content.split(import_existing.UNMAPPED_IMPORT_HEADER, 1)[1]
            if import_existing.UNMAPPED_IMPORT_HEADER in content
            else ""
        )
        for key in previously_missing:
            self.assertIn(f"PAL_SETTING_{key}=", content)
            self.assertNotIn(f"PAL_SETTING_{key}=", fallback)
        self.assertIn(import_existing.PROJECT_TEMPLATE_EXTENSION_HEADER, content)
        self.assertIn("PAL_SETTING_LocalProjectExtension=raw:Enabled", content)
        self.assertIn("ACTIVE_WINDOW=18:00-02:00", content)
        review_by_id = {item["id"]: item for item in review}
        self.assertEqual(review_by_id["pal-setting-Difficulty"]["status"], "AUTO")
        self.assertEqual(
            review_by_id["pal-setting-BuildingNameDisplayCacheTTLSeconds"]["status"],
            "AUTO",
        )

    def test_transient_source_listener_is_waited_out_after_stop(self) -> None:
        observations = {8211: iter((True, False)), 8222: iter((False, False))}

        def listener_state(port: int) -> bool:
            return next(observations[port])

        with (
            mock.patch.object(import_existing, "port_in_use", side_effect=listener_state),
            mock.patch.object(import_existing.time, "sleep") as sleep,
        ):
            busy = import_existing.wait_for_ports_released(
                (8211, 8222), timeout_seconds=30, poll_seconds=0.5
            )

        self.assertEqual(busy, [])
        sleep.assert_called_once_with(0.5)

    def test_persistent_source_listener_remains_blocking_after_timeout(self) -> None:
        with (
            mock.patch.object(import_existing, "port_in_use", return_value=True),
            mock.patch.object(import_existing.time, "monotonic", side_effect=(0.0, 30.0)),
            mock.patch.object(import_existing.time, "sleep") as sleep,
        ):
            busy = import_existing.wait_for_ports_released(
                (8211, 8222), timeout_seconds=30, poll_seconds=0.5
            )

        self.assertEqual(busy, [8211, 8222])
        sleep.assert_not_called()

    def test_process_match_requires_a_real_palserver_executable_argument(self) -> None:
        self.assertTrue(
            import_existing.is_palserver_process(
                ["/bin/bash", "/srv/palworld/PalServer.sh", "-port=8211"]
            )
        )
        self.assertTrue(
            import_existing.is_palserver_process(
                ["/srv/palworld/Pal/Binaries/Linux/PalServer-Linux-Test"]
            )
        )
        self.assertFalse(
            import_existing.is_palserver_process(
                [
                    "python3",
                    "import_existing.py",
                    "stop",
                    "--saved",
                    "/srv/PalServer/Pal/Saved",
                ]
            )
        )

    def test_rejects_managed_port_conflicts_before_import(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = create_project(root)
            (project / "config/server1.env").write_text(
                "SERVER_PORT=40100\nPAL_SETTING_RESTAPIPort=40101\n",
                encoding="utf-8",
            )
            saved = create_source(root / "legacy")

            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                result = import_existing.main(
                    [
                        "inspect",
                        "--project",
                        str(project),
                        "--saved",
                        str(saved),
                        "--world-guid",
                        GUID,
                        "--server",
                        "server2",
                        "--game-port",
                        "40100",
                        "--rest-port",
                        "40201",
                    ]
                )
            self.assertEqual(result, 0)
            review = json.loads(output.getvalue())["review"]
            review_by_id = {item["id"]: item for item in review}
            self.assertEqual(review_by_id["game-port"]["status"], "BLOCKED")
            self.assertIn("40100", review_by_id["game-port"]["reserved_values"])
            self.assertIn(
                "already assigned to server1",
                review_by_id["game-port"]["description"],
            )
            with self.assertRaisesRegex(ValueError, "already assigned to server1"):
                import_existing.validate_project_ports(project, 40100, 40201)

    def test_does_not_stop_a_stale_or_unrelated_runtime_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            saved = create_source(Path(directory) / "legacy")
            current = {
                "pid": 456,
                "type": "docker",
                "control_id": "current-palworld",
                "game_port": 8211,
                "community_server": False,
                "command": "PalServer.sh -port=8211",
            }
            with (
                mock.patch.object(import_existing, "runtime_records", return_value=[current]),
                mock.patch.object(import_existing.subprocess, "run") as run,
            ):
                result = import_existing.stop_source(saved, "docker", "stale-palworld")

            self.assertFalse(result["stopped"])
            self.assertIn("identified safely", result["message"])
            run.assert_not_called()

    def test_manual_stop_is_accepted_even_when_discovery_identity_is_stale(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            saved = create_source(Path(directory) / "legacy")
            with mock.patch.object(import_existing, "runtime_records", return_value=[]):
                result = import_existing.stop_source(
                    saved, "systemd", "palworld.service"
                )

            self.assertTrue(result["stopped"])
            self.assertEqual(result["remaining"], [])
            self.assertIn("already stopped", result["message"])

    def test_atomic_import_preserves_saved_tree_and_normalizes_world_guid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = create_project(root / "managed")
            saved = create_source(root / "legacy", windows_config=True)
            env_file = root / "generated.env"
            env_file.write_text(
                "SERVER_PORT=8211\n"
                "PAL_SETTING_RESTAPIPort=8222\n"
                "PAL_SETTING_RESTAPIEnabled=True\n"
                "REST_API_EXPOSE=true\n"
                "API_ACCESS_TOKEN=example_import_token_0123456789abcdef\n",
                encoding="utf-8",
            )
            docker_missing = subprocess.CompletedProcess([], 1, "", "")

            with (
                mock.patch.object(import_existing, "runtime_records", return_value=[]),
                mock.patch.object(import_existing, "port_in_use", return_value=False),
                mock.patch.object(import_existing.time, "sleep", return_value=None),
                mock.patch.object(import_existing.shutil, "disk_usage", return_value=shutil._ntuple_diskusage(10**9, 0, 10**9)),
                mock.patch.object(import_existing.subprocess, "run", return_value=docker_missing),
                mock.patch.object(import_existing.os, "chown", create=True),
            ):
                metadata = import_existing.import_saved(
                    project,
                    saved,
                    GUID,
                    "server1",
                    env_file,
                    8211,
                    8222,
                )

            target_saved = project / "data/server1/saved"
            self.assertTrue((target_saved / f"SaveGames/0/{GUID}/WorldOption.sav").is_file())
            self.assertTrue(
                (target_saved / f"SaveGames/0/{GUID}/backup/world/2026.07.17-02.45.46/Level.sav").is_file()
            )
            self.assertTrue((target_saved / "Logs/legacy.log").is_file())
            game_user = (target_saved / "Config/LinuxServer/GameUserSettings.ini").read_text("utf-8")
            self.assertIn(f"DedicatedServerName={GUID}", game_user)
            self.assertFalse((target_saved / "Config/WindowsServer/GameUserSettings.ini").exists())
            self.assertEqual((project / "config/server1.env").read_text("utf-8"), env_file.read_text("utf-8"))
            self.assertTrue(metadata["world_option_preserved"])
            metadata_files = list((project / "backups/server1/import").glob("*.json"))
            self.assertEqual(len(metadata_files), 1)
            self.assertEqual(json.loads(metadata_files[0].read_text("utf-8"))["world_guid"], GUID)


if __name__ == "__main__":
    unittest.main()
