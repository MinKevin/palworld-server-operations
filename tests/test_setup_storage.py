from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
SETUP_SOURCE = (ROOT / "install" / "setup.sh").read_text(encoding="utf-8")
FUNCTION_START = SETUP_SOURCE.index("preflight_server_volume_space()")
FUNCTION_END = SETUP_SOURCE.index("\nprepare_server_data()", FUNCTION_START)
PREFLIGHT_SOURCE = SETUP_SOURCE[FUNCTION_START:FUNCTION_END]
PREPARE_START = SETUP_SOURCE.index("prepare_server_data()")
PREPARE_END = SETUP_SOURCE.index("\nprepare_server_data \"$server\"", PREPARE_START)
PREPARE_SOURCE = SETUP_SOURCE[PREPARE_START:PREPARE_END]
LIB_SOURCE = (ROOT / "install" / "lib.sh").read_text(encoding="utf-8")
ID_FUNCTION_START = LIB_SOURCE.index("select_palworld_runtime_id()")
ID_FUNCTION_END = LIB_SOURCE.index("\n\nPALWORLD_PROJECT_UID=", ID_FUNCTION_START)
ID_FUNCTION_SOURCE = LIB_SOURCE[ID_FUNCTION_START:ID_FUNCTION_END]


def find_bash() -> str | None:
    discovered = shutil.which("bash")
    if discovered:
        return discovered
    windows_git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    return str(windows_git_bash) if windows_git_bash.is_file() else None


BASH = find_bash()


@unittest.skipUnless(BASH, "bash is required for setup storage policy tests")
class SetupStoragePreflightTests(unittest.TestCase):
    def select_runtime_id(self, project_id: str, sudo_id: str) -> str:
        script = f"""
set -u
{ID_FUNCTION_SOURCE}
select_palworld_runtime_id "$1" "$2"
"""
        result = subprocess.run(
            [str(BASH), "-s", "--", project_id, sudo_id],
            input=script,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def run_preflight(
        self, probe: str, *, docker_failure: bool = False
    ) -> subprocess.CompletedProcess[str]:
        script = f"""
set -u
PALWORLD_IMAGE=test-image
validate_server_name() {{ [[ "${{1:-}}" =~ ^server[1-9][0-9]*$ ]]; }}
docker() {{
    if [[ "${{PALWORLD_TEST_DOCKER_FAILURE:-false}}" == true ]]; then
        return 23
    fi
    printf '%s\n' "$PALWORLD_TEST_PROBE"
}}
{PREFLIGHT_SOURCE}
preflight_server_volume_space server1
"""
        environment = os.environ.copy()
        environment["PALWORLD_TEST_PROBE"] = probe
        environment["PALWORLD_TEST_DOCKER_FAILURE"] = (
            "true" if docker_failure else "false"
        )
        return subprocess.run(
            [str(BASH), "-s"],
            input=script,
            text=True,
            encoding="utf-8",
            errors="replace",
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )

    def test_fresh_install_warns_below_twelve_gib_and_continues(self) -> None:
        just_under_twelve_gib = 12 * 1024**3 - 1
        result = self.run_preflight(
            f"missing {just_under_twelve_gib} {20 * 1024**3} 12.00 20.00"
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("[WARN]", result.stdout)
        self.assertIn("12 GiB", result.stdout)
        self.assertNotIn("docker stop", PREFLIGHT_SOURCE)

    def test_existing_install_warns_below_four_or_twelve_gib_and_continues(self) -> None:
        below_floor = self.run_preflight(
            f"ready {4 * 1024**3 - 1} {20 * 1024**3} 4.00 20.00"
        )
        warned = self.run_preflight(
            f"ready {6 * 1024**3} {20 * 1024**3} 6.00 20.00"
        )

        self.assertEqual(below_floor.returncode, 0)
        self.assertIn("[WARN]", below_floor.stdout)
        self.assertIn("4 GiB", below_floor.stdout)
        self.assertEqual(warned.returncode, 0)
        self.assertIn("[WARN]", warned.stdout)
        self.assertIn("12 GiB 이상 확보", warned.stdout)

    def test_fresh_install_with_twelve_gib_passes(self) -> None:
        result = self.run_preflight(
            f"missing {12 * 1024**3} {20 * 1024**3} 12.00 20.00"
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("[PASS]", result.stdout)

    def test_probe_failure_or_malformed_result_blocks_setup(self) -> None:
        failed = self.run_preflight("", docker_failure=True)
        malformed = self.run_preflight("ready nope nope nope nope")

        self.assertEqual(failed.returncode, 1)
        self.assertIn("저장공간을 확인하지 못했습니다", failed.stderr)
        self.assertEqual(malformed.returncode, 1)
        self.assertIn("검사 결과가 잘못되었습니다", malformed.stderr)

    def test_runtime_identity_prefers_project_owner_then_sudo_caller(self) -> None:
        self.assertEqual(self.select_runtime_id("1002", "1001"), "1002")
        self.assertEqual(self.select_runtime_id("0", "1001"), "1001")
        self.assertEqual(self.select_runtime_id("0", ""), "1000")
        self.assertEqual(self.select_runtime_id("daemon", "invalid"), "1000")

    def test_running_server_is_never_stopped_after_a_silent_save_failure(self) -> None:
        self.assertIn('palctl status', PREPARE_SOURCE)
        self.assertIn('월드 저장에 실패해', PREPARE_SOURCE)
        self.assertNotIn('palctl save >/dev/null 2>&1 || true', PREPARE_SOURCE)
        self.assertIn('assert-server-ownership', PREPARE_SOURCE)
        self.assertIn('docker stop --time 120 "$container_id"', PREPARE_SOURCE)
        self.assertIn('docker rm "$container_id"', PREPARE_SOURCE)
        self.assertLess(
            PREPARE_SOURCE.index('palctl save'),
            PREPARE_SOURCE.index('docker stop --time 120'),
        )


if __name__ == "__main__":
    unittest.main()
