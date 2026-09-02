#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/build/gc-sections-study/candidate11"
A="${OUT}/babet-a"
ABUILD="${OUT}/a-build"
ASAN="${OUT}/babet-a-san"
ASANBUILD="${OUT}/a-san-build"
D="${OUT}/babet-d"
DBUILD="${OUT}/d-build"
DSAN="${OUT}/babet-d-san"
DSANBUILD="${OUT}/d-san-build"
SUMMARY="${OUT}/full-validation-summary.txt"

for f in "${A}" "${ASAN}" "${D}" "${DSAN}"; do
    [ -x "${f}" ] || { echo "ERREUR: binaire Candidate 11 absent: ${f}" >&2; exit 1; }
done
for d in "${ABUILD}" "${ASANBUILD}" "${DBUILD}" "${DSANBUILD}"; do
    [ -d "${d}" ] || { echo "ERREUR: build Candidate 11 absent: ${d}" >&2; exit 1; }
done
mkdir -p "${OUT}"
: > "${SUMMARY}"

pick_real_locale() {
    locale -a 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^fr_FR\.(utf-8|utf8)$/ {print; exit}'
}
REAL_LOCALE="$(pick_real_locale || true)"
if [ -z "${REAL_LOCALE}" ]; then
    REAL_LOCALE="$(locale -a 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /_.*\.(utf-8|utf8)$/ && $0 !~ /^C\./ {print; exit}' || true)"
fi
if [ -z "${REAL_LOCALE}" ]; then
    echo "ERREUR: aucune locale UTF-8 réelle (par ex. fr_FR.UTF-8) n'est installée." >&2
    echo "Candidate 11 refuse d'adopter A sans cette vérification ciblée." >&2
    exit 1
fi
printf 'real_locale=%s\n' "${REAL_LOCALE}" | tee -a "${SUMMARY}"

run_release_variant() {
    local label="$1" normal="$2" normal_build="$3" san="$4" san_build="$5"
    local log="${OUT}/release-${label}.log"
    echo "==> validation pré-release complète ${label}"
    if env \
        BABET_TEST_PREBUILT_BINARY_NORMAL="${normal}" \
        BABET_TEST_PREBUILT_BUILD_DIR_NORMAL="${normal_build}" \
        BABET_TEST_PREBUILT_BINARY_SANITIZERS="${san}" \
        BABET_TEST_PREBUILT_BUILD_DIR_SANITIZERS="${san_build}" \
        bash "${ROOT}/run_tests.sh" --release >"${log}" 2>&1; then
        echo "[PASS] ${label}: normal + sanitizers + release/network" | tee -a "${SUMMARY}"
    else
        echo "[FAIL] ${label}: validation pré-release" | tee -a "${SUMMARY}"
        echo "--- tail ${log} ---" >&2
        tail -160 "${log}" >&2 || true
        return 1
    fi
}

# A receives one additional full normal campaign under a genuine non-C locale,
# targeting the runtime-library facets that variant A actually discards.
LOCALE_LOG="${OUT}/locale-a.log"
echo "==> campagne complète A sous LC_ALL=${REAL_LOCALE}"
if env LC_ALL="${REAL_LOCALE}" \
    BABET_TEST_PREBUILT_BINARY_NORMAL="${A}" \
    BABET_TEST_PREBUILT_BUILD_DIR_NORMAL="${ABUILD}" \
    bash "${ROOT}/run_tests.sh" >"${LOCALE_LOG}" 2>&1; then
    echo "[PASS] A full suite under LC_ALL=${REAL_LOCALE}" | tee -a "${SUMMARY}"
else
    echo "[FAIL] A full suite under LC_ALL=${REAL_LOCALE}" | tee -a "${SUMMARY}"
    tail -160 "${LOCALE_LOG}" >&2 || true
    exit 1
fi

run_release_variant A "${A}" "${ABUILD}" "${ASAN}" "${ASANBUILD}"
run_release_variant D "${D}" "${DBUILD}" "${DSAN}" "${DSANBUILD}"

cat "${SUMMARY}"
