#!/bin/bash

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass_count=0
fail_count=0

pass() {
    echo "[PASS] $1"
    pass_count=$((pass_count + 1))
}

fail() {
    echo "[FAIL] $1"
    fail_count=$((fail_count + 1))
}

RELEASE="${ROOT}/release.sh"
CMAKE="${ROOT}/CMakeLists.txt"
IGNORE="${ROOT}/.gitignore"
RELEASING="${ROOT}/RELEASING.md"

mapfile -t versions < <(
    sed -nE \
        's/^[[:space:]]*project\([[:space:]]*babet[[:space:]]+VERSION[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' \
        "${CMAKE}"
)

if [ "${#versions[@]}" -eq 1 ]; then
    pass "CMakeLists exposes exactly one semantic project version"
else
    fail "CMakeLists exposes exactly one semantic project version"
fi

if grep -Fq 'CMAKE_VERSION="${CMAKE_VERSIONS[0]}"' "${RELEASE}" \
    && grep -Fq 'VERSION="${CMAKE_VERSION}"' "${RELEASE}"; then
    pass "release builder uses the CMake project version"
else
    fail "release builder uses the CMake project version"
fi

if ! grep -Fq 'git describe --tags' "${RELEASE}"; then
    pass "release builder no longer derives version from Git tags"
else
    fail "release builder no longer derives version from Git tags"
fi

if grep -Fq 'REQUESTED_VERSION="${VERSION}"' "${RELEASE}" \
    && grep -Fq '"${REQUESTED_VERSION}" != "${CMAKE_VERSION}"' "${RELEASE}"; then
    pass "--version is an assertion against the CMake version"
else
    fail "--version is an assertion against the CMake version"
fi

if ! grep -Fq \
    'Recompile avec ./release.sh --build --version' \
    "${RELEASE}"; then
    pass "release mismatch diagnostic no longer suggests a fake override"
else
    fail "release mismatch diagnostic no longer suggests a fake override"
fi

if ! compgen -G "${ROOT}/GITHUB_RELEASE_*.md" >/dev/null; then
    pass "versioned GitHub release scratch files are absent"
else
    fail "versioned GitHub release scratch files are absent"
fi

if [ ! -e "${ROOT}/MODIFIED_FILES.txt" ]; then
    pass "packaging inventory is absent from the source tree"
else
    fail "packaging inventory is absent from the source tree"
fi

if grep -qxF 'GITHUB_RELEASE_*.md' "${IGNORE}" \
    && grep -qxF 'MODIFIED_FILES.txt' "${IGNORE}"; then
    pass "release scratch files are ignored"
else
    fail "release scratch files are ignored"
fi

if [ -f "${ROOT}/THIRD_PARTY_NOTICES.md" ]; then
    pass "third-party notices remain available for binary releases"
else
    fail "third-party notices remain available for binary releases"
fi

if grep -Fq 'dist/release-notes.md' "${RELEASING}"; then
    pass "GitHub release notes stay outside tracked source"
else
    fail "GitHub release notes stay outside tracked source"
fi

if grep -Fq 'tools/release_arch_tag.sh' "${RELEASE}" \
    && grep -Fq 'tools/package_sdk.sh' "${RELEASE}"; then
    pass "release builder delegates architecture naming and developer SDK packaging"
else
    fail "release builder delegates architecture naming and developer SDK packaging"
fi

if grep -Fq 'SDK_DIR=' "${RELEASE}" \
    && grep -Fq 'SDK développeur incomplet' "${RELEASE}"; then
    pass "release builder fails closed on a missing or incomplete developer SDK"
else
    fail "release builder fails closed on a missing or incomplete developer SDK"
fi

echo "release builder structural contracts: ${pass_count} PASS / ${fail_count} FAIL"

[ "${fail_count}" -eq 0 ]
