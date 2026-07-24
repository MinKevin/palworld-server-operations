from __future__ import annotations

import ctypes
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER_SOURCE = (
    ROOT / "tools" / "windows-client" / "source" / "PalworldServerOperationsLauncher.cs"
)
DEFAULT_ADMIN_EXE = ROOT / "windows" / "Palworld Server Operations - Admin.exe"


@unittest.skipUnless(os.name == "nt", "Windows launcher tests require Windows")
class WindowsLauncherLifetimeTests(unittest.TestCase):
    def test_launcher_starts_with_case_duplicate_path_variables(self) -> None:
        executable = Path(
            os.environ.get("PALWORLD_WINDOWS_LAUNCHER_TEST_EXE", DEFAULT_ADMIN_EXE)
        )
        self.assertTrue(executable.is_file(), f"Launcher executable is missing: {executable}")

        with tempfile.TemporaryDirectory(prefix="palworld-launcher-env-test-") as temp_dir:
            temp_path = Path(temp_dir)
            environment = os.environ.copy()
            inherited_path = environment.get("Path", environment.get("PATH", ""))
            environment["Path"] = inherited_path
            environment["PATH"] = inherited_path
            environment["PALWORLD_CLIENT_LANGUAGE"] = "en"
            environment["PALWORLD_CLIENT_TEST_MODE"] = "1"
            environment["PALWORLD_CLIENT_TEST_SETTINGS_DIR"] = str(temp_path / "settings")
            environment["PALWORLD_LAUNCHER_TEST_ERROR_FILE"] = str(
                temp_path / "launcher-error.txt"
            )

            result = subprocess.run(
                [str(executable)],
                env=environment,
                timeout=30.0,
                check=False,
            )
            detail_path = temp_path / "launcher-error.txt"
            detail = detail_path.read_text(encoding="utf-8") if detail_path.is_file() else ""
            self.assertEqual(result.returncode, 0, detail)

    def test_launcher_owns_child_powershell_lifetime(self) -> None:
        executable = Path(
            os.environ.get("PALWORLD_WINDOWS_LAUNCHER_TEST_EXE", DEFAULT_ADMIN_EXE)
        )
        self.assertTrue(executable.is_file(), f"Launcher executable is missing: {executable}")

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel32.WaitForSingleObject.restype = ctypes.c_uint32
        kernel32.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel32.TerminateProcess.restype = ctypes.c_int
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_int

        process_terminate = 0x0001
        synchronize = 0x00100000
        wait_object_0 = 0x00000000
        wait_timeout = 0x00000102

        launcher: subprocess.Popen[bytes] | None = None
        child_handle: int | None = None
        with tempfile.TemporaryDirectory(prefix="palworld-launcher-job-test-") as temp_dir:
            temp_path = Path(temp_dir)
            child_pid_path = temp_path / "child.pid"
            environment = os.environ.copy()
            environment["PALWORLD_LAUNCHER_JOB_TEST_CHILD_PID_FILE"] = str(child_pid_path)
            environment["TEMP"] = str(temp_path)
            environment["TMP"] = str(temp_path)

            try:
                launcher = subprocess.Popen(
                    [str(executable), "--test-mode", "launcher-job-hold"],
                    env=environment,
                )
                deadline = time.monotonic() + 10.0
                while not child_pid_path.is_file() and time.monotonic() < deadline:
                    if launcher.poll() is not None:
                        self.fail(
                            "Launcher exited before publishing its child PowerShell PID "
                            f"(exit code {launcher.returncode})."
                        )
                    time.sleep(0.05)
                self.assertTrue(child_pid_path.is_file(), "Child PowerShell PID was not published.")

                child_pid = int(child_pid_path.read_text(encoding="utf-8").strip())
                child_handle = kernel32.OpenProcess(
                    process_terminate | synchronize, False, child_pid
                )
                self.assertTrue(
                    child_handle,
                    f"Could not open the exact child process handle (Win32 {ctypes.get_last_error()}).",
                )
                self.assertEqual(
                    kernel32.WaitForSingleObject(child_handle, 0),
                    wait_timeout,
                    "Child PowerShell was not alive before the launcher termination test.",
                )

                launcher.terminate()
                launcher.wait(timeout=5.0)
                self.assertEqual(
                    kernel32.WaitForSingleObject(child_handle, 5000),
                    wait_object_0,
                    "Child PowerShell survived after its launcher was terminated.",
                )
            finally:
                if launcher is not None and launcher.poll() is None:
                    launcher.terminate()
                    try:
                        launcher.wait(timeout=5.0)
                    except subprocess.TimeoutExpired:
                        launcher.kill()
                        launcher.wait(timeout=5.0)
                if child_handle:
                    if kernel32.WaitForSingleObject(child_handle, 0) == wait_timeout:
                        kernel32.TerminateProcess(child_handle, 1)
                        kernel32.WaitForSingleObject(child_handle, 5000)
                    kernel32.CloseHandle(child_handle)

    def test_launcher_source_enables_kill_on_job_close(self) -> None:
        content = LAUNCHER_SOURCE.read_text(encoding="utf-8")
        self.assertIn("JobObjectLimitKillOnJobClose", content)
        self.assertIn("JobObjectLimitSilentBreakawayOk", content)
        self.assertIn("SetInformationJobObject", content)
        self.assertIn("AssignProcessToJobObject", content)


if __name__ == "__main__":
    unittest.main()
