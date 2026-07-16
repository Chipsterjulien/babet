#!/bin/bash

# Arrêt au premier échec : si un wget/cmake/make foire silencieusement,
# on ne veut pas continuer à compiler avec un état corrompu. Les commandes
# critiques sont déjà testées explicitement avec `if !`, mais set -e fait
# office de filet de sécurité pour celles qu'on aurait oubliées.
set -e

# Parsing des arguments
RUN_AFTER_BUILD=0
ENABLE_SANITIZERS=0

for arg in "$@"; do
    case "$arg" in
        --run)
            RUN_AFTER_BUILD=1
            ;;
        --sanitizers)
            ENABLE_SANITIZERS=1
            ;;
        --help|-h)
            echo "Usage: $0 [--run] [--sanitizers]"
            echo "  (par défaut)   Compile uniquement"
            echo "  --run          Compile puis exécute le binaire sur test/"
            echo "  --sanitizers   Compile avec ASan + UBSan (GCC/Clang)"
            exit 0
            ;;
        *)
            echo "Argument inconnu : $arg"
            echo "Voir $0 --help"
            exit 1
            ;;
    esac
done

# Vérifier si CMake est installé
if ! command -v cmake &> /dev/null; then
    echo "CMake n'est pas installé. Veuillez l'installer avant de continuer."
    exit 1
fi

# RE2 2025-11-05 et le CMakeLists.txt de Babet requièrent CMake 3.22.
# build_local.sh refuse explicitement une version trop ancienne avant tout
# téléchargement ou compilation.
CMAKE_VERSION="$(cmake --version | awk 'NR == 1 { print $3 }')"
CMAKE_MIN_LOCAL_DEPS="3.22.0"
if [ -z "${CMAKE_VERSION}" ] || \
   [ "$(printf '%s\n' "${CMAKE_MIN_LOCAL_DEPS}" "${CMAKE_VERSION}" | sort -V | head -n 1)" != "${CMAKE_MIN_LOCAL_DEPS}" ]; then
    echo "CMake ${CMAKE_MIN_LOCAL_DEPS} ou plus récent est requis pour RE2 2025-11-05 et les dépendances locales de Babet."
    echo "Version détectée : ${CMAKE_VERSION:-inconnue}"
    exit 1
fi

# Vérifier si wget est installé
if ! command -v wget &> /dev/null; then
    echo "wget n'est pas installé. Veuillez l'installer avant de continuer."
    exit 1
fi

# Vérifier que xargs est installé
if ! command -v xargs &> /dev/null; then
    echo "xargs n'est pas installé. Veuillez l'installer avant de continuer."
    exit 1
fi

# Vérifier que unzip est installé
if ! command -v unzip &> /dev/null; then
    echo "unzip n'est pas installé. Veuillez l'installer avant de continuer."
    exit 1
fi

# Le tarball officiel de libarchive est distribué en .tar.xz.
if ! command -v xz &> /dev/null; then
    echo "xz n'est pas installé. Installez xz/xz-utils avant de continuer."
    exit 1
fi

# --- Vérification d'intégrité des dépendances téléchargées ---------
# Chaîne d'approvisionnement : tout artefact distant est vérifié contre
# un SHA256 épinglé AVANT d'être utilisé. Comportement strict :
#   - hash non renseigné  -> build refusé (exit 1). Un checksum
#     optionnel n'est pas un checksum : le jour d'un bump de version
#     où on oublie de recalculer, on veut un échec, pas un trou muet.
#   - hash ne correspond pas -> fichier suspect supprimé + exit 1.
#     Pas de fallback, pas de "on continue quand même".
# La vérification s'applique AUSSI aux fichiers déjà en cache dans
# downloads/ : un cache empoisonné doit être détecté, sinon le
# mécanisme ne sert à rien.
verify_sha256() {
    local file="$1"
    local expected="$2"
    local name="$3"

    if [ -z "${expected}" ]; then
        echo "ERREUR: checksum SHA256 non renseigné pour ${name}."
        echo "  Build refusé tant que la variable ${name}_SHA256 est vide."
        echo "  Calcule le hash depuis la source OFFICIELLE (voir le"
        echo "  commentaire au-dessus de la variable) puis renseigne-le."
        exit 1
    fi

    if [ ! -f "${file}" ]; then
        echo "ERREUR: fichier introuvable pour vérification (${name}): ${file}"
        exit 1
    fi

    local actual=""
    if command -v sha256sum &> /dev/null; then
        actual="$(sha256sum "${file}" | awk '{print $1}')"
    elif command -v shasum &> /dev/null; then
        actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
    else
        echo "ERREUR: ni sha256sum ni shasum -a 256 disponibles."
        echo "  Impossible de vérifier l'intégrité de ${name}."
        exit 1
    fi

    if [ "${actual}" != "${expected}" ]; then
        echo "ERREUR: checksum SHA256 invalide pour ${name}."
        echo "  attendu : ${expected}"
        echo "  obtenu  : ${actual}"
        echo "  Fichier supprimé (suspect) : ${file}"
        rm -f "${file}"
        exit 1
    fi

    echo "Checksum SHA256 OK pour ${name}."
}

# --- Empreinte du code source du projet ------------------------------
#
# CMake/Make se basent normalement sur les dates de modification. Lorsqu'un
# lot est copié depuis une archive ZIP par-dessus un arbre déjà compilé, les
# dates historiques conservées par ZIP peuvent toutefois rendre un nouveau
# fichier source artificiellement plus ancien que son ancien .o. Le build
# incrémental réutiliserait alors un objet obsolète malgré un contenu modifié.
#
# On calcule donc une empreinte du contenu et des noms de tous les fichiers de
# src/ ainsi que de CMakeLists.txt. Si elle diffère de celle du dernier build
# réussi (ou si le cache est antérieur à ce mécanisme), seul le build CMake de
# Babet est nettoyé. Les dépendances coûteuses restent en cache.
compute_project_sources_sha256() {
    local hash_cmd=()
    if command -v sha256sum &> /dev/null; then
        hash_cmd=(sha256sum)
    elif command -v shasum &> /dev/null; then
        hash_cmd=(shasum -a 256)
    else
        echo "ERREUR: ni sha256sum ni shasum -a 256 disponibles." >&2
        return 1
    fi

    local manifest
    manifest="$(mktemp)" || return 1

    local file
    local file_hash
    while IFS= read -r -d '' file; do
        if ! file_hash="$("${hash_cmd[@]}" "${SCRIPT_DIR}/${file}" | awk '{print $1}')"; then
            rm -f "${manifest}"
            return 1
        fi
        if ! printf '%s  %s\n' "${file_hash}" "${file}" >> "${manifest}"; then
            rm -f "${manifest}"
            return 1
        fi
    done < <(
        cd "${SCRIPT_DIR}" || exit 1
        {
            printf '%s\0' "CMakeLists.txt"
            find src -type f -print0
        } | sort -z
    )

    local project_hash
    if ! project_hash="$("${hash_cmd[@]}" "${manifest}" | awk '{print $1}')"; then
        rm -f "${manifest}"
        return 1
    fi
    rm -f "${manifest}"
    printf '%s\n' "${project_hash}"
}

# --- Téléchargement avec fallback ----------------------------------
# Certains sites amont (notamment lua.org) ont des indisponibilités
# récurrentes. Cette fonction essaie une liste d'URLs dans l'ordre et
# s'arrête à la première qui marche.
#
# La 2e URL est typiquement web.archive.org (Wayback Machine), qui
# archive les tarballs publics et redistribue le binaire raw via
# le suffixe `id_` (sans la barre de navigation Wayback).
#
# Sécurité : le SHA256 reste vérifié APRÈS le téléchargement par
# verify_sha256(). Donc même si une archive distante servait un
# fichier altéré ou un tarball différent (ex: même chemin mais
# release amont qui a re-uploadé sans bump de version), la
# divergence serait détectée et le build refusé.
#
# Cas non couvert : tous les serveurs distants sont down simultanément.
# Dans ce cas, place le tarball à la main dans downloads/<file> avant
# de relancer le script — il sera vérifié SHA256 sans être retéléchargé.
download_with_fallback() {
    local dest="$1" ; shift
    local name="$1" ; shift
    # Le reste des arguments est la liste d'URLs à essayer dans l'ordre.
    local i=1
    local total=$#
    for url in "$@"; do
        if [ "${total}" -gt 1 ]; then
            echo "Téléchargement de ${name} (source ${i}/${total})..."
        else
            echo "Téléchargement de ${name}..."
        fi
        # --tries=2 : un retry pour tolérer un blip réseau, mais sans
        # bloquer trop longtemps sur une URL morte.
        # --timeout=30 : limite la durée d'attente par tentative.
        if wget --tries=2 --timeout=30 "${url}" -O "${dest}"; then
            return 0
        fi
        echo "  -> échec sur ${url}"
        rm -f "${dest}"
        i=$((i+1))
    done
    return 1
}

# Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"
#
if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
    PROJECT_BUILD_DIR="${BUILD_DIR}/project_build_sanitizers"
    CMAKE_SANITIZERS="ON"
else
    PROJECT_BUILD_DIR="${BUILD_DIR}/project_build"
    CMAKE_SANITIZERS="OFF"
fi
PROJECT_NAME="babet"
#
# LUA_VERSION="5.4.7"
LUA_VERSION="5.5.0"
LUA_DIR="lua-$LUA_VERSION"
LUA_TAR="$LUA_DIR.tar.gz"
LUA_BUILD_DIR="${BUILD_DIR}/lua_build"
LUA_URL="https://www.lua.org/ftp/$LUA_TAR"
# Sources alternatives pour Lua (lua.org a connu plusieurs
# indisponibilités récentes). Wayback Machine archive le tarball
# binaire et le SHA256 est revérifié après téléchargement.
LUA_URLS=(
    "${LUA_URL}"
    "https://web.archive.org/web/2025id_/${LUA_URL}"
)
# Pour renseigner LUA_SHA256, calcule le hash depuis la source
# officielle (laisse vide = build refusé) :
#   wget -qO- https://www.lua.org/ftp/lua-5.5.0.tar.gz | sha256sum
LUA_SHA256="57ccc32bbbd005cab75bcc52444052535af691789dba2b9016d5c50640d68b3d"
LUA_LIB_NAME="liblua.a"
LUA_LIB="${LUA_BUILD_DIR}/${LUA_DIR}/src/${LUA_LIB_NAME}"
LUA_INCLUDE="${LUA_BUILD_DIR}/${LUA_DIR}/src"
#
# OPENSSL_VERSION="3.3.1"
OPENSSL_VERSION="3.5.6"
OPENSSL_DIR="openssl-${OPENSSL_VERSION}"
OPENSSL_TAR="${OPENSSL_DIR}.tar.gz"
OPENSSL_BUILD_DIR="${BUILD_DIR}/openssl"
# Dépendance crypto : la plus critique à vérifier. Calcule :
#   wget -qO- https://www.openssl.org/source/openssl-3.5.6.tar.gz | sha256sum
# et recoupe avec le hash publié officiellement par le projet :
#   wget -qO- https://www.openssl.org/source/openssl-3.5.6.tar.gz.sha256
OPENSSL_SHA256="deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736"
OPENSSL_URL="https://www.openssl.org/source/${OPENSSL_TAR}"
# Sources alternatives pour OpenSSL (Wayback en filet, comme Lua).
OPENSSL_URLS=(
    "${OPENSSL_URL}"
    "https://web.archive.org/web/2025id_/${OPENSSL_URL}"
)
#
MINIZ_VERSION="3.1.2"
MINIZ_DIR="miniz-${MINIZ_VERSION}"
MINIZ_ZIP="${MINIZ_DIR}.zip"
MINIZ_URL="https://github.com/richgel999/miniz/releases/download/${MINIZ_VERSION}/${MINIZ_ZIP}"
# Calcule :
#   wget -qO- https://github.com/richgel999/miniz/releases/download/3.1.2/miniz-3.1.2.zip | sha256sum
MINIZ_SHA256="f0446d863f9c19926ad9483c523fdc42e42b8d4a6a431d27e09d49c79a140d9a"
MINIZ_BUILD_DIR="${BUILD_DIR}/miniz"
MINIZ_INSTALL_DIR="${MINIZ_BUILD_DIR}/${MINIZ_DIR}"
MINIZ_C="${MINIZ_INSTALL_DIR}/miniz.c"
MINIZ_H="${MINIZ_INSTALL_DIR}/miniz.h"
#
# zlib : backend gzip épinglé pour libarchive. La distribution officielle
# est construite statiquement et installée dans build/zlib/install afin de ne
# pas dépendre de la version fournie par la distribution Linux.
ZLIB_VERSION="1.3.2"
ZLIB_DIR="zlib-${ZLIB_VERSION}"
ZLIB_TAR="${ZLIB_DIR}.tar.gz"
ZLIB_URLS=(
    "https://zlib.net/${ZLIB_TAR}"
    "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/${ZLIB_TAR}"
)
# Hash publié sur la page officielle zlib :
#   https://zlib.net/
ZLIB_SHA256="bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
ZLIB_ROOT="${BUILD_DIR}/zlib"
ZLIB_SOURCE_DIR="${ZLIB_ROOT}/${ZLIB_DIR}"
ZLIB_CMAKE_BUILD_DIR="${ZLIB_ROOT}/cmake-build"
ZLIB_INSTALL_DIR="${ZLIB_ROOT}/install"
ZLIB_LIB="${ZLIB_INSTALL_DIR}/lib/libz.a"
ZLIB_INCLUDE="${ZLIB_INSTALL_DIR}/include"
#
# XZ Utils / liblzma : backend xz épinglé pour libarchive. La version 5.8.3
# corrige notamment CVE-2026-34743. Seule la bibliothèque statique liblzma
# est construite et installée localement ; aucun outil xz amont n'est lié à
# Babet.
XZ_VERSION="5.8.3"
XZ_DIR="xz-${XZ_VERSION}"
XZ_TAR="${XZ_DIR}.tar.xz"
XZ_URLS=(
    "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/${XZ_TAR}"
    "https://sourceforge.net/projects/lzmautils/files/${XZ_TAR}/download"
)
XZ_SHA256="fff1ffcf2b0da84d308a14de513a1aa23d4e9aa3464d17e64b9714bfdd0bbfb6"
XZ_ROOT="${BUILD_DIR}/xz"
XZ_SOURCE_DIR="${XZ_ROOT}/${XZ_DIR}"
XZ_CMAKE_BUILD_DIR="${XZ_ROOT}/cmake-build"
XZ_INSTALL_DIR="${XZ_ROOT}/install"
XZ_LIB="${XZ_INSTALL_DIR}/lib/liblzma.a"
XZ_INCLUDE="${XZ_INSTALL_DIR}/include"
#
# bzip2 / libbz2 : backend bzip2 épinglé pour libarchive. Le projet amont
# 1.0.x utilise un Makefile classique ; seule la bibliothèque statique
# libbz2.a est compilée avec -fPIC, puis le header public est copié dans une
# installation locale contrôlée par Babet.
BZIP2_VERSION="1.0.8"
BZIP2_DIR="bzip2-${BZIP2_VERSION}"
BZIP2_TAR="${BZIP2_DIR}.tar.gz"
BZIP2_URLS=(
    "https://sourceware.org/pub/bzip2/${BZIP2_TAR}"
    "https://ftp.funet.fi/pub/mirrors/sourceware.org/pub/bzip2/${BZIP2_TAR}"
)
BZIP2_SHA256="ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"
BZIP2_ROOT="${BUILD_DIR}/bzip2"
BZIP2_SOURCE_DIR="${BZIP2_ROOT}/${BZIP2_DIR}"
BZIP2_INSTALL_DIR="${BZIP2_ROOT}/install"
BZIP2_LIB="${BZIP2_INSTALL_DIR}/lib/libbz2.a"
BZIP2_INCLUDE="${BZIP2_INSTALL_DIR}/include"
#
# Zstandard / libzstd : backend zstd épinglé pour libarchive. Seule la
# bibliothèque statique est construite localement, sans programmes, tests,
# compatibilité legacy ni support multithread. La désactivation du
# multithread conserve un profil de ressources borné et des sorties
# déterministes sur toutes les machines.
ZSTD_VERSION="1.5.7"
ZSTD_DIR="zstd-${ZSTD_VERSION}"
ZSTD_TAR="${ZSTD_DIR}.tar.gz"
ZSTD_URLS=(
    "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/${ZSTD_TAR}"
    "https://sourceforge.net/projects/zstandard.mirror/files/v${ZSTD_VERSION}/${ZSTD_TAR}/download"
)
ZSTD_SHA256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"
ZSTD_ROOT="${BUILD_DIR}/zstd"
ZSTD_SOURCE_DIR="${ZSTD_ROOT}/${ZSTD_DIR}"
ZSTD_CMAKE_BUILD_DIR="${ZSTD_ROOT}/cmake-build"
ZSTD_INSTALL_DIR="${ZSTD_ROOT}/install"
ZSTD_LIB="${ZSTD_INSTALL_DIR}/lib/libzstd.a"
ZSTD_INCLUDE="${ZSTD_INSTALL_DIR}/include"
#
# Abseil : dépendance C++ transitive de RE2. La version 20250814.2 est le
# dernier correctif de la branche LTS d’août 2025, choisie pour rester dans la
# même ligne de compatibilité que RE2 2025-11-05 tout en intégrant son dernier
# patch de maintenance. Elle est compilée localement en statique, sans tests.
ABSL_VERSION="20250814.2"
ABSL_DIR="abseil-cpp-${ABSL_VERSION}"
ABSL_TAR="${ABSL_DIR}.tar.gz"
ABSL_URLS=(
    "https://github.com/abseil/abseil-cpp/releases/download/${ABSL_VERSION}/${ABSL_TAR}"
)
ABSL_SHA256="f9148fb00ec98a2396bdf875c99a78e6a70afa662b107862d92b285d857a8320"
ABSL_ROOT="${BUILD_DIR}/abseil"
ABSL_SOURCE_DIR="${ABSL_ROOT}/${ABSL_DIR}"
ABSL_CMAKE_BUILD_DIR="${ABSL_ROOT}/cmake-build"
ABSL_INSTALL_DIR="${ABSL_ROOT}/install"
ABSL_CMAKE_DIR="${ABSL_INSTALL_DIR}/lib/cmake/absl"
ABSL_PROFILE_FILE="${ABSL_CMAKE_BUILD_DIR}/.babet-build-profile"
ABSL_BUILD_PROFILE="abseil=${ABSL_VERSION};cxx=17;shared=OFF;tests=OFF;install=ON"
#
# RE2 : remplace std::regex dans babet.find(). Le moteur garantit un temps
# linéaire et borne sa mémoire ; ICU, tests et benchmarks sont désactivés.
RE2_VERSION="2025-11-05"
RE2_DIR="re2-${RE2_VERSION}"
RE2_TAR="${RE2_DIR}.tar.gz"
RE2_URLS=(
    "https://github.com/google/re2/releases/download/${RE2_VERSION}/${RE2_TAR}"
)
RE2_SHA256="87f6029d2f6de8aa023654240a03ada90e876ce9a4676e258dd01ea4c26ffd67"
RE2_ROOT="${BUILD_DIR}/re2"
RE2_SOURCE_DIR="${RE2_ROOT}/${RE2_DIR}"
RE2_CMAKE_BUILD_DIR="${RE2_ROOT}/cmake-build"
RE2_INSTALL_DIR="${RE2_ROOT}/install"
RE2_LIB="${RE2_INSTALL_DIR}/lib/libre2.a"
RE2_INCLUDE="${RE2_INSTALL_DIR}/include"
RE2_CMAKE_DIR="${RE2_INSTALL_DIR}/lib/cmake/re2"
RE2_PROFILE_FILE="${RE2_CMAKE_BUILD_DIR}/.babet-build-profile"
RE2_BUILD_PROFILE="re2=${RE2_VERSION};abseil=${ABSL_VERSION};icu=OFF;shared=OFF;tests=OFF"
#
# libarchive : backend multi-format de la 2.6.0. Il est compilé avec les
# filtres gzip, xz, bzip2 et zstd internes, adossés respectivement aux
# versions statiques de zlib, liblzma, libbz2 et libzstd ci-dessus.
LIBARCHIVE_VERSION="3.8.8"
LIBARCHIVE_DIR="libarchive-${LIBARCHIVE_VERSION}"
LIBARCHIVE_TAR="${LIBARCHIVE_DIR}.tar.xz"
LIBARCHIVE_URL="https://www.libarchive.org/downloads/${LIBARCHIVE_TAR}"
# Calcule depuis la distribution officielle :
#   wget -qO- https://www.libarchive.org/downloads/libarchive-3.8.8.tar.xz | sha256sum
LIBARCHIVE_SHA256="3873a88801da067d0528a989af06877710529d50ee8fe6f3970cbb4302efb918"
LIBARCHIVE_ROOT="${BUILD_DIR}/libarchive"
LIBARCHIVE_SOURCE_DIR="${LIBARCHIVE_ROOT}/${LIBARCHIVE_DIR}"
LIBARCHIVE_CMAKE_BUILD_DIR="${LIBARCHIVE_ROOT}/cmake-build"
LIBARCHIVE_LIB="${LIBARCHIVE_CMAKE_BUILD_DIR}/libarchive/libarchive.a"
LIBARCHIVE_INCLUDE="${LIBARCHIVE_SOURCE_DIR}/libarchive"
LIBARCHIVE_PROFILE_FILE="${LIBARCHIVE_CMAKE_BUILD_DIR}/.babet-build-profile"
LIBARCHIVE_BUILD_PROFILE="libarchive=${LIBARCHIVE_VERSION};zlib=${ZLIB_VERSION};gzip=ON;xz=${XZ_VERSION};lzma=ON;bzip2=${BZIP2_VERSION};bz2=ON;zstd=${ZSTD_VERSION};zstd_filter=ON"
#
# nlohmann/json : header-only, un seul fichier json.hpp téléchargé
# depuis les releases GitHub. Version épinglée comme pour miniz ; pour
# en changer, il suffit de bumper JSON_VERSION.
JSON_VERSION="3.11.3"
JSON_DIR="json-${JSON_VERSION}"
JSON_HEADER="json.hpp"
JSON_URL="https://github.com/nlohmann/json/releases/download/v${JSON_VERSION}/json.hpp"
# Calcule :
#   wget -qO- https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp | sha256sum
JSON_SHA256="9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6"
JSON_BUILD_DIR="${BUILD_DIR}/json"
JSON_INSTALL_DIR="${JSON_BUILD_DIR}/${JSON_DIR}"
# On place le header sous un sous-dossier nlohmann/ pour que
# #include <nlohmann/json.hpp> fonctionne avec JSON_INSTALL_DIR seul
# ajouté aux include paths.
JSON_INCLUDE_FILE="${JSON_INSTALL_DIR}/nlohmann/json.hpp"
# cpp-httplib : header-only, un seul fichier httplib.h téléchargé
# depuis le tag de release GitHub (raw). Même mécanique que
# nlohmann/json. TLS : CPPHTTPLIB_OPENSSL_SUPPORT est défini dans le
# SEUL .cpp qui inclut httplib.h (src/lua_bindings/http.cpp), pas ici,
# pour garder la macro locale ; on réutilise libssl/libcrypto déjà
# liés (OpenSSL 3.x, requis par cpp-httplib >= 3.0). Aucune nouvelle
# dépendance TLS.
#
# IMPORTANT : on épingle un TAG DE RELEASE réel (pas master). Le
# CPPHTTPLIB_VERSION du header peut précéder le tag publié ; en cas de
# doute, vérifier que le tag v${HTTPLIB_VERSION} existe bien dans
# https://github.com/yhirose/cpp-httplib/releases . Le checksum ne
# peut être stable que sur un tag figé.
HTTPLIB_VERSION="0.45.0"
HTTPLIB_DIR="cpp-httplib-${HTTPLIB_VERSION}"
HTTPLIB_HEADER="httplib.h"
HTTPLIB_URL="https://raw.githubusercontent.com/yhirose/cpp-httplib/v${HTTPLIB_VERSION}/httplib.h"
# Checksum OBLIGATOIRE (build refusé tant qu'il est vide, comme les
# autres deps). Calcule-le depuis la source OFFICIELLE :
#   wget -qO- https://raw.githubusercontent.com/yhirose/cpp-httplib/v0.45.0/httplib.h | sha256sum
HTTPLIB_SHA256="fdb5586b7bb9abbc21d1a6ccce6caf891e26895c5bb2461596ad993df097cbbb"
HTTPLIB_BUILD_DIR="${BUILD_DIR}/httplib"
HTTPLIB_INSTALL_DIR="${HTTPLIB_BUILD_DIR}/${HTTPLIB_DIR}"
# Header posé à plat dans HTTPLIB_INSTALL_DIR : #include <httplib.h>
# fonctionne avec ce seul dossier ajouté aux include paths.
HTTPLIB_INCLUDE_FILE="${HTTPLIB_INSTALL_DIR}/httplib.h"
#
# toml++ : header-only, single-file (toml.hpp amalgamé à la racine du
# repo). Même mécanique que nlohmann/json — on télécharge le seul
# fichier toml.hpp depuis un tag de release GitHub et on le pose sous
# un sous-dossier toml++/ pour que `#include <toml++/toml.hpp>`
# (include canonique communauté) fonctionne avec TOMLPP_INSTALL_DIR
# seul ajouté aux include paths. C++17 minimum (le projet est en
# C++23, donc OK). Pas de TLS, pas de threads, zéro dépendance.
TOMLPP_VERSION="3.4.0"
TOMLPP_DIR="tomlplusplus-${TOMLPP_VERSION}"
TOMLPP_HEADER="toml.hpp"
TOMLPP_URL="https://raw.githubusercontent.com/marzer/tomlplusplus/v${TOMLPP_VERSION}/toml.hpp"
# Checksum OBLIGATOIRE (build refusé tant qu'il est vide, comme les
# autres deps). Calcule-le depuis la source OFFICIELLE :
#   wget -qO- https://raw.githubusercontent.com/marzer/tomlplusplus/v3.4.0/toml.hpp | sha256sum
TOMLPP_SHA256="6b5172ad4dd6519aec67b919181fa7a38a2234131e5b2afa232dfe444819783e"
TOMLPP_BUILD_DIR="${BUILD_DIR}/tomlpp"
TOMLPP_INSTALL_DIR="${TOMLPP_BUILD_DIR}/${TOMLPP_DIR}"
# Sous-dossier toml++/ pour matcher l'include canonique de la lib.
TOMLPP_INCLUDE_FILE="${TOMLPP_INSTALL_DIR}/toml++/toml.hpp"
#
# SQLite : amalgamation officielle (sqlite3.c + sqlite3.h, un seul
# fichier C de ~250k lignes). Pas de threads, pas de dépendances
# externes au-delà de la libc. Compile en quelques secondes sur
# x86_64, ~30-60s sur Pi0. Trade-off acceptable pour avoir une vraie
# DB embarquée sans réinventer la persistance.
#
# Version : déclarée selon le format SQLite XXYYZZBB
#   - X.YY.ZZ = version, BB = patch (0 pour release officielle)
#   - 3530100 = 3.53.1
# URL pattern : https://sqlite.org/YYYY/sqlite-amalgamation-XXYYZZBB.zip
# où YYYY est l'année de la release.
SQLITE_VERSION="3530100"            # 3.53.1
SQLITE_YEAR="2026"
SQLITE_DIR="sqlite-amalgamation-${SQLITE_VERSION}"
SQLITE_ZIP="${SQLITE_DIR}.zip"
SQLITE_URL="https://sqlite.org/${SQLITE_YEAR}/${SQLITE_ZIP}"
# Sources alternatives pour SQLite (Wayback en filet, comme Lua/OpenSSL).
SQLITE_URLS=(
    "${SQLITE_URL}"
    "https://web.archive.org/web/2025id_/${SQLITE_URL}"
)
# Calcule au premier build :
#   wget -qO- "${SQLITE_URL}" | sha256sum
# puis colle ici. SHA3-256 publié officiellement sur sqlite.org peut
# être recoupé. Avec une valeur vide, verify_sha256 fait planter le
# build pour forcer l'utilisateur à fixer la valeur.
SQLITE_SHA256="36ad6e7f38540a3b21a2ac36340833f0a9e426bc1c752751c3ba669466827eae"
SQLITE_BUILD_DIR="${BUILD_DIR}/sqlite"
SQLITE_INSTALL_DIR="${SQLITE_BUILD_DIR}/${SQLITE_DIR}"
SQLITE_C="${SQLITE_INSTALL_DIR}/sqlite3.c"
SQLITE_H="${SQLITE_INSTALL_DIR}/sqlite3.h"
#
GENERATED_DIR="${BUILD_DIR}/generated"


# Créer les répertoires nécessaires
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$LUA_BUILD_DIR"
mkdir -p "$BUILD_DIR"


# Installer miniz si nécessaire
if [ ! -f "${MINIZ_C}" ] || [ ! -f "${MINIZ_H}" ]; then
    echo "Installation de miniz ${MINIZ_VERSION}..."
    mkdir -p "${MINIZ_INSTALL_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${MINIZ_ZIP}" ]; then
        echo "Téléchargement de miniz ${MINIZ_VERSION}..."
        if ! wget "${MINIZ_URL}" -O "${DOWNLOAD_DIR}/${MINIZ_ZIP}"; then
            echo "Échec du téléchargement de miniz."
            rm -f "${DOWNLOAD_DIR}/${MINIZ_ZIP}"
            exit 1
        fi
    fi

    # Vérifié même si déjà en cache (cache empoisonné).
    verify_sha256 "${DOWNLOAD_DIR}/${MINIZ_ZIP}" "${MINIZ_SHA256}" "miniz"

    TEMP_MINIZ="${BUILD_DIR}/miniz_extract"
    rm -rf "${TEMP_MINIZ}"
    mkdir -p "${TEMP_MINIZ}"
    unzip -q "${DOWNLOAD_DIR}/${MINIZ_ZIP}" -d "${TEMP_MINIZ}"
    if [ $? -ne 0 ]; then
        echo "Échec de la décompression de miniz."
        exit 1
    fi

    # La structure interne de l'archive miniz peut varier selon la version,
    # on cherche donc miniz.c et miniz.h où qu'ils soient.
    FOUND_C=$(find "${TEMP_MINIZ}" -name "miniz.c" -print -quit)
    FOUND_H=$(find "${TEMP_MINIZ}" -name "miniz.h" -print -quit)

    if [ -z "${FOUND_C}" ] || [ -z "${FOUND_H}" ]; then
        echo "Erreur : miniz.c ou miniz.h introuvables dans l'archive téléchargée."
        exit 1
    fi

    cp "${FOUND_C}" "${MINIZ_C}"
    cp "${FOUND_H}" "${MINIZ_H}"
    rm -rf "${TEMP_MINIZ}"
    echo "miniz ${MINIZ_VERSION} installé."
fi


# Installer et compiler zlib si nécessaire.
if [ ! -f "${ZLIB_LIB}" ] || \
   [ ! -f "${ZLIB_INCLUDE}/zlib.h" ] || \
   [ ! -f "${ZLIB_INCLUDE}/zconf.h" ]; then
    echo "Installation de zlib ${ZLIB_VERSION}..."
    mkdir -p "${ZLIB_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${ZLIB_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${ZLIB_TAR}" \
                "zlib ${ZLIB_VERSION}" "${ZLIB_URLS[@]}"; then
            echo "Échec du téléchargement de zlib."
            echo "Astuce : place ${ZLIB_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${ZLIB_TAR}" \
        "${ZLIB_SHA256}" "zlib"

    if [ ! -d "${ZLIB_SOURCE_DIR}" ]; then
        echo "Décompression de zlib ${ZLIB_VERSION}..."
        tar -xzf "${DOWNLOAD_DIR}/${ZLIB_TAR}" -C "${ZLIB_ROOT}"
    fi

    rm -rf "${ZLIB_CMAKE_BUILD_DIR}" "${ZLIB_INSTALL_DIR}"
    echo "Compilation de zlib ${ZLIB_VERSION} (statique)..."
    cmake -S "${ZLIB_SOURCE_DIR}" \
          -B "${ZLIB_CMAKE_BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_INSTALL_PREFIX="${ZLIB_INSTALL_DIR}" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DZLIB_BUILD_SHARED=OFF \
          -DZLIB_BUILD_STATIC=ON \
          -DZLIB_BUILD_TESTING=OFF \
          -DZLIB_INSTALL=ON
    cmake --build "${ZLIB_CMAKE_BUILD_DIR}" \
          --target zlibstatic --parallel "$(nproc)"
    cmake --install "${ZLIB_CMAKE_BUILD_DIR}"

    if [ ! -f "${ZLIB_LIB}" ] || \
       [ ! -f "${ZLIB_INCLUDE}/zlib.h" ] || \
       [ ! -f "${ZLIB_INCLUDE}/zconf.h" ]; then
        echo "Échec : installation statique de zlib incomplète."
        exit 1
    fi
    echo "zlib ${ZLIB_VERSION} installé."
else
    echo "zlib ${ZLIB_VERSION} est déjà compilé."
fi

# Installer et compiler XZ Utils / liblzma si nécessaire.
if [ ! -f "${XZ_LIB}" ] || \
   [ ! -f "${XZ_INCLUDE}/lzma.h" ] || \
   [ ! -f "${XZ_INCLUDE}/lzma/version.h" ]; then
    echo "Installation de XZ Utils ${XZ_VERSION}..."
    mkdir -p "${XZ_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${XZ_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${XZ_TAR}" \
                "XZ Utils ${XZ_VERSION}" "${XZ_URLS[@]}"; then
            echo "Échec du téléchargement de XZ Utils."
            echo "Astuce : place ${XZ_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${XZ_TAR}" \
        "${XZ_SHA256}" "XZ Utils"

    if [ ! -d "${XZ_SOURCE_DIR}" ]; then
        echo "Décompression de XZ Utils ${XZ_VERSION}..."
        tar -xJf "${DOWNLOAD_DIR}/${XZ_TAR}" -C "${XZ_ROOT}"
    fi

    rm -rf "${XZ_CMAKE_BUILD_DIR}" "${XZ_INSTALL_DIR}"
    echo "Compilation de XZ Utils ${XZ_VERSION} (liblzma statique)..."
    cmake -S "${XZ_SOURCE_DIR}" \
          -B "${XZ_CMAKE_BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_INSTALL_PREFIX="${XZ_INSTALL_DIR}" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DBUILD_SHARED_LIBS=OFF \
          -DXZ_NLS=OFF \
          -DXZ_THREADS=no
    cmake --build "${XZ_CMAKE_BUILD_DIR}" \
          --target liblzma --parallel "$(nproc)"
    cmake --install "${XZ_CMAKE_BUILD_DIR}" \
          --component liblzma_Development

    if [ ! -f "${XZ_LIB}" ] || \
       [ ! -f "${XZ_INCLUDE}/lzma.h" ] || \
       [ ! -f "${XZ_INCLUDE}/lzma/version.h" ]; then
        echo "Échec : installation statique de liblzma incomplète."
        exit 1
    fi
    echo "XZ Utils ${XZ_VERSION} installé."
else
    echo "XZ Utils ${XZ_VERSION} est déjà compilé."
fi

# Installer et compiler bzip2 / libbz2 si nécessaire.
if [ ! -f "${BZIP2_LIB}" ] || [ ! -f "${BZIP2_INCLUDE}/bzlib.h" ]; then
    echo "Installation de bzip2 ${BZIP2_VERSION}..."
    mkdir -p "${BZIP2_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${BZIP2_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${BZIP2_TAR}" \
                "bzip2 ${BZIP2_VERSION}" "${BZIP2_URLS[@]}"; then
            echo "Échec du téléchargement de bzip2."
            echo "Astuce : place ${BZIP2_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${BZIP2_TAR}" \
        "${BZIP2_SHA256}" "bzip2"

    if [ ! -d "${BZIP2_SOURCE_DIR}" ]; then
        echo "Décompression de bzip2 ${BZIP2_VERSION}..."
        tar -xzf "${DOWNLOAD_DIR}/${BZIP2_TAR}" -C "${BZIP2_ROOT}"
    fi

    rm -rf "${BZIP2_INSTALL_DIR}"
    echo "Compilation de bzip2 ${BZIP2_VERSION} (libbz2 statique)..."
    make -C "${BZIP2_SOURCE_DIR}" clean >/dev/null 2>&1 || true
    make -C "${BZIP2_SOURCE_DIR}" \
         CC="${CC:-cc}" AR="${AR:-ar}" RANLIB="${RANLIB:-ranlib}" \
         CFLAGS="-O2 -fPIC -Wall -Winline -D_FILE_OFFSET_BITS=64" \
         libbz2.a

    mkdir -p "${BZIP2_INSTALL_DIR}/lib" "${BZIP2_INCLUDE}"
    cp "${BZIP2_SOURCE_DIR}/libbz2.a" "${BZIP2_LIB}"
    cp "${BZIP2_SOURCE_DIR}/bzlib.h" "${BZIP2_INCLUDE}/bzlib.h"

    if [ ! -f "${BZIP2_LIB}" ] || \
       [ ! -f "${BZIP2_INCLUDE}/bzlib.h" ]; then
        echo "Échec : installation statique de libbz2 incomplète."
        exit 1
    fi
    echo "bzip2 ${BZIP2_VERSION} installé."
else
    echo "bzip2 ${BZIP2_VERSION} est déjà compilé."
fi

# Installer et compiler Zstandard / libzstd si nécessaire.
if [ ! -f "${ZSTD_LIB}" ] || [ ! -f "${ZSTD_INCLUDE}/zstd.h" ]; then
    echo "Installation de Zstandard ${ZSTD_VERSION}..."
    mkdir -p "${ZSTD_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${ZSTD_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${ZSTD_TAR}" \
                "Zstandard ${ZSTD_VERSION}" "${ZSTD_URLS[@]}"; then
            echo "Échec du téléchargement de Zstandard."
            echo "Astuce : place ${ZSTD_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${ZSTD_TAR}" \
        "${ZSTD_SHA256}" "Zstandard"

    if [ ! -d "${ZSTD_SOURCE_DIR}" ]; then
        echo "Décompression de Zstandard ${ZSTD_VERSION}..."
        tar -xzf "${DOWNLOAD_DIR}/${ZSTD_TAR}" -C "${ZSTD_ROOT}"
    fi

    rm -rf "${ZSTD_CMAKE_BUILD_DIR}" "${ZSTD_INSTALL_DIR}"
    echo "Compilation de Zstandard ${ZSTD_VERSION} (libzstd statique)..."
    cmake -S "${ZSTD_SOURCE_DIR}/build/cmake" \
          -B "${ZSTD_CMAKE_BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_INSTALL_PREFIX="${ZSTD_INSTALL_DIR}" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DZSTD_BUILD_SHARED=OFF \
          -DZSTD_BUILD_STATIC=ON \
          -DZSTD_BUILD_PROGRAMS=OFF \
          -DZSTD_BUILD_TESTS=OFF \
          -DZSTD_BUILD_CONTRIB=OFF \
          -DZSTD_LEGACY_SUPPORT=OFF \
          -DZSTD_MULTITHREAD_SUPPORT=OFF
    cmake --build "${ZSTD_CMAKE_BUILD_DIR}" \
          --target libzstd_static --parallel "$(nproc)"
    cmake --install "${ZSTD_CMAKE_BUILD_DIR}"

    if [ ! -f "${ZSTD_LIB}" ] || \
       [ ! -f "${ZSTD_INCLUDE}/zstd.h" ] || \
       [ ! -f "${ZSTD_INCLUDE}/zstd_errors.h" ]; then
        echo "Échec : installation statique de libzstd incomplète."
        exit 1
    fi
    echo "Zstandard ${ZSTD_VERSION} installé."
else
    echo "Zstandard ${ZSTD_VERSION} est déjà compilé."
fi

# Installer et compiler Abseil si nécessaire.
ABSL_REBUILD=0
if [ ! -f "${ABSL_CMAKE_DIR}/abslConfig.cmake" ] || \
   [ ! -f "${ABSL_INSTALL_DIR}/include/absl/base/config.h" ] || \
   [ ! -f "${ABSL_PROFILE_FILE}" ] || \
   [ "$(cat "${ABSL_PROFILE_FILE}" 2>/dev/null || true)" != \
     "${ABSL_BUILD_PROFILE}" ]; then
    ABSL_REBUILD=1
fi

if [ "${ABSL_REBUILD}" -eq 1 ]; then
    echo "Installation d'Abseil ${ABSL_VERSION}..."
    mkdir -p "${ABSL_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${ABSL_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${ABSL_TAR}" \
                "Abseil ${ABSL_VERSION}" "${ABSL_URLS[@]}"; then
            echo "Échec du téléchargement d'Abseil."
            echo "Astuce : place ${ABSL_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${ABSL_TAR}" \
        "${ABSL_SHA256}" "Abseil"

    if [ ! -d "${ABSL_SOURCE_DIR}" ]; then
        echo "Décompression d'Abseil ${ABSL_VERSION}..."
        tar -xzf "${DOWNLOAD_DIR}/${ABSL_TAR}" -C "${ABSL_ROOT}"
    fi

    rm -rf "${ABSL_CMAKE_BUILD_DIR}" "${ABSL_INSTALL_DIR}"
    echo "Compilation d'Abseil ${ABSL_VERSION} (bibliothèques statiques)..."
    cmake -S "${ABSL_SOURCE_DIR}" \
          -B "${ABSL_CMAKE_BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_CXX_STANDARD=17 \
          -DCMAKE_CXX_STANDARD_REQUIRED=ON \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_INSTALL_PREFIX="${ABSL_INSTALL_DIR}" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DBUILD_SHARED_LIBS=OFF \
          -DBUILD_TESTING=OFF \
          -DABSL_BUILD_TESTING=OFF \
          -DABSL_PROPAGATE_CXX_STD=ON \
          -DABSL_ENABLE_INSTALL=ON
    cmake --build "${ABSL_CMAKE_BUILD_DIR}" --parallel "$(nproc)"
    cmake --install "${ABSL_CMAKE_BUILD_DIR}"

    if [ ! -f "${ABSL_CMAKE_DIR}/abslConfig.cmake" ] || \
       [ ! -f "${ABSL_INSTALL_DIR}/include/absl/base/config.h" ] || \
       [ ! -f "${ABSL_INSTALL_DIR}/lib/libabsl_base.a" ]; then
        echo "Échec : installation statique d'Abseil incomplète."
        exit 1
    fi

    printf '%s\n' "${ABSL_BUILD_PROFILE}" > "${ABSL_PROFILE_FILE}"
    echo "Abseil ${ABSL_VERSION} installé."
else
    echo "Abseil ${ABSL_VERSION} est déjà compilé."
fi

# Installer et compiler RE2 si nécessaire.
RE2_REBUILD=0
if [ ! -f "${RE2_LIB}" ] || \
   [ ! -f "${RE2_INCLUDE}/re2/re2.h" ] || \
   [ ! -f "${RE2_CMAKE_DIR}/re2Config.cmake" ] || \
   [ ! -f "${RE2_PROFILE_FILE}" ] || \
   [ "$(cat "${RE2_PROFILE_FILE}" 2>/dev/null || true)" != \
     "${RE2_BUILD_PROFILE}" ]; then
    RE2_REBUILD=1
fi

if [ "${RE2_REBUILD}" -eq 1 ]; then
    echo "Installation de RE2 ${RE2_VERSION}..."
    mkdir -p "${RE2_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${RE2_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${RE2_TAR}" \
                "RE2 ${RE2_VERSION}" "${RE2_URLS[@]}"; then
            echo "Échec du téléchargement de RE2."
            echo "Astuce : place ${RE2_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${RE2_TAR}" \
        "${RE2_SHA256}" "RE2"

    if [ ! -d "${RE2_SOURCE_DIR}" ]; then
        echo "Décompression de RE2 ${RE2_VERSION}..."
        tar -xzf "${DOWNLOAD_DIR}/${RE2_TAR}" -C "${RE2_ROOT}"
    fi

    rm -rf "${RE2_CMAKE_BUILD_DIR}" "${RE2_INSTALL_DIR}"
    echo "Compilation de RE2 ${RE2_VERSION} (bibliothèque statique)..."
    cmake -S "${RE2_SOURCE_DIR}" \
          -B "${RE2_CMAKE_BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DCMAKE_INSTALL_PREFIX="${RE2_INSTALL_DIR}" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DCMAKE_PREFIX_PATH="${ABSL_INSTALL_DIR}" \
          -Dabsl_DIR="${ABSL_CMAKE_DIR}" \
          -DBUILD_SHARED_LIBS=OFF \
          -DBUILD_TESTING=OFF \
          -DRE2_USE_ICU=OFF \
          -DRE2_TEST=OFF \
          -DRE2_BENCHMARK=OFF \
          -DRE2_BUILD_TESTING=OFF \
          -DRE2_INSTALL=ON
    cmake --build "${RE2_CMAKE_BUILD_DIR}" \
          --target re2 --parallel "$(nproc)"
    cmake --install "${RE2_CMAKE_BUILD_DIR}"

    if [ ! -f "${RE2_LIB}" ] || \
       [ ! -f "${RE2_INCLUDE}/re2/re2.h" ] || \
       [ ! -f "${RE2_CMAKE_DIR}/re2Config.cmake" ]; then
        echo "Échec : installation statique de RE2 incomplète."
        exit 1
    fi

    printf '%s\n' "${RE2_BUILD_PROFILE}" > "${RE2_PROFILE_FILE}"
    echo "RE2 ${RE2_VERSION} installé."
else
    echo "RE2 ${RE2_VERSION} est déjà compilé."
fi

# Installer et compiler libarchive si nécessaire.
#
# La configuration est volontairement minimale : bibliothèque statique,
# aucun outil ni test amont, TAR natif et filtres gzip, xz, bzip2 et zstd internes uniquement.
# Le profil enregistré force une reconstruction lorsque les codecs activés
# changent, même si une ancienne libarchive.a existe déjà dans le cache.
LIBARCHIVE_REBUILD=0
if [ ! -f "${LIBARCHIVE_LIB}" ] || \
   [ ! -f "${LIBARCHIVE_INCLUDE}/archive.h" ] || \
   [ ! -f "${LIBARCHIVE_INCLUDE}/archive_entry.h" ] || \
   [ ! -f "${LIBARCHIVE_PROFILE_FILE}" ] || \
   [ "$(cat "${LIBARCHIVE_PROFILE_FILE}" 2>/dev/null || true)" != \
     "${LIBARCHIVE_BUILD_PROFILE}" ]; then
    LIBARCHIVE_REBUILD=1
fi

if [ "${LIBARCHIVE_REBUILD}" -eq 1 ]; then
    echo "Installation de libarchive ${LIBARCHIVE_VERSION} avec gzip, xz, bzip2 et zstd..."
    mkdir -p "${LIBARCHIVE_ROOT}" "${DOWNLOAD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${LIBARCHIVE_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${LIBARCHIVE_TAR}" \
                "libarchive ${LIBARCHIVE_VERSION}" "${LIBARCHIVE_URL}"; then
            echo "Échec du téléchargement de libarchive."
            echo "Astuce : place ${LIBARCHIVE_TAR} manuellement dans"
            echo "  ${DOWNLOAD_DIR}/"
            echo "puis relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    verify_sha256 "${DOWNLOAD_DIR}/${LIBARCHIVE_TAR}" \
        "${LIBARCHIVE_SHA256}" "libarchive"

    if [ ! -d "${LIBARCHIVE_SOURCE_DIR}" ]; then
        echo "Décompression de libarchive ${LIBARCHIVE_VERSION}..."
        tar -xJf "${DOWNLOAD_DIR}/${LIBARCHIVE_TAR}" \
            -C "${LIBARCHIVE_ROOT}"
    fi

    rm -rf "${LIBARCHIVE_CMAKE_BUILD_DIR}"
    echo "Compilation de libarchive ${LIBARCHIVE_VERSION} (TAR + gzip + xz + bzip2 + zstd)..."
    cmake -S "${LIBARCHIVE_SOURCE_DIR}" \
          -B "${LIBARCHIVE_CMAKE_BUILD_DIR}" \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
          -DBUILD_SHARED_LIBS=OFF \
          -DENABLE_TEST=OFF \
          -DENABLE_INSTALL=OFF \
          -DENABLE_TAR=OFF \
          -DENABLE_CPIO=OFF \
          -DENABLE_CAT=OFF \
          -DENABLE_UNZIP=OFF \
          -DENABLE_OPENSSL=OFF \
          -DENABLE_MBEDTLS=OFF \
          -DENABLE_NETTLE=OFF \
          -DENABLE_LIBB2=OFF \
          -DENABLE_LZ4=OFF \
          -DENABLE_LZO=OFF \
          -DENABLE_LZMA=ON \
          -DLIBLZMA_LIBRARY="${XZ_LIB}" \
          -DLIBLZMA_INCLUDE_DIR="${XZ_INCLUDE}" \
          -DENABLE_ZSTD=ON \
          -DZSTD_LIBRARY="${ZSTD_LIB}" \
          -DZSTD_INCLUDE_DIR="${ZSTD_INCLUDE}" \
          -DENABLE_ZLIB=ON \
          -DZLIB_LIBRARY="${ZLIB_LIB}" \
          -DZLIB_INCLUDE_DIR="${ZLIB_INCLUDE}" \
          -DENABLE_BZip2=ON \
          -DBZIP2_LIBRARIES="${BZIP2_LIB}" \
          -DBZIP2_INCLUDE_DIR="${BZIP2_INCLUDE}" \
          -DENABLE_LIBXML2=OFF \
          -DENABLE_EXPAT=OFF \
          -DENABLE_PCREPOSIX=OFF \
          -DENABLE_PCRE2POSIX=OFF \
          -DENABLE_LIBGCC=OFF \
          -DENABLE_ACL=OFF \
          -DENABLE_XATTR=OFF \
          -DENABLE_ICONV=OFF \
          -DENABLE_CNG=OFF \
          -DENABLE_WERROR=OFF

    cmake --build "${LIBARCHIVE_CMAKE_BUILD_DIR}" \
          --target archive_static --parallel "$(nproc)"

    if [ ! -f "${LIBARCHIVE_LIB}" ]; then
        echo "Échec : bibliothèque statique libarchive introuvable après compilation :"
        echo "  ${LIBARCHIVE_LIB}"
        exit 1
    fi
    if [ ! -f "${LIBARCHIVE_INCLUDE}/archive.h" ] || \
       [ ! -f "${LIBARCHIVE_INCLUDE}/archive_entry.h" ]; then
        echo "Échec : headers publics libarchive introuvables après extraction."
        exit 1
    fi

    printf '%s\n' "${LIBARCHIVE_BUILD_PROFILE}" > \
        "${LIBARCHIVE_PROFILE_FILE}"
    echo "libarchive ${LIBARCHIVE_VERSION} installé avec gzip, xz, bzip2 et zstd."
else
    echo "libarchive ${LIBARCHIVE_VERSION} est déjà compilé avec gzip, xz, bzip2 et zstd."
fi

# Installer nlohmann/json (header-only) si nécessaire
if [ ! -f "${JSON_INCLUDE_FILE}" ]; then
    echo "Installation de nlohmann/json ${JSON_VERSION}..."
    mkdir -p "${JSON_INSTALL_DIR}/nlohmann"

    if [ ! -f "${DOWNLOAD_DIR}/${JSON_DIR}-${JSON_HEADER}" ]; then
        echo "Téléchargement de nlohmann/json ${JSON_VERSION}..."
        if ! wget "${JSON_URL}" -O "${DOWNLOAD_DIR}/${JSON_DIR}-${JSON_HEADER}"; then
            echo "Échec du téléchargement de nlohmann/json."
            rm -f "${DOWNLOAD_DIR}/${JSON_DIR}-${JSON_HEADER}"
            exit 1
        fi
    fi

    # Vérifié même si déjà en cache (cache empoisonné).
    verify_sha256 "${DOWNLOAD_DIR}/${JSON_DIR}-${JSON_HEADER}" "${JSON_SHA256}" "nlohmann/json"

    cp "${DOWNLOAD_DIR}/${JSON_DIR}-${JSON_HEADER}" "${JSON_INCLUDE_FILE}"
    echo "nlohmann/json ${JSON_VERSION} installé."
fi

# Installer cpp-httplib (header-only) si nécessaire
if [ ! -f "${HTTPLIB_INCLUDE_FILE}" ]; then
    echo "Installation de cpp-httplib ${HTTPLIB_VERSION}..."
    mkdir -p "${HTTPLIB_INSTALL_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${HTTPLIB_DIR}-${HTTPLIB_HEADER}" ]; then
        echo "Téléchargement de cpp-httplib ${HTTPLIB_VERSION}..."
        if ! wget "${HTTPLIB_URL}" -O "${DOWNLOAD_DIR}/${HTTPLIB_DIR}-${HTTPLIB_HEADER}"; then
            echo "Échec du téléchargement de cpp-httplib."
            rm -f "${DOWNLOAD_DIR}/${HTTPLIB_DIR}-${HTTPLIB_HEADER}"
            exit 1
        fi
    fi

    # Vérifié même si déjà en cache (cache empoisonné).
    verify_sha256 "${DOWNLOAD_DIR}/${HTTPLIB_DIR}-${HTTPLIB_HEADER}" "${HTTPLIB_SHA256}" "cpp-httplib"

    cp "${DOWNLOAD_DIR}/${HTTPLIB_DIR}-${HTTPLIB_HEADER}" "${HTTPLIB_INCLUDE_FILE}"
    echo "cpp-httplib ${HTTPLIB_VERSION} installé."
fi

# Installer toml++ (header-only single-file) si nécessaire
if [ ! -f "${TOMLPP_INCLUDE_FILE}" ]; then
    echo "Installation de toml++ ${TOMLPP_VERSION}..."
    mkdir -p "${TOMLPP_INSTALL_DIR}/toml++"

    if [ ! -f "${DOWNLOAD_DIR}/${TOMLPP_DIR}-${TOMLPP_HEADER}" ]; then
        echo "Téléchargement de toml++ ${TOMLPP_VERSION}..."
        if ! wget "${TOMLPP_URL}" -O "${DOWNLOAD_DIR}/${TOMLPP_DIR}-${TOMLPP_HEADER}"; then
            echo "Échec du téléchargement de toml++."
            rm -f "${DOWNLOAD_DIR}/${TOMLPP_DIR}-${TOMLPP_HEADER}"
            exit 1
        fi
    fi

    # Vérifié même si déjà en cache (cache empoisonné).
    verify_sha256 "${DOWNLOAD_DIR}/${TOMLPP_DIR}-${TOMLPP_HEADER}" "${TOMLPP_SHA256}" "toml++"

    cp "${DOWNLOAD_DIR}/${TOMLPP_DIR}-${TOMLPP_HEADER}" "${TOMLPP_INCLUDE_FILE}"
    echo "toml++ ${TOMLPP_VERSION} installé."
fi

# Installer SQLite (amalgamation officielle, single-source) si nécessaire
if [ ! -f "${SQLITE_C}" ] || [ ! -f "${SQLITE_H}" ]; then
    echo "Installation de SQLite ${SQLITE_VERSION}..."
    mkdir -p "${SQLITE_BUILD_DIR}"

    if [ ! -f "${DOWNLOAD_DIR}/${SQLITE_ZIP}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${SQLITE_ZIP}" \
                "SQLite ${SQLITE_VERSION}" "${SQLITE_URLS[@]}"; then
            echo "Échec du téléchargement de SQLite depuis toutes les sources."
            echo "Astuce : si tu as le zip ailleurs, place-le manuellement"
            echo "  dans ${DOWNLOAD_DIR}/${SQLITE_ZIP}"
            echo "et relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    # Vérifié même si déjà en cache.
    verify_sha256 "${DOWNLOAD_DIR}/${SQLITE_ZIP}" "${SQLITE_SHA256}" "SQLite"

    if [ ! -d "${SQLITE_INSTALL_DIR}" ]; then
        echo "Décompression de SQLite ${SQLITE_VERSION}..."
        unzip -q "${DOWNLOAD_DIR}/${SQLITE_ZIP}" -d "${SQLITE_BUILD_DIR}"
        if [ $? -ne 0 ]; then
            echo "Échec de la décompression de SQLite."
            exit 1
        fi
    fi

    echo "SQLite ${SQLITE_VERSION} installé."
fi

# Télécharger Lua si nécessaire
if [ ! -f "$DOWNLOAD_DIR/$LUA_TAR" ]; then
    if ! download_with_fallback "$DOWNLOAD_DIR/$LUA_TAR" \
            "Lua $LUA_VERSION" "${LUA_URLS[@]}"; then
        echo "Échec du téléchargement de Lua depuis toutes les sources."
        echo "Astuce : si tu as le tarball ailleurs, place-le manuellement"
        echo "  dans ${DOWNLOAD_DIR}/${LUA_TAR}"
        echo "et relance le script. Le SHA256 sera vérifié."
        exit 1
    fi
fi

# Vérifié même si déjà en cache (cache empoisonné).
verify_sha256 "$DOWNLOAD_DIR/$LUA_TAR" "${LUA_SHA256}" "Lua"

# Décompresser Lua si nécessaire
if [ ! -d "$LUA_BUILD_DIR/$LUA_DIR" ]; then
    echo "Décompression de Lua $LUA_VERSION..."
    tar -xzf "$DOWNLOAD_DIR/$LUA_TAR" -C "$LUA_BUILD_DIR"
    if [ $? -ne 0 ]; then
        echo "Échec de la décompression de Lua."
        exit 1
    fi
fi

# Compiler Lua si les fichiers nécessaires sont absents
if [ ! -f "$LUA_LIB" ] || [ ! -f "${LUA_INCLUDE}/lua.h" ]; then
    echo "Compilation de Lua $LUA_VERSION..."
    cd "$LUA_BUILD_DIR/$LUA_DIR" || exit 1
    sed -i 's/^MYCFLAGS=.*/MYCFLAGS=-fPIC/' src/Makefile
    sed -i 's/^MYLIBS=.*/MYLIBS=-lm/' src/Makefile
    sed -i 's/^ALL_T=.*/ALL_T=liblua.a/' src/Makefile

    make clean
    make linux -j"$(nproc)"
    if [ $? -ne 0 ]; then
        echo "Échec de la compilation de Lua."
        exit 1
    fi
else
    echo "Lua $LUA_VERSION est déjà compilé."
fi

# Revenir au répertoire du script
cd "$SCRIPT_DIR" || exit 1


# OpenSSL : TOUJOURS compilé en local depuis la version pinnée
# ci-dessus, jamais utilisé depuis le système.
#
# Pourquoi : la libssl-dev d'Ubuntu, celle d'Arch et celle de
# Raspberry Pi OS sont des versions différentes (souvent une
# 3.0.x ou 3.2.x sur les Ubuntu LTS), et linker contre la version
# système donnerait 3 binaires non-reproductibles selon la machine
# qui compile. Cohérence avec miniz, json, httplib, tomlpp, sqlite
# qui sont tous vendored.
#
# Trade-off accepté : premier build ~30-60s sur x86_64 (variable
# selon CPU), 1-2h sur RPi0. Builds suivants instantanés grâce au
# cache build/openssl/.
OPENSSL_PATH_LOCAL=$(find "${OPENSSL_BUILD_DIR}" -name "libssl.a" -print -quit 2>/dev/null | sed 's|^\./||')

if [ ! -f "${OPENSSL_PATH_LOCAL}" ]; then
    echo "openssl ${OPENSSL_VERSION} : pas encore compilé localement"

    if [ ! -f "${DOWNLOAD_DIR}/${OPENSSL_TAR}" ]; then
        if ! download_with_fallback "${DOWNLOAD_DIR}/${OPENSSL_TAR}" \
                "openssl ${OPENSSL_VERSION}" "${OPENSSL_URLS[@]}"; then
            echo "Échec du téléchargement d'openssl depuis toutes les sources."
            echo "Astuce : si tu as le tarball ailleurs, place-le manuellement"
            echo "  dans ${DOWNLOAD_DIR}/${OPENSSL_TAR}"
            echo "et relance le script. Le SHA256 sera vérifié."
            exit 1
        fi
    fi

    # SHA256 vérifié systématiquement, même si déjà en cache.
    verify_sha256 "${DOWNLOAD_DIR}/${OPENSSL_TAR}" "${OPENSSL_SHA256}" "openssl"

    if [ ! -d "${OPENSSL_BUILD_DIR}/${OPENSSL_DIR}" ]; then
        echo "Décompression de openssl ${OPENSSL_VERSION}..."
        mkdir -p "${OPENSSL_BUILD_DIR}"
        tar -xzf "${DOWNLOAD_DIR}/${OPENSSL_TAR}" -C "${OPENSSL_BUILD_DIR}"
        if [ $? -ne 0 ]; then
            echo "Échec de la décompression de openssl."
            exit 1
        fi
    fi

    echo "Compilation de openssl ${OPENSSL_VERSION} (peut prendre du temps)..."
    cd "${OPENSSL_BUILD_DIR}/${OPENSSL_DIR}" || exit 1
    # --openssldir=/etc/ssl : pointe OPENSSLDIR vers l'emplacement
    # standard sur Arch, Debian, Ubuntu, Alpine, et de nombreuses
    # autres distros. Sans ça, SSL_CTX_set_default_verify_paths()
    # cherche les CA dans le chemin par défaut d'OpenSSL upstream
    # (~/usr/local/ssl) qui n'existe nulle part en pratique →
    # HTTPS échoue par défaut.
    # Fedora/RHEL/OpenSUSE/*BSD utilisent d'autres chemins ;
    # un probing runtime côté socket.cpp les couvre en complément.
    ./Configure no-shared --openssldir=/etc/ssl
    make clean
    make -j"$(nproc)"
    if [ $? -ne 0 ]; then
        echo "Échec de la compilation d'openssl."
        exit 1
    fi
fi

OPENSSL_PATH="${OPENSSL_BUILD_DIR}/${OPENSSL_DIR}/libssl.a"
CRYPTO_PATH="${OPENSSL_BUILD_DIR}/${OPENSSL_DIR}/libcrypto.a"

# Revenir au répertoire du script
cd "$SCRIPT_DIR" || exit 1


# Créer le répertoire de build pour le projet
mkdir -p "$PROJECT_BUILD_DIR"

PROJECT_SOURCE_HASH_FILE="${PROJECT_BUILD_DIR}/.babet-source-tree.sha256"
PROJECT_SOURCE_HASH="$(compute_project_sources_sha256)"
if [ -z "${PROJECT_SOURCE_HASH}" ]; then
    echo "Échec du calcul de l'empreinte des sources Babet."
    exit 1
fi
PREVIOUS_PROJECT_SOURCE_HASH=""
if [ -f "${PROJECT_SOURCE_HASH_FILE}" ]; then
    PREVIOUS_PROJECT_SOURCE_HASH="$(cat "${PROJECT_SOURCE_HASH_FILE}")"
fi
PROJECT_SOURCE_CHANGED=0
if [ "${PROJECT_SOURCE_HASH}" != "${PREVIOUS_PROJECT_SOURCE_HASH}" ]; then
    PROJECT_SOURCE_CHANGED=1
fi

cd "$PROJECT_BUILD_DIR" || exit 1

# --- Génération des modules Lua bundlés ---------------------------
# On régénère systématiquement : c'est rapide et ça garantit qu'un
# vendor/*.lua modifié sera repris au prochain build sans clear.sh.
echo "Génération des modules Lua bundlés..."
mkdir -p "${GENERATED_DIR}"
bash "${SCRIPT_DIR}/tools/embed_lua_module.sh" \
    "${SCRIPT_DIR}/vendor/inspect.lua" \
    "${GENERATED_DIR}/embedded_inspect.hpp" \
    "inspect"
bash "${SCRIPT_DIR}/tools/embed_lua_module.sh" \
    "${SCRIPT_DIR}/vendor/argparse.lua" \
    "${GENERATED_DIR}/embedded_argparse.hpp" \
    "argparse"
bash "${SCRIPT_DIR}/tools/embed_lua_module.sh" \
    "${SCRIPT_DIR}/vendor/logging.lua" \
    "${GENERATED_DIR}/embedded_logging.hpp" \
    "logging"

if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
    echo "Configuration pré-release : ASan + UBSan activés."
fi

cmake "$SCRIPT_DIR" \
    -DLUA_LIB="$LUA_LIB" \
    -DLUA_INCLUDE="$LUA_INCLUDE" \
    -DOPENSSL_LIB="${OPENSSL_PATH}" \
    -DCRYPTO_LIB="${CRYPTO_PATH}" \
    -DMINIZ_SRC="${MINIZ_C}" \
    -DMINIZ_INCLUDE="${MINIZ_INSTALL_DIR}" \
    -DLIBARCHIVE_LIB="${LIBARCHIVE_LIB}" \
    -DLIBARCHIVE_INCLUDE="${LIBARCHIVE_INCLUDE}" \
    -DZLIB_LIB="${ZLIB_LIB}" \
    -DZLIB_INCLUDE="${ZLIB_INCLUDE}" \
    -DLZMA_LIB="${XZ_LIB}" \
    -DLZMA_INCLUDE="${XZ_INCLUDE}" \
    -DBZIP2_LIB="${BZIP2_LIB}" \
    -DBZIP2_INCLUDE="${BZIP2_INCLUDE}" \
    -DBZIP2_VERSION="${BZIP2_VERSION}" \
    -DZSTD_LIB="${ZSTD_LIB}" \
    -DZSTD_INCLUDE="${ZSTD_INCLUDE}" \
    -DABSL_CMAKE_DIR="${ABSL_CMAKE_DIR}" \
    -DRE2_CMAKE_DIR="${RE2_CMAKE_DIR}" \
    -DRE2_INCLUDE="${RE2_INCLUDE}" \
    -DJSON_INCLUDE="${JSON_INSTALL_DIR}" \
    -DHTTPLIB_INCLUDE="${HTTPLIB_INSTALL_DIR}" \
    -DTOMLPP_INCLUDE="${TOMLPP_INSTALL_DIR}" \
    -DSQLITE_SRC="${SQLITE_C}" \
    -DSQLITE_INCLUDE="${SQLITE_INSTALL_DIR}" \
    -DGENERATED_INCLUDE="${GENERATED_DIR}" \
    -DBABET_ENABLE_SANITIZERS="${CMAKE_SANITIZERS}"
if [ $? -ne 0 ]; then
    echo "Échec de la configuration avec CMake."
    exit 1
fi

if [ "${PROJECT_SOURCE_CHANGED}" -eq 1 ]; then
    echo "Changement du contenu source détecté : nettoyage du build CMake de Babet..."
    if ! cmake --build . --target clean; then
        echo "Échec du nettoyage du build CMake de Babet."
        exit 1
    fi
fi

# Compiler le projet
make -j"$(nproc)"
if [ $? -ne 0 ]; then
    echo "Échec de la compilation du projet."
    exit 1
fi

# L'empreinte n'est validée qu'après une compilation réussie. En cas d'échec,
# le prochain lancement nettoiera de nouveau le build au lieu d'enregistrer un
# état partiellement construit comme référence.
printf '%s\n' "${PROJECT_SOURCE_HASH}" > "${PROJECT_SOURCE_HASH_FILE}"

# Reset complet du dossier test pour partir d'un état propre
rm -rf "${SCRIPT_DIR}/test"
mkdir -p "${SCRIPT_DIR}/test"

# Copier le binaire compilé
cp "${PROJECT_BUILD_DIR}/${PROJECT_NAME}" "${SCRIPT_DIR}/test/${PROJECT_NAME}"

# Copier le contenu de examples/ vers test/ (s'il existe)
if [ -d "${SCRIPT_DIR}/examples" ]; then
    cp -r "${SCRIPT_DIR}/examples/." "${SCRIPT_DIR}/test/"
fi

echo "Build OK. Binaire prêt dans ${SCRIPT_DIR}/test/${PROJECT_NAME}"

# Si --run : lance le binaire sur le dossier test
if [ "${RUN_AFTER_BUILD}" -eq 1 ]; then
    echo "Lancement du binaire sur test/..."
    cd "${SCRIPT_DIR}/test/"
    (./"${PROJECT_NAME}" .)
fi
