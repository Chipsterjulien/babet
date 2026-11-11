#!/usr/bin/env bash
# Optional focused runner; full release tests exercise the complete runtime too.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ {print $2;exit}' "$ROOT/build_local.sh")"
MINIZ_VERSION="$(awk -F'"' '/^MINIZ_VERSION="/ {print $2;exit}' "$ROOT/build_local.sh")"
LUA="$ROOT/build/lua_build/lua-$LUA_VERSION/src"
MINIZ="$ROOT/build/miniz/miniz-$MINIZ_VERSION"
FLAGS=();MODE=OFF
case "${1:-}" in
 --sanitizers) FLAGS=(-fsanitize=address,undefined -fno-omit-frame-pointer);MODE=ASAN_UBSAN ;;
 --ubsan) FLAGS=(-fsanitize=undefined -fno-omit-frame-pointer);MODE=UBSAN ;;
 "") ;;
 *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2;exit 1 ;;
esac
TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-runtime-gui.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
LIBS=(-ldl -lm -pthread)
if [ "$(getconf LONG_BIT)" = 32 ];then LIBS+=(-latomic);fi
"${CC:-cc}" "${FLAGS[@]}" -I"$MINIZ" -c "$MINIZ/miniz.c" -o "$TMP/miniz.o"
"${CXX:-c++}" -std=c++23 -Wall -Wextra -Wpedantic -Werror "${FLAGS[@]}" \
 -I"$ROOT/src" -I"$LUA" -isystem "$MINIZ" "$ROOT/tests/runtime_gui_native.cpp" \
 "$ROOT"/src/lua_bindings/{gui,gui_gtk_loader,main_thread,process_state,process,process_common,process_launch_internal,process_terminal_internal,signal,fileExists}.cpp \
 "$ROOT"/src/project_core/{runtime_info,zip_utils,executable_path}.cpp "$TMP/miniz.o" "$LUA/liblua.a" "${LIBS[@]}" -o "$TMP/probe"
BABET_TEST_GUI_SANITIZERS="$MODE" python3 "$ROOT/tools/test_gui_event_loop.py" "$TMP/probe"
BABET_TEST_GUI_SANITIZERS="$MODE" python3 "$ROOT/tools/test_gui_files.py" "$TMP/probe"
python3 "$ROOT/tools/test_runtime_info.py" "$TMP/probe"
