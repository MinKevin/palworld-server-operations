#!/usr/bin/env python3
"""In-container CLI for the Palworld REST API and local supervisor."""

from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from common import STATUS_FILE, api_request, queue_command, read_json


def print_json(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def healthy_supervisor_status(status: object, now: float | None = None) -> bool:
    if not isinstance(status, dict):
        return False
    try:
        age = (time.time() if now is None else now) - float(status.get("updated_epoch", 0))
    except (TypeError, ValueError):
        return False
    return (
        status.get("manager") == "running"
        and status.get("game") != "update-failed"
        and not status.get("policy_error")
        and age < 180
    )


def queue_action(
    action: str,
    waittime: int | None = None,
    *,
    parameters: dict[str, Any] | None = None,
) -> None:
    queue_command(action, waittime, source="palctl", parameters=parameters)
    print(f"요청을 접수했습니다: {action}")


def format_uptime(seconds: int | float) -> str:
    seconds = int(seconds)
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    parts = []
    if days:
        parts.append(f"{days}d")
    if hours or days:
        parts.append(f"{hours}h")
    if minutes or hours or days:
        parts.append(f"{minutes}m")
    parts.append(f"{seconds}s")
    return " ".join(parts)


def show_players(as_json: bool) -> None:
    result = api_request("players")
    if as_json:
        print_json(result)
        return
    players = result.get("players", []) if isinstance(result, dict) else []
    if not players:
        print("접속 중인 플레이어가 없습니다.")
        return
    columns = ("name", "accountName", "userId", "level", "ping")
    widths = {column: len(column) for column in columns}
    for player in players:
        for column in columns:
            widths[column] = max(widths[column], len(str(player.get(column, ""))))
    print("  ".join(column.ljust(widths[column]) for column in columns))
    print("  ".join("-" * widths[column] for column in columns))
    for player in players:
        print("  ".join(str(player.get(column, "")).ljust(widths[column]) for column in columns))


def show_metrics(as_json: bool) -> None:
    result = api_request("metrics")
    if as_json:
        print_json(result)
        return
    if not isinstance(result, dict):
        print_json(result)
        return
    for key, value in result.items():
        if key == "uptime":
            value = f"{value} ({format_uptime(value)})"
        print(f"{key}: {value}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="팰월드 서버 관리 CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name, help_text in (
        ("status", "내부 관리기와 게임 프로세스 상태"),
        ("info", "공식 API 서버 정보"),
        ("settings", "현재 적용된 게임 설정"),
        ("save", "월드 즉시 저장"),
        ("start", "서버 즉시 시작 후 다음 운영 종료부터 시간표 복귀"),
        ("auto", "수동 시작/정지 해제 후 시간표로 복귀"),
        ("force-stop", "서버 강제 종료"),
    ):
        subparsers.add_parser(name, help=help_text)

    players = subparsers.add_parser("players", help="접속 플레이어 목록")
    players.add_argument("--json", action="store_true", help="표 대신 JSON 출력")

    metrics = subparsers.add_parser("metrics", help="FPS, 접속자 수, 가동 시간 등의 지표")
    metrics.add_argument("--json", action="store_true", help="항목 목록 대신 JSON 출력")

    announce = subparsers.add_parser("announce", help="전체 공지 전송")
    announce.add_argument("message")

    for name, help_text in (("kick", "플레이어 추방"), ("ban", "플레이어 차단")):
        item = subparsers.add_parser(name, help=help_text)
        item.add_argument("userid", help="players 결과의 userId")
        item.add_argument("message", nargs="?", default="", help="플레이어에게 보낼 메시지")

    unban = subparsers.add_parser("unban", help="플레이어 차단 해제")
    unban.add_argument("userid")

    stop = subparsers.add_parser("stop", help="공지·저장·정상 종료 후 다음 운영 시작까지 정지")
    stop.add_argument("--wait", type=int, default=60, help="종료 전 플레이어 대기 시간(초)")

    shutdown = subparsers.add_parser("shutdown", help="stop과 동일한 스케줄 복귀형 안전 종료")
    shutdown.add_argument("--wait", type=int, default=60, help="종료 전 플레이어 대기 시간(초)")

    safe_stop = subparsers.add_parser("safe-stop", help="공지·저장 후 REST stop, 다음 운영 시작까지 정지")
    safe_stop.add_argument("--wait", type=int, default=60, help="종료 전 플레이어 대기 시간(초)")

    restart = subparsers.add_parser("restart", help="공지·카운트다운·저장 후 서버 재시작")
    restart.add_argument("--wait", type=int, default=60, help="재시작 전 플레이어 대기 시간(초)")

    reset_stop = subparsers.add_parser("reset-stop", help=argparse.SUPPRESS)
    reset_stop.add_argument("--wait", type=int, default=60, help=argparse.SUPPRESS)

    test_start = subparsers.add_parser("test-start", help=argparse.SUPPRESS)
    test_start.add_argument("--duration", type=int, default=1800, help=argparse.SUPPRESS)
    subparsers.add_parser("test-finish", help=argparse.SUPPRESS)

    update = subparsers.add_parser("update", help="정상 저장 후 SteamCMD 업데이트 및 필요 시 재시작")
    update.add_argument(
        "--wait",
        type=int,
        default=None,
        help="업데이트 종료 전 플레이어 대기 시간(초), 기본값은 common.env 설정",
    )

    subparsers.add_parser("health", help=argparse.SUPPRESS)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    command = args.command
    try:
        if command == "status":
            status = read_json(STATUS_FILE)
            if status is None:
                raise RuntimeError("관리기 상태 파일이 아직 생성되지 않았습니다.")
            print_json(status)
        elif command == "health":
            status = read_json(STATUS_FILE)
            return 0 if healthy_supervisor_status(status) else 1
        elif command == "players":
            show_players(args.json)
        elif command == "metrics":
            show_metrics(args.json)
        elif command in {"info", "settings"}:
            print_json(api_request(command))
        elif command == "announce":
            print_json(api_request("announce", method="POST", body={"message": args.message}))
        elif command == "save":
            print_json(api_request("save", method="POST"))
        elif command in {"kick", "ban"}:
            body = {"userid": args.userid}
            if args.message:
                body["message"] = args.message
            print_json(api_request(command, method="POST", body=body))
        elif command == "unban":
            print_json(api_request("unban", method="POST", body={"userid": args.userid}))
        elif command in {"start", "auto", "force-stop"}:
            queue_action(command)
        elif command == "test-start":
            if not 60 <= args.duration <= 7200:
                raise ValueError("test-start duration must be between 60 and 7200 seconds")
            queue_action(command, parameters={"duration": args.duration})
        elif command == "test-finish":
            queue_action(command)
        elif command in {"stop", "shutdown", "safe-stop", "restart", "reset-stop"}:
            queue_action(command, args.wait)
        elif command == "update":
            queue_action(command, args.wait)
        else:
            raise RuntimeError(f"지원하지 않는 명령: {command}")
        return 0
    except (RuntimeError, OSError, ValueError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
