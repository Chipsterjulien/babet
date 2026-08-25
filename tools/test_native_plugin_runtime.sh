#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-}"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+ - $2}"; FAIL=$((FAIL + 1)); }

if [ -z "${BINARY}" ] || [ ! -x "${BINARY}" ]; then
    echo "native plugin runtime: missing Babet binary" >&2
    exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-native-plugin.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP}"' EXIT
mkdir -p "${TMP}/plugins" "${TMP}/project"

C_PLUGIN="${TMP}/plugins/fixture-c.so"
CPP_PLUGIN="${TMP}/plugins/fixture-cpp.so"
BAD_PLUGIN="${TMP}/plugins/bad-abi.so"
MISSING_PLUGIN="${TMP}/plugins/missing-symbol.so"

if cc -std=c11 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        -I"${ROOT}/include" "${ROOT}/tests/native_plugins/plugin_c.c" \
        -o "${C_PLUGIN}" && \
   c++ -std=c++23 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        -I"${ROOT}/include" "${ROOT}/tests/native_plugins/plugin_cpp.cpp" \
        -o "${CPP_PLUGIN}" && \
   cc -std=c11 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        -I"${ROOT}/include" "${ROOT}/tests/native_plugins/plugin_bad_abi.c" \
        -o "${BAD_PLUGIN}" && \
   cc -std=c11 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        "${ROOT}/tests/native_plugins/plugin_missing_symbol.c" \
        -o "${MISSING_PLUGIN}"; then
    pass "C and C++ native plugin fixtures build as standalone shared objects"
else
    fail "C and C++ native plugin fixtures build as standalone shared objects"
fi

if nm -D "${BINARY}" 2>/dev/null | grep -Eq '[[:space:]]babet_version$' && \
   nm -D "${BINARY}" 2>/dev/null | grep -Eq '[[:space:]]babet_status_name$' && \
   nm -D "${BINARY}" 2>/dev/null | grep -Eq '[[:space:]]babet_host_call_argument_count$' && \
   nm -D "${BINARY}" 2>/dev/null | grep -Eq '[[:space:]]babet_host_call_arguments$' && \
   nm -D "${BINARY}" 2>/dev/null | grep -Eq '[[:space:]]babet_host_call_set_result$' && \
   nm -D "${BINARY}" 2>/dev/null | grep -Eq '[[:space:]]babet_host_call_set_error$'; then
    pass "Babet exports the complete narrow C surface required by plugins"
else
    fail "Babet exports the complete narrow C surface required by plugins"
fi

if ! ldd "${C_PLUGIN}" 2>/dev/null | grep -Fq 'libbabet' && \
   ! ldd "${CPP_PLUGIN}" 2>/dev/null | grep -Fq 'libbabet'; then
    pass "native plugins have no dynamic libbabet dependency"
else
    fail "native plugins have no dynamic libbabet dependency"
fi

cat > "${TMP}/project/main.lua" <<'LUA'
local c_path, cpp_path, bad_path, missing_path = arg[1], arg[2], arg[3], arg[4]

assert(type(babet.plugin) == "table" and type(babet.plugin.load) == "function")

local c, c_err = babet.plugin.load(c_path)
assert(c, c_err)
assert(c.name == "lot11-c-fixture" and c.version == "1.0.0" and c.abi == 1)
assert(type(c.path) == "string" and type(c.functions) == "table")
assert(c.functions.add(20, 22) == 42)
assert(c.functions.version() == "2.22.2")
assert(c.functions.status_name() == "ok")
local binary = "A\0B"
assert(c.functions.echo(binary) == "C:" .. binary)

local unsupported_ok, unsupported_err = pcall(c.functions.echo, {})
assert(not unsupported_ok and tostring(unsupported_err):find("unsupported type", 1, true))

local duplicate, duplicate_err = babet.plugin.load(c_path)
assert(duplicate == nil and type(duplicate_err) == "string"
       and duplicate_err:find("already loaded", 1, true))

local cpp, cpp_err = babet.plugin.load(cpp_path)
assert(cpp, cpp_err)
assert(cpp.functions.decorate("value") == "cpp:value")

local bad, bad_err = babet.plugin.load(bad_path)
assert(bad == nil and type(bad_err) == "string"
       and bad_err:find("unsupported plugin ABI", 1, true))

local missing, missing_err = babet.plugin.load(missing_path)
assert(missing == nil and type(missing_err) == "string"
       and missing_err:find("missing required symbol", 1, true))

local worker = assert(babet.workers.spawn([[
    local loaded, err = babet.plugin.load("/definitely/not/a/plugin.so")
    return loaded == nil and type(err) == "string"
           and err:find("unavailable in workers", 1, true) ~= nil
]]))
local worker_ok, worker_result = worker:join()
assert(worker_ok == true and worker_result == true)

print("NATIVE_PLUGIN_RUNTIME_OK")
LUA

OUTPUT="$("${BINARY}" "${TMP}/project" "${C_PLUGIN}" "${CPP_PLUGIN}" \
                   "${BAD_PLUGIN}" "${MISSING_PLUGIN}" 2>&1)"
RC=$?
if [ "${RC}" -eq 0 ] && grep -Fxq 'NATIVE_PLUGIN_RUNTIME_OK' <<<"${OUTPUT}"; then
    pass "explicit C/C++ plugin loading, scalar calls and rejection paths work"
else
    fail "explicit C/C++ plugin loading, scalar calls and rejection paths work" \
         "rc=${RC}; output=${OUTPUT}"
fi

echo "native plugin runtime regression: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
