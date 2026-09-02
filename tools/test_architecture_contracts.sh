#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

EN="${ROOT}/ARCHITECTURE.md"
FR="${ROOT}/ARCHITECTURE.fr.md"

if [[ -f "${EN}" && -f "${FR}" ]]; then
    pass "bilingual architecture overview exists"
else
    fail "bilingual architecture overview exists"
fi

if grep -Fq 'Lua project' "${EN}" && grep -Fq 'Babet --create-exe' "${EN}" \
    && grep -Fq 'projet Lua' "${FR}" && grep -Fq 'Babet --create-exe' "${FR}"; then
    pass "architecture keeps --create-exe as the core one-file model"
else
    fail "architecture keeps --create-exe as the core one-file model"
fi

if grep -Fq 'generated `--create-exe` applications' "${EN}" \
    && grep -Fq 'les refusent explicitement' "${FR}"; then
    pass "architecture keeps native plugins outside generated applications"
else
    fail "architecture keeps native plugins outside generated applications"
fi

if grep -Fq 'another native program embeds Babet' "${EN}" \
    && grep -Fq 'un autre programme natif embarque Babet' "${FR}" \
    && grep -Fq 'libbabet.a' "${EN}" && grep -Fq 'libbabet.a' "${FR}"; then
    pass "architecture distinguishes libbabet embedding direction"
else
    fail "architecture distinguishes libbabet embedding direction"
fi

if grep -Fq 'babet-X.Y.Z-linux-x86_64-sdk.tar.gz' "${EN}" \
    && grep -Fq 'babet-X.Y.Z-linux-aarch64-sdk.tar.gz' "${EN}" \
    && grep -Fq 'babet-X.Y.Z-linux-armhf-sdk.tar.gz' "${EN}"; then
    pass "architecture documents the three official SDK architecture names"
else
    fail "architecture documents the three official SDK architecture names"
fi

if grep -Fq 'GUI-only exception' "${EN}" \
    && grep -Fq 'exception volontaire, limitée à la GUI' "${FR}" \
    && grep -Fq 'is the only supported GUI backend today' "${EN}"; then
    pass "architecture scopes the system-GTK autonomy exception"
else
    fail "architecture scopes the system-GTK autonomy exception"
fi

if grep -Fq 'future study, not current behaviour' "${EN}" \
    && grep -Fq 'étude future, pas contrat actuel' "${FR}"; then
    pass "architecture keeps Gentoo-style profiles explicitly deferred"
else
    fail "architecture keeps Gentoo-style profiles explicitly deferred"
fi

echo "architecture overview contracts: ${PASS} PASS / ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
