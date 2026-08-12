#!/usr/bin/env bash

# Shared host-side helpers for the Linux setup, manager, and Compose wrapper.

PALWORLD_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PALWORLD_PROJECT_DIR="${PALWORLD_PROJECT_DIR:-$(cd -- "$PALWORLD_SCRIPT_DIR/.." && pwd -P)}"
PALWORLD_PROJECT_DIR="$(cd -- "$PALWORLD_PROJECT_DIR" && pwd -P)"
PALWORLD_INSTALL_DIR="$PALWORLD_SCRIPT_DIR"
PYTHONDONTWRITEBYTECODE=1
export PALWORLD_PROJECT_DIR PALWORLD_INSTALL_DIR PYTHONDONTWRITEBYTECODE

# Match the container account to the owner of this project directory. This
# keeps host-mounted worlds manageable by the SSH account and avoids assigning
# them to an unrelated host user that happens to own UID 1000. A scaffold may
# temporarily be root-owned, so prefer the original sudo caller before using
# the historical 1000:1000 fallback.
select_palworld_runtime_id() {
    local project_id="${1:-}"
    local sudo_id="${2:-}"

    if [[ "$project_id" =~ ^[0-9]+$ ]] && (( project_id >= 1000 )); then
        printf '%s\n' "$project_id"
    elif [[ "$sudo_id" =~ ^[0-9]+$ ]] && (( sudo_id >= 1000 )); then
        printf '%s\n' "$sudo_id"
    else
        printf '1000\n'
    fi
}

PALWORLD_PROJECT_UID="$(stat -c '%u' -- "$PALWORLD_PROJECT_DIR")"
PALWORLD_PROJECT_GID="$(stat -c '%g' -- "$PALWORLD_PROJECT_DIR")"
PALWORLD_UID="$(select_palworld_runtime_id "$PALWORLD_PROJECT_UID" "${SUDO_UID:-}")"
PALWORLD_GID="$(select_palworld_runtime_id "$PALWORLD_PROJECT_GID" "${SUDO_GID:-}")"
PALWORLD_IMAGE="local/palworld-dedicated-server:uid${PALWORLD_UID}-gid${PALWORLD_GID}"
PALWORLD_RUNTIME_LAYOUT="policy-bind-v1+update-lock-v1+steam-state-v1"
PALWORLD_RUNTIME_DIR="$PALWORLD_PROJECT_DIR/runtime"
PALWORLD_COMPOSE_FILE="$PALWORLD_RUNTIME_DIR/compose.yaml"
PALWORLD_PROJECT_OPERATION_LOCK_FD=""
PALWORLD_HOST_PROJECT_REGISTRY_DIR="/var/lib/palworld-server-operations"
PALWORLD_HOST_PROJECT_REGISTRY_FILE="$PALWORLD_HOST_PROJECT_REGISTRY_DIR/project-dir"
PALWORLD_HOST_OPERATION_LOCK_FILE="$PALWORLD_HOST_PROJECT_REGISTRY_DIR/operation.lock"
PALWORLD_HOST_OPERATION_LOCK_FD=""
export PALWORLD_UID PALWORLD_GID PALWORLD_IMAGE

validate_server_name() {
    [[ "${1:-}" =~ ^server[1-9][0-9]*$ ]]
}

read_palworld_host_project_registration() {
    local registry_file="$PALWORLD_HOST_PROJECT_REGISTRY_FILE"
    if [[ -L "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" || -L "$registry_file" ]] \
        || [[ -e "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" && ! -d "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" ]] \
        || [[ -e "$registry_file" && ! -f "$registry_file" ]]; then
        echo "오류: Docker 호스트 프로젝트 등록 경로가 안전하지 않습니다: $registry_file" >&2
        return 1
    fi
    [[ -f "$registry_file" ]] || return 3
    if [[ "$(stat -c '%u' -- "$PALWORLD_HOST_PROJECT_REGISTRY_DIR")" != 0 ]] \
        || [[ "$(stat -c '%u' -- "$registry_file")" != 0 ]]; then
        echo "오류: Docker 호스트 프로젝트 등록 파일은 root 소유여야 합니다: $registry_file" >&2
        return 1
    fi
    local registered=""
    IFS= read -r registered <"$registry_file" || true
    if [[ -z "$registered" || "$registered" != /* ]] \
        || [[ "$(wc -l <"$registry_file")" -ne 1 ]]; then
        echo "오류: Docker 호스트 프로젝트 등록 파일 형식이 잘못되었습니다: $registry_file" >&2
        return 1
    fi
    printf '%s\n' "$registered"
}

assert_palworld_host_project_claim_available() {
    local registered=""
    local status=0
    registered="$(read_palworld_host_project_registration)" || status=$?
    if (( status == 3 )); then
        return 0
    fi
    (( status == 0 )) || return 1
    if [[ "$registered" != "$PALWORLD_PROJECT_DIR" ]]; then
        echo "오류: 이 Docker 호스트에는 이미 다른 관리 프로젝트가 등록되어 있습니다." >&2
        echo "등록 프로젝트: $registered" >&2
        echo "현재 프로젝트: $PALWORLD_PROJECT_DIR" >&2
        return 1
    fi
}

assert_palworld_host_project_owner() {
    local registered=""
    local status=0
    registered="$(read_palworld_host_project_registration)" || status=$?
    if (( status != 0 )); then
        if (( status == 3 )); then
            echo "오류: 이 Docker 호스트에 관리 프로젝트가 아직 등록되지 않았습니다." >&2
            echo "먼저 현재 작업 디렉터리에서 Setup을 실행하세요: $PALWORLD_PROJECT_DIR" >&2
        fi
        return 1
    fi
    if [[ "$registered" != "$PALWORLD_PROJECT_DIR" ]]; then
        echo "오류: 이 Docker 호스트는 다른 Palworld Server Operations 프로젝트가 소유합니다." >&2
        echo "등록 프로젝트: $registered" >&2
        echo "현재 프로젝트: $PALWORLD_PROJECT_DIR" >&2
        echo "컨테이너와 volume 충돌을 막기 위해 작업을 중단했습니다." >&2
        return 1
    fi
    python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" assert-host-ownership
}

register_palworld_host_project() {
    (( EUID == 0 )) || {
        echo "오류: Docker 호스트 프로젝트 등록에는 root 권한이 필요합니다." >&2
        return 1
    }
    [[ "$PALWORLD_PROJECT_DIR" != *$'\n'* && "$PALWORLD_PROJECT_DIR" != *$'\r'* ]] || {
        echo "오류: 프로젝트 경로에 줄바꿈 문자를 사용할 수 없습니다." >&2
        return 1
    }
    if [[ -L "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" ]] \
        || [[ -e "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" && ! -d "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" ]]; then
        echo "오류: Docker 호스트 프로젝트 등록 경로가 안전하지 않습니다: $PALWORLD_HOST_PROJECT_REGISTRY_DIR" >&2
        return 1
    fi
    install -d -o root -g root -m 0755 "$PALWORLD_HOST_PROJECT_REGISTRY_DIR"
    [[ "$(stat -c '%u' -- "$PALWORLD_HOST_PROJECT_REGISTRY_DIR")" == 0 ]] || {
        echo "오류: Docker 호스트 프로젝트 등록 디렉터리는 root 소유여야 합니다." >&2
        return 1
    }
    acquire_palworld_host_operation_lock
    local lock_file="$PALWORLD_HOST_PROJECT_REGISTRY_DIR/registry.lock"
    local lock_fd=""
    local registered=""
    local temporary=""
    if [[ -L "$lock_file" || ( -e "$lock_file" && ! -f "$lock_file" ) ]]; then
        echo "오류: Docker 호스트 프로젝트 등록 잠금이 안전하지 않습니다: $lock_file" >&2
        return 1
    fi
    ( umask 0077; : >>"$lock_file" )
    chown root:root "$lock_file"
    chmod 0600 "$lock_file"
    exec {lock_fd}>>"$lock_file"
    flock -x "$lock_fd"
    if ! python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" assert-host-ownership; then
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi
    if [[ -e "$PALWORLD_HOST_PROJECT_REGISTRY_FILE" || -L "$PALWORLD_HOST_PROJECT_REGISTRY_FILE" ]]; then
        if ! registered="$(read_palworld_host_project_registration)"; then
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            return 1
        fi
        if [[ "$registered" != "$PALWORLD_PROJECT_DIR" ]]; then
            flock -u "$lock_fd"
            exec {lock_fd}>&-
            echo "오류: 이 Docker 호스트에는 이미 다른 관리 프로젝트가 등록되어 있습니다." >&2
            echo "등록 프로젝트: $registered" >&2
            echo "현재 프로젝트: $PALWORLD_PROJECT_DIR" >&2
            return 1
        fi
    else
        temporary="$(mktemp "$PALWORLD_HOST_PROJECT_REGISTRY_DIR/.project-dir.XXXXXXXX")"
        printf '%s\n' "$PALWORLD_PROJECT_DIR" >"$temporary"
        chown root:root "$temporary"
        chmod 0644 "$temporary"
        mv -f -- "$temporary" "$PALWORLD_HOST_PROJECT_REGISTRY_FILE"
        echo "[PASS] Docker 호스트 관리 프로젝트 등록: $PALWORLD_PROJECT_DIR"
    fi
    # Remove Project intentionally preserves this host-wide lock. Normalize its
    # group only after the registry claim is confirmed, so a later project with
    # a different owner GID can use non-root Test/operate commands without a
    # losing claim changing the active owner's permissions.
    chown root:"$PALWORLD_GID" "$PALWORLD_HOST_OPERATION_LOCK_FILE"
    chmod 0660 "$PALWORLD_HOST_OPERATION_LOCK_FILE"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
}

acquire_palworld_host_operation_lock() {
    if [[ -n "$PALWORLD_HOST_OPERATION_LOCK_FD" ]]; then
        return 0
    fi
    command -v flock >/dev/null 2>&1 || {
        echo "오류: 호스트 관리 작업 잠금에 필요한 flock 명령을 찾을 수 없습니다." >&2
        return 1
    }
    if [[ -L "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" \
        || ( -e "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" && ! -d "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" ) \
        || -L "$PALWORLD_HOST_OPERATION_LOCK_FILE" \
        || ( -e "$PALWORLD_HOST_OPERATION_LOCK_FILE" && ! -f "$PALWORLD_HOST_OPERATION_LOCK_FILE" ) ]]; then
        echo "오류: 호스트 관리 작업 잠금 경로가 안전하지 않습니다: $PALWORLD_HOST_OPERATION_LOCK_FILE" >&2
        return 1
    fi
    if [[ -d "$PALWORLD_HOST_PROJECT_REGISTRY_DIR" \
        && "$(stat -c '%u' -- "$PALWORLD_HOST_PROJECT_REGISTRY_DIR")" != 0 ]]; then
        echo "오류: 호스트 관리 작업 잠금 디렉터리는 root 소유여야 합니다: $PALWORLD_HOST_PROJECT_REGISTRY_DIR" >&2
        return 1
    fi
    if [[ ! -e "$PALWORLD_HOST_OPERATION_LOCK_FILE" ]]; then
        (( EUID == 0 )) || {
            echo "오류: 호스트 관리 작업 잠금이 아직 준비되지 않았습니다. 먼저 Setup 또는 Manage를 실행하세요." >&2
            return 1
        }
        install -d -o root -g root -m 0755 "$PALWORLD_HOST_PROJECT_REGISTRY_DIR"
        # Create the stable lock inode once. Concurrent first Setup processes
        # must never truncate or re-own a lock another project already holds.
        ( set -o noclobber; umask 0077; : >"$PALWORLD_HOST_OPERATION_LOCK_FILE" ) \
            2>/dev/null || true
    fi
    [[ "$(stat -c '%u' -- "$PALWORLD_HOST_PROJECT_REGISTRY_DIR")" == 0 \
        && "$(stat -c '%u' -- "$PALWORLD_HOST_OPERATION_LOCK_FILE")" == 0 ]] || {
        echo "오류: 호스트 관리 작업 잠금은 root 소유여야 합니다: $PALWORLD_HOST_OPERATION_LOCK_FILE" >&2
        return 1
    }
    exec {PALWORLD_HOST_OPERATION_LOCK_FD}>>"$PALWORLD_HOST_OPERATION_LOCK_FILE"
    if ! flock -n "$PALWORLD_HOST_OPERATION_LOCK_FD"; then
        exec {PALWORLD_HOST_OPERATION_LOCK_FD}>&-
        PALWORLD_HOST_OPERATION_LOCK_FD=""
        echo "오류: 다른 Palworld Setup/Manage 작업이 이 Docker 호스트에서 진행 중입니다. 완료 후 다시 실행하세요." >&2
        return 1
    fi
}

release_palworld_host_project_registration() {
    (( EUID == 0 )) || return 1
    local lock_file="$PALWORLD_HOST_PROJECT_REGISTRY_DIR/registry.lock"
    local lock_fd=""
    if [[ -L "$lock_file" || ! -f "$lock_file" ]]; then
        echo "오류: Docker 호스트 프로젝트 등록 잠금이 안전하지 않습니다: $lock_file" >&2
        return 1
    fi
    exec {lock_fd}>>"$lock_file"
    flock -x "$lock_fd"
    if ! assert_palworld_host_project_owner; then
        flock -u "$lock_fd"
        exec {lock_fd}>&-
        return 1
    fi
    rm -f -- "$PALWORLD_HOST_PROJECT_REGISTRY_FILE"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
}

acquire_palworld_project_operation_lock() {
    local lock_file="$PALWORLD_RUNTIME_DIR/project-operation.lock"
    if [[ -n "$PALWORLD_PROJECT_OPERATION_LOCK_FD" ]]; then
        return 0
    fi
    acquire_palworld_host_operation_lock
    # The registry can change while a caller waits for the host-wide lock.
    # Revalidate only after the lock is held before touching this project path.
    assert_palworld_host_project_owner
    command -v flock >/dev/null 2>&1 || {
        echo "오류: 관리 작업 잠금에 필요한 flock 명령을 찾을 수 없습니다." >&2
        return 1
    }
    if [[ -L "$PALWORLD_RUNTIME_DIR" || -L "$lock_file" ]] \
        || [[ -e "$PALWORLD_RUNTIME_DIR" && ! -d "$PALWORLD_RUNTIME_DIR" ]] \
        || [[ -e "$lock_file" && ! -f "$lock_file" ]]; then
        echo "오류: project 관리 작업 잠금 경로가 안전하지 않습니다: $lock_file" >&2
        return 1
    fi
    install -d -m 0755 "$PALWORLD_RUNTIME_DIR"
    ( umask 0007; : >>"$lock_file" )
    if (( EUID == 0 )); then
        chown "$PALWORLD_UID:$PALWORLD_GID" "$lock_file"
        chmod 0660 "$lock_file"
    fi
    exec {PALWORLD_PROJECT_OPERATION_LOCK_FD}>>"$lock_file"
    if ! flock -n "$PALWORLD_PROJECT_OPERATION_LOCK_FD"; then
        exec {PALWORLD_PROJECT_OPERATION_LOCK_FD}>&-
        PALWORLD_PROJECT_OPERATION_LOCK_FD=""
        echo "오류: 다른 Setup/Manage 작업이 진행 중입니다. 완료 후 다시 실행하세요." >&2
        return 1
    fi
    # Older releases copied development documentation and the self-extracting
    # installer into the managed project. Remove only these exact known files,
    # and only after host registration, Docker ownership, and both locks have
    # been revalidated.
    rm -f -- \
        "$PALWORLD_PROJECT_DIR/README.md" \
        "$PALWORLD_PROJECT_DIR/OPERATIONS.md" \
        "$PALWORLD_PROJECT_DIR/BUILD.md" \
        "$PALWORLD_PROJECT_DIR/PROJECT_CONTEXT.md" \
        "$PALWORLD_PROJECT_DIR/CONTRIBUTING.md" \
        "$PALWORLD_PROJECT_DIR/PalworldServerInstaller.run"
}

require_current_image_runtime_layout_for_token_rotation() {
    local container_id="${1:-}"
    local actual_layout="" container_image_id="" tagged_image_id=""

    [[ "$container_id" =~ ^[a-f0-9]{12,64}$ ]] || {
        echo "오류: token 재발급 대상 컨테이너 ID가 잘못되었습니다." >&2
        return 1
    }

    container_image_id="$(docker container inspect --format '{{.Image}}' "$container_id" 2>/dev/null)" || {
        echo "오류: token 재발급 대상 컨테이너의 이미지 ID를 확인하지 못했습니다." >&2
        return 1
    }
    tagged_image_id="$(docker image inspect --format '{{.Id}}' "$PALWORLD_IMAGE" 2>/dev/null)" || {
        echo "오류: 현재 서버 이미지를 찾지 못했습니다: $PALWORLD_IMAGE" >&2
        return 1
    }
    if [[ "$container_image_id" != "$tagged_image_id" ]]; then
        echo "오류: 실행 컨테이너와 현재 서버 이미지가 다릅니다. token 재발급 전에 설정 재적용이 필요합니다." >&2
        echo "먼저 Manage → 기존 서버 이미지 갱신·설정 재적용을 완료하세요." >&2
        return 1
    fi

    if ! actual_layout="$(
        docker image inspect \
            --format '{{ index .Config.Labels "io.palworld.runtime-layout" }}' \
            "$tagged_image_id" 2>/dev/null
    )"; then
        echo "오류: 현재 서버 이미지를 찾거나 runtime layout을 확인하지 못했습니다: $PALWORLD_IMAGE" >&2
        echo "안전상 컨테이너·설정·token을 변경하지 않았습니다." >&2
        echo "먼저 Manage → 기존 서버 이미지 갱신·설정 재적용을 완료한 뒤 token 재발급을 다시 실행하세요." >&2
        return 1
    fi
    if [[ "$actual_layout" != "$PALWORLD_RUNTIME_LAYOUT" ]]; then
        echo "오류: 현재 서버 이미지는 영구 운영 정책, 공유 update lock, SteamCMD 상태 보존을 지원하는 최신 runtime layout이 아닙니다." >&2
        echo "안전상 컨테이너·설정·token을 변경하지 않았습니다." >&2
        echo "먼저 Manage → 기존 서버 이미지 갱신·설정 재적용을 완료한 뒤 token 재발급을 다시 실행하세요." >&2
        return 1
    fi
}

prepare_server_policy_storage() {
    local server="$1"
    local runtime_uid="${2:-$PALWORLD_UID}"
    local runtime_gid="${3:-$PALWORLD_GID}"
    local container="palworld-$server"
    local policy_root="$PALWORLD_RUNTIME_DIR/policy"
    local policy_dir="$policy_root/$server"
    local policy_file="$policy_dir/policy.json"
    local temporary_policy=""
    local copy_error_file=""
    local copy_error=""

    validate_server_name "$server" || {
        echo "오류: 운영 정책 경로의 서버 이름이 잘못되었습니다: $server" >&2
        return 2
    }
    [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ ]] || {
        echo "오류: 운영 정책 경로의 UID/GID가 잘못되었습니다." >&2
        return 2
    }
    if [[ -L "$PALWORLD_RUNTIME_DIR" || -L "$policy_root" || -L "$policy_dir" || -L "$policy_file" ]]; then
        echo "오류: 운영 정책 경로에는 심볼릭 링크를 사용할 수 없습니다: $policy_dir" >&2
        return 1
    fi
    if [[ -e "$PALWORLD_RUNTIME_DIR" && ! -d "$PALWORLD_RUNTIME_DIR" ]] \
        || [[ -e "$policy_root" && ! -d "$policy_root" ]] \
        || [[ -e "$policy_dir" && ! -d "$policy_dir" ]] \
        || [[ -e "$policy_file" && ! -f "$policy_file" ]]; then
        echo "오류: 운영 정책 경로 형식이 잘못되었습니다: $policy_file" >&2
        return 1
    fi

    install -d -m 0755 "$PALWORLD_RUNTIME_DIR" "$policy_root" "$policy_dir"
    if [[ ! -e "$policy_file" ]] \
        && docker container inspect "$container" >/dev/null 2>&1; then
        temporary_policy="$(mktemp "$policy_dir/.policy.json.migrate.XXXXXXXX")"
        copy_error_file="$(mktemp "$policy_dir/.policy.json.copy-error.XXXXXXXX")"
        if docker cp "$container:/palworld/manager/policy.json" "$temporary_policy" \
            >/dev/null 2>"$copy_error_file"; then
            if python3 -B "$PALWORLD_INSTALL_DIR/scripts/policy.py" \
                "$temporary_policy" >/dev/null 2>&1; then
                if [[ ! -e "$policy_file" ]]; then
                    chmod 0600 "$temporary_policy"
                    mv -- "$temporary_policy" "$policy_file"
                    echo "$server 기존 운영 정책을 runtime/policy/$server/policy.json으로 이전했습니다."
                fi
            else
                echo "오류: $server 기존 policy.json이 안전한 운영 정책 형식이 아니어서 컨테이너 재생성을 중단합니다." >&2
                rm -f -- "$temporary_policy" "$copy_error_file"
                return 1
            fi
        else
            copy_error="$(tr '\n' ' ' <"$copy_error_file")"
            if grep -Eiq 'could not find|no such file|not found' "$copy_error_file"; then
                echo "안내: $server 기존 컨테이너에 이전할 policy.json이 없어 기본 자동 정책으로 시작합니다." >&2
            else
                echo "오류: $server 기존 운영 정책을 읽지 못해 컨테이너 재생성을 중단합니다: ${copy_error:-unknown docker cp error}" >&2
                rm -f -- "$temporary_policy" "$copy_error_file"
                return 1
            fi
        fi
        rm -f -- "$temporary_policy" "$copy_error_file"
    fi
    if [[ -e "$policy_file" ]] \
        && ! python3 -B "$PALWORLD_INSTALL_DIR/scripts/policy.py" "$policy_file"; then
        echo "오류: $server 운영 정책을 복구한 뒤 Setup/Manage를 다시 실행하세요: $policy_file" >&2
        return 1
    fi
    chown -R "$runtime_uid:$runtime_gid" "$policy_dir"
}

preflight_server_policy_storage() {
    local server="$1"
    local runtime_uid="${2:-$PALWORLD_UID}"
    local runtime_gid="${3:-$PALWORLD_GID}"
    local policy_dir="$PALWORLD_RUNTIME_DIR/policy/$server"

    validate_server_name "$server" || return 2
    docker run --rm \
        --user "$runtime_uid:$runtime_gid" \
        --entrypoint /bin/sh \
        --volume "$policy_dir:/palworld/policy" \
        "$PALWORLD_IMAGE" \
        -c 'set -eu; printf "policy-ok\n" > /palworld/policy/.manager-policy-test; grep -qx policy-ok /palworld/policy/.manager-policy-test; rm /palworld/policy/.manager-policy-test'
}

prepare_shared_update_storage() {
    local runtime_uid="${1:-$PALWORLD_UID}"
    local runtime_gid="${2:-$PALWORLD_GID}"
    local lock_dir="$PALWORLD_RUNTIME_DIR/update-lock"
    local lock_file="$lock_dir/steam-update.lock"

    [[ "$runtime_uid" =~ ^[0-9]+$ && "$runtime_gid" =~ ^[0-9]+$ ]] || {
        echo "오류: 공유 업데이트 잠금 경로의 UID/GID가 잘못되었습니다." >&2
        return 2
    }
    if [[ -L "$PALWORLD_RUNTIME_DIR" || -L "$lock_dir" || -L "$lock_file" ]]; then
        echo "오류: 공유 업데이트 잠금 경로에는 심볼릭 링크를 사용할 수 없습니다: $lock_dir" >&2
        return 1
    fi
    if [[ -e "$PALWORLD_RUNTIME_DIR" && ! -d "$PALWORLD_RUNTIME_DIR" ]] \
        || [[ -e "$lock_dir" && ! -d "$lock_dir" ]] \
        || [[ -e "$lock_file" && ! -f "$lock_file" ]]; then
        echo "오류: 공유 업데이트 잠금 경로 형식이 잘못되었습니다: $lock_file" >&2
        return 1
    fi

    install -d -m 0755 "$PALWORLD_RUNTIME_DIR" "$lock_dir"
    chown "$runtime_uid:$runtime_gid" "$lock_dir"
    if [[ -e "$lock_file" ]]; then
        chown "$runtime_uid:$runtime_gid" "$lock_file"
    fi
}

preflight_shared_update_storage() {
    local runtime_uid="${1:-$PALWORLD_UID}"
    local runtime_gid="${2:-$PALWORLD_GID}"
    local lock_dir="$PALWORLD_RUNTIME_DIR/update-lock"

    docker run --rm \
        --user "$runtime_uid:$runtime_gid" \
        --entrypoint /bin/sh \
        --volume "$lock_dir:/palworld/update-lock" \
        "$PALWORLD_IMAGE" \
        -c 'set -eu; printf "lock-ok\n" > /palworld/update-lock/.manager-update-lock-test; grep -qx lock-ok /palworld/update-lock/.manager-update-lock-test; python3 -c "import fcntl; handle = open(\"/palworld/update-lock/.manager-update-lock-test\", \"a+b\"); fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB); fcntl.flock(handle.fileno(), fcntl.LOCK_UN); handle.close()"; rm /palworld/update-lock/.manager-update-lock-test'
}

generate_compose() {
    python3 -B "$PALWORLD_INSTALL_DIR/scripts/instances.py" generate-compose >/dev/null
}

palworld_compose() {
    generate_compose
    (
        cd "$PALWORLD_PROJECT_DIR"
        docker compose \
            --project-directory "$PALWORLD_PROJECT_DIR" \
            --file "$PALWORLD_COMPOSE_FILE" \
            "$@"
    )
}
