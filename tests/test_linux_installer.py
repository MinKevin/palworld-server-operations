from __future__ import annotations

import base64
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_linux_installer  # noqa: E402


class LinuxInstallerTests(unittest.TestCase):
    def test_payload_contains_install_tools_but_not_local_secrets_or_dev_tests(self) -> None:
        payload = build_linux_installer.build_payload()
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
            names = set(archive.getnames())
        self.assertIn("install/manager", names)
        self.assertIn("install/setup.sh", names)
        self.assertIn("install/scaffold.sh", names)
        self.assertIn("install/test", names)
        self.assertIn("install/scripts/doctor.py", names)
        self.assertIn("install/scripts/resource_metrics.py", names)
        self.assertIn("install/scripts/reset_world.py", names)
        self.assertIn("scaffold/config/kr/common.env", names)
        self.assertIn("scaffold/config/kr/server.template.env", names)
        self.assertIn("scaffold/config/en/common.env", names)
        self.assertIn("scaffold/config/en/server.template.env", names)
        self.assertIn("scaffold/LICENSE", names)
        self.assertIn("scaffold/operate/pal", names)
        self.assertFalse(any(name.lower().endswith(".md") for name in names))
        self.assertNotIn("config/server1.env", names)
        self.assertFalse(any(name.startswith("tests/") for name in names))
        self.assertFalse(any(name.endswith("cleanup.py") for name in names))

    def test_generated_run_file_is_self_extracting_and_keeps_existing_configs(self) -> None:
        self.assertEqual(build_linux_installer.main(), 0)
        content = build_linux_installer.OUTPUT_FILE.read_text(encoding="utf-8")
        header, encoded = content.split(build_linux_installer.PAYLOAD_MARKER + "\n", 1)
        self.assertTrue(header.startswith("#!/usr/bin/env bash\n"))
        self.assertIn('temporary_dir="$(mktemp -d', header)
        self.assertIn("launcher_path=", header)
        self.assertIn("trap cleanup EXIT", header)
        self.assertIn('rm -f -- "$launcher_path"', header)
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", header)
        self.assertNotIn('bash "$temporary_dir/install/scaffold.sh" "$project_dir"', header)
        self.assertIn('bash "$temporary_dir/install/manager" prepare-scaffold', header)
        self.assertIn('--language)', header)
        self.assertIn('project_dir="$launcher_dir/palworld-docker"', header)
        self.assertIn('.palworld-server-operations-project', header)
        self.assertIn('--launcher "$launcher_path"', header)
        scaffold = (ROOT / "install/scaffold.sh").read_text(encoding="utf-8")
        self.assertIn('[[ ! -e "$project_dir/config/common.env" ]]', scaffold)
        self.assertIn('"$project_dir/README.md"', scaffold)
        self.assertIn('"$project_dir/PalworldServerInstaller.run"', scaffold)
        self.assertNotIn('install -m 0644 "$scaffold_dir/$document"', scaffold)
        self.assertIn("ensure_common_default", scaffold)
        self.assertIn("PALWORLD_REFRESH_SERVER_TEMPLATE", scaffold)
        self.assertIn('backups/template', scaffold)
        self.assertIn('cmp -s -- "$server_template_source"', scaffold)
        self.assertIn("--refresh-server-template", (ROOT / "install/manager").read_text("utf-8"))
        self.assertIn("palworld-server-operations-project-v1", scaffold)
        self.assertIn("detect_host_timezone", scaffold)
        self.assertIn('install -m 0644 "$scaffold_dir/LICENSE"', scaffold)
        self.assertIn("GAME_PORT_BASE 39471", scaffold)
        self.assertIn("REST_API_PORT_BASE 39472", scaffold)
        self.assertNotIn("random_port_pair", scaffold)
        self.assertIn("SERVER_PORT_STEP 10", scaffold)
        self.assertGreater(len(base64.b64decode(encoded)), 1000)

    def test_public_repository_docs_and_secret_exclusions(self) -> None:
        content = (ROOT / "README.md").read_text(encoding="utf-8")
        korean_content = (ROOT / "README.ko.md").read_text(encoding="utf-8")
        ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
        license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        self.assertEqual(
            {path.name for path in ROOT.glob("*.md")},
            {
                "README.md",
                "README.ko.md",
                "NOTICE.md",
            },
        )
        ignored_paths = {line.strip() for line in ignore.splitlines()}
        self.assertIn("/docs/", ignored_paths)
        self.assertIn("/for-clients/", ignored_paths)
        for name in (
            "CODE_OF_CONDUCT.md",
            "CODE_SIGNING_POLICY.md",
            "CONTRIBUTING.md",
            "SECURITY.md",
        ):
            self.assertTrue((ROOT / ".github" / name).is_file())
        signing_policy = (ROOT / ".github" / "CODE_SIGNING_POLICY.md").read_text(
            encoding="utf-8"
        )
        release_workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("## Code signing policy", content)
        self.assertIn("## Code signing policy (코드 서명 정책)", korean_content)
        self.assertIn("Free code signing provided by SignPath.io", signing_policy)
        self.assertIn("certificate by SignPath Foundation", signing_policy)
        self.assertIn("uses: actions/upload-artifact@v7", release_workflow)
        self.assertIn("gh release create", release_workflow)
        for name in (
            "admin-server-api-en.png",
            "admin-server-api-ko.png",
            "admin-ssh-management-en.png",
            "admin-ssh-management-ko.png",
        ):
            self.assertTrue((ROOT / ".github" / "assets" / name).is_file())
        self.assertIn("PalworldServerInstaller.run", content)
        self.assertIn("Palworld Server Operations - Client.exe", content)
        self.assertIn("tools/build_linux_installer.py", content)
        self.assertIn("tools/windows-client/build-exe.ps1", content)
        self.assertIn("config/serverN.env", content)
        self.assertIn("SHA-256", content)
        self.assertIn("Palworld Server Operations", content)
        self.assertIn("Palworld Server Operations", korean_content)
        for action in (
            "Install and start a new server",
            "Import an existing server",
            "Update Docker image and reapply settings",
            "Reset server world",
            "Restore server world",
            "Show API token",
            "Rotate API token",
            "Edit and apply server.env",
            "Check server",
            "Remove selected server",
            "Remove all managed servers",
            "Remove all servers and the project directory",
        ):
            self.assertIn(action, content)
        self.assertIn("Use **Review Common Settings** for `common.env`", content)
        self.assertIn("`common.env`는 **공통 설정 검토**에서 변경합니다", korean_content)
        self.assertIn("The SSH Management footer polls only", content)
        self.assertIn("SSH Management 하단의 모니터링만", korean_content)
        self.assertIn("container and its management API must be running", content)
        self.assertIn("컨테이너와 관리 API는 실행 중이어야", korean_content)
        self.assertIn("one Palworld Server Operations project directory per Docker host", content)
        self.assertIn("Docker 호스트 하나에는 Palworld Server Operations 프로젝트", korean_content)
        self.assertIn("data/serverN/logs/resource-usage.sqlite3", content)
        self.assertIn("data/serverN/logs/resource-usage.sqlite3", korean_content)
        self.assertNotIn("Manage ENV", content)
        self.assertNotIn("Manage ENV", korean_content)
        self.assertNotIn("Palworld Server " + "Manager", content)
        self.assertNotIn("gitea." + "mkevin", content.lower())
        self.assertIn("GNU GENERAL PUBLIC LICENSE", license_text)
        self.assertIn("Version 3, 29 June 2007", license_text)
        for ignored_path in (
            "/config/server[0-9]*.env",
            "/data/",
            "/runtime/",
            "/backups/",
            "/docs/",
            "/for-clients/",
        ):
            self.assertIn(ignored_path, ignore)

    def test_temporary_host_python_calls_disable_bytecode_cache(self) -> None:
        for relative_path in ("install/manager", "install/setup.sh", "install/test", "install/lib.sh"):
            content = (ROOT / relative_path).read_text(encoding="utf-8")
            self.assertNotIn('python3 "$PALWORLD_', content)
            self.assertIn('python3 -B "$PALWORLD_', content)

    def test_manager_exposes_non_interactive_ssh_operations(self) -> None:
        content = (ROOT / "install/manager").read_text(encoding="utf-8")
        self.assertIn("manager update --server serverN", content)
        self.assertIn("manager restore --server serverN", content)
        self.assertIn("manager token --server serverN [--show | --rotate]", content)
        self.assertIn("manager list [--format table|json]", content)
        self.assertIn('python3 -B "$PALWORLD_INSTALL_DIR/scripts/restore_world.py"', content)

    def test_reset_and_restore_pin_project_and_single_server_before_execution(self) -> None:
        manager = (ROOT / "install/manager").read_text(encoding="utf-8")
        guard = manager[
            manager.index("parse_guarded_world_action_arguments()") : manager.index(
                "guarded_import_tool()"
            )
        ]
        self.assertIn("--project|--project=*", guard)
        self.assertIn("server_count != 1", guard)
        dispatch = manager[manager.index('if (( $# > 0 )); then') :]
        for command in ("reset", "restore"):
            section = dispatch[dispatch.index(f"        {command})") :]
            section = section[: section.index(";;")]
            self.assertIn(
                f'parse_guarded_world_action_arguments {command} "$@"', section
            )
            self.assertIn(
                'assert-server-ownership "$GUARDED_WORLD_SERVER"', section
            )
            self.assertIn('--project "$PALWORLD_PROJECT_DIR"', section)
            self.assertIn('"${GUARDED_WORLD_ARGUMENTS[@]}"', section)

        for relative_path in (
            "install/scripts/reset_world.py",
            "install/scripts/restore_world.py",
        ):
            parser_source = (ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn("allow_abbrev=False", parser_source)

    def test_setup_retries_config_only_instance_before_allocating_a_new_number(self) -> None:
        manager = (ROOT / "install/manager").read_text(encoding="utf-8")
        setup = (ROOT / "install/setup.sh").read_text(encoding="utf-8")
        library = (ROOT / "install/lib.sh").read_text(encoding="utf-8")
        self.assertIn('run_setup --next "$@"', manager)
        self.assertIn('instances.py" next-setup', setup)
        self.assertIn('PALWORLD_SETUP_SERVER=$server', setup)
        self.assertLess(
            setup.index("acquire_palworld_project_operation_lock"),
            setup.index('instances.py" next-setup'),
        )
        self.assertIn('flock -n "$PALWORLD_PROJECT_OPERATION_LOCK_FD"', library)
        self.assertIn('(^|/)\\.{1,2}(/|$)', setup)

    def test_state_changing_manager_operations_share_the_project_lock(self) -> None:
        manager = (ROOT / "install/manager").read_text(encoding="utf-8")
        setup = (ROOT / "install/setup.sh").read_text(encoding="utf-8")
        library = (ROOT / "install/lib.sh").read_text(encoding="utf-8")
        token_section = manager[
            manager.index("manage_server_token()") : manager.index("assert_root()")
        ]
        recovery_section = manager[
            manager.index("wait_for_managed_container_recovery()") : manager.index(
                "recover_token_rotation_state()"
            )
        ]
        self.assertIn("docker exec -i", recovery_section)
        self.assertIn("expected_token = sys.stdin.read()", recovery_section)
        self.assertNotIn('sys.argv[1]', recovery_section)
        self.assertGreaterEqual(
            token_section.count("acquire_palworld_project_operation_lock"), 2
        )
        for function_name in (
            "remove_servers()",
            "remove_all_managed()",
            "remove_project_directory()",
        ):
            section = manager[manager.index(function_name) :]
            section = section[: section.index("\n}")]
            self.assertIn("acquire_palworld_project_operation_lock", section)
        dispatch = manager[manager.index('if (( $# > 0 )); then') :]
        for command in ("reset)", "restore)"):
            section = dispatch[dispatch.index(command) :]
            section = section[: section.index(";;")]
            self.assertIn("acquire_palworld_project_operation_lock", section)
        test_script = (ROOT / "install/test").read_text(encoding="utf-8")
        self.assertLess(
            test_script.index("assert_palworld_host_project_owner"),
            test_script.index("acquire_palworld_project_operation_lock"),
        )
        self.assertLess(
            test_script.index("acquire_palworld_project_operation_lock"),
            test_script.index('exec python3 -B "$PALWORLD_INSTALL_DIR/scripts/doctor.py"'),
        )
        project_delete = manager[
            manager.index("remove_project_directory()") : manager.index("setup_menu()")
        ]
        self.assertNotIn('rm -rf -- "$target"', project_delete)
        self.assertIn('rmdir -- "$target"', project_delete)
        self.assertIn(".palworld-server-operations-project", manager)
        self.assertIn("/var/lib/palworld-server-operations", library)
        self.assertIn("register_palworld_host_project", setup)
        self.assertIn("release_palworld_host_project_registration", manager)

    def test_server_env_apply_uses_a_lightweight_transactional_recreate(self) -> None:
        manager = (ROOT / "install/manager").read_text(encoding="utf-8")
        section = manager[
            manager.index("apply_server_env()") : manager.index(
                "acquire_common_or_registered_project_guard()"
            )
        ]

        lock = section.index("acquire_palworld_project_operation_lock")
        validation = section.index('--config-only --server "$server"')
        compose_validation = section.index("palworld_compose config --quiet")
        port_preflight = section.index('preflight-host-ports "$server"')
        world_save = section.index('docker exec "$container_id" palctl save')
        container_stop = section.index('docker stop --time 120 "$container_id"')
        recreate = section.index(
            'palworld_compose up -d --no-build --force-recreate "$server"'
        )

        self.assertLess(lock, validation)
        self.assertLess(validation, compose_validation)
        self.assertLess(compose_validation, port_preflight)
        self.assertLess(port_preflight, world_save)
        self.assertLess(world_save, container_stop)
        self.assertLess(container_stop, recreate)
        self.assertIn("validate_server_env_backup_path", section)
        self.assertIn("wait_for_managed_container_recovery", section)
        self.assertGreaterEqual(section.count("recover_server_env_apply"), 3)
        self.assertIn("--no-start --no-build --force-recreate", section)
        self.assertNotIn("docker build", section)
        self.assertNotIn("prepare_host", section)

    def test_runtime_compose_does_not_depend_on_temporary_build_context(self) -> None:
        source = (ROOT / "install/scripts/instances.py").read_text(encoding="utf-8")
        self.assertNotIn('"    build:"', source)
        self.assertNotIn("context:", source)
        self.assertIn('"        source: /proc/stat"', source)
        self.assertIn('"        target: /host-proc-stat"', source)
        self.assertNotIn("/var/run/docker.sock", source)
        self.assertIn("io.palworld.project-dir", source)

    def test_host_tools_honor_external_project_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            config = project / "config"
            config.mkdir()
            (config / "common.env").write_text("MANAGER_API_PORT=18080\n", encoding="utf-8")
            (config / "server1.env").write_text(
                "SERVER_PORT=8211\n"
                "REST_API_EXPOSE=false\n"
                "PAL_SETTING_RESTAPIPort=8212\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["PALWORLD_PROJECT_DIR"] = str(project)
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "install/scripts/instances.py"),
                    "generate-compose",
                ],
                text=True,
                encoding="utf-8",
                errors="replace",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=environment,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            compose = (project / "runtime/compose.yaml").read_text(encoding="utf-8")
            resolved_project = project.resolve()
            self.assertIn(json.dumps(str(resolved_project / "config/server1.env")), compose)
            self.assertNotIn(json.dumps(str(ROOT / "config/server1.env")), compose)


if __name__ == "__main__":
    unittest.main()
