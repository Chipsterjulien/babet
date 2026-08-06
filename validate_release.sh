#!/bin/bash
# validate_release.sh — validation complète avant publication.
#
# Enchaîne automatiquement :
#   1. build + tests ASan/UBSan ;
#   2. restauration du build normal + tests complets ;
#   3. smoke tests réseau avec le binaire normal final.
#
# Un échec de compilation est distingué des autres échecs par run_tests.sh.
# Il interrompt immédiatement la campagne : relancer le même code dans le
# second mode ne fournirait aucune information supplémentaire. En revanche,
# un échec de test sous sanitizers laisse encore le build normal s'exécuter,
# afin de restaurer le binaire final et de compléter le diagnostic.
#
# Chaque appel à run_tests.sh exécute d'abord les préflights hermétiques du
# bootstrap Zstandard, du décodage des buffers inotify et des budgets de
# sérialisation workers. Ils passent donc une fois pour le build sanitizer et
# une fois pour le build normal lorsque la compilation sanitizer réussit.
#
# Le réseau est volontairement testé APRES la restauration du build normal :
# les sanitizers servent à détecter les erreurs mémoire/UB, mais peuvent
# modifier les timings et les interpositions système. Le smoke test valide le
# binaire réellement destiné à la release.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_FAILURE_EXIT_CODE=2
SANITIZERS_RC=1
NORMAL_RC=1
NETWORK_RC=1
NORMAL_SKIPPED=0
NETWORK_SKIPPED=0

print_stage() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

print_stage "Étape 1/3 — ASan + UBSan"
bash "${SCRIPT_DIR}/run_tests.sh" --sanitizers
SANITIZERS_RC=$?

if [ ${SANITIZERS_RC} -eq ${BUILD_FAILURE_EXIT_CODE} ]; then
    NORMAL_SKIPPED=1
    NETWORK_SKIPPED=1
    echo
    echo "Étape 2/3 — build normal : IGNORÉ"
    echo "La compilation ASan/UBSan a échoué ; la campagne est arrêtée."
    echo
    echo "Étape 3/3 — smoke tests réseau : IGNORÉS"
    echo "Aucun binaire normal final validé n'est disponible."
else
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
        if [ ${NORMAL_RC} -eq ${BUILD_FAILURE_EXIT_CODE} ]; then
            echo "La compilation du build normal a échoué."
        else
            echo "Le build normal final ou ses tests ont échoué."
        fi
    fi
fi

echo
echo "============================================================"
echo "Bilan de la validation pré-release"
echo "============================================================"
if [ ${SANITIZERS_RC} -eq 0 ]; then
    echo "  ASan + UBSan        : OK"
elif [ ${SANITIZERS_RC} -eq ${BUILD_FAILURE_EXIT_CODE} ]; then
    echo "  ASan + UBSan        : ÉCHEC DE COMPILATION"
else
    echo "  ASan + UBSan        : ÉCHEC (code ${SANITIZERS_RC})"
fi

if [ ${NORMAL_SKIPPED} -eq 1 ]; then
    echo "  Build normal final  : IGNORÉ"
elif [ ${NORMAL_RC} -eq 0 ]; then
    echo "  Build normal final  : OK"
elif [ ${NORMAL_RC} -eq ${BUILD_FAILURE_EXIT_CODE} ]; then
    echo "  Build normal final  : ÉCHEC DE COMPILATION"
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
    && [ ${NORMAL_SKIPPED} -eq 0 ] \
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
