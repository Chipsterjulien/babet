#!/bin/bash
# Lightweight regression test for the Zstandard bootstrap guards.
# It uses synthetic archives only: no network access and no compilation.

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build_dependency_utils.sh
. "${SCRIPT_DIR}/build_dependency_utils.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "${TMP_ROOT}"' EXIT

pass_count=0
fail() {
    echo "[FAIL] $1"
    exit 1
}
pass() {
    echo "[PASS] $1"
    pass_count=$((pass_count + 1))
}

INSTALL_DIR="${TMP_ROOT}/install"
mkdir -p "${INSTALL_DIR}/lib" "${INSTALL_DIR}/include"
: > "${INSTALL_DIR}/lib/libzstd.a"
: > "${INSTALL_DIR}/include/zstd.h"

if babet_zstd_install_complete \
        "${INSTALL_DIR}/lib/libzstd.a" "${INSTALL_DIR}/include"; then
    fail "an installation missing zstd_errors.h was accepted"
fi
pass "partial Zstandard installation is rejected"

: > "${INSTALL_DIR}/include/zstd_errors.h"
if ! babet_zstd_install_complete \
        "${INSTALL_DIR}/lib/libzstd.a" "${INSTALL_DIR}/include"; then
    fail "a complete installation was rejected"
fi
pass "complete Zstandard installation is accepted"

ARCHIVE_TREE="${TMP_ROOT}/archive-tree/zstd-1.5.7"
mkdir -p "${ARCHIVE_TREE}/build/cmake"
printf '%s\n' 'cmake_minimum_required(VERSION 3.22)' \
    > "${ARCHIVE_TREE}/build/cmake/CMakeLists.txt"
printf '%s\n' 'archive marker' > "${ARCHIVE_TREE}/MARKER"
tar -czf "${TMP_ROOT}/zstd-1.5.7.tar.gz" \
    -C "${TMP_ROOT}/archive-tree" zstd-1.5.7

ZSTD_ROOT="${TMP_ROOT}/zstd"
ZSTD_SOURCE="${ZSTD_ROOT}/zstd-1.5.7"
mkdir -p "${ZSTD_SOURCE}"
printf '%s\n' 'stale partial tree' > "${ZSTD_SOURCE}/STALE"

if ! babet_prepare_zstd_source "${ZSTD_SOURCE}" "${ZSTD_ROOT}" \
        "${TMP_ROOT}/zstd-1.5.7.tar.gz" "zstd-1.5.7"; then
    fail "an incomplete source tree was not repaired"
fi
if [ ! -f "${ZSTD_SOURCE}/build/cmake/CMakeLists.txt" ] || \
   [ ! -f "${ZSTD_SOURCE}/MARKER" ] || \
   [ -e "${ZSTD_SOURCE}/STALE" ]; then
    fail "source repair did not replace the stale tree cleanly"
fi
pass "incomplete Zstandard source is re-extracted cleanly"

printf '%s\n' 'keep existing complete tree' > "${ZSTD_SOURCE}/KEEP"
if ! babet_prepare_zstd_source "${ZSTD_SOURCE}" "${ZSTD_ROOT}" \
        "${TMP_ROOT}/zstd-1.5.7.tar.gz" "zstd-1.5.7"; then
    fail "a complete source tree was rejected"
fi
if [ ! -f "${ZSTD_SOURCE}/KEEP" ]; then
    fail "a complete source tree was unnecessarily replaced"
fi
pass "complete Zstandard source is reused"

BAD_TREE="${TMP_ROOT}/bad-tree/zstd-1.5.7"
mkdir -p "${BAD_TREE}/build/cmake"
printf '%s\n' 'missing CMake entry point' > "${BAD_TREE}/README"
tar -czf "${TMP_ROOT}/bad-zstd.tar.gz" \
    -C "${TMP_ROOT}/bad-tree" zstd-1.5.7
rm -rf "${ZSTD_SOURCE}"

if babet_prepare_zstd_source "${ZSTD_SOURCE}" "${ZSTD_ROOT}" \
        "${TMP_ROOT}/bad-zstd.tar.gz" "zstd-1.5.7"; then
    fail "a malformed source archive was accepted"
fi
if [ -e "${ZSTD_SOURCE}" ]; then
    fail "a malformed archive left a partial final source tree"
fi
pass "malformed Zstandard archive leaves no partial source tree"

echo "Zstandard bootstrap regression tests: ${pass_count} PASS / 0 FAIL"
