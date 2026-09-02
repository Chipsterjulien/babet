#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
contains(){
    local file="$1" needle="$2" label="$3"
    if grep -Fq -- "$needle" "$file"; then pass "$label"; else fail "$label"; fi
}
not_contains(){
    local file="$1" needle="$2" label="$3"
    if grep -Fq -- "$needle" "$file"; then fail "$label"; else pass "$label"; fi
}

contains "$ROOT/build_local.sh" 'OPENSSL_VERSION="3.5.8"' \
    "vendored OpenSSL is pinned to 3.5.8"
contains "$ROOT/build_local.sh" 'a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2' \
    "OpenSSL 3.5.8 source hash is pinned"
contains "$ROOT/build_local.sh" 'OPENSSL_PATH_LOCAL="${OPENSSL_BUILD_DIR}/${OPENSSL_DIR}/libssl.a"' \
    "OpenSSL cache check targets the exact pinned version"
contains "$ROOT/build_local.sh" 'CRYPTO_PATH_LOCAL="${OPENSSL_BUILD_DIR}/${OPENSSL_DIR}/libcrypto.a"' \
    "libcrypto cache check targets the exact pinned version"
not_contains "$ROOT/build_local.sh" 'find "${OPENSSL_BUILD_DIR}" -name "libssl.a"' \
    "stale OpenSSL versions cannot satisfy the cache probe"
contains "$ROOT/build_local.sh" 'OPENSSL_CONFIGURE_FLAGS=(' \
    "OpenSSL Configure contract is explicit after Candidate 11 adoption"
contains "$ROOT/build_local.sh" '    no-shared' \
    "OpenSSL remains a static no-shared build"
if awk '
    /OPENSSL_CONFIGURE_FLAGS=\(/ { inside=1; next }
    inside && /^\)/ { inside=0 }
    inside { print }
' "$ROOT/build_local.sh" | grep -E '^[[:space:]]+no-' | grep -Fv 'no-shared' >/dev/null; then
    fail "no OpenSSL capability-trimming no-* option is introduced"
else
    pass "no OpenSSL capability-trimming no-* option is introduced"
fi

contains "$ROOT/tools/run_candidate9_openssl_study.sh" 'build_local.sh" --size-audit' \
    "Candidate 9 runner creates its fresh baseline itself"
contains "$ROOT/tools/measure_openssl_map.sh" 'build/project_build/babet-link.map' \
    "Candidate 9 consumes the exact size-audit linker map"
contains "$ROOT/tools/measure_openssl_map.sh" 'cp -- "${SOURCE_MAP}" "${MAP_FILE}"' \
    "exact baseline map is copied without relinking"
not_contains "$ROOT/tools/measure_openssl_map.sh" 'CMAKE_EXE_LINKER_FLAGS' \
    "Candidate 9 no longer injects map flags into CMake"
contains "$ROOT/tools/measure_openssl_map.sh" 'cxx_compiler_version=' \
    "map provenance records compiler version"
contains "$ROOT/tools/measure_openssl_map.sh" 'ld_version_line=' \
    "map provenance records binutils linker version"
contains "$ROOT/tools/measure_openssl_map.sh" 'strip_version_line=' \
    "map provenance records strip version"

contains "$ROOT/tools/analyze_openssl_map.py" 'review_upper_bound' \
    "OpenSSL report exposes a review-only candidate upper bound"
contains "$ROOT/tools/analyze_openssl_map.py" '"PQC"' \
    "OpenSSL map classification identifies PQC members"
contains "$ROOT/tools/analyze_openssl_map.py" '"legacy provider"' \
    "OpenSSL map classification identifies legacy-provider members"
contains "$ROOT/tools/analyze_openssl_map.py" 'first_section' \
    "archive-reason parsing avoids localized GNU ld headings"

contains "$ROOT/tools/test_tls_capabilities.sh" 'root -> intermediate -> leaf' \
    "TLS fixture validates a real certificate chain"
contains "$ROOT/tools/test_tls_capabilities.sh" '-tls1_2' \
    "TLS fixture forces TLS 1.2 cases"
contains "$ROOT/tools/test_tls_capabilities.sh" '-tls1_3' \
    "TLS fixture forces TLS 1.3 cases"
contains "$ROOT/tools/test_tls_capabilities.sh" 'TLS_CHACHA20_POLY1305_SHA256' \
    "TLS fixture forces ChaCha20-Poly1305"
contains "$ROOT/tools/test_tls_capabilities.sh" 'secp384r1' \
    "TLS fixture forces P-384"
contains "$ROOT/tools/test_tls_capabilities.sh" 'rsa_pss_rsae_sha256' \
    "TLS fixture forces RSA-PSS"
contains "$ROOT/tools/test_tls_capabilities.sh" 'X25519MLKEM768' \
    "TLS fixture protects the OpenSSL 3.5 hybrid PQ group when available"

contains "$ROOT/src/lua_bindings/socket.cpp" 'SSL_CTX_set_default_verify_paths' \
    "runtime uses OpenSSL default trust paths"
contains "$ROOT/src/lua_bindings/socket.cpp" '/etc/pki/tls/certs/ca-bundle.crt' \
    "runtime probes Fedora/RHEL trust bundle"
contains "$ROOT/src/lua_bindings/socket.cpp" '/var/lib/ca-certificates/ca-bundle.pem' \
    "runtime probes openSUSE trust bundle"

contains "$ROOT/OPENSSL_STUDY.md" 'No OpenSSL `no-*` size option is introduced' \
    "English study keeps Candidate 9 observation-only"
contains "$ROOT/OPENSSL_STUDY.fr.md" 'Aucun `no-*` OpenSSL' \
    "French study keeps Candidate 9 observation-only"

# Syntax-only check without writing __pycache__ into the source tree.
if python3 - "$ROOT/tools/analyze_openssl_map.py" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
compile(src, sys.argv[1], "exec")
PY
then
    pass "OpenSSL map analyser Python syntax is valid"
else
    fail "OpenSSL map analyser Python syntax is valid"
fi

echo "Candidate 9 contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
