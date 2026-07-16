#!/bin/bash
# =====================================================================
# release.sh — automatise la fabrication d'une release Babet
# =====================================================================
#
# Ce que le script fait :
#   1. (optionnel) build via build_local.sh  --> --build
#   2. copie du binaire dans dist/
#   3. strip du binaire
#   4. sha256 du binaire strippé
#   5. tarball babet-<version>-linux-<arch>.tar.gz
#      (contient : babet, README, changelogs, licences et notes.md)
#   6. sha256 du tarball
#
# Sortie : tout dans le répertoire dist/ à la racine du projet.
# Ce dossier est ignoré par git (cf. .gitignore).
#
# Usage :
#   ./release.sh                  # utilise le binaire existant
#   ./release.sh --build          # rebuild d'abord (recommandé pour release)
#   ./release.sh --version 1.2.0  # définit explicitement la version
#   ./release.sh -h               # aide
#
# Si --version n'est pas fourni, le script utilise le dernier tag git
# (ex. "v1.2.0" -> "1.2.0"). En l'absence de tag, version = "unversioned".
# =====================================================================

set -euo pipefail

# --- Parsing des arguments -------------------------------------------
DO_BUILD=0
VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build)
            DO_BUILD=1
            shift
            ;;
        --version)
            if [[ $# -lt 2 ]]; then
                echo "ERREUR: --version exige un argument" >&2
                exit 1
            fi
            # Strip leading 'v' si présent : --version v1.3.4 -> 1.3.4
            # Cohérent avec la détection auto depuis git tag.
            VERSION="${2#v}"
            shift 2
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "ERREUR: argument inconnu '$1'" >&2
            echo "Voir $0 --help" >&2
            exit 1
            ;;
    esac
done

# --- Localisation projet ---------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT_NAME="babet"
BUILT_BINARY="${SCRIPT_DIR}/build/project_build/${PROJECT_NAME}"
DIST_DIR="${SCRIPT_DIR}/dist"

# --- Détection de l'architecture -------------------------------------
ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64) ARCH_TAG="linux-x86_64" ;;
    aarch64|arm64) ARCH_TAG="linux-aarch64" ;;
    *) ARCH_TAG="linux-${ARCH}" ;;
esac

# --- Détection de la version -----------------------------------------
if [[ -z "${VERSION}" ]]; then
    # Tentative : dernier tag git de la forme vX.Y.Z
    if command -v git &>/dev/null && [[ -d "${SCRIPT_DIR}/.git" ]]; then
        GIT_TAG="$(git -C "${SCRIPT_DIR}" describe --tags --abbrev=0 2>/dev/null || true)"
        if [[ -n "${GIT_TAG}" ]]; then
            # Strip leading 'v' si présent : "v1.2.0" -> "1.2.0"
            VERSION="${GIT_TAG#v}"
        fi
    fi
    if [[ -z "${VERSION}" ]]; then
        VERSION="unversioned"
    fi
fi

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERREUR: version invalide '${VERSION}' (format attendu: X.Y.Z)" >&2
    exit 1
fi

echo "=========================================="
echo "  Babet release builder"
echo "  Version : ${VERSION}"
echo "  Arch    : ${ARCH_TAG}"
echo "=========================================="
echo ""

# --- Vérification des outils requis ----------------------------------
for tool in sha256sum strip tar; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "ERREUR: '${tool}' introuvable dans PATH" >&2
        exit 1
    fi
done

# --- Étape 1 : build (optionnel) -------------------------------------
if [[ "${DO_BUILD}" -eq 1 ]]; then
    echo "[1/6] Build via build_local.sh..."
    if [[ ! -x "${SCRIPT_DIR}/build_local.sh" ]]; then
        echo "ERREUR: build_local.sh introuvable ou non exécutable" >&2
        exit 1
    fi
    bash "${SCRIPT_DIR}/build_local.sh"
    echo "      Build terminé."
else
    echo "[1/6] Skip build (utilise le binaire existant)."
fi

# --- Vérification du binaire ----------------------------------------
if [[ ! -f "${BUILT_BINARY}" ]]; then
    echo "ERREUR: binaire introuvable à ${BUILT_BINARY}" >&2
    echo "  Lance avec --build pour rebuild, ou exécute build_local.sh d'abord." >&2
    exit 1
fi

EXPECTED_VERSION_OUTPUT="${PROJECT_NAME} ${VERSION}"
ACTUAL_VERSION_OUTPUT="$("${BUILT_BINARY}" --version 2>/dev/null || true)"
if [[ "${ACTUAL_VERSION_OUTPUT}" != "${EXPECTED_VERSION_OUTPUT}" ]]; then
    echo "ERREUR: le binaire ne correspond pas à la version de release." >&2
    echo "  attendu : ${EXPECTED_VERSION_OUTPUT}" >&2
    echo "  obtenu  : ${ACTUAL_VERSION_OUTPUT:-<aucune sortie>}" >&2
    echo "  Recompile avec ./release.sh --build --version ${VERSION}." >&2
    exit 1
fi

# --- Préparation de dist/ -------------------------------------------
echo "[2/6] Préparation de dist/..."
rm -rf "${DIST_DIR}"
mkdir -p "${DIST_DIR}"

# Les licences de libarchive, zlib, XZ Utils/liblzma, bzip2/libbz2,
# Zstandard/libzstd, RE2 et Abseil imposent que leurs notices accompagnent toute
# distribution binaire. On les place également à la racine de dist/ pour le cas
# où le binaire seul est publié en dehors du tarball.
if [[ ! -f "${SCRIPT_DIR}/THIRD_PARTY_NOTICES.md" ]]; then
    echo "ERREUR: THIRD_PARTY_NOTICES.md introuvable à la racine" >&2
    exit 1
fi
cp "${SCRIPT_DIR}/THIRD_PARTY_NOTICES.md" "${DIST_DIR}/"

# Nom versionné du binaire pour la distribution hors tarball.
# Important : on inclut arch ET version pour qu'on puisse stocker
# côte à côte sur GitHub Releases plusieurs binaires (x86_64,
# aarch64, armv6l du RPi0...). Si on gardait juste "babet",
# le second upload écraserait le premier.
BINARY_NAME_VERSIONED="${PROJECT_NAME}-${VERSION}-${ARCH_TAG}"

# Copie du binaire dans dist/ sous son nom versionné.
cp "${BUILT_BINARY}" "${DIST_DIR}/${BINARY_NAME_VERSIONED}"
echo "      Binaire copié : dist/${BINARY_NAME_VERSIONED}"

# --- Étape 3 : strip ------------------------------------------------
echo "[3/6] Strip du binaire..."
SIZE_BEFORE=$(stat -c%s "${DIST_DIR}/${BINARY_NAME_VERSIONED}")
strip "${DIST_DIR}/${BINARY_NAME_VERSIONED}"
SIZE_AFTER=$(stat -c%s "${DIST_DIR}/${BINARY_NAME_VERSIONED}")
echo "      Taille : ${SIZE_BEFORE} -> ${SIZE_AFTER} octets"

# --- Étape 4 : sha256 du binaire ------------------------------------
echo "[4/6] Calcul SHA256 du binaire..."
BINARY_SHA256_FILE="${DIST_DIR}/${BINARY_NAME_VERSIONED}.sha256"

(cd "${DIST_DIR}" && sha256sum "${BINARY_NAME_VERSIONED}") \
    > "${BINARY_SHA256_FILE}"
echo "      SHA256 binaire : $(awk '{print $1}' "${BINARY_SHA256_FILE}")"

# --- Étape 5 : tarball ----------------------------------------------
echo "[5/6] Création du tarball..."
TARBALL_BASENAME="${PROJECT_NAME}-${VERSION}-${ARCH_TAG}"
TARBALL_FILE="${DIST_DIR}/${TARBALL_BASENAME}.tar.gz"

# Liste des fichiers à inclure. README.fr.md et notes.md sont
# optionnels (ne plantent pas le script s'ils manquent).
INCLUDE_FILES=("${PROJECT_NAME}")
[[ -f "${SCRIPT_DIR}/README.md" ]]    && INCLUDE_FILES+=("README.md")    || echo "      WARN: README.md absent" >&2
[[ -f "${SCRIPT_DIR}/README.fr.md" ]] && INCLUDE_FILES+=("README.fr.md")
[[ -f "${SCRIPT_DIR}/CHANGELOG.md" ]] && INCLUDE_FILES+=("CHANGELOG.md")
[[ -f "${SCRIPT_DIR}/CHANGELOG.fr.md" ]] && INCLUDE_FILES+=("CHANGELOG.fr.md")
[[ -f "${SCRIPT_DIR}/LICENSE" ]]      && INCLUDE_FILES+=("LICENSE")      || { echo "ERREUR: LICENSE introuvable à la racine" >&2 ; exit 1; }
[[ -f "${SCRIPT_DIR}/THIRD_PARTY_NOTICES.md" ]] && INCLUDE_FILES+=("THIRD_PARTY_NOTICES.md") || { echo "ERREUR: THIRD_PARTY_NOTICES.md introuvable à la racine" >&2 ; exit 1; }
[[ -f "${SCRIPT_DIR}/notes.md" ]]     && INCLUDE_FILES+=("notes.md")

# Stage : on copie les fichiers à inclure dans un sous-dossier nommé
# explicitement, pour que le tarball s'extraie en babet-X.Y.Z-arch/
#
# IMPORTANT : DANS le tarball, le binaire reprend le nom court
# "babet" (sans arch ni version). C'est plus ergonomique pour les
# scripts une fois l'archive extraite : on a "babet-X.Y.Z-arch/babet"
# qu'on peut appeler directement ou symlinker. L'arch+version reste
# visible au niveau du dossier d'extraction, ce qui suffit pour
# identifier de quelle release il vient.
#
# On stage dans un sous-dossier .stage/ pour éviter le conflit de nom
# avec le binaire seul qui s'appelle aussi
# ${PROJECT_NAME}-${VERSION}-${ARCH_TAG} (mais c'est un fichier, pas
# un dossier).
STAGE_PARENT="${DIST_DIR}/.stage"
STAGE_DIR="${STAGE_PARENT}/${TARBALL_BASENAME}"
mkdir -p "${STAGE_DIR}"
cp "${DIST_DIR}/${BINARY_NAME_VERSIONED}" "${STAGE_DIR}/${PROJECT_NAME}"
for f in "${INCLUDE_FILES[@]:1}"; do
    cp "${SCRIPT_DIR}/${f}" "${STAGE_DIR}/"
done

# Création du tarball depuis le parent du stage (pour que les chemins
# dans l'archive soient bien babet-X.Y.Z-arch/... et pas
# .stage/babet-X.Y.Z-arch/...)
(cd "${STAGE_PARENT}" && tar -czf "${TARBALL_FILE}" "${TARBALL_BASENAME}")

# Nettoyage du stage.
rm -rf "${STAGE_PARENT}"

echo "      Tarball : $(basename "${TARBALL_FILE}")"
echo "      Contenu :"
tar -tzf "${TARBALL_FILE}" | sed 's/^/        /'

# --- Étape 6 : sha256 du tarball ------------------------------------
echo "[6/6] Calcul SHA256 du tarball..."
TARBALL_SHA256_FILE="${TARBALL_FILE}.sha256"
(cd "${DIST_DIR}" && sha256sum "${TARBALL_BASENAME}.tar.gz") > "${TARBALL_SHA256_FILE}"
echo "      SHA256 tarball : $(awk '{print $1}' "${TARBALL_SHA256_FILE}")"

# --- Résumé ---------------------------------------------------------
echo ""
echo "=========================================="
echo "  RELEASE PRÊTE dans dist/"
echo "=========================================="
ls -lh "${DIST_DIR}/" | awk 'NR>1 {printf "  %s  %s\n", $5, $9}'
echo ""
echo "Tu peux maintenant uploader ces fichiers sur la page Releases GitHub :"
echo "  - $(basename "${TARBALL_FILE}")"
echo "  - $(basename "${TARBALL_SHA256_FILE}")"
echo ""
echo "Le binaire seul et son sha256 sont aussi dans dist/ si tu veux les"
echo "distribuer séparément :"
echo "  - ${BINARY_NAME_VERSIONED}"
echo "  - $(basename "${BINARY_SHA256_FILE}")"
echo ""
