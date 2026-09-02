#!/bin/bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${1:-${ROOT_DIR}/test/babet}"
CACHE_FILE="${ROOT_DIR}/build/project_build/CMakeCache.txt"
OUT_DIR="${ROOT_DIR}/build/openssl-study"
REPORT="${OUT_DIR}/tls-capabilities.txt"
TMPDIR="$(mktemp -d -t babet-c9-tls-XXXXXX)"
SERVER_PID=""
PASS=0
FAIL=0
SKIP=0

cleanup() {
    if [ -n "${SERVER_PID}" ] && kill -0 "${SERVER_PID}" 2>/dev/null; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMPDIR}"
}
trap cleanup EXIT

log() {
    printf '%s\n' "$*" | tee -a "${REPORT}"
}
pass() { PASS=$((PASS + 1)); log "[PASS] $*"; }
fail() { FAIL=$((FAIL + 1)); log "[FAIL] $*"; }
skip() { SKIP=$((SKIP + 1)); log "[SKIP] $*"; }

[ -x "${BIN}" ] || { echo "ERREUR: binaire Babet absent/non exécutable: ${BIN}" >&2; exit 1; }
[ -f "${CACHE_FILE}" ] || { echo "ERREUR: cache CMake absent: ${CACHE_FILE}" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERREUR: python3 est requis pour réserver les ports." >&2; exit 1; }

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

CRYPTO_LIB="$(cache_value CRYPTO_LIB)"
OPENSSL_ROOT="$(dirname "${CRYPTO_LIB}")"
OPENSSL="${OPENSSL_ROOT}/apps/openssl"
OPENSSL_PROVENANCE="vendored"

if [ ! -x "${OPENSSL}" ]; then
    if command -v openssl >/dev/null 2>&1; then
        OPENSSL="$(command -v openssl)"
        OPENSSL_PROVENANCE="system-fallback"
    else
        echo "ERREUR: aucun exécutable openssl disponible." >&2
        exit 1
    fi
fi

mkdir -p "${OUT_DIR}"
: > "${REPORT}"
log "Babet Candidate 9 — deterministic TLS capability matrix"
log "======================================================="
log ""
log "babet=${BIN}"
log "openssl=${OPENSSL}"
log "openssl_provenance=${OPENSSL_PROVENANCE}"
log "openssl_version=$("${OPENSSL}" version 2>/dev/null || true)"
log ""

ROOT_KEY="${TMPDIR}/root.key"
ROOT_CERT="${TMPDIR}/root.crt"
INT_KEY="${TMPDIR}/intermediate.key"
INT_CSR="${TMPDIR}/intermediate.csr"
INT_CERT="${TMPDIR}/intermediate.crt"
RSA_KEY="${TMPDIR}/server-rsa.key"
RSA_CSR="${TMPDIR}/server-rsa.csr"
RSA_CERT="${TMPDIR}/server-rsa.crt"
EC_KEY="${TMPDIR}/server-ec.key"
EC_CSR="${TMPDIR}/server-ec.csr"
EC_CERT="${TMPDIR}/server-ec.crt"

cat > "${TMPDIR}/intermediate.ext" <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

cat > "${TMPDIR}/server-rsa.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1,DNS:localhost
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

cat > "${TMPDIR}/server-ec.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1,DNS:localhost
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

cert_fail() {
    echo "ERREUR: génération des certificats Candidate 9: $1" >&2
    exit 1
}

"${OPENSSL}" req -x509 -newkey rsa:3072 -nodes -sha256 -days 2 \
    -subj "/CN=Babet Candidate 9 Root CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "${ROOT_KEY}" -out "${ROOT_CERT}" \
    >"${TMPDIR}/root.log" 2>&1 || cert_fail "root"

"${OPENSSL}" req -newkey rsa:3072 -nodes -sha256 \
    -subj "/CN=Babet Candidate 9 Intermediate CA" \
    -keyout "${INT_KEY}" -out "${INT_CSR}" \
    >"${TMPDIR}/intermediate-csr.log" 2>&1 || cert_fail "intermediate CSR"

"${OPENSSL}" x509 -req -sha256 -days 2 \
    -in "${INT_CSR}" -CA "${ROOT_CERT}" -CAkey "${ROOT_KEY}" -CAcreateserial \
    -extfile "${TMPDIR}/intermediate.ext" \
    -out "${INT_CERT}" >"${TMPDIR}/intermediate-sign.log" 2>&1 || cert_fail "intermediate sign"

"${OPENSSL}" req -newkey rsa:2048 -nodes -sha256 \
    -subj "/CN=localhost" -keyout "${RSA_KEY}" -out "${RSA_CSR}" \
    >"${TMPDIR}/rsa-csr.log" 2>&1 || cert_fail "RSA leaf CSR"

"${OPENSSL}" x509 -req -sha256 -days 2 \
    -in "${RSA_CSR}" -CA "${INT_CERT}" -CAkey "${INT_KEY}" -CAcreateserial \
    -extfile "${TMPDIR}/server-rsa.ext" \
    -out "${RSA_CERT}" >"${TMPDIR}/rsa-sign.log" 2>&1 || cert_fail "RSA leaf sign"

"${OPENSSL}" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 \
    -out "${EC_KEY}" >"${TMPDIR}/ec-key.log" 2>&1 || cert_fail "ECDSA leaf key"

"${OPENSSL}" req -new -sha256 -subj "/CN=localhost" \
    -key "${EC_KEY}" -out "${EC_CSR}" \
    >"${TMPDIR}/ec-csr.log" 2>&1 || cert_fail "ECDSA leaf CSR"

"${OPENSSL}" x509 -req -sha256 -days 2 \
    -in "${EC_CSR}" -CA "${INT_CERT}" -CAkey "${INT_KEY}" -CAcreateserial \
    -extfile "${TMPDIR}/server-ec.ext" \
    -out "${EC_CERT}" >"${TMPDIR}/ec-sign.log" 2>&1 || cert_fail "ECDSA leaf sign"

if "${OPENSSL}" verify -CAfile "${ROOT_CERT}" -untrusted "${INT_CERT}" "${RSA_CERT}" >/dev/null 2>&1 &&
   "${OPENSSL}" verify -CAfile "${ROOT_CERT}" -untrusted "${INT_CERT}" "${EC_CERT}" >/dev/null 2>&1; then
    pass "root -> intermediate -> leaf certificate chains validate"
else
    fail "generated certificate chains do not validate"
fi

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

wait_port() {
    local port="$1"
    python3 - "${port}" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(50):
    s = socket.socket()
    s.settimeout(0.1)
    try:
        s.connect(("127.0.0.1", port))
    except OSError:
        time.sleep(0.05)
    else:
        s.close()
        raise SystemExit(0)
    finally:
        try:
            s.close()
        except Exception:
            pass
raise SystemExit(1)
PY
}

run_case() {
    local name="$1"
    local cert="$2"
    local key="$3"
    shift 3
    local port
    port="$(free_port)"
    local server_log="${TMPDIR}/server-${PASS}-${FAIL}-${SKIP}.log"

    "${OPENSSL}" s_server -accept "127.0.0.1:${port}" \
        -cert "${cert}" -key "${key}" -cert_chain "${INT_CERT}" \
        -www "$@" >"${server_log}" 2>&1 &
    SERVER_PID="$!"

    if ! wait_port "${port}"; then
        fail "${name}: OpenSSL server did not start"
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
        SERVER_PID=""
        return
    fi

    cat > "${TMPDIR}/main.lua" <<EOF
local r, e = babet.http.get("https://127.0.0.1:${port}/", {
    ca_cert = "${ROOT_CERT}",
    timeout = 5,
    max_body_size = 1024 * 1024,
})
if not r then
    io.stderr:write(tostring(e), "\\n")
    os.exit(2)
end
print("TLS_OK " .. tostring(r.status))
EOF

    output="$("${BIN}" "${TMPDIR}/main.lua" 2>&1)"
    rc=$?

    kill "${SERVER_PID}" 2>/dev/null || true
    wait "${SERVER_PID}" 2>/dev/null || true
    SERVER_PID=""

    if [ "${rc}" -eq 0 ] && printf '%s\n' "${output}" | grep -q '^TLS_OK 200$'; then
        pass "${name}"
    else
        fail "${name}: rc=${rc}; ${output}"
        log "  server_log=${server_log}"
    fi
}

run_case "TLS 1.2 / RSA / PKCS#1 / X25519 / AES-GCM" \
    "${RSA_CERT}" "${RSA_KEY}" \
    -tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256 \
    -groups X25519 -sigalgs rsa_pkcs1_sha256

run_case "TLS 1.2 / ECDSA / P-256 / AES-GCM" \
    "${EC_CERT}" "${EC_KEY}" \
    -tls1_2 -cipher ECDHE-ECDSA-AES128-GCM-SHA256 \
    -groups secp256r1 -sigalgs ecdsa_secp256r1_sha256

run_case "TLS 1.3 / RSA-PSS / X25519 / AES-GCM" \
    "${RSA_CERT}" "${RSA_KEY}" \
    -tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256 \
    -groups X25519 -sigalgs rsa_pss_rsae_sha256

run_case "TLS 1.3 / RSA-PSS / P-384 / AES-GCM" \
    "${RSA_CERT}" "${RSA_KEY}" \
    -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384 \
    -groups secp384r1 -sigalgs rsa_pss_rsae_sha256

run_case "TLS 1.3 / ECDSA / P-256 / ChaCha20-Poly1305" \
    "${EC_CERT}" "${EC_KEY}" \
    -tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256 \
    -groups secp256r1 -sigalgs ecdsa_secp256r1_sha256

if "${OPENSSL}" list -tls-groups 2>/dev/null | grep -q 'X25519MLKEM768'; then
    run_case "TLS 1.3 / RSA-PSS / X25519MLKEM768 / AES-GCM" \
        "${RSA_CERT}" "${RSA_KEY}" \
        -tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256 \
        -groups X25519MLKEM768 -sigalgs rsa_pss_rsae_sha256
else
    skip "X25519MLKEM768 is unavailable in the OpenSSL CLI used by the fixture"
fi

log ""
log "Result: ${PASS} PASS / ${FAIL} FAIL / ${SKIP} SKIP"
log "Report: ${REPORT}"

[ "${FAIL}" -eq 0 ]
