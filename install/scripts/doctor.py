#!/usr/bin/env python3
"""Validate the host, Docker deployment, Palworld ports, and read-only APIs."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

import instances
from policy import PolicyFileError, read_policy_file


PROJECT_DIR = Path(
    os.getenv("PALWORLD_PROJECT_DIR", str(Path(__file__).resolve().parents[2]))
).resolve()
CONFIG_DIR = PROJECT_DIR / "config"
INSTALLATION_PROGRESS_STALL_SECONDS = 180.0


@dataclass(frozen=True)
class ServerSpec:
    name: str
    container: str
    env_file: Path
    default_game_port: int
    default_rest_port: int


@dataclass
class InstallationProgressTracker:
    """Track how long the user-visible SteamCMD phase has stayed unchanged."""

    value: str = ""
    changed_at: float | None = None

    def observe(self, value: str, now: float) -> tuple[float, bool]:
        if self.changed_at is None or value != self.value:
            self.value = value
            self.changed_at = now
            return 0.0, True
        return max(0.0, now - self.changed_at), False


def server_spec(name: str) -> ServerSpec:
    game_port, rest_port = instances.default_ports(name)
    return ServerSpec(
        name, instances.container_name(name), CONFIG_DIR / f"{name}.env", game_port, rest_port
    )


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw_line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"{path}:{number}: KEY=VALUE 형식이 아닙니다.")
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ValueError(f"{path}:{number}: 잘못된 환경 변수 이름: {key!r}")
        values[key] = value.strip()
    return values


def parse_bool(value: str, name: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "y", "on"}:
        return True
    if normalized in {"0", "false", "no", "n", "off"}:
        return False
    raise ValueError(f"{name}에는 true 또는 false를 지정해야 합니다: {value!r}")


def parse_port(value: str, name: str) -> int:
    if not value.isdigit() or not 1 <= int(value) <= 65535:
        raise ValueError(f"{name}에는 1~65535 포트를 지정해야 합니다: {value!r}")
    return int(value)


def parse_duration(value: str, name: str) -> float:
    if not value.strip() or value.strip().lower() in {"0", "off", "none", "disabled"}:
        return 0.0
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*", value, re.IGNORECASE)
    if not match:
        raise ValueError(f"{name}에는 60s, 15m, 6h 같은 시간을 지정해야 합니다: {value!r}")
    multiplier = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2).lower()]
    return float(match.group(1)) * multiplier


def validate_timezone_name(value: str, name: str) -> str:
    timezone_name = value.strip()
    if (
        not timezone_name
        or not re.fullmatch(
            r"[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*", timezone_name
        )
        or any(part in {".", ".."} for part in timezone_name.split("/"))
    ):
        raise ValueError(
            f"{name}에는 UTC, Asia/Seoul, America/New_York 같은 "
            f"IANA 시간대를 지정해야 합니다: {value!r}"
        )
    return timezone_name


def parse_clock(value: str, name: str) -> int:
    match = re.fullmatch(r"\s*(\d{1,2}):(\d{2})\s*", value)
    if not match:
        raise ValueError(f"{name}에는 HH:MM 형식을 지정해야 합니다: {value!r}")
    hour, minute = int(match.group(1)), int(match.group(2))
    if hour > 23 or minute > 59:
        raise ValueError(f"{name}에는 00:00~23:59 시각을 지정해야 합니다: {value!r}")
    return hour * 60 + minute


def validate_active_window(value: str, name: str) -> None:
    if value.strip().lower() in {"always", "24h", "all"}:
        return
    parts = value.split("-", 1)
    if len(parts) != 2:
        raise ValueError(f"{name}에는 always 또는 HH:MM-HH:MM을 지정해야 합니다: {value!r}")
    parse_clock(parts[0], name)
    parse_clock(parts[1], name)


def validate_restart_times(value: str, name: str) -> None:
    if not value.strip():
        return
    for item in value.split(","):
        parse_clock(item, name)


def validate_server_args(value: str, name: str) -> None:
    try:
        arguments = shlex.split(value)
    except ValueError as error:
        raise ValueError(f"{name} 인용부호 형식 오류: {error}") from error
    for argument in arguments:
        normalized = argument.lower()
        if normalized == "-publiclobby" or normalized.startswith("-port="):
            raise ValueError(
                f"{name}에 {argument!r}를 직접 넣지 마세요. "
                "COMMUNITY_SERVER 또는 SERVER_PORT를 사용하세요."
            )


def run(command: Sequence[str], timeout: float = 20) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        cwd=PROJECT_DIR,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def call_host_rest_api(
    port: int, username: str, password: str, access_token: str, timeout: float = 10
) -> tuple[bool, str]:
    token = base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/api/info",
        headers={
            "Accept": "application/json",
            "Authorization": f"Basic {token}",
            "X-Palworld-Manager-Token": access_token,
        },
    )
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=timeout) as response:
            payload = response.read()
        if payload:
            json.loads(payload.decode("utf-8"))
        return True, ""
    except (urllib.error.URLError, json.JSONDecodeError, UnicodeDecodeError, TimeoutError) as error:
        return False, str(error)


def call_host_manager_api(
    port: int, username: str, password: str, access_token: str, timeout: float = 10
) -> tuple[bool, str]:
    token = base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/manager/status",
        headers={
            "Accept": "application/json",
            "Authorization": f"Basic {token}",
            "X-Palworld-Manager-Token": access_token,
        },
    )
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=timeout) as response:
            payload = response.read()
        status = json.loads(payload.decode("utf-8"))
        if not isinstance(status, dict) or status.get("manager") != "running":
            return False, "관리 API 상태 응답이 올바르지 않습니다."
        return True, ""
    except (urllib.error.URLError, json.JSONDecodeError, UnicodeDecodeError, TimeoutError) as error:
        return False, str(error)


def call_host_verification_api(
    port: int, username: str, password: str, access_token: str, timeout: float = 10
) -> tuple[bool, str]:
    challenge = "0" * 64
    token = base64.b64encode(f"{username}:{password}".encode()).decode("ascii")
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/manager/verify?challenge={challenge}",
        headers={
            "Accept": "application/json",
            "Authorization": f"Basic {token}",
            "X-Palworld-Manager-Token": access_token,
        },
    )
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8"))
        message = f"palworld-docker-manager:1:{challenge}".encode("utf-8")
        expected = hmac.new(
            access_token.encode("utf-8"), message, hashlib.sha256
        ).hexdigest()
        if (
            not isinstance(payload, dict)
            or payload.get("product") != "palworld-docker-manager"
            or payload.get("protocol") != 1
            or payload.get("token_verified") is not True
            or payload.get("challenge") != challenge
            or not hmac.compare_digest(str(payload.get("proof", "")), expected)
        ):
            return False, "서버·토큰 검증 응답이 올바르지 않습니다."
        return True, ""
    except (
        urllib.error.URLError,
        json.JSONDecodeError,
        UnicodeDecodeError,
        TimeoutError,
    ) as error:
        return False, str(error)


class Report:
    def __init__(self) -> None:
        self.passed = 0
        self.warnings = 0
        self.failed = 0
        self.skipped = 0

    def pass_(self, message: str) -> None:
        self.passed += 1
        print(f"[PASS] {message}")

    def warn(self, message: str) -> None:
        self.warnings += 1
        print(f"[WARN] {message}")

    def fail(self, message: str) -> None:
        self.failed += 1
        print(f"[FAIL] {message}")

    def skip(self, message: str) -> None:
        self.skipped += 1
        print(f"[SKIP] {message}")

    def summary(self, config_only: bool = False) -> int:
        print()
        print(
            f"검사 결과: PASS {self.passed}, WARN {self.warnings}, "
            f"FAIL {self.failed}, SKIP {self.skipped}"
        )
        if self.failed:
            print("문제가 발견되었습니다. 위 FAIL 항목과 컨테이너 로그를 확인하세요.")
            return 1
        if config_only:
            print("설정 검사를 통과했습니다.")
        elif self.skipped:
            print("검사 가능한 항목은 완료했습니다. 위 SKIP 항목은 서버 상태를 확인하세요.")
        else:
            print("이상이 없습니다. 서버는 현재 운영 정책에 맞는 상태로 유지됩니다.")
        return 0


def selected_specs(value: str) -> list[ServerSpec]:
    if value.strip().lower() == "all":
        names = [server.name for server in instances.installed_servers()]
        if not names:
            names = instances.configured_names()
    else:
        names = [item.strip() for item in value.split(",") if item.strip()]
    if not names:
        raise ValueError("검사할 서버가 없습니다.")
    unique: list[str] = []
    for name in names:
        instances.server_number(name)
        if name not in unique:
            unique.append(name)
    return [server_spec(name) for name in sorted(unique, key=instances.server_sort_key)]


def validate_configs(
    report: Report, specs: list[ServerSpec]
) -> tuple[dict[str, dict[str, str]], str | None]:
    common_path = CONFIG_DIR / "common.env"
    try:
        common = load_env(common_path)
    except (OSError, ValueError) as error:
        report.fail(str(error))
        common = {}

    expected_timezone: str | None = None
    try:
        expected_timezone = validate_timezone_name(
            common.get("TZ", ""), "common.env.TZ"
        )
        report.pass_(f"컨테이너 시간대 설정: TZ={expected_timezone}")
    except ValueError as error:
        report.fail(str(error))

    manager_port: int | None = None
    try:
        manager_port = parse_port(
            common.get("MANAGER_API_PORT", "18080"), "common.env.MANAGER_API_PORT"
        )
        game_port_base, rest_api_port_base, server_port_step = (
            instances.port_generation_settings(common)
        )
        bool_defaults = {
            "UPDATE_ON_START": "true",
            "VALIDATE_ON_UPDATE": "false",
            "AUTO_UPDATE_ENABLED": "true",
        }
        for key, default in bool_defaults.items():
            parse_bool(common.get(key, default), f"common.env.{key}")
        automatic_updates = parse_bool(
            common.get("AUTO_UPDATE_ENABLED", "true"), "common.env.AUTO_UPDATE_ENABLED"
        )
        check_interval = parse_duration(
            common.get("UPDATE_CHECK_INTERVAL", "15m"), "common.env.UPDATE_CHECK_INTERVAL"
        )
        retry_interval = parse_duration(
            common.get("UPDATE_RETRY_INTERVAL", "5m"), "common.env.UPDATE_RETRY_INTERVAL"
        )
        steamcmd_progress_timeout = parse_duration(
            common.get("STEAMCMD_PROGRESS_TIMEOUT", "5m"),
            "common.env.STEAMCMD_PROGRESS_TIMEOUT",
        )
        warning_seconds = parse_duration(
            common.get("UPDATE_WARNING_SECONDS", "60s"), "common.env.UPDATE_WARNING_SECONDS"
        )
        restart_warning_seconds = parse_duration(
            common.get("RESTART_WARNING_SECONDS", "60s"), "common.env.RESTART_WARNING_SECONDS"
        )
        shutdown_warning_seconds = parse_duration(
            common.get("SHUTDOWN_WARNING_SECONDS", "60s"), "common.env.SHUTDOWN_WARNING_SECONDS"
        )
        parse_duration(common.get("CRASH_RESTART_DELAY", "10s"), "common.env.CRASH_RESTART_DELAY")
        shutdown_wait = parse_duration(
            common.get("SHUTDOWN_WAIT", "30s"), "common.env.SHUTDOWN_WAIT"
        )
        if shutdown_wait < 0:
            raise ValueError("common.env.SHUTDOWN_WAIT에는 0 이상의 시간을 지정해야 합니다.")
        api_username = common.get("API_USERNAME", "admin")
        if not api_username or ":" in api_username:
            raise ValueError("common.env.API_USERNAME은 비어 있지 않고 ':'를 포함하지 않아야 합니다.")
        for key, default in (("RUNTIME_LOG_MAX_SIZE_MB", "20"), ("RUNTIME_LOG_BACKUP_COUNT", "5")):
            value = common.get(key, default)
            if not value.isdigit() or int(value) < 1:
                raise ValueError(f"common.env.{key}에는 1 이상의 정수를 지정해야 합니다.")
        if check_interval < 60 or retry_interval < 60 or steamcmd_progress_timeout < 60:
            raise ValueError(
                "업데이트 확인·재시도 주기와 SteamCMD 진행 정체 제한은 각각 60초 이상이어야 합니다."
            )
        if (
            warning_seconds < 0
            or restart_warning_seconds < 0
            or shutdown_warning_seconds < 0
            or not common.get("UPDATE_WARNING_MESSAGE", "업데이트를 위해 {time} 뒤 서버가 재시작됩니다.").strip()
            or not common.get("RESTART_WARNING_MESSAGE", "{time} 뒤 서버가 재시작됩니다.").strip()
            or not common.get("RESTART_COUNTDOWN_MESSAGE", "서버 재시작까지 {seconds}초").strip()
            or not common.get("SHUTDOWN_WARNING_MESSAGE", "{time} 뒤 서버가 종료됩니다.").strip()
            or not common.get("SHUTDOWN_COUNTDOWN_MESSAGE", "서버 종료까지 {seconds}초").strip()
        ):
            raise ValueError("업데이트·재시작·안전 종료 안내 시간과 메시지를 확인하세요.")
        report.pass_(
            "운영 중 자동 업데이트 설정: "
            + (f"확인 {check_interval:g}초, 안내 {warning_seconds:g}초" if automatic_updates else "비활성화")
        )
        report.pass_(
            "신규 서버 포트 할당 기준: "
            f"game base {game_port_base}, REST API base {rest_api_port_base}; "
            f"serverN은 (N-1) × {server_port_step} 추가"
        )
    except ValueError as error:
        report.fail(str(error))

    configs: dict[str, dict[str, str]] = {}
    for spec in specs:
        try:
            env = load_env(spec.env_file)
            configs[spec.name] = env
        except (OSError, ValueError) as error:
            report.fail(str(error))
            continue

        try:
            mode = stat.S_IMODE(spec.env_file.stat().st_mode)
            if mode & 0o077:
                report.fail(
                    f"{spec.name}: config/{spec.name}.env 권한은 0600이어야 합니다: "
                    f"현재 {mode:04o}"
                )
            else:
                report.pass_(f"{spec.name} server env 권한: {mode:04o}")
        except OSError as error:
            report.fail(f"{spec.name} server env 권한 확인 실패: {error}")

        try:
            game_port = parse_port(env.get("SERVER_PORT", ""), f"{spec.name}.SERVER_PORT")
            rest_port = parse_port(
                env.get("PAL_SETTING_RESTAPIPort", ""), f"{spec.name}.PAL_SETTING_RESTAPIPort"
            )
            expose = parse_bool(env.get("REST_API_EXPOSE", ""), f"{spec.name}.REST_API_EXPOSE")
            parse_bool(env.get("COMMUNITY_SERVER", "false"), f"{spec.name}.COMMUNITY_SERVER")
            validate_active_window(env.get("ACTIVE_WINDOW", "always"), f"{spec.name}.ACTIVE_WINDOW")
            validate_restart_times(env.get("RESTART_TIMES", ""), f"{spec.name}.RESTART_TIMES")
            validate_server_args(env.get("SERVER_ARGS", ""), f"{spec.name}.SERVER_ARGS")
            if manager_port is None:
                raise ValueError("common.env.MANAGER_API_PORT 설정을 확인하세요.")
            if rest_port == manager_port:
                raise ValueError(
                    f"{spec.name}: PAL_SETTING_RESTAPIPort와 컨테이너 내부 "
                    "MANAGER_API_PORT는 달라야 합니다."
                )
        except ValueError as error:
            report.fail(str(error))
            continue

        report.pass_(f"{spec.name} 포트 설정: game UDP {game_port}, 통합 API TCP {rest_port}")

        try:
            api_enabled = parse_bool(
                env.get("PAL_SETTING_RESTAPIEnabled", ""), f"{spec.name}.PAL_SETTING_RESTAPIEnabled"
            )
        except ValueError as error:
            report.fail(str(error))
            api_enabled = False
        if api_enabled:
            report.pass_(f"{spec.name} REST API 활성화")
        else:
            report.fail(f"{spec.name}: 관리 명령과 테스트를 위해 RESTAPIEnabled=True가 필요합니다.")

        if expose:
            report.warn(
                f"{spec.name} 공식 REST·Linux 관리 API가 외부에 공개됩니다. "
                "인터넷에 직접 노출하지 말고 방화벽/VPN/TLS를 사용하세요."
            )
        else:
            report.pass_(f"{spec.name} 통합 API 외부 비공개(127.0.0.1 전용)")

        password = env.get("PAL_SETTING_AdminPassword", "")
        if len(password) < 12 or "CHANGE_ME" in password.upper():
            report.fail(f"{spec.name}: AdminPassword를 12자 이상의 고유한 값으로 변경하세요.")
        else:
            report.pass_(f"{spec.name} 관리자 비밀번호 기본 검사")

        try:
            instances.validate_access_token(
                env.get("API_ACCESS_TOKEN", ""), f"{spec.name}.API_ACCESS_TOKEN"
            )
            report.pass_(f"{spec.name} API access token 형식·길이")
        except ValueError as error:
            report.fail(str(error))

        if "RESTART_INTERVAL" in env:
            report.warn(f"{spec.name}: 더 이상 사용하지 않는 RESTART_INTERVAL 설정을 제거하세요.")

    return configs, expected_timezone


def validate_configured_port_conflicts(report: Report) -> None:
    claimed: dict[tuple[int, str], str] = {}
    for name in instances.configured_names():
        try:
            env = load_env(CONFIG_DIR / f"{name}.env")
            game_port = parse_port(env.get("SERVER_PORT", ""), f"{name}.SERVER_PORT")
            rest_port = parse_port(env.get("PAL_SETTING_RESTAPIPort", ""), f"{name}.PAL_SETTING_RESTAPIPort")
        except (OSError, ValueError) as error:
            report.fail(f"전체 포트 검사 실패: {error}")
            continue
        for port, protocol, label in (
            (game_port, "udp", f"{name} game"),
            (rest_port, "tcp", f"{name} integrated API"),
        ):
            key = (port, protocol)
            if key in claimed:
                report.fail(f"포트 충돌: {label}과 {claimed[key]}가 모두 {port}/{protocol}를 사용합니다.")
            else:
                claimed[key] = label


def check_host(report: Report, expected_timezone: str) -> bool:
    timezone_name = ""
    timezone_error = ""
    try:
        timezone = run(["timedatectl", "show", "--property=Timezone", "--value"])
        if timezone.returncode == 0:
            timezone_name = timezone.stdout.strip()
        else:
            timezone_error = timezone.stderr.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired) as error:
        timezone_error = str(error)
    if not timezone_name:
        try:
            timezone_name = Path("/etc/timezone").read_text(encoding="utf-8").strip()
        except OSError:
            pass

    if timezone_name == expected_timezone:
        report.pass_(f"호스트 시간대: {expected_timezone}")
    else:
        report.fail(
            f"호스트 시간대가 common.env의 TZ={expected_timezone}와 다릅니다: "
            f"{timezone_name or timezone_error or 'unknown'}"
        )

    for command, label in ((["docker", "version"], "Docker Engine"), (["docker", "compose", "version"], "Compose")):
        try:
            result = run(command)
        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            report.fail(f"{label} 실행 실패: {error}")
            return False
        if result.returncode == 0:
            report.pass_(f"{label} 사용 가능")
        else:
            report.fail(f"{label} 실행 실패: {result.stderr.strip()}")
            return False
    return True


def inspect_container(spec: ServerSpec) -> tuple[dict[str, object] | None, str]:
    result = run(["docker", "inspect", spec.container])
    if result.returncode != 0:
        return None, result.stderr.strip()
    try:
        values = json.loads(result.stdout)
        return values[0], ""
    except (json.JSONDecodeError, IndexError, TypeError) as error:
        return None, str(error)


def storage_mount_errors(inspected: dict[str, object], spec: ServerSpec) -> list[str]:
    mounts = inspected.get("Mounts", [])
    if not isinstance(mounts, list):
        return ["Docker inspect Mounts 형식 오류"]

    by_destination = {
        str(mount.get("Destination", "")): mount
        for mount in mounts
        if isinstance(mount, dict)
    }
    errors: list[str] = []

    server_mount = by_destination.get("/palworld/server")
    expected_volume = instances.server_volume_name(spec.name)
    if not server_mount:
        errors.append("/palworld/server named volume 누락")
    elif server_mount.get("Type") != "volume" or server_mount.get("Name") != expected_volume:
        errors.append(f"서버 파일 볼륨 불일치: {server_mount}")
    elif server_mount.get("RW") is not True:
        errors.append("서버 파일 볼륨이 읽기 전용")

    steam_mount = by_destination.get("/home/palworld/.local/share/Steam")
    expected_steam_volume = instances.steam_volume_name(spec.name)
    if not steam_mount:
        errors.append("SteamCMD 상태 named volume 누락")
    elif (
        steam_mount.get("Type") != "volume"
        or steam_mount.get("Name") != expected_steam_volume
    ):
        errors.append(f"SteamCMD 상태 볼륨 불일치: {steam_mount}")
    elif steam_mount.get("RW") is not True:
        errors.append("SteamCMD 상태 볼륨이 읽기 전용")

    saved_mount = by_destination.get("/palworld/server/Pal/Saved")
    expected_saved = str(instances.saved_path(spec.name).resolve())
    if not saved_mount:
        errors.append("Pal/Saved bind mount 누락")
    elif saved_mount.get("Type") != "bind" or str(saved_mount.get("Source", "")) != expected_saved:
        errors.append(f"Saved bind 경로 불일치: {saved_mount}")
    elif saved_mount.get("RW") is not True:
        errors.append("Saved bind mount가 읽기 전용")

    logs_mount = by_destination.get("/palworld/logs")
    expected_logs = str(instances.logs_path(spec.name).resolve())
    if not logs_mount:
        errors.append("runtime logs bind mount 누락")
    elif logs_mount.get("Type") != "bind" or str(logs_mount.get("Source", "")) != expected_logs:
        errors.append(f"runtime logs bind 경로 불일치: {logs_mount}")
    elif logs_mount.get("RW") is not True:
        errors.append("runtime logs bind mount가 읽기 전용")

    policy_mount = by_destination.get("/palworld/policy")
    expected_policy = str(instances.policy_dir(spec.name).resolve())
    if not policy_mount:
        errors.append("운영 정책 bind mount 누락")
    elif (
        policy_mount.get("Type") != "bind"
        or str(policy_mount.get("Source", "")) != expected_policy
    ):
        errors.append(f"운영 정책 bind 경로 불일치: {policy_mount}")
    elif policy_mount.get("RW") is not True:
        errors.append("운영 정책 bind mount가 읽기 전용")
    update_lock_mount = by_destination.get("/palworld/update-lock")
    expected_update_lock = str(instances.update_lock_dir().resolve())
    if not update_lock_mount:
        errors.append("shared update lock bind mount missing")
    elif (
        update_lock_mount.get("Type") != "bind"
        or str(update_lock_mount.get("Source", "")) != expected_update_lock
    ):
        errors.append(f"shared update lock bind path mismatch: {update_lock_mount}")
    elif update_lock_mount.get("RW") is not True:
        errors.append("shared update lock bind mount is read-only")

    for source, destination in (
        ("/proc/stat", "/host-proc-stat"),
        ("/proc/meminfo", "/host-proc-meminfo"),
        ("/proc/net/dev", "/host-proc-net-dev"),
        ("/proc/net/route", "/host-proc-net-route"),
    ):
        metric_mount = by_destination.get(destination)
        if not metric_mount:
            errors.append(f"resource metrics bind mount 누락: {destination}")
        elif metric_mount.get("Type") != "bind" or str(metric_mount.get("Source", "")) != source:
            errors.append(f"resource metrics bind 경로 불일치: {metric_mount}")
        elif metric_mount.get("RW") is not False:
            errors.append(f"resource metrics bind mount가 쓰기 가능: {destination}")
    return errors


def container_log_tail(spec: ServerSpec, lines: int = 40) -> str:
    result = run(["docker", "logs", "--tail", str(lines), spec.container])
    output = "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())
    return output or "최근 컨테이너 로그 없음"


def with_recent_logs(spec: ServerSpec, message: str) -> str:
    return f"{message}\n최근 컨테이너 로그:\n{container_log_tail(spec)}"


def format_bytes(value: int) -> str:
    if value >= 1024**3:
        return f"{value / 1024**3:.2f} GiB"
    if value >= 1024**2:
        return f"{value / 1024**2:.1f} MiB"
    return f"{value / 1024:.1f} KiB"


def installation_progress(logs: str) -> str:
    marker = logs.rfind("installing/updating Palworld dedicated server")
    current = logs[marker:] if marker >= 0 else logs
    if "REST API started" in current:
        return "REST API 시작 완료"
    if "starting game server" in current:
        return "게임 서버 시작 및 REST API 준비 중"
    if "Success! App '2394010' fully installed." in current:
        return "팰월드 서버 파일 설치 완료, 설정 생성 대기"

    updates = list(
        re.finditer(
            r"Update state \([^)]*\) ([^,]+), progress: ([0-9.]+) \(([0-9]+) / ([0-9]+)\)",
            current,
        )
    )
    if updates:
        match = updates[-1]
        stage = match.group(1).strip()
        progress = float(match.group(2))
        downloaded = int(match.group(3))
        total = int(match.group(4))
        if stage.lower() in {"unknown", "reconfiguring"} and progress == 0 and total == 0:
            return "SteamCMD 다운로드 메타데이터 준비 중 · 전송량 미확정"
        stage_text = {
            "downloading": "팰월드 서버 다운로드",
            "verifying update": "팰월드 서버 파일 검증",
            "committing": "팰월드 서버 파일 적용",
        }.get(stage, f"SteamCMD {stage}")
        size = f" · {format_bytes(downloaded)} / {format_bytes(total)}" if total else ""
        return f"{stage_text} {progress:.2f}%{size}"

    bootstrap = list(re.finditer(r"\[\s*([0-9]{1,3})%\]\s+([^\n]+)", current))
    if bootstrap:
        match = bootstrap[-1]
        return f"SteamCMD 자체 업데이트 {int(match.group(1))}% · {match.group(2).strip()}"
    for phrase, message in (
        ("Extracting package", "SteamCMD 자체 업데이트 압축 해제 중"),
        ("Installing update", "SteamCMD 자체 업데이트 설치 중"),
        ("Connecting anonymously", "Steam 서버 익명 로그인 중"),
        ("Waiting for user info", "Steam 사용자 정보 대기 중"),
    ):
        if phrase in current:
            return message
    return "컨테이너 및 SteamCMD 초기화 중"


def installation_runtime_diagnostics(spec: ServerSpec) -> list[tuple[str, str]]:
    """Collect bounded, read-only details for a stalled first installation."""
    details: list[tuple[str, str]] = []
    storage = run(
        [
            "docker",
            "exec",
            spec.container,
            "python3",
            "-c",
            (
                "import json,shutil; "
                "s=shutil.disk_usage('/palworld/server'); "
                "print(json.dumps({'free':s.free,'used':s.used,'total':s.total}))"
            ),
        ],
        timeout=10,
    )
    if storage.returncode == 0:
        try:
            values = json.loads(storage.stdout)
            free = int(values["free"])
            used = int(values["used"])
            total = int(values["total"])
            level = "WARN" if free < 12 * 1024**3 else "INFO"
            suffix = (
                " · 최초 설치에 부족할 수 있으므로 Docker 저장공간을 정리하거나 확장하세요."
                if level == "WARN"
                else ""
            )
            details.append(
                (
                    level,
                    f"{spec.name} 게임 파일 volume 저장공간: "
                    f"사용 {format_bytes(used)}, 사용 가능 {format_bytes(free)}, "
                    f"전체 {format_bytes(total)}{suffix}",
                )
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            pass

    processes = run(
        ["docker", "top", spec.container, "-eo", "pid,stat,etime,comm"],
        timeout=10,
    )
    if processes.returncode == 0:
        commands: list[str] = []
        for line in processes.stdout.splitlines()[1:]:
            fields = line.split(None, 3)
            if len(fields) == 4:
                commands.append(f"{fields[3]}({fields[1]}, {fields[2]})")
        if commands:
            details.append(
                (
                    "INFO",
                    f"{spec.name} 컨테이너 활성 프로세스: {', '.join(commands[:8])}",
                )
            )
    return details


def supervisor_failure(status: object) -> str | None:
    if not isinstance(status, dict):
        return None
    if status.get("manager") == "failed":
        return f"컨테이너 관리자가 실패했습니다: {status.get('reason', 'unknown')}"
    if status.get("policy_error"):
        return (
            "운영 정책 파일 오류로 서버 시작이 차단되었습니다: "
            f"{status.get('policy_error')}"
        )
    if status.get("game") == "update-failed":
        return f"게임 서버 자동 업데이트가 실패했습니다: {status.get('reason', 'unknown')}"
    try:
        exit_count = int(status.get("game_exit_count", 0))
    except (TypeError, ValueError):
        exit_count = 0
    if status.get("game") == "crash-wait" and exit_count >= 3:
        return (
            f"게임 프로세스가 반복 종료됐습니다: {exit_count}회, "
            f"마지막 종료 코드 {status.get('last_exit_code', 'unknown')}"
        )
    return None


def read_supervisor_status(spec: ServerSpec) -> tuple[dict[str, object] | None, str]:
    result = run(["docker", "exec", spec.container, "palctl", "status"], timeout=10)
    if result.returncode != 0:
        return None, result.stderr.strip() or result.stdout.strip()
    try:
        status = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        return None, str(error)
    if not isinstance(status, dict):
        return None, "palctl status 응답이 JSON 객체가 아닙니다."
    return status, ""


def temporary_start_action(status: dict[str, object], after_change: bool) -> str:
    """Return none, wait, automatic, or confirm for the runtime check."""
    if status.get("game") == "running":
        return "none"
    if status.get("desired_running") is not False:
        return "wait"
    if status.get("policy") == "stopped" and not after_change:
        return "confirm"
    return "automatic"


def test_session_state_restored(status: dict[str, object]) -> bool:
    if status.get("test_session_active"):
        return False
    game = status.get("game")
    if status.get("desired_running") is True:
        return game == "running"
    return game not in {"running", "stopping"}


def confirm_manual_test_start(spec: ServerSpec, manual_start: str = "ask") -> bool:
    if manual_start == "yes":
        return True
    if manual_start == "no":
        return False
    try:
        answer = input(
            f"{spec.name}은 Advanced Shutdown으로 수동 정지되어 있습니다. "
            "검사 동안만 임시 시작할까요? [y/N]: "
        ).strip().lower()
    except EOFError:
        return False
    return answer in {"y", "yes", "예", "네"}


def wait_for_supervisor_status(
    spec: ServerSpec, deadline: float
) -> tuple[dict[str, object] | None, str, bool]:
    """Wait for the full supervisor status, distinguishing a stopped container."""
    last_reason = "컨테이너 관리자가 아직 준비되지 않았습니다."
    next_notice = 0.0
    next_stall_warning = 0.0
    progress_tracker = InstallationProgressTracker()
    while True:
        inspected, error = inspect_container(spec)
        if inspected is None:
            return None, error or "컨테이너를 찾을 수 없습니다.", False
        state = inspected.get("State", {})
        if not isinstance(state, dict) or not state.get("Running"):
            status_text = state.get("Status", "stopped") if isinstance(state, dict) else "stopped"
            return None, f"Docker 컨테이너 상태: {status_text}", False

        status, status_error = read_supervisor_status(spec)
        if status is not None:
            failure = supervisor_failure(status)
            if failure:
                return None, failure, True
            if (
                status.get("manager") == "running"
                and "policy" in status
                and "desired_running" in status
            ):
                return status, "", True
            last_reason = str(status.get("reason", "컨테이너 관리자가 초기화 중입니다."))
        elif status_error:
            last_reason = status_error

        now = time.monotonic()
        if now >= deadline:
            logs = container_log_tail(spec, lines=200)
            progress = installation_progress(logs)
            unchanged_for, _changed = progress_tracker.observe(progress, now)
            timeout_detail = f"{last_reason}; 마지막 감지 단계: {progress}"
            if unchanged_for >= INSTALLATION_PROGRESS_STALL_SECONDS:
                timeout_detail += f"; 같은 단계가 {int(unchanged_for)}초 동안 지속됨"
            runtime_details = installation_runtime_diagnostics(spec)
            if runtime_details:
                timeout_detail += "; " + "; ".join(message for _level, message in runtime_details)
            return None, with_recent_logs(spec, timeout_detail), True
        if now >= next_notice:
            remaining = max(0, int(deadline - now))
            logs = container_log_tail(spec, lines=200)
            progress = installation_progress(logs)
            unchanged_for, changed = progress_tracker.observe(progress, now)
            if changed:
                next_stall_warning = 0.0
            unchanged_suffix = (
                f" · 같은 단계 {int(unchanged_for)}초"
                if unchanged_for >= INSTALLATION_PROGRESS_STALL_SECONDS
                else ""
            )
            print(
                f"[PROGRESS] {spec.name} {progress}{unchanged_suffix} · "
                f"제한 시간까지 {remaining}초"
            )
            if (
                unchanged_for >= INSTALLATION_PROGRESS_STALL_SECONDS
                and now >= next_stall_warning
            ):
                print(
                    f"[WARN] {spec.name} SteamCMD 단계가 {int(unchanged_for)}초 동안 "
                    "바뀌지 않았습니다. 컨테이너는 실행 중이며 다운로드 메타데이터 "
                    "준비 또는 Steam 네트워크·디스크 I/O 지연일 수 있습니다. "
                    "설정된 정체 제한에 도달하면 해당 SteamCMD 시도만 종료하고 "
                    "자동으로 다시 시도합니다."
                )
                for level, message in installation_runtime_diagnostics(spec):
                    print(f"[{level}] {message}")
                next_stall_warning = now + INSTALLATION_PROGRESS_STALL_SECONDS
            next_notice = now + 10
        time.sleep(min(2, max(0.1, deadline - now)))


def request_temporary_test_start(
    report: Report,
    spec: ServerSpec,
    duration: int,
    original_policy: str,
) -> bool:
    result = run(
        [
            "docker",
            "exec",
            spec.container,
            "palctl",
            "test-start",
            "--duration",
            str(duration),
        ],
        timeout=20,
    )
    if result.returncode != 0:
        report.fail(
            f"{spec.name} 임시 검사 시작 요청 실패: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
        return False
    report.pass_(
        f"{spec.name} 임시 검사 시작 요청 · 기존 운영 정책 유지: {original_policy}"
    )
    return True


def finish_temporary_test(
    report: Report,
    spec: ServerSpec,
    original_policy: str,
    original_reason: str,
) -> None:
    result = run(["docker", "exec", spec.container, "palctl", "test-finish"], timeout=20)
    if result.returncode != 0:
        report.fail(
            f"{spec.name} 임시 검사 종료 요청 실패: "
            f"{result.stderr.strip() or result.stdout.strip()}"
        )
        return

    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        status, _error = read_supervisor_status(spec)
        if status is not None:
            if test_session_state_restored(status):
                report.pass_(
                    f"{spec.name} 임시 검사 종료 · 기존 운영 상태 복귀: "
                    f"{original_policy} ({status.get('desired_reason', original_reason)})"
                )
                return
        time.sleep(1)
    report.fail(
        f"{spec.name} 임시 검사 종료 후 기존 운영 정책 상태로 복귀하지 못했습니다. "
        "palctl status와 runtime.log를 확인하세요."
    )


def wait_until_ready(spec: ServerSpec, deadline: float) -> tuple[bool, str]:
    last_reason = "컨테이너가 아직 준비되지 않았습니다."
    next_notice = 0.0
    runtime_user_checked = False
    while True:
        inspected, error = inspect_container(spec)
        if inspected is None:
            last_reason = error
        else:
            state = inspected.get("State", {})
            try:
                restart_count = int(inspected.get("RestartCount", 0))
            except (TypeError, ValueError):
                restart_count = 0
            if restart_count >= 3:
                return False, with_recent_logs(
                    spec, f"컨테이너가 시작 실패로 {restart_count}회 재시작됐습니다."
                )
            if isinstance(state, dict) and state.get("Running"):
                if not runtime_user_checked:
                    identity = run(["docker", "exec", spec.container, "id", "-u"])
                    if identity.returncode != 0:
                        last_reason = identity.stderr.strip() or identity.stdout.strip()
                    elif identity.stdout.strip() == "0":
                        return False, with_recent_logs(
                            spec,
                            "컨테이너가 root 사용자로 실행 중입니다. 이미지를 다시 빌드해야 합니다.",
                        )
                    else:
                        runtime_user_checked = True

                supervisor_status, _status_error = read_supervisor_status(spec)
                if supervisor_status is not None:
                    failure = supervisor_failure(supervisor_status)
                    if failure:
                        return False, with_recent_logs(spec, failure)

                api = run(["docker", "exec", spec.container, "palctl", "info"], timeout=10)
                if api.returncode == 0:
                    return True, ""
                last_reason = api.stderr.strip() or api.stdout.strip()
            else:
                last_reason = f"컨테이너 상태: {state}"

        now = time.monotonic()
        if now >= deadline:
            return False, with_recent_logs(spec, last_reason)
        if now >= next_notice:
            remaining = max(0, int(deadline - now))
            progress = ""
            status, _status_error = read_supervisor_status(spec)
            if status is not None and status.get("test_session_active"):
                progress = "임시 검사 기동 및 REST API 준비 중"
            elif status is not None and status.get("desired_running"):
                progress = "게임 서버 및 REST API 준비 중"
            if not progress:
                progress = installation_progress(container_log_tail(spec, lines=200))
            print(f"[PROGRESS] {spec.name} {progress} · 제한 시간까지 {remaining}초")
            next_notice = now + 10
        time.sleep(min(5, max(0.1, deadline - now)))


def external_forwarding_warning(
    server_name: str,
    game_port: int,
    rest_port: int,
    expose_rest_api: bool,
) -> str:
    forwarding_ports = f"game UDP {game_port}"
    if expose_rest_api:
        forwarding_ports += f", REST API TCP {rest_port}"
    return (
        f"{server_name} 외부 경로 미검증: 공유기/NAT/클라우드 방화벽에서 "
        f"{forwarding_ports} 포워딩을 별도로 확인하세요."
    )


def check_container_timezone(
    report: Report, spec: ServerSpec, expected_timezone: str
) -> bool:
    configured = run(["docker", "exec", spec.container, "printenv", "TZ"])
    actual_timezone = configured.stdout.strip()
    if configured.returncode != 0 or actual_timezone != expected_timezone:
        detail = actual_timezone or configured.stderr.strip() or "unknown"
        report.fail(
            f"{spec.name} 컨테이너 시간대가 common.env의 TZ={expected_timezone}와 "
            f"다릅니다: {detail}"
        )
        return False

    current_time = run(["docker", "exec", spec.container, "date", "+%Z %z"])
    if current_time.returncode != 0:
        report.fail(
            f"{spec.name} 컨테이너 시간 확인 실패: "
            f"{current_time.stderr.strip() or current_time.stdout.strip() or 'unknown'}"
        )
        return False

    report.pass_(
        f"{spec.name} 컨테이너 시간대: TZ={expected_timezone} · "
        f"{current_time.stdout.strip()}"
    )
    return True


def check_ready_server(
    report: Report,
    spec: ServerSpec,
    env: dict[str, str],
    expected_timezone: str,
) -> None:
    report.pass_(f"{spec.name} 컨테이너와 REST API 준비 완료")

    inspected, inspect_error = inspect_container(spec)
    if inspected is None:
        report.fail(f"{spec.name} 저장소 mount 검사 실패: {inspect_error}")
    else:
        mount_errors = storage_mount_errors(inspected, spec)
        if mount_errors:
            for mount_error in mount_errors:
                report.fail(f"{spec.name} 저장소 mount 오류: {mount_error}")
        else:
            report.pass_(
                f"{spec.name} 서버 파일 volume, Saved, logs, 운영 정책 및 "
                "resource metrics read-only bind mount"
            )

    policy_path = instances.policy_dir(spec.name) / "policy.json"
    try:
        policy = read_policy_file(policy_path)
    except PolicyFileError as error:
        report.fail(f"{spec.name} 운영 정책 파일 오류: {error}")
    else:
        report.pass_(
            f"{spec.name} 운영 정책 파일 검증: {policy.get('override', 'invalid')}"
        )

    storage_access = run(
        [
            "docker",
            "exec",
            spec.container,
            "/bin/sh",
            "-c",
            "test -r /palworld/server/PalServer.sh && test -w /palworld/server && test -w /palworld/server/Pal && test -w /palworld/server/Pal/Saved && test -w /palworld/logs && test -w /palworld/policy && test -w /palworld/update-lock",
        ]
    )
    if storage_access.returncode == 0:
        report.pass_(
            f"{spec.name} 서버 파일, Saved, runtime logs 및 운영 정책 "
            "읽기·쓰기 권한"
        )
    else:
        report.fail(
            f"{spec.name} 서버 파일, Saved, runtime logs 또는 운영 정책 "
            "접근 권한 오류"
        )

    identity = run(["docker", "exec", spec.container, "id", "-u"])
    if identity.returncode == 0 and identity.stdout.strip() not in {"", "0"}:
        report.pass_(f"{spec.name} 비-root 실행 사용자: UID {identity.stdout.strip()}")
    else:
        report.fail(f"{spec.name} 컨테이너 실행 사용자가 root이거나 확인할 수 없습니다.")

    check_container_timezone(report, spec, expected_timezone)

    game_port = parse_port(env["SERVER_PORT"], f"{spec.name}.SERVER_PORT")
    rest_port = parse_port(env["PAL_SETTING_RESTAPIPort"], f"{spec.name}.PAL_SETTING_RESTAPIPort")
    expose = parse_bool(env["REST_API_EXPOSE"], f"{spec.name}.REST_API_EXPOSE")
    common = load_env(CONFIG_DIR / "common.env")
    manager_port = parse_port(
        common["MANAGER_API_PORT"], "common.env.MANAGER_API_PORT"
    )

    game_mapping = run(["docker", "port", spec.container, f"{game_port}/udp"])
    if game_mapping.returncode == 0 and f":{game_port}" in game_mapping.stdout:
        report.pass_(f"{spec.name} 게임 포트 게시: {game_mapping.stdout.strip().replace(chr(10), ', ')}")
    else:
        report.fail(f"{spec.name} UDP {game_port} 게시 상태를 확인할 수 없습니다.")

    gateway_mapping_result = run(["docker", "port", spec.container, f"{manager_port}/tcp"])
    mapping = gateway_mapping_result.stdout.strip()
    if gateway_mapping_result.returncode != 0 or f":{rest_port}" not in mapping:
        report.fail(f"{spec.name} 통합 API TCP {rest_port} 게시 상태를 확인할 수 없습니다.")
    elif expose and ("0.0.0.0:" in mapping or "[::]:" in mapping):
        report.pass_(f"{spec.name} 통합 API 외부 게시: {mapping.replace(chr(10), ', ')}")
    elif not expose and all(line.startswith("127.0.0.1:") for line in mapping.splitlines()):
        report.pass_(f"{spec.name} 통합 API 로컬 전용 게시: {mapping}")
    else:
        report.fail(f"{spec.name} REST_API_EXPOSE 설정과 Docker 게시 주소가 다릅니다: {mapping}")
    host_api_ok, host_api_error = call_host_rest_api(
        rest_port,
        common.get("API_USERNAME", "admin"),
        env.get("PAL_SETTING_AdminPassword", ""),
        env.get("API_ACCESS_TOKEN", ""),
    )
    if host_api_ok:
        report.pass_(f"{spec.name} 호스트 REST API 게시·인증·응답")
    else:
        report.fail(f"{spec.name} 호스트 REST API 호출 실패: {host_api_error}")

    manager_api_ok, manager_api_error = call_host_manager_api(
        rest_port,
        common.get("API_USERNAME", "admin"),
        env.get("PAL_SETTING_AdminPassword", ""),
        env.get("API_ACCESS_TOKEN", ""),
    )
    if manager_api_ok:
        report.pass_(f"{spec.name} Linux 관리 API 게시·인증·상태 응답")
    else:
        report.fail(f"{spec.name} Linux 관리 API 호출 실패: {manager_api_error}")

    verification_ok, verification_error = call_host_verification_api(
        rest_port,
        common.get("API_USERNAME", "admin"),
        env.get("PAL_SETTING_AdminPassword", ""),
        env.get("API_ACCESS_TOKEN", ""),
    )
    if verification_ok:
        report.pass_(f"{spec.name} Windows 사용자용 서버·토큰 challenge 검증")
    else:
        report.fail(f"{spec.name} Windows 사용자용 서버·토큰 검증 실패: {verification_error}")

    status_result = run(["docker", "exec", spec.container, "palctl", "status"], timeout=20)
    if status_result.returncode == 0:
        report.pass_(f"{spec.name} 관리 명령: palctl status")
        try:
            status = json.loads(status_result.stdout)
            automatic_updates = parse_bool(
                common.get("AUTO_UPDATE_ENABLED", "false"), "common.env.AUTO_UPDATE_ENABLED"
            ) and not env.get("STEAM_BETA", common.get("STEAM_BETA", "")).strip()
            if status.get("automatic_updates") is automatic_updates:
                installed_build = status.get("installed_build_id")
                if automatic_updates and isinstance(installed_build, int):
                    report.pass_(f"{spec.name} 운영 중 자동 업데이트 활성, 설치 빌드 {installed_build}")
                elif automatic_updates:
                    report.fail(f"{spec.name} Steam 설치 빌드 ID를 확인할 수 없습니다.")
                else:
                    report.pass_(f"{spec.name} 운영 중 자동 업데이트 비활성")
            else:
                report.fail(f"{spec.name} 자동 업데이트 설정과 감독기 상태가 다릅니다.")
        except (json.JSONDecodeError, ValueError) as error:
            report.fail(f"{spec.name} palctl status 해석 실패: {error}")
    else:
        report.fail(
            f"{spec.name} palctl status 실패: {status_result.stderr.strip() or status_result.stdout.strip()}"
        )

    for command in ("info", "metrics", "players", "settings"):
        result = run(["docker", "exec", spec.container, "palctl", command], timeout=20)
        if result.returncode == 0:
            report.pass_(f"{spec.name} 관리 명령: palctl {command}")
        else:
            report.fail(f"{spec.name} palctl {command} 실패: {result.stderr.strip() or result.stdout.strip()}")

    report.warn(external_forwarding_warning(spec.name, game_port, rest_port, expose))


def check_server(
    report: Report,
    spec: ServerSpec,
    env: dict[str, str],
    wait_seconds: int,
    *,
    expected_timezone: str,
    after_change: bool,
    manual_start: str = "ask",
) -> None:
    deadline = time.monotonic() + wait_seconds
    status, reason, container_running = wait_for_supervisor_status(spec, deadline)
    if not container_running:
        message = f"{spec.name} Docker 컨테이너가 정지되어 검사할 수 없습니다: {reason}"
        if after_change:
            report.fail(message)
        else:
            report.skip(message)
        return
    if status is None:
        report.fail(f"{spec.name} 컨테이너 관리자가 준비되지 않았습니다: {reason}")
        return

    action = temporary_start_action(status, after_change)
    if action == "confirm" and not confirm_manual_test_start(spec, manual_start):
        report.skip(
            f"{spec.name} Advanced Shutdown 상태 유지 · 사용자가 임시 시작을 선택하지 않음"
        )
        return

    temporary_session = action in {"automatic", "confirm"}
    original_policy = str(status.get("policy", "auto"))
    original_reason = str(status.get("desired_reason", "stopped"))
    if temporary_session:
        # Ensure an explicit Test has enough time to boot even when --wait was
        # omitted, while retaining the longer Setup/Manage deadline.
        deadline = max(deadline, time.monotonic() + 300)
        duration = max(600, int(max(0, deadline - time.monotonic())) + 300)
        if not request_temporary_test_start(report, spec, duration, original_policy):
            return

    try:
        ready, ready_reason = wait_until_ready(spec, deadline)
        if not ready:
            report.fail(f"{spec.name}가 준비되지 않았습니다: {ready_reason}")
            return
        check_ready_server(report, spec, env, expected_timezone)
    finally:
        if temporary_session:
            finish_temporary_test(
                report,
                spec,
                original_policy,
                original_reason,
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="팰월드 서버 설치·설정·네트워크 종합 검사")
    parser.add_argument("--server", default="server1", help="serverN, 쉼표 목록 또는 all")
    parser.add_argument("--wait", type=int, default=0, help="REST API가 준비되기를 기다릴 최대 시간(초)")
    parser.add_argument("--config-only", action="store_true", help="Docker에 접속하지 않고 설정만 검사")
    parser.add_argument(
        "--after-change",
        action="store_true",
        help="Setup/Manage 직후 운영 정책을 보존하며 서버를 임시 기동해 검사",
    )
    parser.add_argument(
        "--manual-start",
        choices=("ask", "yes", "no"),
        default="ask",
        help=(
            "Advanced Shutdown 서버의 임시 검사 시작 여부: "
            "ask(대화형), yes(허용), no(건너뜀)"
        ),
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.wait < 0:
        print("오류: --wait는 0 이상의 값이어야 합니다.", file=sys.stderr)
        return 2

    report = Report()
    try:
        specs = selected_specs(args.server)
    except ValueError as error:
        print(f"오류: {error}", file=sys.stderr)
        return 2
    configs, expected_timezone = validate_configs(report, specs)
    validate_configured_port_conflicts(report)
    if args.config_only:
        return report.summary(config_only=True)
    if expected_timezone is None or not check_host(report, expected_timezone):
        return report.summary()
    for spec in specs:
        if spec.name in configs:
            check_server(
                report,
                spec,
                configs[spec.name],
                args.wait,
                expected_timezone=expected_timezone,
                after_change=args.after_change,
                manual_start=args.manual_start,
            )
    return report.summary()


if __name__ == "__main__":
    sys.exit(main())
