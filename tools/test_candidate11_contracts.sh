#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
check_file(){ [ -f "$1" ] && pass "$2" || fail "$2"; }
check_grep(){ local pat="$1" file="$2" msg="$3"; grep -Eq -- "$pat" "$file" && pass "$msg" || fail "$msg"; }
check_not_grep(){ local pat="$1" file="$2" msg="$3"; ! grep -Eq -- "$pat" "$file" && pass "$msg" || fail "$msg"; }

M="${ROOT}/tools/measure_candidate11_gc_adoption.sh"
A="${ROOT}/tools/audit_candidate11_gc_log.sh"
B="${ROOT}/tools/benchmark_candidate11_tls.sh"
F="${ROOT}/tools/test_candidate11_full_variants.sh"
R="${ROOT}/tools/run_candidate11_gc_adoption.sh"
for pair in \
    "$M|Candidate 11 measurement tool exists" \
    "$A|Candidate 11 GC audit exists" \
    "$B|Candidate 11 TLS benchmark exists" \
    "$F|Candidate 11 full validation exists" \
    "$R|Candidate 11 runner exists"; do
    IFS='|' read -r file msg <<<"$pair"; check_file "$file" "$msg"
done

for f in "$M" "$A" "$B" "$F" "$R" "${ROOT}/run_tests.sh" "${ROOT}/validate_release.sh" "${ROOT}/tools/test_embedding_runtime.sh"; do
    if bash -n "$f"; then pass "shell syntax: ${f#${ROOT}/}"; else fail "shell syntax: ${f#${ROOT}/}"; fi
done

check_grep 'build_variant a .* 0 1' "$M" "A is linker-GC-only with print-gc-sections"
check_not_grep 'build_variant d .*GC_BABET_SECTIONS|BABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS=ON' "$M" "D never enables Babet section splitting"
check_grep '\./Configure no-shared --openssldir=/etc/ssl "\$\{flags\[@\]\}"' "$M" "OpenSSL control and D share the production Configure contract"
check_grep 'make -j"\$\(nproc\)" build_libs' "$M" "OpenSSL witness builds libraries only"
check_grep 'mktemp -d "\$\{OUT\}/openssl-work-XXXXXX"' "$M" "OpenSSL witness work stays out of /tmp"
check_grep '"\$\{dest\}/configure\.log"; then' "$M" "OpenSSL warning guard scopes to Configure only"
check_not_grep '"\$\{dest\}/configure\.log" "\$\{dest\}/build\.log"' "$M" "build_libs install-variable noise is not treated as Configure drift"
check_grep 'flags\+=\( -ffunction-sections -fdata-sections \)' "$M" "only D OpenSSL adds function/data sections"
check_grep 'size_control.*-ne.*size_a' "$M" "fresh production-control must reproduce A size"
check_grep 'build_variant a-san' "$M" "A sanitizer binary is built"
check_grep 'build_variant d-san' "$M" "D sanitizer binary is built"
check_grep 'babet_version|babet_status_name|babet_host_call_argument_count|babet_host_call_arguments|babet_host_call_set_result|babet_host_call_set_error' "$A" "A audit watches exact exported C symbols"
check_grep '\\.init_array|\\.fini_array|\\.ctors|\\.dtors' "$A" "A audit watches init/fini/ctor/dtor sections"
check_not_grep 'removing unused section\.\*\(babet_' "$A" "A audit no longer treats arbitrary babet_ substrings as sensitive"
check_grep 'MAX_REGRESSION_PCT=10\.0' "$B" "TLS benchmark threshold is fixed before measurement"
check_grep 'SAMPLES=12' "$B" "TLS benchmark uses repeated balanced samples"
check_grep 'TARGET_SAMPLE_MS=1000' "$B" "TLS benchmark calibrates away sub-100ms samples"
check_grep 'RETRY_TARGET_SAMPLE_MS=2500' "$B" "TLS benchmark has an automatic long-sample retry"
check_grep 'statistics\.median' "$B" "TLS benchmark compares medians"
check_grep 'paired_median_pct' "$B" "TLS benchmark uses block-paired medians"
check_grep 'relative_mad_pct' "$B" "TLS benchmark quantifies timing noise"
check_grep 'mins=\{k:min\(v\)' "$B" "TLS benchmark also reports minima"
check_grep 'D_vs_baseline_global_median_pct' "$B" "TLS benchmark gates production D global median against baseline"
check_grep 'D_vs_baseline_paired_median_pct' "$B" "TLS benchmark gates production D paired median against baseline"
check_grep 'LC_ALL="\$\{REAL_LOCALE\}"' "$F" "A receives a full real-locale test run"
check_grep '--resume' "$R" "Candidate 11 runner supports validated resume"
check_grep 'matches_A_size=yes' "$R" "resume requires validated OpenSSL witness"
check_grep 'run_tests\.sh" --release' "$F" "A and D use full pre-release validation"
check_grep 'BABET_TEST_PREBUILT_BINARY_NORMAL' "${ROOT}/run_tests.sh" "run_tests supports internal prebuilt normal candidate"
check_grep 'BABET_TEST_PREBUILT_BINARY_SANITIZERS' "${ROOT}/run_tests.sh" "run_tests supports internal prebuilt sanitizer candidate"
check_grep 'BABET_TEST_PREBUILT_BINARY_UBSAN' "${ROOT}/run_tests.sh" "run_tests exposes a separate prebuilt UBSan hook"
check_grep 'BABET_EMBEDDING_BUILD_DIR' "${ROOT}/tools/test_embedding_runtime.sh" "embedding test follows the candidate build directory"
check_grep 'BABET_TEST_PREBUILT_BINARY_NORMAL' "${ROOT}/validate_release.sh" "release smoke test follows the candidate normal binary"
check_grep 'Candidate 11' "${ROOT}/GC_SECTIONS_STUDY.md" "GC study documents Candidate 11"
check_grep 'Candidate 11' "${ROOT}/todo" "todo tracks Candidate 11"

printf 'Candidate 11 contracts: %d PASS / %d FAIL\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
