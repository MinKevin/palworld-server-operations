from __future__ import annotations

import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build_ssh_payloads  # noqa: E402
import payload_manifest  # noqa: E402


class SshPayloadTests(unittest.TestCase):
    def payload_names(self, operation: str) -> set[str]:
        payload = build_ssh_payloads.build_payload(operation)
        with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
            return set(archive.getnames())

    def test_setup_payload_uses_shared_installer_sources_without_secrets(self) -> None:
        names = self.payload_names("setup")
        self.assertIn("install/setup.sh", names)
        self.assertIn("install/scaffold.sh", names)
        self.assertIn("scaffold/config/kr/common.env", names)
        self.assertIn("scaffold/config/kr/server.template.env", names)
        self.assertIn("scaffold/config/en/common.env", names)
        self.assertIn("scaffold/config/en/server.template.env", names)
        self.assertNotIn("config/server1.env", names)
        self.assertFalse(any(name.startswith("tests/") for name in names))
        self.assertFalse(any(name.lower().endswith(".md") for name in names))

    def test_test_and_manage_payloads_are_operation_scoped(self) -> None:
        test_names = self.payload_names("test")
        self.assertIn("install/test", test_names)
        self.assertIn("install/scripts/doctor.py", test_names)
        self.assertIn("install/scripts/policy.py", test_names)
        self.assertNotIn("install/setup.sh", test_names)
        manage_names = self.payload_names("manage")
        self.assertIn("install/manager", manage_names)
        self.assertIn("install/scripts/reset_world.py", manage_names)
        self.assertIn("install/scripts/resource_metrics.py", manage_names)
        self.assertNotIn("install/setup.sh", manage_names)
        self.assertFalse(any(name.lower().endswith(".md") for name in test_names | manage_names))

    def test_test_payload_doctor_imports_are_self_contained(self) -> None:
        payload = build_ssh_payloads.build_payload("test")
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory)
            with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
                for member in archive.getmembers():
                    source = archive.extractfile(member)
                    self.assertIsNotNone(source)
                    target = destination / member.name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.read())
            result = subprocess.run(
                [sys.executable, str(destination / "install/scripts/doctor.py"), "--help"],
                cwd=destination,
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_builder_writes_hash_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            build_ssh_payloads, "OUTPUT_DIR", Path(directory)
        ):
            self.assertEqual(build_ssh_payloads.main(), 0)
            manifest = json.loads((Path(directory) / "manifest.json").read_text("utf-8"))
            self.assertEqual(set(manifest["payloads"]), {"setup", "test", "manage"})
            for operation in manifest["payloads"]:
                self.assertEqual(len(manifest["payloads"][operation]["sha256"]), 64)

    def test_unknown_operation_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            payload_manifest.ssh_operation_files("unknown")


if __name__ == "__main__":
    unittest.main()
