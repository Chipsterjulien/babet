#!/bin/bash
set -eu
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ { print $2; exit }' "${ROOT_DIR}/build_local.sh")"
LUA_ROOT="${ROOT_DIR}/build/lua_build/lua-${LUA_VERSION}/src"
if [ ! -f "${LUA_ROOT}/liblua.a" ]; then
    echo "[FAIL] Worker process tests require the project's built Lua library." >&2
    exit 1
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-worker-process.XXXXXX")"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
FLAGS=(-std=c++23 -Wall -Wextra -Wpedantic -Werror)
case "${1:-}" in
    --sanitizers) FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
    --ubsan) FLAGS+=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
    "") ;;
    *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2; exit 1 ;;
esac
WRAPS=()
SYSTEM_LIBS=(-ldl -lm -pthread)
if [ "$(getconf LONG_BIT 2>/dev/null || printf '64')" = "32" ]; then SYSTEM_LIBS+=(-latomic); fi
for symbol in pipe2 fdopen posix_spawn_file_actions_init posix_spawn_file_actions_adddup2 posix_spawnattr_init posix_spawn; do
    WRAPS+=("-Wl,--wrap=${symbol}")
done
"${CXX:-c++}" "${FLAGS[@]}" -I"${ROOT_DIR}/src" -I"${LUA_ROOT}" \
    "${ROOT_DIR}/tools/worker_process_selftest.cpp" \
    "${ROOT_DIR}/src/lua_bindings/worker_process.cpp" \
    "${LUA_ROOT}/liblua.a" "${WRAPS[@]}" "${SYSTEM_LIBS[@]}" \
    -o "${TMP_ROOT}/worker-process"
"${TMP_ROOT}/worker-process"
