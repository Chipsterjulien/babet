#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$1"; then pass "$2"; else fail "$2"; fi; }

for file in CMakeLists.txt build_local.sh run_tests.sh validate_release.sh \
    tools/test_embedding_runtime.sh tools/test_lua_longjmp_oom.sh; do
    check "[ -f '${ROOT}/${file}' ]" "sanitizer contract source exists: ${file}"
done

check "bash -n '${ROOT}/build_local.sh' && bash -n '${ROOT}/run_tests.sh' && bash -n '${ROOT}/validate_release.sh'" \
    "sanitizer orchestration shell syntax"
check "grep -Fq 'BABET_SANITIZER_MODE' '${ROOT}/CMakeLists.txt' && grep -Fq 'OFF ASAN_UBSAN UBSAN' '${ROOT}/CMakeLists.txt'" \
    "CMake exposes OFF / ASAN_UBSAN / UBSAN modes"
check "grep -Fq -- '-fsanitize=address,undefined' '${ROOT}/CMakeLists.txt' && grep -Fq -- '-fsanitize=undefined' '${ROOT}/CMakeLists.txt'" \
    "CMake keeps distinct ASan+UBSan and UBSan flags"
check "grep -Fq 'Legacy alias for BABET_SANITIZER_MODE=ASAN_UBSAN' '${ROOT}/CMakeLists.txt'" \
    "legacy BABET_ENABLE_SANITIZERS keeps its historical ASan+UBSan meaning"
check "grep -Fq -- '--ubsan)' '${ROOT}/build_local.sh' && grep -Fq 'project_build_ubsan' '${ROOT}/build_local.sh'" \
    "build_local exposes UBSan with a separate build tree"
check "grep -Fq -- '--ubsan)' '${ROOT}/run_tests.sh' && grep -Fq 'BABET_TEST_PREBUILT_BINARY_UBSAN' '${ROOT}/run_tests.sh'" \
    "run_tests exposes UBSan and a separate prebuilt hook"
if grep -Fq 'ASAN_ENABLED=0' "${ROOT}/run_tests.sh" \
    && [ "$(grep -Fc 'if [ "${ASAN_ENABLED}" -eq 1 ]; then' "${ROOT}/run_tests.sh")" -ge 3 ]; then
    pass "ASan-specific loader/LD_PRELOAD exceptions are gated by ASAN_ENABLED"
else
    fail "ASan-specific loader/LD_PRELOAD exceptions are gated by ASAN_ENABLED"
fi
check "grep -Fq 'UBSAN) EMBEDDING_ARGS+=(--ubsan)' '${ROOT}/run_tests.sh' && grep -Fq 'UBSAN) OOM_ARGS+=(--ubsan)' '${ROOT}/run_tests.sh'" \
    "UBSan propagates to embedding and OOM regressions"
check "grep -Fq 'project_build_ubsan' '${ROOT}/tools/test_embedding_runtime.sh' && grep -Fq -- '--ubsan) FLAGS+=(-fsanitize=undefined' '${ROOT}/tools/test_lua_longjmp_oom.sh'" \
    "focused runtime helpers understand UBSan-only builds"
check "grep -Fq 'SYSTEM_LIBS+=(-latomic)' '${ROOT}/tools/test_lua_longjmp_oom.sh'" \
    "standalone OOM sanitizer harness keeps the 32-bit libatomic link contract"
check "grep -Fq 'armv6l|armv7l|armhf' '${ROOT}/validate_release.sh' && grep -Fq 'SANITIZER_ARG=\"--ubsan\"' '${ROOT}/validate_release.sh'" \
    "release validation selects UBSan-only for linux-armhf"
check "grep -Fq 'pre_release_sanitizers=\${PRE_RELEASE_SANITIZERS}' '${ROOT}/tools/run_native_arch_release_validation.sh'" \
    "native compact report records sanitizer coverage"
check "bash '${ROOT}/build_local.sh' --help | grep -Fq -- '--ubsan'" \
    "build_local help documents UBSan"
check "bash '${ROOT}/run_tests.sh' --help | grep -Fq -- '--ubsan'" \
    "run_tests help documents UBSan"

printf 'sanitizer mode contracts: %d PASS / %d FAIL\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
