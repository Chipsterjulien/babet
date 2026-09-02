#!/bin/bash
# validate_release.sh — validation complète avant publication.
#
# Enchaîne automatiquement :
#   1. build + tests sanitizers adaptés à l'architecture native ;
#   2. restauration du build normal + tests complets ;
#   3. smoke tests réseau avec le binaire normal final.
#
# Politique sanitizer de release :
#   - x86_64/aarch64 et autres hôtes pris en charge : ASan + UBSan ;
#   - linux-armhf (armv6l/armv7l/armhf) : UBSan seul.
#
# Le mode UBSan-only armhf est volontaire et explicite. Sur le builder ARMv6
# de référence, le runtime GCC 12 ASan échoue avant main() même pour un programme
# C minimal (diagnostic d'ordre du runtime en dynamique, puis SIGSEGV avec les
# contournements preload/statique), tandis que libatomic et UBSan minimaux passent.
# La campagne ne présente donc jamais cette architecture comme validée par ASan.
#
# Un échec de compilation est distingué des autres échecs par run_tests.sh.
# Il interrompt immédiatement la campagne : relancer le même code dans le
# second mode ne fournirait aucune information supplémentaire. En revanche,
# un échec de test sous sanitizers laisse encore le build normal s'exécuter,
# afin de restaurer le binaire final et de compléter le diagnostic.
#
# Le réseau est volontairement testé APRES la restauration du build normal :
# les sanitizers servent à détecter les erreurs mémoire/UB, mais peuvent modifier
# les timings et les interpositions système. Le smoke test valide le binaire
# réellement destiné à la release.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_FAILURE_EXIT_CODE=2
SANITIZERS_RC=1
NORMAL_RC=1
NETWORK_RC=1
NORMAL_SKIPPED=0
NETWORK_SKIPPED=0

# BABET_VALIDATE_ARCH est un hook mainteneur/test hermétique. En usage normal,
# la sélection repose exclusivement sur l'architecture native.
VALIDATE_ARCH="${BABET_VALIDATE_ARCH:-$(uname -m)}"
case "${VALIDATE_ARCH}" in
    armv6l|armv7l|armhf)
        SANITIZER_ARG="--ubsan"
        SANITIZER_LABEL="UBSan (linux-armhf)"
        ;;
    *)
        SANITIZER_ARG="--sanitizers"
        SANITIZER_LABEL="ASan + UBSan"
        ;;
esac

print_stage() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

print_stage "Étape 1/3 — ${SANITIZER_LABEL}"
if [ "${SANITIZER_ARG}" = "--ubsan" ]; then
    echo "INFO: politique linux-armhf : ASan non revendiqué ; validation UBSan seule."
fi
bash "${SCRIPT_DIR}/run_tests.sh" "${SANITIZER_ARG}"
SANITIZERS_RC=$?

if [ ${SANITIZERS_RC} -eq ${BUILD_FAILURE_EXIT_CODE} ]; then
    NORMAL_SKIPPED=1
    NETWORK_SKIPPED=1
    echo
    echo "Étape 2/3 — build normal : IGNORÉ"
    echo "La compilation ${SANITIZER_LABEL} a échoué ; la campagne est arrêtée."
    echo
    echo "Étape 3/3 — smoke tests réseau : IGNORÉS"
    echo "Aucun binaire normal final validé n'est disponible."
else
    print_stage "Étape 2/3 — restauration et validation du build normal"
    bash "${SCRIPT_DIR}/run_tests.sh"
    NORMAL_RC=$?

    if [ ${NORMAL_RC} -eq 0 ]; then
        print_stage "Étape 3/3 — smoke tests réseau (binaire normal)"
        NETWORK_BINARY="${BABET_TEST_PREBUILT_BINARY_NORMAL:-${SCRIPT_DIR}/test/babet}"
        bash "${SCRIPT_DIR}/smoke_test_network.sh" "${NETWORK_BINARY}"
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
    echo "  ${SANITIZER_LABEL} : OK"
elif [ ${SANITIZERS_RC} -eq ${BUILD_FAILURE_EXIT_CODE} ]; then
    echo "  ${SANITIZER_LABEL} : ÉCHEC DE COMPILATION"
else
    echo "  ${SANITIZER_LABEL} : ÉCHEC (code ${SANITIZERS_RC})"
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
