#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
    cat <<'EOF'
사용법: sudo bash install/setup.sh [--server serverN | --next] [--test-timeout 초] [--prepare-only]

  옵션 없음          의존성을 준비하고 server1 설치·시작·검사
  --server serverN   지정한 번호의 서버 설치·시작·검사
  --next             미완료 config-only 서버를 재개하거나 다음 빈 번호를 설치
  --test-timeout 초  첫 설치 완료를 기다릴 최대 시간(기본 1200초)
  --prepare-only     공통 호스트 도구와 Docker만 준비하고 서버는 만들지 않음
EOF
}

server=server1
select_next_server=false
explicit_server_requested=false
test_timeout=1200
prepare_only=false
while (( $# > 0 )); do
    case "$1" in
        --server)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            server="$2"
            explicit_server_requested=true
            shift 2
            ;;
        --next)
            select_next_server=true
            shift
            ;;
        --test-timeout)
            [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
            test_timeout="$2"
            shift 2
            ;;
        --prepare-only)
            prepare_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

if ! validate_server_name "$server"; then
    echo "오류: --server 값은 serverN 형식이어야 합니다. 예: server3" >&2
    exit 2
fi

if [[ "$select_next_server" == true && "$explicit_server_requested" == true ]]; then
    echo "오류: --server와 --next는 함께 사용할 수 없습니다." >&2
    exit 2
fi

if [[ "$(uname -s)" != Linux ]]; then
    echo "오류: install/setup.sh는 Linux 호스트에서만 실행할 수 있습니다." >&2
    exit 1
fi

if (( EUID != 0 )); then
    echo "오류: 시스템 시간대와 패키지를 설정하려면 관리자 권한이 필요합니다." >&2
    echo "다음처럼 실행하세요: sudo bash install/setup.sh --server $server" >&2
    exit 1
fi

architecture="$(uname -m)"
case "$architecture" in
    x86_64|amd64) ;;
    *)
        echo "오류: 현재 팰월드 컨테이너는 x86-64 환경을 기준으로 합니다. 현재 아키텍처: $architecture" >&2
        exit 1
        ;;
esac

if [[ ! -r /etc/os-release ]]; then
    echo "오류: Linux 배포판 정보를 확인할 수 없습니다: /etc/os-release" >&2
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        echo "오류: 자동 설치는 Ubuntu와 Debian만 지원합니다. 현재 배포판: ${ID:-unknown}" >&2
        exit 1
        ;;
esac

apt_updated=false
apt_update_once() {
    if [[ "$apt_updated" == false ]]; then
        apt-get update
        apt_updated=true
    fi
}

install_base_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    dpkg-query -W -f='${Status}' tzdata 2>/dev/null | grep -q 'install ok installed' || missing+=(tzdata)
    dpkg-query -W -f='${Status}' ca-certificates 2>/dev/null | grep -q 'install ok installed' || missing+=(ca-certificates)

    if (( ${#missing[@]} > 0 )); then
        echo "필수 패키지를 설치합니다: ${missing[*]}"
        apt_update_once
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        echo "필수 패키지 확인 완료: curl, python3, ca-certificates, tzdata"
    fi
    if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
        echo "오류: Python 3.9 이상이 필요합니다. 현재 배포판의 python3를 업그레이드하세요." >&2
        exit 1
    fi
}

read_common_value() {
    local key="$1"
    local file="$PALWORLD_PROJECT_DIR/config/common.env"
    [[ -f "$file" ]] || return 0
    awk -F= -v wanted="$key" '
        {
            candidate=$1
            gsub(/^[ \t]+|[ \t]+$/, "", candidate)
            if (candidate == wanted) {
                sub(/^[^=]*=/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                if (($0 ~ /^".*"$/) || ($0 ~ /^\047.*\047$/)) {
                    print substr($0, 2, length($0) - 2)
                } else {
                    print
                }
                exit
            }
        }
    ' "$file"
}

configure_timezone() {
    local current="" desired_timezone=""
    desired_timezone="$(read_common_value TZ)"
    [[ -n "$desired_timezone" ]] || desired_timezone=Asia/Seoul
    if [[ ! "$desired_timezone" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] \
        || [[ "$desired_timezone" =~ (^|/)\.{1,2}(/|$) ]] \
        || [[ ! -f "/usr/share/zoneinfo/$desired_timezone" ]]; then
        echo "오류: config/common.env의 TZ가 유효한 IANA 시간대가 아닙니다: $desired_timezone" >&2
        exit 1
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        current="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "$current" && -r /etc/timezone ]]; then
        current="$(tr -d '[:space:]' </etc/timezone)"
    fi

    if [[ "$current" == "$desired_timezone" ]]; then
        echo "호스트 시간대 확인 완료: $desired_timezone"
        return
    fi

    echo "호스트 시간대를 common.env 기준으로 변경합니다: ${current:-unknown} -> $desired_timezone"
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$desired_timezone" 2>/dev/null; then
        :
    else
        ln -snf "/usr/share/zoneinfo/$desired_timezone" /etc/localtime
        printf '%s\n' "$desired_timezone" >/etc/timezone
    fi
    echo "호스트 현재 시각: $(date '+%Y-%m-%d %H:%M:%S %Z %z')"
}

configure_docker_repository() {
    local repository_url="https://download.docker.com/linux/${ID}"
    local suite="${VERSION_CODENAME:-}"
    if [[ "$ID" == ubuntu ]]; then
        suite="${UBUNTU_CODENAME:-$suite}"
    fi
    [[ -n "$suite" ]] || { echo "오류: 배포판 코드명을 확인할 수 없습니다." >&2; exit 1; }

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "$repository_url/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf '%s\n' \
        'Types: deb' \
        "URIs: $repository_url" \
        "Suites: $suite" \
        'Components: stable' \
        "Architectures: $(dpkg --print-architecture)" \
        'Signed-By: /etc/apt/keyrings/docker.asc' \
        >/etc/apt/sources.list.d/docker.sources
    apt_updated=false
}

install_docker_if_needed() {
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        echo "Docker Engine과 Compose 플러그인 확인 완료"
        return
    fi

    echo "Docker Engine 또는 Compose 플러그인이 없어 공식 저장소에서 설치합니다."
    configure_docker_repository
    apt_update_once
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    else
        service docker start
    fi
    docker info >/dev/null
    docker compose version
}

configure_docker_user() {
    local target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" || "$target_user" == root ]]; then
        echo "안내: 원래 일반 사용자를 확인할 수 없어 docker 그룹 추가를 건너뜁니다."
        return
    fi
    getent group docker >/dev/null 2>&1 || groupadd docker
    if id -nG "$target_user" | tr ' ' '\n' | grep -qx docker; then
        echo "Docker 사용자 권한 확인 완료: $target_user"
    else
        usermod -aG docker "$target_user"
        echo "사용자 '$target_user'를 docker 그룹에 추가했습니다. 새 권한은 다시 로그인한 뒤 적용됩니다."
        echo "주의: docker 그룹은 사실상 호스트 관리자 권한을 가집니다."
    fi
}

ensure_server_volume() {
    local server="$1"
    local server_volume="palworld-$server-server"
    docker volume create \
        --label io.palworld.manager=palworld-docker \
        --label "io.palworld.instance=$server" \
        --label "io.palworld.project-dir=$PALWORLD_PROJECT_DIR" \
        --label io.palworld.role=server-files \
        "$server_volume" >/dev/null
}

preflight_server_volume_space() {
    local server="$1"
    local server_volume="palworld-$server-server"
    local probe="" files_state="" free_bytes="" total_bytes=""
    local free_gib="" total_gib=""
    local fresh_install_min_bytes=$((12 * 1024 * 1024 * 1024))
    local existing_update_min_bytes=$((4 * 1024 * 1024 * 1024))

    validate_server_name "$server" || {
        echo "오류: 저장공간 검사 대상 서버 이름이 잘못되었습니다: $server" >&2
        return 2
    }
    if ! probe="$(
        docker run --rm \
            --user 0:0 \
            --entrypoint python3 \
            --volume "$server_volume:/volume" \
            "$PALWORLD_IMAGE" \
            -c 'import os, shutil
usage = shutil.disk_usage("/volume")
ready = all(os.path.isfile(path) for path in (
    "/volume/PalServer.sh",
    "/volume/DefaultPalWorldSettings.ini",
))
print(
    "ready" if ready else "missing",
    usage.free,
    usage.total,
    f"{usage.free / 1024**3:.2f}",
    f"{usage.total / 1024**3:.2f}",
)' \
    )"; then
        echo "오류: $server Docker 게임 파일 볼륨의 저장공간을 확인하지 못했습니다." >&2
        return 1
    fi
    read -r files_state free_bytes total_bytes free_gib total_gib <<<"$probe"
    if [[ "$files_state" != ready && "$files_state" != missing ]] \
        || [[ ! "$free_bytes" =~ ^[0-9]+$ || ! "$total_bytes" =~ ^[0-9]+$ ]] \
        || [[ ! "$free_gib" =~ ^[0-9]+([.][0-9]+)?$ || ! "$total_gib" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "오류: $server Docker 게임 파일 볼륨의 저장공간 검사 결과가 잘못되었습니다: $probe" >&2
        return 1
    fi

    if [[ "$files_state" == missing ]] && (( free_bytes < fresh_install_min_bytes )); then
        echo "오류: $server SteamCMD 최초 설치 전에 Docker 게임 파일 볼륨에 12 GiB 이상의 여유 공간이 필요합니다." >&2
        echo "현재 사용 가능 ${free_gib} GiB / 전체 ${total_gib} GiB. 기존 컨테이너는 변경하지 않았습니다." >&2
        return 1
    fi
    if [[ "$files_state" == ready ]] && (( free_bytes < existing_update_min_bytes )); then
        echo "오류: $server 갱신 전에 Docker 게임 파일 볼륨에 최소 4 GiB의 여유 공간이 필요합니다." >&2
        echo "현재 사용 가능 ${free_gib} GiB / 전체 ${total_gib} GiB. 기존 컨테이너는 변경하지 않았습니다." >&2
        return 1
    fi
    if (( free_bytes < fresh_install_min_bytes )); then
        echo "[WARN] $server Docker 게임 파일 저장공간이 적습니다: 사용 가능 ${free_gib} GiB / 전체 ${total_gib} GiB"
        echo "[WARN] 기존 설치 갱신은 계속하지만 대규모 Steam 업데이트 전에 12 GiB 이상 확보하는 것을 권장합니다."
    else
        echo "[PASS] $server Docker 게임 파일 저장공간: 사용 가능 ${free_gib} GiB / 전체 ${total_gib} GiB"
    fi
}

prepare_server_data() {
    local server="$1"
    local container="palworld-$server"
    local legacy_volume="palworld-$server-data"
    local server_volume="palworld-$server-server"
    local data_dir="$PALWORLD_PROJECT_DIR/data/$server"
    local saved_dir="$data_dir/saved"
    local logs_dir="$data_dir/logs"
    local policy_dir="$PALWORLD_PROJECT_DIR/runtime/policy/$server"
    local legacy_server_dir="$data_dir/server"
    local legacy_saved_dir="$legacy_server_dir/Pal/Saved"
    local can_remove_legacy_server=true
    local had_container=false
    local was_running=false
    local server_files_missing=false
    local status_json="" game_state=""
    local container_id="" inspect_output="" inspect_detail=""

    install -d -m 0755 "$PALWORLD_PROJECT_DIR/data"
    install -d -m 0700 "$data_dir" "$saved_dir" "$logs_dir"

    # Validate or migrate the persistent policy before stopping an existing
    # game. A damaged policy must never turn a safe Manage into downtime.
    prepare_server_policy_storage "$server" "$PALWORLD_UID" "$PALWORLD_GID"
    if inspect_output="$(docker container inspect --format '{{.Id}}' "$container" 2>&1)"; then
        container_id="$inspect_output"
        [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] || {
            echo "오류: $container Docker inspect가 잘못된 immutable ID를 반환했습니다." >&2
            return 1
        }
        python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" \
            assert-server-ownership "$server"
        had_container=true
        if [[ "$(docker inspect --format '{{.State.Running}}' "$container_id")" == true ]]; then
            was_running=true
            echo "$server 기존 컨테이너를 안전하게 정지합니다."
            if ! status_json="$(docker exec "$container_id" palctl status 2>/dev/null)"; then
                echo "오류: $server 게임 상태를 확인할 수 없어 실행 중인 컨테이너를 변경하지 않습니다." >&2
                echo "잠시 후 다시 시도하거나 Runtime Logs에서 관리 API 상태를 확인하세요." >&2
                return 1
            fi
            game_state="$(python3 -c '
import json
import sys

status = json.load(sys.stdin)
game = status.get("game")
if not isinstance(game, str) or not game:
    raise SystemExit(1)
print(game)
' <<<"$status_json" 2>/dev/null)" || {
                echo "오류: $server 관리 API가 잘못된 게임 상태를 반환해 컨테이너를 변경하지 않습니다." >&2
                return 1
            }
            case "$game_state" in
                running)
                    if ! docker exec "$container_id" palctl save >/dev/null 2>&1; then
                        echo "오류: $server 월드 저장에 실패해 실행 중인 컨테이너를 변경하지 않습니다." >&2
                        return 1
                    fi
                    ;;
                stopped|policy-blocked|update-failed|restart-wait|crash-wait) ;;
                *)
                    echo "오류: $server 게임이 '$game_state' 전환 상태라 Setup을 시작하지 않습니다. 상태가 안정된 뒤 다시 시도하세요." >&2
                    return 1
                    ;;
            esac
            docker stop --time 120 "$container_id" >/dev/null
        fi
        if ! python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" \
            preflight-host-ports "$server" >/dev/null; then
            if [[ "$was_running" == true ]]; then
                echo "[WARN] 새 포트 사전 검사 실패로 기존 $server 컨테이너를 다시 시작합니다." >&2
                if ! docker start "$container_id" >/dev/null; then
                    echo "오류: 기존 $server 컨테이너 재시작에도 실패했습니다. Docker 상태와 Runtime Logs를 확인하세요." >&2
                fi
            fi
            return 1
        fi
    else
        inspect_detail="${inspect_output,,}"
        if [[ "$inspect_detail" != *"no such"* && "$inspect_detail" != *"not found"* ]]; then
            echo "오류: $container Docker 상태를 확인하지 못했습니다: $inspect_output" >&2
            return 1
        fi
    fi
    if [[ "$had_container" == true ]]; then
        docker rm "$container_id" >/dev/null
    fi

    if [[ -d "$legacy_saved_dir" && -n "$(find "$legacy_saved_dir" -mindepth 1 -print -quit)" ]]; then
        if [[ -z "$(find "$saved_dir" -mindepth 1 -print -quit)" ]]; then
            echo "$server 기존 bind 데이터의 Pal/Saved를 data/$server/saved로 이전합니다."
            cp -a "$legacy_saved_dir/." "$saved_dir/"
        else
            echo "주의: 기존 $legacy_saved_dir 및 $saved_dir 양쪽에 데이터가 있어 자동 병합하지 않습니다." >&2
            echo "기존 server 디렉터리를 유지하므로 설치 후 내용을 직접 비교하세요." >&2
            can_remove_legacy_server=false
        fi
    fi
    if [[ -d "$legacy_server_dir" && "$can_remove_legacy_server" == true ]]; then
        rm -rf -- "$legacy_server_dir"
        echo "$server 이전 bind 방식의 재설치 가능한 서버 파일을 정리했습니다."
    fi

    if docker volume inspect "$legacy_volume" >/dev/null 2>&1; then
        if [[ -z "$(find "$saved_dir" -mindepth 1 -print -quit)" ]]; then
            echo "$server 기존 Docker 볼륨에서 Pal/Saved를 data/$server/saved로 이전합니다."
            docker run --rm \
                --user 0:0 \
                --entrypoint /bin/sh \
                --volume "$legacy_volume:/source:ro" \
                --volume "$saved_dir:/destination" \
                "$PALWORLD_IMAGE" \
                -c 'set -eu; if [ -d /source/server/Pal/Saved ]; then cp -a /source/server/Pal/Saved/. /destination/; elif [ -d /source/Pal/Saved ]; then cp -a /source/Pal/Saved/. /destination/; fi'
            docker volume rm "$legacy_volume" >/dev/null
        else
            echo "주의: $legacy_volume 및 $saved_dir 양쪽에 데이터가 있어 기존 볼륨을 유지합니다." >&2
        fi
    fi

    ensure_server_volume "$server"
    if ! docker run --rm \
        --user 0:0 \
        --entrypoint /bin/sh \
        --volume "$server_volume:/volume" \
        "$PALWORLD_IMAGE" \
        -c 'test -f /volume/PalServer.sh && test -f /volume/DefaultPalWorldSettings.ini'; then
        server_files_missing=true
    fi
    docker run --rm \
        --user 0:0 \
        --entrypoint /bin/sh \
        --volume "$server_volume:/volume" \
        "$PALWORLD_IMAGE" \
        -c "set -eu; mkdir -p /volume/Pal/Saved; chown -R $PALWORLD_UID:$PALWORLD_GID /volume"

    chown -R "$PALWORLD_UID:$PALWORLD_GID" "$data_dir" "$policy_dir"
    chmod 0700 "$data_dir" "$saved_dir" "$logs_dir"
    echo "$server 서버 볼륨 및 Saved bind mount 쓰기 사전 검사를 실행합니다."
    docker run --rm \
        --user "$PALWORLD_UID:$PALWORLD_GID" \
        --entrypoint /bin/sh \
        --volume "$server_volume:/palworld/server" \
        --volume "$saved_dir:/palworld/server/Pal/Saved" \
        --volume "$logs_dir:/palworld/logs" \
        --volume "$policy_dir:/palworld/policy" \
        "$PALWORLD_IMAGE" \
        -c 'set -eu; printf "volume-ok\n" > /palworld/server/.manager-volume-test; grep -qx volume-ok /palworld/server/.manager-volume-test; rm /palworld/server/.manager-volume-test; rmdir /palworld/server/Pal/.manager-pal-test 2>/dev/null || true; mkdir /palworld/server/Pal/.manager-pal-test; rmdir /palworld/server/Pal/.manager-pal-test; printf "saved-ok\n" > /palworld/server/Pal/Saved/.manager-bind-test; grep -qx saved-ok /palworld/server/Pal/Saved/.manager-bind-test; rm /palworld/server/Pal/Saved/.manager-bind-test; printf "logs-ok\n" > /palworld/logs/.manager-log-test; grep -qx logs-ok /palworld/logs/.manager-log-test; rm /palworld/logs/.manager-log-test; printf "policy-ok\n" > /palworld/policy/.manager-policy-test; grep -qx policy-ok /palworld/policy/.manager-policy-test; rm /palworld/policy/.manager-policy-test'

    echo "$server 서버 파일 볼륨 준비 완료: $server_volume"
    if [[ "$server_files_missing" == true ]]; then
        echo "[INFO] $server 게임 파일이 아직 없는 볼륨입니다. 가져온 Pal/Saved와 별개로 SteamCMD가 팰월드 서버 파일 전체를 설치합니다."
    fi
    echo "$server 월드·설정 경로 준비 완료: $saved_dir"
    echo "$server 런타임 로그 경로 준비 완료: $logs_dir"
    echo "$server 운영 정책 경로 준비 완료: $policy_dir"
}

assert_palworld_host_project_claim_available
install_base_dependencies
install_docker_if_needed
start_docker
register_palworld_host_project
acquire_palworld_project_operation_lock
configure_timezone
configure_docker_user

if [[ "$prepare_only" == true ]]; then
    echo "호스트 준비 완료: 공통 도구, common.env 시간대, Docker Engine과 Compose"
    exit 0
fi

if [[ "$select_next_server" == true ]]; then
    server="$(python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" next-setup)"
    if [[ -f "$PALWORLD_PROJECT_DIR/config/$server.env" ]]; then
        echo "[INFO] 이전 Setup에서 남은 config-only $server 설치를 재개합니다."
    else
        echo "[INFO] 신규 서버 번호를 선택했습니다: $server"
    fi
fi
python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" assert-server-ownership "$server"
echo "PALWORLD_SETUP_SERVER=$server"

cd "$PALWORLD_PROJECT_DIR"
chmod +x \
    "$PALWORLD_INSTALL_DIR/setup.sh" \
    "$PALWORLD_INSTALL_DIR/manager" \
    "$PALWORLD_INSTALL_DIR/test" \
    "$PALWORLD_INSTALL_DIR/lib.sh" \
    "$PALWORLD_PROJECT_DIR/operate/pal"

python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" ensure-template >/dev/null
python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" create-config "$server" >/dev/null
chmod 0600 "$PALWORLD_PROJECT_DIR/config/$server.env"
if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "${SUDO_GID:-}" =~ ^[0-9]+$ ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$PALWORLD_PROJECT_DIR/config/$server.env"
fi
echo "$server 설정 준비: $PALWORLD_PROJECT_DIR/config/$server.env"
echo "$server 설정을 검사합니다."
python3 -B "$PALWORLD_INSTALL_DIR/scripts/doctor.py" --config-only --server "$server"

ensure_server_volume "$server"
echo "팰월드 서버 이미지를 빌드합니다."
docker build \
    --pull \
    --build-arg "PALWORLD_PROJECT_DIR=$PALWORLD_PROJECT_DIR" \
    --build-arg "PALWORLD_UID=$PALWORLD_UID" \
    --build-arg "PALWORLD_GID=$PALWORLD_GID" \
    --tag "$PALWORLD_IMAGE" \
    "$PALWORLD_INSTALL_DIR"

# Validate the generated Compose model before an existing container is stopped
# or removed. This catches malformed environment and mount configuration while
# the previous service can still remain available.
palworld_compose config --quiet

preflight_server_volume_space "$server"
python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" \
    preflight-host-ports "$server" >/dev/null
prepare_shared_update_storage "$PALWORLD_UID" "$PALWORLD_GID"
preflight_shared_update_storage "$PALWORLD_UID" "$PALWORLD_GID"
prepare_server_data "$server"
echo "$server 컨테이너를 시작합니다."
palworld_compose up -d --no-build "$server"

echo "설치 후 종합 검사를 시작합니다. 첫 설치에서는 SteamCMD 다운로드 때문에 시간이 걸릴 수 있습니다."
if python3 -B "$PALWORLD_INSTALL_DIR/scripts/doctor.py" \
    --server "$server" --wait "$test_timeout" --after-change; then
    echo
    echo "설치와 검사가 완료되었습니다. 서버는 현재 운영 시간과 기존 수동 정책에 맞는 상태입니다."
    echo "운영 시간 안이면 실행을 유지하고, 운영 시간 밖 또는 수동 정지 정책이면 정지 상태로 복귀합니다."
    echo "다시 검사: 설치 프로그램 실행 후 Test에서 $server 선택"
    echo
    echo "$server Windows 프로그램 연결 정보:"
    python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" connection-info "$server"
    echo "저장 위치: $PALWORLD_PROJECT_DIR/config/$server.env 및 config/common.env"
    echo "주의: 관리자 비밀번호와 API token이 평문으로 출력되었습니다. 로그와 화면 공유 시 가리세요."
    echo "나중에 확인·재발급: 설치 프로그램 → Manage → API access token 확인·재발급"
else
    echo
    echo "설치는 실행했지만 검사에서 문제가 발견되었습니다. 컨테이너는 원인 확인을 위해 유지합니다." >&2
    echo "로그 확인: docker logs --tail 200 palworld-$server" >&2
    exit 1
fi
