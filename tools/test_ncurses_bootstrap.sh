#!/bin/bash
# Lightweight regression test for the ncurses source bootstrap and the
# space-safe out-of-tree configure path. No network access or compilation.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build_dependency_utils.sh
. "${SCRIPT_DIR}/build_dependency_utils.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

pass_count=0
fail() { echo "[FAIL] $1"; exit 1; }
pass() { echo "[PASS] $1"; pass_count=$((pass_count + 1)); }

make_complete_tree() {
    local root="$1"
    mkdir -p "${root}/misc"
    : > "${root}/configure"
    : > "${root}/install-sh"
    : > "${root}/config.guess"
    : > "${root}/config.sub"
    : > "${root}/misc/terminfo.src"
    : > "${root}/COPYING"
}

SOURCE="${TMP_ROOT}/source"
make_complete_tree "${SOURCE}"
if ! babet_ncurses_source_complete "${SOURCE}"; then
    fail "a complete ncurses source tree was rejected"
fi
pass "complete ncurses source tree is accepted"

rm -f "${SOURCE}/install-sh"
if babet_ncurses_source_complete "${SOURCE}"; then
    fail "a source tree missing install-sh was accepted"
fi
pass "source tree missing install-sh is rejected"

rm -rf "${SOURCE}"
make_complete_tree "${SOURCE}"
rm -f "${SOURCE}/config.guess"
if babet_ncurses_source_complete "${SOURCE}"; then
    fail "a source tree missing config.guess was accepted"
fi
pass "source tree missing configure auxiliaries is rejected"

ARCHIVE_PARENT="${TMP_ROOT}/archive"
ARCHIVE_TREE="${ARCHIVE_PARENT}/ncurses-6.6"
make_complete_tree "${ARCHIVE_TREE}"
printf '%s\n' 'fresh archive' > "${ARCHIVE_TREE}/MARKER"
tar -czf "${TMP_ROOT}/ncurses-6.6.tar.gz" -C "${ARCHIVE_PARENT}" ncurses-6.6

NCURSES_ROOT="${TMP_ROOT}/root with spaces/ncurses"
NCURSES_SOURCE="${NCURSES_ROOT}/ncurses-6.6"
mkdir -p "${NCURSES_SOURCE}"
printf '%s\n' stale > "${NCURSES_SOURCE}/STALE"
if ! babet_prepare_ncurses_source "${NCURSES_SOURCE}" "${NCURSES_ROOT}" \
        "${TMP_ROOT}/ncurses-6.6.tar.gz" "ncurses-6.6"; then
    fail "an incomplete ncurses source tree was not repaired"
fi
if [ ! -f "${NCURSES_SOURCE}/install-sh" ] || \
   [ ! -f "${NCURSES_SOURCE}/config.guess" ] || \
   [ ! -f "${NCURSES_SOURCE}/MARKER" ] || \
   [ -e "${NCURSES_SOURCE}/STALE" ]; then
    fail "ncurses source repair did not replace the stale tree cleanly"
fi
pass "incomplete ncurses tree is re-extracted under a path with spaces"

printf '%s\n' keep > "${NCURSES_SOURCE}/KEEP"
if ! babet_prepare_ncurses_source "${NCURSES_SOURCE}" "${NCURSES_ROOT}" \
        "${TMP_ROOT}/ncurses-6.6.tar.gz" "ncurses-6.6"; then
    fail "a complete ncurses source tree was rejected"
fi
if [ ! -f "${NCURSES_SOURCE}/KEEP" ]; then
    fail "a complete ncurses source tree was unnecessarily replaced"
fi
pass "complete ncurses source tree is reused"

BAD_PARENT="${TMP_ROOT}/bad-archive"
BAD_TREE="${BAD_PARENT}/ncurses-6.6"
make_complete_tree "${BAD_TREE}"
rm -f "${BAD_TREE}/install-sh"
tar -czf "${TMP_ROOT}/bad-ncurses.tar.gz" -C "${BAD_PARENT}" ncurses-6.6
rm -rf "${NCURSES_SOURCE}"
if babet_prepare_ncurses_source "${NCURSES_SOURCE}" "${NCURSES_ROOT}" \
        "${TMP_ROOT}/bad-ncurses.tar.gz" "ncurses-6.6"; then
    fail "a malformed ncurses archive was accepted"
fi
if [ -e "${NCURSES_SOURCE}" ]; then
    fail "a malformed ncurses archive left a partial final source tree"
fi
pass "malformed ncurses archive leaves no partial source tree"

# Reproduce the important path shape from the real failure. The parent path
# contains spaces, but configure is invoked from build/ through a relative path
# whose srcdir component itself contains no spaces.
SPACE_ROOT="${TMP_ROOT}/project with spaces/build/ncurses"
FAKE_SOURCE="${SPACE_ROOT}/ncurses-6.6"
FAKE_BUILD="${SPACE_ROOT}/build"
mkdir -p "${FAKE_SOURCE}" "${FAKE_BUILD}"
cat > "${FAKE_SOURCE}/configure" <<'SH'
#!/bin/sh
case "$0" in
    ../ncurses-6.6/configure) exit 0 ;;
    *) exit 23 ;;
esac
SH
chmod +x "${FAKE_SOURCE}/configure"
(
    cd "${FAKE_BUILD}"
    ../ncurses-6.6/configure
) || fail "relative configure invocation failed below a path containing spaces"
pass "relative configure path survives a project path containing spaces"

# The fallback build must never silently use the host's ncurses utilities.
BUILD_LOCAL="${SCRIPT_DIR}/../build_local.sh"
if ! grep -Fq -- '--with-tic-path="${NCURSES_FINAL_WORKSPACE}/tools/tic"' "${BUILD_LOCAL}" || \
   ! grep -Fq -- '--with-infocmp-path="${NCURSES_FINAL_WORKSPACE}/tools/infocmp"' "${BUILD_LOCAL}"; then
    fail "final fallback generation is not pinned to self-built tic/infocmp"
fi
pass "fallback generation is pinned to self-built ncurses tools"

if ! grep -Fq 'NCURSES_BOOTSTRAP_TIC="${NCURSES_BOOTSTRAP_DIR}/progs/tic"' "${BUILD_LOCAL}" || \
   ! grep -Fq 'NCURSES_BOOTSTRAP_INFOCMP="${NCURSES_BOOTSTRAP_DIR}/progs/infocmp"' "${BUILD_LOCAL}"; then
    fail "bootstrap tool paths are not tied to the pinned ncurses build"
fi
pass "bootstrap tic/infocmp come from pinned ncurses 6.6"

# MKfallback.sh derives an unquoted -o path from `pwd`. Reproduce the actual
# constraint: even if source and tools live under a project path containing
# spaces, the final fallback-generation cwd and exposed tool/source paths must
# all be space-free.
WORK_SOURCE="${TMP_ROOT}/project with spaces/ncurses-6.6"
WORK_TOOLS="${TMP_ROOT}/project with spaces/bootstrap tools"
mkdir -p "${WORK_SOURCE}" "${WORK_TOOLS}"
printf '#!/bin/sh\nexit 0\n' > "${WORK_TOOLS}/tic"
printf '#!/bin/sh\nexit 0\n' > "${WORK_TOOLS}/infocmp"
chmod +x "${WORK_TOOLS}/tic" "${WORK_TOOLS}/infocmp"
WORKSPACE="$(babet_prepare_ncurses_final_workspace \
    "${WORK_SOURCE}" "${WORK_TOOLS}/tic" "${WORK_TOOLS}/infocmp")" || \
    fail "space-free ncurses final workspace could not be created"
case "${WORKSPACE}" in
    *' '*) rm -rf "${WORKSPACE}"; fail "final ncurses workspace contains spaces" ;;
esac
for exposed in "${WORKSPACE}/source" "${WORKSPACE}/tools/tic" \
               "${WORKSPACE}/tools/infocmp" "${WORKSPACE}/build"; do
    case "${exposed}" in
        *' '*) rm -rf "${WORKSPACE}"; fail "final ncurses exposed path contains spaces" ;;
    esac
    [ -e "${exposed}" ] || {
        rm -rf "${WORKSPACE}"
        fail "final ncurses workspace is incomplete"
    }
done
(
    cd "${WORKSPACE}/build"
    tmp_info="$(pwd)/tmp_info"
    case "${tmp_info}" in *' '*) exit 1 ;; esac
) || {
    rm -rf "${WORKSPACE}"
    fail "MKfallback-style temporary path is not space-safe"
}
rm -rf "${WORKSPACE}"
pass "fallback generation cwd is space-free below a project path with spaces"

if ! grep -Fq 'babet_prepare_ncurses_final_workspace' "${BUILD_LOCAL}" || \
   ! grep -Fq '../source/configure' "${BUILD_LOCAL}"; then
    fail "final ncurses build is not routed through the space-free workspace"
fi
pass "final ncurses build uses the space-free workspace"

echo "ncurses bootstrap regression tests: ${pass_count} PASS / 0 FAIL"
