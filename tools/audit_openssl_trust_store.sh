#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_FILE="${ROOT_DIR}/build/project_build/CMakeCache.txt"
BIN="${1:-${ROOT_DIR}/test/babet}"
OUT_DIR="${ROOT_DIR}/build/openssl-study"
REPORT="${OUT_DIR}/trust-store-audit.txt"
mkdir -p "${OUT_DIR}"
: > "${REPORT}"

log() { printf '%s\n' "$*" | tee -a "${REPORT}"; }

cache_value() {
    local key="$1"
    awk -v key="${key}" '
        index($0, key ":") == 1 {
            line=$0
            sub(/^[^=]*=/, "", line)
            print line
            exit
        }
    ' "${CACHE_FILE}"
}

log "Babet Candidate 9 — trust-store audit"
log "====================================="
log ""

if grep -Fq -- './Configure no-shared --openssldir=/etc/ssl' "${ROOT_DIR}/build_local.sh"; then
    log "[PASS] build_local.sh pins OpenSSL OPENSSLDIR to /etc/ssl"
else
    log "[WARN] expected ./Configure no-shared --openssldir=/etc/ssl not found"
fi

if [ -f "${CACHE_FILE}" ]; then
    CRYPTO_LIB="$(cache_value CRYPTO_LIB)"
    OPENSSL_ROOT="$(dirname "${CRYPTO_LIB}")"
    OPENSSL="${OPENSSL_ROOT}/apps/openssl"
    if [ -x "${OPENSSL}" ]; then
        log "vendored_openssl=$("${OPENSSL}" version 2>/dev/null || true)"
        log "vendored_openssldir=$("${OPENSSL}" version -d 2>/dev/null || true)"
    else
        log "[WARN] vendored OpenSSL CLI not found at ${OPENSSL}"
    fi
else
    log "[WARN] CMake cache unavailable: ${CACHE_FILE}"
fi

DEFAULT_VERIFY_HITS="$(grep -R -n --include='*.cpp' --include='*.hpp' \
    'SSL_CTX_set_default_verify_paths' "${ROOT_DIR}/src" 2>/dev/null || true)"
CA_PATH_HITS="$(grep -R -n --include='*.cpp' --include='*.hpp' -E \
    '/etc/(ssl|pki)|ca-certificates\.crt|ca-bundle\.crt|cert\.pem|SSL_CERT_(FILE|DIR)' \
    "${ROOT_DIR}/src" 2>/dev/null || true)"

log ""
if [ -n "${DEFAULT_VERIFY_HITS}" ]; then
    log "[PASS] runtime source calls SSL_CTX_set_default_verify_paths:"
    log "${DEFAULT_VERIFY_HITS}"
else
    log "[WARN] no SSL_CTX_set_default_verify_paths call found under src/"
fi

log ""
if [ -n "${CA_PATH_HITS}" ]; then
    log "[INFO] runtime CA-path/env probing references:"
    log "${CA_PATH_HITS}"
else
    log "[INFO] no explicit CA-path/env probing strings found under src/"
fi

log ""
log "Environment escape hatches:"
log "SSL_CERT_FILE=${SSL_CERT_FILE-<unset>}"
log "SSL_CERT_DIR=${SSL_CERT_DIR-<unset>}"

if [ -x "${BIN}" ]; then
    TMP="$(mktemp -d -t babet-c9-trust-XXXXXX)"
    trap 'rm -rf "${TMP}"' EXIT
    cat > "${TMP}/main.lua" <<'EOF'
local r, e = babet.http.get("https://example.com/", {
    timeout = 10,
    max_body_size = 1024 * 1024,
})
if r then
    print("PUBLIC_TRUST_OK " .. tostring(r.status))
else
    io.stderr:write("PUBLIC_TRUST_ERR " .. tostring(e) .. "\n")
    os.exit(2)
end
EOF
    output="$("${BIN}" "${TMP}/main.lua" 2>&1)"
    rc=$?
    if [ "${rc}" -eq 0 ] && printf '%s\n' "${output}" | grep -q '^PUBLIC_TRUST_OK '; then
        log ""
        log "[PASS] public HTTPS verifies with no explicit ca_cert on this host: ${output}"
    else
        log ""
        log "[WARN] public HTTPS probe did not succeed (network/proxy/trust may be responsible): rc=${rc}; ${output}"
    fi
else
    log ""
    log "[WARN] Babet binary unavailable for advisory public trust probe: ${BIN}"
fi

log ""
log "Cross-distribution note:"
log "The public probe above proves only this host. Fedora/openSUSE container checks remain"
log "a separate portability observation and must not become blocking third-party/network tests."
log ""
log "Report: ${REPORT}"
