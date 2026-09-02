#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
contains() { grep -Fq -- "$2" "$1"; }
not_contains() { ! grep -Fq -- "$2" "$1"; }
check() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

HDR="src/lua_bindings/gui.hpp"
IMPL="src/lua_bindings/gui.cpp"
LOADER="src/lua_bindings/gui_gtk_loader.cpp"
REG="src/project_core/runtime_registration.cpp"
CURSES="src/lua_bindings/curses.cpp"
CMAKE="CMakeLists.txt"
RUN="run_tests.sh"
DESIGN="GUI_DESIGN.md"

check "GUI binding header exists" test -f "$HDR"
check "GUI binding implementation exists" test -f "$IMPL"
check "GTK loader implementation exists" test -f "$LOADER"
check "runtime registration includes GUI binding" contains "$REG" '../lua_bindings/gui.hpp'
check "runtime registration installs babet.gui" contains "$REG" 'babet_gui::register_gui(L)'
check "normal validation runs GUI runtime structural contracts" contains "$RUN" 'tools/test_gui_runtime_contracts.sh'

if [ -f "$IMPL" ]; then
    check "GTK4 runtime soname is fixed" contains "$LOADER" 'libgtk-4.so.1'
    check "GTK4 is opened lazily" contains "$LOADER" 'dlopen('
    check "GTK loader resolves symbols explicitly" contains "$LOADER" 'dlsym('
    check "GTK loader uses local eager symbol resolution" contains "$LOADER" 'RTLD_NOW | RTLD_LOCAL'
    check "GTK development headers are absent" not_contains "$LOADER" '#include <gtk/'
    check "GTK locale mutation is disabled" contains "$LOADER" 'gtk_disable_setlocale'
    check "recoverable GTK initialization is used" contains "$LOADER" 'gtk_init_check'
    check "uncontrolled gtk_init is absent" bash -c "! grep -E '[^_]gtk_init\\(' '$LOADER' >/dev/null"
    check "GUI public calls enforce the main thread" contains "$IMPL" 'babet_runtime::require_main_thread'
    check "GUI init rejects active curses" contains "$IMPL" 'babet_curses::session_active()'
    check "GUI session state is queryable by curses" contains "$HDR" 'session_active() noexcept'
    check "GUI cleanup hook is explicit" contains "$HDR" 'cleanup_on_main_thread(lua_State *L) noexcept'
check "GUI cleanup is scoped to the closing Lua state" contains "$IMPL" 'state->owner == closing_owner'
    check "available is registered" contains "$IMPL" '"available"'
    check "init is registered" contains "$IMPL" '"init"'
    check "GUI uses common exception boundary" contains "$IMPL" 'lua_cfunction_exception_boundary'
    check "missing GTK diagnostic identifies GTK4" contains "$LOADER" 'GTK 4'
    check "missing GTK diagnostic gives Arch install example" contains "$LOADER" 'pacman -S gtk4'
    check "missing GTK diagnostic gives Debian install example" contains "$LOADER" 'apt install libgtk-4-1'
    check "missing GTK diagnostic gives Fedora install example" contains "$LOADER" 'dnf install gtk4'
fi

check "curses start rejects an active GUI" contains "$CURSES" 'babet_gui::session_active()'
check "CMake has no direct GTK link item" not_contains "$CMAKE" 'gtk-4'
check "CMake has no GTK pkg-config discovery" not_contains "$CMAKE" 'pkg_check_modules(GTK'
check "design still forbids direct GTK link" contains "$DESIGN" 'must not link GTK'

echo "GUI runtime structural contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
