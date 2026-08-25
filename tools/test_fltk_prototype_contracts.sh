#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

pass=0
fail=0
ok() { echo "[PASS] $1"; pass=$((pass + 1)); }
ko() { echo "[FAIL] $1"; fail=$((fail + 1)); }
check() { local label="$1"; shift; if "$@"; then ok "$label"; else ko "$label"; fi; }
contains() { grep -Fq -- "$2" "$1"; }
not_contains() { ! grep -Fq -- "$2" "$1"; }

DOC="FLTK_PROTOTYPE.md"
SRC="prototypes/fltk/main.cpp"
PCMAKE="prototypes/fltk/CMakeLists.txt"
BOOT="prototypes/fltk/bootstrap_fltk.sh"
PTEST="prototypes/fltk/test.sh"

check "FLTK prototype contract exists" test -f "$DOC"
check "FLTK prototype source exists" test -f "$SRC"
check "FLTK prototype has a separate CMake project" test -f "$PCMAKE"
check "FLTK prototype bootstrap is separate" test -x "$BOOT"
check "FLTK prototype runtime test is separate" test -x "$PTEST"
check "prototype publishes a separate stable FLTK validation log" contains "$PTEST" 'babet-fltk-tests.txt'
check "prototype log wrapper avoids nested logs" contains "$PTEST" 'BABET_FLTK_TEST_LOG_ACTIVE'
check "prototype log survives validation failures" contains "$PTEST" 'set +e'
check "prototype log is published atomically" contains "$PTEST" 'mv -f -- "${clean_log}" "${FLTK_TEST_LOG}"'
check "prototype documentation names the separate FLTK log" contains "$DOC" '`babet-fltk-tests.txt`'
check "prototype consumes standalone libbabet SDK" contains "$PCMAKE" 'BABET_SDK_DIR'
check "prototype uses FLTK CONFIG package" contains "$PCMAKE" 'find_package(FLTK 1.4 CONFIG REQUIRED)'
check "prototype links the canonical FLTK target" contains "$PCMAKE" 'fltk::fltk'
check "prototype reuses call_global host-to-Lua path" contains "$SRC" 'babet_context_call_global'
check "prototype does not poll Lua globals" not_contains "$SRC" 'babet_context_get_global'
check "prototype does not mutate Lua globals as a bridge" not_contains "$SRC" 'babet_context_set_global'
check "prototype contains the Lua error at callback boundary" contains "$SRC" 'Lua callback error'
check "prototype catches unexpected C++ callback exceptions" contains "$SRC" 'host callback exception contained'
check "prototype uses the FLTK event loop" contains "$SRC" 'Fl::run()'
check "prototype disables callbacks before context destruction" contains "$SRC" 'state.callbacks_enabled = false;'
check "prototype detaches widget callback before context destruction" contains "$SRC" 'state.button->callback(nullptr, nullptr);'
check "prototype destroys GUI before Babet context" bash -c "python3 - <<'PY'
s=open('$SRC', encoding='utf-8').read()
assert s.index('delete state.window') < s.index('const babet_status destroy_status = babet_context_destroy(state.ctx)')
PY"
check "prototype has an automated event-loop self-test" contains "$SRC" 'LOT9_FLTK_SELFTEST_OK'
check "prototype pins stable FLTK 1.4.5" contains "$BOOT" 'FLTK_VERSION="1.4.5"'
check "prototype verifies FLTK SHA-256" contains "$BOOT" 'eede1fb2b8e9c2e581e77082e15252145855c79aad30070ee3b24aabe2f926f1'
check "normal CMake never finds FLTK" not_contains "CMakeLists.txt" 'find_package(FLTK'
check "normal bootstrap never downloads FLTK" not_contains "build_local.sh" 'fltk-1.4.5'
check "normal test harness never bootstraps FLTK" not_contains "run_tests.sh" 'bootstrap_fltk.sh'
check "prototype documents short event-loop callbacks" contains "$DOC" 'callbacks execute on the event-loop thread and should stay short'
check "prototype records the Lot 10 missing-capability list" contains "$DOC" 'What Lot 9 deliberately cannot express'
check "prototype forbids polling workaround" contains "$DOC" 'polled globals/timers would hide rather than solve'
check "prototype documents desktop runtime dependency boundary" contains "$DOC" 'needs a compatible X11/Wayland graphical environment'

echo "FLTK prototype structural contracts: ${pass} PASS / ${fail} FAIL"
exit "$fail"
