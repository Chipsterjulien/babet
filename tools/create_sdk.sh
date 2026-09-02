#!/bin/bash
# Create a relocatable static Babet developer SDK from Babet's in-tree runtime
# archive and all pinned third-party static archives.
set -euo pipefail

if [ "$#" -lt 4 ]; then
    echo "Usage: $0 <output-dir> <public-header> <runtime-archive> <dependency-archive>..." >&2
    exit 1
fi

OUTPUT_DIR="$1"
PUBLIC_HEADER="$2"
shift 2

if ! command -v ar >/dev/null 2>&1; then
    echo "ERREUR: ar est requis pour construire le SDK développeur." >&2
    exit 1
fi
if ! command -v ranlib >/dev/null 2>&1; then
    echo "ERREUR: ranlib est requis pour construire le SDK développeur." >&2
    exit 1
fi
if [ ! -f "${PUBLIC_HEADER}" ]; then
    echo "ERREUR: header public introuvable : ${PUBLIC_HEADER}" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/babet-sdk.XXXXXX")"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
mkdir -p "${WORK_DIR}/archives" "${WORK_DIR}/sdk/include/babet" "${WORK_DIR}/sdk/lib"

cp -- "${PUBLIC_HEADER}" "${WORK_DIR}/sdk/include/babet/babet.h"
PLUGIN_HEADER="$(dirname -- "${PUBLIC_HEADER}")/plugin.h"
if [ ! -f "${PLUGIN_HEADER}" ]; then
    echo "ERREUR: header plugin public introuvable : ${PLUGIN_HEADER}" >&2
    exit 1
fi
cp -- "${PLUGIN_HEADER}" "${WORK_DIR}/sdk/include/babet/plugin.h"

# Documentation and examples are part of the standalone developer experience.
# The builder lives under tools/, so resolve these from the source tree rather
# than from the caller's current working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
for DOC in ARCHITECTURE.md ARCHITECTURE.fr.md EMBEDDING.md EMBEDDING.fr.md EMBEDDING_DESIGN.md HOST_FUNCTIONS_DESIGN.md NATIVE_PLUGINS.md NATIVE_PLUGINS.fr.md NATIVE_PLUGIN_DESIGN.md; do
    if [ ! -f "${SOURCE_ROOT}/${DOC}" ]; then
        echo "ERREUR: documentation d'embedding introuvable : ${SOURCE_ROOT}/${DOC}" >&2
        exit 1
    fi
    cp -- "${SOURCE_ROOT}/${DOC}" "${WORK_DIR}/sdk/${DOC}"
done
if [ ! -d "${SOURCE_ROOT}/examples/embedding" ]; then
    echo "ERREUR: exemples d'embedding introuvables." >&2
    exit 1
fi
mkdir -p "${WORK_DIR}/sdk/examples"
cp -a -- "${SOURCE_ROOT}/examples/embedding" "${WORK_DIR}/sdk/examples/embedding"
if [ ! -d "${SOURCE_ROOT}/examples/native_plugin" ]; then
    echo "ERREUR: exemples de plugin natif introuvables." >&2
    exit 1
fi
cp -a -- "${SOURCE_ROOT}/examples/native_plugin" "${WORK_DIR}/sdk/examples/native_plugin"

# libbabet.a folds third-party static libraries into the redistributable SDK,
# so the SDK must carry Babet's licence and the bundled dependency notices.
for REDIST in LICENSE THIRD_PARTY_NOTICES.md; do
    if [ ! -f "${SOURCE_ROOT}/${REDIST}" ]; then
        echo "ERREUR: fichier de redistribution introuvable : ${SOURCE_ROOT}/${REDIST}" >&2
        exit 1
    fi
    cp -- "${SOURCE_ROOT}/${REDIST}" "${WORK_DIR}/sdk/${REDIST}"
done

# MRI `ar -M` does not have a portable quoting convention for archive names
# containing spaces. Stage every input under a numbered, space-free name first;
# this also makes generation deterministic regardless of the checkout path.
declare -A SEEN=()
INDEX=0
for ARCHIVE in "$@"; do
    if [ ! -f "${ARCHIVE}" ]; then
        echo "ERREUR: archive statique introuvable : ${ARCHIVE}" >&2
        exit 1
    fi
    CANONICAL="$(readlink -f -- "${ARCHIVE}")"
    if [ -n "${SEEN[${CANONICAL}]:-}" ]; then
        continue
    fi
    SEEN["${CANONICAL}"]=1
    STAGED="$(printf '%04d.a' "${INDEX}")"
    cp -- "${ARCHIVE}" "${WORK_DIR}/archives/${STAGED}"
    INDEX=$((INDEX + 1))
done

if [ "${INDEX}" -eq 0 ]; then
    echo "ERREUR: aucune archive fournie pour le SDK développeur." >&2
    exit 1
fi

(
    cd "${WORK_DIR}/archives"
    {
        echo "CREATE ../sdk/lib/libbabet.a"
        for ((I = 0; I < INDEX; ++I)); do
            printf 'ADDLIB %04d.a\n' "${I}"
        done
        echo "SAVE"
        echo "END"
    } | ar -M
)
ranlib "${WORK_DIR}/sdk/lib/libbabet.a"

cat > "${WORK_DIR}/sdk/README.txt" <<'EOF_README'
Babet static developer SDK
=======================================

Contents:
  include/babet/babet.h       public embedding/host-call C API
  include/babet/plugin.h      native plugin ABI v1 declarations
  lib/libbabet.a              Babet runtime + pinned static third-party libraries
  ARCHITECTURE.md/.fr.md      project architecture overview
  EMBEDDING.md                complete English embedding guide
  EMBEDDING.fr.md             complete French developer guide
  EMBEDDING_DESIGN.md         architectural embedding contract
  HOST_FUNCTIONS_DESIGN.md    Lua -> host callback contract
  NATIVE_PLUGINS.md/.fr.md    native plugin developer guides
  NATIVE_PLUGIN_DESIGN.md     native plugin ABI/loader contract
  examples/embedding/         executable C examples + CMake project
  examples/native_plugin/     standalone C/C++ plugin examples
  LICENSE                     Babet licence
  THIRD_PARTY_NOTICES.md      bundled dependency notices

Linux host build example:
  cc -std=c99 -I/path/to/sdk/include -c host.c -o host.o
  c++ host.o /path/to/sdk/lib/libbabet.a -ldl -pthread -lm -o host

Examples with CMake:
  cmake -S /path/to/sdk/examples/embedding -B build -DBABET_SDK_DIR=/path/to/sdk
  cmake --build build
  ctest --test-dir build --output-on-failure

Use a C++ linker driver for the final link because Babet itself is implemented
in C++. On 32-bit Linux targets, add -latomic. The SDK intentionally does not
provide a shared libbabet.so and the embedding ABI remains experimental.
See EMBEDDING.md or EMBEDDING.fr.md for lifecycle, scalar-value, host-function,
threading and Linux/glibc compatibility details.
EOF_README

PARENT_DIR="$(dirname -- "${OUTPUT_DIR}")"
mkdir -p "${PARENT_DIR}"
PUBLISH_DIR="${OUTPUT_DIR}.new.$$"
rm -rf -- "${PUBLISH_DIR}"
mv -- "${WORK_DIR}/sdk" "${PUBLISH_DIR}"
rm -rf -- "${OUTPUT_DIR}"
mv -- "${PUBLISH_DIR}" "${OUTPUT_DIR}"

trap - EXIT
rm -rf -- "${WORK_DIR}"
