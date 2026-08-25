#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
BUILD_ROOT="${ROOT}/build/fltk-prototype"
CACHE_DIR="${BUILD_ROOT}/cache"
SOURCE_DIR="${BUILD_ROOT}/fltk-source"
FLTK_BUILD_DIR="${BUILD_ROOT}/fltk-build"
PREFIX_DIR="${BUILD_ROOT}/fltk-prefix"

FLTK_VERSION="1.4.5"
FLTK_ARCHIVE="fltk-${FLTK_VERSION}-source.tar.gz"
FLTK_URL="https://github.com/fltk/fltk/releases/download/release-${FLTK_VERSION}/${FLTK_ARCHIVE}"
FLTK_SHA256="eede1fb2b8e9c2e581e77082e15252145855c79aad30070ee3b24aabe2f926f1"

mkdir -p "${CACHE_DIR}"
ARCHIVE_PATH="${CACHE_DIR}/${FLTK_ARCHIVE}"

sha_ok() {
    [[ -f "$1" ]] && printf '%s  %s\n' "${FLTK_SHA256}" "$1" | sha256sum -c - >/dev/null 2>&1
}

if ! sha_ok "${ARCHIVE_PATH}"; then
    rm -f "${ARCHIVE_PATH}"
    echo "Téléchargement de FLTK ${FLTK_VERSION} (prototype GUI optionnel)..."
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --proto '=https' --tlsv1.2 \
            --output "${ARCHIVE_PATH}.tmp" "${FLTK_URL}"
    elif command -v wget >/dev/null 2>&1; then
        wget --https-only --output-document="${ARCHIVE_PATH}.tmp" "${FLTK_URL}"
    else
        echo "Erreur : curl ou wget est nécessaire pour le bootstrap FLTK optionnel." >&2
        exit 2
    fi
    mv "${ARCHIVE_PATH}.tmp" "${ARCHIVE_PATH}"
    if ! sha_ok "${ARCHIVE_PATH}"; then
        rm -f "${ARCHIVE_PATH}"
        echo "Erreur : checksum SHA-256 FLTK ${FLTK_VERSION} incorrect." >&2
        exit 1
    fi
fi

echo "Checksum SHA-256 OK pour FLTK ${FLTK_VERSION}."

if [[ ! -f "${PREFIX_DIR}/.babet-fltk-${FLTK_VERSION}" ]]; then
    rm -rf "${SOURCE_DIR}" "${FLTK_BUILD_DIR}" "${PREFIX_DIR}"
    mkdir -p "${SOURCE_DIR}" "${FLTK_BUILD_DIR}" "${PREFIX_DIR}"
    tar -xzf "${ARCHIVE_PATH}" -C "${SOURCE_DIR}" --strip-components=1

    cmake -S "${SOURCE_DIR}" -B "${FLTK_BUILD_DIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${PREFIX_DIR}" \
        -DFLTK_BUILD_SHARED_LIBS=OFF \
        -DFLTK_BUILD_TEST=OFF \
        -DFLTK_BUILD_EXAMPLES=OFF \
        -DFLTK_BUILD_FLUID=OFF \
        -DFLTK_BUILD_FLTK_OPTIONS=OFF \
        -DFLTK_BUILD_FORMS=OFF \
        -DFLTK_BUILD_GL=OFF
    cmake --build "${FLTK_BUILD_DIR}" --parallel
    cmake --install "${FLTK_BUILD_DIR}"
    touch "${PREFIX_DIR}/.babet-fltk-${FLTK_VERSION}"
fi

CONFIG_PATH="$(find "${PREFIX_DIR}" -type f -name FLTKConfig.cmake -print -quit)"
if [[ -z "${CONFIG_PATH}" ]]; then
    echo "Erreur : FLTKConfig.cmake introuvable après installation." >&2
    exit 1
fi

echo "FLTK ${FLTK_VERSION} prêt dans ${PREFIX_DIR}"
printf '%s\n' "${PREFIX_DIR}"
