#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VERSION="$(awk -F'"' '/^LUA_VERSION="/ {print $2; exit}' "${ROOT}/build_local.sh")"
LUA="${ROOT}/build/lua_build/lua-${VERSION}/src"
[[ -f "${LUA}/liblua.a" ]] || { echo '[FAIL] file lock tests require the built project Lua.' >&2; exit 1; }
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-lock-test.XXXXXX")"
trap 'rm -rf -- "$TEMP"' EXIT
FLAGS=()
case "${1:-}" in
    '') ;;
    --sanitizers) FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
    --ubsan) FLAGS+=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
    *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2; exit 1 ;;
esac
"${CXX:-c++}" -std=c++23 -Wall -Wextra -Wpedantic -Werror -g \
    "${FLAGS[@]}" -I"${ROOT}/src" -I"${LUA}" \
    "${ROOT}/tests/fs/lock_file_native.cpp" "${ROOT}/src/lua_bindings/lockFile.cpp" \
    "${LUA}/liblua.a" -ldl -lm -pthread -Wl,--wrap=pwrite -Wl,--wrap=ftruncate -Wl,--wrap=close -o "${TEMP}/probe"
timeout 60 "${TEMP}/probe"
