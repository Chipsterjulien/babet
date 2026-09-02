#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/gc-sections-study/candidate11"
mkdir -p "${OUT}"

RESUME=0
if [ "${1:-}" = "--resume" ]; then
    RESUME=1
elif [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--resume]" >&2
    exit 2
fi

require_resume_artifacts() {
    local f
    for f in \
        "${OUT}/report.txt" \
        "${OUT}/variant-a-print-gc-sections.txt" \
        "${OUT}/babet-a" \
        "${OUT}/babet-d" \
        "${OUT}/babet-a-san" \
        "${OUT}/babet-d-san"; do
        [ -e "${f}" ] || { echo "ERREUR: artefact Candidate 11 absent pour --resume: ${f}" >&2; exit 1; }
    done
    for f in "${OUT}/a-build" "${OUT}/d-build" "${OUT}/a-san-build" "${OUT}/d-san-build"; do
        [ -d "${f}" ] || { echo "ERREUR: build Candidate 11 absent pour --resume: ${f}" >&2; exit 1; }
    done
    grep -q '^  matches_A_size=yes$' "${OUT}/report.txt" || {
        echo "ERREUR: le témoin OpenSSL existant n'est pas validé; --resume refusé." >&2
        exit 1
    }
    [ -x "${ROOT}/build/size-audit-babet" ] || {
        echo "ERREUR: baseline size-audit absente pour --resume." >&2
        exit 1
    }
}

echo "============================================================"
echo "Babet Candidate 11 — section-GC adoption review"
echo "============================================================"
echo

echo "==> Candidate 11 contracts"
bash "${ROOT}/tools/test_candidate11_contracts.sh"

if [ "${RESUME}" -eq 1 ]; then
    echo
    echo "==> Resume validated A/D measurement artifacts"
    require_resume_artifacts
    cat "${OUT}/report.txt"
else
    echo
    echo "==> Fresh OpenSSL 3.5.8 size-audit baseline"
    bash "${ROOT}/build_local.sh" --size-audit

    echo
    echo "==> A / production-control / D measurement"
    bash "${ROOT}/tools/measure_candidate11_gc_adoption.sh"
fi

echo
echo "==> Variant A discarded-section audit"
bash "${ROOT}/tools/audit_candidate11_gc_log.sh"

echo
echo "==> Deterministic TLS capabilities on A"
bash "${ROOT}/tools/test_tls_capabilities.sh" "${OUT}/babet-a"
cp -- "${ROOT}/build/openssl-study/tls-capabilities.txt" "${OUT}/tls-capabilities-a.txt"

echo
echo "==> Deterministic TLS capabilities on D"
bash "${ROOT}/tools/test_tls_capabilities.sh" "${OUT}/babet-d"
cp -- "${ROOT}/build/openssl-study/tls-capabilities.txt" "${OUT}/tls-capabilities-d.txt"

echo
echo "==> Local TLS performance baseline / A / D"
bash "${ROOT}/tools/benchmark_candidate11_tls.sh"

echo
echo "==> Full real-locale / sanitizers / release validation"
bash "${ROOT}/tools/test_candidate11_full_variants.sh"

echo
echo "============================================================"
echo "Candidate 11 completed"
echo "============================================================"
echo "Send back the output of this command. Reports are in:"
echo "  build/gc-sections-study/candidate11/report.txt"
echo "  build/gc-sections-study/candidate11/gc-audit.txt"
echo "  build/gc-sections-study/candidate11/tls-benchmark.txt"
echo "  build/gc-sections-study/candidate11/full-validation-summary.txt"
