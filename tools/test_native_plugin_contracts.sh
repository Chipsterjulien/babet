#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

require_file() {
    if [ -f "${ROOT}/$1" ]; then pass "$2"; else fail "$2"; fi
}
require_grep() {
    if grep -Eq -- "$1" "${ROOT}/$2" 2>/dev/null; then pass "$3"; else fail "$3"; fi
}
require_not_grep() {
    if ! grep -Eq -- "$1" "${ROOT}/$2" 2>/dev/null; then pass "$3"; else fail "$3"; fi
}

require_file "include/babet/plugin.h" "public native plugin C header exists"
require_file "NATIVE_PLUGIN_DESIGN.md" "native plugin design contract exists"
require_file "NATIVE_PLUGINS.md" "English native plugin guide exists"
require_file "NATIVE_PLUGINS.fr.md" "French native plugin guide exists"
require_file "src/lua_bindings/native_plugin.cpp" "native plugin loader exists"
require_file "src/project_core/host_call_api.cpp" "generic host-call C API implementation exists"
require_file "tests/native_plugins/plugin_c.c" "C plugin runtime fixture exists"
require_file "tests/native_plugins/plugin_cpp.cpp" "C++ plugin runtime fixture exists"
require_file "tests/native_plugins/plugin_non_noexcept.cpp" "C++ negative noexcept fixture exists"
require_file "tests/native_plugins/plugin_bad_name_length.c" "bounded-name regression fixture exists"
require_file "tests/native_plugins/plugin_extended_function.c" "function-stride regression fixture exists"
require_file "tests/native_plugins/plugin_reserved_nonzero.c" "reserved-field regression fixture exists"
require_file "tools/test_native_plugin_runtime.sh" "native plugin runtime regression exists"
require_file "examples/native_plugin/CMakeLists.txt" "native plugin examples CMake project exists"

require_grep 'BABET_PLUGIN_ABI_VERSION_V1' "include/babet/plugin.h" "plugin ABI is explicitly versioned"
require_grep 'BABET_PLUGIN_QUERY_SYMBOL_V1.*babet_plugin_query_v1' "include/babet/plugin.h" "plugin query symbol is fixed"
require_grep 'struct_size' "include/babet/plugin.h" "plugin descriptor carries struct size"
require_grep 'function_struct_size' "include/babet/plugin.h" "plugin descriptor carries function declaration stride"
require_grep 'babet_plugin_callback_v1.*BABET_PLUGIN_NOEXCEPT|babet_plugin_callback_v1' "include/babet/plugin.h" "plugin has a dedicated noexcept-capable callback type"
require_grep 'babet_string_view name' "include/babet/plugin.h" "plugin function names are length-delimited"
require_not_grep 'lua_State' "include/babet/plugin.h" "public plugin ABI exposes no lua_State"
require_not_grep 'std::|#include <(string|vector|memory|exception)>|class[[:space:]]' "include/babet/plugin.h" "public plugin ABI exposes no STL/C++ object"

require_grep 'Binary-size reduction is explicitly \*\*not\*\* a motivation' "NATIVE_PLUGIN_DESIGN.md" "plugin motivation excludes binary-size reduction"
require_grep 'specialised/vendor SDK' "NATIVE_PLUGIN_DESIGN.md" "plugin motivation includes specialised/vendor SDKs"
require_grep 'fully trusted in-process code' "NATIVE_PLUGIN_DESIGN.md" "native plugins are explicitly trusted in-process"
require_grep 'There is no sandbox' "NATIVE_PLUGIN_DESIGN.md" "native plugin design promises no sandbox"
require_grep 'RTLD_NOW \| RTLD_LOCAL' "NATIVE_PLUGIN_DESIGN.md" "plugin ELF loading is local and eager"
require_grep 'never `dlclose\(\)`' "NATIVE_PLUGIN_DESIGN.md" "successful plugins stay loaded for process lifetime"
require_grep 'generated `--create-exe` applications' "NATIVE_PLUGIN_DESIGN.md" "generated applications explicitly reject plugins"
require_grep 'worker Lua states' "NATIVE_PLUGIN_DESIGN.md" "worker plugin loading is explicitly unavailable"
require_grep 'external embedding hosts' "NATIVE_PLUGIN_DESIGN.md" "embedding-host plugin loading is explicitly deferred"
require_grep 'package manager' "NATIVE_PLUGIN_DESIGN.md" "plugin package manager is explicitly absent"
require_grep 'Internet downloader' "NATIVE_PLUGIN_DESIGN.md" "plugin Internet downloader is explicitly absent"
require_grep 'automatic `require\(\)` discovery' "NATIVE_PLUGIN_DESIGN.md" "automatic plugin discovery is explicitly absent"
require_grep '/tmp.*extraction' "NATIVE_PLUGIN_DESIGN.md" "temporary extraction is explicitly absent"

require_grep 'dlopen\(prepared\.canonical_path\.c_str\(\), RTLD_NOW \| RTLD_LOCAL\)' "src/lua_bindings/native_plugin.cpp" "loader uses explicit RTLD_NOW|RTLD_LOCAL dlopen"
require_grep 'valid_shared_object_filename' "src/lua_bindings/native_plugin.cpp" "loader accepts explicit .so and numeric .so.<version> paths only"
require_grep 'std::isdigit' "src/lua_bindings/native_plugin.cpp" "versioned plugin suffixes are numeric dotted components"
require_grep 'descriptor->reserved != 0' "src/lua_bindings/native_plugin.cpp" "v1 reserved descriptor field fails closed unless zero"
require_grep 'BABET_PLUGIN_QUERY_SYMBOL_V1' "src/lua_bindings/native_plugin.cpp" "loader resolves only the versioned query symbol"
require_grep 'descriptor->abi_version != BABET_PLUGIN_ABI_VERSION_V1' "src/lua_bindings/native_plugin.cpp" "loader rejects incompatible plugin ABI"
require_grep 'BABET_PLUGIN_MAX_FUNCTIONS_V1' "src/lua_bindings/native_plugin.cpp" "plugin function count is bounded"
require_grep 'push_fail_protected\(state, error\)' "src/lua_bindings/native_plugin.cpp" "plugin loader reports owned C++ errors through a protected Lua builder"
require_grep 'path_already_loaded' "src/lua_bindings/native_plugin.cpp" "duplicate canonical plugin loads are rejected"
require_grep 'same_file_already_loaded' "src/lua_bindings/native_plugin.cpp" "hardlink aliases are rejected by underlying-file identity"
require_grep 'handle_already_loaded' "src/lua_bindings/native_plugin.cpp" "duplicate DSOs are rejected by dlopen handle identity"
require_grep 'same_native_plugin_runtime' "src/lua_bindings/native_plugin.cpp" "plugin runtime identity uses the shared Lua registry"
require_not_grep 'runtime->state_ != state' "src/lua_bindings/native_plugin.cpp" "plugin callbacks do not reject coroutine lua_State pointers"
require_not_grep 'strnlen\(declared\.name' "src/lua_bindings/native_plugin.cpp" "plugin function names are never scanned as unbounded C strings"
require_grep 'handle_guard\.release\(\)' "src/lua_bindings/native_plugin.cpp" "successful plugin handle is deliberately retained"
require_grep 'generated --create-exe applications' "src/lua_bindings/native_plugin.cpp" "generated application refusal is implemented"
require_grep 'unavailable in workers' "src/lua_bindings/native_plugin.cpp" "worker plugin refusal is implemented"
require_grep 'unavailable in embedding hosts' "src/lua_bindings/native_plugin.cpp" "embedding plugin refusal is implemented"
require_grep 'plugin\.functions' "NATIVE_PLUGIN_DESIGN.md" "plugin functions are returned in an explicit local table"

require_grep '--export-dynamic-symbol=babet_version' "CMakeLists.txt" "Babet exports plugin version helper"
require_grep '--export-dynamic-symbol=babet_status_name' "CMakeLists.txt" "Babet exports plugin status helper"
require_grep '--export-dynamic-symbol=babet_host_call_set_result' "CMakeLists.txt" "Babet exports plugin callback result symbol"
require_grep '--export-dynamic-symbol=babet_host_call_arguments' "CMakeLists.txt" "Babet exports plugin callback argument symbol"
require_grep '--undefined=babet_host_call_set_result' "CMakeLists.txt" "Babet forces the static callback API member into the executable"
require_grep 'check_linker_flag\(CXX' "CMakeLists.txt" "CMake probes export-dynamic-symbol linker support"
require_grep 'BABET_HAS_EXPORT_DYNAMIC_SYMBOL' "CMakeLists.txt" "unsupported plugin linker capability fails explicitly"
require_not_grep 'add_library\([^\n]*SHARED.*babet' "CMakeLists.txt" "Lot 11 still introduces no shared libbabet runtime"
require_grep 'test_native_plugin_contracts\.sh' "run_tests.sh" "normal validation runs native plugin structural contracts"
require_grep 'test_native_plugin_runtime\.sh' "run_tests.sh" "normal validation runs native plugin runtime regression"

require_grep 'babet_plugin_query_v1' "tests/native_plugins/plugin_c.c" "C fixture exports the v1 query symbol"
require_grep 'extern "C".*babet_plugin_query_v1.*noexcept' "tests/native_plugins/plugin_cpp.cpp" "C++ fixture exports a noexcept C query symbol"
require_grep 'std::string' "tests/native_plugins/plugin_cpp.cpp" "C++ fixture uses C++ internally"
require_grep 'extern "C" [{]' "tests/native_plugins/plugin_cpp.cpp" "C++ plugin callbacks use C linkage"
require_grep 'static babet_status decorate_callback' "tests/native_plugins/plugin_cpp.cpp" "C++ fixture callbacks stay local to the DSO"
require_grep 'static babet_status decorate' "examples/native_plugin/decorate_plugin.cpp" "official C++ example keeps callback symbol local"
require_grep 'caught C\+\+ plugin exception sentinel' "tests/native_plugins/plugin_cpp.cpp" "C++ fixture contains exceptions inside the plugin"
require_grep 'babet_host_call_set_result' "tests/native_plugins/plugin_cpp.cpp" "C++ fixture crosses back through copied scalar result"
require_grep 'babet_version\(\)' "tests/native_plugins/plugin_c.c" "C fixture consumes the exported Babet version helper"
require_grep 'babet_status_name' "tests/native_plugins/plugin_c.c" "C fixture consumes the exported status helper"
require_grep 'nm -D' "tools/test_native_plugin_runtime.sh" "runtime regression checks exported host symbols"
require_grep 'libbabet' "tools/test_native_plugin_runtime.sh" "runtime regression checks plugins do not depend on libbabet.so"
require_grep 'already loaded' "tools/test_native_plugin_runtime.sh" "runtime regression covers duplicate load rejection"
require_grep 'HARDLINK_PLUGIN' "tools/test_native_plugin_runtime.sh" "runtime regression covers hardlink duplicate identity"
require_grep 'VERSIONED_PLUGIN' "tools/test_native_plugin_runtime.sh" "runtime regression covers numeric .so.<version> loading"
require_grep 'INVALID_SUFFIX_PLUGIN' "tools/test_native_plugin_runtime.sh" "runtime regression rejects nonnumeric .so suffixes"
require_grep 'plugin_reserved_nonzero' "tools/test_native_plugin_runtime.sh" "runtime regression rejects nonzero reserved field"
require_grep 'decorate_callback\|caught_exception_callback' "tools/test_native_plugin_runtime.sh" "runtime regression checks callback symbols stay local"
require_grep 'coroutine\.(wrap|create)' "tools/test_native_plugin_runtime.sh" "runtime regression covers plugin calls and loading from coroutines"
require_grep 'plugin_non_noexcept' "tools/test_native_plugin_runtime.sh" "runtime regression compile-rejects non-noexcept C++ callbacks"
require_grep 'plugin_bad_name_length' "tools/test_native_plugin_runtime.sh" "runtime regression covers oversized length without NUL scanning"
require_grep 'plugin_extended_function' "tools/test_native_plugin_runtime.sh" "runtime regression covers forward-compatible function stride"
require_grep 'unsupported plugin ABI' "tools/test_native_plugin_runtime.sh" "runtime regression covers ABI mismatch"
require_grep 'missing required symbol' "tools/test_native_plugin_runtime.sh" "runtime regression covers missing entry symbol"
require_grep 'unavailable in workers' "tools/test_native_plugin_runtime.sh" "runtime regression covers worker refusal"
require_grep 'OUTPUT="\$\("\$\{BINARY\}"' "tools/test_native_plugin_runtime.sh" "runtime regression quotes Babet binary paths containing spaces"

require_grep 'does \*\*not\*\* promise to catch a C\+\+ exception' "NATIVE_PLUGIN_DESIGN.md" "design rejects cross-DSO C++ exception containment claims"
require_grep 'coroutines' "NATIVE_PLUGIN_DESIGN.md" "design documents coroutine support"
require_grep 'hardlinks' "NATIVE_PLUGIN_DESIGN.md" "design documents DSO identity beyond canonical paths"
require_grep 'numeric dotted version' "NATIVE_PLUGIN_DESIGN.md" "design documents strict versioned shared-object filenames"
require_grep 'must be zero' "NATIVE_PLUGIN_DESIGN.md" "design documents the v1 reserved-field rule"
require_grep 'Declared lengths are part of the trusted' "NATIVE_PLUGIN_DESIGN.md" "design documents trust in plugin-provided view lengths"

require_grep 'include/babet/plugin\.h' "tools/create_sdk.sh" "developer SDK publishes the plugin ABI header"
require_grep 'NATIVE_PLUGIN_DESIGN\.md' "tools/create_sdk.sh" "developer SDK publishes native plugin design"
require_grep 'examples/native_plugin' "tools/create_sdk.sh" "developer SDK publishes native plugin examples"
require_grep 'find include -type f -print0' "build_local.sh" "project source fingerprint covers plugin.h through the public include tree"
require_grep 'Lot 11 reopens native plugins' "INVARIANTS.md" "project invariants record the narrow Lot 11 native-plugin reopening"
require_grep 'Generated `--create-exe`' "INVARIANTS.md" "project invariants preserve generated-application plugin refusal"
require_grep 'not by reducing Babet.s binary size' "INVARIANTS.md" "project invariants reject binary size as plugin motivation"
require_grep 'plugin\.h' "README.md" "English SDK overview names the native plugin public header"
require_grep 'plugin\.h' "README.fr.md" "French SDK overview names the native plugin public header"
require_grep 'loading native plugins from an external embedding context' "EMBEDDING.md" "English embedding guide distinguishes plugin ABI from embedding loader support"
require_grep "chargement de plugins natifs depuis un contexte d.embedding externe" "EMBEDDING.fr.md" "French embedding guide distinguishes plugin ABI from embedding loader support"
require_grep 'embedded contexts deliberately register `babet.plugin.load\(\)` in refusal' "EMBEDDING_DESIGN.md" "embedding design records Lot 11 loader separation"

printf 'native plugin structural contracts: %d PASS / %d FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
