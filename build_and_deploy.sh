#!/bin/bash

# Arrêt au premier échec : si un wget/cmake/make foire silencieusement,
# on ne veut pas continuer à compiler avec un état corrompu. Les commandes
# critiques sont déjà testées explicitement avec `if !`, mais set -e fait
# office de filet de sécurité pour celles qu'on aurait oubliées.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="babet"
INSTALL_PATH="/usr/local/bin/${PROJECT_NAME}"

# Compile via le script normal (pas besoin de root pour ça)
if ! bash "${SCRIPT_DIR}/build_local.sh"; then
    echo "Échec de la compilation."
    exit 1
fi

BINARY="${SCRIPT_DIR}/test/${PROJECT_NAME}"
if [ ! -x "${BINARY}" ]; then
    echo "Erreur : binaire ${BINARY} introuvable après compilation."
    exit 1
fi

# Le builder doit retrouver son descripteur dans les octets du runtime.
# UPX le masque dans le fichier compressé : conserver le binaire du build.
# Tester le vrai packaging avant toute écriture dans /usr/local/bin.
mkdir -p -- "${SCRIPT_DIR}/build"
SMOKE_DIR=$(mktemp -d "${SCRIPT_DIR}/build/deploy-smoke.XXXXXX")
trap 'rm -rf -- "${SMOKE_DIR}"' EXIT
printf '%s\n' 'print("BABET_DEPLOY_SMOKE_OK")' > "${SMOKE_DIR}/main.lua"
echo "Vérification du packaging avant installation..."
if ! "${BINARY}" -c "${SMOKE_DIR}" "${SMOKE_DIR}/application"; then
    echo "Échec du packaging : installation annulée."
    exit 1
fi
if ! SMOKE_OUTPUT=$("${SMOKE_DIR}/application") ||
    [ "${SMOKE_OUTPUT}" != "BABET_DEPLOY_SMOKE_OK" ]; then
    echo "Échec de l'application générée : installation annulée."
    exit 1
fi

# Préparer le fichier dans le dossier cible, puis publier par rename : un
# processus déjà lancé garde son inode et un échec de copie garde l'ancien
# binaire intact. Le shell privilégié possède et nettoie son propre temporaire.
echo "Installation vers ${INSTALL_PATH}..."
INSTALL_COMMAND=(bash -s --)
if [ "$(id -u)" -ne 0 ]; then
    INSTALL_COMMAND=(sudo bash -s --)
fi
"${INSTALL_COMMAND[@]}" "${BINARY}" "${INSTALL_PATH}" <<'INSTALL_SCRIPT'
set -e
source_path=$1
target_path=$2
temporary_path=$(mktemp "${target_path}.tmp.XXXXXX")
trap 'rm -f -- "${temporary_path}"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
install -m 0755 -- "${source_path}" "${temporary_path}"
mv -fT -- "${temporary_path}" "${target_path}"
INSTALL_SCRIPT

echo "Installé avec succès dans ${INSTALL_PATH}."
echo "Test : babet --help"
