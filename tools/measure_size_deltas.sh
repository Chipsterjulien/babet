#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_FILE="${ROOT_DIR}/build/project_build/CMakeCache.txt"
BASELINE_BINARY="${ROOT_DIR}/build/size-audit-babet"
OUT_DIR="${ROOT_DIR}/build/size-differentials"
REPORT="${OUT_DIR}/report.txt"

if [ ! -f "${CACHE_FILE}" ]; then
    echo "ERREUR: cache CMake de référence absent: ${CACHE_FILE}" >&2
    echo "Lance d'abord ./build_local.sh --size-audit." >&2
    exit 1
fi
if [ ! -x "${BASELINE_BINARY}" ]; then
    echo "ERREUR: binaire strippé de référence absent: ${BASELINE_BINARY}" >&2
    echo "Lance d'abord ./build_local.sh --size-audit." >&2
    exit 1
fi
if ! command -v strip >/dev/null 2>&1; then
    echo "ERREUR: strip est requis pour les mesures différentielles." >&2
    exit 1
fi

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

required_vars=(
    LUA_LIB LUA_INCLUDE OPENSSL_LIB CRYPTO_LIB MINIZ_SRC MINIZ_INCLUDE
    LIBARCHIVE_LIB LIBARCHIVE_INCLUDE ZLIB_LIB ZLIB_INCLUDE LZMA_LIB LZMA_INCLUDE
    BZIP2_LIB BZIP2_INCLUDE BZIP2_VERSION ZSTD_LIB ZSTD_INCLUDE ABSL_CMAKE_DIR
    RE2_CMAKE_DIR RE2_INCLUDE NCURSES_LIB NCURSES_INCLUDE JSON_INCLUDE
    HTTPLIB_INCLUDE TOMLPP_INCLUDE SQLITE_SRC SQLITE_INCLUDE GENERATED_INCLUDE
)

cmake_args=()
for var in "${required_vars[@]}"; do
    value="$(cache_value "${var}")"
    if [ -z "${value}" ]; then
        echo "ERREUR: variable ${var} absente du cache CMake de référence." >&2
        exit 1
    fi
    cmake_args+=("-D${var}=${value}")
done
cmake_args+=(
    -DBABET_ENABLE_SANITIZERS=OFF
    -DBABET_ENABLE_SIZE_AUDIT=OFF
)

baseline_size="$(stat -c '%s' "${BASELINE_BINARY}")"
mkdir -p "${OUT_DIR}"

cat > "${REPORT}" <<EOF_REPORT
Babet differential stripped-size measurements
=============================================

Baseline: ${baseline_size} bytes

These are real stripped-binary deltas. The first five rows remove one feature
group at a time; later rows deliberately combine groups to expose shared
dependency effects and the current light-builder floor. These measurements are
more useful than linker-map attribution for deciding whether a supported build
profile is justified.

Variant                              Size (bytes)       Delta saved    Baseline
-----------------------------------  ---------------  ---------------  --------
EOF_REPORT

measure_variant() {
    local name="$1"
    shift
    local build_dir="${OUT_DIR}/${name}-build"
    local binary="${OUT_DIR}/babet-${name}"
    local feature_args=()
    local flag

    for flag in "$@"; do
        feature_args+=("-D${flag}=ON")
    done

    rm -rf -- "${build_dir}"
    cmake -S "${ROOT_DIR}" -B "${build_dir}" \
        "${cmake_args[@]}" \
        "${feature_args[@]}" >/dev/null
    cmake --build "${build_dir}" --target babet -j"$(nproc)" >/dev/null
    cp -- "${build_dir}/babet" "${binary}"
    strip "${binary}"

    local size delta pct
    size="$(stat -c '%s' "${binary}")"
    delta=$((baseline_size - size))
    pct="$(awk -v d="${delta}" -v b="${baseline_size}" 'BEGIN { printf "%.2f%%", (d * 100.0) / b }')"
    printf '%-35s  %15d  %15d  %8s\n' \
        "${name}" "${size}" "${delta}" "${pct}" >> "${REPORT}"
}

measure_variant "without-sqlite" BABET_SIZE_EXPERIMENT_NO_SQLITE
measure_variant "without-find-re2" BABET_SIZE_EXPERIMENT_NO_FIND_RE2
measure_variant "without-network" BABET_SIZE_EXPERIMENT_NO_NETWORK
measure_variant "without-archive-compression" BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
measure_variant "without-hashing" \
    BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING
measure_variant "without-network-hashing" \
    BABET_SIZE_EXPERIMENT_NO_NETWORK \
    BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING
measure_variant "without-four-large" \
    BABET_SIZE_EXPERIMENT_NO_SQLITE \
    BABET_SIZE_EXPERIMENT_NO_FIND_RE2 \
    BABET_SIZE_EXPERIMENT_NO_NETWORK \
    BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION
measure_variant "without-four-large-hashing" \
    BABET_SIZE_EXPERIMENT_NO_SQLITE \
    BABET_SIZE_EXPERIMENT_NO_FIND_RE2 \
    BABET_SIZE_EXPERIMENT_NO_NETWORK \
    BABET_SIZE_EXPERIMENT_NO_ARCHIVE_COMPRESSION \
    BABET_SIZE_EXPERIMENT_NO_OPENSSL_HASHING

cat >> "${REPORT}" <<'EOF_REPORT'

Interpretation rule
-------------------
Do not sum the one-feature rows. The combined rows deliberately measure shared
dependency effects: network+hashing can release the OpenSSL static archives,
without-four-large is the first empirical light-builder candidate, and
without-four-large-hashing measures the current experimental light-builder
floor with hashing removed as well.
EOF_REPORT

cat "${REPORT}"
echo
echo "Rapport différentiel : ${REPORT}"
