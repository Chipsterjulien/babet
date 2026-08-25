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
BAD_NAME_PLUGIN="${TMP}/plugins/bad-name-length.so"
EXTENDED_PLUGIN="${TMP}/plugins/extended-function.so"
RESERVED_PLUGIN="${TMP}/plugins/reserved-nonzero.so"
HARDLINK_PLUGIN="${TMP}/plugins/fixture-c-hardlink.so"
VERSIONED_PLUGIN="${TMP}/plugins/fixture-versioned.so.1.2.3"
INVALID_SUFFIX_PLUGIN="${TMP}/plugins/fixture-invalid.so.txt"

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
        -o "${MISSING_PLUGIN}" && \
   cc -std=c11 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        -I"${ROOT}/include" "${ROOT}/tests/native_plugins/plugin_bad_name_length.c" \
        -o "${BAD_NAME_PLUGIN}" && \
   cc -std=c11 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        -I"${ROOT}/include" "${ROOT}/tests/native_plugins/plugin_extended_function.c" \
        -o "${EXTENDED_PLUGIN}" && \
   cc -std=c11 -fPIC -shared -Wall -Wextra -Wpedantic -Werror \
        -I"${ROOT}/include" "${ROOT}/tests/native_plugins/plugin_reserved_nonzero.c" \
        -o "${RESERVED_PLUGIN}" && \
   ln -- "${C_PLUGIN}" "${HARDLINK_PLUGIN}" && \
   cp -- "${C_PLUGIN}" "${VERSIONED_PLUGIN}" && \
   cp -- "${C_PLUGIN}" "${INVALID_SUFFIX_PLUGIN}"; then
    pass "C/C++ and malformed native plugin fixtures build as standalone shared objects"
else
    fail "C/C++ and malformed native plugin fixtures build as standalone shared objects"
fi

# In C++, the plugin callback type is noexcept. A callback without noexcept
# must therefore be rejected at compile time instead of relying on a host-side
# catch across potentially different C++ runtimes.
if c++ -std=c++23 -Wall -Wextra -Wpedantic -Werror -I"${ROOT}/include" \
       -c "${ROOT}/tests/native_plugins/plugin_non_noexcept.cpp" \
       -o "${TMP}/plugin_non_noexcept.o" >/dev/null 2>&1; then
    fail "C++ plugin ABI rejects potentially-throwing callbacks at compile time"
else
    pass "C++ plugin ABI rejects potentially-throwing callbacks at compile time"
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

if nm -D "${CPP_PLUGIN}" 2>/dev/null | grep -Eq '[[:space:]](decorate_callback|caught_exception_callback)$'; then
    fail "C++ fixture exports only the query symbol from its plugin API"
else
    pass "C++ fixture exports only the query symbol from its plugin API"
fi

cat > "${TMP}/project/main.lua" <<'LUA'
local c_path, cpp_path, bad_path, missing_path, bad_name_path,
      extended_path, reserved_path, hardlink_path, versioned_path,
      invalid_suffix_path =
      arg[1], arg[2], arg[3], arg[4], arg[5], arg[6], arg[7], arg[8], arg[9], arg[10]

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

-- Host/plugin thunks must accept coroutine lua_State* values that share the
-- same global registry as the main thread.
assert(coroutine.wrap(function() return c.functions.add(7, 8) end)() == 15)
local co = coroutine.create(function() return c.functions.echo("co") end)
local resumed, co_value = coroutine.resume(co)
assert(resumed == true and co_value == "C:co")

local unsupported_ok, unsupported_err = pcall(c.functions.echo, {})
assert(not unsupported_ok and tostring(unsupported_err):find("unsupported type", 1, true))

local duplicate, duplicate_err = babet.plugin.load(c_path)
assert(duplicate == nil and type(duplicate_err) == "string"
       and duplicate_err:find("already loaded", 1, true))

-- A hardlink is a different canonical pathname but the same underlying DSO.
local hardlink, hardlink_err = babet.plugin.load(hardlink_path)
assert(hardlink == nil and type(hardlink_err) == "string"
       and hardlink_err:find("already loaded", 1, true))

-- Exercise plugin.load itself from a coroutine.
local cpp, cpp_err = coroutine.wrap(function()
    return babet.plugin.load(cpp_path)
end)()
assert(cpp, cpp_err)
local cpp_co = coroutine.create(function()
    return cpp.functions.decorate("value")
end)
local cpp_resumed, cpp_value = coroutine.resume(cpp_co)
assert(cpp_resumed == true and cpp_value == "cpp:value")

-- The C++ callback intentionally throws internally, catches inside the plugin,
-- reports a Lua error, then the same plugin remains usable. This is run against
-- the official statically-linked Babet binary, not only sanitizer builds.
local exception_ok, exception_err = pcall(cpp.functions.caught_exception)
assert(exception_ok == false)
assert(tostring(exception_err):find("caught C++ plugin exception sentinel", 1, true))
assert(cpp.functions.decorate("after") == "cpp:after")

local bad, bad_err = babet.plugin.load(bad_path)
assert(bad == nil and type(bad_err) == "string"
       and bad_err:find("unsupported plugin ABI", 1, true))

local missing, missing_err = babet.plugin.load(missing_path)
assert(missing == nil and type(missing_err) == "string"
       and missing_err:find("missing required symbol", 1, true))

-- The bad name declares a length above the public limit while its backing
-- buffer has no NUL. The loader must reject by length before reading the bytes.
local bad_name, bad_name_err = babet.plugin.load(bad_name_path)
assert(bad_name == nil and type(bad_name_err) == "string"
       and bad_name_err:find("invalid function declaration", 1, true))

-- A larger function declaration stride proves the v1 prefix can grow without
-- silently changing array indexing.
local extended, extended_err = babet.plugin.load(extended_path)
assert(extended, extended_err)
assert(extended.functions.answer() == 42)

-- Reserved ABI fields are zero in v1 so older hosts fail closed if a future
-- plugin assigns semantics to them.
local reserved, reserved_err = babet.plugin.load(reserved_path)
assert(reserved == nil and type(reserved_err) == "string"
       and reserved_err:find("reserved field must be zero", 1, true))

-- Only numeric dotted ELF version suffixes are accepted after .so.
local invalid_suffix, invalid_suffix_err = babet.plugin.load(invalid_suffix_path)
assert(invalid_suffix == nil and type(invalid_suffix_err) == "string"
       and invalid_suffix_err:find("must end in .so or .so.<version>", 1, true))

-- Versioned Linux shared-object filenames are accepted explicitly.
local versioned_co = coroutine.create(function()
    return babet.plugin.load(versioned_path)
end)
local versioned_resumed, versioned, versioned_err = coroutine.resume(versioned_co)
assert(versioned_resumed == true and versioned, tostring(versioned_err))
assert(versioned.functions.add(2, 3) == 5)

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
                   "${BAD_PLUGIN}" "${MISSING_PLUGIN}" "${BAD_NAME_PLUGIN}" \
                   "${EXTENDED_PLUGIN}" "${RESERVED_PLUGIN}" \
                   "${HARDLINK_PLUGIN}" "${VERSIONED_PLUGIN}" \
                   "${INVALID_SUFFIX_PLUGIN}" 2>&1)"
RC=$?
if [ "${RC}" -eq 0 ] && grep -Fxq 'NATIVE_PLUGIN_RUNTIME_OK' <<<"${OUTPUT}"; then
    pass "plugin loading, coroutines, ABI stride, reserved/filename contracts and rejection paths work"
else
    fail "plugin loading, coroutines, ABI stride, reserved/filename contracts and rejection paths work" \
         "rc=${RC}; output=${OUTPUT}"
fi

echo "native plugin runtime regression: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
