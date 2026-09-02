#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/build/openssl-study"
CACHE_FILE="${ROOT_DIR}/build/project_build/CMakeCache.txt"
BIN="${ROOT_DIR}/test/babet"

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

echo "============================================================"
echo "Babet Candidate 9 — OpenSSL observation/protection study"
echo "============================================================"
echo

echo "==> Contract checks"
bash "${ROOT_DIR}/tools/test_candidate9_contracts.sh"
echo

echo "==> Fresh OpenSSL 3.5.8 size-audit baseline"
"${ROOT_DIR}/build_local.sh" --size-audit
echo

if [ ! -f "${CACHE_FILE}" ]; then
    echo "ERREUR: cache CMake absent après --size-audit." >&2
    exit 1
fi
crypto_lib="$(awk '/^CRYPTO_LIB:/{sub(/^[^=]*=/, ""); print; exit}' "${CACHE_FILE}")"
case "${crypto_lib}" in
    *openssl-3.5.8*) ;;
    *)
        echo "ERREUR: la baseline n'utilise pas OpenSSL 3.5.8: ${crypto_lib:-<absent>}" >&2
        exit 1
        ;;
esac

echo "==> Exact size-audit map capture and provenance"
"${ROOT_DIR}/tools/measure_openssl_map.sh"
echo

echo "==> OpenSSL archive-member attribution"
python3 "${ROOT_DIR}/tools/analyze_openssl_map.py" \
    "${OUT_DIR}/babet.map" --out-dir "${OUT_DIR}"
cat "${OUT_DIR}/openssl-map-report.txt"
echo

echo "==> Deterministic TLS capability matrix"
"${ROOT_DIR}/tools/test_tls_capabilities.sh" "${BIN}"
echo

echo "==> Trust-store audit"
"${ROOT_DIR}/tools/audit_openssl_trust_store.sh" "${BIN}"
echo

echo "============================================================"
echo "Candidate 9 observation suite completed"
echo "============================================================"
echo "Reports:"
echo "  build/openssl-study/map-build-metadata.txt"
echo "  build/openssl-study/openssl-map-report.txt"
echo "  build/openssl-study/openssl-objects.tsv"
echo "  build/openssl-study/openssl-families.tsv"
echo "  build/openssl-study/tls-capabilities.txt"
echo "  build/openssl-study/trust-store-audit.txt"
