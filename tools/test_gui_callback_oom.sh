#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ { print $2; exit }' "${ROOT_DIR}/build_local.sh")"
LUA_ROOT="${ROOT_DIR}/build/lua_build/lua-${LUA_VERSION}/src"
if [ ! -f "${LUA_ROOT}/liblua.a" ]; then
    echo "[FAIL] GUI callback allocator tests require the project's built Lua." >&2
    exit 1
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-gui-callback-oom.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT
SAN_FLAGS=()
case "${1:-}" in
    --sanitizers) SAN_FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
    --ubsan) SAN_FLAGS+=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
    "") ;;
    *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2; exit 1 ;;
esac
SYSTEM_LIBS=(-ldl -lm -pthread)
if [ "$(getconf LONG_BIT 2>/dev/null || printf '64')" = "32" ]; then SYSTEM_LIBS+=(-latomic); fi
"${CC:-cc}" -std=c99 -Wall -Wextra -Werror "${SAN_FLAGS[@]}" -fPIC -shared \
    -DBABET_FAKE_GTK_OOM_PROBE -Wl,-soname,libgtk-4.so.1 \
    "${ROOT_DIR}/tests/gui/fake_gtk4_runtime.c" -o "${TMP_ROOT}/libgtk-4.so.1"
"${CXX:-c++}" -std=c++23 -Wall -Wextra -Wpedantic -Werror "${SAN_FLAGS[@]}" \
    -I"${ROOT_DIR}/src" -I"${LUA_ROOT}" \
    "${ROOT_DIR}/tests/gui/callback_oom.cpp" \
    "${ROOT_DIR}/src/lua_bindings/gui.cpp" \
    "${ROOT_DIR}/src/lua_bindings/gui_gtk_loader.cpp" \
    "${ROOT_DIR}/src/lua_bindings/main_thread.cpp" \
    "${ROOT_DIR}/src/lua_bindings/process_state.cpp" \
    "${LUA_ROOT}/liblua.a" "${SYSTEM_LIBS[@]}" -o "${TMP_ROOT}/probe"
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" drag
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" text
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" drop
BABET_FAKE_GTK_DND_HIT=target LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" drop-setter
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" source-setter

python3 - "${ROOT_DIR}" "${TMP_ROOT}/picture.png" <<'PYIMG'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / "tools"))
from test_gui_files import png_bytes
Path(sys.argv[2]).write_bytes(png_bytes())
PYIMG
BABET_TEST_PICTURE="${TMP_ROOT}/picture.png" LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" picture
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" file-dialog
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" file-completion

LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" tags
LD_LIBRARY_PATH="${TMP_ROOT}" "${TMP_ROOT}/probe" file-drop
