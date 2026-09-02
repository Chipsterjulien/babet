#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${ROOT}/build/project_build/CMakeCache.txt"
OUT="${ROOT}/build/gc-sections-study"
REPORT="${OUT}/archive-section-audit.txt"
mkdir -p "${OUT}"

[ -f "${CACHE}" ] || { echo "ERREUR: cache CMake absent; lance d'abord --size-audit." >&2; exit 1; }
for cmd in ar readelf; do command -v "${cmd}" >/dev/null 2>&1 || { echo "ERREUR: ${cmd} requis." >&2; exit 1; }; done

cache_value() {
    local key="$1"
    awk -v key="${key}" 'index($0,key ":")==1 { line=$0; sub(/^[^=]*=/,"",line); print line; exit }' "${CACHE}"
}

archives=(
    "$(c++ -print-file-name=libstdc++.a)"
    "$(c++ -print-file-name=libsupc++.a)"
    "$(cc -print-libgcc-file-name)"
    "$(cache_value LUA_LIB)"
    "$(cache_value ZSTD_LIB)"
    "$(cache_value LIBARCHIVE_LIB)"
    "$(cache_value CRYPTO_LIB)"
    "$(cache_value OPENSSL_LIB)"
)

: > "${REPORT}"
printf 'Babet Candidate 10 — existing per-function section audit\n' | tee -a "${REPORT}"
printf '========================================================\n\n' | tee -a "${REPORT}"
printf '%-56s %8s %8s\n' "archive" "sampled" "split" | tee -a "${REPORT}"
printf '%-56s %8s %8s\n' "-------" "-------" "-----" | tee -a "${REPORT}"

for archive in "${archives[@]}"; do
    [ -f "${archive}" ] || continue
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/babet-gc-audit.XXXXXX")"
    sampled=0
    split=0
    while IFS= read -r member && [ ${sampled} -lt 40 ]; do
        [ -n "${member}" ] || continue
        obj="${tmp}/sample.o"
        if ar p "${archive}" "${member}" > "${obj}" 2>/dev/null && [ -s "${obj}" ]; then
            sampled=$((sampled + 1))
            if readelf -S "${obj}" 2>/dev/null | grep -Eq '\.text\.[^[:space:]]+'; then
                split=$((split + 1))
            fi
        fi
    done < <(ar t "${archive}" 2>/dev/null)
    printf '%-56s %8d %8d\n' "${archive}" "${sampled}" "${split}" | tee -a "${REPORT}"
    rm -rf -- "${tmp}"
done

echo | tee -a "${REPORT}"
echo "This is an observation only: variant A measures the actual linker-only gain." | tee -a "${REPORT}"
echo "Report: ${REPORT}"
