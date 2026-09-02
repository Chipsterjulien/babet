#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/gc-sections-study"
REPORT="${OUT}/runtime-validation.txt"
mkdir -p "${OUT}"
: > "${REPORT}"

for name in variant-a variant-b variant-c; do
    bin="${OUT}/babet-${name}"
    echo "==> ${name}" | tee -a "${REPORT}"
    [ -x "${bin}" ] || { echo "[FAIL] missing ${bin}" | tee -a "${REPORT}"; exit 1; }

    bash "${ROOT}/tools/test_runtime_surface.sh" "${bin}" 2>&1 | tee -a "${REPORT}"
    bash "${ROOT}/tools/test_native_plugin_runtime.sh" "${bin}" 2>&1 | tee -a "${REPORT}"
    bash "${ROOT}/tests/test_packaging.sh" "${bin}" 2>&1 | tee -a "${REPORT}"

    # Reuse Candidate 9's deterministic TLS matrix against the exact variant.
    bash "${ROOT}/tools/test_tls_capabilities.sh" "${bin}" 2>&1 | tee -a "${REPORT}"
    cp -- "${ROOT}/build/openssl-study/tls-capabilities.txt" \
        "${OUT}/tls-capabilities-${name}.txt"
    echo | tee -a "${REPORT}"
done

echo "Candidate 10 targeted runtime validation completed" | tee -a "${REPORT}"
echo "Report: ${REPORT}"
