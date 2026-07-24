#!/usr/bin/env python3
"""Build the self-extracting Linux Palworld installer."""

from __future__ import annotations

import base64
import gzip
import io
import os
import tarfile
from pathlib import Path

from payload_manifest import executable_mode, linux_installer_files


PROJECT_DIR = Path(__file__).resolve().parents[1]
OUTPUT_FILE = PROJECT_DIR / "PalworldServerInstaller.run"
PAYLOAD_MARKER = "__PALWORLD_INSTALLER_PAYLOAD_BELOW__"


HEADER = r'''#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat <<'EOF'
사용법:
  ./PalworldServerInstaller.run
  ./PalworldServerInstaller.run --project-dir /path/to/palworld-docker
  ./PalworldServerInstaller.run --language ko|en

기본값으로 실행 파일 옆의 palworld-docker 전용 디렉터리를 사용합니다.
EOF
}

project_dir=""
env_language="ko"
while (( $# > 0 )); do
    case "$1" in
        --project-dir)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            project_dir="$2"
            shift 2
            ;;
        --language)
            [[ $# -ge 2 && ( "$2" == ko || "$2" == en ) ]] || { usage >&2; exit 2; }
            env_language="$2"
            shift 2
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

for command in awk base64 install mktemp tail tar; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "오류: Linux 기본 명령을 찾을 수 없습니다: $command" >&2
        exit 1
    }
done

launcher_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
launcher_path="$launcher_dir/$(basename -- "$0")"
if [[ -z "$project_dir" ]]; then
    if [[ -f "$launcher_dir/.palworld-server-operations-project" ]] \
        || [[ -f "$launcher_dir/config/common.env" && -f "$launcher_dir/operate/pal" ]] \
        || [[ "$(basename -- "$launcher_dir")" == palworld-docker ]]; then
        project_dir="$launcher_dir"
    else
        project_dir="$launcher_dir/palworld-docker"
    fi
fi
mkdir -p -- "$project_dir"
project_dir="$(cd -- "$project_dir" && pwd -P)"
case "$project_dir" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
        echo "오류: 서버 관리 디렉터리로 사용할 수 없는 경로: $project_dir" >&2
        exit 1
        ;;
esac

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/palworld-installer.XXXXXXXX")"
cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$temporary_dir" || true
    if [[ -e "$launcher_path" || -L "$launcher_path" ]]; then
        if rm -f -- "$launcher_path"; then
            echo "설치 프로그램 삭제 완료: $launcher_path"
        else
            echo "경고: 실행한 설치 프로그램을 삭제하지 못했습니다: $launcher_path" >&2
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

payload_line="$(awk '/^__PALWORLD_INSTALLER_PAYLOAD_BELOW__$/ { print NR + 1; exit }' "$0")"
[[ -n "$payload_line" ]] || { echo "오류: 설치 프로그램 payload를 찾을 수 없습니다." >&2; exit 1; }
tail -n "+$payload_line" "$0" | base64 --decode | tar -xzf - -C "$temporary_dir"

chmod +x \
    "$temporary_dir/install/manager" \
    "$temporary_dir/install/scaffold.sh" \
    "$temporary_dir/install/setup.sh" \
    "$temporary_dir/install/test" \
    "$temporary_dir/install/lib.sh"

echo "서버 관리 디렉터리: $project_dir"
echo "설치 도구는 임시 경로에서 실행되며 종료 시 자동 삭제됩니다."
echo

export PALWORLD_PROJECT_DIR="$project_dir"
export PALWORLD_INSTALL_DIR="$temporary_dir/install"
export PALWORLD_ENV_LANGUAGE="$env_language"
export PYTHONDONTWRITEBYTECODE=1
cd "$project_dir"
if (( EUID == 0 )); then
    env PALWORLD_PROJECT_DIR="$project_dir" \
        PALWORLD_INSTALL_DIR="$temporary_dir/install" \
        PALWORLD_ENV_LANGUAGE="$env_language" \
        PYTHONDONTWRITEBYTECODE=1 \
        bash "$temporary_dir/install/manager" prepare-scaffold \
            --scaffold "$temporary_dir/scaffold" \
            --language "$env_language" \
            --launcher "$launcher_path"
else
    sudo env PALWORLD_PROJECT_DIR="$project_dir" \
        PALWORLD_INSTALL_DIR="$temporary_dir/install" \
        PALWORLD_ENV_LANGUAGE="$env_language" \
        PYTHONDONTWRITEBYTECODE=1 \
        bash "$temporary_dir/install/manager" prepare-scaffold \
            --scaffold "$temporary_dir/scaffold" \
            --language "$env_language" \
            --launcher "$launcher_path"
fi
bash "$temporary_dir/install/manager"
exit $?
__PALWORLD_INSTALLER_PAYLOAD_BELOW__
'''


def build_payload() -> bytes:
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", mtime=0) as gzip_file:
        with tarfile.open(fileobj=gzip_file, mode="w") as archive:
            for source, destination in linux_installer_files():
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
    encoded = base64.b64encode(build_payload()).decode("ascii")
    wrapped = "\n".join(encoded[index : index + 76] for index in range(0, len(encoded), 76))
    OUTPUT_FILE.write_text(HEADER + wrapped + "\n", encoding="utf-8", newline="\n")
    if os.name != "nt":
        OUTPUT_FILE.chmod(0o755)
    print(OUTPUT_FILE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
