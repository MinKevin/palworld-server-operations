#!/usr/bin/env python3
"""Interactive host client for the in-container backup and restore API."""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: KEY=VALUE 형식이 아닙니다.")
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def connection_settings(project: Path, server: str) -> tuple[str, int, str, str, str]:
    if not re.fullmatch(r"server[1-9][0-9]*", server):
        raise ValueError(f"잘못된 서버 이름: {server}")
    common = load_env(project / "config/common.env")
    instance = load_env(project / f"config/{server}.env")
    raw_port = instance.get("PAL_SETTING_RESTAPIPort", "")
    if not raw_port.isdigit() or not 1 <= int(raw_port) <= 65535:
        raise ValueError(f"{server}.PAL_SETTING_RESTAPIPort 설정을 확인하세요.")
    username = common.get("API_USERNAME", "admin")
    password = instance.get("PAL_SETTING_AdminPassword", "")
    access_token = instance.get("API_ACCESS_TOKEN", "")
    if not username or not password or not access_token:
        raise ValueError(
            f"{server} API 사용자명, 관리자 비밀번호 또는 access token이 비어 있습니다."
        )
    return "127.0.0.1", int(raw_port), username, password, access_token


def authenticated_request(
    url: str,
    username: str,
    password: str,
    access_token: str,
    *,
    body: dict[str, Any] | None = None,
) -> urllib.request.Request:
    token = base64.b64encode(f"{username}:{password}".encode("utf-8")).decode("ascii")
    payload = None if body is None else json.dumps(body).encode("utf-8")
    return urllib.request.Request(
        url,
        data=payload,
        method="GET" if payload is None else "POST",
        headers={
            "Authorization": f"Basic {token}",
            "X-Palworld-Manager-Token": access_token,
            "Accept": "application/json" if payload is None else "application/x-ndjson",
            **({"Content-Type": "application/json"} if payload is not None else {}),
        },
    )


def error_detail(error: urllib.error.HTTPError) -> str:
    raw = error.read().decode("utf-8", errors="replace")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        payload = None
    detail = payload.get("error") if isinstance(payload, dict) else raw.strip()
    return f"HTTP {error.code}: {detail or error.reason}"


def list_backups(
    base_url: str, username: str, password: str, access_token: str
) -> dict[str, Any]:
    request = authenticated_request(
        f"{base_url}/v1/manager/backups", username, password, access_token
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise RuntimeError(error_detail(error)) from error
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RuntimeError(f"백업 목록 요청 실패: {error}") from error
    if not isinstance(payload, dict) or not isinstance(payload.get("backups"), list):
        raise RuntimeError("백업 목록 응답 형식이 올바르지 않습니다.")
    return payload


def format_bytes(value: int) -> str:
    if value >= 1024**3:
        return f"{value / 1024**3:.2f} GiB"
    if value >= 1024**2:
        return f"{value / 1024**2:.1f} MiB"
    if value >= 1024:
        return f"{value / 1024:.1f} KiB"
    return f"{value} B"


def stream_restore(
    base_url: str,
    username: str,
    password: str,
    access_token: str,
    backup_name: str,
    waittime: int,
) -> bool:
    request = authenticated_request(
        f"{base_url}/v1/manager/restore",
        username,
        password,
        access_token,
        body={"backup": backup_name, "waittime": waittime},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    final_result: dict[str, Any] | None = None
    try:
        with opener.open(request, timeout=max(3600, waittime + 300)) as response:
            for raw_line in response:
                try:
                    event = json.loads(raw_line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if not isinstance(event, dict):
                    continue
                if event.get("type") == "log":
                    timestamp = event.get("timestamp", "-")
                    level = str(event.get("level", "info")).upper()
                    print(f"[{timestamp}] [{level}] {event.get('message', '')}", flush=True)
                elif event.get("type") == "result":
                    final_result = event
    except urllib.error.HTTPError as error:
        raise RuntimeError(error_detail(error)) from error
    except (urllib.error.URLError, TimeoutError) as error:
        raise RuntimeError(f"복원 연결 실패: {error}") from error
    if final_result is None:
        raise RuntimeError("복원 스트림이 최종 결과 없이 종료되었습니다. runtime.log를 확인하세요.")
    success = bool(final_result.get("success"))
    label = "완료" if success else "실패"
    print(f"복원 {label}: {final_result.get('message', 'unknown')}")
    return success


def choose_backup(payload: dict[str, Any]) -> str | None:
    backups = payload["backups"]
    print()
    print(f"월드 GUID: {payload.get('world_guid', '-')}")
    print(f"복원 가능한 시점: {len(backups)}개")
    if not backups:
        print("  복원 가능한 완료 백업 없음")
        return None
    for index, backup in enumerate(backups, 1):
        kind = "복원 전 보존" if backup.get("kind") == "pre-restore" else "자동 백업"
        print(
            f"  {index}. {backup.get('name')} "
            f"({kind}, 파일 {backup.get('file_count', 0)}개, "
            f"{format_bytes(int(backup.get('size_bytes', 0)))})"
        )
    print("  Q. 뒤로가기")
    while True:
        choice = input("복원할 시점 번호: ").strip()
        if choice.lower() == "q":
            return None
        if choice.isdigit() and 1 <= int(choice) <= len(backups):
            return str(backups[int(choice) - 1]["name"])
        print("올바른 번호 또는 Q를 입력하세요.", file=sys.stderr)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="팰월드 백업 시점 조회 및 동기식 월드 복원",
        allow_abbrev=False,
    )
    parser.add_argument(
        "--project",
        default=os.getenv("PALWORLD_PROJECT_DIR", str(Path(__file__).resolve().parents[2])),
    )
    parser.add_argument("--server", required=True)
    parser.add_argument("--wait", type=int, default=60)
    parser.add_argument(
        "--backup",
        help="restore this exact backup name instead of opening the interactive selector",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="confirm a non-interactive --backup restore",
    )
    parser.add_argument(
        "--list-json",
        action="store_true",
        help="print the available backup payload as JSON and exit",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if not 0 <= args.wait <= 3600:
        print("오류: --wait는 0~3600초여야 합니다.", file=sys.stderr)
        return 2
    try:
        project = Path(args.project).resolve()
        host, port, username, password, access_token = connection_settings(
            project, args.server
        )
        base_url = f"http://{host}:{port}"
        payload = list_backups(base_url, username, password, access_token)
        if args.list_json:
            print(json.dumps(payload, ensure_ascii=False))
            return 0
        if args.backup:
            available = {
                str(item.get("name"))
                for item in payload["backups"]
                if isinstance(item, dict) and item.get("name")
            }
            if args.backup not in available:
                raise ValueError(f"backup is not available: {args.backup}")
            selected = args.backup
        else:
            selected = choose_backup(payload)
        if selected is None:
            return 0
        print()
        print(f"선택한 백업: {selected}")
        if args.backup and not args.yes:
            raise ValueError("--backup requires --yes for a non-interactive restore")
        if not args.yes:
            confirmation = input(
                f"계속하려면 RESTORE {args.server} 입력: "
            ).strip()
            if confirmation != f"RESTORE {args.server}":
                print("복원을 취소했습니다.")
                return 0
        print("동기식 월드 복원을 시작합니다. 완료될 때까지 이 창을 닫지 마세요.")
        return (
            0
            if stream_restore(
                base_url, username, password, access_token, selected, args.wait
            )
            else 1
        )
    except (OSError, RuntimeError, ValueError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
