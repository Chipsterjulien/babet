#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${ROOT}/build/gc-sections-study/candidate11/variant-a-print-gc-sections.txt"
OUT="${ROOT}/build/gc-sections-study/candidate11/gc-audit.txt"
[ -f "${LOG}" ] || { echo "ERREUR: log GC A absent: ${LOG}" >&2; exit 1; }
mkdir -p "$(dirname "${OUT}")"

removed_count="$(grep -c 'removing unused section' "${LOG}" || true)"
libarchive_count="$(grep -Ei 'removing unused section.*libarchive\.a' "${LOG}" | wc -l | tr -d ' ')"
libstdcpp_count="$(grep -Ei 'removing unused section.*(libstdc\+\+\.a|libsupc\+\+\.a)' "${LOG}" | wc -l | tr -d ' ')"

# Only the narrow C surface exported by the Babet executable is adoption-critical
# here. Do NOT match arbitrary "babet_" substrings: C++ COMDAT/template sections
# legitimately contain names such as babet_value and libbabet.a itself.
exported_symbols=(
    babet_version
    babet_status_name
    babet_host_call_argument_count
    babet_host_call_arguments
    babet_host_call_set_result
    babet_host_call_set_error
)

sensitive_file="$(mktemp)"
trap 'rm -f -- "${sensitive_file}"' EXIT

# Section-based registration/lifetime mechanisms must never be discarded.
grep -Ei 'removing unused section.*(\.init_array|\.fini_array|\.ctors|\.dtors)' "${LOG}" \
    >> "${sensitive_file}" || true

# Exact exported C symbols must remain rooted. Match symbol/section text, not
# the containing archive path or unrelated C++ identifiers.
for sym in "${exported_symbols[@]}"; do
    grep -E "removing unused section.*(^|[^[:alnum:]_])${sym}([^[:alnum:]_]|$)" "${LOG}" \
        >> "${sensitive_file}" || true
done

# Deduplicate while preserving deterministic output.
sensitive="$(sort -u "${sensitive_file}" || true)"

{
    echo "Babet Candidate 11 — variant A discarded-section audit"
    echo "======================================================="
    echo
    echo "removed_section_records=${removed_count}"
    echo "libstdcxx_or_libsupcxx_records=${libstdcpp_count}"
    echo "libarchive_records=${libarchive_count}"
    echo
    if [ -n "${sensitive}" ]; then
        echo "SENSITIVE DISCARDS — FAIL"
        printf '%s\n' "${sensitive}"
    else
        echo "[PASS] no exported Babet C symbol / init/fini-array / ctor/dtor section discarded"
    fi
    echo
    echo "Exact exported C symbols protected by this audit:"
    printf '  %s\n' "${exported_symbols[@]}"
    echo
    echo "Note: discarded C++ COMDAT/template sections inside libbabet.a are expected"
    echo "under linker GC and are not treated as exported-surface loss. Runtime/plugin/"
    echo "embedding tests remain the behavioral guardrail."
    echo
    echo "libarchive.a removals (review list, first 80):"
    grep -Ei 'removing unused section.*libarchive\.a' "${LOG}" | head -80 || true
    echo
    echo "Top source archives/files in discarded records:"
    sed -n "s/.*in file ['\"]\([^'\"]*\)['\"].*/\1/p" "${LOG}" \
        | sed 's#(.\+)$##' \
        | sort | uniq -c | sort -nr | head -40 || true
} > "${OUT}"

cat "${OUT}"
[ -z "${sensitive}" ]
