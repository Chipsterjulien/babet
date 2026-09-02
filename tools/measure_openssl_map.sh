#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_FILE="${ROOT_DIR}/build/project_build/CMakeCache.txt"
SOURCE_MAP="${ROOT_DIR}/build/project_build/babet-link.map"
BASELINE_BINARY="${ROOT_DIR}/build/size-audit-babet"
SIZE_REPORT="${ROOT_DIR}/build/size-audit.txt"
OUT_DIR="${ROOT_DIR}/build/openssl-study"
MAP_FILE="${OUT_DIR}/babet.map"
REPORT="${OUT_DIR}/map-build-metadata.txt"

die() {
    echo "ERREUR: $*" >&2
    exit 1
}

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

[ -f "${CACHE_FILE}" ] || die "cache CMake absent: ${CACHE_FILE}"
[ -f "${SOURCE_MAP}" ] || die "map size-audit absente: ${SOURCE_MAP}"
[ -x "${BASELINE_BINARY}" ] || die "baseline strippée absente: ${BASELINE_BINARY}"
[ -f "${SIZE_REPORT}" ] || die "rapport size-audit absent: ${SIZE_REPORT}"

openssl_lib="$(cache_value OPENSSL_LIB)"
crypto_lib="$(cache_value CRYPTO_LIB)"
case "${openssl_lib}|${crypto_lib}" in
    *openssl-3.5.8*) ;;
    *)
        die "Candidate 9 exige OpenSSL 3.5.8; cache actuel: OPENSSL_LIB=${openssl_lib:-<absent>} CRYPTO_LIB=${crypto_lib:-<absent>}"
        ;;
esac

mkdir -p "${OUT_DIR}"
cp -- "${SOURCE_MAP}" "${MAP_FILE}"

baseline_size="$(stat -c '%s' "${BASELINE_BINARY}")"
baseline_sha="$(sha256sum "${BASELINE_BINARY}" | awk '{print $1}')"
map_sha="$(sha256sum "${MAP_FILE}" | awk '{print $1}')"
commit="unavailable"
if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse --verify HEAD >/dev/null 2>&1; then
    commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
fi

compiler="$(cache_value CMAKE_CXX_COMPILER)"
compiler_id="$(cache_value CMAKE_CXX_COMPILER_ID)"
compiler_version="$(cache_value CMAKE_CXX_COMPILER_VERSION)"
linker="$(command -v ld || true)"
strip_bin="$(command -v strip || true)"
openssl_cli="$(dirname "${crypto_lib}")/apps/openssl"

{
    echo "Babet Candidate 9 — exact baseline/map provenance"
    echo "================================================="
    echo
    echo "date_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "architecture=$(uname -m)"
    echo "commit=${commit}"
    echo "baseline_binary=${BASELINE_BINARY}"
    echo "baseline_size=${baseline_size}"
    echo "baseline_sha256=${baseline_sha}"
    echo "source_map=${SOURCE_MAP}"
    echo "copied_map=${MAP_FILE}"
    echo "map_sha256=${map_sha}"
    echo "size_report=${SIZE_REPORT}"
    echo "cxx_compiler=${compiler}"
    echo "cxx_compiler_id=${compiler_id}"
    echo "cxx_compiler_version=${compiler_version}"
    if [ -n "${compiler}" ] && [ -x "${compiler}" ]; then
        echo "cxx_version_line=$("${compiler}" --version | head -n1)"
    fi
    if [ -n "${linker}" ]; then
        echo "ld_version_line=$("${linker}" --version | head -n1)"
    fi
    if [ -n "${strip_bin}" ]; then
        echo "strip_version_line=$("${strip_bin}" --version | head -n1)"
    fi
    echo "openssl_lib=${openssl_lib}"
    echo "crypto_lib=${crypto_lib}"
    if [ -x "${openssl_cli}" ]; then
        echo "openssl_version=$("${openssl_cli}" version)"
        echo "openssl_dir=$("${openssl_cli}" version -d)"
    fi
    echo
    echo "NOTE: Candidate 9 analyses the exact GNU ld map emitted by the same"
    echo "./build_local.sh --size-audit link that produced the stripped baseline."
    echo "There is no second comparison build and therefore no linker-flag drift."
} > "${REPORT}"

cat "${REPORT}"
echo
echo "Map Candidate 9 : ${MAP_FILE}"
