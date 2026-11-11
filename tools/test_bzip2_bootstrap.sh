#!/bin/bash
# Offline cache-recovery tests. The tiny Makefile simulates archive production;
# no compiler, network access or changes to the project's build/ are needed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
. "${SCRIPT_DIR}/build_dependency_utils.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-bzip2-test.XXXXXX")"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
pass_count=0
pass() { echo "[PASS] $1"; pass_count=$((pass_count + 1)); }
fail() { echo "[FAIL] $1"; exit 1; }
clean_extraction() {
    if compgen -G "$1/.extract-*" >/dev/null; then
        fail "temporary extraction directory was not cleaned"
    fi
}

ARCHIVE_NAME=bzip2-1.0.8
TREE="${TMP_ROOT}/archive tree/${ARCHIVE_NAME}"
mkdir -p "${TREE}"
required=(Makefile bzlib.h bzlib_private.h words0 blocksort.c huffman.c
          crctable.c randtable.c compress.c decompress.c bzlib.c)
for file in "${required[@]}"; do
    printf 'fixture: %s\n' "${file}" > "${TREE}/${file}"
done
cat > "${TREE}/Makefile" <<'MAKE'
.PHONY: clean
libbz2.a: bzlib.h bzlib_private.h words0 blocksort.c huffman.c crctable.c randtable.c compress.c decompress.c bzlib.c
	printf '%s\n' 'fresh test archive' > libbz2.a
clean:
	test ! -f fail-clean
	rm -f *.o libbz2.a
MAKE
ARCHIVE="${TMP_ROOT}/${ARCHIVE_NAME}.tar.gz"
tar -czf "${ARCHIVE}" -C "${TMP_ROOT}/archive tree" "${ARCHIVE_NAME}"

BUILD_ROOT="${TMP_ROOT}/builder's project with spaces/bzip2"
SOURCE="${BUILD_ROOT}/${ARCHIVE_NAME}"
mkdir -p "${SOURCE}"
printf 'stale library\n' > "${SOURCE}/libbz2.a"
printf 'stale object\n' > "${SOURCE}/bzlib.o"
if babet_bzip2_source_complete "${SOURCE}"; then
    fail "a library-only source directory was accepted"
fi
pass "bzip2 source containing only old build products is rejected"

for file in "${required[@]}"; do
    mv "${TREE}/${file}" "${TREE}/${file}.saved"
    if babet_bzip2_source_complete "${TREE}"; then
        fail "source missing ${file} was accepted"
    fi
    mv "${TREE}/${file}.saved" "${TREE}/${file}"
done
pass "all eleven bzip2 build inputs are required"

babet_prepare_bzip2_source "${SOURCE}" "${BUILD_ROOT}" "${ARCHIVE}" "${ARCHIVE_NAME}" ||
    fail "incomplete source was not repaired"
babet_bzip2_source_complete "${SOURCE}" || fail "repaired source is incomplete"
[ ! -e "${SOURCE}/libbz2.a" ] && [ ! -e "${SOURCE}/bzlib.o" ] ||
    fail "source repair retained stale products"
clean_extraction "${BUILD_ROOT}"
pass "bzip2 repair replaces partial sources and stale objects in a path with spaces"

touch "${SOURCE}/KEEP"
babet_prepare_bzip2_source "${SOURCE}" "${BUILD_ROOT}" "${TMP_ROOT}/missing.tar.gz" "${ARCHIVE_NAME}" ||
    fail "complete source was not reused"
[ -f "${SOURCE}/KEEP" ] || fail "complete source was replaced"
pass "complete bzip2 source is reused without opening the archive"

FRESH_ROOT="${TMP_ROOT}/fresh build/bzip2"
babet_prepare_bzip2_source "${FRESH_ROOT}/${ARCHIVE_NAME}" "${FRESH_ROOT}" "${ARCHIVE}" "${ARCHIVE_NAME}" ||
    fail "fresh source extraction failed"
clean_extraction "${FRESH_ROOT}"
pass "bzip2 source can be extracted into a missing build directory"

BAD_TREE="${TMP_ROOT}/bad tree/${ARCHIVE_NAME}"
mkdir -p "${BAD_TREE}"
printf 'not a complete source tree\n' > "${BAD_TREE}/bzlib.h"
tar -czf "${TMP_ROOT}/incomplete.tar.gz" -C "${TMP_ROOT}/bad tree" "${ARCHIVE_NAME}"
rm "${SOURCE}/bzlib.h"
if babet_prepare_bzip2_source "${SOURCE}" "${BUILD_ROOT}" "${TMP_ROOT}/incomplete.tar.gz" "${ARCHIVE_NAME}"; then
    fail "incomplete archive was accepted"
fi
[ -f "${SOURCE}/KEEP" ] && [ ! -e "${SOURCE}/bzlib.h" ] ||
    fail "failed validation modified the old source"
clean_extraction "${BUILD_ROOT}"
pass "incomplete bzip2 archive is refused without replacing existing sources"

printf 'not a gzip archive\n' > "${TMP_ROOT}/corrupt.tar.gz"
if babet_prepare_bzip2_source "${SOURCE}" "${BUILD_ROOT}" "${TMP_ROOT}/corrupt.tar.gz" "${ARCHIVE_NAME}" > "${TMP_ROOT}/tar-error.log" 2>&1; then
    fail "failed tar extraction was accepted"
fi
[ -f "${SOURCE}/KEEP" ] || fail "failed extraction discarded the old source"
clean_extraction "${BUILD_ROOT}"
pass "bzip2 extraction errors preserve the old tree and clean temporary files"

# Exercise the actual bzip2 block and checksum function from build_local.sh.
# This catches a missing call to the repair helper, not just helper behavior.
python3 - "${ROOT}/build_local.sh" "${TMP_ROOT}/bootstrap.sh" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
verify = source.split('verify_sha256() {', 1)[1].split('\n}\n', 1)[0]
block = source.split('# Installer et compiler bzip2 / libbz2 si nécessaire.\n', 1)[1]
block = block.split('# Installer et compiler Zstandard / libzstd si nécessaire.', 1)[0]
pathlib.Path(sys.argv[2]).write_text('''#!/bin/bash
set -eu
. "${BABET_BOOTSTRAP_HELPERS}"
BZIP2_VERSION=1.0.8
BZIP2_DIR="bzip2-${BZIP2_VERSION}"
BZIP2_TAR="${BZIP2_DIR}.tar.gz"
BZIP2_ROOT="${BABET_BOOTSTRAP_ROOT}/bzip2"
BZIP2_SOURCE_DIR="${BZIP2_ROOT}/${BZIP2_DIR}"
BZIP2_INSTALL_DIR="${BZIP2_ROOT}/install"
BZIP2_LIB="${BZIP2_INSTALL_DIR}/lib/libbz2.a"
BZIP2_INCLUDE="${BZIP2_INSTALL_DIR}/include"
DOWNLOAD_DIR="${BABET_BOOTSTRAP_ROOT}/downloads"
BZIP2_SHA256="${BABET_BOOTSTRAP_SHA256}"
BZIP2_URLS=(disabled)
download_with_fallback() { echo "unexpected download" >&2; return 1; }
''' + 'verify_sha256() {' + verify + '\n}\n' + block)
PY

CASE_ROOT="${TMP_ROOT}/actual builder's project with spaces"
CASE_SOURCE="${CASE_ROOT}/bzip2/${ARCHIVE_NAME}"
CASE_INSTALL="${CASE_ROOT}/bzip2/install"
mkdir -p "${CASE_ROOT}/downloads" "${CASE_SOURCE}" "${CASE_INSTALL}/lib"
cp "${ARCHIVE}" "${CASE_ROOT}/downloads/${ARCHIVE_NAME}.tar.gz"
printf 'stale library\n' > "${CASE_SOURCE}/libbz2.a"
printf 'partial install\n' > "${CASE_INSTALL}/lib/libbz2.a"
ARCHIVE_SHA="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
run_builder() {
    BABET_BOOTSTRAP_HELPERS="${SCRIPT_DIR}/build_dependency_utils.sh" \
    BABET_BOOTSTRAP_ROOT="${CASE_ROOT}" BABET_BOOTSTRAP_SHA256="${ARCHIVE_SHA}" \
        bash "${TMP_ROOT}/bootstrap.sh"
}
if ! run_builder > "${TMP_ROOT}/build.log" 2>&1; then
    cat "${TMP_ROOT}/build.log"
    fail "actual bzip2 bootstrap did not repair the reported partial-cache failure"
fi
cmp -s "${TREE}/bzlib.h" "${CASE_INSTALL}/include/bzlib.h" ||
    fail "public header was not installed"
grep -qxF 'fresh test archive' "${CASE_INSTALL}/lib/libbz2.a" ||
    fail "stale library was installed"
clean_extraction "${CASE_ROOT}/bzip2"
pass "actual bzip2 bootstrap repairs the missing-header failure and installs fresh products"

mv "${CASE_ROOT}/downloads/${ARCHIVE_NAME}.tar.gz" "${TMP_ROOT}/cached.tar.gz"
touch "${CASE_SOURCE}/fail-clean"
run_builder > "${TMP_ROOT}/build.log" 2>&1 || fail "complete installation was rebuilt"
grep -qxF 'fresh test archive' "${CASE_INSTALL}/lib/libbz2.a" || fail "complete installation was modified"
pass "actual bzip2 bootstrap reuses a complete installation without a download or build"

mv "${TMP_ROOT}/cached.tar.gz" "${CASE_ROOT}/downloads/${ARCHIVE_NAME}.tar.gz"
rm "${CASE_INSTALL}/include/bzlib.h"
if run_builder > "${TMP_ROOT}/build.log" 2>&1; then
    fail "make clean failure was ignored"
fi
[ ! -e "${CASE_INSTALL}/lib/libbz2.a" ] || fail "archive was published after a clean failure"
pass "actual bzip2 bootstrap stops when make clean fails"

rm "${CASE_SOURCE}/fail-clean"
touch "${CASE_SOURCE}/KEEP"
run_builder > "${TMP_ROOT}/build.log" 2>&1 || {
    cat "${TMP_ROOT}/build.log"
    fail "partial installation was not rebuilt from complete sources"
}
[ -f "${CASE_SOURCE}/KEEP" ] && [ -f "${CASE_INSTALL}/include/bzlib.h" ] ||
    fail "complete sources were replaced or header was not restored"
pass "actual bzip2 bootstrap rebuilds a partial installation while retaining complete sources"

rm "${CASE_INSTALL}/include/bzlib.h"
printf 'wrong archive\n' > "${CASE_ROOT}/downloads/${ARCHIVE_NAME}.tar.gz"
if run_builder > "${TMP_ROOT}/build.log" 2>&1; then
    fail "archive checksum mismatch was accepted"
fi
[ -f "${CASE_SOURCE}/KEEP" ] && [ -f "${CASE_INSTALL}/lib/libbz2.a" ] ||
    fail "checksum mismatch modified the source or installation"
pass "actual bzip2 bootstrap verifies SHA256 before changing sources or installation"

echo "bzip2 bootstrap regression tests: ${pass_count} PASS / 0 FAIL"
