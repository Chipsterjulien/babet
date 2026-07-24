#!/bin/bash
# validate_release.sh — validation complète avant publication.
#
# Enchaîne automatiquement :
#   - un préflight léger du bootstrap Zstandard ;
#   1. build + tests ASan/UBSan ;
#   2. restauration du build normal + tests complets ;
#   3. smoke tests réseau avec le binaire normal final.
#
# Le réseau est volontairement testé APRES la restauration du build normal :
# les sanitizers servent à détecter les erreurs mémoire/UB, mais peuvent
# modifier les timings et les interpositions système. Le smoke test valide le
# binaire réellement destiné à la release.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SANITIZERS_RC=1
NORMAL_RC=1
NETWORK_RC=1
NETWORK_SKIPPED=0

print_stage() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

print_stage "Préflight — bootstrap Zstandard"
if ! bash "${SCRIPT_DIR}/tools/test_zstd_bootstrap.sh"; then
    echo
    echo "Validation pré-release : ÉCHEC"
    exit 1
fi

print_stage "Étape 1/3 — ASan + UBSan"
bash "${SCRIPT_DIR}/run_tests.sh" --sanitizers
SANITIZERS_RC=$?

print_stage "Étape 2/3 — restauration et validation du build normal"
bash "${SCRIPT_DIR}/run_tests.sh"
NORMAL_RC=$?

if [ ${NORMAL_RC} -eq 0 ]; then
    print_stage "Étape 3/3 — smoke tests réseau (binaire normal)"
    bash "${SCRIPT_DIR}/smoke_test_network.sh" "${SCRIPT_DIR}/test/babet"
    NETWORK_RC=$?
else
    NETWORK_SKIPPED=1
    echo
    echo "Étape 3/3 — smoke tests réseau : IGNORÉS"
    echo "Le build normal final ou ses tests ont échoué."
fi

echo
echo "============================================================"
echo "Bilan de la validation pré-release"
echo "============================================================"
if [ ${SANITIZERS_RC} -eq 0 ]; then
    echo "  ASan + UBSan        : OK"
else
    echo "  ASan + UBSan        : ÉCHEC (code ${SANITIZERS_RC})"
fi

if [ ${NORMAL_RC} -eq 0 ]; then
    echo "  Build normal final  : OK"
else
    echo "  Build normal final  : ÉCHEC (code ${NORMAL_RC})"
fi

if [ ${NETWORK_SKIPPED} -eq 1 ]; then
    echo "  Smoke tests réseau  : IGNORÉS"
elif [ ${NETWORK_RC} -eq 0 ]; then
    echo "  Smoke tests réseau  : OK"
else
    echo "  Smoke tests réseau  : ÉCHEC (code ${NETWORK_RC})"
fi

if [ ${SANITIZERS_RC} -eq 0 ] \
    && [ ${NORMAL_RC} -eq 0 ] \
    && [ ${NETWORK_SKIPPED} -eq 0 ] \
    && [ ${NETWORK_RC} -eq 0 ]; then
    echo
    echo "Validation pré-release : OK"
    exit 0
fi

echo
echo "Validation pré-release : ÉCHEC"
exit 1
