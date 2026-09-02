#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
has(){ if grep -Fq -- "$2" "$1"; then pass "$3"; else fail "$3"; fi; }
not_has(){ if grep -Fq -- "$2" "$1"; then fail "$3"; else pass "$3"; fi; }

CMAKE="${ROOT}/CMakeLists.txt"
BUILD="${ROOT}/build_local.sh"
RUN="${ROOT}/run_tests.sh"
STUDY="${ROOT}/GC_SECTIONS_STUDY.md"
STUDY_FR="${ROOT}/GC_SECTIONS_STUDY.fr.md"

has "$CMAKE" 'option(BABET_ENABLE_GC_SECTIONS' \
    "production linker-GC option exists"
if grep -A2 -F 'option(BABET_ENABLE_GC_SECTIONS' "$CMAKE" | grep -Fq 'ON)'; then
    pass "production linker GC defaults ON"
else
    fail "production linker GC defaults ON"
fi
has "$CMAKE" 'check_linker_flag(CXX "-Wl,--gc-sections" BABET_HAS_GC_SECTIONS)' \
    "production linker capability is checked"
has "$CMAKE" 'target_link_options(${PROJECT_NAME} PRIVATE -Wl,--gc-sections)' \
    "production executable links with --gc-sections"
has "$BUILD" '-DBABET_ENABLE_GC_SECTIONS=ON' \
    "build_local pins production linker GC ON"

has "$BUILD" 'OPENSSL_CONFIGURE_FLAGS=(' \
    "OpenSSL production Configure contract is explicit"
has "$BUILD" '    -ffunction-sections' \
    "OpenSSL production build enables function sections"
has "$BUILD" '    -fdata-sections' \
    "OpenSSL production build enables data sections"
has "$BUILD" 'OPENSSL_BUILD_CONTRACT_FILE=' \
    "OpenSSL cache records its build contract"
has "$BUILD" 'OPENSSL_CLI_LOCAL=' \
    "OpenSSL cache also requires the exact vendored validation CLI"
has "$BUILD" 'OPENSSL_EXPECTED_CONTRACT=' \
    "OpenSSL cache computes the expected build contract"
has "$BUILD" 'cache absent ou configuration obsolète, reconstruction' \
    "OpenSSL cache mismatch forces reconstruction"
has "$BUILD" 'rm -rf -- "${OPENSSL_BUILD_DIR:?}/${OPENSSL_DIR}"' \
    "OpenSSL stale configured tree is discarded"
has "$BUILD" 'make -j"$(nproc)" build_libs apps/openssl' \
    "OpenSSL bootstrap builds static libraries plus the vendored TLS test CLI"

# Babet source-level section splitting stays a maintainer-only experiment and
# is never enabled by build_local.sh.
has "$CMAKE" 'option(BABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS' \
    "Babet source section splitting remains maintainer-only"
not_has "$BUILD" 'BABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS=ON' \
    "production build does not section-split Babet-owned sources"

has "$RUN" 'test_gc_sections_contracts.sh' \
    "permanent test suite runs GC production contracts"
has "$RUN" 'test_gc_sections_runtime.sh' \
    "ordinary production tests verify the actual built GC contract"
has "${ROOT}/tools/run_gc_sections_integration.sh" 'benchmark_candidate11_tls.sh' \
    "final integration runner replays the interleaved TLS benchmark"
has "${ROOT}/tools/benchmark_candidate11_tls.sh" '5) order=(d a baseline)' \
    "TLS benchmark covers all six baseline/A/D execution orders"
has "${ROOT}/tools/benchmark_candidate11_tls.sh" 'TARGET_SAMPLE_MS=1000' \
    "TLS benchmark calibrates each sample to a meaningful duration"
has "${ROOT}/tools/benchmark_candidate11_tls.sh" 'D_vs_baseline_global_median_pct' \
    "TLS benchmark reports production D global median against baseline"
has "${ROOT}/tools/benchmark_candidate11_tls.sh" 'D_vs_baseline_paired_median_pct' \
    "TLS benchmark reports production D paired median against baseline"
has "${ROOT}/tools/benchmark_candidate11_tls.sh" 'relative_mad_pct' \
    "TLS benchmark has an explicit timing-noise gate"
has "${ROOT}/tools/benchmark_candidate11_tls.sh" '_min_ms=' \
    "TLS benchmark reports minima alongside medians"
has "$STUDY" 'Production adoption' \
    "English study records production adoption"
has "$STUDY_FR" 'Adoption en production' \
    "French study records production adoption"

echo "GC production contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
