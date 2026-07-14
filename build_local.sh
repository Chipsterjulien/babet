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
MINIZ_VERSION="3.1.1"
MINIZ_DIR="miniz-${MINIZ_VERSION}"
MINIZ_ZIP="${MINIZ_DIR}.zip"
MINIZ_URL="https://github.com/richgel999/miniz/releases/download/${MINIZ_VERSION}/${MINIZ_ZIP}"
# Calcule :
#   wget -qO- https://github.com/richgel999/miniz/releases/download/3.1.1/miniz-3.1.1.zip | sha256sum
MINIZ_SHA256="cb28402bb2af93bdc331b60d16807e89727d1712a2d0a7ba0cac79a3e406fe40"
MINIZ_BUILD_DIR="${BUILD_DIR}/miniz"
MINIZ_INSTALL_DIR="${MINIZ_BUILD_DIR}/${MINIZ_DIR}"
MINIZ_C="${MINIZ_INSTALL_DIR}/miniz.c"
MINIZ_H="${MINIZ_INSTALL_DIR}/miniz.h"
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

# Compiler le projet
make -j"$(nproc)"
if [ $? -ne 0 ]; then
    echo "Échec de la compilation du projet."
    exit 1
fi


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
