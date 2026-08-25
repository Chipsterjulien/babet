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

HDR="include/babet/babet.h"
IMPL="src/embedding/babet_c_api.cpp"
DESIGN="HOST_FUNCTIONS_DESIGN.md"
SMOKE="tests/embedding_smoke.c"
EXT="tests/embedding_external_smoke.c"
CPP_SMOKE="tests/embedding_cpp_callback_smoke.cpp"
FLTK="prototypes/fltk/main.cpp"
EXAMPLE="examples/embedding/07_host_functions.c"

check "host-function design contract exists" test -f "$DESIGN"
check "public host-call handle is opaque" contains "$HDR" 'typedef struct babet_host_call babet_host_call;'
check "public host callback type exists" contains "$HDR" 'typedef babet_status (*babet_host_function)'
check "public registration API exists" contains "$HDR" 'babet_context_register_host_function'
check "public callback argument accessors exist" bash -c "grep -Fq 'babet_host_call_argument_count' '$HDR' && grep -Fq 'babet_host_call_arguments' '$HDR'"
check "public callback result setter exists" contains "$HDR" 'babet_host_call_set_result'
check "public callback error setter exists" contains "$HDR" 'babet_host_call_set_error'
check "reentrancy has an explicit public status" contains "$HDR" 'BABET_STATUS_REENTRANT_CALL'
check "public host API exposes no Lua state" not_contains "$HDR" 'lua_State'
check "public host API exposes no STL type" not_contains "$HDR" 'std::'

check "Lua namespace is fixed under babet.host" contains "$DESIGN" 'babet.host.<name>'
check "host names are copied" contains "$DESIGN" 'copies the name at registration time'
check "Lua keywords are rejected as host names" contains "$DESIGN" 'excluding Lua reserved keywords'
check "host userdata remains host-owned" contains "$DESIGN" 'does **not** own, copy or destroy'
check "first host API deliberately has no unregister" contains "$DESIGN" 'no unregister operation in Lot 10'
check "host callbacks run synchronously" contains "$DESIGN" 'A host callback is synchronous'
check "host callbacks stay on owner thread" contains "$DESIGN" 'same owner thread'
check "workers do not inherit host callbacks" contains "$DESIGN" 'do not inherit them.'
check "host callback arguments stay scalar" contains "$DESIGN" 'exactly:'
check "host result strings are copied immediately" contains "$DESIGN" 'copies string data immediately'
check "host failures become Lua errors" contains "$DESIGN" 'A host-function failure becomes a normal Lua error'
check "host callback C++ exceptions are contained" contains "$DESIGN" 'Babet catches `std::bad_alloc`, `std::exception`'
check "nested context entry is explicitly forbidden" contains "$DESIGN" 'BABET_STATUS_REENTRANT_CALL'

check "implementation stores host registrations in context" contains "$IMPL" 'host_functions'
check "implementation uses Lua closures for registered functions" contains "$IMPL" 'lua_pushcclosure(state, host_function_thunk, 2)'
check "implementation tracks active callback reentrancy" contains "$IMPL" 'host_callback_active'
check "embedding callback identity uses shared Lua registry" contains "$IMPL" 'kEmbeddingContextRegistryKey'
check "embedding callbacks accept coroutine lua_State values" bash -c "grep -Fq 'same_embedding_context' '$IMPL' && ! grep -Fq 'context->lua != state' '$IMPL'"
check "host registration bypasses user metamethods" bash -c "grep -Fq 'lua_rawget(state, -2)' '$IMPL' && grep -Fq 'lua_rawset(state, -3)' '$IMPL'"
check "host registration reserves ownership before Lua publication" contains "$IMPL" 'context->host_functions.reserve(context->host_functions.size() + 1)'
check "implementation catches host std::exception" contains "$IMPL" 'catch (const std::exception &error)'
check "implementation owns callback result strings" contains "$IMPL" 'host_result_string_storage'
check "implementation owns callback diagnostics" contains "$IMPL" 'host_callback_error_storage'
check "registration installs through a protected Lua call" contains "$IMPL" 'lua_pcall(context->lua, 1, 0, 0)'

check "C smoke covers host registration" contains "$SMOKE" 'register scalar host callback'
check "C smoke covers binary-safe host result" contains "$SMOKE" 'H\\0I'
check "C smoke covers host failure diagnostic" contains "$SMOKE" 'host callback sentinel'
check "C smoke covers uncaught host failure conversion" contains "$SMOKE" 'uncaught host callback failure'
check "C smoke proves recovery after uncaught host failure" contains "$SMOKE" 'host callback recovery after uncaught failure'
check "C smoke covers host callbacks from coroutines" bash -c "grep -Fq 'coroutine.wrap' '$SMOKE' && grep -Fq 'coroutine.create' '$SMOKE'"
check "C smoke covers hostile babet.host metamethod" contains "$SMOKE" 'host __newindex sentinel'
check "C smoke verifies call_global reaches host by relative counter" bash -c "grep -Fq 'echo_calls_before_call_global' '$SMOKE' && grep -Fq 'echo_calls_before_call_global + 1' '$SMOKE'"
check "C++ callback smoke exists" test -f "$CPP_SMOKE"
check "C++ callback smoke throws across callback body" contains "$CPP_SMOKE" 'throw std::runtime_error'
check "C++ callback smoke proves recovery" contains "$CPP_SMOKE" 'babet.host.ok_cpp() == 42'
check "C smoke covers reentrant run rejection" contains "$SMOKE" 'reentrant_run_status'
check "C smoke covers reentrant destroy rejection" contains "$SMOKE" 'reentrant_destroy_status'
check "C smoke proves workers lack host callbacks" contains "$SMOKE" 'return babet.host == nil'
check "C smoke covers late registration" contains "$SMOKE" 'late host callback registration'
check "C smoke covers wrong-thread registration" contains "$SMOKE" 'wrong-thread register host'
check "external SDK smoke consumes host registration API" contains "$EXT" 'babet_context_register_host_function'
check "standalone SDK ships a host-function example" test -f "$EXAMPLE"
check "host-function example returns a copied temporary string" contains "$EXAMPLE" 'Babet copies the temporary buffer synchronously here.'

check "FLTK prototype registers a public host function" contains "$FLTK" 'babet_context_register_host_function'
check "FLTK Lua fixture calls the host function" contains "$FLTK" 'babet.host.set_button_label'
check "FLTK host function updates the widget" contains "$FLTK" 'state->button->copy_label(label.c_str())'
check "FLTK prototype still avoids global polling" not_contains "$FLTK" 'babet_context_get_global'
check "FLTK prototype still avoids global mutation bridge" not_contains "$FLTK" 'babet_context_set_global'

echo "host-function contracts: ${pass} PASS / ${fail} FAIL"
exit "$fail"
