from __future__ import annotations

import hashlib
import hmac
import json
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import doctor  # noqa: E402
import instances  # noqa: E402


OFFICIAL_SETTINGS = {
    "BaseCampMaxNum",
    "BaseCampMaxNumInGuild",
    "BaseCampWorkerMaxNum",
    "ItemContainerForceMarkDirtyInterval",
    "MaxBuildingLimitNum",
    "PhysicsActiveDropItemMaxNum",
    "ServerReplicatePawnCullDistance",
    "AdminPassword",
    "AllowConnectPlatform",
    "bAllowClientMod",
    "bEnableBuildingPlayerUIdDisplay",
    "bIsShowJoinLeftMessage",
    "bIsUseBackupSaveData",
    "ChatPostLimitPerMinute",
    "CrossplayPlatforms",
    "LogFormatType",
    "PublicIP",
    "PublicPort",
    "RCONEnabled",
    "RCONPort",
    "RESTAPIEnabled",
    "RESTAPIPort",
    "ServerDescription",
    "ServerName",
    "ServerPassword",
    "ServerPlayerMaxNum",
    "AutoResetGuildTimeNoOnlinePlayers",
    "bAllowEnhanceStat_Attack",
    "bAllowEnhanceStat_Health",
    "bAllowEnhanceStat_Stamina",
    "bAllowEnhanceStat_Weight",
    "bAllowEnhanceStat_WorkSpeed",
    "bAllowGlobalPalboxExport",
    "bAllowGlobalPalboxImport",
    "bAutoResetGuildNoOnlinePlayers",
    "bBuildAreaLimit",
    "bCharacterRecreateInHardcore",
    "bDisplayPvPItemNumOnWorldMap_BaseCamp",
    "bDisplayPvPItemNumOnWorldMap_Player",
    "bEnableFastTravel",
    "bEnableFastTravelOnlyBaseCamp",
    "bEnableInvaderEnemy",
    "bEnableVoiceChat",
    "bExistPlayerAfterLogout",
    "bHardcore",
    "bInvisibleOtherGuildBaseCampAreaFX",
    "bIsPvP",
    "bIsRandomizerPalLevelRandom",
    "bIsStartLocationSelectByMap",
    "bShowPlayerList",
    "RandomizerSeed",
    "RandomizerType",
    "VoiceChatMaxVolumeDistance",
    "VoiceChatZeroVolumeDistance",
    "AdditionalDropItemNumWhenPlayerKillingInPvPMode",
    "AdditionalDropItemWhenPlayerKillingInPvPMode",
    "bAdditionalDropItemWhenPlayerKillingInPvPMode",
    "BlockRespawnTime",
    "bPalLost",
    "BuildObjectDamageRate",
    "BuildObjectDeteriorationDamageRate",
    "CollectionDropRate",
    "CollectionObjectHpRate",
    "CollectionObjectRespawnSpeedRate",
    "DayTimeSpeedRate",
    "DeathPenalty",
    "DenyTechnologyList",
    "EnemyDropItemRate",
    "EquipmentDurabilityDamageRate",
    "ExpRate",
    "GuildPlayerMaxNum",
    "GuildRejoinCooldownMinutes",
    "ItemCorruptionMultiplier",
    "ItemWeightRate",
    "MonsterFarmActionSpeedRate",
    "NightTimeSpeedRate",
    "PalAutoHPRegeneRate",
    "PalAutoHpRegeneRateInSleep",
    "PalCaptureRate",
    "PalDamageRateAttack",
    "PalDamageRateDefense",
    "PalEggDefaultHatchingTime",
    "PalSpawnNumRate",
    "PalStaminaDecreaceRate",
    "PalStomachDecreaceRate",
    "PlayerAutoHPRegeneRate",
    "PlayerAutoHpRegeneRateInSleep",
    "PlayerDamageRateAttack",
    "PlayerDamageRateDefense",
    "PlayerStaminaDecreaceRate",
    "PlayerStomachDecreaceRate",
    "RespawnPenaltyDurationThreshold",
    "RespawnPenaltyTimeScale",
    "SupplyDropSpan",
}

INI_COMPATIBILITY_SETTINGS = {
    "AutoSaveSpan",
    "AutoTransferMasterCheckIntervalSeconds",
    "AutoTransferMasterThresholdDays",
    "BanListURL",
    "BuildingNameDisplayCacheTTLSeconds",
    "BuildObjectHpRate",
    "CoopPlayerMaxNum",
    "Difficulty",
    "DropItemAliveMaxHours",
    "DropItemMaxNum",
    "DropItemMaxNum_UNKO",
    "EnablePredatorBossPal",
    "MaxGuildsPerFrame",
    "PlayerDataPalStorageUpdateCheckTickInterval",
    "Region",
    "WorkSpeedRate",
    "bActiveUNKO",
    "bCanPickupOtherGuildDeathPenaltyDrop",
    "bEnableAimAssistKeyboard",
    "bEnableAimAssistPad",
    "bEnableDefenseOtherGuildPlayer",
    "bEnableFriendlyFire",
    "bEnableNonLoginPenalty",
    "bEnablePlayerToPlayerDamage",
    "bIsMultiplay",
    "bUseAuth",
}


class EnvTests(unittest.TestCase):
    def test_host_verification_checks_token_header_and_hmac_proof(self) -> None:
        access_token = "test_access_token_0123456789abcdef"

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                challenge = "0" * 64
                if self.headers.get("X-Palworld-Manager-Token") != access_token:
                    self.send_error(403)
                    return
                proof = hmac.new(
                    access_token.encode("utf-8"),
                    f"palworld-docker-manager:1:{challenge}".encode("utf-8"),
                    hashlib.sha256,
                ).hexdigest()
                body = json.dumps(
                    {
                        "product": "palworld-docker-manager",
                        "protocol": 1,
                        "token_verified": True,
                        "challenge": challenge,
                        "proof": proof,
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, _format: str, *_args: object) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            valid, detail = doctor.call_host_verification_api(
                server.server_address[1], "admin", "password", access_token
            )
            self.assertTrue(valid, detail)
            invalid, _detail = doctor.call_host_verification_api(
                server.server_address[1], "admin", "password", "wrong-token"
            )
            self.assertFalse(invalid)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)

    def test_load_env_ignores_comments_and_splits_once(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "server.env"
            path.write_text("# comment\nA=one=two\nEMPTY=\n", encoding="utf-8")
            self.assertEqual(doctor.load_env(path), {"A": "one=two", "EMPTY": ""})

    def test_port_validation(self) -> None:
        self.assertEqual(doctor.parse_port("8211", "PORT"), 8211)
        with self.assertRaises(ValueError):
            doctor.parse_port("70000", "PORT")

    def test_bool_validation(self) -> None:
        self.assertTrue(doctor.parse_bool("true", "VALUE"))
        self.assertFalse(doctor.parse_bool("off", "VALUE"))
        with self.assertRaises(ValueError):
            doctor.parse_bool("perhaps", "VALUE")

    def test_duration_units(self) -> None:
        self.assertEqual(doctor.parse_duration("60s", "duration"), 60)
        self.assertEqual(doctor.parse_duration("15m", "duration"), 900)
        with self.assertRaises(ValueError):
            doctor.parse_duration("soon", "duration")

    def test_timezone_validation_accepts_utc_and_non_korean_iana_zones(self) -> None:
        self.assertEqual(doctor.validate_timezone_name("UTC", "TZ"), "UTC")
        self.assertEqual(
            doctor.validate_timezone_name("America/New_York", "TZ"),
            "America/New_York",
        )
        with self.assertRaises(ValueError):
            doctor.validate_timezone_name("../etc/localtime", "TZ")

    def test_host_check_uses_configured_utc_timezone(self) -> None:
        def fake_run(
            command: list[str], timeout: float = 20
        ) -> subprocess.CompletedProcess[str]:
            del timeout
            stdout = "UTC\n" if command[0] == "timedatectl" else "ok\n"
            return subprocess.CompletedProcess(command, 0, stdout, "")

        report = doctor.Report()
        with mock.patch.object(doctor, "run", side_effect=fake_run):
            self.assertTrue(doctor.check_host(report, "UTC"))

        self.assertEqual(report.failed, 0)
        self.assertEqual(report.passed, 3)

    def test_container_check_uses_configured_non_korean_timezone(self) -> None:
        spec = doctor.ServerSpec(
            "server1", "palworld-server1", Path("server1.env"), 8211, 8212
        )

        def fake_run(
            command: list[str], timeout: float = 20
        ) -> subprocess.CompletedProcess[str]:
            del timeout
            if command[-2:] == ["printenv", "TZ"]:
                return subprocess.CompletedProcess(command, 0, "America/New_York\n", "")
            if command[-2:] == ["date", "+%Z %z"]:
                return subprocess.CompletedProcess(command, 0, "EDT -0400\n", "")
            raise AssertionError(f"unexpected command: {command}")

        report = doctor.Report()
        with mock.patch.object(doctor, "run", side_effect=fake_run):
            self.assertTrue(
                doctor.check_container_timezone(report, spec, "America/New_York")
            )

        self.assertEqual(report.failed, 0)
        self.assertEqual(report.passed, 1)

    def test_schedule_and_server_args_are_validated_before_install(self) -> None:
        doctor.validate_active_window("14:00-02:00", "ACTIVE_WINDOW")
        doctor.validate_restart_times("04:00,16:00", "RESTART_TIMES")
        doctor.validate_server_args('-logformat=text -publicip="192.0.2.1"', "SERVER_ARGS")
        with self.assertRaises(ValueError):
            doctor.validate_active_window("25:00-02:00", "ACTIVE_WINDOW")
        with self.assertRaises(ValueError):
            doctor.validate_restart_times("04:70", "RESTART_TIMES")
        with self.assertRaises(ValueError):
            doctor.validate_server_args('-port=9000', "SERVER_ARGS")
        with self.assertRaises(ValueError):
            doctor.validate_server_args('"unterminated', "SERVER_ARGS")

    def test_repeated_game_failure_is_detected(self) -> None:
        status = {
            "manager": "running",
            "game": "crash-wait",
            "game_exit_count": 3,
            "last_exit_code": 1,
        }
        self.assertIn("반복 종료", doctor.supervisor_failure(status) or "")

    def test_update_failure_is_detected(self) -> None:
        status = {
            "manager": "running",
            "game": "update-failed",
            "reason": "SteamCMD exit 8",
        }
        self.assertIn("자동 업데이트가 실패", doctor.supervisor_failure(status) or "")

    def test_invalid_persistent_policy_is_reported_as_a_blocking_failure(self) -> None:
        status = {
            "manager": "running",
            "game": "stopped",
            "policy": "invalid",
            "policy_error": "operating policy JSON is invalid",
            "desired_running": False,
        }
        failure = doctor.supervisor_failure(status) or ""
        self.assertIn("운영 정책 파일 오류", failure)
        self.assertIn("operating policy JSON is invalid", failure)

    def test_single_game_failure_can_recover(self) -> None:
        status = {
            "manager": "running",
            "game": "crash-wait",
            "game_exit_count": 1,
            "last_exit_code": 1,
        }
        self.assertIsNone(doctor.supervisor_failure(status))

    def test_running_server_is_checked_without_temporary_start(self) -> None:
        status = {
            "game": "running",
            "policy": "auto",
            "desired_running": True,
        }
        self.assertEqual(doctor.temporary_start_action(status, after_change=False), "none")

    def test_off_window_server_is_started_temporarily(self) -> None:
        status = {
            "game": "stopped",
            "policy": "auto",
            "desired_running": False,
        }
        self.assertEqual(
            doctor.temporary_start_action(status, after_change=False),
            "automatic",
        )

    def test_manual_shutdown_requires_confirmation_only_for_test_menu(self) -> None:
        status = {
            "game": "stopped",
            "policy": "stopped",
            "desired_running": False,
        }
        self.assertEqual(
            doctor.temporary_start_action(status, after_change=False),
            "confirm",
        )
        self.assertEqual(
            doctor.temporary_start_action(status, after_change=True),
            "automatic",
        )

    def test_manual_shutdown_confirmation_has_noninteractive_policy(self) -> None:
        spec = doctor.server_spec("server1")
        self.assertTrue(doctor.confirm_manual_test_start(spec, "yes"))
        self.assertFalse(doctor.confirm_manual_test_start(spec, "no"))

    def test_manual_start_cli_policy_defaults_to_interactive(self) -> None:
        parser = doctor.build_parser()
        self.assertEqual(parser.parse_args([]).manual_start, "ask")
        self.assertEqual(
            parser.parse_args(["--manual-start", "yes"]).manual_start,
            "yes",
        )

    def test_temporary_test_restore_follows_current_schedule_boundary(self) -> None:
        self.assertTrue(
            doctor.test_session_state_restored(
                {
                    "test_session_active": False,
                    "desired_running": False,
                    "game": "stopped",
                }
            )
        )
        self.assertTrue(
            doctor.test_session_state_restored(
                {
                    "test_session_active": False,
                    "desired_running": True,
                    "game": "running",
                }
            )
        )
        self.assertFalse(
            doctor.test_session_state_restored(
                {
                    "test_session_active": False,
                    "desired_running": True,
                    "game": "stopped",
                }
            )
        )

    def test_steam_download_progress_is_summarized(self) -> None:
        logs = (
            "installing/updating Palworld dedicated server\n"
            " Update state (0x61) downloading, progress: 45.47 (2343560029 / 5154554668)\n"
        )
        progress = doctor.installation_progress(logs)
        self.assertIn("45.47%", progress)
        self.assertIn("GiB", progress)

    def test_steam_unknown_zero_progress_is_explained_as_metadata_preparation(self) -> None:
        progress = doctor.installation_progress(
            "installing/updating Palworld dedicated server\n"
            " Update state (0x3) unknown, progress: 0.00 (0 / 0)\n"
        )
        self.assertIn("메타데이터 준비", progress)
        self.assertNotIn("unknown", progress)

    def test_installation_progress_tracker_reports_and_resets_stagnation(self) -> None:
        tracker = doctor.InstallationProgressTracker()

        self.assertEqual(tracker.observe("metadata", 100.0), (0.0, True))
        self.assertEqual(tracker.observe("metadata", 280.0), (180.0, False))
        self.assertEqual(tracker.observe("downloading", 300.0), (0.0, True))

    def test_installation_runtime_diagnostics_warns_about_low_volume_space(self) -> None:
        spec = doctor.server_spec("server1")
        storage = subprocess.CompletedProcess(
            [],
            0,
            stdout=json.dumps(
                {
                    "free": 4 * 1024**3,
                    "used": 20 * 1024**3,
                    "total": 24 * 1024**3,
                }
            ),
            stderr="",
        )
        processes = subprocess.CompletedProcess(
            [],
            0,
            stdout="PID STAT ELAPSED COMMAND\n42 Sl 00:03 steamcmd\n",
            stderr="",
        )
        with mock.patch.object(doctor, "run", side_effect=[storage, processes]):
            details = doctor.installation_runtime_diagnostics(spec)

        self.assertTrue(any(level == "WARN" and "4.00 GiB" in message for level, message in details))
        self.assertTrue(any("steamcmd" in message for _level, message in details))

    def test_storage_mount_layout(self) -> None:
        spec = doctor.server_spec("server1")
        inspected = {
            "Mounts": [
                {
                    "Type": "volume",
                    "Name": "palworld-server1-server",
                    "Source": "/var/lib/docker/volumes/palworld-server1-server/_data",
                    "Destination": "/palworld/server",
                    "RW": True,
                },
                {
                    "Type": "volume",
                    "Name": "palworld-server1-steam",
                    "Source": "/var/lib/docker/volumes/palworld-server1-steam/_data",
                    "Destination": "/home/palworld/.local/share/Steam",
                    "RW": True,
                },
                {
                    "Type": "bind",
                    "Source": str(doctor.instances.saved_path("server1").resolve()),
                    "Destination": "/palworld/server/Pal/Saved",
                    "RW": True,
                },
                {
                    "Type": "bind",
                    "Source": str(doctor.instances.logs_path("server1").resolve()),
                    "Destination": "/palworld/logs",
                    "RW": True,
                },
                {
                    "Type": "bind",
                    "Source": str(doctor.instances.policy_dir("server1").resolve()),
                    "Destination": "/palworld/policy",
                    "RW": True,
                },
                {
                    "Type": "bind",
                    "Source": str(doctor.instances.update_lock_dir().resolve()),
                    "Destination": "/palworld/update-lock",
                    "RW": True,
                },
                *[
                    {
                        "Type": "bind",
                        "Source": source,
                        "Destination": destination,
                        "RW": False,
                    }
                    for source, destination in (
                        ("/proc/stat", "/host-proc-stat"),
                        ("/proc/meminfo", "/host-proc-meminfo"),
                        ("/proc/net/dev", "/host-proc-net-dev"),
                        ("/proc/net/route", "/host-proc-net-route"),
                    )
                ],
            ]
        }
        self.assertEqual(doctor.storage_mount_errors(inspected, spec), [])

    def test_storage_mount_layout_rejects_old_parent_bind(self) -> None:
        spec = doctor.server_spec("server1")
        inspected = {
            "Mounts": [
                {
                    "Type": "bind",
                    "Source": str(doctor.instances.data_path("server1").resolve()),
                    "Destination": "/palworld",
                    "RW": True,
                }
            ]
        }
        errors = doctor.storage_mount_errors(inspected, spec)
        self.assertTrue(any("shared update lock bind mount missing" in error for error in errors))
        self.assertTrue(any("named volume 누락" in error for error in errors))
        self.assertTrue(any("SteamCMD 상태 named volume 누락" in error for error in errors))
        self.assertTrue(any("Saved bind mount 누락" in error for error in errors))
        self.assertTrue(any("runtime logs bind mount 누락" in error for error in errors))
        self.assertTrue(any("운영 정책 bind mount 누락" in error for error in errors))


class ConfigurationTemplateTests(unittest.TestCase):
    def test_server_template_lists_every_known_setting(self) -> None:
        content = (ROOT / "config" / "server.template.env").read_text(encoding="utf-8")
        listed = set(re.findall(r"PAL_SETTING_([A-Za-z0-9_]+)=", content))
        self.assertEqual(listed, OFFICIAL_SETTINGS | INI_COMPATIBILITY_SETTINGS)

    def test_ini_compatibility_settings_are_marked_separately(self) -> None:
        templates = (
            (
                ROOT / "config" / "server.template.env",
                "INI 호환 · 공식 v1.0 문서 미등재",
            ),
            (
                ROOT / "config" / "en" / "server.template.env",
                "INI compatibility; not listed in the official v1.0 reference",
            ),
        )
        for path, marker in templates:
            lines = path.read_text(encoding="utf-8").splitlines()
            for index, line in enumerate(lines):
                match = re.search(r"PAL_SETTING_([A-Za-z0-9_]+)=", line)
                if not match:
                    continue
                comments: list[str] = []
                for previous in reversed(lines[:index]):
                    if not previous.strip() or not previous.lstrip().startswith("#"):
                        break
                    comments.append(previous)
                block = "\n".join(reversed(comments))
                key = match.group(1)
                if key in INI_COMPATIBILITY_SETTINGS:
                    self.assertIn(
                        marker,
                        block,
                        msg=f"Missing compatibility marker: {path}:{key}",
                    )
                else:
                    self.assertNotIn(
                        marker,
                        block,
                        msg=f"Official setting mislabeled: {path}:{key}",
                    )

    def test_each_setting_has_a_description_above_it(self) -> None:
        lines = (ROOT / "config" / "server.template.env").read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if "PAL_SETTING_" not in line or "=" not in line:
                continue
            previous = next((item.strip() for item in reversed(lines[:index]) if item.strip()), "")
            self.assertTrue(previous.startswith("#"), msg=f"Missing description: {line}")

    def test_template_ports_and_next_server_defaults_are_distinct(self) -> None:
        server1 = doctor.load_env(ROOT / "config" / "server.template.env")
        server2_game, server2_rest = instances.default_ports("server2")
        ports = {
            doctor.parse_port(server1["SERVER_PORT"], "server1 game"),
            doctor.parse_port(server1["PAL_SETTING_RESTAPIPort"], "server1 REST"),
            server2_game,
            server2_rest,
        }
        self.assertEqual(len(ports), 4)
        common = doctor.load_env(ROOT / "config" / "common.env")
        manager_port = doctor.parse_port(common["MANAGER_API_PORT"], "manager internal")
        self.assertNotIn(manager_port, ports)
        self.assertEqual(common["GAME_PORT_BASE"], "39471")
        self.assertEqual(common["REST_API_PORT_BASE"], "39472")
        self.assertEqual(common["SERVER_PORT_STEP"], "10")

    def test_korean_and_english_env_templates_keep_identical_settings(self) -> None:
        def assignments(path: Path) -> list[tuple[str, str]]:
            values = []
            for raw in path.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if line.startswith("# ") and "=" in line:
                    line = line[2:].strip()
                if re.match(r"^[A-Z][A-Za-z0-9_]*=", line):
                    values.append(tuple(line.split("=", 1)))
            return values

        for korean, english in (
            (
                assignments(ROOT / "config" / "kr" / "common.env"),
                assignments(ROOT / "config" / "en" / "common.env"),
            ),
            (
                assignments(ROOT / "config" / "kr" / "server.template.env"),
                assignments(ROOT / "config" / "en" / "server.template.env"),
            ),
        ):
            self.assertEqual([key for key, _value in korean], [key for key, _value in english])
            korean_values = {key: value for key, value in korean if not key.endswith("_MESSAGE")}
            english_values = {key: value for key, value in english if not key.endswith("_MESSAGE")}
            self.assertEqual(korean_values, english_values)
        self.assertEqual(
            (ROOT / "config" / "common.env").read_bytes(),
            (ROOT / "config" / "kr" / "common.env").read_bytes(),
        )
        self.assertEqual(
            (ROOT / "config" / "server.template.env").read_bytes(),
            (ROOT / "config" / "kr" / "server.template.env").read_bytes(),
        )

    def test_doctor_explains_port_allocation_and_external_forwarding(self) -> None:
        source = (SCRIPTS / "doctor.py").read_text(encoding="utf-8")
        self.assertIn("신규 서버 포트 할당 기준", source)
        self.assertIn("serverN은 (N-1) ×", source)
        public = doctor.external_forwarding_warning("server2", 8221, 8222, True)
        self.assertIn("server2 외부 경로 미검증", public)
        self.assertIn("game UDP 8221", public)
        self.assertIn("REST API TCP 8222", public)
        private = doctor.external_forwarding_warning("server2", 8221, 8222, False)
        self.assertIn("game UDP 8221", private)
        self.assertNotIn("REST API TCP 8222", private)


class ContainerImageTests(unittest.TestCase):
    def test_runtime_user_is_non_root(self) -> None:
        content = (ROOT / "install" / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("USER palworld:palworld", content)
        self.assertIn("HOME=/home/palworld", content)
        self.assertIn("libcurl4", content)
        self.assertIn("xdg-user-dirs", content)
        self.assertIn("RUN steamcmd +quit", content)
        self.assertLess(content.index("USER root"), content.index("USER palworld:palworld"))
        self.assertNotIn("COPY scripts/ /opt/palworld/", content)
        self.assertIn("scripts/manager.py", content)
        self.assertNotIn("scripts/cleanup.py", content)

    def test_setup_preflights_server_volume_and_saved_bind_permissions(self) -> None:
        content = (ROOT / "install" / "setup.sh").read_text(encoding="utf-8")
        helper = (ROOT / "install" / "lib.sh").read_text(encoding="utf-8")
        self.assertIn('prepare_server_data "$server"', content)
        self.assertIn('data/$server/saved', content)
        self.assertIn('server_volume="palworld-$server-server"', content)
        self.assertIn('steam_volume="palworld-$server-steam"', content)
        self.assertIn('.manager-bind-test', content)
        self.assertIn('.manager-volume-test', content)
        self.assertIn('.manager-log-test', content)
        self.assertIn('--volume "$logs_dir:/palworld/logs"', content)
        self.assertIn('.manager-policy-test', content)
        self.assertIn('--volume "$policy_dir:/palworld/policy"', content)
        self.assertIn(
            '--volume "$steam_volume:/home/palworld/.local/share/Steam"',
            content,
        )
        self.assertIn('.manager-steam-test', content)
        self.assertIn(
            'prepare_shared_update_storage "$PALWORLD_UID" "$PALWORLD_GID"', content
        )
        self.assertIn(
            'preflight_shared_update_storage "$PALWORLD_UID" "$PALWORLD_GID"', content
        )
        self.assertIn(
            'prepare_server_policy_storage "$server" "$PALWORLD_UID" "$PALWORLD_GID"',
            content,
        )
        self.assertLess(
            content.index('prepare_server_policy_storage "$server"'),
            content.index('docker rm "$container_id"'),
        )
        self.assertIn('.manager-pal-test', content)
        self.assertIn('mkdir -p /volume/Pal/Saved', content)
        build_call = content.rindex("docker build \\")
        self.assertIn("    --pull \\", content[build_call:])
        storage_preflight_call = content.rindex(
            'preflight_server_volume_space "$server"'
        )
        prepare_data_call = content.rindex('prepare_server_data "$server"')
        self.assertLess(
            content.rindex(
                'ensure_server_volume "$server"\nensure_steam_volume "$server"\necho "팰월드 서버 이미지를 빌드합니다."'
            ),
            build_call,
        )
        self.assertLess(build_call, storage_preflight_call)
        self.assertLess(storage_preflight_call, prepare_data_call)
        self.assertIn("SteamCMD 최초 설치 전에", content)
        self.assertIn("기존 컨테이너는 변경하지 않았습니다", content)
        self.assertIn(
            'PALWORLD_PROJECT_UID="$(stat -c \'%u\' -- "$PALWORLD_PROJECT_DIR")"',
            helper,
        )
        self.assertIn(
            'PALWORLD_PROJECT_GID="$(stat -c \'%g\' -- "$PALWORLD_PROJECT_DIR")"',
            helper,
        )
        self.assertIn(
            'PALWORLD_UID="$(select_palworld_runtime_id "$PALWORLD_PROJECT_UID" "${SUDO_UID:-}")"',
            helper,
        )
        self.assertIn(
            'PALWORLD_GID="$(select_palworld_runtime_id "$PALWORLD_PROJECT_GID" "${SUDO_GID:-}")"',
            helper,
        )
        self.assertIn(
            'PALWORLD_IMAGE="local/palworld-dedicated-server:uid${PALWORLD_UID}-gid${PALWORLD_GID}"',
            helper,
        )
        self.assertIn("export PALWORLD_UID PALWORLD_GID PALWORLD_IMAGE", helper)
        self.assertIn('--build-arg "PALWORLD_UID=$PALWORLD_UID"', content)
        self.assertIn('--build-arg "PALWORLD_GID=$PALWORLD_GID"', content)
        instances_source = (SCRIPTS / "instances.py").read_text(encoding="utf-8")
        reset_source = (SCRIPTS / "reset_world.py").read_text(encoding="utf-8")
        self.assertIn('os.getenv(\n    "PALWORLD_IMAGE"', instances_source)
        self.assertIn('os.getenv("PALWORLD_UID", "1000")', reset_source)
        self.assertIn('os.getenv("PALWORLD_GID", "1000")', reset_source)

    def test_shared_update_storage_rejects_unsafe_paths_and_is_preflighted(self) -> None:
        helper = (ROOT / "install" / "lib.sh").read_text(encoding="utf-8")
        manager_source = (ROOT / "install" / "manager").read_text(encoding="utf-8")

        self.assertIn('local lock_dir="$PALWORLD_RUNTIME_DIR/update-lock"', helper)
        self.assertIn('[[ -L "$PALWORLD_RUNTIME_DIR" || -L "$lock_dir"', helper)
        self.assertIn('[[ -e "$lock_file" && ! -f "$lock_file" ]]', helper)
        self.assertIn('--volume "$lock_dir:/palworld/update-lock"', helper)
        self.assertIn('.manager-update-lock-test', helper)
        self.assertIn('fcntl.LOCK_EX | fcntl.LOCK_NB', helper)
        self.assertIn(
            'prepare_shared_update_storage "$PALWORLD_UID" "$PALWORLD_GID"',
            manager_source,
        )
        self.assertIn(
            'preflight_shared_update_storage "$PALWORLD_UID" "$PALWORLD_GID"',
            manager_source,
        )

    def test_remove_deletes_current_and_legacy_server_volumes(self) -> None:
        content = (ROOT / "install" / "manager").read_text(encoding="utf-8")
        self.assertIn('server_volume="palworld-$server-server"', content)
        self.assertIn('steam_volume="palworld-$server-steam"', content)
        self.assertIn('legacy_volume="palworld-$server-data"', content)
        self.assertIn('remove_docker_volume "$server_volume"', content)
        self.assertIn('remove_docker_volume "$steam_volume"', content)
        self.assertIn('remove_docker_volume "$legacy_volume"', content)
        self.assertIn('docker volume rm "$volume"', content)
        self.assertIn('rm -rf -- "$backup_target"', content)
        self.assertIn('policy_target="$policy_root/$server"', content)
        self.assertIn('rm -rf -- "$policy_target"', content)
        self.assertIn('[[ -L "$runtime_root" || -L "$policy_root" ]]', content)
        self.assertIn("backups/server[0-9]*", content)
        self.assertIn(
            "--filter label=io.palworld.image=palworld-dedicated-server",
            content,
        )
        self.assertIn('managed_image_target="$managed_image_id"', content)

    def test_policy_storage_is_migrated_before_every_container_recreation(self) -> None:
        helper = (ROOT / "install" / "lib.sh").read_text(encoding="utf-8")
        manager_source = (ROOT / "install" / "manager").read_text(encoding="utf-8")
        common_source = (SCRIPTS / "common.py").read_text(encoding="utf-8")
        dockerfile = (ROOT / "install" / "Dockerfile").read_text(encoding="utf-8")

        self.assertIn('POLICY_FILE = Path(os.getenv("POLICY_FILE"', common_source)
        self.assertIn('docker cp "$container:/palworld/manager/policy.json"', helper)
        self.assertIn('mktemp "$policy_dir/.policy.json.migrate.XXXXXXXX"', helper)
        self.assertIn("컨테이너 재생성을 중단", helper)
        self.assertIn('scripts/policy.py', helper)
        self.assertIn('scripts/policy.py', dockerfile)
        self.assertIn('[[ -e "$policy_file" && ! -f "$policy_file" ]]', helper)
        self.assertIn('chown -R "$runtime_uid:$runtime_gid" "$policy_dir"', helper)
        self.assertIn(
            'preflight_server_policy_storage "$server" "$PALWORLD_UID" "$PALWORLD_GID"',
            manager_source,
        )
        self.assertIn("전체 서버 제거 완료", manager_source)
        self.assertIn("백업, 운영 정책, 서버 파일 볼륨", manager_source)
        token_function = manager_source[
            manager_source.index("manage_server_token()") : manager_source.index(
                "assert_root()"
            )
        ]
        self.assertLess(
            token_function.index(
                'prepare_server_policy_storage "$server" "$PALWORLD_UID" "$PALWORLD_GID"'
            ),
            token_function.index('palworld_compose up -d --no-build --force-recreate'),
        )

    def test_token_rotation_rejects_legacy_image_before_any_state_change(self) -> None:
        dockerfile = (ROOT / "install" / "Dockerfile").read_text(encoding="utf-8")
        helper = (ROOT / "install" / "lib.sh").read_text(encoding="utf-8")
        manager_source = (ROOT / "install" / "manager").read_text(encoding="utf-8")

        expected_layout = "policy-bind-v1+update-lock-v1+steam-state-v1"
        self.assertIn(f'io.palworld.runtime-layout="{expected_layout}"', dockerfile)
        self.assertIn(f'PALWORLD_RUNTIME_LAYOUT="{expected_layout}"', helper)
        self.assertIn('index .Config.Labels "io.palworld.runtime-layout"', helper)
        self.assertIn('[[ "$actual_layout" != "$PALWORLD_RUNTIME_LAYOUT" ]]', helper)
        self.assertIn("컨테이너·설정·token을 변경하지 않았습니다", helper)
        self.assertIn("Manage → 기존 서버 이미지 갱신·설정 재적용", helper)

        token_function = manager_source[
            manager_source.index("manage_server_token()") : manager_source.index(
                "assert_root()"
            )
        ]
        guard = token_function.index(
            "require_current_image_runtime_layout_for_token_rotation"
        )
        for state_change in (
            'docker exec "$container_id" palctl save',
            'instances.py" rotate-token',
            'prepare_server_policy_storage "$server"',
            "palworld_compose up -d --no-build --force-recreate",
        ):
            self.assertLess(guard, token_function.index(state_change))
        self.assertNotIn('docker stop --time 120 "$container"', manager_source)
        self.assertIn("wait_for_token_rotation_recovery", manager_source)
        self.assertIn('/v1/manager/status', manager_source)
        self.assertIn('/v1/api/info', manager_source)
        self.assertIn('/v1/manager/resources/current', manager_source)
        self.assertIn('and "policy" in status', manager_source)
        self.assertIn('isinstance(status.get("desired_running"), bool)', manager_source)
        self.assertIn('desired_running = status.get("desired_running")', manager_source)
        self.assertIn('if desired_running is True:', manager_source)
        self.assertIn('elif desired_running is False:', manager_source)
        self.assertIn('"$server" 1200 "$token"', manager_source)
        self.assertIn('expected_token = sys.stdin.read()', manager_source)
        self.assertIn('hmac.compare_digest(token, expected_token)', manager_source)
        self.assertIn("read_live_container_token", manager_source)
        self.assertIn("config/$server.env와 실행 컨테이너의 API token이 서로 다릅니다", manager_source)
        self.assertIn("inspect_container_id_or_missing", manager_source)
        self.assertIn("PALWORLD_TOKEN_STATE=rolled-back", manager_source)
        self.assertIn("PALWORLD_TOKEN_STATE=indeterminate", manager_source)

        setup_source = (ROOT / "install" / "setup.sh").read_text(encoding="utf-8")
        self.assertLess(
            setup_source.rindex("docker build \\"),
            setup_source.rindex('prepare_server_data "$server"'),
        )

    def test_manager_exposes_only_ephemeral_install_actions(self) -> None:
        content = (ROOT / "install" / "manager").read_text(encoding="utf-8")
        self.assertIn("1. Setup", content)
        self.assertIn("2. Manage", content)
        self.assertIn("3. Test", content)
        self.assertIn("4. Remove", content)
        self.assertIn("Q. Exit", content)
        self.assertIn("Q. 뒤로가기", content)
        self.assertNotIn("5. Exit", content)
        self.assertIn("서버 월드 초기화", content)
        self.assertIn("서버 월드 복원", content)
        self.assertIn("API access token 확인·재발급", content)
        self.assertIn("instances.py\" rotate-token", content)
        self.assertIn("기존 토큰은 즉시 폐기", content)
        self.assertIn("restore_world.py", content)
        self.assertNotIn("Cleanup", content)
        self.assertNotIn("cleanup_preflight", content)


if __name__ == "__main__":
    unittest.main()
