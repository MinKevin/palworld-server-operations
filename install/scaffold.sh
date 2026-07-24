#!/usr/bin/env bash
set -Eeuo pipefail

# Shared project scaffolding for both the self-extracting Linux installer and
# the Windows SSH management client. Installation tools stay in a temporary
# directory; only runtime files are copied into the managed project.

if (( $# != 2 )); then
    echo "usage: scaffold.sh PROJECT_DIR SCAFFOLD_DIR" >&2
    exit 2
fi

for command in awk install mktemp mv; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "오류: project scaffold에 필요한 Linux 기본 명령 누락: $command" >&2
        exit 1
    }
done

project_dir="$1"
scaffold_dir="$2"
mkdir -p -- "$project_dir"
project_dir="$(cd -- "$project_dir" && pwd -P)"
scaffold_dir="$(cd -- "$scaffold_dir" && pwd -P)"
project_marker="$project_dir/.palworld-server-operations-project"
project_marker_value="palworld-server-operations-project-v1"

case "$project_dir" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
        echo "오류: 서버 관리 디렉터리로 사용할 수 없는 경로: $project_dir" >&2
        exit 1
        ;;
esac

if [[ -e "$project_marker" || -L "$project_marker" ]]; then
    if [[ -L "$project_marker" || ! -f "$project_marker" ]] \
        || [[ "$(cat -- "$project_marker")" != "$project_marker_value" ]]; then
        echo "오류: 프로젝트 표식이 안전하지 않거나 다른 형식입니다: $project_marker" >&2
        exit 1
    fi
else
    legacy_project=false
    [[ -f "$project_dir/config/common.env" && -f "$project_dir/operate/pal" ]] \
        && legacy_project=true
    unrelated_entry=""
    allowed_launcher="${PALWORLD_PROJECT_LAUNCHER_PATH:-}"
    for candidate in "$project_dir"/.[!.]* "$project_dir"/..?* "$project_dir"/*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        if [[ -n "$allowed_launcher" ]] \
            && [[ "$(cd -- "$(dirname -- "$candidate")" && pwd -P)/$(basename -- "$candidate")" == "$allowed_launcher" ]]; then
            continue
        fi
        unrelated_entry="$candidate"
        break
    done
    if [[ "$legacy_project" != true && -n "$unrelated_entry" ]]; then
        echo "오류: 기존 일반 파일이 있는 디렉터리는 관리 프로젝트로 초기화하지 않습니다: $project_dir" >&2
        echo "비어 있는 전용 palworld-docker 디렉터리를 사용하거나 --project-dir로 지정하세요." >&2
        exit 1
    fi
    marker_temporary="$(mktemp "$project_dir/.project-marker.XXXXXXXX")"
    printf '%s\n' "$project_marker_value" >"$marker_temporary"
    chmod 0644 "$marker_temporary"
    mv -f -- "$marker_temporary" "$project_marker"
fi

env_language="${PALWORLD_ENV_LANGUAGE:-ko}"
case "$env_language" in
    ko)
        common_source="$scaffold_dir/config/kr/common.env"
        server_template_source="$scaffold_dir/config/kr/server.template.env"
        ;;
    en)
        common_source="$scaffold_dir/config/en/common.env"
        server_template_source="$scaffold_dir/config/en/server.template.env"
        ;;
    *)
        echo "오류: PALWORLD_ENV_LANGUAGE는 ko 또는 en이어야 합니다: $env_language" >&2
        exit 2
        ;;
esac

for required in \
    "$scaffold_dir/LICENSE" \
    "$scaffold_dir/operate/pal" \
    "$common_source" \
    "$server_template_source"; do
    [[ -f "$required" ]] || { echo "오류: 공통 설치 파일 누락: $required" >&2; exit 1; }
done

install -d -m 0755 \
    "$project_dir/config" \
    "$project_dir/data" \
    "$project_dir/backups" \
    "$project_dir/operate" \
    "$project_dir/runtime"

install -m 0755 "$scaffold_dir/operate/pal" "$project_dir/operate/pal"
install -m 0644 "$scaffold_dir/LICENSE" "$project_dir/LICENSE"

# Older releases copied development documentation and the installer into the
# managed project. They are not runtime dependencies and must not remain on a
# server after a current Setup/Manage entry point has run.
rm -f -- \
    "$project_dir/README.md" \
    "$project_dir/OPERATIONS.md" \
    "$project_dir/BUILD.md" \
    "$project_dir/PROJECT_CONTEXT.md" \
    "$project_dir/CONTRIBUTING.md" \
    "$project_dir/PalworldServerInstaller.run"

common_created=false
if [[ ! -e "$project_dir/config/common.env" ]]; then
    install -m 0644 "$common_source" "$project_dir/config/common.env"
    common_created=true
else
    echo "기존 설정 유지: $project_dir/config/common.env"
fi

ensure_common_default() {
    local key="$1"
    local value="$2"
    local description="$3"
    if ! awk -F= -v wanted="$key" '
        {
            candidate=$1
            gsub(/^[ \t]+|[ \t]+$/, "", candidate)
            if (candidate == wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "$project_dir/config/common.env"; then
        printf '\n# %s\n%s=%s\n' "$description" "$key" "$value" \
            >> "$project_dir/config/common.env"
        echo "공통 설정 기본값 추가: $key=$value"
    fi
}

read_common_value() {
    local key="$1"
    awk -F= -v wanted="$key" '
        {
            candidate=$1
            gsub(/^[ \t]+|[ \t]+$/, "", candidate)
            if (candidate == wanted) {
                sub(/^[^=]*=/, "")
                gsub(/^[ \t]+|[ \t]+$/, "")
                print
                exit
            }
        }
    ' "$project_dir/config/common.env"
}

set_common_value() {
    local key="$1"
    local value="$2"
    local temporary
    temporary="$(mktemp "$project_dir/config/.common.env.XXXXXXXX")"
    awk -F= -v wanted="$key" -v replacement="$value" '
        BEGIN { replaced=0 }
        {
            candidate=$1
            gsub(/^[ \t]+|[ \t]+$/, "", candidate)
            if (candidate == wanted) {
                print wanted "=" replacement
                replaced=1
            } else {
                print
            }
        }
        END { if (!replaced) print wanted "=" replacement }
    ' "$project_dir/config/common.env" > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$project_dir/config/common.env"
}

detect_host_timezone() {
    local detected=""
    if command -v timedatectl >/dev/null 2>&1; then
        detected="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "$detected" && -r /etc/timezone ]]; then
        detected="$(tr -d '[:space:]' </etc/timezone)"
    fi
    if [[ -z "$detected" && -L /etc/localtime ]]; then
        detected="$(readlink -f /etc/localtime 2>/dev/null || true)"
        detected="${detected#/usr/share/zoneinfo/}"
    fi
    if [[ "$detected" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] \
        && [[ ! "$detected" =~ (^|/)\.{1,2}(/|$) ]] \
        && [[ -f "/usr/share/zoneinfo/$detected" ]]; then
        printf '%s\n' "$detected"
    fi
}

if [[ "$common_created" == true && "$env_language" == en ]]; then
    detected_timezone="$(detect_host_timezone)"
    if [[ -n "$detected_timezone" ]]; then
        set_common_value TZ "$detected_timezone"
        echo "Initial English common.env timezone: TZ=$detected_timezone (detected from host)"
    else
        set_common_value TZ UTC
        echo "[WARN] Host timezone could not be detected; initial English common.env uses TZ=UTC. Review it before Setup." >&2
    fi
fi

ensure_common_default \
    GAME_PORT_BASE 39471 \
    "신규 serverN.env 게임 포트 기준값 - server1에 그대로 사용"
ensure_common_default \
    REST_API_PORT_BASE 39472 \
    "신규 serverN.env REST API 포트 기준값 - GAME_PORT_BASE + 1"
ensure_common_default \
    SERVER_PORT_STEP 10 \
    "서버 번호 증가당 포트 증가값 - serverN: 기준값 + (N-1) × 증가값"

# Migrate only the short-lived development template value. Existing numeric
# project settings remain untouched.
if [[ "$(read_common_value GAME_PORT_BASE)" == auto ]]; then
    set_common_value GAME_PORT_BASE 39471
    echo "공통 설정 auto 값 고정: GAME_PORT_BASE=39471"
fi
if [[ "$(read_common_value REST_API_PORT_BASE)" == auto ]]; then
    set_common_value REST_API_PORT_BASE 39472
    echo "공통 설정 auto 값 고정: REST_API_PORT_BASE=39472"
fi

if [[ ! -e "$project_dir/config/server.template.env" ]]; then
    install -m 0644 \
        "$server_template_source" \
        "$project_dir/config/server.template.env"
else
    echo "기존 설정 유지: $project_dir/config/server.template.env"
fi

echo "서버 관리 디렉터리 준비 완료: $project_dir"
