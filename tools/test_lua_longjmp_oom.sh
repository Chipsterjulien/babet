#!/bin/bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ { print $2; exit }' \
    "${ROOT_DIR}/build_local.sh")"
if [ -z "${LUA_VERSION}" ]; then
    echo "Impossible de déterminer LUA_VERSION depuis build_local.sh." >&2
    exit 1
fi
LUA_ROOT="${ROOT_DIR}/build/lua_build/lua-${LUA_VERSION}/src"
LUA_LIB="${LUA_ROOT}/liblua.a"
if [ ! -f "${LUA_LIB}" ]; then
    echo "[FAIL] Lua static library not found: ${LUA_LIB}" >&2
    exit 1
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-lua-oom.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
CXX_BIN="${CXX:-c++}"
FLAGS=(-std=c++23 -Wall -Wextra -Wpedantic -Werror)
if [ "${1:-}" = "--sanitizers" ]; then
    FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
"${CXX_BIN}" "${FLAGS[@]}" \
    -I"${ROOT_DIR}/src/lua_bindings" -I"${LUA_ROOT}" \
    "${SCRIPT_DIR}/lua_longjmp_oom_selftest.cpp" \
    "${ROOT_DIR}/src/lua_bindings/deepCopyTable.cpp" \
    "${ROOT_DIR}/src/lua_bindings/listFiles.cpp" \
    "${ROOT_DIR}/src/lua_bindings/exec.cpp" \
    "${ROOT_DIR}/src/lua_bindings/process_common.cpp" \
    "${ROOT_DIR}/src/lua_bindings/process_launch_internal.cpp" \
    "${ROOT_DIR}/src/lua_bindings/process_terminal_internal.cpp" \
    "${LUA_LIB}" -ldl -lm -pthread \
    -o "${TMP_ROOT}/lua_longjmp_oom_selftest"
"${TMP_ROOT}/lua_longjmp_oom_selftest"
