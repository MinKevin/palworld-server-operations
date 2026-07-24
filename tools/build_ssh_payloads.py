#!/usr/bin/env python3
"""Build deterministic, operation-scoped payloads for the Windows SSH client."""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import tarfile
from pathlib import Path

from payload_manifest import executable_mode, ssh_operation_files


PROJECT_DIR = Path(__file__).resolve().parents[1]
OUTPUT_DIR = PROJECT_DIR / "tools/windows-ssh-manager/generated"
OPERATIONS = ("setup", "test", "manage")


def build_payload(operation: str) -> bytes:
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", mtime=0) as gzip_file:
        with tarfile.open(fileobj=gzip_file, mode="w") as archive:
            for source, destination in ssh_operation_files(operation):
                content = source.read_bytes()
                info = tarfile.TarInfo(destination)
                info.size = len(content)
                info.mtime = 0
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mode = executable_mode(source)
                archive.addfile(info, io.BytesIO(content))
    return compressed.getvalue()


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, object] = {"version": 2, "payloads": {}}
    payloads = manifest["payloads"]
    assert isinstance(payloads, dict)
    for operation in OPERATIONS:
        payload = build_payload(operation)
        output = OUTPUT_DIR / f"{operation}.tar.gz"
        output.write_bytes(payload)
        operation_files = ssh_operation_files(operation)
        payloads[operation] = {
            "file": output.name,
            "size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "entries": [destination for _source, destination in operation_files],
            "sources": [
                {
                    "entry": destination,
                    "path": source.relative_to(PROJECT_DIR).as_posix(),
                    "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                }
                for source, destination in operation_files
            ],
        }
        print(output)
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
