#!/usr/bin/env python3
"""Discover, configure, and render dynamic Palworld server instances."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path


PROJECT_DIR = Path(
    os.getenv("PALWORLD_PROJECT_DIR", str(Path(__file__).resolve().parents[2]))
).resolve()
CONFIG_DIR = PROJECT_DIR / "config"
DATA_DIR = PROJECT_DIR / "data"
RUNTIME_DIR = PROJECT_DIR / "runtime"
COMPOSE_FILE = RUNTIME_DIR / "compose.yaml"
TEMPLATE_FILE = CONFIG_DIR / "server.template.env"
IMAGE_NAME = os.getenv(
    "PALWORLD_IMAGE", "local/palworld-dedicated-server:uid1000-gid1000"
)
MANAGER_LABEL_KEY = "io.palworld.manager"
MANAGER_LABEL_VALUE = "palworld-docker"
MANAGER_LABEL = f"{MANAGER_LABEL_KEY}={MANAGER_LABEL_VALUE}"
INSTANCE_LABEL = "io.palworld.instance"
PROJECT_LABEL = "io.palworld.project-dir"
COMPOSE_WORKING_DIR_LABEL = "com.docker.compose.project.working_dir"
SERVER_RE = re.compile(r"server([1-9][0-9]*)$")
CONTAINER_RE = re.compile(r"palworld-server([1-9][0-9]*)$")
VOLUME_RE = re.compile(r"palworld-(server[1-9][0-9]*)-(?:server|steam|data)$")
ACCESS_TOKEN_RE = re.compile(r"[A-Za-z0-9_-]{32,128}")
DEFAULT_GAME_PORT_BASE = 39471
DEFAULT_REST_API_PORT_BASE = DEFAULT_GAME_PORT_BASE + 1


@dataclass(frozen=True)
class InstalledServer:
    name: str
    container: str
    image: str
    state: str
    status: str


def server_number(name: str) -> int:
    match = SERVER_RE.fullmatch(name)
    if not match:
        raise ValueError(f"서버 이름 형식 오류: {name!r} (예: server1)")
    return int(match.group(1))


def server_sort_key(name: str) -> int:
    return server_number(name)


def config_path(name: str) -> Path:
    server_number(name)
    return CONFIG_DIR / f"{name}.env"


def data_path(name: str) -> Path:
    server_number(name)
    return DATA_DIR / name


def saved_path(name: str) -> Path:
    return data_path(name) / "saved"


def logs_path(name: str) -> Path:
    return data_path(name) / "logs"


def policy_dir(name: str) -> Path:
    server_number(name)
    return RUNTIME_DIR / "policy" / name


def update_lock_dir() -> Path:
    return RUNTIME_DIR / "update-lock"


def server_volume_name(name: str) -> str:
    server_number(name)
    return f"palworld-{name}-server"


def steam_volume_name(name: str) -> str:
    server_number(name)
    return f"palworld-{name}-steam"


def container_name(name: str) -> str:
    server_number(name)
    return f"palworld-{name}"


def port_generation_settings(common: dict[str, str] | None = None) -> tuple[int, int, int]:
    if common is None:
        common_file = CONFIG_DIR / "common.env"
        try:
            common = load_env(common_file) if common_file.exists() else {}
        except OSError as error:
            raise ValueError(f"common.env 자동 포트 설정을 읽을 수 없습니다: {error}") from error

    def positive_integer(key: str, default: str, *, port: bool = False) -> int:
        raw = common.get(key, default)
        if not raw.isdigit():
            raise ValueError(f"common.env.{key}에는 1 이상의 정수를 지정해야 합니다.")
        value = int(raw)
        maximum = 65535
        if value < 1 or value > maximum:
            kind = "1~65535 포트" if port else "1~65535 범위의 증가값"
            raise ValueError(f"common.env.{key}에는 {kind}을 지정해야 합니다.")
        return value

    return (
        positive_integer("GAME_PORT_BASE", str(DEFAULT_GAME_PORT_BASE), port=True),
        positive_integer("REST_API_PORT_BASE", str(DEFAULT_REST_API_PORT_BASE), port=True),
        positive_integer("SERVER_PORT_STEP", "10"),
    )


def default_ports(name: str, common: dict[str, str] | None = None) -> tuple[int, int]:
    number = server_number(name)
    game_base, rest_base, step = port_generation_settings(common)
    game_port = game_base + (number - 1) * step
    rest_port = rest_base + (number - 1) * step
    if game_port > 65535 or rest_port > 65535:
        raise ValueError(
            f"{name}: common.env 기준값과 SERVER_PORT_STEP으로 계산한 자동 포트가 "
            "65535를 초과했습니다."
        )
    return game_port, rest_port


def parse_port(value: str | int, name: str) -> int:
    text = str(value).strip()
    if not text.isdigit() or not 1 <= int(text) <= 65535:
        raise ValueError(f"{name} must be a port between 1 and 65535: {value!r}")
    return int(text)


def parse_bool(value: str, name: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "y", "on"}:
        return True
    if normalized in {"0", "false", "no", "n", "off"}:
        return False
    raise ValueError(f"{name} must be true or false: {value!r}")


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def set_env_value(content: str, key: str, value: str) -> str:
    pattern = re.compile(rf"(?m)^{re.escape(key)}=.*$")
    replacement = f"{key}={value}"
    if pattern.search(content):
        return pattern.sub(lambda _match: replacement, content, count=1)
    return f"{replacement}\n{content}"


def write_atomic(path: Path, content: str) -> None:
    existing = path.stat() if path.exists() else None
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", newline="\n", dir=path.parent, delete=False
    ) as handle:
        handle.write(content.rstrip() + "\n")
        temporary = Path(handle.name)
    if existing is not None:
        os.chmod(temporary, existing.st_mode & 0o7777)
        if hasattr(os, "chown"):
            try:
                os.chown(temporary, existing.st_uid, existing.st_gid)
            except (AttributeError, PermissionError):
                pass
    temporary.replace(path)


def validate_access_token(value: str, label: str = "API_ACCESS_TOKEN") -> str:
    token = value.strip()
    if not ACCESS_TOKEN_RE.fullmatch(token):
        raise ValueError(
            f"{label}에는 영문자·숫자·밑줄·하이픈으로 된 32~128자 토큰이 필요합니다."
        )
    return token


def protect_config_file(path: Path) -> None:
    """Restrict server env files because they contain passwords and access tokens."""
    try:
        path.chmod(0o600)
    except OSError as error:
        raise OSError(f"서버 설정 파일 권한을 0600으로 제한할 수 없습니다: {path}") from error


def ensure_access_token(name: str) -> tuple[str, bool]:
    path = config_path(name)
    if not path.exists():
        raise FileNotFoundError(f"서버 설정 파일을 찾을 수 없습니다: {path}")
    content = path.read_text(encoding="utf-8-sig")
    current = load_env(path).get("API_ACCESS_TOKEN", "").strip()
    if not current or "CHANGE_ME" in current.upper():
        generated = secrets.token_urlsafe(32)
        content = set_env_value(content, "API_ACCESS_TOKEN", generated)
        write_atomic(path, content)
        protect_config_file(path)
        return generated, True
    token = validate_access_token(current, f"{name}.API_ACCESS_TOKEN")
    protect_config_file(path)
    return token, False


def read_access_token(name: str) -> str:
    """Read one configured token without silently changing server state."""
    path = config_path(name)
    if not path.exists():
        raise FileNotFoundError(f"서버 설정 파일을 찾을 수 없습니다: {path}")
    current = load_env(path).get("API_ACCESS_TOKEN", "").strip()
    return validate_access_token(current, f"{name}.API_ACCESS_TOKEN")


def rotate_access_token(name: str) -> str:
    path = config_path(name)
    if not path.exists():
        raise FileNotFoundError(f"서버 설정 파일을 찾을 수 없습니다: {path}")
    generated = secrets.token_urlsafe(32)
    content = path.read_text(encoding="utf-8-sig")
    write_atomic(path, set_env_value(content, "API_ACCESS_TOKEN", generated))
    protect_config_file(path)
    return generated


def ensure_template() -> Path:
    if TEMPLATE_FILE.exists():
        return TEMPLATE_FILE
    candidates = (CONFIG_DIR / "server1.env", CONFIG_DIR / "server1.env.example")
    source = next((path for path in candidates if path.exists()), None)
    if source is None:
        raise FileNotFoundError("서버 환경 파일 템플릿 원본을 찾을 수 없습니다.")
    content = source.read_text(encoding="utf-8-sig")
    defaults = {
        "SERVER_PORT": str(DEFAULT_GAME_PORT_BASE),
        "REST_API_EXPOSE": "false",
        "API_ACCESS_TOKEN": "",
        "ACTIVE_WINDOW": "always",
        "RESTART_TIMES": "04:00",
        "COMMUNITY_SERVER": "false",
        "SERVER_ARGS": "",
        "PAL_SETTING_ServerName": "My Palworld Server",
        "PAL_SETTING_ServerDescription": "Docker managed Palworld server",
        "PAL_SETTING_ServerPassword": "",
        "PAL_SETTING_AdminPassword": "CHANGE_ME_TO_A_LONG_RANDOM_PASSWORD",
        "PAL_SETTING_ServerPlayerMaxNum": "32",
        "PAL_SETTING_RESTAPIEnabled": "True",
        "PAL_SETTING_RESTAPIPort": str(DEFAULT_REST_API_PORT_BASE),
    }
    for key, value in defaults.items():
        content = set_env_value(content, key, value)
    content = "# Template for creating a new serverN environment file\n" + content
    write_atomic(TEMPLATE_FILE, content)
    return TEMPLATE_FILE


def create_config(name: str) -> tuple[Path, bool]:
    number = server_number(name)
    destination = config_path(name)
    if destination.exists():
        ensure_access_token(name)
        return destination, False
    template = ensure_template()
    content = template.read_text(encoding="utf-8-sig")
    game_port, rest_port = default_ports(name)
    restart_minutes = 4 * 60 + (number - 1) * 15
    restart_time = f"{(restart_minutes // 60) % 24:02d}:{restart_minutes % 60:02d}"
    values = {
        "SERVER_PORT": str(game_port),
        "RESTART_TIMES": restart_time,
        "PAL_SETTING_ServerName": f"My Palworld Server {number}",
        "PAL_SETTING_ServerDescription": f"Docker managed Palworld server {number}",
        "PAL_SETTING_AdminPassword": secrets.token_urlsafe(24),
        "PAL_SETTING_RESTAPIPort": str(rest_port),
        "API_ACCESS_TOKEN": secrets.token_urlsafe(32),
    }
    for key, value in values.items():
        content = set_env_value(content, key, value)
    write_atomic(destination, content)
    protect_config_file(destination)
    return destination, True


def connection_info(name: str) -> dict[str, str | int]:
    """Return the credentials and ports Windows clients need after Setup."""
    env = load_env(config_path(name))
    common = load_env(CONFIG_DIR / "common.env")
    default_game, default_rest = default_ports(name, common)
    token, _created = ensure_access_token(name)
    return {
        "server": name,
        "username": common.get("API_USERNAME", "admin").strip() or "admin",
        "admin_password": env.get("PAL_SETTING_AdminPassword", ""),
        "api_access_token": token,
        "game_port": parse_port(env.get("SERVER_PORT", default_game), "SERVER_PORT"),
        "rest_api_port": parse_port(
            env.get("PAL_SETTING_RESTAPIPort", default_rest), "PAL_SETTING_RESTAPIPort"
        ),
    }


def print_connection_info(name: str, output_format: str) -> None:
    info = connection_info(name)
    if output_format == "json":
        print(json.dumps(info, ensure_ascii=False))
        return
    print(f"서버: {info['server']}")
    print(f"API 사용자명: {info['username']}")
    print(f"관리자 비밀번호: {info['admin_password']}")
    print(f"API access token: {info['api_access_token']}")
    print(f"게임 서버 포트 (UDP): {info['game_port']}")
    print(f"REST API 포트 (TCP): {info['rest_api_port']}")


def configured_names() -> list[str]:
    names: list[str] = []
    for path in CONFIG_DIR.glob("server*.env"):
        name = path.stem
        if SERVER_RE.fullmatch(name):
            names.append(name)
    return sorted(set(names), key=server_sort_key)


def run_docker(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", *command],
        cwd=PROJECT_DIR,
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def running_published_port_owners() -> dict[tuple[int, str], set[str]]:
    """Return host ports published by running Docker containers."""
    listing = run_docker(["ps", "-q"])
    if listing.returncode != 0:
        raise OSError(listing.stderr.strip() or "Docker container listing failed")
    container_ids = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    if not container_ids:
        return {}
    inspected = run_docker(["container", "inspect", *container_ids])
    if inspected.returncode != 0:
        raise OSError(inspected.stderr.strip() or "Docker port inspection failed")
    try:
        containers = json.loads(inspected.stdout)
    except json.JSONDecodeError as error:
        raise OSError(f"Docker port inspection returned invalid JSON: {error}") from error
    owners: dict[tuple[int, str], set[str]] = {}
    for container in containers:
        if not isinstance(container, dict) or not container.get("State", {}).get("Running"):
            continue
        name = str(container.get("Name", "")).lstrip("/") or "unknown-container"
        ports = container.get("NetworkSettings", {}).get("Ports", {}) or {}
        for container_port, bindings in ports.items():
            match = re.fullmatch(r"\d+/(tcp|udp)", str(container_port))
            if match is None or not isinstance(bindings, list):
                continue
            for binding in bindings:
                try:
                    host_port = parse_port(binding.get("HostPort", ""), "Docker HostPort")
                except (AttributeError, ValueError):
                    continue
                owners.setdefault((host_port, match.group(1)), set()).add(name)
    return owners


def probe_host_binding(host: str, port: int, protocol: str) -> None:
    socket_type = socket.SOCK_DGRAM if protocol == "udp" else socket.SOCK_STREAM
    with socket.socket(socket.AF_INET, socket_type) as probe:
        probe.bind((host, port))


def preflight_host_ports(name: str, bind_probe=probe_host_binding) -> list[dict[str, object]]:
    """Reject requested host ports already owned outside the target container."""
    server_number(name)
    env = load_env(config_path(name))
    common = load_env(CONFIG_DIR / "common.env")
    default_game, default_rest = default_ports(name, common)
    game_port = parse_port(env.get("SERVER_PORT", default_game), f"{name}.SERVER_PORT")
    rest_port = parse_port(
        env.get("PAL_SETTING_RESTAPIPort", default_rest),
        f"{name}.PAL_SETTING_RESTAPIPort",
    )
    expose = parse_bool(env.get("REST_API_EXPOSE", "false"), f"{name}.REST_API_EXPOSE")
    desired = (
        ("0.0.0.0", game_port, "udp", "game"),
        ("0.0.0.0" if expose else "127.0.0.1", rest_port, "tcp", "integrated API"),
    )
    owners = running_published_port_owners()
    target_container = container_name(name)
    checked: list[dict[str, object]] = []
    for host, port, protocol, purpose in desired:
        port_owners = owners.get((port, protocol), set())
        unrelated = sorted(owner for owner in port_owners if owner != target_container)
        if unrelated:
            raise OSError(
                f"{name} {purpose} host port {port}/{protocol} is already published by "
                f"Docker container(s): {', '.join(unrelated)}"
            )
        if target_container not in port_owners:
            try:
                bind_probe(host, port, protocol)
            except OSError as error:
                raise OSError(
                    f"{name} {purpose} host port {host}:{port}/{protocol} is already in use"
                ) from error
        checked.append(
            {"host": host, "port": port, "protocol": protocol, "purpose": purpose}
        )
    return checked


def docker_label(labels: object, key: str) -> str:
    """Read one label from Docker's JSON ``ps`` representation.

    Docker exposes ``Labels`` as a comma-delimited string in ``docker ps
    --format '{{json .}}'``. Accept a mapping too so this parser remains
    compatible with structured Docker responses.
    """
    if isinstance(labels, dict):
        return str(labels.get(key, ""))
    for item in str(labels or "").split(","):
        label_key, separator, value = item.partition("=")
        if separator and label_key == key:
            return value
    return ""


def docker_resource_belongs_to_project(
    *,
    labels: object,
    resource: str,
    project_dir: Path,
    strict: bool,
) -> bool:
    """Classify a container using explicit ownership before legacy evidence."""
    expected_project = str(project_dir)
    explicit_owner = docker_label(labels, PROJECT_LABEL)
    compose_owner = docker_label(labels, COMPOSE_WORKING_DIR_LABEL)
    for label_name, owner in (
        (PROJECT_LABEL, explicit_owner),
        (COMPOSE_WORKING_DIR_LABEL, compose_owner),
    ):
        if owner and owner != expected_project:
            if strict:
                raise ValueError(
                    f"{resource}: 다른 프로젝트 소유 Docker 리소스입니다 "
                    f"({label_name}={owner!r}, 현재={expected_project!r})."
                )
            return False
    if explicit_owner or compose_owner:
        return True
    if strict:
        raise ValueError(
            f"{resource}: 프로젝트 소유 label이 없는 legacy 리소스의 소유권을 "
            "확인할 수 없습니다. 연결된 현재 프로젝트 컨테이너 같은 강한 소유권 "
            "근거가 필요합니다."
        )
    return False


def assert_global_project_resource_ownership(
    *, labels: object, resource: str, legacy_evidence: bool
) -> None:
    """Validate a project-wide image or network with no server identity."""
    expected_project = str(PROJECT_DIR)
    explicit_owner = docker_label(labels, PROJECT_LABEL)
    compose_owner = docker_label(labels, COMPOSE_WORKING_DIR_LABEL)
    for label_name, owner in (
        (PROJECT_LABEL, explicit_owner),
        (COMPOSE_WORKING_DIR_LABEL, compose_owner),
    ):
        if owner and owner != expected_project:
            raise ValueError(
                f"{resource}: 다른 프로젝트 소유 Docker 리소스입니다 "
                f"({label_name}={owner!r}, 현재={expected_project!r})."
            )
    if explicit_owner or compose_owner:
        return
    if legacy_evidence:
        return
    raise ValueError(
        f"{resource}: 프로젝트 소유 label이 없는 전역 legacy 리소스입니다. "
        "현재 프로젝트 설정이 없어 안전하게 소유권을 확인할 수 없습니다."
    )


def parse_installed_servers(
    lines: list[str],
    *,
    strict: bool = False,
    project_dir: Path | None = None,
) -> list[InstalledServer]:
    servers: dict[str, InstalledServer] = {}
    for line in lines:
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            if strict:
                raise ValueError("Docker 컨테이너 목록 JSON을 해석할 수 없습니다.") from error
            continue
        container = str(value.get("Names", "")).removeprefix("/")
        labeled_name = docker_label(value.get("Labels", ""), INSTANCE_LABEL)
        if labeled_name:
            if not SERVER_RE.fullmatch(labeled_name):
                if strict:
                    raise ValueError(
                        f"{container or 'unknown container'}: {INSTANCE_LABEL} label 형식이 "
                        f"잘못되었습니다: {labeled_name!r}"
                    )
                continue
            name = labeled_name
        else:
            match = CONTAINER_RE.fullmatch(container)
            if not match:
                if strict:
                    raise ValueError(
                        f"{container or 'unknown container'}: {INSTANCE_LABEL} label 또는 "
                        "palworld-serverN 이름이 필요합니다."
                    )
                continue
            name = f"server{match.group(1)}"
        if project_dir is not None and container != container_name(name):
            if strict:
                raise ValueError(
                    f"{container or 'unknown container'}: 관리 대상 {name}의 컨테이너 이름은 "
                    f"{container_name(name)!r}이어야 합니다."
                )
            continue
        if project_dir is not None and not docker_resource_belongs_to_project(
            labels=value.get("Labels", ""),
            resource=container or "unknown container",
            project_dir=project_dir,
            strict=strict,
        ):
            continue
        if name in servers:
            if strict:
                raise ValueError(
                    f"{name}: 같은 {INSTANCE_LABEL} label을 가진 Docker 컨테이너가 "
                    "둘 이상입니다."
                )
            continue
        servers[name] = InstalledServer(
            name=name,
            container=container,
            image=str(value.get("Image", "")),
            state=str(value.get("State", "unknown")),
            status=str(value.get("Status", "unknown")),
        )
    return sorted(servers.values(), key=lambda item: server_sort_key(item.name))


def parse_inspected_server(
    output: str,
    expected_name: str,
    *,
    project_dir: Path | None = None,
) -> InstalledServer:
    """Parse one exact-name ``docker container inspect`` response."""
    server_number(expected_name)
    expected_container = container_name(expected_name)
    try:
        payload = json.loads(output)
        value = payload[0]
        container = str(value.get("Name", "")).removeprefix("/")
        config = value.get("Config") or {}
        state_data = value.get("State") or {}
    except (IndexError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(
            f"{expected_container}: Docker inspect 결과를 해석할 수 없습니다."
        ) from error
    if container != expected_container:
        raise ValueError(
            f"{expected_container}: Docker inspect가 다른 컨테이너를 반환했습니다: {container!r}"
        )
    if project_dir is not None and not docker_resource_belongs_to_project(
        labels=config.get("Labels") or {},
        resource=container,
        project_dir=project_dir,
        strict=True,
    ):
        raise ValueError(f"{container}: 현재 프로젝트 소유 컨테이너가 아닙니다.")
    state = str(state_data.get("Status", "unknown"))
    return InstalledServer(
        name=expected_name,
        container=container,
        image=str(config.get("Image", "")),
        state=state,
        status=state,
    )


def docker_query_error(action: str, result: subprocess.CompletedProcess[str]) -> OSError:
    detail = (result.stderr or result.stdout).strip()
    if not detail:
        detail = f"exit code {result.returncode}"
    return OSError(f"Docker {action} 실패: {detail}")


def installed_servers(*, strict: bool = False) -> list[InstalledServer]:
    """Return containers owned by this manager or its selected project.

    The manager label is authoritative.  Exact ``palworld-serverN`` names are
    accepted as a legacy/recovery fallback only when structured Docker labels
    prove that the selected project created them.
    """
    try:
        result = run_docker(
            [
                "ps",
                "-a",
                "--filter",
                f"label={MANAGER_LABEL}",
                "--format",
                "{{json .}}",
            ]
        )
    except FileNotFoundError:
        if strict:
            raise OSError("Docker CLI를 찾을 수 없습니다.") from None
        return []
    if result.returncode != 0:
        if strict:
            raise docker_query_error("컨테이너 목록 조회", result)
        return []

    configured = configured_names()
    by_name: dict[str, InstalledServer] = {}
    listed = parse_installed_servers(result.stdout.splitlines(), strict=strict)
    for listed_server in listed:
        expected_container = container_name(listed_server.name)
        if listed_server.container != expected_container:
            if strict:
                raise ValueError(
                    f"{listed_server.container}: 관리 대상 {listed_server.name}의 컨테이너 "
                    f"이름은 {expected_container!r}이어야 합니다."
                )
            continue
        inspected = run_docker(["container", "inspect", expected_container])
        if inspected.returncode != 0:
            # The container can disappear between ``ps`` and ``inspect``. Other
            # inspect errors remain fatal in strict state-changing inventories.
            detail = (inspected.stderr or inspected.stdout).strip().lower()
            if "no such" in detail or "not found" in detail:
                continue
            if strict:
                raise docker_query_error(f"{expected_container} 소유권 조회", inspected)
            continue
        try:
            parse_inspected_server(
                inspected.stdout,
                listed_server.name,
                project_dir=PROJECT_DIR,
            )
        except ValueError:
            if strict:
                raise
            continue
        # Keep the richer human-readable status from ``docker ps`` after the
        # structured inspect result has established ownership.
        by_name[listed_server.name] = listed_server
    for name in configured:
        if name in by_name:
            continue
        try:
            inspected = run_docker(["container", "inspect", container_name(name)])
        except FileNotFoundError:
            if strict:
                raise OSError("Docker CLI를 찾을 수 없습니다.") from None
            break
        if inspected.returncode != 0:
            detail = (inspected.stderr or inspected.stdout).strip().lower()
            if "no such" in detail or "not found" in detail:
                continue
            if strict:
                raise docker_query_error(
                    f"{container_name(name)} 소유권 조회", inspected
                )
            continue
        try:
            by_name[name] = parse_inspected_server(
                inspected.stdout,
                name,
                project_dir=PROJECT_DIR,
            )
        except ValueError:
            if strict:
                raise
    return sorted(by_name.values(), key=lambda item: server_sort_key(item.name))


def docker_inspect_payload(
    arguments: list[str], resource: str
) -> dict[str, object] | None:
    """Return one Docker inspect object, or ``None`` when it does not exist."""
    try:
        result = run_docker(arguments)
    except FileNotFoundError:
        raise OSError("Docker CLI를 찾을 수 없습니다.") from None
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().lower()
        if "no such" in detail or "not found" in detail:
            return None
        raise docker_query_error(f"{resource} 소유권 조회", result)
    try:
        payload = json.loads(result.stdout)
        value = payload[0]
    except (IndexError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"{resource}: Docker inspect 결과를 해석할 수 없습니다.") from error
    if not isinstance(value, dict):
        raise ValueError(f"{resource}: Docker inspect 결과가 객체가 아닙니다.")
    return value


def assert_server_ownership(name: str) -> None:
    """Reject a target container or volume owned by another project."""
    server_number(name)
    expected_container = container_name(name)
    attached_volumes: set[str] = set()
    container = docker_inspect_payload(
        ["container", "inspect", expected_container], expected_container
    )
    if container is not None:
        actual_name = str(container.get("Name", "")).removeprefix("/")
        if actual_name != expected_container:
            raise ValueError(
                f"{expected_container}: 다른 컨테이너가 반환되었습니다: {actual_name!r}"
            )
        config = container.get("Config") or {}
        labels = (config.get("Labels") or {}) if isinstance(config, dict) else {}
        docker_resource_belongs_to_project(
            labels=labels,
            resource=expected_container,
            project_dir=PROJECT_DIR,
            strict=True,
        )
        mounts = container.get("Mounts") or []
        if isinstance(mounts, list):
            attached_volumes = {
                str(mount.get("Name", ""))
                for mount in mounts
                if isinstance(mount, dict) and str(mount.get("Type", "")) == "volume"
            }

    for volume_name in (
        server_volume_name(name),
        steam_volume_name(name),
        f"palworld-{name}-data",
    ):
        volume = docker_inspect_payload(["volume", "inspect", volume_name], volume_name)
        if volume is None:
            continue
        consumers_result = run_docker(
            ["ps", "-a", "--filter", f"volume={volume_name}", "--format", "{{.Names}}"]
        )
        if consumers_result.returncode != 0:
            raise docker_query_error(f"{volume_name} 사용 컨테이너 조회", consumers_result)
        consumers = {
            item.strip()
            for item in consumers_result.stdout.splitlines()
            if item.strip()
        }
        unrelated = sorted(consumers - {expected_container})
        if unrelated:
            raise ValueError(
                f"{volume_name}: 다른 컨테이너도 관리 volume을 사용 중입니다: "
                f"{', '.join(unrelated)}"
            )
        labels = volume.get("Labels") or {}
        explicit_owner = docker_label(labels, PROJECT_LABEL)
        compose_owner = docker_label(labels, COMPOSE_WORKING_DIR_LABEL)
        if explicit_owner or compose_owner:
            docker_resource_belongs_to_project(
                labels=labels,
                resource=volume_name,
                project_dir=PROJECT_DIR,
                strict=True,
            )
        else:
            if volume_name not in attached_volumes:
                raise ValueError(
                    f"{volume_name}: project label이 없는 legacy volume이며, "
                    f"현재 소유가 확인된 {expected_container}에도 연결되어 있지 않습니다."
                )


def assert_host_ownership() -> None:
    """Validate every reserved Palworld Docker name before host mutation.

    Manager labels find current containers, while global exact-name scans catch
    unlabeled legacy or foreign resources before a new project can claim the
    host. Ownership itself is always read from structured ``docker inspect``
    mappings, so commas in a valid project path cannot corrupt label parsing.
    """
    verified_servers = installed_servers(strict=True)
    try:
        container_result = run_docker(["ps", "-a", "--format", "{{.Names}}"])
        volume_result = run_docker(["volume", "ls", "--format", "{{.Name}}"])
        managed_volume_result = run_docker(
            ["volume", "ls", "--filter", f"label={MANAGER_LABEL}", "--format", "{{.Name}}"]
        )
    except FileNotFoundError:
        raise OSError("Docker CLI를 찾을 수 없습니다.") from None
    for action, result in (
        ("전체 컨테이너 이름 조회", container_result),
        ("전체 volume 이름 조회", volume_result),
        ("관리 volume 이름 조회", managed_volume_result),
    ):
        if result.returncode != 0:
            raise docker_query_error(action, result)

    reserved: set[str] = set()
    for container in container_result.stdout.splitlines():
        match = CONTAINER_RE.fullmatch(container.strip())
        if match:
            reserved.add(f"server{match.group(1)}")
    for volume_name in volume_result.stdout.splitlines():
        match = VOLUME_RE.fullmatch(volume_name.strip())
        if match:
            reserved.add(match.group(1))
    for server in sorted(reserved, key=server_sort_key):
        assert_server_ownership(server)

    # A manager-labelled volume with a non-standard name cannot be mapped to a
    # server safely and must never be silently ignored by Remove All.
    for volume_name in managed_volume_result.stdout.splitlines():
        volume_name = volume_name.strip()
        match = VOLUME_RE.fullmatch(volume_name)
        if not match:
            raise ValueError(
                f"{volume_name or 'unknown volume'}: 관리 label이 있지만 안전한 서버 volume 이름이 아닙니다."
            )

    image = docker_inspect_payload(["image", "inspect", IMAGE_NAME], IMAGE_NAME)
    if image is not None:
        image_config = image.get("Config") or {}
        image_labels = (
            (image_config.get("Labels") or {})
            if isinstance(image_config, dict)
            else {}
        )
        image_consumers_result = run_docker(
            [
                "ps",
                "-a",
                "--filter",
                f"ancestor={image.get('Id') or IMAGE_NAME}",
                "--format",
                "{{.Names}}",
            ]
        )
        if image_consumers_result.returncode != 0:
            raise docker_query_error(f"{IMAGE_NAME} 사용 컨테이너 조회", image_consumers_result)
        image_consumers = {
            item.strip()
            for item in image_consumers_result.stdout.splitlines()
            if item.strip()
        }
        verified_names = {server.container for server in verified_servers}
        unrelated_image_consumers = sorted(image_consumers - verified_names)
        if unrelated_image_consumers:
            raise ValueError(
                f"{IMAGE_NAME}: 다른 컨테이너도 관리 이미지 ID를 사용 중입니다: "
                f"{', '.join(unrelated_image_consumers)}"
            )
        image_is_used_by_verified = bool(image_consumers & verified_names)
        assert_global_project_resource_ownership(
            labels=image_labels,
            resource=IMAGE_NAME,
            legacy_evidence=image_is_used_by_verified,
        )
    network_name = "palworld_default"
    network = docker_inspect_payload(
        ["network", "inspect", network_name], network_name
    )
    if network is not None:
        endpoints = network.get("Containers") or {}
        endpoint_values = endpoints.values() if isinstance(endpoints, dict) else []
        endpoint_names = {
            str(item.get("Name", ""))
            for item in endpoint_values
            if isinstance(item, dict) and item.get("Name")
        }
        verified_names = {server.container for server in verified_servers}
        unrelated_endpoints = sorted(endpoint_names - verified_names)
        if unrelated_endpoints:
            raise ValueError(
                f"{network_name}: 다른 컨테이너도 관리 네트워크를 사용 중입니다: "
                f"{', '.join(unrelated_endpoints)}"
            )
        assert_global_project_resource_ownership(
            labels=network.get("Labels") or {},
            resource=network_name,
            legacy_evidence=bool(endpoint_names & verified_names),
        )


def reserved_server_names() -> list[str]:
    """Return every server number already represented by config, data, Docker, or volumes."""
    names = set(configured_names())
    names.update(server.name for server in installed_servers())
    if DATA_DIR.is_dir():
        names.update(
            path.name
            for path in DATA_DIR.iterdir()
            if path.is_dir() and SERVER_RE.fullmatch(path.name)
        )
    policy_root = RUNTIME_DIR / "policy"
    if policy_root.is_dir():
        names.update(
            path.name
            for path in policy_root.iterdir()
            if SERVER_RE.fullmatch(path.name)
        )
    try:
        volumes = run_docker(["volume", "ls", "--format", "{{.Name}}"])
    except FileNotFoundError:
        volumes = None
    if volumes is not None and volumes.returncode == 0:
        for volume in volumes.stdout.splitlines():
            match = VOLUME_RE.fullmatch(volume.strip())
            if match:
                names.add(match.group(1))
    return sorted(names, key=server_sort_key)


def next_server_name(existing: list[str] | None = None) -> str:
    selected = existing if existing is not None else reserved_server_names()
    used = {server_number(name) for name in selected}
    number = 1
    while number in used:
        number += 1
    return f"server{number}"


def next_setup_server_name(
    configured: list[str] | None = None,
    installed: list[InstalledServer] | None = None,
) -> str:
    """Resume the oldest config-only instance before allocating a new number.

    Setup creates ``serverN.env`` before Docker/image work begins.  A failed or
    interrupted first install must therefore retry that same instance instead
    of silently consuming another server number on every attempt.  Import uses
    :func:`next_server_name` directly and still requires a completely unused
    target, so its atomic staging contract is unchanged.
    """
    configured_names_value = configured if configured is not None else configured_names()
    installed_value = installed if installed is not None else installed_servers(strict=True)
    installed_names = {item.name for item in installed_value}
    for name in sorted(set(configured_names_value), key=server_sort_key):
        if name not in installed_names:
            return name
    return next_server_name()


def yaml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def generate_compose() -> Path:
    lines = [
        "# Generated file - do not edit directly",
        "name: palworld",
        "services:",
    ]
    names = configured_names()
    common = load_env(CONFIG_DIR / "common.env")
    manager_port = parse_port(common.get("MANAGER_API_PORT", "18080"), "MANAGER_API_PORT")
    configured: list[tuple[str, int, int, bool]] = []
    claimed_ports: dict[tuple[int, str], str] = {}
    for name in names:
        ensure_access_token(name)
        env = load_env(config_path(name))
        default_game, default_rest = default_ports(name, common)
        game_port = parse_port(env.get("SERVER_PORT", default_game), f"{name}.SERVER_PORT")
        rest_port = parse_port(
            env.get("PAL_SETTING_RESTAPIPort", default_rest),
            f"{name}.PAL_SETTING_RESTAPIPort",
        )
        expose = parse_bool(env.get("REST_API_EXPOSE", "false"), f"{name}.REST_API_EXPOSE")
        if rest_port == manager_port:
            raise ValueError(
                f"{name}.PAL_SETTING_RESTAPIPort와 MANAGER_API_PORT는 서로 달라야 합니다."
            )
        for port, protocol, label in (
            (game_port, "udp", f"{name} game"),
            (rest_port, "tcp", f"{name} integrated API"),
        ):
            key = (port, protocol)
            if key in claimed_ports:
                raise ValueError(
                    f"호스트 포트 충돌: {label}과 {claimed_ports[key]}가 모두 "
                    f"{port}/{protocol}를 사용합니다."
                )
            claimed_ports[key] = label
        configured.append((name, game_port, rest_port, expose))
    if not names:
        lines[-1] = "services: {}"
    for name, game_port, rest_port, expose in configured:
        rest_host = "0.0.0.0" if expose else "127.0.0.1"
        lines.extend(
            [
                f"  {name}:",
                f"    image: {yaml_string(IMAGE_NAME)}",
                f"    container_name: {yaml_string(container_name(name))}",
                "    restart: unless-stopped",
                "    stop_grace_period: 2m",
                "    security_opt:",
                "      - no-new-privileges:true",
                "    env_file:",
                f"      - {yaml_string(str(CONFIG_DIR / 'common.env'))}",
                f"      - {yaml_string(str(config_path(name)))}",
                "    environment:",
                f"      INSTANCE_NAME: {yaml_string(name)}",
                '      POLICY_FILE: "/palworld/policy/policy.json"',
                '      UPDATE_LOCK_FILE: "/palworld/update-lock/steam-update.lock"',
                "    labels:",
                "      io.palworld.manager: palworld-docker",
                f"      io.palworld.instance: {yaml_string(name)}",
                f"      io.palworld.project-dir: {yaml_string(str(PROJECT_DIR))}",
                "    ports:",
                f"      - {yaml_string(f'{game_port}:{game_port}/udp')}",
                f"      - {yaml_string(f'{rest_host}:{rest_port}:{manager_port}/tcp')}",
                "    volumes:",
                "      - type: volume",
                f"        source: {name}-server",
                "        target: /palworld/server",
                "      - type: volume",
                f"        source: {name}-steam",
                "        target: /home/palworld/.local/share/Steam",
                "      - type: bind",
                f"        source: {yaml_string(str(saved_path(name)))}",
                "        target: /palworld/server/Pal/Saved",
                "      - type: bind",
                f"        source: {yaml_string(str(logs_path(name)))}",
                "        target: /palworld/logs",
                "      - type: bind",
                f"        source: {yaml_string(str(policy_dir(name)))}",
                "        target: /palworld/policy",
                "      - type: bind",
                f"        source: {yaml_string(str(update_lock_dir()))}",
                "        target: /palworld/update-lock",
                "      - type: bind",
                "        source: /proc/stat",
                "        target: /host-proc-stat",
                "        read_only: true",
                "      - type: bind",
                "        source: /proc/meminfo",
                "        target: /host-proc-meminfo",
                "        read_only: true",
                "      - type: bind",
                "        source: /proc/net/dev",
                "        target: /host-proc-net-dev",
                "        read_only: true",
                "      - type: bind",
                "        source: /proc/net/route",
                "        target: /host-proc-net-route",
                "        read_only: true",
                "    healthcheck:",
                '      test: ["CMD", "palctl", "health"]',
                "      interval: 30s",
                "      timeout: 5s",
                "      retries: 3",
                "      start_period: 10m",
                "    logging:",
                "      driver: json-file",
                "      options:",
                "        max-size: 20m",
                '        max-file: "5"',
                "    ulimits:",
                "      nofile:",
                "        soft: 100000",
                "        hard: 100000",
            ]
        )
    if not names:
        lines.append("volumes: {}")
    else:
        lines.append("volumes:")
        for name in names:
            lines.extend(
                [
                    f"  {name}-server:",
                    f"    name: {yaml_string(server_volume_name(name))}",
                    "    external: true",
                    f"  {name}-steam:",
                    f"    name: {yaml_string(steam_volume_name(name))}",
                    "    external: true",
                ]
            )
    lines.extend(
        [
            "networks:",
            "  default:",
            "    labels:",
            "      io.palworld.manager: palworld-docker",
            f"      io.palworld.project-dir: {yaml_string(str(PROJECT_DIR))}",
        ]
    )
    write_atomic(COMPOSE_FILE, "\n".join(lines))
    return COMPOSE_FILE


def print_installed(output_format: str) -> None:
    servers = installed_servers(strict=True)
    if output_format == "json":
        print(json.dumps([asdict(server) for server in servers], ensure_ascii=False))
    elif output_format == "names":
        for server in servers:
            print(server.name)
    else:
        for server in servers:
            print(f"{server.name}\t{server.container}\t{server.image}\t{server.state}\t{server.status}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="팰월드 동적 서버 인스턴스 관리 보조 도구")
    subparsers = parser.add_subparsers(dest="command", required=True)
    listing = subparsers.add_parser("list")
    listing.add_argument("--format", choices=("table", "names", "json"), default="table")
    subparsers.add_parser("next")
    subparsers.add_parser("next-setup")
    create = subparsers.add_parser("create-config")
    create.add_argument("server")
    subparsers.add_parser("ensure-template")
    subparsers.add_parser("generate-compose")
    remove = subparsers.add_parser("remove-config")
    remove.add_argument("server")
    access_token = subparsers.add_parser("access-token")
    access_token.add_argument("server")
    rotate_token = subparsers.add_parser("rotate-token")
    rotate_token.add_argument("server")
    info = subparsers.add_parser("connection-info")
    info.add_argument("server")
    info.add_argument("--format", choices=("text", "json"), default="text")
    port_preflight = subparsers.add_parser("preflight-host-ports")
    port_preflight.add_argument("server")
    subparsers.add_parser("assert-host-ownership")
    ownership = subparsers.add_parser("assert-server-ownership")
    ownership.add_argument("server")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "list":
            print_installed(args.format)
        elif args.command == "next":
            print(next_server_name())
        elif args.command == "next-setup":
            print(next_setup_server_name())
        elif args.command == "create-config":
            path, created = create_config(args.server)
            print(json.dumps({"path": str(path), "created": created}, ensure_ascii=False))
        elif args.command == "ensure-template":
            print(ensure_template())
        elif args.command == "generate-compose":
            print(generate_compose())
        elif args.command == "remove-config":
            path = config_path(args.server)
            path.unlink(missing_ok=True)
            print(path)
        elif args.command == "access-token":
            print(read_access_token(args.server))
        elif args.command == "rotate-token":
            print(rotate_access_token(args.server))
        elif args.command == "connection-info":
            print_connection_info(args.server, args.format)
        elif args.command == "preflight-host-ports":
            print(json.dumps(preflight_host_ports(args.server), ensure_ascii=False))
        elif args.command == "assert-host-ownership":
            assert_host_ownership()
        elif args.command == "assert-server-ownership":
            assert_server_ownership(args.server)
        return 0
    except (OSError, ValueError) as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
