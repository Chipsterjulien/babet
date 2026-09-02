#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${2:-${ROOT}/build/project_build}"
CACHE="${BUILD_DIR}/CMakeCache.txt"
LINK_TXT="${BUILD_DIR}/CMakeFiles/babet.dir/link.txt"
OPENSSL_DIR="${ROOT}/build/openssl/openssl-3.5.8"
STAMP="${OPENSSL_DIR}/.babet-build-contract"
CONFIGDATA="${OPENSSL_DIR}/configdata.pm"
BINARY="${1:-${ROOT}/test/babet}"

fail(){ echo "[FAIL] $1" >&2; exit 1; }
pass(){ echo "[PASS] $1"; }

[ -x "${BINARY}" ] || fail "production Babet binary is missing: ${BINARY}"
[ -f "${CACHE}" ] || fail "production CMake cache is missing"
[ -f "${LINK_TXT}" ] || fail "production link command is missing"
[ -f "${STAMP}" ] || fail "OpenSSL build-contract stamp is missing"
[ -f "${CONFIGDATA}" ] || fail "OpenSSL configdata.pm is missing"

if grep -Fq 'BABET_ENABLE_GC_SECTIONS:BOOL=ON' "${CACHE}"; then
    pass "production CMake cache has BABET_ENABLE_GC_SECTIONS=ON"
else
    fail "production CMake cache does not have linker GC enabled"
fi

if grep -Fq -- '-Wl,--gc-sections' "${LINK_TXT}"; then
    pass "production link command contains --gc-sections"
else
    fail "production link command does not contain --gc-sections"
fi

expected=$'version=3.5.8\nConfigure=no-shared --openssldir=/etc/ssl -ffunction-sections -fdata-sections'
actual="$(cat "${STAMP}")"
if [ "${actual}" = "${expected}" ]; then
    pass "OpenSSL cache stamp matches the adopted section contract"
else
    echo "expected OpenSSL contract:" >&2
    printf '%s\n' "${expected}" >&2
    echo "actual OpenSSL contract:" >&2
    printf '%s\n' "${actual}" >&2
    fail "OpenSSL cache stamp differs from the adopted section contract"
fi

if grep -Fq -- '-ffunction-sections' "${CONFIGDATA}" \
    && grep -Fq -- '-fdata-sections' "${CONFIGDATA}"; then
    pass "actual OpenSSL Configure state contains section-splitting flags"
else
    fail "actual OpenSSL Configure state lacks section-splitting flags"
fi

TMP="$(mktemp "${ROOT}/build/gc-runtime-size.XXXXXX")"
trap 'rm -f -- "${TMP}"' EXIT
cp -- "${BINARY}" "${TMP}"
strip "${TMP}"
size="$(stat -c '%s' "${TMP}")"
echo "production_stripped_size=${size}"
# Reference only: toolchain/architecture dependent, never a hard release gate.
if [ "$(uname -m)" = "x86_64" ]; then
    echo "candidate11_x86_64_reference=13842952"
fi
