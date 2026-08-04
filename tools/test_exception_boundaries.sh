#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0

fail() {
    echo "[FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

require_pattern() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    if ! grep -Eq "${pattern}" "${ROOT_DIR}/${file}"; then
        fail "${label}"
    fi
}

for specification in \
    "src/lua_bindings/compression.cpp|compression_lua_boundary<lua_compress>|compression.compress" \
    "src/lua_bindings/compression.cpp|compression_lua_boundary<lua_decompress>|compression.decompress" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_which>|sys.which" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_env>|sys.env" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_setenv>|sys.setenv" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_hostname>|sys.hostname" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_uname>|sys.uname" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_pid>|sys.pid" \
    "src/lua_bindings/user.cpp|user_lua_boundary<lua_user_get>|user.get" \
    "src/lua_bindings/user.cpp|user_lua_boundary<lua_user_exists>|user.exists" \
    "src/lua_bindings/inotify.cpp|inotify_gc_boundary|inotify.__gc" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_tostring>|inotify.__tostring" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_add>|inotify.add" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_read>|inotify.read" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_remove>|inotify.remove" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_close>|inotify.close" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<lua_inotify_new>|inotify.new"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" \
        "lua_pushcfunction\\(L, ${pattern}\\);" \
        "${label} is not registered through its C++ exception boundary"
done

if grep -Eq \
    'lua_pushcfunction\(L, (lua_compress|lua_decompress|lua_sys_(which|env|setenv|hostname|uname|pid)|lua_user_(get|exists)|inot_(gc|tostring|add|read|remove|close)|lua_inotify_new)\);' \
    "${ROOT_DIR}/src/lua_bindings/"{compression,sys,user,inotify}.cpp; then
    fail "at least one audited Lua C function is still registered directly"
fi

require_pattern "src/lua_bindings/lua_utils.hpp" \
    'lua_cfunction_exception_boundary' \
    "common Lua C++ exception boundary helper is missing"

if [ "${FAILURES}" -ne 0 ]; then
    echo "Exception boundary structural checks: ${FAILURES} failure(s)"
    exit 1
fi

CXX_BIN="${CXX:-c++}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-boundary-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

if ! "${CXX_BIN}" -std=c++23 -Wall -Wextra -Wpedantic -Werror \
    -I"${ROOT_DIR}/src/lua_bindings" \
    "${SCRIPT_DIR}/exception_boundary_selftest.cpp" \
    -o "${TMP_ROOT}/exception_boundary_selftest"; then
    fail "exception boundary self-test compilation"
    exit 1
fi

if ! "${TMP_ROOT}/exception_boundary_selftest"; then
    fail "exception boundary self-test execution"
    exit 1
fi

echo "Exception boundary checks: 17/17 registrations protected"
