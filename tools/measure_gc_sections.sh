#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/build/project_build/CMakeCache.txt"
BASELINE="${ROOT}/build/size-audit-babet"
OUT="${ROOT}/build/gc-sections-study"
REPORT="${OUT}/report.txt"
GC_LOG="${OUT}/variant-a-print-gc-sections.txt"
THRESHOLD=$((256 * 1024))
OPENSSL_VERSION="3.5.8"
OPENSSL_SHA256="a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2"
OPENSSL_TAR="${ROOT}/downloads/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_GC_ROOT="${OUT}/openssl-gc"
OPENSSL_GC_SRC="${OPENSSL_GC_ROOT}/openssl-${OPENSSL_VERSION}"
OPENSSL_GC_SSL="${OPENSSL_GC_SRC}/libssl.a"
OPENSSL_GC_CRYPTO="${OPENSSL_GC_SRC}/libcrypto.a"

[ -f "${CACHE}" ] || { echo "ERREUR: cache CMake absent." >&2; exit 1; }
[ -x "${BASELINE}" ] || { echo "ERREUR: baseline size-audit absente." >&2; exit 1; }
for cmd in cmake strip sha256sum tar; do command -v "${cmd}" >/dev/null 2>&1 || { echo "ERREUR: ${cmd} requis." >&2; exit 1; }; done
mkdir -p "${OUT}"

cache_value() {
    local key="$1"
    awk -v key="${key}" 'index($0,key ":")==1 { line=$0; sub(/^[^=]*=/,"",line); print line; exit }' "${CACHE}"
}

required=(LUA_LIB LUA_INCLUDE MINIZ_SRC MINIZ_INCLUDE LIBARCHIVE_LIB LIBARCHIVE_INCLUDE ZLIB_LIB ZLIB_INCLUDE LZMA_LIB LZMA_INCLUDE BZIP2_LIB BZIP2_INCLUDE BZIP2_VERSION ZSTD_LIB ZSTD_INCLUDE ABSL_CMAKE_DIR RE2_CMAKE_DIR RE2_INCLUDE NCURSES_LIB NCURSES_INCLUDE JSON_INCLUDE HTTPLIB_INCLUDE TOMLPP_INCLUDE SQLITE_SRC SQLITE_INCLUDE GENERATED_INCLUDE)
common=()
for var in "${required[@]}"; do
    value="$(cache_value "${var}")"
    [ -n "${value}" ] || { echo "ERREUR: variable CMake absente: ${var}" >&2; exit 1; }
    common+=("-D${var}=${value}")
done
common+=( -DBABET_ENABLE_SANITIZERS=OFF -DBABET_ENABLE_SIZE_AUDIT=OFF )
BASE_SSL="$(cache_value OPENSSL_LIB)"
BASE_CRYPTO="$(cache_value CRYPTO_LIB)"
[ -f "${BASE_SSL}" ] && [ -f "${BASE_CRYPTO}" ] || { echo "ERREUR: archives OpenSSL baseline absentes." >&2; exit 1; }

build_openssl_gc() {
    if [ -f "${OPENSSL_GC_SSL}" ] && [ -f "${OPENSSL_GC_CRYPTO}" ]; then
        return
    fi
    [ -f "${OPENSSL_TAR}" ] || { echo "ERREUR: tarball OpenSSL absent: ${OPENSSL_TAR}" >&2; exit 1; }
    actual="$(sha256sum "${OPENSSL_TAR}" | awk '{print $1}')"
    [ "${actual}" = "${OPENSSL_SHA256}" ] || { echo "ERREUR: SHA256 OpenSSL inattendu." >&2; exit 1; }
    rm -rf -- "${OPENSSL_GC_ROOT}"
    mkdir -p "${OPENSSL_GC_ROOT}"
    tar -xzf "${OPENSSL_TAR}" -C "${OPENSSL_GC_ROOT}"
    (
        cd "${OPENSSL_GC_SRC}"
        ./Configure no-shared --openssldir=/etc/ssl -ffunction-sections -fdata-sections >/dev/null
        make -j"$(nproc)" >/dev/null
    )
    [ -f "${OPENSSL_GC_SSL}" ] && [ -f "${OPENSSL_GC_CRYPTO}" ] || { echo "ERREUR: OpenSSL GC non produit." >&2; exit 1; }
}

build_variant() {
    local name="$1" ssl="$2" crypto="$3" print_gc="$4" babet_sections="$5"
    local dir="${OUT}/${name}-build" bin="${OUT}/babet-${name}"
    rm -rf -- "${dir}"
    args=("${common[@]}" "-DOPENSSL_LIB=${ssl}" "-DCRYPTO_LIB=${crypto}" -DBABET_ENABLE_GC_SECTIONS=ON)
    if [ "${babet_sections}" = 1 ]; then args+=( -DBABET_SIZE_EXPERIMENT_GC_BABET_SECTIONS=ON ); fi
    if [ "${print_gc}" = 1 ]; then args+=( -DBABET_SIZE_EXPERIMENT_GC_PRINT=ON ); fi
    cmake -S "${ROOT}" -B "${dir}" "${args[@]}" >/dev/null
    if [ "${print_gc}" = 1 ]; then
        : > "${GC_LOG}"
        cmake --build "${dir}" --target babet -j"$(nproc)" >/dev/null 2>"${GC_LOG}"
    else
        cmake --build "${dir}" --target babet -j"$(nproc)" >/dev/null
    fi
    cp -- "${dir}/babet" "${bin}"
    strip "${bin}"
}

baseline_size="$(stat -c '%s' "${BASELINE}")"
build_variant variant-a "${BASE_SSL}" "${BASE_CRYPTO}" 1 0
build_variant variant-b "${BASE_SSL}" "${BASE_CRYPTO}" 0 1
build_openssl_gc
build_variant variant-c "${OPENSSL_GC_SSL}" "${OPENSSL_GC_CRYPTO}" 0 1

size_a="$(stat -c '%s' "${OUT}/babet-variant-a")"
size_b="$(stat -c '%s' "${OUT}/babet-variant-b")"
size_c="$(stat -c '%s' "${OUT}/babet-variant-c")"
gain_a=$((baseline_size-size_a))
gain_b_total=$((baseline_size-size_b))
gain_c_total=$((baseline_size-size_c))
gain_b_marginal=$((size_a-size_b))
gain_c_marginal=$((size_b-size_c))

cat > "${REPORT}" <<EOF
Babet Candidate 10 — section-GC stripped-size measurements
===========================================================

Baseline: ${baseline_size} bytes
Acceptance-study threshold fixed before measurement: ${THRESHOLD} bytes (256 KiB)

Variant A: -Wl,--gc-sections only
  size=${size_a}
  gain_vs_baseline=${gain_a}

Variant B: A + -ffunction-sections -fdata-sections on Babet-owned sources
  size=${size_b}
  gain_vs_baseline=${gain_b_total}
  marginal_vs_A=${gain_b_marginal}

Variant C: B + section-split OpenSSL 3.5.8 archives
  size=${size_c}
  gain_vs_baseline=${gain_c_total}
  marginal_vs_B=${gain_c_marginal}

Decision gate
-------------
Candidate 10 is measurement-only. A total realised saving below 256 KiB is an
immediate STOP. A saving at or above 256 KiB only authorises an adoption review;
it does not enable these flags in the normal build. Runtime surface, plugins,
embedding/packaging and TLS capabilities must remain protected before adoption.
EOF

cat "${REPORT}"
echo "Report: ${REPORT}"
