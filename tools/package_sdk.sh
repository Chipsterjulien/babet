#!/bin/bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "Usage: $0 <sdk-dir> <dist-dir> <project> <version> <arch-tag>" >&2
    exit 1
fi

SDK_DIR="$1"
DIST_DIR="$2"
PROJECT="$3"
VERSION="$4"
ARCH_TAG="$5"

for tool in tar sha256sum ar; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        echo "ERREUR: '${tool}' introuvable dans PATH" >&2
        exit 1
    fi
done

if [[ ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERREUR: version invalide '${VERSION}'." >&2
    exit 1
fi
if [[ ! "${ARCH_TAG}" =~ ^linux-[A-Za-z0-9._+-]+$ ]]; then
    echo "ERREUR: tag d'architecture invalide '${ARCH_TAG}'." >&2
    exit 1
fi

REQUIRED_FILES=(
    "include/babet/babet.h"
    "include/babet/plugin.h"
    "lib/libbabet.a"
    "README.txt"
    "LICENSE"
    "THIRD_PARTY_NOTICES.md"
)
for rel in "${REQUIRED_FILES[@]}"; do
    if [[ ! -f "${SDK_DIR}/${rel}" ]]; then
        echo "ERREUR: SDK développeur incomplet, fichier manquant : ${rel}" >&2
        exit 1
    fi
done

BASENAME="${PROJECT}-${VERSION}-${ARCH_TAG}-sdk"
TARBALL="${DIST_DIR}/${BASENAME}.tar.gz"
SHA_FILE="${TARBALL}.sha256"

mkdir -p "${DIST_DIR}"
DIST_DIR="$(cd "${DIST_DIR}" && pwd)"
if ! ar t "${SDK_DIR}/lib/libbabet.a" >/dev/null 2>&1; then
    echo "ERREUR: SDK développeur invalide : lib/libbabet.a n'est pas une archive statique lisible." >&2
    exit 1
fi
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/babet-release-sdk.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/${BASENAME}"
cp -a -- "${SDK_DIR}/." "${WORK_DIR}/${BASENAME}/"

(
    cd "${WORK_DIR}"
    tar -czf "${TARBALL}" "${BASENAME}"
)
(
    cd "${DIST_DIR}"
    sha256sum "${BASENAME}.tar.gz" > "${BASENAME}.tar.gz.sha256"
)

printf '%s\n' "${TARBALL}"
printf '%s\n' "${SHA_FILE}"
