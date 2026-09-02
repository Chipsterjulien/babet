#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/gc-sections-integration"
mkdir -p "${OUT}"

stage(){
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

stage "Babet 2.23.0 — final section-GC production integration"

stage "1/7 — permanent structural contracts"
bash "${ROOT}/tools/test_gc_sections_contracts.sh"

stage "2/7 — interleaved Candidate 11 TLS cross-check"
C11="${ROOT}/build/gc-sections-study/candidate11"
# Preserve the pre-adoption 15,563,592-byte baseline before the production
# size-audit below overwrites build/size-audit-babet. This also makes retries of
# this integration runner stable.
if [ ! -x "${C11}/babet-baseline" ] \
    && [ -x "${ROOT}/build/size-audit-babet" ] \
    && [ "$(stat -c '%s' "${ROOT}/build/size-audit-babet")" = "15563592" ]; then
    cp -- "${ROOT}/build/size-audit-babet" "${C11}/babet-baseline"
fi
if [ -x "${C11}/babet-baseline" ] \
    && [ -x "${C11}/babet-a" ] \
    && [ -x "${C11}/babet-d" ]; then
    bash "${ROOT}/tools/benchmark_candidate11_tls.sh"
    cp -- "${C11}/tls-benchmark.txt" "${OUT}/candidate11-tls-benchmark-interleaved.txt"
else
    echo "[INFO] Candidate 11 A/D binaries are absent; historical performance"
    echo "       cross-check is skipped. This does not change production validation."
fi

stage "3/7 — real production size-audit build"
bash "${ROOT}/build_local.sh" --size-audit
bash "${ROOT}/tools/test_gc_sections_runtime.sh" "${ROOT}/test/babet" \
    | tee "${OUT}/runtime-contract.txt"
cp -- "${ROOT}/build/size-audit.txt" "${OUT}/size-audit.txt"

stage "4/7 — deterministic TLS capabilities on production"
bash "${ROOT}/tools/test_tls_capabilities.sh" "${ROOT}/test/babet"
cp -- "${ROOT}/build/openssl-study/tls-capabilities.txt" "${OUT}/tls-capabilities-production.txt"

stage "5/7 — complete production suite under a real UTF-8 locale"
REAL_LOCALE=""
for candidate in fr_FR.UTF-8 fr_FR.utf8 en_US.UTF-8 en_US.utf8; do
    if locale -a 2>/dev/null | grep -Fxiq "${candidate}"; then
        REAL_LOCALE="${candidate}"
        break
    fi
done
if [ -z "${REAL_LOCALE}" ]; then
    echo "ERREUR: aucune vraie locale UTF-8 (fr_FR/en_US) n'est installée." >&2
    exit 1
fi
echo "real_locale=${REAL_LOCALE}"
LC_ALL="${REAL_LOCALE}" \
BABET_TEST_PREBUILT_BINARY_NORMAL="${ROOT}/test/babet" \
BABET_TEST_PREBUILT_BUILD_DIR_NORMAL="${ROOT}/build/project_build" \
bash "${ROOT}/run_tests.sh"

stage "6/7 — full production pre-release validation"
bash "${ROOT}/run_tests.sh" --release

stage "7/7 — final restored production contract"
bash "${ROOT}/tools/test_gc_sections_runtime.sh" "${ROOT}/test/babet" \
    | tee "${OUT}/runtime-contract-final.txt"

FINAL="${ROOT}/build/gc-sections-integration/final-babet-stripped"
cp -- "${ROOT}/test/babet" "${FINAL}"
strip "${FINAL}"
FINAL_SIZE="$(stat -c '%s' "${FINAL}")"
PUBLISHED_222=14997128
DELTA=$((PUBLISHED_222 - FINAL_SIZE))
python3 - "${FINAL_SIZE}" "${PUBLISHED_222}" > "${OUT}/summary.txt" <<'PY'
import sys
final=int(sys.argv[1]); old=int(sys.argv[2])
delta=old-final
pct=delta/old*100.0
print("Babet production section-GC integration")
print("========================================")
print(f"final_stripped_size={final}")
print(f"v2.22.2_published_size={old}")
print(f"smaller_than_v2.22.2_bytes={delta}")
print(f"smaller_than_v2.22.2_pct={pct:.2f}")
print("decision=ADOPT linker --gc-sections + OpenSSL function/data sections")
print("babet_owned_function_data_sections=NOT_ADOPTED")
PY
cat "${OUT}/summary.txt"

echo
echo "============================================================"
echo "Production GC integration validation completed"
echo "============================================================"
echo "Send back this complete output. Reports are in build/gc-sections-integration/."
