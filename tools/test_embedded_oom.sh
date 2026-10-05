#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ { print $2; exit }' "${ROOT_DIR}/build_local.sh")"
MINIZ_VERSION="$(awk -F'"' '/^MINIZ_VERSION="/ { print $2; exit }' "${ROOT_DIR}/build_local.sh")"
LUA_ROOT="${ROOT_DIR}/build/lua_build/lua-${LUA_VERSION}/src"
MINIZ_ROOT="${ROOT_DIR}/build/miniz/miniz-${MINIZ_VERSION}"
if [ ! -f "${LUA_ROOT}/liblua.a" ] || [ ! -f "${MINIZ_ROOT}/miniz.c" ]; then
    echo "[FAIL] Embedded OOM tests require the project's built Lua and miniz sources." >&2
    exit 1
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-embedded-oom.XXXXXX")"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
CXX_BIN="${CXX:-c++}"
SAN_FLAGS=()
case "${1:-}" in
    --sanitizers) SAN_FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
    --ubsan) SAN_FLAGS+=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
    "") ;;
    *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2; exit 1 ;;
esac
FLAGS=(-std=c++23 -Wall -Wextra -Wpedantic -Werror "${SAN_FLAGS[@]}")
SYSTEM_LIBS=(-ldl -lm -pthread)
if [ "$(getconf LONG_BIT 2>/dev/null || printf '64')" = "32" ]; then
    SYSTEM_LIBS+=(-latomic)
fi
"${CXX_BIN}" "${FLAGS[@]}" -I"${ROOT_DIR}/src" -I"${LUA_ROOT}" \
    "${SCRIPT_DIR}/embedded_searcher_oom_selftest.cpp" \
    "${ROOT_DIR}/src/project_core/embedded_searcher.cpp" \
    "${LUA_ROOT}/liblua.a" "${SYSTEM_LIBS[@]}" -o "${TMP_ROOT}/searcher"
"${TMP_ROOT}/searcher"
"${CC:-cc}" "${SAN_FLAGS[@]}" -I"${MINIZ_ROOT}" -c "${MINIZ_ROOT}/miniz.c" \
    -o "${TMP_ROOT}/miniz.o"
"${CXX_BIN}" "${FLAGS[@]}" -I"${ROOT_DIR}/src" -isystem "${MINIZ_ROOT}" \
    "${SCRIPT_DIR}/embedded_archive_oom_selftest.cpp" \
    "${ROOT_DIR}/src/project_core/zip_utils.cpp" "${TMP_ROOT}/miniz.o" \
    "${SYSTEM_LIBS[@]}" -o "${TMP_ROOT}/archive"
"${TMP_ROOT}/archive"
