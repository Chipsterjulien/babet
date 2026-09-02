#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

require_file() {
    if [ -f "${SCRIPT_DIR}/$1" ]; then pass "$2"; else fail "$2"; fi
}

require_grep() {
    local pattern="$1" file="$2" label="$3"
    if grep -Eq -- "${pattern}" "${SCRIPT_DIR}/${file}"; then pass "${label}"; else fail "${label}"; fi
}

forbid_grep() {
    local pattern="$1" file="$2" label="$3"
    if grep -Eq -- "${pattern}" "${SCRIPT_DIR}/${file}"; then fail "${label}"; else pass "${label}"; fi
}

require_file "EMBEDDING_DESIGN.md" "embedding design contract exists"
require_file "HOST_FUNCTIONS_DESIGN.md" "host-function design contract exists"
require_file "EMBEDDING.md" "English embedding developer guide exists"
require_file "EMBEDDING.fr.md" "French embedding developer guide exists"
require_file "examples/embedding/CMakeLists.txt" "standalone embedding example CMake project exists"
require_file "examples/embedding/README.md" "embedding example quick-start exists"
require_file "examples/embedding/01_hello.c" "minimal embedding example exists"
require_file "examples/embedding/02_search_root.c" "search-root embedding example exists"
require_file "examples/embedding/03_values.c" "scalar-value embedding example exists"
require_file "examples/embedding/04_call.c" "direct-call embedding example exists"
require_file "examples/embedding/05_errors.c" "error-recovery embedding example exists"
require_file "examples/embedding/06_lifecycle_threads.c" "lifecycle/threading embedding example exists"
require_file "examples/embedding/07_host_functions.c" "host-function embedding example exists"
require_file "include/babet/babet.h" "public embedding C header exists"
require_file "src/embedding/babet_c_api.cpp" "embedding C implementation exists"
require_file "tests/embedding_smoke.c" "embedding smoke host is written in C"
require_file "tests/embedding_external_smoke.c" "external standalone SDK smoke host is written in C"
require_file "tools/create_sdk.sh" "standalone developer SDK builder exists"
require_file "tools/test_sdk_builder.sh" "standalone SDK builder regression exists"

require_grep 'static `libbabet\.a`' "EMBEDDING_DESIGN.md" "static-first embedding artifact is explicit"
require_grep 'runtime.*libbabet\.so|libbabet\.so.*dependency' "EMBEDDING_DESIGN.md" "official CLI autonomy is explicit"
require_grep 'exactly one live embedded context' "EMBEDDING_DESIGN.md" "single-context first contract is explicit"
require_grep 'created, used and destroyed by one host thread' "EMBEDDING_DESIGN.md" "same-thread context lifecycle is explicit"
require_grep 'No `lua_State`' "EMBEDDING_DESIGN.md" "Lua internals are excluded from public ABI"
require_grep 'No C\+\+ exception may cross' "EMBEDDING_DESIGN.md" "C exception boundary is explicit"
require_grep 'experimental through Lot 10' "EMBEDDING_DESIGN.md" "public ABI is not frozen prematurely"
require_grep 'exactly one explicit module search root' "EMBEDDING_DESIGN.md" "embedding design defines a single explicit module root"
require_grep 'before its first Lua execution call' "EMBEDDING_DESIGN.md" "embedding design freezes search root before execution"
require_grep 'same absolute root is propagated to workers' "EMBEDDING_DESIGN.md" "embedding design keeps parent and worker module roots aligned"
require_grep 'only five scalar types' "EMBEDDING_DESIGN.md" "embedding design limits first value exchange to scalars"
require_grep 'BABET_STATUS_UNSUPPORTED_VALUE' "EMBEDDING_DESIGN.md" "embedding design rejects unsupported structured values explicitly"
require_grep 'context-owned storage' "EMBEDDING_DESIGN.md" "embedding design defines returned string lifetime"
require_grep 'does not implicitly copy globals into workers' "EMBEDDING_DESIGN.md" "embedding design preserves worker global isolation"
require_grep 'babet_context_call_global\(\)' "EMBEDDING_DESIGN.md" "embedding design defines direct scalar global calls"
require_grep 'requests exactly one result' "EMBEDDING_DESIGN.md" "embedding design fixes one-result call semantics"
require_grep 'missing/non-function global or a Lua exception returns' "EMBEDDING_DESIGN.md" "embedding design classifies bad call targets as Lua errors"
require_grep 'does not resolve dotted method paths' "EMBEDDING_DESIGN.md" "embedding design defers dotted method lookup"
require_grep 'relocatable static SDK' "EMBEDDING_DESIGN.md" "embedding design defines a relocatable standalone SDK"
require_grep 'flattened `libbabet\.a`' "EMBEDDING_DESIGN.md" "embedding design defines a flattened standalone archive"
require_grep 'C\+\+ linker driver' "EMBEDDING_DESIGN.md" "embedding design documents the C++ final-link requirement"
require_grep 'linker garbage collection is not a host requirement' "EMBEDDING_DESIGN.md" "embedding design keeps linker GC optional for SDK consumers"
require_grep 'same.*object again with `-Wl,--gc-sections`|`-Wl,--gc-sections`' "EMBEDDING_DESIGN.md" "embedding design requires separate GC-link compatibility coverage"

require_grep 'babet_context_create\(\)' "EMBEDDING.md" "English guide documents the minimal lifecycle"
require_grep 'babet_context_set_search_root\(\)' "EMBEDDING.md" "English guide documents search-root use"
require_grep 'BABET_VALUE_STRING' "EMBEDDING.md" "English guide documents scalar values"
require_grep 'borrowed from the context' "EMBEDDING.md" "English guide documents borrowed string lifetime"
require_grep 'babet_context_call_global\(\)' "EMBEDDING.md" "English guide documents direct Lua calls"
require_grep 'BABET_STATUS_BUSY' "EMBEDDING.md" "English guide documents single-context contention"
require_grep 'BABET_STATUS_WRONG_THREAD' "EMBEDDING.md" "English guide documents thread ownership"
require_grep 'objdump -T' "EMBEDDING.md" "English guide documents GLIBC symbol measurement"
require_grep 'not currently promise a fixed `glibc >= X`' "EMBEDDING.md" "English guide avoids a false glibc baseline promise"
require_grep 'babet_context_create\(\)' "EMBEDDING.fr.md" "French guide documents the minimal lifecycle"
require_grep 'babet_context_set_search_root\(\)' "EMBEDDING.fr.md" "French guide documents search-root use"
require_grep 'BABET_VALUE_STRING' "EMBEDDING.fr.md" "French guide documents scalar values"
require_grep 'emprunté au contexte' "EMBEDDING.fr.md" "French guide documents borrowed string lifetime"
require_grep 'babet_context_call_global\(\)' "EMBEDDING.fr.md" "French guide documents direct Lua calls"
require_grep 'BABET_STATUS_BUSY' "EMBEDDING.fr.md" "French guide documents single-context contention"
require_grep 'BABET_STATUS_WRONG_THREAD' "EMBEDDING.fr.md" "French guide documents thread ownership"
require_grep 'objdump -T' "EMBEDDING.fr.md" "French guide documents GLIBC symbol measurement"
require_grep 'ne promet actuellement aucun seuil fixe `glibc >= X`' "EMBEDDING.fr.md" "French guide avoids a false glibc baseline promise"

require_grep 'babet_context_create' "examples/embedding/01_hello.c" "minimal example creates an embedding context"
require_grep 'babet_context_set_search_root' "examples/embedding/02_search_root.c" "search-root example configures a module root"
require_grep "require\('greeting'\)" "examples/embedding/02_search_root.c" "search-root example requires a host module"
require_grep 'BABET_VALUE_STRING' "examples/embedding/03_values.c" "value example sends a binary-safe string"
require_grep 'babet_context_get_global' "examples/embedding/03_values.c" "value example reads a Lua scalar"
require_grep 'babet_context_call_global' "examples/embedding/04_call.c" "call example invokes a Lua global"
require_grep 'BABET_STATUS_LUA_ERROR' "examples/embedding/05_errors.c" "error example checks Lua failure classification"
require_grep 'recovered' "examples/embedding/05_errors.c" "error example proves context recovery"
require_grep 'BABET_STATUS_BUSY' "examples/embedding/06_lifecycle_threads.c" "lifecycle example checks second-context rejection"
require_grep 'BABET_STATUS_WRONG_THREAD' "examples/embedding/06_lifecycle_threads.c" "lifecycle example checks wrong-thread rejection"
require_grep 'BABET_SDK_DIR' "examples/embedding/CMakeLists.txt" "example CMake project consumes the standalone SDK"
require_grep 'LINKER_LANGUAGE CXX' "examples/embedding/CMakeLists.txt" "example CMake project uses a C++ final linker"

require_grep 'typedef struct babet_context babet_context;' "include/babet/babet.h" "public context is opaque"
require_grep 'extern "C"' "include/babet/babet.h" "public header supports C++ hosts through a C ABI"
forbid_grep 'lua_State|std::|#include[[:space:]]*<lua|class[[:space:]]' "include/babet/babet.h" "public header exposes no Lua/C++ implementation type"
require_grep 'BABET_STATUS_BUSY' "include/babet/babet.h" "public status surface represents single-context contention"
require_grep 'BABET_STATUS_WRONG_THREAD' "include/babet/babet.h" "public status surface represents wrong-thread use"
require_grep 'babet_context_set_search_root' "include/babet/babet.h" "public API exposes explicit search-root configuration"
require_grep 'before the first Lua execution call' "include/babet/babet.h" "search-root lifecycle is explicit in public header"
require_grep 'same \?\.lua and \?/init\.lua' "include/babet/babet.h" "public search-root semantics match folder mode"
require_grep 'BABET_STATUS_UNSUPPORTED_VALUE' "include/babet/babet.h" "public status surface represents unsupported Lua values"
require_grep 'typedef uint32_t babet_value_type;' "include/babet/babet.h" "public scalar value tag is fixed-width and accepts unknown values safely"
require_grep 'typedef uint32_t babet_status;' "include/babet/babet.h" "public status tag is fixed-width and accepts unknown values safely"
forbid_grep 'typedef enum babet_(status|value_type)' "include/babet/babet.h" "public ABI does not expose invalid-prone enum objects"
require_grep 'BABET_VALUE_NIL' "include/babet/babet.h" "public scalar values include nil"
require_grep 'BABET_VALUE_BOOLEAN' "include/babet/babet.h" "public scalar values include boolean"
require_grep 'BABET_VALUE_INTEGER' "include/babet/babet.h" "public scalar values include signed integer"
require_grep 'BABET_VALUE_NUMBER' "include/babet/babet.h" "public scalar values include number"
require_grep 'BABET_VALUE_STRING' "include/babet/babet.h" "public scalar values include byte string"
require_grep 'int64_t integer' "include/babet/babet.h" "public integer marshalling is explicitly 64-bit"
require_grep 'size_t length' "include/babet/babet.h" "public string marshalling is length-delimited"
require_grep 'babet_context_set_global' "include/babet/babet.h" "public API exposes C-to-Lua scalar globals"
require_grep 'babet_context_get_global' "include/babet/babet.h" "public API exposes Lua-to-C scalar globals"
require_grep 'babet_context_call_global' "include/babet/babet.h" "public API exposes scalar global function calls"
require_grep 'one Lua result is requested' "include/babet/babet.h" "public call API documents one-result semantics"
require_grep 'extra Lua results are discarded' "include/babet/babet.h" "public call API documents extra-result discard"

require_grep 'std::mutex g_context_mutex' "src/embedding/babet_c_api.cpp" "embedding context ownership is serialized"
require_grep 'g_active_context' "src/embedding/babet_c_api.cpp" "embedding enforces one active context"
require_grep 'register_main_thread\(\)' "src/embedding/babet_c_api.cpp" "embedding captures the host owner thread"
require_grep 'register_bundled_modules\(state\)' "src/embedding/babet_c_api.cpp" "embedding installs bundled Lua modules"
require_grep 'register_babet\(state, nullptr, NativePluginMode::embedding\)' "src/embedding/babet_c_api.cpp" "embedding installs the complete Babet Lua API with explicit native-plugin refusal mode"
require_grep 'babet_context_set_search_root' "src/embedding/babet_c_api.cpp" "embedding implements explicit search-root configuration"
require_grep 'fs::absolute' "src/embedding/babet_c_api.cpp" "embedding resolves search root to an absolute path"
require_grep 'fs::is_directory' "src/embedding/babet_c_api.cpp" "embedding rejects non-directory search roots"
require_grep 'std::errc::no_such_file_or_directory' "src/embedding/babet_c_api.cpp" "missing search roots are classified as invalid arguments"
require_grep 'std::errc::not_a_directory' "src/embedding/babet_c_api.cpp" "non-directory path errors are classified as invalid arguments"
require_grep 'execution_started' "src/embedding/babet_c_api.cpp" "embedding freezes search root once execution starts"
require_grep 'set_workers_init_context\(std::move\(worker_root\)' "src/embedding/babet_c_api.cpp" "embedding propagates search root to worker initialization"
require_grep 'prepend_babet_package_path\(state, package_prefix\)' "src/embedding/babet_c_api.cpp" "embedding reuses shared protected package-path helper"
require_grep 'value_string_storage' "src/embedding/babet_c_api.cpp" "embedding owns returned scalar string storage"
require_grep 'set_global_thunk' "src/embedding/babet_c_api.cpp" "C-to-Lua scalar emission runs through a protected thunk"
require_grep 'get_global_thunk' "src/embedding/babet_c_api.cpp" "Lua-to-C scalar lookup runs through a protected thunk"
require_grep 'lua_pcall\(context->lua, 1, 0, 0\)' "src/embedding/babet_c_api.cpp" "C-to-Lua scalar mutation catches Lua longjmp failures"
require_grep 'lua_pcall\(context->lua, 1, 1, 0\)' "src/embedding/babet_c_api.cpp" "Lua-to-C scalar lookup catches Lua longjmp failures"
require_grep 'BABET_STATUS_UNSUPPORTED_VALUE' "src/embedding/babet_c_api.cpp" "structured Lua values return explicit unsupported status"
require_grep 'owned_string.assign' "src/embedding/babet_c_api.cpp" "borrowed string round-trip copies input before invalidation"
require_grep 'call_global_thunk' "src/embedding/babet_c_api.cpp" "scalar global calls run through a protected thunk"
require_grep 'lua_call\(state, static_cast<int>\(operation->arguments->size\(\)\), 1\)' "src/embedding/babet_c_api.cpp" "scalar global calls request exactly one Lua result"
require_grep 'owned_arguments.reserve' "src/embedding/babet_c_api.cpp" "call arguments are copied before context invalidation"
require_grep 'read_scalar_result' "src/embedding/babet_c_api.cpp" "global reads and calls share scalar result conversion"
require_grep 'context->execution_started = true' "src/embedding/babet_c_api.cpp" "direct Lua calls freeze the search-root lifecycle"
require_grep 'close_babet_lua_state\(context->lua\)' "src/embedding/babet_c_api.cpp" "embedding uses shared terminal-aware teardown"
require_grep 'catch \(' "src/embedding/babet_c_api.cpp" "C API has explicit C++ exception containment"

forbid_grep '^void register_babet\(' "src/main.cpp" "register_babet implementation no longer lives in CLI main"
require_grep 'runtime_registration\.hpp' "src/main.cpp" "CLI consumes shared runtime registration"
require_grep 'runtime_registration\.hpp' "src/lua_bindings/workers.cpp" "workers consume shared runtime registration"
require_grep '^void register_babet\(' "src/project_core/runtime_registration.cpp" "runtime registration has one reusable implementation"
require_grep '^void close_babet_lua_state\(' "src/project_core/runtime_registration.cpp" "terminal-aware Lua teardown has one reusable implementation"
require_grep '^void prepend_babet_package_path\(' "src/project_core/runtime_registration.cpp" "package-path mutation has one reusable implementation"
require_grep 'prepend_babet_package_path\(state, package_prefix\)' "src/main.cpp" "CLI uses shared package-path helper"
require_grep 'prepend_babet_package_path\(state, package_prefix\)' "src/lua_bindings/workers.cpp" "workers use shared package-path helper"

require_grep 'add_library\(\$\{BABET_RUNTIME_TARGET\} STATIC' "CMakeLists.txt" "CMake builds a static libbabet runtime"
require_grep 'OUTPUT_NAME babet' "CMakeLists.txt" "static runtime artifact is named libbabet"
require_grep 'target_link_libraries\(\$\{PROJECT_NAME\} PRIVATE \$\{BABET_RUNTIME_TARGET\}\)' "CMakeLists.txt" "official CLI links libbabet statically at build time"
forbid_grep 'add_library\([^)]*SHARED' "CMakeLists.txt" "Lot 6 does not introduce a shared libbabet runtime"
require_grep 'add_executable\(babet_embedding_smoke EXCLUDE_FROM_ALL' "CMakeLists.txt" "C smoke host is an explicit non-product build target"
require_grep 'LINKER_LANGUAGE CXX' "CMakeLists.txt" "C host links the C++ runtime with the correct linker driver"

require_grep 'find include -type f -print0' "build_local.sh" "build source fingerprint includes the public embedding header"
require_grep 'create_sdk\.sh' "build_local.sh" "normal build creates the standalone developer SDK"
require_grep 'ABSL_STATIC_LIBS' "build_local.sh" "standalone SDK includes pinned Abseil static archives"
require_grep 'SDK développeur autonome : non généré pour le build sanitizer' "build_local.sh" "sanitizer build does not masquerade as a redistributable SDK"
require_grep 'test_embedding_runtime\.sh' "run_tests.sh" "normal validation runs the embedding runtime smoke test"
require_grep 'test_embedding_contracts\.sh' "run_tests.sh" "normal validation runs the embedding structural preflight"
require_grep 'test_sdk_builder\.sh' "run_tests.sh" "normal validation runs the standalone SDK builder preflight"
require_grep 'ASAN_UBSAN.*EMBEDDING_ARGS\+=\(--sanitizers\)' "run_tests.sh" "ASan/UBSan validation selects the instrumented embedding build"
require_grep 'UBSAN.*EMBEDDING_ARGS\+=\(--ubsan\)' "run_tests.sh" "UBSan validation selects the UBSan embedding build"

require_grep 'BABET_STATUS_BUSY' "tests/embedding_smoke.c" "smoke host exercises second-context rejection"
require_grep 'babet\.base64\.encode' "tests/embedding_smoke.c" "smoke host exercises a real Babet binding"
require_grep 'babet\.json\.decode' "tests/embedding_smoke.c" "smoke host exercises a Babet submodule"
require_grep "require\('inspect'\)" "tests/embedding_smoke.c" "smoke host exercises a bundled module"
require_grep "inspect\(\{answer=42\}\)" "tests/embedding_smoke.c" "smoke host functionally exercises bundled inspect module"
require_grep 'babet\.workers\.spawn' "tests/embedding_smoke.c" "smoke host exercises worker runtime reuse"
require_grep 'embedding sentinel' "tests/embedding_smoke.c" "smoke host exercises Lua error diagnostics"
require_grep 'BABET_STATUS_WRONG_THREAD' "tests/embedding_smoke.c" "smoke host exercises wrong-thread rejection"
require_grep 'recreate' "tests/embedding_smoke.c" "smoke host exercises sequential context recreation"
require_grep 'host_module\.lua' "tests/embedding_smoke.c" "smoke host creates an external Lua module fixture"
require_grep 'host_pkg/init\.lua' "tests/embedding_smoke.c" "smoke host creates an init.lua package fixture"
require_grep 'file search root' "tests/embedding_smoke.c" "smoke host rejects an existing regular file as search root"
require_grep 'missing search root' "tests/embedding_smoke.c" "smoke host rejects a missing search root as invalid argument"
require_grep 'babet_context_set_search_root\(context, g_search_root\)' "tests/embedding_smoke.c" "smoke host configures the explicit search root"
require_grep "require\('host_module'\)" "tests/embedding_smoke.c" "main embedded state requires a module from the host root"
require_grep "require\('host_pkg'\)" "tests/embedding_smoke.c" "main embedded state exercises root ?/init.lua semantics"
require_grep 'workers\.spawn.*host_module' "tests/embedding_smoke.c" "worker requires a module from the same host root"
require_grep 'search root after run' "tests/embedding_smoke.c" "smoke host rejects late search-root mutation"
require_grep 'wrong-thread search root' "tests/embedding_smoke.c" "smoke host rejects search-root mutation from another thread"
require_grep 'set host nil' "tests/embedding_smoke.c" "smoke host sends nil from C to Lua"
require_grep 'set host boolean' "tests/embedding_smoke.c" "smoke host sends boolean from C to Lua"
require_grep 'set host integer' "tests/embedding_smoke.c" "smoke host sends integer from C to Lua"
require_grep 'set host number' "tests/embedding_smoke.c" "smoke host sends number from C to Lua"
require_grep 'set host byte string' "tests/embedding_smoke.c" "smoke host sends binary string from C to Lua"
require_grep 'get Lua byte string' "tests/embedding_smoke.c" "smoke host reads binary string from Lua to C"
require_grep 'round-trip borrowed string' "tests/embedding_smoke.c" "smoke host round-trips borrowed binary string safely"
require_grep 'BABET_STATUS_UNSUPPORTED_VALUE' "tests/embedding_smoke.c" "smoke host rejects structured Lua values explicitly"
require_grep 'wrong-thread set global' "tests/embedding_smoke.c" "smoke host rejects C-to-Lua values from wrong thread"
require_grep 'wrong-thread get global' "tests/embedding_smoke.c" "smoke host rejects Lua-to-C values from wrong thread"
require_grep 'call Lua scalar function' "tests/embedding_smoke.c" "smoke host calls Lua with scalar arguments"
require_grep 'function host_scalar_call' "tests/embedding_smoke.c" "smoke host defines the scalar call fixture before invoking it"
require_grep 'function host_no_result' "tests/embedding_smoke.c" "smoke host defines the no-result call fixture"
require_grep 'function host_structured_result' "tests/embedding_smoke.c" "smoke host defines the structured-result call fixture"
require_grep 'function host_call_error' "tests/embedding_smoke.c" "smoke host defines the Lua-error call fixture"
require_grep 'call_arguments\[0\]\.type = BABET_VALUE_NIL' "tests/embedding_smoke.c" "smoke host includes nil in direct call arguments"
require_grep 'get borrowed call string' "tests/embedding_smoke.c" "smoke host copies borrowed call string inputs safely"
require_grep 'X\\0Y\\0R' "tests/embedding_smoke.c" "smoke host checks binary-safe scalar call results"
require_grep 'call Lua no-result function' "tests/embedding_smoke.c" "smoke host maps no-result calls to nil"
require_grep 'reject structured call result' "tests/embedding_smoke.c" "smoke host rejects structured call results"
require_grep 'call missing function' "tests/embedding_smoke.c" "smoke host covers missing call targets"
require_grep 'embedding call sentinel' "tests/embedding_smoke.c" "smoke host covers Lua call errors"
require_grep 'call recovery after Lua error' "tests/embedding_smoke.c" "smoke host proves call recovery after Lua error"
require_grep 'wrong-thread call global' "tests/embedding_smoke.c" "smoke host rejects direct calls from wrong thread"
require_grep 'search root after call' "tests/embedding_smoke.c" "smoke host proves direct calls freeze search-root configuration"

require_grep 'babet-sdk\.XXXXXX' "tools/create_sdk.sh" "SDK builder uses a space-free temporary merge workspace"
require_grep 'ADDLIB %04d\.a' "tools/create_sdk.sh" "SDK builder flattens staged static archives through ar MRI"
require_grep 'include/babet/babet\.h' "tools/create_sdk.sh" "SDK builder publishes the public header layout"
require_grep 'lib/libbabet\.a' "tools/create_sdk.sh" "SDK builder publishes one flattened libbabet archive"
require_grep 'EMBEDDING\.fr\.md' "tools/create_sdk.sh" "SDK builder publishes bilingual developer documentation"
require_grep 'EMBEDDING_DESIGN\.md' "tools/create_sdk.sh" "SDK builder publishes the embedding design contract"
require_grep 'examples/embedding' "tools/create_sdk.sh" "SDK builder publishes embedding examples"
require_grep 'project_build_sanitizers' "tools/test_embedding_runtime.sh" "runtime regression targets the ASan/UBSan libbabet build when requested"
require_grep 'project_build_ubsan' "tools/test_embedding_runtime.sh" "runtime regression targets the UBSan libbabet build when requested"
require_grep 'sdk moved with spaces' "tools/test_embedding_runtime.sh" "runtime regression relocates the SDK before external linking"
require_grep 'embedding_external_smoke\.c' "tools/test_embedding_runtime.sh" "runtime regression compiles a source-tree-independent external host"
require_grep 'external C host compiles and links using only the moved standalone SDK' "tools/test_embedding_runtime.sh" "runtime regression checks out-of-tree standalone linking"
require_grep 'external SDK host also links with --gc-sections' "tools/test_embedding_runtime.sh" "runtime regression separately checks SDK linkage with linker GC"
require_grep 'external SDK host runs correctly with --gc-sections' "tools/test_embedding_runtime.sh" "runtime regression executes the linker-GC SDK host"
require_grep 'documentation examples configure and build out of tree' "tools/test_embedding_runtime.sh" "runtime regression builds SDK documentation examples"
require_grep 'documentation examples execute successfully' "tools/test_embedding_runtime.sh" "runtime regression executes SDK documentation examples"
require_grep 'max_glibc_requirement' "tools/test_embedding_runtime.sh" "runtime regression measures GLIBC symbol requirements"
require_grep 'babet_context_call_global' "tests/embedding_external_smoke.c" "external SDK smoke exercises the public scalar call API"
require_grep 'babet\.base64\.encode' "tests/embedding_external_smoke.c" "external SDK smoke exercises a real Babet binding"


require_grep 'babet_host_call' "include/babet/babet.h" "public header exposes opaque host-call handle"
require_grep 'babet_context_register_host_function' "include/babet/babet.h" "public header exposes host-function registration"
require_grep 'BABET_STATUS_REENTRANT_CALL' "include/babet/babet.h" "public status surface represents callback reentrancy rejection"
require_grep 'babet\.host\.<name>' "HOST_FUNCTIONS_DESIGN.md" "host-function design fixes the Lua namespace"
require_grep 'no unregister operation in Lot 10' "HOST_FUNCTIONS_DESIGN.md" "host-function design fixes callback lifetime"
require_grep 'do not inherit them' "HOST_FUNCTIONS_DESIGN.md" "host-function design preserves worker isolation"
require_grep 'BABET_STATUS_REENTRANT_CALL' "HOST_FUNCTIONS_DESIGN.md" "host-function design forbids nested context entry"
require_grep 'babet_context_register_host_function' "examples/embedding/07_host_functions.c" "host-function example registers a C callback"
require_grep 'babet\.host\.greet' "examples/embedding/07_host_functions.c" "host-function example is called from Lua"
require_grep 'HOST_FUNCTIONS_DESIGN\.md' "tools/create_sdk.sh" "SDK builder publishes host-function design contract"
require_grep 'babet_context_register_host_function' "tools/test_embedding_runtime.sh" "runtime regression checks host-function export"
require_grep 'babet_context_register_host_function' "tests/embedding_external_smoke.c" "external SDK smoke exercises host-function registration"
require_grep 'embedding_cpp_callback_smoke' "CMakeLists.txt" "CMake builds the C++ host callback exception smoke"
require_grep 'babet_enable_sanitizers\(babet_embedding_cpp_callback_smoke' "CMakeLists.txt" "sanitizers cover the C++ host callback exception smoke"
require_grep 'C\+\+ host callback exceptions are contained and the context recovers' "tools/test_embedding_runtime.sh" "runtime regression executes the C++ callback exception smoke"
require_grep 'uncaught host callback failure' "tests/embedding_smoke.c" "C smoke verifies uncaught host failure conversion"
require_grep 'invalid_status_host_function' "tests/embedding_smoke.c" "C smoke verifies unknown host status rejection without enum UB"
require_grep 'coroutine\.wrap' "tests/embedding_smoke.c" "C smoke verifies host callbacks from Lua coroutines"
require_grep 'host __newindex sentinel' "tests/embedding_smoke.c" "C smoke verifies raw host registration bypasses metamethods"
require_grep 'kEmbeddingContextRegistryKey' "src/embedding/babet_c_api.cpp" "embedding callback identity is registry-scoped across coroutines"
require_grep 'changing a babet_status value changes the public ABI v1' "src/embedding/babet_c_api.cpp" "public status ABI v1 numbering has a compile-time sentinel"
require_grep 'changing a babet_value_type value changes the public ABI v1' "src/embedding/babet_c_api.cpp" "public value-tag ABI v1 numbering has a compile-time sentinel"

while IFS='|' read -r result label; do
    if [ "${result}" = "PASS" ]; then
        pass "${label}"
    else
        fail "${label}"
    fi
done < <(python3 - "${SCRIPT_DIR}" <<'PY_ABI_TAG_COVERAGE'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
header = (root / "include/babet/babet.h").read_text()


def public_tag_map(type_name, prefix):
    match = re.search(
        rf"typedef\s+uint32_t\s+{re.escape(type_name)}\s*;\s*enum\s*\{{(?P<body>.*?)\}}\s*;",
        header,
        re.S,
    )
    if not match:
        raise RuntimeError(f"cannot locate public {type_name} constants")
    pairs = re.findall(
        rf"\b({re.escape(prefix)}[A-Z0-9_]+)\s*=\s*([0-9]+)",
        match.group("body"),
    )
    if not pairs:
        raise RuntimeError(f"no {prefix} constants found")
    return {name: int(value) for name, value in pairs}


def function_body(path, name):
    text = (root / path).read_text()
    match = re.search(
        rf"\b{re.escape(name)}\s*\([^;{{}}]*\)\s*(?:noexcept\s*)?\{{",
        text,
        re.S,
    )
    if not match:
        raise RuntimeError(f"cannot locate {path}:{name}")
    start = text.find("{", match.start())
    depth = 0
    for pos in range(start, len(text)):
        char = text[pos]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1 : pos]
    raise RuntimeError(f"unterminated body for {path}:{name}")


def case_set(path, name, prefix):
    body = function_body(path, name)
    return set(re.findall(rf"case\s+({re.escape(prefix)}[A-Z0-9_]+)\s*:", body))


def ref_set(path, name, prefix):
    body = function_body(path, name)
    return set(re.findall(rf"\b({re.escape(prefix)}[A-Z0-9_]+)\b", body))


def exact(label, expected, actual):
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        def render(items):
            return ",".join(
                f"{item[0]}={item[1]}" if isinstance(item, tuple) else str(item)
                for item in items
            )

        details = []
        if missing:
            details.append("missing=" + render(missing))
        if extra:
            details.append("extra=" + render(extra))
        print("FAIL|" + label + " (" + "; ".join(details) + ")")
        return False
    print("PASS|" + label)
    return True


try:
    statuses = public_tag_map("babet_status", "BABET_STATUS_")
    values = public_tag_map("babet_value_type", "BABET_VALUE_")

    expected_status_values = {
        "BABET_STATUS_OK": 0,
        "BABET_STATUS_INVALID_ARGUMENT": 1,
        "BABET_STATUS_BUSY": 2,
        "BABET_STATUS_WRONG_THREAD": 3,
        "BABET_STATUS_LUA_ERROR": 4,
        "BABET_STATUS_OUT_OF_MEMORY": 5,
        "BABET_STATUS_INTERNAL_ERROR": 6,
        "BABET_STATUS_UNSUPPORTED_VALUE": 7,
        "BABET_STATUS_REENTRANT_CALL": 8,
    }
    expected_value_values = {
        "BABET_VALUE_NIL": 0,
        "BABET_VALUE_BOOLEAN": 1,
        "BABET_VALUE_INTEGER": 2,
        "BABET_VALUE_NUMBER": 3,
        "BABET_VALUE_STRING": 4,
    }

    exact(
        "public status ABI v1 numbering/additions are explicit",
        set(expected_status_values.items()),
        set(statuses.items()),
    )
    exact(
        "public value-tag ABI v1 numbering/additions are explicit",
        set(expected_value_values.items()),
        set(values.items()),
    )

    status_names = set(statuses)
    status_sites = [
        ("src/embedding/babet_c_api.cpp", "valid_status"),
        ("src/embedding/babet_c_api.cpp", "babet_status_name"),
        ("src/lua_bindings/native_plugin.cpp", "valid_status"),
    ]
    status_ok = True
    status_details = []
    for path, name in status_sites:
        actual = case_set(path, name, "BABET_STATUS_")
        if actual != status_names:
            status_ok = False
            status_details.append(f"{path}:{name}")
    print(
        ("PASS|" if status_ok else "FAIL|")
        + "all public statuses are covered by validators and status-name mapping"
        + ("" if status_ok else " (mismatch: " + ", ".join(status_details) + ")")
    )

    value_names = set(values)
    exhaustive_value_switches = [
        ("src/project_core/host_call_api.cpp", "valid_value_type"),
        ("src/embedding/babet_c_api.cpp", "set_global_thunk"),
        ("src/embedding/babet_c_api.cpp", "valid_value_type"),
        ("src/embedding/babet_c_api.cpp", "embedding_host_call_copy_result"),
        ("src/embedding/babet_c_api.cpp", "push_host_result"),
        ("src/embedding/babet_c_api.cpp", "push_owned_scalar"),
        ("src/embedding/babet_c_api.cpp", "babet_context_set_global"),
        ("src/embedding/babet_c_api.cpp", "babet_context_call_global"),
        ("src/lua_bindings/native_plugin.cpp", "push_plugin_result"),
        ("src/lua_bindings/native_plugin.cpp", "native_plugin_copy_result"),
    ]
    value_switch_ok = True
    value_switch_details = []
    for path, name in exhaustive_value_switches:
        actual = case_set(path, name, "BABET_VALUE_")
        if actual != value_names:
            value_switch_ok = False
            value_switch_details.append(f"{path}:{name}")
    print(
        ("PASS|" if value_switch_ok else "FAIL|")
        + "all exhaustive scalar tag switches cover every public value type"
        + ("" if value_switch_ok else " (mismatch: " + ", ".join(value_switch_details) + ")")
    )

    lua_to_public_converters = [
        ("src/embedding/babet_c_api.cpp", "read_host_argument"),
        ("src/embedding/babet_c_api.cpp", "read_scalar_result"),
        ("src/lua_bindings/native_plugin.cpp", "read_plugin_argument"),
    ]
    converter_ok = True
    converter_details = []
    for path, name in lua_to_public_converters:
        actual = ref_set(path, name, "BABET_VALUE_")
        if actual != value_names:
            converter_ok = False
            converter_details.append(f"{path}:{name}")
    print(
        ("PASS|" if converter_ok else "FAIL|")
        + "Lua-to-public scalar converters cover every public value type"
        + ("" if converter_ok else " (mismatch: " + ", ".join(converter_details) + ")")
    )
except Exception as exc:
    print(f"FAIL|ABI tag coverage preflight could not run ({exc})")
PY_ABI_TAG_COVERAGE
)

echo "embedding structural contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
