#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check_contains() {
    local label="$1" file="$2" text="$3"
    if grep -Fq -- "$text" "$file"; then pass "$label"; else fail "$label"; fi
}
check_absent() {
    local label="$1" path="$2"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then pass "$label"; else fail "$label"; fi
}

DESIGN="GUI_DESIGN.md"
INV="INVARIANTS.md"
RUN="run_tests.sh"

if [ -f "$DESIGN" ]; then pass "dynamic GUI design contract exists"; else fail "dynamic GUI design contract exists"; fi
check_contains "GUI dependency is optional" "$DESIGN" 'optional, system-dependent GUI feature'
check_contains "GTK4 is the only initial backend" "$DESIGN" 'first and only supported backend'
check_contains "normal build must not link GTK" "$DESIGN" 'must not link GTK'
check_contains "normal build must not require GTK development headers" "$DESIGN" 'require GTK development'
check_contains "GTK is loaded lazily" "$DESIGN" 'discovered lazily'
check_contains "GTK runtime uses dlopen" "$DESIGN" 'dlopen()'
check_contains "GTK symbols use dlsym" "$DESIGN" 'dlsym()'
check_contains "GTK4 soname is explicit" "$DESIGN" 'libgtk-4.so.1'
check_contains "GUI is not implemented as a native plugin" "$DESIGN" 'Native plugins are not the GUI backend mechanism'
check_contains "GUI helper extraction is forbidden" "$DESIGN" 'No extraction of a helper DSO'
check_contains "GTK cannot change Babet locale" "$DESIGN" 'gtk_disable_setlocale()'
check_contains "GTK initialization is recoverable" "$DESIGN" 'gtk_init_check()'
check_contains "uncontrolled gtk_init is forbidden" "$DESIGN" 'never `gtk_init()`'
check_contains "GTK3 main loop API is rejected" "$DESIGN" 'removed the old `gtk_main()` API'
check_contains "GUI is main-thread only" "$DESIGN" 'All GTK/widget operations are main-thread only'
check_contains "GUI and curses are mutually exclusive" "$DESIGN" 'active ncurses session and an active GUI session are mutually exclusive'
check_contains "Lua GUI callbacks are protected" "$DESIGN" 'protected Lua call'
check_contains "dead widget handles are invalidated" "$DESIGN" 'every associated Lua handle is invalidated'
check_contains "create-exe remains one file" "$DESIGN" 'still published as exactly one'
check_contains "GUI create-exe depends on target GTK" "$DESIGN" 'requested GUI runtime must already be present'
check_contains "narrow MVP exposes a window" "$DESIGN" '`babet.gui.window()`'
check_contains "narrow MVP exposes callbacks" "$DESIGN" '`button:onClick()`'
check_contains "generic GObject introspection is deferred" "$DESIGN" 'GObject Introspection is deliberately out of scope'
check_contains "invariants point at the active GUI design" "$INV" '[GUI_DESIGN.md](GUI_DESIGN.md)'
check_contains "normal harness runs the GUI design preflight" "$RUN" 'tools/test_gui_design_contract.sh'

check_absent "old GUI study is retired" "GUI_STUDY.md"
check_absent "old FLTK prototype document is retired" "FLTK_PROTOTYPE.md"
check_absent "old FLTK source tree is retired" "prototypes/fltk"
check_absent "old FLTK structural preflight is retired" "tools/test_fltk_prototype_contracts.sh"
check_absent "old GUI-study structural preflight is retired" "tools/test_gui_study_contract.sh"

if ! grep -Fq -- 'prototypes/fltk/test.sh' "$RUN"; then
    pass "normal harness no longer invokes FLTK prototype"
else
    fail "normal harness no longer invokes FLTK prototype"
fi

if grep -Fq -- 'babet_context_register_host_function' "examples/embedding/07_host_functions.c"; then
    pass "non-GUI embedding example still consumes host-function API"
else
    fail "non-GUI embedding example still consumes host-function API"
fi

echo "dynamic GUI design contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
