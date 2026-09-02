#!/bin/bash
# Usage:
#   ./clear_code.sh           # nettoie les artefacts de build/test rapides
#   ./clear_code.sh --all     # reset complet des artefacts générés connus

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REMOVE_ALL=0

for arg in "$@"; do
    case "$arg" in
        --all)
            REMOVE_ALL=1
            ;;
        --help|-h)
            echo "Usage: $0 [--all]"
            echo "  (par défaut)   Nettoie build/, test/ et l'ancien src/third_party/"
            echo "  --all          Ajoute downloads/, dist/, journaux de tests et scratch release"
            exit 0
            ;;
        *)
            echo "Argument inconnu : $arg"
            echo "Voir $0 --help"
            exit 1
            ;;
    esac
done

remove_dir_if_present() {
    local path="$1"
    local label="$2"

    if [ -d "$path" ]; then
        echo "Suppression de ${label}..."
        rm -rf -- "$path"
    fi
}

remove_file_if_present() {
    local path="$1"
    local label="$2"

    if [ -f "$path" ] || [ -L "$path" ]; then
        echo "Suppression de ${label}..."
        rm -f -- "$path"
    fi
}

# Artefacts de compilation et de tests locaux. Le SDK développeur généré
# vit sous build/ et est donc couvert ici sans règle spécifique.
remove_dir_if_present "${SCRIPT_DIR}/build" "build/"
remove_dir_if_present "${SCRIPT_DIR}/test" "test/"

# Hérité de l'ancien emplacement de miniz, au cas où il traîne encore.
remove_dir_if_present "${SCRIPT_DIR}/src/third_party" "src/third_party/ (legacy)"

if [ "$REMOVE_ALL" -eq 1 ]; then
    # Sources et artefacts reconstruisibles explicitement connus du projet.
    remove_dir_if_present "${SCRIPT_DIR}/downloads" "downloads/"
    remove_dir_if_present "${SCRIPT_DIR}/dist" "dist/"

    # Journaux stables : le journal FLTK n'est plus produit après 2.23.0,
    # mais --all continue de supprimer cet artefact legacy s'il existe.
    remove_file_if_present "${SCRIPT_DIR}/babet-tests.txt" "babet-tests.txt"
    remove_file_if_present "${SCRIPT_DIR}/native-arch-validation.log" "native-arch-validation.log"
    remove_file_if_present "${SCRIPT_DIR}/babet-fltk-tests.txt" "babet-fltk-tests.txt"

    # Scratch files de release historiques/locaux explicitement ignorés par Git.
    remove_file_if_present "${SCRIPT_DIR}/MODIFIED_FILES.txt" "MODIFIED_FILES.txt"
    shopt -s nullglob
    release_notes=("${SCRIPT_DIR}"/GITHUB_RELEASE_*.md)
    shopt -u nullglob
    for release_note in "${release_notes[@]}"; do
        remove_file_if_present "$release_note" "$(basename "$release_note")"
    done
fi

echo "Terminé."
