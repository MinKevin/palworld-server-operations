from __future__ import annotations

import sys
import tempfile
import unittest
import json
import subprocess
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "install" / "scripts"
sys.path.insert(0, str(SCRIPTS))

import instances  # noqa: E402


class NamingTests(unittest.TestCase):
    def test_smallest_missing_number_is_reused(self) -> None:
        self.assertEqual(instances.next_server_name(["server1", "server4"]), "server2")

    def test_setup_resumes_oldest_config_only_server(self) -> None:
        installed = [
            instances.InstalledServer(
                name="server1",
                container="palworld-server1",
                image="test",
                state="running",
                status="Up",
            )
        ]
        self.assertEqual(
            instances.next_setup_server_name(
                ["server1", "server2", "server4"], installed
            ),
            "server2",
        )

    def test_setup_allocates_new_number_when_every_config_is_installed(self) -> None:
        installed = [
            instances.InstalledServer(
                name="server1",
                container="palworld-server1",
                image="test",
                state="running",
                status="Up",
            )
        ]
        with patch.object(instances, "next_server_name", return_value="server2") as next_name:
            self.assertEqual(
                instances.next_setup_server_name(["server1"], installed),
                "server2",
            )
        next_name.assert_called_once_with()

    def test_reserved_config_data_and_volume_numbers_are_not_reused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "data"
            runtime = root / "runtime"
            (data / "server2").mkdir(parents=True)
            (runtime / "policy/server4").mkdir(parents=True)
            docker_result = type(
                "DockerResult",
                (),
                {"returncode": 0, "stdout": "palworld-server3-server\n"},
            )()
            with (
                patch.object(instances, "DATA_DIR", data),
                patch.object(instances, "RUNTIME_DIR", runtime),
                patch.object(instances, "configured_names", return_value=["server1"]),
                patch.object(instances, "installed_servers", return_value=[]),
                patch.object(instances, "run_docker", return_value=docker_result),
            ):
                self.assertEqual(instances.next_server_name(), "server5")

    def test_default_ports_follow_server_number(self) -> None:
        self.assertEqual(instances.default_ports("server1"), (39471, 39472))
        self.assertEqual(instances.default_ports("server3"), (39491, 39492))

    def test_custom_port_bases_and_step_follow_server_number(self) -> None:
        common = {
            "GAME_PORT_BASE": "9001",
            "REST_API_PORT_BASE": "9002",
            "SERVER_PORT_STEP": "20",
        }
        self.assertEqual(instances.default_ports("server1", common), (9001, 9002))
        self.assertEqual(instances.default_ports("server3", common), (9041, 9042))

    def test_invalid_port_generation_values_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            instances.default_ports("server1", {"SERVER_PORT_STEP": "0"})
        with self.assertRaises(ValueError):
            instances.default_ports(
                "server3",
                {
                    "GAME_PORT_BASE": "65530",
                    "REST_API_PORT_BASE": "65531",
                    "SERVER_PORT_STEP": "10",
                },
            )

    def test_server_name_validation(self) -> None:
        self.assertEqual(instances.server_number("server12"), 12)
        with self.assertRaises(ValueError):
            instances.server_number("server0")

    def test_docker_rows_are_filtered_and_sorted(self) -> None:
        rows = [
            json.dumps({"Names": "other", "Image": "other", "State": "running", "Status": "Up"}),
            json.dumps(
                {
                    "Names": "palworld-server4",
                    "Image": instances.IMAGE_NAME,
                    "State": "exited",
                    "Status": "Exited (0)",
                }
            ),
            json.dumps(
                {
                    "Names": "palworld-server1",
                    "Image": instances.IMAGE_NAME,
                    "State": "running",
                    "Status": "Up 1 minute",
                }
            ),
        ]
        servers = instances.parse_installed_servers(rows)
        self.assertEqual([server.name for server in servers], ["server1", "server4"])

    def test_manager_instance_label_is_authoritative_over_container_name(self) -> None:
        rows = [
            json.dumps(
                {
                    "Names": "palworld-compose-generated-1",
                    "Image": instances.IMAGE_NAME,
                    "State": "running",
                    "Status": "Up 1 minute",
                    "Labels": (
                        f"{instances.MANAGER_LABEL},"
                        f"{instances.INSTANCE_LABEL}=server2"
                    ),
                }
            )
        ]
        servers = instances.parse_installed_servers(rows)
        self.assertEqual([server.name for server in servers], ["server2"])
        self.assertEqual(servers[0].container, "palworld-compose-generated-1")

    def test_strict_manager_inventory_rejects_duplicate_instance_labels(self) -> None:
        rows = [
            json.dumps(
                {
                    "Names": f"container-{index}",
                    "Labels": f"{instances.INSTANCE_LABEL}=server1",
                }
            )
            for index in (1, 2)
        ]
        with self.assertRaisesRegex(ValueError, "둘 이상"):
            instances.parse_installed_servers(rows, strict=True)

    def test_installed_server_query_uses_manager_label_first(self) -> None:
        docker_result = type(
            "DockerResult",
            (),
            {"returncode": 0, "stdout": "", "stderr": ""},
        )()
        with (
            patch.object(instances, "configured_names", return_value=[]),
            patch.object(instances, "run_docker", return_value=docker_result) as run_docker,
        ):
            self.assertEqual(instances.installed_servers(), [])
        run_docker.assert_called_once_with(
            [
                "ps",
                "-a",
                "--filter",
                f"label={instances.MANAGER_LABEL}",
                "--format",
                "{{json .}}",
            ]
        )

    def test_configured_exact_name_requires_compose_ownership_as_legacy_fallback(self) -> None:
        listing = type(
            "DockerResult",
            (),
            {"returncode": 0, "stdout": "", "stderr": ""},
        )()
        inspected = type(
            "DockerResult",
            (),
            {
                "returncode": 0,
                "stdout": json.dumps(
                    [
                        {
                            "Name": "/palworld-server1",
                            "Config": {
                                "Image": instances.IMAGE_NAME,
                                "Labels": {
                                    instances.COMPOSE_WORKING_DIR_LABEL: str(
                                        instances.PROJECT_DIR
                                    )
                                },
                            },
                            "State": {"Status": "running"},
                        }
                    ]
                ),
                "stderr": "",
            },
        )()
        with (
            patch.object(instances, "configured_names", return_value=["server1"]),
            patch.object(instances, "run_docker", side_effect=[listing, inspected]) as run_docker,
        ):
            servers = instances.installed_servers(strict=True)
        self.assertEqual([server.name for server in servers], ["server1"])
        self.assertEqual(servers[0].state, "running")
        self.assertEqual(
            run_docker.call_args_list[1].args[0],
            ["container", "inspect", "palworld-server1"],
        )

    def test_missing_configured_container_is_not_reported_as_docker(self) -> None:
        listing = type(
            "DockerResult",
            (),
            {"returncode": 0, "stdout": "", "stderr": ""},
        )()
        missing = type(
            "DockerResult",
            (),
            {"returncode": 1, "stdout": "[]", "stderr": "No such object"},
        )()
        with (
            patch.object(instances, "configured_names", return_value=["server2"]),
            patch.object(instances, "run_docker", side_effect=[listing, missing]),
        ):
            self.assertEqual(instances.installed_servers(strict=True), [])

    def test_strict_listing_reports_docker_daemon_failures(self) -> None:
        failed = type(
            "DockerResult",
            (),
            {"returncode": 1, "stdout": "", "stderr": "permission denied"},
        )()
        with patch.object(instances, "run_docker", return_value=failed):
            with self.assertRaisesRegex(OSError, "permission denied"):
                instances.installed_servers(strict=True)

    def test_strict_configured_inspect_does_not_treat_daemon_failure_as_missing(self) -> None:
        listing = subprocess.CompletedProcess([], 0, "", "")
        failed = subprocess.CompletedProcess([], 1, "", "permission denied")
        with (
            patch.object(instances, "configured_names", return_value=["server1"]),
            patch.object(instances, "run_docker", side_effect=[listing, failed]),
        ):
            with self.assertRaisesRegex(OSError, "permission denied"):
                instances.installed_servers(strict=True)

    def test_project_selection_alone_never_proves_a_legacy_docker_resource(self) -> None:
        with self.assertRaisesRegex(ValueError, "강한 소유권 근거"):
            instances.docker_resource_belongs_to_project(
                labels={},
                resource="palworld-server1",
                project_dir=instances.PROJECT_DIR,
                strict=True,
            )
        with self.assertRaisesRegex(ValueError, "전역 legacy"):
            instances.assert_global_project_resource_ownership(
                labels={}, resource=instances.IMAGE_NAME, legacy_evidence=False
            )


class ConfigurationGenerationTests(unittest.TestCase):
    def test_host_port_preflight_rejects_unrelated_docker_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config_dir = Path(directory) / "config"
            config_dir.mkdir()
            (config_dir / "common.env").write_text(
                "GAME_PORT_BASE=39471\nREST_API_PORT_BASE=39472\nSERVER_PORT_STEP=10\n",
                encoding="utf-8",
            )
            (config_dir / "server1.env").write_text(
                "SERVER_PORT=39471\nPAL_SETTING_RESTAPIPort=39472\nREST_API_EXPOSE=true\n",
                encoding="utf-8",
            )
            listing = subprocess.CompletedProcess([], 0, "container-id\n", "")
            inspected = subprocess.CompletedProcess(
                [],
                0,
                json.dumps(
                    [
                        {
                            "Name": "/unrelated",
                            "State": {"Running": True},
                            "NetworkSettings": {
                                "Ports": {
                                    "8211/udp": [
                                        {"HostIp": "0.0.0.0", "HostPort": "39471"}
                                    ]
                                }
                            },
                        }
                    ]
                ),
                "",
            )
            with (
                patch.object(instances, "CONFIG_DIR", config_dir),
                patch.object(instances, "run_docker", side_effect=[listing, inspected]),
            ):
                with self.assertRaisesRegex(OSError, "unrelated"):
                    instances.preflight_host_ports("server1", bind_probe=lambda *_: None)

    def test_host_port_preflight_allows_the_current_target_and_probes_free_port(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config_dir = Path(directory) / "config"
            config_dir.mkdir()
            (config_dir / "common.env").write_text(
                "GAME_PORT_BASE=39471\nREST_API_PORT_BASE=39472\nSERVER_PORT_STEP=10\n",
                encoding="utf-8",
            )
            (config_dir / "server1.env").write_text(
                "SERVER_PORT=39471\nPAL_SETTING_RESTAPIPort=39472\nREST_API_EXPOSE=false\n",
                encoding="utf-8",
            )
            listing = subprocess.CompletedProcess([], 0, "target-id\n", "")
            inspected = subprocess.CompletedProcess(
                [],
                0,
                json.dumps(
                    [
                        {
                            "Name": "/palworld-server1",
                            "State": {"Running": True},
                            "NetworkSettings": {
                                "Ports": {
                                    "8211/udp": [
                                        {"HostIp": "0.0.0.0", "HostPort": "39471"}
                                    ]
                                }
                            },
                        }
                    ]
                ),
                "",
            )
            probes: list[tuple[str, int, str]] = []
            with (
                patch.object(instances, "CONFIG_DIR", config_dir),
                patch.object(instances, "run_docker", side_effect=[listing, inspected]),
            ):
                checked = instances.preflight_host_ports(
                    "server1", bind_probe=lambda *item: probes.append(item)
                )
            self.assertEqual(probes, [("127.0.0.1", 39472, "tcp")])
            self.assertEqual(len(checked), 2)

    def test_access_token_is_generated_preserved_and_rotated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_dir = root / "config"
            config_dir.mkdir()
            server = config_dir / "server1.env"
            server.write_text("SERVER_PORT=8211\n", encoding="utf-8")
            with patch.object(instances, "CONFIG_DIR", config_dir):
                token, created = instances.ensure_access_token("server1")
                self.assertTrue(created)
                self.assertRegex(token, r"^[A-Za-z0-9_-]{32,128}$")
                stable, created_again = instances.ensure_access_token("server1")
                self.assertFalse(created_again)
                self.assertEqual(stable, token)
                rotated = instances.rotate_access_token("server1")
                self.assertNotEqual(rotated, token)
                self.assertEqual(
                    instances.load_env(server)["API_ACCESS_TOKEN"], rotated
                )

    def test_invalid_existing_access_token_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config_dir = Path(directory) / "config"
            config_dir.mkdir()
            (config_dir / "server1.env").write_text(
                "API_ACCESS_TOKEN=too-short\n", encoding="utf-8"
            )
            with patch.object(instances, "CONFIG_DIR", config_dir):
                with self.assertRaisesRegex(ValueError, "32~128"):
                    instances.ensure_access_token("server1")

    def test_read_access_token_is_strict_and_never_mutates_a_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config_dir = Path(directory) / "config"
            config_dir.mkdir()
            server = config_dir / "server1.env"
            original = "API_ACCESS_TOKEN=CHANGE_ME\n"
            server.write_text(original, encoding="utf-8")
            with patch.object(instances, "CONFIG_DIR", config_dir):
                with self.assertRaisesRegex(ValueError, "32~128"):
                    instances.read_access_token("server1")
            self.assertEqual(server.read_text(encoding="utf-8"), original)

    def test_connection_info_reports_setup_credentials_and_ports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config_dir = Path(directory) / "config"
            config_dir.mkdir()
            (config_dir / "common.env").write_text(
                "API_USERNAME=operator\n"
                "GAME_PORT_BASE=31001\n"
                "REST_API_PORT_BASE=31002\n"
                "SERVER_PORT_STEP=10\n",
                encoding="utf-8",
            )
            (config_dir / "server2.env").write_text(
                "SERVER_PORT=31011\n"
                "PAL_SETTING_RESTAPIPort=31012\n"
                "PAL_SETTING_AdminPassword=admin-secret\n"
                f"API_ACCESS_TOKEN={'T' * 32}\n",
                encoding="utf-8",
            )
            with patch.object(instances, "CONFIG_DIR", config_dir):
                info = instances.connection_info("server2")
            self.assertEqual(info["username"], "operator")
            self.assertEqual(info["admin_password"], "admin-secret")
            self.assertEqual(info["api_access_token"], "T" * 32)
            self.assertEqual(info["game_port"], 31011)
            self.assertEqual(info["rest_api_port"], 31012)

    def test_new_config_preserves_template_rest_exposure_choice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_dir = root / "config"
            config_dir.mkdir()
            (config_dir / "common.env").write_text(
                "GAME_PORT_BASE=8211\nREST_API_PORT_BASE=8212\nSERVER_PORT_STEP=10\n",
                encoding="utf-8",
            )
            template = config_dir / "server.template.env"
            template.write_text(
                "SERVER_PORT=8211\n"
                "REST_API_EXPOSE=true\n"
                "RESTART_TIMES=04:00\n"
                "PAL_SETTING_AdminPassword=CHANGE_ME\n"
                "PAL_SETTING_RESTAPIPort=8212\n",
                encoding="utf-8",
            )
            with (
                patch.object(instances, "PROJECT_DIR", root),
                patch.object(instances, "CONFIG_DIR", config_dir),
                patch.object(instances, "TEMPLATE_FILE", template),
            ):
                path, created = instances.create_config("server2")
            self.assertTrue(created)
            self.assertIn("REST_API_EXPOSE=true", path.read_text(encoding="utf-8"))
            self.assertRegex(
                instances.load_env(path)["API_ACCESS_TOKEN"],
                r"^[A-Za-z0-9_-]{32,128}$",
            )

    def test_new_config_uses_server_volume_and_saved_bind_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_dir = root / "config"
            runtime_dir = root / "runtime"
            config_dir.mkdir()
            (config_dir / "common.env").write_text(
                "MANAGER_API_PORT=8213\n"
                "GAME_PORT_BASE=9001\n"
                "REST_API_PORT_BASE=9002\n"
                "SERVER_PORT_STEP=20\n",
                encoding="utf-8",
            )
            template = config_dir / "server.template.env"
            template.write_text(
                "SERVER_PORT=8211\n"
                "REST_API_EXPOSE=false\n"
                "RESTART_TIMES=04:00\n"
                "PAL_SETTING_ServerName=Template\n"
                "PAL_SETTING_ServerDescription=Template\n"
                "PAL_SETTING_AdminPassword=CHANGE_ME\n"
                "PAL_SETTING_RESTAPIPort=8212\n",
                encoding="utf-8",
            )
            with (
                patch.object(instances, "PROJECT_DIR", root),
                patch.object(instances, "CONFIG_DIR", config_dir),
                patch.object(instances, "DATA_DIR", root / "data"),
                patch.object(instances, "RUNTIME_DIR", runtime_dir),
                patch.object(instances, "COMPOSE_FILE", runtime_dir / "compose.yaml"),
                patch.object(instances, "TEMPLATE_FILE", template),
            ):
                path, created = instances.create_config("server3")
                self.assertTrue(created)
                content = path.read_text(encoding="utf-8")
                self.assertIn("SERVER_PORT=9041", content)
                self.assertIn("PAL_SETTING_RESTAPIPort=9042", content)
                self.assertNotIn("MANAGER_API_PORT", content)
                compose = instances.generate_compose().read_text(encoding="utf-8")
                self.assertIn(instances.yaml_string(str(root / "data" / "server3" / "saved")), compose)
                self.assertIn("target: /palworld/server/Pal/Saved", compose)
                self.assertIn(instances.yaml_string(str(root / "data" / "server3" / "logs")), compose)
                self.assertIn("target: /palworld/logs", compose)
                self.assertEqual(
                    instances.policy_dir("server3"),
                    runtime_dir / "policy" / "server3",
                )
                self.assertIn(
                    instances.yaml_string(str(runtime_dir / "policy" / "server3")), compose
                )
                self.assertIn("target: /palworld/policy", compose)
                self.assertIn('POLICY_FILE: "/palworld/policy/policy.json"', compose)
                self.assertEqual(instances.update_lock_dir(), runtime_dir / "update-lock")
                self.assertIn(instances.yaml_string(str(runtime_dir / "update-lock")), compose)
                self.assertIn("target: /palworld/update-lock", compose)
                self.assertIn(
                    'UPDATE_LOCK_FILE: "/palworld/update-lock/steam-update.lock"', compose
                )
                for source, target in (
                    ("/proc/stat", "/host-proc-stat"),
                    ("/proc/meminfo", "/host-proc-meminfo"),
                    ("/proc/net/dev", "/host-proc-net-dev"),
                    ("/proc/net/route", "/host-proc-net-route"),
                ):
                    self.assertIn(f"source: {source}", compose)
                    self.assertIn(f"target: {target}", compose)
                self.assertGreaterEqual(compose.count("read_only: true"), 4)
                self.assertIn('name: "palworld-server3-server"', compose)
                self.assertIn("target: /palworld/server", compose)
                self.assertIn('"127.0.0.1:9042:8213/tcp"', compose)
                self.assertNotIn('"127.0.0.1:9042:9042/tcp"', compose)

    def test_compose_rejects_invalid_exposure_and_duplicate_host_ports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_dir = root / "config"
            runtime_dir = root / "runtime"
            config_dir.mkdir()
            (config_dir / "common.env").write_text(
                "MANAGER_API_PORT=18080\n"
                "GAME_PORT_BASE=8211\n"
                "REST_API_PORT_BASE=8212\n"
                "SERVER_PORT_STEP=10\n",
                encoding="utf-8",
            )
            server1 = config_dir / "server1.env"
            server2 = config_dir / "server2.env"
            server1.write_text(
                "SERVER_PORT=8211\nPAL_SETTING_RESTAPIPort=8212\nREST_API_EXPOSE=invalid\n",
                encoding="utf-8",
            )
            server2.write_text(
                "SERVER_PORT=8211\nPAL_SETTING_RESTAPIPort=8222\nREST_API_EXPOSE=false\n",
                encoding="utf-8",
            )
            with (
                patch.object(instances, "PROJECT_DIR", root),
                patch.object(instances, "CONFIG_DIR", config_dir),
                patch.object(instances, "DATA_DIR", root / "data"),
                patch.object(instances, "RUNTIME_DIR", runtime_dir),
                patch.object(instances, "COMPOSE_FILE", runtime_dir / "compose.yaml"),
            ):
                with self.assertRaisesRegex(ValueError, "REST_API_EXPOSE"):
                    instances.generate_compose()
                server1.write_text(
                    "SERVER_PORT=8211\nPAL_SETTING_RESTAPIPort=8212\nREST_API_EXPOSE=false\n",
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(ValueError, "포트 충돌"):
                    instances.generate_compose()


if __name__ == "__main__":
    unittest.main()
