#!/bin/bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ { print $2; exit }' "${ROOT_DIR}/build_local.sh")"
LUA_ROOT="${ROOT_DIR}/build/lua_build/lua-${LUA_VERSION}/src"
if [ ! -f "${LUA_ROOT}/liblua.a" ]; then
    echo "[FAIL] mergeTables tests require the project's built Lua library." >&2
    exit 1
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-merge-tables.XXXXXX")"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
FLAGS=(-std=c++23 -Wall -Wextra -Wpedantic -Werror)
case "${1:-}" in
    --sanitizers) FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
    --ubsan) FLAGS+=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
    "") ;;
    *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2; exit 1 ;;
esac
SYSTEM_LIBS=(-ldl -lm -pthread)
if [ "$(getconf LONG_BIT 2>/dev/null || printf '64')" = "32" ]; then SYSTEM_LIBS+=(-latomic); fi
"${CXX:-c++}" "${FLAGS[@]}" -I"${ROOT_DIR}/src/lua_bindings" -I"${LUA_ROOT}" \
    "${SCRIPT_DIR}/merge_tables_selftest.cpp" "${ROOT_DIR}/src/lua_bindings/mergeTables.cpp" \
    -Wl,--wrap=lua_next -Wl,--wrap=lua_newuserdatauv \
    "${LUA_ROOT}/liblua.a" "${SYSTEM_LIBS[@]}" -o "${TMP_ROOT}/merge-tables"
"${TMP_ROOT}/merge-tables" "${ROOT_DIR}/tests/tables/merge.lua"
