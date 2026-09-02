#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/babet-sdk-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP_DIR}"' EXIT
INPUT_DIR="${TMP_DIR}/input archives with spaces"
OUTPUT_DIR="${TMP_DIR}/moved sdk with spaces"
mkdir -p "${INPUT_DIR}"
printf '%s\n' '#ifndef BABET_FAKE_H' '#define BABET_FAKE_H' '#endif' > "${TMP_DIR}/babet.h"
printf '%s\n' '#ifndef BABET_PLUGIN_FAKE_H' '#define BABET_PLUGIN_FAKE_H' '#endif' > "${TMP_DIR}/plugin.h"
printf 'one\n' > "${INPUT_DIR}/member_one.o"
printf 'two\n' > "${INPUT_DIR}/member_two.o"
ar rcs "${INPUT_DIR}/lib one.a" "${INPUT_DIR}/member_one.o"
ar rcs "${INPUT_DIR}/lib two.a" "${INPUT_DIR}/member_two.o"

if bash "${ROOT}/tools/create_sdk.sh" \
    "${OUTPUT_DIR}" "${TMP_DIR}/babet.h" \
    "${INPUT_DIR}/lib one.a" "${INPUT_DIR}/lib two.a"; then
    pass "standalone SDK builder accepts archive paths containing spaces"
else
    fail "standalone SDK builder accepts archive paths containing spaces"
fi

if [ -f "${OUTPUT_DIR}/include/babet/babet.h" ] &&
   [ -f "${OUTPUT_DIR}/include/babet/plugin.h" ] &&
   cmp -s "${TMP_DIR}/babet.h" "${OUTPUT_DIR}/include/babet/babet.h" &&
   cmp -s "${TMP_DIR}/plugin.h" "${OUTPUT_DIR}/include/babet/plugin.h"; then
    pass "standalone SDK builder publishes embedding and plugin public headers"
else
    fail "standalone SDK builder publishes embedding and plugin public headers"
fi

SDK_LIB="${OUTPUT_DIR}/lib/libbabet.a"
if [ -f "${SDK_LIB}" ] && ar t "${SDK_LIB}" >/dev/null 2>&1; then
    pass "standalone SDK builder publishes a valid flattened archive"
else
    fail "standalone SDK builder publishes a valid flattened archive"
fi

MEMBERS="$(ar t "${SDK_LIB}" 2>/dev/null || true)"
if grep -Fxq 'member_one.o' <<<"${MEMBERS}" &&
   grep -Fxq 'member_two.o' <<<"${MEMBERS}"; then
    pass "flattened SDK archive contains members from every input archive"
else
    fail "flattened SDK archive contains members from every input archive"
fi

if grep -Fq 'c++ host.o' "${OUTPUT_DIR}/README.txt" 2>/dev/null &&
   grep -Fq -- '-ldl -pthread -lm' "${OUTPUT_DIR}/README.txt" 2>/dev/null; then
    pass "standalone SDK documents the required Linux host link boundary"
else
    fail "standalone SDK documents the required Linux host link boundary"
fi

if [ -f "${OUTPUT_DIR}/ARCHITECTURE.md" ] &&
   [ -f "${OUTPUT_DIR}/ARCHITECTURE.fr.md" ] &&
   [ -f "${OUTPUT_DIR}/EMBEDDING.md" ] &&
   [ -f "${OUTPUT_DIR}/EMBEDDING.fr.md" ] &&
   [ -f "${OUTPUT_DIR}/EMBEDDING_DESIGN.md" ] &&
   [ -f "${OUTPUT_DIR}/HOST_FUNCTIONS_DESIGN.md" ] &&
   [ -f "${OUTPUT_DIR}/NATIVE_PLUGINS.md" ] &&
   [ -f "${OUTPUT_DIR}/NATIVE_PLUGINS.fr.md" ] &&
   [ -f "${OUTPUT_DIR}/NATIVE_PLUGIN_DESIGN.md" ] &&
   grep -Fq 'Linux/glibc compatibility' "${OUTPUT_DIR}/EMBEDDING.md" &&
   grep -Fq 'Compatibilité Linux/glibc' "${OUTPUT_DIR}/EMBEDDING.fr.md"; then
    pass "standalone SDK publishes architecture, embedding, host-function and native-plugin guides"
else
    fail "standalone SDK publishes architecture, embedding, host-function and native-plugin guides"
fi

if [ -f "${OUTPUT_DIR}/LICENSE" ] &&
   [ -f "${OUTPUT_DIR}/THIRD_PARTY_NOTICES.md" ]; then
    pass "standalone SDK carries Babet licence and third-party redistribution notices"
else
    fail "standalone SDK carries Babet licence and third-party redistribution notices"
fi

if [ -f "${OUTPUT_DIR}/examples/embedding/CMakeLists.txt" ] &&
   [ -f "${OUTPUT_DIR}/examples/embedding/01_hello.c" ] &&
   [ -f "${OUTPUT_DIR}/examples/embedding/06_lifecycle_threads.c" ] &&
   [ -f "${OUTPUT_DIR}/examples/embedding/07_host_functions.c" ] &&
   [ -f "${OUTPUT_DIR}/examples/embedding/modules/greeting.lua" ] &&
   [ -f "${OUTPUT_DIR}/examples/native_plugin/CMakeLists.txt" ] &&
   [ -f "${OUTPUT_DIR}/examples/native_plugin/echo_plugin.c" ] &&
   [ -f "${OUTPUT_DIR}/examples/native_plugin/decorate_plugin.cpp" ]; then
    pass "standalone SDK publishes embedding and native-plugin examples"
else
    fail "standalone SDK publishes embedding and native-plugin examples"
fi

echo "developer SDK builder regression: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
