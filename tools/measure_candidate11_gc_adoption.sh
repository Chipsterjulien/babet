#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/build/project_build/CMakeCache.txt"
BASELINE="${ROOT}/build/size-audit-babet"
OUT="${ROOT}/build/gc-sections-study/candidate11"
REPORT="${OUT}/report.txt"
GC_LOG="${OUT}/variant-a-print-gc-sections.txt"
THRESHOLD=$((256 * 1024))
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
OPENSSL_TAR="${ROOT}/downloads/openssl-${OPENSSL_VERSION}.tar.gz"

[ -f "${CACHE}" ] || { echo "ERREUR: cache CMake absent: ${CACHE}" >&2; exit 1; }
[ -x "${BASELINE}" ] || { echo "ERREUR: baseline size-audit absente: ${BASELINE}" >&2; exit 1; }
for cmd in cmake strip sha256sum tar make nproc; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "ERREUR: ${cmd} requis." >&2; exit 1; }
done
mkdir -p "${OUT}"

cache_value() {
    local key="$1"
    awk -v key="${key}" 'index($0,key ":")==1 { line=$0; sub(/^[^=]*=/,"",line); print line; exit }' "${CACHE}"
}

required=(
    LUA_LIB LUA_INCLUDE MINIZ_SRC MINIZ_INCLUDE LIBARCHIVE_LIB LIBARCHIVE_INCLUDE
    ZLIB_LIB ZLIB_INCLUDE LZMA_LIB LZMA_INCLUDE BZIP2_LIB BZIP2_INCLUDE BZIP2_VERSION
    ZSTD_LIB ZSTD_INCLUDE ABSL_CMAKE_DIR RE2_CMAKE_DIR RE2_INCLUDE NCURSES_LIB
    NCURSES_INCLUDE JSON_INCLUDE HTTPLIB_INCLUDE TOMLPP_INCLUDE SQLITE_SRC
    SQLITE_INCLUDE GENERATED_INCLUDE
)
common=()
for var in "${required[@]}"; do
    value="$(cache_value "${var}")"
    [ -n "${value}" ] || { echo "ERREUR: variable CMake absente: ${var}" >&2; exit 1; }
    common+=("-D${var}=${value}")
done
common+=( -DBABET_ENABLE_SIZE_AUDIT=OFF )
BASE_SSL="$(cache_value OPENSSL_LIB)"
BASE_CRYPTO="$(cache_value CRYPTO_LIB)"
[ -f "${BASE_SSL}" ] && [ -f "${BASE_CRYPTO}" ] || {
    echo "ERREUR: archives OpenSSL baseline absentes." >&2
    exit 1
}

build_variant() {
    local name="$1" ssl="$2" crypto="$3" sanitizers="$4" print_gc="$5"
    local dir="${OUT}/${name}-build"
    local bin="${OUT}/babet-${name}"
    local args=("${common[@]}" "-DOPENSSL_LIB=${ssl}" "-DCRYPTO_LIB=${crypto}" -DBABET_ENABLE_GC_SECTIONS=ON)
    if [ "${sanitizers}" = 1 ]; then
        args+=( -DBABET_ENABLE_SANITIZERS=ON )
    else
        args+=( -DBABET_ENABLE_SANITIZERS=OFF )
    fi
    if [ "${print_gc}" = 1 ]; then
        args+=( -DBABET_SIZE_EXPERIMENT_GC_PRINT=ON )
    fi

    rm -rf -- "${dir}"
    cmake -S "${ROOT}" -B "${dir}" "${args[@]}" >/dev/null
    if [ "${print_gc}" = 1 ]; then
        : > "${GC_LOG}"
        cmake --build "${dir}" --target babet -j"$(nproc)" >/dev/null 2>"${GC_LOG}"
    else
        cmake --build "${dir}" --target babet -j"$(nproc)" >/dev/null
    fi
    cp -- "${dir}/babet" "${bin}"
    if [ "${sanitizers}" = 0 ]; then
        strip "${bin}"
    fi
}

build_openssl_pair() {
    [ -f "${OPENSSL_TAR}" ] || { echo "ERREUR: tarball OpenSSL absent: ${OPENSSL_TAR}" >&2; exit 1; }
    local actual
    actual="$(sha256sum "${OPENSSL_TAR}" | awk '{print $1}')"
    [ "${actual}" = "${OPENSSL_SHA256}" ] || { echo "ERREUR: SHA256 OpenSSL inattendu." >&2; exit 1; }

    local tmp
    tmp="$(mktemp -d "${OUT}/openssl-work-XXXXXX")"
    trap 'rm -rf -- "${tmp:-}"' RETURN

    local kind src dest flags
    for kind in control sections; do
        mkdir -p "${tmp}/${kind}"
        tar -xzf "${OPENSSL_TAR}" -C "${tmp}/${kind}"
        src="${tmp}/${kind}/openssl-${OPENSSL_VERSION}"
        dest="${OUT}/openssl-${kind}"
        rm -rf -- "${dest}"
        mkdir -p "${dest}"
        flags=()
        if [ "${kind}" = sections ]; then
            flags+=( -ffunction-sections -fdata-sections )
        fi
        (
            cd "${src}"
            # Keep the production Configure contract literal; the section build
            # differs only by the two compiler flags appended below.
            ./Configure no-shared --openssldir=/etc/ssl "${flags[@]}" >"${dest}/configure.log" 2>&1
            # Only the two static libraries are needed for the witness and D.
            # The default `make` target also builds OpenSSL programs/tests and
            # needlessly consumes substantial temporary disk space.
            make -j"$(nproc)" build_libs >>"${dest}/build.log" 2>&1
        )
        cp -- "${src}/libssl.a" "${dest}/libssl.a"
        cp -- "${src}/libcrypto.a" "${dest}/libcrypto.a"
        # Configure itself must stay clean.  The `build_libs` target may emit
        # mkinstallvars.pl warnings about install-only variables because no install
        # prefix is requested; those warnings do not alter libcrypto.a/libssl.a.
        # The byte-identical production-control witness below is the authoritative
        # equivalence gate for the produced archives.
        if grep -Eqi 'uninitialized value|No value given for (CMAKECONFIGDIR|PKGCONFIGDIR|libdir)' \
            "${dest}/configure.log"; then
            echo "ERREUR: avertissements OpenSSL inattendus pendant Configure (${kind})." >&2
            echo "Voir ${dest}/configure.log" >&2
            exit 1
        fi
        # The copied archives are all Candidate 11 needs from this source tree.
        rm -rf -- "${tmp}/${kind}"
    done
    rm -rf -- "${tmp}"
    trap - RETURN
}

baseline_size="$(stat -c '%s' "${BASELINE}")"

# A: linker GC only, using the exact production OpenSSL archives.
build_variant a "${BASE_SSL}" "${BASE_CRYPTO}" 0 1
size_a="$(stat -c '%s' "${OUT}/babet-a")"
gain_a=$((baseline_size - size_a))

# Control + D come from two fresh OpenSSL builds made from the same tarball.
# The control must reproduce A's stripped size before the section build is
# considered attributable.
build_openssl_pair
CONTROL_SSL="${OUT}/openssl-control/libssl.a"
CONTROL_CRYPTO="${OUT}/openssl-control/libcrypto.a"
SECTION_SSL="${OUT}/openssl-sections/libssl.a"
SECTION_CRYPTO="${OUT}/openssl-sections/libcrypto.a"

build_variant control "${CONTROL_SSL}" "${CONTROL_CRYPTO}" 0 0
size_control="$(stat -c '%s' "${OUT}/babet-control")"
if [ "${size_control}" -ne "${size_a}" ]; then
    cat > "${REPORT}" <<EOF_REPORT
Babet Candidate 11 — GC adoption measurement
=============================================
Baseline: ${baseline_size}
A: ${size_a}
Fresh-production-control: ${size_control}

STOP: the fresh OpenSSL control did not reproduce variant A at the byte-size
level. D would be confounded and was not accepted for attribution.
EOF_REPORT
    cat "${REPORT}"
    exit 1
fi

build_variant d "${SECTION_SSL}" "${SECTION_CRYPTO}" 0 0
size_d="$(stat -c '%s' "${OUT}/babet-d")"
gain_d_total=$((baseline_size - size_d))
gain_d_vs_a=$((size_a - size_d))

# Build matching sanitizer binaries for the full Candidate 11 validation.
build_variant a-san "${BASE_SSL}" "${BASE_CRYPTO}" 1 0
build_variant d-san "${SECTION_SSL}" "${SECTION_CRYPTO}" 1 0

cat > "${REPORT}" <<EOF_REPORT
Babet Candidate 11 — GC adoption measurement
=============================================

Baseline: ${baseline_size} bytes
Precommitted realised-saving review threshold: ${THRESHOLD} bytes (256 KiB)

A — linker GC only
  size=${size_a}
  gain_vs_baseline=${gain_a}

Fresh OpenSSL production-control witness
  size=${size_control}
  matches_A_size=yes
  Configure=./Configure no-shared --openssldir=/etc/ssl

D — A + section-split OpenSSL 3.5.8, without Babet section splitting
  size=${size_d}
  gain_vs_baseline=${gain_d_total}
  marginal_vs_A=${gain_d_vs_a}
  Configure=./Configure no-shared --openssldir=/etc/ssl -ffunction-sections -fdata-sections

Interpretation
--------------
A remains an adoption candidate because its realised saving exceeds the fixed
256 KiB gate. B from Candidate 10 remains STOP (61,440-byte marginal gain).
D is attributable only because the fresh production-control witness reproduces
A's stripped size exactly. Final adoption still requires the Candidate 11 audit,
real-locale run, full normal/sanitizer/release validation, and local TLS
performance check.
EOF_REPORT

cat "${REPORT}"
echo "Report: ${REPORT}"
