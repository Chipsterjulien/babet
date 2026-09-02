#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

ARCH_HELPER="${ROOT}/tools/release_arch_tag.sh"
PACKAGER="${ROOT}/tools/package_sdk.sh"

check_arch() {
    local input="$1" expected="$2"
    local actual
    actual="$(bash "${ARCH_HELPER}" "${input}" 2>/dev/null || true)"
    if [[ "${actual}" == "${expected}" ]]; then
        pass "architecture ${input} maps to ${expected}"
    else
        fail "architecture ${input} maps to ${expected}"
    fi
}

check_arch x86_64 linux-x86_64
check_arch amd64 linux-x86_64
check_arch aarch64 linux-aarch64
check_arch arm64 linux-aarch64
check_arch armv6l linux-armhf
check_arch armv7l linux-armhf
check_arch armhf linux-armhf
check_arch riscv64 linux-riscv64

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/babet-release-sdk-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP_DIR}"' EXIT
SDK_DIR="${TMP_DIR}/sdk with spaces"
DIST_DIR="${TMP_DIR}/dist with spaces"
mkdir -p "${SDK_DIR}/include/babet" "${SDK_DIR}/lib" "${SDK_DIR}/examples/embedding"
printf 'header\n' > "${SDK_DIR}/include/babet/babet.h"
printf 'plugin\n' > "${SDK_DIR}/include/babet/plugin.h"
printf 'object\n' > "${TMP_DIR}/member.o"
ar rcs "${SDK_DIR}/lib/libbabet.a" "${TMP_DIR}/member.o"
printf 'sdk\n' > "${SDK_DIR}/README.txt"
printf 'license\n' > "${SDK_DIR}/LICENSE"
printf 'notices\n' > "${SDK_DIR}/THIRD_PARTY_NOTICES.md"
printf 'example\n' > "${SDK_DIR}/examples/embedding/example.c"

if bash "${PACKAGER}" "${SDK_DIR}" "${DIST_DIR}" babet 2.24.0 linux-armhf >/dev/null; then
    pass "developer SDK release packager accepts paths containing spaces"
else
    fail "developer SDK release packager accepts paths containing spaces"
fi

BASE="babet-2.24.0-linux-armhf-sdk"
TARBALL="${DIST_DIR}/${BASE}.tar.gz"
SHA="${TARBALL}.sha256"
if [[ -f "${TARBALL}" && -f "${SHA}" ]]; then
    pass "developer SDK release names tarball and checksum by version and architecture"
else
    fail "developer SDK release names tarball and checksum by version and architecture"
fi

CONTENTS="$(tar -tzf "${TARBALL}" 2>/dev/null || true)"
if grep -Fxq "${BASE}/include/babet/babet.h" <<<"${CONTENTS}" \
    && grep -Fxq "${BASE}/include/babet/plugin.h" <<<"${CONTENTS}" \
    && grep -Fxq "${BASE}/lib/libbabet.a" <<<"${CONTENTS}" \
    && grep -Fxq "${BASE}/LICENSE" <<<"${CONTENTS}" \
    && grep -Fxq "${BASE}/THIRD_PARTY_NOTICES.md" <<<"${CONTENTS}"; then
    pass "developer SDK release tarball preserves public SDK and licence payload"
else
    fail "developer SDK release tarball preserves public SDK and licence payload"
fi

if (cd "${DIST_DIR}" && sha256sum -c "${BASE}.tar.gz.sha256" >/dev/null 2>&1); then
    pass "developer SDK release checksum verifies"
else
    fail "developer SDK release checksum verifies"
fi

if rm -f "${SDK_DIR}/THIRD_PARTY_NOTICES.md" \
    && ! bash "${PACKAGER}" "${SDK_DIR}" "${DIST_DIR}" babet 2.24.0 linux-armhf >/dev/null 2>&1; then
    pass "developer SDK release fails closed when redistribution notices are missing"
else
    fail "developer SDK release fails closed when redistribution notices are missing"
fi

echo "release developer SDK regression: ${PASS} PASS / ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
