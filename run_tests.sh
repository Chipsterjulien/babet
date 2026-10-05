#!/bin/bash
# run_tests.sh — compile le projet puis teste les deux modes d'exécution
# (mode dossier et mode exécutable embarqué), avec un bilan global.
#
# Codes de sortie : 0 si les tests passent, 1 pour un échec de validation,
# 2 pour un échec de compilation ou un binaire manquant après build.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="babet"
TEST_DIR="${SCRIPT_DIR}/test"
EXAMPLES_DIR="${SCRIPT_DIR}/examples"
SANITIZER_MODE="OFF"
SANITIZERS_ENABLED=0
ASAN_ENABLED=0
RELEASE_VALIDATION=0
BUILD_FAILURE_EXIT_CODE=2

# Maintainer prebuilt-validation hook. When these variables are set, the test
# harness exercises an already-built binary/build directory instead of invoking
# build_local.sh. Candidate 11 introduced the hook; the final GC integration
# keeps it generic for focused release validation without changing normal use.
PREBUILT_BINARY_NORMAL="${BABET_TEST_PREBUILT_BINARY_NORMAL:-}"
PREBUILT_BUILD_DIR_NORMAL="${BABET_TEST_PREBUILT_BUILD_DIR_NORMAL:-}"
PREBUILT_BINARY_SANITIZERS="${BABET_TEST_PREBUILT_BINARY_SANITIZERS:-}"
PREBUILT_BUILD_DIR_SANITIZERS="${BABET_TEST_PREBUILT_BUILD_DIR_SANITIZERS:-}"
PREBUILT_BINARY_UBSAN="${BABET_TEST_PREBUILT_BINARY_UBSAN:-}"
PREBUILT_BUILD_DIR_UBSAN="${BABET_TEST_PREBUILT_BUILD_DIR_UBSAN:-}"

# Exécute toute invocation top-level dans un pseudo-terminal afin que les
# outils qui colorent uniquement leur sortie interactive conservent leurs
# couleurs à l'écran. Le flux brut est enregistré temporairement, puis les
# séquences ANSI et les retours chariot du pseudo-terminal sont retirés avant
# la publication atomique du journal texte. Les appels internes de --release
# héritent de BABET_TEST_LOG_ACTIVE et ne créent donc pas de journaux imbriqués.
run_with_log() {
    local test_log=""
    local raw_log=""
    local clean_log=""
    local test_command=""
    local -a pipeline_status=()
    local test_rc=1
    local tee_rc=1
    local clean_rc=0

    # Le nom reste volontairement identique afin que le journal à transmettre
    # soit toujours évident. Chaque invocation top-level de run_tests.sh
    # remplace atomiquement le journal précédent.
    test_log="${SCRIPT_DIR}/${PROJECT_NAME}-tests.txt"
    raw_log=$(mktemp "${TMPDIR:-/tmp}/${PROJECT_NAME}-tests-log.XXXXXX") || {
        echo "ÉCHEC : impossible de créer le journal temporaire."
        return 1
    }
    clean_log=$(mktemp "${test_log}.tmp.XXXXXX") || {
        echo "ÉCHEC : impossible de préparer ${test_log}."
        rm -f -- "${raw_log}"
        return 1
    }
    trap 'rm -f -- "${raw_log}" "${clean_log}"' EXIT

    # %q protège le chemin du script et tous les arguments lors du passage par
    # l'option --command de util-linux script.
    printf -v test_command '%q ' bash "${BASH_SOURCE[0]}" "$@"

    echo "Journal sans couleurs : ${test_log}"
    echo

    export BABET_TEST_LOG_ACTIVE=1
    if command -v script >/dev/null 2>&1; then
        script --quiet --return --flush \
            --command "${test_command}" /dev/null \
            | tee "${raw_log}"
        pipeline_status=("${PIPESTATUS[@]}")
        test_rc=${pipeline_status[0]}
        tee_rc=${pipeline_status[1]}
    else
        echo "AVERTISSEMENT : commande 'script' introuvable ; " \
             "les couleurs automatiques peuvent être désactivées."
        bash "${BASH_SOURCE[0]}" "$@" 2>&1 | tee "${raw_log}"
        pipeline_status=("${PIPESTATUS[@]}")
        test_rc=${pipeline_status[0]}
        tee_rc=${pipeline_status[1]}
    fi
    unset BABET_TEST_LOG_ACTIVE

    # Retire les séquences OSC (notamment les hyperliens), les séquences CSI
    # (dont les couleurs SGR) et les CR ajoutés par le pseudo-terminal.
    LC_ALL=C sed -E \
        -e $'s/\x1B\\][^\a]*(\a|\x1B\\\\)//g' \
        -e $'s/\x1B\\[[0-?]*[ -\\/]*[@-~]//g' \
        -e $'s/\r//g' \
        "${raw_log}" > "${clean_log}" || clean_rc=$?

    if [ ${clean_rc} -eq 0 ]; then
        if ! mv -f -- "${clean_log}" "${test_log}"; then
            clean_rc=1
        fi
    fi

    rm -f -- "${raw_log}"
    if [ -f "${clean_log}" ]; then
        rm -f -- "${clean_log}"
    fi
    trap - EXIT

    echo
    if [ ${clean_rc} -eq 0 ]; then
        echo "Journal sans couleurs enregistré : ${test_log}"
    else
        echo "ÉCHEC : impossible d'enregistrer le journal sans couleurs."
    fi

    if [ ${test_rc} -ne 0 ]; then
        return "${test_rc}"
    fi
    if [ ${tee_rc} -ne 0 ]; then
        echo "ÉCHEC : la copie du flux de validation a échoué."
        return "${tee_rc}"
    fi
    return "${clean_rc}"
}

for arg in "$@"; do
    case "$arg" in
        --sanitizers)
            if [ "${SANITIZER_MODE}" != "OFF" ] && [ "${SANITIZER_MODE}" != "ASAN_UBSAN" ]; then
                echo "Les options --sanitizers et --ubsan ne peuvent pas être combinées."
                exit 1
            fi
            SANITIZER_MODE="ASAN_UBSAN"
            ;;
        --ubsan)
            if [ "${SANITIZER_MODE}" != "OFF" ] && [ "${SANITIZER_MODE}" != "UBSAN" ]; then
                echo "Les options --sanitizers et --ubsan ne peuvent pas être combinées."
                exit 1
            fi
            SANITIZER_MODE="UBSAN"
            ;;
        --release)
            RELEASE_VALIDATION=1
            ;;
        --help|-h)
            echo "Usage: $0 [--sanitizers|--ubsan|--release]"
            echo "  (par défaut)   Build normal + tests complets + babet-tests.txt"
            echo "  --sanitizers   Build ASan/UBSan + tests compatibles + babet-tests.txt"
            echo "  --ubsan        Build UBSan seul + tests compatibles + babet-tests.txt"
            echo "  --release      Validation pré-release complète + babet-tests.txt"
            exit 0
            ;;
        *)
            echo "Argument inconnu : $arg"
            echo "Voir $0 --help"
            exit 1
            ;;
    esac
done

case "${SANITIZER_MODE}" in
    ASAN_UBSAN)
        SANITIZERS_ENABLED=1
        ASAN_ENABLED=1
        ;;
    UBSAN)
        SANITIZERS_ENABLED=1
        ;;
    OFF)
        ;;
esac

if [ "${RELEASE_VALIDATION}" -eq 1 ] && [ "${SANITIZERS_ENABLED}" -eq 1 ]; then
    echo "L'option --release ne peut pas être combinée avec un mode sanitizer explicite."
    exit 1
fi

# Tous les modes top-level produisent le même journal texte complet.
# En --release, validate_release.sh rappelle run_tests.sh avec cette variable
# héritée, ce qui évite tout wrapper/journal imbriqué.
if [ "${BABET_TEST_LOG_ACTIVE:-0}" -ne 1 ]; then
    run_with_log "$@"
    exit $?
fi

if [ "${RELEASE_VALIDATION}" -eq 1 ]; then
    exec bash "${SCRIPT_DIR}/validate_release.sh"
fi

print_preflight_stage() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

print_preflight_stage "Préflight — modularisation du harnais Lua"
if ! bash "${SCRIPT_DIR}/tools/test_selftest_layout.sh"; then
    echo "ÉCHEC : le préflight de modularisation du harnais Lua a échoué."
    exit 1
fi

print_preflight_stage "Préflight — comptage explicite des auto-tests"
if ! bash "${SCRIPT_DIR}/tools/test_selftest_accounting.sh"; then
    echo "ÉCHEC : le préflight de comptage des auto-tests a échoué."
    exit 1
fi

print_preflight_stage "Préflight — nettoyage des artefacts locaux"
if ! bash "${SCRIPT_DIR}/tools/test_clear_code_contracts.sh"; then
    echo "ÉCHEC : le préflight de nettoyage des artefacts locaux a échoué."
    exit 1
fi

print_preflight_stage "Préflight — chemins et liens symboliques des arborescences"
if ! bash "${SCRIPT_DIR}/tools/test_filesystem_symlink_contracts.sh"; then
    echo "ÉCHEC : le contrat des chemins d'arborescences a échoué."
    exit 1
fi

print_preflight_stage "Préflight — fonctions hôte Lua -> C/C++"
if ! bash "${SCRIPT_DIR}/tools/test_host_function_contracts.sh"; then
    echo "ÉCHEC : le préflight des fonctions hôte Lua -> C/C++ a échoué."
    exit 1
fi

print_preflight_stage "Préflight — plugins natifs C/C++"
if ! bash "${SCRIPT_DIR}/tools/test_native_plugin_contracts.sh"; then
    echo "ÉCHEC : le préflight des plugins natifs C/C++ a échoué."
    exit 1
fi

print_preflight_stage "Préflight — contrat d'embedding C/libbabet"
if ! bash "${SCRIPT_DIR}/tools/test_embedding_contracts.sh"; then
    echo "ÉCHEC : le préflight du contrat d'embedding C/libbabet a échoué."
    exit 1
fi

print_preflight_stage "Préflight — builder SDK développeur"
if ! bash "${SCRIPT_DIR}/tools/test_sdk_builder.sh"; then
    echo "ÉCHEC : le préflight du builder SDK développeur a échoué."
    exit 1
fi

print_preflight_stage "Préflight — contrat GUI dynamique optionnelle"
if ! bash "${SCRIPT_DIR}/tools/test_gui_design_contract.sh"; then
    echo "ÉCHEC : le préflight du contrat GUI dynamique a échoué."
    exit 1
fi

print_preflight_stage "Préflight — implémentation GUI GTK4 dynamique"
if ! bash "${SCRIPT_DIR}/tools/test_gui_runtime_contracts.sh"; then
    echo "ÉCHEC : le préflight de l'implémentation GUI GTK4 a échoué."
    exit 1
fi

print_preflight_stage "Préflight — widgets et boucle GUI GTK4"
if ! bash "${SCRIPT_DIR}/tools/test_gui_widget_contracts.sh"; then
    echo "ÉCHEC : le préflight des widgets GUI GTK4 a échoué."
    exit 1
fi

print_preflight_stage "Régression — chargeur GTK4 dynamique isolé"
if ! bash "${SCRIPT_DIR}/tools/test_gui_gtk_loader.sh"; then
    echo "ÉCHEC : la régression du chargeur GTK4 dynamique a échoué."
    exit 1
fi

print_preflight_stage "Préflight — contrat de conception ncursesw"
if ! bash "${SCRIPT_DIR}/tools/test_ncurses_design_contract.sh"; then
    echo "ÉCHEC : le préflight du contrat de conception ncursesw a échoué."
    exit 1
fi

print_preflight_stage "Préflight — implémentation ncursesw"
if ! bash "${SCRIPT_DIR}/tools/test_ncurses_runtime_contracts.sh"; then
    echo "ÉCHEC : le préflight de l'implémentation ncursesw a échoué."
    exit 1
fi

print_preflight_stage "Préflight — bootstrap ncursesw"
if ! bash "${SCRIPT_DIR}/tools/test_ncurses_bootstrap.sh"; then
    echo "ÉCHEC : le préflight du bootstrap ncursesw a échoué."
    exit 1
fi

print_preflight_stage "Préflight — bootstrap Zstandard"
if ! bash "${SCRIPT_DIR}/tools/test_zstd_bootstrap.sh"; then
    echo "ÉCHEC : le préflight du bootstrap Zstandard a échoué."
    exit 1
fi

print_preflight_stage "Préflight — décodage des buffers inotify"
if ! bash "${SCRIPT_DIR}/tools/test_inotify_buffer.sh"; then
    echo "ÉCHEC : le préflight du décodage inotify a échoué."
    exit 1
fi

print_preflight_stage "Préflight — budgets de sérialisation workers"
if ! bash "${SCRIPT_DIR}/tools/test_workers_serialization_budget.sh"; then
    echo "ÉCHEC : le préflight des budgets workers a échoué."
    exit 1
fi

print_preflight_stage "Préflight — sauvegarde SQLite"
if ! bash "${SCRIPT_DIR}/tools/test_sqlite_backup_contracts.sh"; then
    echo "ÉCHEC : le préflight de sauvegarde SQLite a échoué."
    exit 1
fi

print_preflight_stage "Préflight — sockets Unix"
if ! bash "${SCRIPT_DIR}/tools/test_unix_socket_contracts.sh"; then
    echo "ÉCHEC : le préflight des sockets Unix a échoué."
    exit 1
fi

print_preflight_stage "Préflight — WebSocket RFC 6455"
if ! bash "${SCRIPT_DIR}/tools/test_websocket_contracts.sh"; then
    echo "ÉCHEC : le préflight WebSocket a échoué."
    exit 1
fi

print_preflight_stage "Préflight — confinement find xdev"
if ! bash "${SCRIPT_DIR}/tools/test_find_xdev_contracts.sh"; then
    echo "ÉCHEC : le préflight de babet.find xdev a échoué."
    exit 1
fi

print_preflight_stage "Préflight — robustesse find sur arborescence vivante"
if ! bash "${SCRIPT_DIR}/tools/test_find_disappearance_contracts.sh"; then
    echo "ÉCHEC : le préflight de robustesse de babet.find a échoué."
    exit 1
fi

print_preflight_stage "Préflight — orchestration de validation"
if ! bash "${SCRIPT_DIR}/tools/test_release_fail_fast.sh"; then
    echo "ÉCHEC : le préflight de l'orchestration de validation a échoué."
    exit 1
fi

print_preflight_stage "Préflight — modes sanitizer de release"
if ! bash "${SCRIPT_DIR}/tools/test_sanitizer_modes.sh"; then
    echo "ÉCHEC : le préflight des modes sanitizer a échoué."
    exit 1
fi

print_preflight_stage "Préflight — artefact SDK développeur de release"
if ! bash "${SCRIPT_DIR}/tools/test_release_sdk.sh"; then
    echo "ÉCHEC : le préflight de l'artefact SDK développeur a échoué."
    exit 1
fi

print_preflight_stage "Préflight — validation native de release par architecture"
if ! bash "${SCRIPT_DIR}/tools/test_native_arch_release_contracts.sh"; then
    echo "ÉCHEC : le préflight de validation native par architecture a échoué."
    exit 1
fi

print_preflight_stage "Préflight — vue d'ensemble de l'architecture"
if ! bash "${SCRIPT_DIR}/tools/test_architecture_contracts.sh"; then
    echo "ÉCHEC : le préflight de la vue d'ensemble de l'architecture a échoué."
    exit 1
fi

print_preflight_stage "Préflight — cohérence du builder de release"
if ! bash "${SCRIPT_DIR}/tools/test_release_builder_contracts.sh"; then
    echo "ÉCHEC : le préflight du builder de release a échoué."
    exit 1
fi

print_preflight_stage "Préflight — déploiement sans compression du runtime"
if ! python3 "${SCRIPT_DIR}/tools/test_deploy.py"; then
    echo "ÉCHEC : le contrôle du déploiement a échoué."
    exit 1
fi

print_preflight_stage "Préflight — étude taille et profils de build"
if ! bash "${SCRIPT_DIR}/tools/test_size_audit_contracts.sh"; then
    echo "ÉCHEC : le préflight de l'étude taille/profils a échoué."
    exit 1
fi

print_preflight_stage "Préflight — builds différentiels de taille"
if ! bash "${SCRIPT_DIR}/tools/test_size_differential_contracts.sh"; then
    echo "ÉCHEC : le préflight des builds différentiels de taille a échoué."
    exit 1
fi

print_preflight_stage "Préflight — Candidate 9 OpenSSL"
if ! bash "${SCRIPT_DIR}/tools/test_candidate9_contracts.sh"; then
    echo "ÉCHEC : le préflight Candidate 9 OpenSSL a échoué."
    exit 1
fi

print_preflight_stage "Préflight — Candidate 10 GC de sections"
if ! bash "${SCRIPT_DIR}/tools/test_candidate10_contracts.sh"; then
    echo "ÉCHEC : le préflight Candidate 10 GC de sections a échoué."
    exit 1
fi

print_preflight_stage "Préflight — Candidate 11 adoption GC"
if ! bash "${SCRIPT_DIR}/tools/test_candidate11_contracts.sh"; then
    echo "ÉCHEC : le préflight Candidate 11 adoption GC a échoué."
    exit 1
fi

print_preflight_stage "Préflight — contrat GC de sections en production"
if ! bash "${SCRIPT_DIR}/tools/test_gc_sections_contracts.sh"; then
    echo "ÉCHEC : le préflight GC de sections en production a échoué."
    exit 1
fi

print_preflight_stage "Préflight — frontières d'exception C++/Lua"
if ! bash "${SCRIPT_DIR}/tools/test_exception_boundaries.sh"; then
    echo "ÉCHEC : le préflight des frontières d'exception a échoué."
    exit 1
fi

print_preflight_stage "Préflight — préparation parent du lancement"
if ! bash "${SCRIPT_DIR}/tools/test_process_launch_preparation.sh"; then
    echo "ÉCHEC : le préflight de préparation du lancement a échoué."
    exit 1
fi

BUILD_ARGS=()
PREBUILT_BINARY=""
PREBUILT_BUILD_DIR=""
case "${SANITIZER_MODE}" in
    ASAN_UBSAN)
        BUILD_ARGS+=(--sanitizers)
        PREBUILT_BINARY="${PREBUILT_BINARY_SANITIZERS}"
        PREBUILT_BUILD_DIR="${PREBUILT_BUILD_DIR_SANITIZERS}"
        # Les valeurs fournies par l'utilisateur restent prioritaires.
        export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1}"
        export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
        ;;
    UBSAN)
        BUILD_ARGS+=(--ubsan)
        PREBUILT_BINARY="${PREBUILT_BINARY_UBSAN}"
        PREBUILT_BUILD_DIR="${PREBUILT_BUILD_DIR_UBSAN}"
        export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
        ;;
    OFF)
        PREBUILT_BINARY="${PREBUILT_BINARY_NORMAL}"
        PREBUILT_BUILD_DIR="${PREBUILT_BUILD_DIR_NORMAL}"
        ;;
esac

# --- 1. Compilation -------------------------------------------------
if [ -n "${PREBUILT_BINARY}" ]; then
    if [ ! -x "${PREBUILT_BINARY}" ]; then
        echo "ÉCHEC : binaire préconstruit absent/non exécutable : ${PREBUILT_BINARY}"
        exit "${BUILD_FAILURE_EXIT_CODE}"
    fi
    if [ -z "${PREBUILT_BUILD_DIR}" ] || [ ! -d "${PREBUILT_BUILD_DIR}" ]; then
        echo "ÉCHEC : build CMake préconstruit absent : ${PREBUILT_BUILD_DIR}"
        exit "${BUILD_FAILURE_EXIT_CODE}"
    fi
    BINARY="${PREBUILT_BINARY}"
    echo "### Validation d'un binaire préconstruit ###"
    echo "Binaire : ${BINARY}"
    echo "Build CMake associé : ${PREBUILT_BUILD_DIR}"
else
    case "${SANITIZER_MODE}" in
        ASAN_UBSAN) echo "### Compilation (ASan + UBSan) ###" ;;
        UBSAN) echo "### Compilation (UBSan) ###" ;;
        OFF) echo "### Compilation ###" ;;
    esac
    if ! bash "${SCRIPT_DIR}/build_local.sh" "${BUILD_ARGS[@]}"; then
        echo "ÉCHEC : la compilation a échoué."
        exit "${BUILD_FAILURE_EXIT_CODE}"
    fi
    BINARY="${TEST_DIR}/${PROJECT_NAME}"
fi
echo ""

if [ ! -f "${BINARY}" ]; then
    echo "ÉCHEC : binaire introuvable après compilation (${BINARY})."
    exit "${BUILD_FAILURE_EXIT_CODE}"
fi

# Ordinary production builds must prove that the adopted GC/OpenSSL contract is
# present in the actual CMake/link/OpenSSL state. Maintainer prebuilt candidates
# intentionally skip this production-only check.
if [ -z "${PREBUILT_BINARY}" ]; then
    case "${SANITIZER_MODE}" in
        ASAN_UBSAN) GC_BUILD_DIR="${SCRIPT_DIR}/build/project_build_sanitizers" ;;
        UBSAN) GC_BUILD_DIR="${SCRIPT_DIR}/build/project_build_ubsan" ;;
        OFF) GC_BUILD_DIR="${SCRIPT_DIR}/build/project_build" ;;
    esac
    print_preflight_stage "Régression — contrat GC de sections du build réel"
    if ! bash "${SCRIPT_DIR}/tools/test_gc_sections_runtime.sh"         "${BINARY}" "${GC_BUILD_DIR}"; then
        echo "ÉCHEC : le build réel n'applique pas le contrat GC/OpenSSL adopté."
        exit 1
    fi
fi

print_preflight_stage "Régression — packaging --create-exe"
if ! bash "${SCRIPT_DIR}/tests/test_packaging.sh" "${BINARY}"; then
    echo "ÉCHEC : les contrats de packaging --create-exe ont échoué."
    exit 1
fi

print_preflight_stage "Régression — GUI GTK4 dynamique et --create-exe"
if ! bash "${SCRIPT_DIR}/tools/test_gui_runtime.sh" "${BINARY}"; then
    echo "ÉCHEC : la régression runtime GUI GTK4 a échoué."
    exit 1
fi

print_preflight_stage "Régression — état processus après chargement GTK"
if ! python3 "${SCRIPT_DIR}/tools/test_gui_process_state.py" "${BINARY}"; then
    echo "ÉCHEC : la protection de l'état processus après chargement GTK a échoué."
    exit 1
fi

print_preflight_stage "Régression — analyseur de taille du linker"
if ! bash "${SCRIPT_DIR}/tools/test_size_audit_runtime.sh" "${BINARY}"; then
    echo "ÉCHEC : la régression de l'analyseur de taille a échoué."
    exit 1
fi

print_preflight_stage "Régression — embedding C/libbabet"
EMBEDDING_ARGS=("${BINARY}")
case "${SANITIZER_MODE}" in
    ASAN_UBSAN) EMBEDDING_ARGS+=(--sanitizers) ;;
    UBSAN) EMBEDDING_ARGS+=(--ubsan) ;;
esac
if [ -n "${PREBUILT_BUILD_DIR}" ]; then
    if ! BABET_EMBEDDING_BUILD_DIR="${PREBUILT_BUILD_DIR}" \
        bash "${SCRIPT_DIR}/tools/test_embedding_runtime.sh" "${EMBEDDING_ARGS[@]}"; then
        echo "ÉCHEC : la régression runtime d'embedding C/libbabet a échoué."
        exit 1
    fi
else
    if ! bash "${SCRIPT_DIR}/tools/test_embedding_runtime.sh" "${EMBEDDING_ARGS[@]}"; then
        echo "ÉCHEC : la régression runtime d'embedding C/libbabet a échoué."
        exit 1
    fi
fi

print_preflight_stage "Régression — plugins natifs C/C++"
if ! bash "${SCRIPT_DIR}/tools/test_runtime_surface.sh" "${BINARY}"; then
    echo "ÉCHEC : la surface runtime babet.* est incomplète ou inattendue."
    exit 1
fi

if ! bash "${SCRIPT_DIR}/tools/test_native_plugin_runtime.sh" "${BINARY}"; then
    echo "ÉCHEC : la régression runtime des plugins natifs C/C++ a échoué."
    exit 1
fi

print_preflight_stage "Régression — nettoyage OOM Lua / RAII C++"
OOM_ARGS=()
case "${SANITIZER_MODE}" in
    ASAN_UBSAN) OOM_ARGS+=(--sanitizers) ;;
    UBSAN) OOM_ARGS+=(--ubsan) ;;
esac
if ! bash "${SCRIPT_DIR}/tools/test_lua_longjmp_oom.sh" "${OOM_ARGS[@]}"; then
    echo "ÉCHEC : le test OOM Lua / RAII C++ a échoué."
    exit 1
fi

print_preflight_stage "Régression — erreurs mémoire des modules embarqués"
if ! bash "${SCRIPT_DIR}/tools/test_embedded_oom.sh" "${OOM_ARGS[@]}"; then
    echo "ÉCHEC : le nettoyage mémoire/archives des modules embarqués a échoué."
    exit 1
fi

print_preflight_stage "Régression — mergeTables, parcours et erreurs mémoire"
if ! bash "${SCRIPT_DIR}/tools/test_merge_tables.sh" "${OOM_ARGS[@]}"; then
    echo "ÉCHEC : la régression de mergeTables a échoué."
    exit 1
fi

print_preflight_stage "Régression — commandes standard des workers, ressources et erreurs mémoire"
if ! bash "${SCRIPT_DIR}/tools/test_worker_process_native.sh" "${OOM_ARGS[@]}"; then
    echo "ÉCHEC : la régression native des commandes standard des workers a échoué."
    exit 1
fi

print_preflight_stage "Régression — spawn interactif sous pseudo-terminal"
if ! bash "${SCRIPT_DIR}/tools/test_spawn_pty.sh" "${BINARY}"; then
    echo "ÉCHEC : le test PTY de babet.spawn a échoué."
    exit 1
fi

print_preflight_stage "Régression — ncursesw sous pseudo-terminal"
if ! bash "${SCRIPT_DIR}/tools/test_curses_pty.sh" "${BINARY}"; then
    echo "ÉCHEC : le test PTY/runtime ncursesw a échoué."
    exit 1
fi

print_preflight_stage "Régression — arrêt curses par callback et sources de copie"
if ! bash "${SCRIPT_DIR}/tools/test_runtime_safety_native.sh" "${OOM_ARGS[@]}"; then
    echo "ÉCHEC : les régressions natives curses/sources de copie ont échoué."
    exit 1
fi

print_preflight_stage "Régression — os.exit, finaliseurs et restauration du terminal"
if ! python3 "${SCRIPT_DIR}/tools/test_cli_exit.py" "${BINARY}"; then
    echo "ÉCHEC : le test de sortie contrôlée du CLI a échoué."
    exit 1
fi

print_preflight_stage "Régression — client WebSocket RFC 6455"
if ! bash "${SCRIPT_DIR}/tools/test_websocket_runtime.sh" "${BINARY}"; then
    echo "ÉCHEC : le test runtime WebSocket a échoué."
    exit 1
fi

print_preflight_stage "Régression — module inspect.lua embarqué"
if ! "${BINARY}" "${SCRIPT_DIR}/tools/test_inspect_runtime.lua"; then
    echo "ÉCHEC : les contrats runtime du module inspect.lua ont échoué."
    exit 1
fi

# Les tests 4, 6 et 8 injectent une bibliothèque de test avec LD_PRELOAD.
# Pour un binaire ASan, le runtime AddressSanitizer doit rester le premier
# objet chargé ; sinon le loader arrête le processus avant même main().
ASAN_RUNTIME=""
if [ "${ASAN_ENABLED}" -eq 1 ]; then
    ASAN_RUNTIME=$(ldd "${BINARY}" 2>/dev/null \
        | awk '/asan/ && $3 ~ /^\// { print $3; exit }')
    if [ -z "${ASAN_RUNTIME}" ] || [ ! -f "${ASAN_RUNTIME}" ]; then
        echo "ÉCHEC : runtime ASan dynamique introuvable pour ${BINARY}."
        exit 1
    fi
fi

babet_test_preload() {
    local hook="$1"
    local value="${hook}"
    if [ -n "${ASAN_RUNTIME}" ]; then
        value="${ASAN_RUNTIME}:${value}"
    fi
    if [ -n "${LD_PRELOAD:-}" ]; then
        value="${value}:${LD_PRELOAD}"
    fi
    printf '%s' "${value}"
}

print_preflight_stage "Régression — disparition concurrente dans babet.find"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    bash "${SCRIPT_DIR}/tools/test_find_disappearing_directory.sh" "${BINARY}"; then
    echo "ÉCHEC : le test de disparition concurrente dans babet.find a échoué."
    exit 1
fi

print_preflight_stage "Régression — conservation des données dans moveTree"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    python3 "${SCRIPT_DIR}/tools/test_tree_safety.py" "${BINARY}"; then
    echo "ÉCHEC : la régression de conservation des arborescences a échoué."
    exit 1
fi

print_preflight_stage "Régression — SIGPIPE TLS et signaux des processus enfants"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    python3 "${SCRIPT_DIR}/tools/test_signal_runtime.py" "${BINARY}"; then
    echo "ÉCHEC : la régression des signaux réseau/processus a échoué."
    exit 1
fi

print_preflight_stage "Régression — autorités TLS, isolation des CA et identité serveur"
if ! python3 "${SCRIPT_DIR}/tools/test_ca_trust.py" "${BINARY}"; then
    echo "ÉCHEC : la régression des politiques de confiance TLS a échoué."
    exit 1
fi

print_preflight_stage "Régression — envois abandonnés et tampon de réception"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    python3 "${SCRIPT_DIR}/tools/test_network_recovery.py" "${BINARY}"; then
    echo "ÉCHEC : la régression des états réseau a échoué."
    exit 1
fi

print_preflight_stage "Régression — identité, loaders et limites des exécutables embarqués"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    python3 "${SCRIPT_DIR}/tools/test_embedded_runtime.py" "${BINARY}"; then
    echo "ÉCHEC : la régression des exécutables embarqués a échoué."
    exit 1
fi

print_preflight_stage "Régression — hook initial et erreurs de lecture du binaire"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    python3 "${SCRIPT_DIR}/tools/test_startup_state.py" "${BINARY}"; then
    echo "ÉCHEC : la régression du hook initial ou de l'identité du binaire a échoué."
    exit 1
fi

print_preflight_stage "Régression — identité embarquée et applications endommagées"
if ! BABET_TEST_ASAN_RUNTIME="${ASAN_RUNTIME}" \
    python3 "${SCRIPT_DIR}/tools/test_image_identity.py" "${BINARY}"; then
    echo "ÉCHEC : la régression d'identité des exécutables a échoué."
    exit 1
fi

print_preflight_stage "Régression — fermeture déterministe des curseurs SQLite"
if ! python3 "${SCRIPT_DIR}/tools/test_lifecycle_runtime.py" "${BINARY}"; then
    echo "ÉCHEC : la régression du cycle de vie SQLite a échoué."
    exit 1
fi

print_preflight_stage "Régression — sortie des workers et locale partagée"
if ! python3 "${SCRIPT_DIR}/tools/test_worker_process_state.py" "${BINARY}"; then
    echo "ÉCHEC : la régression de l'état processus des workers a échoué."
    exit 1
fi

print_preflight_stage "Régression — commandes standard et signaux des workers"
if ! python3 "${SCRIPT_DIR}/tools/test_worker_standard_process.py" "${BINARY}"; then
    echo "ÉCHEC : la régression des commandes standard des workers a échoué."
    exit 1
fi

modes_ok=0
modes_total=0

selftest_total_pass() {
    printf '%s\n' "$1" | awk '
        /^Résultat : [0-9]+ PASS \/ [0-9]+ FAIL$/ { print $3; exit }
    '
}

selftest_category_pass() {
    local output="$1"
    local category="$2"
    printf '%s\n' "${output}" | awk -v marker="[${category}]" '
        $1 == marker {
            for (i = 2; i <= NF; ++i) {
                if ($i == "PASS") { print $(i - 1); exit }
            }
        }
    '
}

selftest_category_pass_or_zero() {
    local value
    value=$(selftest_category_pass "$1" "$2")
    if [ -z "${value}" ]; then
        value=0
    fi
    printf '%s' "${value}"
}

validate_selftest_accounting() {
    local output="$1"
    local label="$2"
    local total common folder embedded single_run accounted

    total=$(selftest_total_pass "${output}")
    common=$(selftest_category_pass "${output}" "common")
    folder=$(selftest_category_pass_or_zero "${output}" "folder")
    embedded=$(selftest_category_pass_or_zero "${output}" "embedded")
    single_run=$(selftest_category_pass_or_zero "${output}" "single-run")

    if [ -z "${total}" ] || [ -z "${common}" ]; then
        echo "  -> comptage ${label} : ÉCHEC (résumé de catégories absent)"
        return 1
    fi

    accounted=$((common + folder + embedded + single_run))
    if [ "${accounted}" -ne "${total}" ]; then
        echo "  -> comptage ${label} : ÉCHEC (${accounted} tests classés pour ${total} PASS)"
        return 1
    fi

    return 0
}

validate_cross_mode_selftest_accounting() {
    local folder_output="$1"
    local embedded_output="$2"
    local embedded_path_output="$3"
    local accounting_ok=1
    local folder_common embedded_common embedded_path_common
    local folder_specific folder_embedded folder_single
    local embedded_folder embedded_specific embedded_single
    local embedded_path_folder embedded_path_specific embedded_path_single

    validate_selftest_accounting "${folder_output}" "dossier" \
        || accounting_ok=0
    validate_selftest_accounting "${embedded_output}" "embarqué" \
        || accounting_ok=0
    validate_selftest_accounting "${embedded_path_output}" "embarqué via PATH" \
        || accounting_ok=0

    folder_common=$(selftest_category_pass "${folder_output}" "common")
    embedded_common=$(selftest_category_pass "${embedded_output}" "common")
    embedded_path_common=$(
        selftest_category_pass "${embedded_path_output}" "common")

    folder_specific=$(selftest_category_pass_or_zero \
        "${folder_output}" "folder")
    folder_embedded=$(selftest_category_pass_or_zero \
        "${folder_output}" "embedded")
    folder_single=$(selftest_category_pass_or_zero \
        "${folder_output}" "single-run")

    embedded_folder=$(selftest_category_pass_or_zero \
        "${embedded_output}" "folder")
    embedded_specific=$(selftest_category_pass_or_zero \
        "${embedded_output}" "embedded")
    embedded_single=$(selftest_category_pass_or_zero \
        "${embedded_output}" "single-run")

    embedded_path_folder=$(selftest_category_pass_or_zero \
        "${embedded_path_output}" "folder")
    embedded_path_specific=$(selftest_category_pass_or_zero \
        "${embedded_path_output}" "embedded")
    embedded_path_single=$(selftest_category_pass_or_zero \
        "${embedded_path_output}" "single-run")

    if [ -z "${folder_common}" ] || [ -z "${embedded_common}" ] \
        || [ -z "${embedded_path_common}" ] \
        || [ "${folder_common}" -ne "${embedded_common}" ] \
        || [ "${embedded_common}" -ne "${embedded_path_common}" ]; then
        echo "  -> tests communs : ÉCHEC " \
             "(dossier=${folder_common:-absent}, " \
             "embarqué=${embedded_common:-absent}, " \
             "PATH=${embedded_path_common:-absent})"
        accounting_ok=0
    else
        echo "  -> tests communs : ${folder_common} PASS dans les trois exécutions"
    fi

    if [ "${folder_embedded}" -ne 0 ] \
        || [ "${embedded_folder}" -ne 0 ] \
        || [ "${embedded_single}" -ne 0 ] \
        || [ "${embedded_path_folder}" -ne 0 ] \
        || [ "${embedded_path_single}" -ne 0 ]; then
        echo "  -> catégories spécifiques : ÉCHEC " \
             "(catégorie exécutée dans le mauvais mode)"
        accounting_ok=0
    else
        echo "  -> spécifiques dossier : ${folder_specific} PASS"
        echo "  -> spécifiques embarqués : ${embedded_specific} PASS"
        echo "  -> une seule exécution : ${folder_single} PASS"
    fi

    if [ "${embedded_specific}" -ne "${embedded_path_specific}" ]; then
        echo "  -> embarqué direct/PATH : ÉCHEC " \
             "(${embedded_specific} vs ${embedded_path_specific})"
        accounting_ok=0
    fi

    [ ${accounting_ok} -eq 1 ]
}

# --- 2. Test mode dossier ------------------------------------------
echo "### Test 1/2 : mode dossier ###"
modes_total=$((modes_total + 1))

# Le test d'intégration du plafond de nœuds workers matérialise près d'un
# million de valeurs JSON. Il s'exécute une seule fois : mode dossier du build
# normal. Les autres modes forcent explicitement la variable à vide pour qu'un
# environnement utilisateur ne puisse pas répéter ce test lourd.
if [ "${SANITIZERS_ENABLED}" -eq 0 ]; then
    WORKERS_NODE_LIMIT_TEST=1
else
    WORKERS_NODE_LIMIT_TEST=
fi

dir_output=$(cd "${TEST_DIR}" \
    && BABET_TEST_WORKERS_NODE_LIMIT="${WORKERS_NODE_LIMIT_TEST}" \
        ./"${PROJECT_NAME}" . __ARG__a __ARG__b 2>&1)
dir_rc=$?

if [ ${dir_rc} -eq 0 ]; then
    echo "${dir_output}" | grep -E 'PASS /' || true
    echo "  -> mode dossier : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "--- sortie complète (mode dossier) ---"
    echo "${dir_output}"
    echo "--------------------------------------"
    echo "  -> mode dossier : ÉCHEC (code ${dir_rc})"
fi
echo ""

# --- 3. Test mode embarqué -----------------------------------------
echo "### Test 2/2 : mode embarqué ###"
modes_total=$((modes_total + 1))

ISOLATED_DIR=$(mktemp -d)
if [ -z "${ISOLATED_DIR}" ] || [ ! -d "${ISOLATED_DIR}" ]; then
    echo "  -> mode embarqué : ÉCHEC (impossible de créer un dossier temporaire)"
else
    EMBEDDED_BIN="${ISOLATED_DIR}/babet_embedded"

    # On construit l'exe embarqué à partir de examples/ (contenu Lua pur,
    # sans binaire dedans). Le résultat est placé SEUL dans un dossier isolé :
    # aucun main.lua / inspect.lua / mymod sur le disque à côté de lui.
    # S'il trouve ses fichiers, c'est forcément depuis le zip embarqué.
    if ! (cd "${SCRIPT_DIR}" && "${BINARY}" --create-exe "${EXAMPLES_DIR}" "${EMBEDDED_BIN}"); then
        echo "  -> mode embarqué : ÉCHEC (création de l'exécutable embarqué)"
    elif [ ! -f "${EMBEDDED_BIN}" ]; then
        echo "  -> mode embarqué : ÉCHEC (exécutable embarqué non produit)"
    else
        emb_output=$(cd "${ISOLATED_DIR}" \
            && BABET_TEST_WORKERS_NODE_LIMIT= \
                ./babet_embedded __ARG__a __ARG__b 2>&1)
        emb_rc=$?

        if [ ${emb_rc} -eq 0 ]; then
            echo "${emb_output}" | grep -E 'PASS /' || true
            echo "  -> mode embarqué : OK"
            modes_ok=$((modes_ok + 1))
        else
            echo "--- sortie complète (mode embarqué) ---"
            echo "${emb_output}"
            echo "---------------------------------------"
            echo "  -> mode embarqué : ÉCHEC (code ${emb_rc})"
        fi

        # Test 2bis : invocation via PATH, comme un binaire installé.
        # Reproduit "babet installé dans /usr/local/bin/ et invoqué depuis
        # ailleurs" — exactement le cas où argv[0] vaut juste le basename.
        # On lance par le nom seul (pas ./babet_embedded) avec ISOLATED_DIR
        # dans le PATH. Le cwd doit être writable pour que le harnais puisse
        # créer son sandbox, donc on utilise un autre tmpdir.
        PATH_TEST_CWD=$(mktemp -d)
        emb_path_output=$(cd "${PATH_TEST_CWD}" \
            && BABET_TEST_WORKERS_NODE_LIMIT= \
                PATH="${ISOLATED_DIR}:$PATH" \
                babet_embedded __ARG__a __ARG__b 2>&1)
        emb_path_rc=$?
        rm -rf "${PATH_TEST_CWD}"

        if [ ${emb_path_rc} -eq 0 ]; then
            echo "${emb_path_output}" | grep -E 'PASS /' || true
            echo "  -> mode embarqué via PATH : OK"
        else
            echo "--- sortie complète (mode embarqué via PATH) ---"
            echo "${emb_path_output}"
            echo "------------------------------------------------"
            echo "  -> mode embarqué via PATH : ÉCHEC (code ${emb_path_rc})"
            # Annule le succès du test embarqué précédent : si le PATH ne
            # marche pas, le mode embarqué n'est pas vraiment fonctionnel.
            if [ ${emb_rc} -eq 0 ]; then
                modes_ok=$((modes_ok - 1))
            fi
        fi

        # Le nombre total de PASS peut légitimement différer entre le runner
        # de dossier et l'application embarquée. On ne compare donc jamais un
        # delta numérique figé : chaque test s'enregistre dans une catégorie,
        # puis on vérifie que les tests communs sont identiques et que chaque
        # total est entièrement expliqué par ses catégories.
        if [ ${dir_rc} -eq 0 ] && [ ${emb_rc} -eq 0 ] \
            && [ ${emb_path_rc} -eq 0 ]; then
            echo ""
            echo "### Comptage explicite des auto-tests ###"
            if validate_cross_mode_selftest_accounting \
                "${dir_output}" "${emb_output}" "${emb_path_output}"; then
                echo "  -> comptage explicite : OK"
            else
                echo "  -> comptage explicite : ÉCHEC"
                # Le comptage fait partie du contrat du Test 2. Ne décrémente
                # qu'une fois le succès déjà enregistré du mode embarqué.
                modes_ok=$((modes_ok - 1))
            fi
        fi
    fi

    # === Test 3 : runtime ne capture pas les flags génériques =======
    # Le bug fixé en v1.8.1 : --version/-V étaient interceptés par le
    # runtime Babet AVANT que le main.lua du binaire empaqueté ne
    # soit lancé. Résultat : `mon_app --version` affichait "babet
    # X.Y.Z" au lieu de la version de mon_app.
    #
    # Test : pour les 4 flags génériques (--version, -V, --help, -h),
    # le binaire empaqueté doit transmettre l'arg au script, pas le
    # court-circuiter au runtime. Détection indirecte : si le runtime
    # interceptait, la 1re ligne serait soit "babet X.Y.Z" (cas
    # --version/-V) soit "Usage: babet ..." (cas --help/-h). Sinon
    # c'est du Lua qui s'exécute -- peu importe le résultat des tests
    # internes, ce qui compte c'est que le script ait été lancé.
    echo ""
    echo "### Test 3 : flags non interceptés par le runtime ###"
    modes_total=$((modes_total + 1))
    runtime_intercept=0

    if [ ! -f "${EMBEDDED_BIN}" ]; then
        echo "  -> ÉCHEC (binaire embarqué introuvable)"
        runtime_intercept=1
    else
        for flag in "--version" "-V" "--help" "-h"; do
            first_line=$(cd "${ISOLATED_DIR}" && \
                ./babet_embedded "${flag}" 2>&1 | head -1)
            if echo "${first_line}" | \
                    grep -qE '^babet [0-9]+\.[0-9]+\.[0-9]+$|^Usage: babet '; then
                echo "  -> ${flag} : ÉCHEC (runtime a intercepté: '${first_line}')"
                runtime_intercept=1
            else
                echo "  -> ${flag} : OK (transmis au script)"
            fi
        done
    fi

    if [ ${runtime_intercept} -eq 0 ]; then
        echo "  -> Test 3 : OK"
        modes_ok=$((modes_ok + 1))
    else
        echo "  -> Test 3 : ÉCHEC"
    fi

    rm -rf "${ISOLATED_DIR}"
fi
echo ""

# === Test 4 : --create-exe et symlinks (régression audit v21) =======
# Régressions corrigées dans create_executable.cpp et zip_utils.cpp :
#   a) fs::relative résolvait les symlinks : un module du projet qui
#      est un symlink vers un fichier HORS du projet (proj/mylib.lua
#      -> ../shared/mylib.lua) était embarqué sous le nom d'entrée
#      "../shared/mylib.lua" au lieu de "mylib.lua", et
#      require("mylib") échouait dans le binaire empaqueté.
#      Fix : entry.path().lexically_relative(dir), comme copyTree.
#   b) recursive_directory_iterator (variante jetante) était appelé
#      hors de tout try/catch : un sous-dossier illisible pendant
#      --create-exe levait une filesystem_error non attrapée ->
#      std::terminate (abort, code 134) au lieu d'une erreur propre.
#      Fix : try/catch dans createZipFromDirectory -> message + exit 1.
#   c) le temporaire de fusion reprenait tout le basename de sortie : une
#      destination pourtant valide proche de NAME_MAX échouait.
#      Fix : nom interne court et indépendant de la destination.
#   d) le parent de sortie pouvait être remplacé entre la création du
#      temporaire et rename().
#      Fix : parent épinglé et publication par renameat() sur ce descripteur.
echo "### Test 4 : --create-exe et symlinks ###"
modes_total=$((modes_total + 1))
test4_ok=1

SYMLINK_ROOT=$(mktemp -d)
if [ -z "${SYMLINK_ROOT}" ] || [ ! -d "${SYMLINK_ROOT}" ]; then
    echo "  -> ÉCHEC (impossible de créer un dossier temporaire)"
    test4_ok=0
else
    # --- 4a : projet dont un module est un symlink hors projet ------
    mkdir -p "${SYMLINK_ROOT}/shared" "${SYMLINK_ROOT}/proj"
    cat > "${SYMLINK_ROOT}/shared/mylib.lua" << 'LUA'
return { value = 42 }
LUA
    cat > "${SYMLINK_ROOT}/proj/main.lua" << 'LUA'
local ok, lib = pcall(require, "mylib")
if ok and type(lib) == "table" and lib.value == 42 then
    print("SYMLINK_OK")
else
    print("SYMLINK_FAIL: " .. tostring(lib))
    os.exit(1)
end
LUA
    ln -s ../shared/mylib.lua "${SYMLINK_ROOT}/proj/mylib.lua"

    SYM_BIN="${SYMLINK_ROOT}/app_symlink"
    # Slash final volontaire sur le dossier : forme produite par la
    # complétion tab, absorbée par lexically_relative.
    if ! "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj/" "${SYM_BIN}" > /dev/null 2>&1; then
        echo "  -> module symlinké : ÉCHEC (création du binaire)"
        test4_ok=0
    else
        sym_out=$("${SYM_BIN}" 2>&1)
        if echo "${sym_out}" | grep -q "SYMLINK_OK"; then
            echo "  -> module symlinké empaqueté : OK"
        else
            echo "  -> module symlinké : ÉCHEC (${sym_out})"
            test4_ok=0
        fi
    fi

    # --- 4b : sous-dossier illisible -> erreur propre, pas un abort -
    # chmod 000 est sans effet pour root (il lit tout) : on saute
    # proprement dans ce cas plutôt que d'échouer à tort.
    if [ "$(id -u)" -eq 0 ]; then
        echo "  -> sous-dossier illisible : SKIP (exécuté en root)"
    else
        mkdir -p "${SYMLINK_ROOT}/proj/locked"
        : > "${SYMLINK_ROOT}/proj/locked/secret.lua"
        chmod 000 "${SYMLINK_ROOT}/proj/locked"
        "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj" \
            "${SYMLINK_ROOT}/app_locked" > /dev/null 2>&1
        locked_rc=$?
        chmod 755 "${SYMLINK_ROOT}/proj/locked"
        if [ ${locked_rc} -eq 1 ]; then
            echo "  -> sous-dossier illisible : OK (erreur propre, code 1)"
        else
            echo "  -> sous-dossier illisible : ÉCHEC (code ${locked_rc}," \
                 "attendu 1 ; 134 = abort/std::terminate)"
            test4_ok=0
        fi
    fi

    # --- 4c : refus d'écraser le binaire courant (revue ChatGPT) ----
    # mergeFiles lit le binaire pendant qu'il tronque la sortie : si
    # la sortie désignait le même inode (chemin direct, symlink,
    # hardlink), --create-exe DÉTRUISAIT babet lui-même. Les deux
    # formes doivent être refusées, et le binaire rester intact
    # (hash vérifié).
    hash_before=$(sha256sum "${BINARY}" | cut -d' ' -f1)
    "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj" "${BINARY}" \
        > /dev/null 2>&1
    rc_self=$?
    ln -s "${BINARY}" "${SYMLINK_ROOT}/self_sl"
    "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj" \
        "${SYMLINK_ROOT}/self_sl" > /dev/null 2>&1
    rc_selfsl=$?
    hash_after=$(sha256sum "${BINARY}" | cut -d' ' -f1)
    if [ ${rc_self} -eq 1 ] && [ ${rc_selfsl} -eq 1 ] \
        && [ "${hash_before}" = "${hash_after}" ]; then
        echo "  -> refus d'écraser le binaire courant (direct + symlink) : OK"
    else
        echo "  -> ÉCHEC (auto-écrasement : rc=${rc_self}/${rc_selfsl}," \
             "hash $([ \"${hash_before}\" = \"${hash_after}\" ] && echo intact || echo MODIFIÉ))"
        test4_ok=0
    fi

    # --- 4d : reconstruction stable (revue ChatGPT post-v2.2.0) ----
    # L'output d'un build précédent situé DANS le dossier empaqueté
    # était réembarqué dans le ZIP : app(N+1) = Babet + projet +
    # app(N), croissance à chaque reconstruction. On construit DEUX
    # fois le même output dans le projet : la taille doit rester
    # stable (tolérance 4 Kio : horodatages du zip) et le binaire
    # doit fonctionner. C'est le test qui manquait au lot 16.
    BIN_ABS=$(readlink -f "${BINARY}")
    STAB_DIR=$(mktemp -d)
    printf 'print("stab ok")\n' > "${STAB_DIR}/main.lua"
    ( cd "${STAB_DIR}" && "${BIN_ABS}" --create-exe . app ) > /dev/null 2>&1
    size1=$(stat -c %s "${STAB_DIR}/app" 2>/dev/null || echo 0)
    ( cd "${STAB_DIR}" && "${BIN_ABS}" --create-exe . app ) > /dev/null 2>&1
    size2=$(stat -c %s "${STAB_DIR}/app" 2>/dev/null || echo 999999999)
    delta=$(( size2 - size1 ))
    [ "${delta}" -lt 0 ] && delta=$(( -delta ))
    out_stab=$("${STAB_DIR}/app" 2>/dev/null)
    if [ "${size1}" -gt 0 ] && [ "${delta}" -lt 4096 ] \
        && [ "${out_stab}" = "stab ok" ]; then
        echo "  -> reconstruction stable (output exclu du zip) : OK"
    else
        echo "  -> ÉCHEC (reconstruction : ${size1} -> ${size2} octets," \
             "delta=${delta}, sortie='${out_stab}')"
        test4_ok=0
    fi
    rm -rf "${STAB_DIR}"

    # --- 4e : métadonnées VCS exclues récursivement (lot 4) --------
    mkdir -p "${SYMLINK_ROOT}/proj/.git/objects" \
             "${SYMLINK_ROOT}/proj/nested/.svn/pristine" \
             "${SYMLINK_ROOT}/proj/nested/deeper/.hg/store"
    printf 'git-secret\n' > "${SYMLINK_ROOT}/proj/.git/objects/secret"
    printf 'svn-secret\n' > "${SYMLINK_ROOT}/proj/nested/.svn/pristine/secret"
    printf 'hg-secret\n' > "${SYMLINK_ROOT}/proj/nested/deeper/.hg/store/secret"
    printf 'normal\n' > "${SYMLINK_ROOT}/proj/nested/normal.txt"

    VCS_BIN="${SYMLINK_ROOT}/app_vcs"
    if ! "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj" "${VCS_BIN}" \
        > /dev/null 2>&1; then
        echo "  -> exclusion .git/.svn/.hg : ÉCHEC (création du binaire)"
        test4_ok=0
    else
        vcs_entries=$(unzip -Z1 "${VCS_BIN}" 2>/dev/null || true)
        if echo "${vcs_entries}" | grep -Eq '(^|/)\.(git|svn|hg)(/|$)'; then
            echo "  -> exclusion .git/.svn/.hg : ÉCHEC (métadonnées présentes)"
            test4_ok=0
        elif ! echo "${vcs_entries}" | grep -q '^nested/normal.txt$'; then
            echo "  -> exclusion .git/.svn/.hg : ÉCHEC (fichier normal absent)"
            test4_ok=0
        else
            echo "  -> exclusion récursive .git/.svn/.hg : OK"
        fi
    fi

    # --- 4f : basename de sortie proche de NAME_MAX -----------------
    # Le temporaire de fusion ne doit pas recopier tout le basename : une
    # destination valide de 244 octets échouait sinon avec ENAMETOOLONG.
    LONG_NAME=$(printf 'x%.0s' $(seq 1 244))
    LONG_BIN="${SYMLINK_ROOT}/${LONG_NAME}"
    if "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj" "${LONG_BIN}" \
        > /dev/null 2>&1 \
        && [ -x "${LONG_BIN}" ]; then
        long_out=$("${LONG_BIN}" 2>&1)
        if echo "${long_out}" | grep -q "SYMLINK_OK"; then
            echo "  -> basename de sortie long : OK"
        else
            echo "  -> basename long : ÉCHEC (sortie=${long_out})"
            test4_ok=0
        fi
    else
        echo "  -> basename long : ÉCHEC (création)"
        test4_ok=0
    fi

    # --- 4g : parent de sortie remplacé pendant la fusion -----------
    # Le hook déplace le symlink de parent au moment du fchmod du temporaire,
    # donc après l'ouverture du dossier et avant la publication. renameat()
    # doit rester attaché au parent initialement épinglé.
    cat > "${SYMLINK_ROOT}/merge_parent_race.c" << 'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*fchmod_fn)(int, mode_t);
static fchmod_fn real_fchmod_fn = 0;
static int injected = 0;

__attribute__((constructor))
static void init_merge_parent_race(void)
{
    real_fchmod_fn = (fchmod_fn)dlsym(RTLD_NEXT, "fchmod");
}

int fchmod(int fd, mode_t mode)
{
    if (!real_fchmod_fn)
    {
        return -1;
    }

    if (!injected)
    {
        const char *link = getenv("BABET_TEST_MERGE_PARENT_LINK");
        const char *next = getenv("BABET_TEST_MERGE_NEW_PARENT");
        if (link && next)
        {
            injected = 1;
            (void)unlink(link);
            const int symlink_result = symlink(next, link);
            (void)symlink_result;
        }
    }

    return real_fchmod_fn(fd, mode);
}
C

    mkdir -p "${SYMLINK_ROOT}/publish_a" "${SYMLINK_ROOT}/publish_b"
    ln -s "${SYMLINK_ROOT}/publish_a" "${SYMLINK_ROOT}/publish_link"
    if ! cc -shared -fPIC -O2 "${SYMLINK_ROOT}/merge_parent_race.c" \
        -ldl -o "${SYMLINK_ROOT}/merge_parent_race.so"; then
        echo "  -> parent de publication épinglé : ÉCHEC (preload)"
        test4_ok=0
    else
        race_out=$(LD_PRELOAD="$(babet_test_preload \
                "${SYMLINK_ROOT}/merge_parent_race.so")" \
            BABET_TEST_MERGE_PARENT_LINK="${SYMLINK_ROOT}/publish_link" \
            BABET_TEST_MERGE_NEW_PARENT="${SYMLINK_ROOT}/publish_b" \
            "${BINARY}" --create-exe "${SYMLINK_ROOT}/proj" \
                "${SYMLINK_ROOT}/publish_link/app" 2>&1)
        race_rc=$?
        if [ ${race_rc} -eq 0 ] \
            && [ -x "${SYMLINK_ROOT}/publish_a/app" ] \
            && [ ! -e "${SYMLINK_ROOT}/publish_b/app" ]; then
            published_out=$("${SYMLINK_ROOT}/publish_a/app" 2>&1)
            if echo "${published_out}" | grep -q "SYMLINK_OK"; then
                echo "  -> parent de publication épinglé malgré remplacement : OK"
            else
                echo "  -> parent épinglé : ÉCHEC (binaire=${published_out})"
                test4_ok=0
            fi
        else
            echo "  -> parent épinglé : ÉCHEC (rc=${race_rc}, sortie=${race_out})"
            test4_ok=0
        fi
    fi

    rm -rf "${SYMLINK_ROOT}"
fi

if [ ${test4_ok} -eq 1 ]; then
    echo "  -> Test 4 : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "  -> Test 4 : ÉCHEC"
fi
echo ""

# === Test 5 : exécution d'un script seul (lot 10, audit v21) ========
# `babet <fichier>` exécute le fichier directement (mode fichier) :
#   - n'importe quelle extension (shebang '#!' ignoré par Lua) ;
#   - package.path ancré au répertoire du script -> require() des
#     fichiers voisins ;
#   - arg[0] = chemin du script tel que tapé, arg[1..] = arguments.
# Avant ce lot, l'argument était toujours traité comme un dossier et
# `babet script.lua` échouait avec un message trompeur.
echo "### Test 5 : babet <script.lua> ###"
modes_total=$((modes_total + 1))
test5_ok=1

SCRIPT_ROOT=$(mktemp -d)
if [ -z "${SCRIPT_ROOT}" ] || [ ! -d "${SCRIPT_ROOT}" ]; then
    echo "  -> ÉCHEC (impossible de créer un dossier temporaire)"
    test5_ok=0
else
    # --- 5a : script .lua + module voisin + table arg ---------------
    cat > "${SCRIPT_ROOT}/helper.lua" << 'LUA'
return { greet = function(n) return "hello " .. n end }
LUA
    cat > "${SCRIPT_ROOT}/tool.lua" << 'LUA'
local h = require("helper")
print(h.greet("script"))
print("arg0=" .. tostring(arg[0]))
print("arg1=" .. tostring(arg[1]))
print("arg2=" .. tostring(arg[2]))
LUA
    t5_out=$("${BINARY}" "${SCRIPT_ROOT}/tool.lua" un deux 2>&1)
    if echo "${t5_out}" | grep -q "hello script"; then
        echo "  -> require() d'un voisin en mode fichier : OK"
    else
        echo "  -> ÉCHEC (require voisin) : ${t5_out}"
        test5_ok=0
    fi
    if echo "${t5_out}" | grep -q "arg0=.*tool\.lua" \
        && echo "${t5_out}" | grep -q "arg1=un" \
        && echo "${t5_out}" | grep -q "arg2=deux"; then
        echo "  -> table arg (arg[0]=script, arg[1..]=args) : OK"
    else
        echo "  -> ÉCHEC (table arg) : ${t5_out}"
        test5_ok=0
    fi

    # --- 5b : fichier SANS extension + shebang, exécuté directement -
    # Le shebang doit pointer un chemin SANS espace (limitation
    # kernel) : on symlinke le binaire dans le mktemp (chemin sûr),
    # ce qui valide au passage que /proc/self/exe résout le lien.
    ln -s "${BINARY}" "${SCRIPT_ROOT}/babet_bin"
    {
        printf '#!%s\n' "${SCRIPT_ROOT}/babet_bin"
        printf 'print("SHEBANG_OK arg1=" .. tostring(arg[1]))\n'
    } > "${SCRIPT_ROOT}/mytool"
    chmod +x "${SCRIPT_ROOT}/mytool"
    t5b_out=$("${SCRIPT_ROOT}/mytool" direct 2>&1)
    if echo "${t5b_out}" | grep -q "SHEBANG_OK arg1=direct"; then
        echo "  -> shebang #!babet (fichier sans extension) : OK"
    else
        echo "  -> ÉCHEC (shebang) : ${t5b_out}"
        test5_ok=0
    fi

    # --- 5c : erreurs claires ----------------------------------------
    "${BINARY}" "${SCRIPT_ROOT}/nexiste.pas" > /dev/null 2>&1
    rc_missing=$?
    err_missing=$("${BINARY}" "${SCRIPT_ROOT}/nexiste.pas" 2>&1)
    if [ ${rc_missing} -eq 1 ] \
        && echo "${err_missing}" | grep -q "n'est ni un script"; then
        echo "  -> chemin inexistant : erreur claire + code 1 : OK"
    else
        echo "  -> ÉCHEC (chemin inexistant : rc=${rc_missing}, ${err_missing})"
        test5_ok=0
    fi
    mkdir -p "${SCRIPT_ROOT}/vide"
    err_dir=$("${BINARY}" "${SCRIPT_ROOT}/vide" 2>&1)
    if echo "${err_dir}" | grep -q "main.lua introuvable"; then
        echo "  -> dossier sans main.lua : message historique : OK"
    else
        echo "  -> ÉCHEC (dossier sans main.lua) : ${err_dir}"
        test5_ok=0
    fi

    # --- 5d : main.lua est un DOSSIER (revue ChatGPT post-audit) ----
    # fs::exists laissait passer un dossier nommé main.lua : le mode
    # dossier échouait avec un "Is a directory" abscons, et
    # --create-exe produisait EN SILENCE un binaire sans main.lua
    # embarqué (le zip ne prend que les fichiers réguliers). Les deux
    # doivent désormais échouer proprement, code 1, message clair.
    mkdir -p "${SCRIPT_ROOT}/bad_project/main.lua"
    err_badrun=$("${BINARY}" "${SCRIPT_ROOT}/bad_project" 2>&1)
    rc_badrun=$?
    if [ ${rc_badrun} -eq 1 ] \
        && echo "${err_badrun}" | grep -q "main.lua introuvable"; then
        echo "  -> main.lua-dossier (exécution) : erreur claire : OK"
    else
        echo "  -> ÉCHEC (main.lua-dossier exécution : rc=${rc_badrun}, ${err_badrun})"
        test5_ok=0
    fi
    "${BINARY}" --create-exe "${SCRIPT_ROOT}/bad_project" \
        "${SCRIPT_ROOT}/bad_out" > /dev/null 2>&1
    rc_badexe=$?
    if [ ${rc_badexe} -eq 1 ] && [ ! -e "${SCRIPT_ROOT}/bad_out" ]; then
        echo "  -> main.lua-dossier (--create-exe) : refus propre : OK"
    else
        echo "  -> ÉCHEC (main.lua-dossier --create-exe : rc=${rc_badexe})"
        test5_ok=0
    fi

    rm -rf "${SCRIPT_ROOT}"
fi

if [ ${test5_ok} -eq 1 ]; then
    echo "  -> Test 5 : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "  -> Test 5 : ÉCHEC"
fi
echo ""

# === Test 6 : lancement/nettoyage processus bornés =================
# 1) Une chdir() enfant artificiellement bloquée vérifie que les délais de
#    lancement de exec(), pipeline() et spawnPipeline() restent bornés.
# 2) Les deux pipelines vérifient aussi le rollback d’une étape déjà lancée
#    lorsque l’étape suivante ne termine pas son lancement à temps.
# 3) Une erreur fatale de poll vérifie que exec() tue puis récupère l’enfant
#    sans attendre indéfiniment. Le preload reproduit ces scénarios sans
#    ajouter de hook de test au binaire de production.
echo "### Test 6 : exec/pipelines lancement et nettoyage bornés ###"
modes_total=$((modes_total + 1))
test6_ok=1

EXEC_ROOT=$(mktemp -d)
if [ -z "${EXEC_ROOT}" ] || [ ! -d "${EXEC_ROOT}" ]; then
    echo "  -> ÉCHEC (impossible de créer un dossier temporaire)"
    test6_ok=0
else
    mkdir -p "${EXEC_ROOT}/slow_cwd"
    cat > "${EXEC_ROOT}/slow_chdir.c" << 'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int (*real_chdir_fn)(const char *) = 0;
static int (*real_poll_fn)(struct pollfd *, nfds_t, int) = 0;
static int enabled = 0;
static int fail_poll = 0;
static int poll_failed_once = 0;
static pid_t owner_pid = 0;
static const char *target = 0;

__attribute__((constructor))
static void init_slow_chdir(void)
{
    real_chdir_fn = (int (*)(const char *))dlsym(RTLD_NEXT, "chdir");
    real_poll_fn = (int (*)(struct pollfd *, nfds_t, int))
        dlsym(RTLD_NEXT, "poll");
    enabled = getenv("BABET_TEST_SLOW_CHDIR") != 0;
    fail_poll = getenv("BABET_TEST_FAIL_POLL") != 0;
    owner_pid = getpid();
    target = getenv("BABET_TEST_SLOW_CHDIR_TARGET");
}

int chdir(const char *path)
{
    if (!real_chdir_fn)
    {
        errno = ENOSYS;
        return -1;
    }
    if (enabled && target && path && strcmp(path, target) == 0)
    {
        struct timespec delay = {5, 0};
        while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {}
    }
    return real_chdir_fn(path);
}

static int is_babet_exec_io_poll(const struct pollfd *fds,
                                 nfds_t nfds, int timeout)
{
    /*
     * La boucle d'E/S de babet.exec() appelle poll() sans timeout avec :
     *   - stdout en lecture ;
     *   - stderr en lecture ;
     *   - stdin désactivé (fd négatif) quand aucun stdin n'est fourni.
     *
     * Sous ASan, le runtime peut effectuer ses propres poll() avant le
     * test. L'ancien filtre (nfds == 3) consommait alors l'injection trop
     * tôt et la commande "sleep 5" allait jusqu'à son terme. On vise ici
     * uniquement la forme exacte du poll() de babet.exec().
     */
    return fds != 0 && nfds == 3 && timeout == -1 &&
           fds[0].fd >= 0 && fds[0].events == POLLIN &&
           fds[1].fd >= 0 && fds[1].events == POLLIN &&
           fds[2].fd < 0  && fds[2].events == POLLOUT;
}

int poll(struct pollfd *fds, nfds_t nfds, int timeout)
{
    if (!real_poll_fn)
    {
        errno = ENOSYS;
        return -1;
    }
    if (fail_poll && getpid() == owner_pid && !poll_failed_once &&
        is_babet_exec_io_poll(fds, nfds, timeout))
    {
        poll_failed_once = 1;
        errno = EIO;
        return -1;
    }
    return real_poll_fn(fds, nfds, timeout);
}
C
    cat > "${EXEC_ROOT}/test.lua" << LUA
local function pid_is_running(pid)
    local probe = babet.exec("ps", { "-o", "stat=", "-p", tostring(pid) })
    if type(probe) ~= "table" or probe.code ~= 0 then return false end
    local state = probe.stdout:match("%S+")
    return state ~= nil and state:sub(1, 1) ~= "Z"
end

local function read_pid(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local pid = tonumber(f:read("*l"))
    f:close()
    return pid
end

local trace_path = "${EXEC_ROOT}/test6-stage.txt"
local function mark_stage(name)
    local f = assert(io.open(trace_path, "a"))
    f:write(name, "\n")
    f:close()
end

mark_stage("exec")
local t0 = babet.monotonic()
local r, e = babet.exec("true", {}, {
    cwd = "${EXEC_ROOT}/slow_cwd",
    timeout = 0.30,
})
local dt = babet.monotonic() - t0
if type(r) == "table" and e == nil and r.timed_out == true and dt < 2.0 then
    print("EXEC_PRELAUNCH_TIMEOUT_OK")
else
    io.stderr:write("bad exec result: r=" .. tostring(r)
        .. " e=" .. tostring(e) .. " dt=" .. tostring(dt) .. "\n")
    os.exit(1)
end

local sync_pid_path = "${EXEC_ROOT}/pipeline_sync.pid"
local sync_descendant_path = "${EXEC_ROOT}/pipeline_sync_descendant.pid"
local sync_command =
    "sh -c 'trap \"\" TERM; while :; do sleep 1; done' "
    .. ">/dev/null 2>&1 & echo \$! > " .. sync_descendant_path
    .. "; echo \$\$ > " .. sync_pid_path .. "; exec sleep 5"
mark_stage("pipeline")
t0 = babet.monotonic()
r, e = babet.pipeline({
    { "sh", { "-c", sync_command } },
    { "true", {}, { cwd = "${EXEC_ROOT}/slow_cwd" } },
}, { timeout = 0.30 })
dt = babet.monotonic() - t0
local sync_pid = read_pid(sync_pid_path)
local sync_descendant = read_pid(sync_descendant_path)
if r == nil and type(e) == "string"
    and e:find("launch timed out", 1, true) ~= nil
    and dt < 2.0 and sync_pid and not pid_is_running(sync_pid)
    and sync_descendant and not pid_is_running(sync_descendant) then
    print("PIPELINE_PRELAUNCH_TIMEOUT_OK")
else
    io.stderr:write("bad pipeline result: r=" .. tostring(r)
        .. " e=" .. tostring(e) .. " dt=" .. tostring(dt)
        .. " pid=" .. tostring(sync_pid)
        .. " descendant=" .. tostring(sync_descendant) .. "\n")
    for _, pid in ipairs({ sync_pid, sync_descendant }) do
        if pid and pid_is_running(pid) then
            babet.exec("kill", { "-9", tostring(pid) })
        end
    end
    os.exit(1)
end

local stream_pid_path = "${EXEC_ROOT}/pipeline_stream.pid"
local stream_descendant_path = "${EXEC_ROOT}/pipeline_stream_descendant.pid"
local stream_command =
    "sh -c 'trap \"\" TERM; while :; do sleep 1; done' "
    .. ">/dev/null 2>&1 & echo \$! > " .. stream_descendant_path
    .. "; echo \$\$ > " .. stream_pid_path .. "; exec sleep 5"
mark_stage("spawnPipeline")
t0 = babet.monotonic()
local pipeline, spawn_err = babet.spawnPipeline({
    { "sh", { "-c", stream_command } },
    { "true", {}, { cwd = "${EXEC_ROOT}/slow_cwd" } },
}, { launch_timeout = 0.30 })
dt = babet.monotonic() - t0
local stream_pid = read_pid(stream_pid_path)
local stream_descendant = read_pid(stream_descendant_path)
if pipeline == nil and type(spawn_err) == "string"
    and spawn_err:find("launch timed out", 1, true) ~= nil
    and dt < 2.0 and stream_pid and not pid_is_running(stream_pid)
    and stream_descendant and not pid_is_running(stream_descendant) then
    print("SPAWN_PIPELINE_PRELAUNCH_TIMEOUT_OK")
else
    io.stderr:write("bad spawnPipeline result: p=" .. tostring(pipeline)
        .. " e=" .. tostring(spawn_err) .. " dt=" .. tostring(dt)
        .. " pid=" .. tostring(stream_pid)
        .. " descendant=" .. tostring(stream_descendant) .. "\n")
    for _, pid in ipairs({ stream_pid, stream_descendant }) do
        if pid and pid_is_running(pid) then
            babet.exec("kill", { "-9", tostring(pid) })
        end
    end
    os.exit(1)
end
LUA
    cat > "${EXEC_ROOT}/test_poll.lua" << 'LUA'
local t0 = babet.monotonic()
local r, e = babet.exec("sleep", { "5" })
local dt = babet.monotonic() - t0
if r == nil and type(e) == "string"
    and e:find("poll failed", 1, true) ~= nil and dt < 2.0 then
    print("EXEC_POLL_CLEANUP_OK")
else
    io.stderr:write("bad result: r=" .. tostring(r)
        .. " e=" .. tostring(e) .. " dt=" .. tostring(dt) .. "\n")
    os.exit(1)
end
LUA

    if ! cc -shared -fPIC -O2 "${EXEC_ROOT}/slow_chdir.c" \
        -ldl -o "${EXEC_ROOT}/slow_chdir.so"; then
        echo "  -> ÉCHEC (compilation du preload)"
        test6_ok=0
    else
        if [ "${ASAN_ENABLED}" -eq 1 ]; then
            # Les scénarios slow_chdir reposent sur une interposition LD_PRELOAD
            # volontairement hostile. Sur AArch64 + ASan, cette combinaison a
            # montré un blocage reproductible dans poll() avant que le timeout
            # de lancement testé puisse rendre la main. Comme pour l'injection
            # poll ci-dessous, ce n'est pas un signal fiable sur le runtime
            # instrumenté. La campagne --release rejoue obligatoirement le même
            # scénario sur le build normal final, où il reste pleinement testé.
            echo "  -> timeout de lancement exec/pipeline/spawnPipeline : différé au build normal final (ASan/LD_PRELOAD)"
            echo "  -> rollback d'un pipeline partiellement lancé : différé au build normal final (ASan/LD_PRELOAD)"
        else
            T6_WATCHDOG_SECONDS=20
            T6_WATCHDOG_KILL_AFTER=5
            T6_STAGE_FILE="${EXEC_ROOT}/test6-stage.txt"
            rm -f -- "${T6_STAGE_FILE}"
            if ! command -v timeout >/dev/null 2>&1; then
                echo "  -> ÉCHEC (commande timeout absente pour le watchdog du Test 6)"
                test6_ok=0
            else
                t6_out=$(timeout --signal=TERM --kill-after="${T6_WATCHDOG_KILL_AFTER}s" \
                    "${T6_WATCHDOG_SECONDS}s" \
                    env LD_PRELOAD="$(babet_test_preload "${EXEC_ROOT}/slow_chdir.so")" \
                    BABET_TEST_SLOW_CHDIR=1 \
                    BABET_TEST_SLOW_CHDIR_TARGET="${EXEC_ROOT}/slow_cwd" \
                    "${BINARY}" "${EXEC_ROOT}/test.lua" 2>&1)
                t6_rc=$?
                t6_stage=$(tail -n 1 "${T6_STAGE_FILE}" 2>/dev/null || printf '%s' 'unknown')
                if [ ${t6_rc} -eq 0 ] \
                    && echo "${t6_out}" | grep -q "EXEC_PRELAUNCH_TIMEOUT_OK" \
                    && echo "${t6_out}" | grep -q "PIPELINE_PRELAUNCH_TIMEOUT_OK" \
                    && echo "${t6_out}" | grep -q "SPAWN_PIPELINE_PRELAUNCH_TIMEOUT_OK"; then
                    echo "  -> timeout de lancement exec/pipeline/spawnPipeline : OK"
                    echo "  -> rollback d'un pipeline partiellement lancé : OK"
                else
                    if [ ${t6_rc} -eq 124 ] || [ ${t6_rc} -eq 137 ]; then
                        echo "  -> ÉCHEC watchdog Test 6 (phase=${t6_stage}, rc=${t6_rc}, limite=${T6_WATCHDOG_SECONDS}s)"
                    else
                        echo "  -> ÉCHEC (phase=${t6_stage}, rc=${t6_rc}, sortie=${t6_out})"
                    fi
                    for pid_file in \
                        "${EXEC_ROOT}/pipeline_sync.pid" \
                        "${EXEC_ROOT}/pipeline_sync_descendant.pid" \
                        "${EXEC_ROOT}/pipeline_stream.pid" \
                        "${EXEC_ROOT}/pipeline_stream_descendant.pid"; do
                        if [ -f "${pid_file}" ]; then
                            t6_pid=$(cat "${pid_file}" 2>/dev/null || true)
                            case "${t6_pid}" in
                                ''|*[!0-9]*) ;;
                                *) kill -KILL "${t6_pid}" 2>/dev/null || true ;;
                            esac
                        fi
                    done
                    test6_ok=0
                fi
            fi
        fi

        CLOSED_STDIO_MARKER="${EXEC_ROOT}/closed_stdio.ok"
        cat > "${EXEC_ROOT}/test_closed_stdio.lua" << LUA
local result, err = babet.pipeline({
    { "cat" },
    { "sh", { "-c", "cat; printf stage-error >&2" } },
}, { stdin = "closed-stdio" })
local good = type(result) == "table" and err == nil
    and result.stdout == "closed-stdio"
    and result.stderr[2] == "stage-error"
local marker = assert(io.open("${CLOSED_STDIO_MARKER}", "w"))
marker:write(good and "OK" or ("BAD:" .. tostring(err)))
marker:close()
if not good then os.exit(1) end
LUA
        rm -f "${CLOSED_STDIO_MARKER}"
        (
            exec 0<&- 1>&- 2>&-
            "${BINARY}" "${EXEC_ROOT}/test_closed_stdio.lua"
        )
        t6_closed_rc=$?
        if [ ${t6_closed_rc} -eq 0 ]             && [ "$(cat "${CLOSED_STDIO_MARKER}" 2>/dev/null)" = "OK" ]; then
            echo "  -> stdin/stdout/stderr fermés avant lancement : OK"
        else
            echo "  -> ÉCHEC descripteurs standards fermés (rc=${t6_closed_rc})"
            test6_ok=0
        fi

        if [ "${ASAN_ENABLED}" -eq 1 ]; then
            # Le runtime ASan intercepte poll() avant les bibliothèques de
            # test chargées ensuite par LD_PRELOAD. Forcer notre hook avant
            # ASan fait au contraire refuser le démarrage du processus.
            #
            # Ce test d'injection artificielle n'est donc pas fiable dans
            # un processus ASan. La commande --release l'exécute
            # obligatoirement avec le build normal final, tandis que
            # tous les chemins ordinaires de babet.exec restent couverts
            # ici par ASan/UBSan et par le harnais Lua complet.
            echo "  -> erreur poll injectée : différée au build normal final (ASan/LD_PRELOAD incompatibles)"
        else
            t6_poll_out=$(LD_PRELOAD="$(babet_test_preload "${EXEC_ROOT}/slow_chdir.so")" \
                BABET_TEST_FAIL_POLL=1 \
                "${BINARY}" "${EXEC_ROOT}/test_poll.lua" 2>&1)
            t6_poll_rc=$?
            if [ ${t6_poll_rc} -eq 0 ] \
                && echo "${t6_poll_out}" | grep -q "EXEC_POLL_CLEANUP_OK"; then
                echo "  -> erreur poll : child nettoyé sans blocage : OK"
            else
                echo "  -> ÉCHEC poll (rc=${t6_poll_rc}, sortie=${t6_poll_out})"
                test6_ok=0
            fi
        fi
    fi
    rm -rf "${EXEC_ROOT}"
fi

if [ ${test6_ok} -eq 1 ]; then
    echo "  -> Test 6 : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "  -> Test 6 : ÉCHEC"
fi
echo ""

# === Test 7 : diagnostics des erreurs Lua non textuelles (lot 5B) ===
echo "### Test 7 : diagnostics Lua non textuels ###"
modes_total=$((modes_total + 1))
test7_ok=1

ERROR_ROOT=$(mktemp -d)
if [ -z "${ERROR_ROOT}" ] || [ ! -d "${ERROR_ROOT}" ]; then
    echo "  -> ÉCHEC (impossible de créer un dossier temporaire)"
    test7_ok=0
else
    cat > "${ERROR_ROOT}/error_table.lua" << 'LUA'
error({ code = 42 })
LUA

    t7_file_out=$("${BINARY}" "${ERROR_ROOT}/error_table.lua" 2>&1)
    t7_file_rc=$?
    if [ ${t7_file_rc} -eq 1 ] \
        && { echo "${t7_file_out}" | grep -q "table:" \
             || echo "${t7_file_out}" | grep -q "type table"; }; then
        echo "  -> script error({}) : diagnostic utile : OK"
    else
        echo "  -> ÉCHEC script error({}) (rc=${t7_file_rc}, sortie=${t7_file_out})"
        test7_ok=0
    fi

    mkdir -p "${ERROR_ROOT}/embedded_project"
    cp "${ERROR_ROOT}/error_table.lua" \
       "${ERROR_ROOT}/embedded_project/main.lua"
    if ! "${BINARY}" --create-exe "${ERROR_ROOT}/embedded_project" \
        "${ERROR_ROOT}/error_embedded" >/dev/null 2>&1; then
        echo "  -> ÉCHEC (création du binaire error({}))"
        test7_ok=0
    else
        t7_emb_out=$("${ERROR_ROOT}/error_embedded" 2>&1)
        t7_emb_rc=$?
        if [ ${t7_emb_rc} -eq 1 ] \
            && { echo "${t7_emb_out}" | grep -q "table:" \
                 || echo "${t7_emb_out}" | grep -q "type table"; }; then
            echo "  -> embarqué error({}) : diagnostic utile : OK"
        else
            echo "  -> ÉCHEC embarqué error({}) (rc=${t7_emb_rc}, sortie=${t7_emb_out})"
            test7_ok=0
        fi
    fi
    rm -rf "${ERROR_ROOT}"
fi

if [ ${test7_ok} -eq 1 ]; then
    echo "  -> Test 7 : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "  -> Test 7 : ÉCHEC"
fi
echo ""

# === Test 8 : durcissement attributs/touch contre les courses locales ===
echo "### Test 8 : attributs et touch sans TOCTOU destructrice ###"
modes_total=$((modes_total + 1))
test8_ok=1

ATTR_ROOT=$(mktemp -d)
if [ -z "${ATTR_ROOT}" ] || [ ! -d "${ATTR_ROOT}" ]; then
    echo "  -> ÉCHEC (impossible de créer un dossier temporaire)"
    test8_ok=0
else
    cat > "${ATTR_ROOT}/fs_race.c" << 'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int (*chmod_fn)(const char *, mode_t);
typedef int (*openat_fn)(int, const char *, int, ...);

static chmod_fn real_chmod_fn = 0;
static openat_fn real_openat_fn = 0;
static int chmod_injected = 0;
static int openat_injected = 0;

__attribute__((constructor))
static void init_fs_race(void)
{
    real_chmod_fn = (chmod_fn)dlsym(RTLD_NEXT, "chmod");
    real_openat_fn = (openat_fn)dlsym(RTLD_NEXT, "openat");
}

static int proc_fd_targets(const char *proc_path, const char *target)
{
    char resolved[4096];
    const ssize_t length = readlink(proc_path, resolved,
                                    sizeof(resolved) - 1);
    if (length < 0)
    {
        return 0;
    }
    resolved[length] = '\0';
    return target && strcmp(resolved, target) == 0;
}

int chmod(const char *path, mode_t mode)
{
    if (!real_chmod_fn)
    {
        errno = ENOSYS;
        return -1;
    }

    const char *test_mode = getenv("BABET_TEST_FS_RACE_MODE");
    const char *target = getenv("BABET_TEST_ATTR_TARGET");

    if (!chmod_injected && test_mode &&
        strncmp(path, "/proc/self/fd/", 14) == 0 &&
        proc_fd_targets(path, target))
    {
        if (strcmp(test_mode, "rollback") == 0)
        {
            const int rc = real_chmod_fn(path, mode);
            if (rc == 0)
            {
                chmod_injected = 1;
                errno = EIO;
                return -1;
            }
            return rc;
        }

        if (strcmp(test_mode, "replace") == 0)
        {
            const char *saved = getenv("BABET_TEST_ATTR_SAVED");
            const char *victim = getenv("BABET_TEST_ATTR_VICTIM");
            chmod_injected = 1;
            if (!saved || !victim || rename(target, saved) != 0 ||
                symlink(victim, target) != 0)
            {
                return -1;
            }
        }
    }

    return real_chmod_fn(path, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (flags & O_CREAT)
    {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }

    if (!real_openat_fn)
    {
        errno = ENOSYS;
        return -1;
    }

    const char *test_mode = getenv("BABET_TEST_FS_RACE_MODE");
    const char *name = getenv("BABET_TEST_TOUCH_NAME");
    if (!openat_injected && test_mode &&
        strcmp(test_mode, "touch") == 0 && name &&
        strcmp(path, name) == 0 && (flags & O_PATH) == O_PATH)
    {
        openat_injected = 1;
        const int fd = real_openat_fn(
            dirfd, path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (fd >= 0)
        {
            static const char payload[] = "race-payload";
            const ssize_t written = write(fd, payload, sizeof(payload) - 1);
            (void)written;
            (void)close(fd);
        }
        errno = ENOENT;
        return -1;
    }

    if (flags & O_CREAT)
    {
        return real_openat_fn(dirfd, path, flags, mode);
    }
    return real_openat_fn(dirfd, path, flags);
}
C

    if ! cc -shared -fPIC -O2 "${ATTR_ROOT}/fs_race.c" \
        -ldl -o "${ATTR_ROOT}/fs_race.so"; then
        echo "  -> ÉCHEC (compilation du preload)"
        test8_ok=0
    else
        # 8A - un chmod qui a effectivement modifié le mode puis signale une
        # erreur doit restaurer owner/group/mode sur le même inode.
        ATTR_TARGET="${ATTR_ROOT}/rollback-target.txt"
        printf 'rollback-test\n' > "${ATTR_TARGET}"
        chmod 0644 "${ATTR_TARGET}"

        cat > "${ATTR_ROOT}/rollback.lua" << LUA
local path = "${ATTR_TARGET}"
local before, before_err = babet.getAttributes(path)
assert(type(before) == "table" and before_err == nil)

local ok, err = babet.setAttributes(
    path, before.owner, before.group, tonumber("600", 8))
local mode, mode_err = babet.getMode(path)

if ok == nil and type(err) == "string"
    and err:find("chmod failed after chown", 1, true) ~= nil
    and mode == tonumber("644", 8) and mode_err == nil then
    print("SETATTR_ROLLBACK_OK")
else
    io.stderr:write("bad rollback: ok=" .. tostring(ok)
        .. " err=" .. tostring(err)
        .. " mode=" .. tostring(mode)
        .. " mode_err=" .. tostring(mode_err) .. "\n")
    os.exit(1)
end
LUA

        t8_out=$(LD_PRELOAD="$(babet_test_preload "${ATTR_ROOT}/fs_race.so")" \
            BABET_TEST_FS_RACE_MODE=rollback \
            BABET_TEST_ATTR_TARGET="${ATTR_TARGET}" \
            "${BINARY}" "${ATTR_ROOT}/rollback.lua" 2>&1)
        t8_rc=$?
        if [ ${t8_rc} -eq 0 ] \
            && echo "${t8_out}" | grep -q "SETATTR_ROLLBACK_OK"; then
            echo "  -> chmod partiel : attributs restaurés : OK"
        else
            echo "  -> ÉCHEC rollback (rc=${t8_rc}, sortie=${t8_out})"
            test8_ok=0
        fi

        # 8B - remplacement du chemin entre chown et chmod : le descripteur
        # épinglé doit recevoir le mode, jamais la nouvelle cible du chemin.
        ATTR_TARGET="${ATTR_ROOT}/race-target.txt"
        ATTR_SAVED="${ATTR_ROOT}/race-target.saved"
        ATTR_VICTIM="${ATTR_ROOT}/race-victim.txt"
        printf 'original\n' > "${ATTR_TARGET}"
        printf 'victim\n' > "${ATTR_VICTIM}"
        chmod 0644 "${ATTR_TARGET}" "${ATTR_VICTIM}"

        cat > "${ATTR_ROOT}/replace.lua" << LUA
local target = "${ATTR_TARGET}"
local saved = "${ATTR_SAVED}"
local victim = "${ATTR_VICTIM}"
local before = assert(babet.getAttributes(target))
local ok, err = babet.setAttributes(
    target, before.owner, before.group, tonumber("600", 8))
local saved_mode = babet.getMode(saved)
local victim_mode = babet.getMode(victim)
local link = babet.exec("readlink", { target }, {
    env = { LD_PRELOAD = "" },
})

if ok == true and err == nil
    and saved_mode == tonumber("600", 8)
    and victim_mode == tonumber("644", 8)
    and type(link) == "table" and link.code == 0 then
    print("SETATTR_PINNED_INODE_OK")
else
    io.stderr:write("bad pinned result: ok=" .. tostring(ok)
        .. " err=" .. tostring(err)
        .. " saved_mode=" .. tostring(saved_mode)
        .. " victim_mode=" .. tostring(victim_mode) .. "\n")
    os.exit(1)
end
LUA

        t8_out=$(LD_PRELOAD="$(babet_test_preload "${ATTR_ROOT}/fs_race.so")" \
            BABET_TEST_FS_RACE_MODE=replace \
            BABET_TEST_ATTR_TARGET="${ATTR_TARGET}" \
            BABET_TEST_ATTR_SAVED="${ATTR_SAVED}" \
            BABET_TEST_ATTR_VICTIM="${ATTR_VICTIM}" \
            "${BINARY}" "${ATTR_ROOT}/replace.lua" 2>&1)
        t8_rc=$?
        if [ ${t8_rc} -eq 0 ] \
            && echo "${t8_out}" | grep -q "SETATTR_PINNED_INODE_OK"; then
            echo "  -> remplacement concurrent : inode d'origine conservé : OK"
        else
            echo "  -> ÉCHEC inode épinglé (rc=${t8_rc}, sortie=${t8_out})"
            test8_ok=0
        fi

        # 8C - un fichier créé dans la fenêtre ENOENT/O_CREAT doit être repris
        # sans O_TRUNC et conserver tous ses octets.
        TOUCH_NAME="touch-race-target.txt"
        TOUCH_TARGET="${ATTR_ROOT}/${TOUCH_NAME}"
        rm -f "${TOUCH_TARGET}"
        cat > "${ATTR_ROOT}/touch.lua" << LUA
local path = "${TOUCH_TARGET}"
local ok, err = babet.touch(path)
local file = io.open(path, "rb")
local contents = file and file:read("*a")
if file then file:close() end
if ok == true and err == nil and contents == "race-payload" then
    print("TOUCH_RACE_PRESERVED_OK")
else
    io.stderr:write("bad touch race: ok=" .. tostring(ok)
        .. " err=" .. tostring(err)
        .. " contents=" .. tostring(contents) .. "\n")
    os.exit(1)
end
LUA

        t8_out=$(LD_PRELOAD="$(babet_test_preload "${ATTR_ROOT}/fs_race.so")" \
            BABET_TEST_FS_RACE_MODE=touch \
            BABET_TEST_TOUCH_NAME="${TOUCH_NAME}" \
            "${BINARY}" "${ATTR_ROOT}/touch.lua" 2>&1)
        t8_rc=$?
        if [ ${t8_rc} -eq 0 ] \
            && echo "${t8_out}" | grep -q "TOUCH_RACE_PRESERVED_OK"; then
            echo "  -> apparition concurrente : contenu non tronqué : OK"
        else
            echo "  -> ÉCHEC course touch (rc=${t8_rc}, sortie=${t8_out})"
            test8_ok=0
        fi
    fi
    rm -rf "${ATTR_ROOT}"
fi

if [ ${test8_ok} -eq 1 ]; then
    echo "  -> Test 8 : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "  -> Test 8 : ÉCHEC"
fi
echo ""

# === Test 9 : chemin exécutable sans troncature PATH_MAX (lot 6) ===
echo "### Test 9 : chemin exécutable dynamique ###"
modes_total=$((modes_total + 1))
test9_ok=1

EXEPATH_ROOT=$(mktemp -d)
if [ -z "${EXEPATH_ROOT}" ] || [ ! -d "${EXEPATH_ROOT}" ]; then
    echo "  -> ÉCHEC (impossible de créer un dossier temporaire)"
    test9_ok=0
else
    cat > "${EXEPATH_ROOT}/readlink_full.c" << 'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>

typedef ssize_t (*readlink_fn)(const char *, char *, size_t);
static readlink_fn real_readlink_fn = 0;
static int injected = 0;

ssize_t readlink(const char *path, char *buffer, size_t size)
{
    if (!real_readlink_fn)
    {
        real_readlink_fn = (readlink_fn)dlsym(RTLD_NEXT, "readlink");
    }

    if (!injected && path && strcmp(path, "/proc/self/exe") == 0)
    {
        injected = 1;
        memset(buffer, 'x', size);
        return (ssize_t)size;
    }
    return real_readlink_fn(path, buffer, size);
}
C

    cat > "${EXEPATH_ROOT}/test_executable_path.cpp" << 'CPP'
#include "executable_path.hpp"
#include <cstdlib>
#include <iostream>
#include <limits.h>
#include <string>

int main(int argc, char **argv)
{
    if (argc < 1)
    {
        return 2;
    }

    char expected[PATH_MAX];
    if (!realpath(argv[0], expected))
    {
        return 3;
    }

    try
    {
        const std::string actual = getExecutablePath();
        if (actual != expected)
        {
            std::cerr << "actual=" << actual << " expected=" << expected
                      << "\n";
            return 1;
        }
    }
    catch (const std::exception &error)
    {
        std::cerr << error.what() << "\n";
        return 1;
    }

    std::cout << "EXECUTABLE_PATH_DYNAMIC_OK\n";
    return 0;
}
CPP

    if ! cc -shared -fPIC -O2 "${EXEPATH_ROOT}/readlink_full.c" \
        -ldl -o "${EXEPATH_ROOT}/readlink_full.so"; then
        echo "  -> ÉCHEC (compilation du preload readlink)"
        test9_ok=0
    elif ! c++ -std=c++23 -O2 \
        -I"${SCRIPT_DIR}/src/project_core" \
        "${EXEPATH_ROOT}/test_executable_path.cpp" \
        "${SCRIPT_DIR}/src/project_core/executable_path.cpp" \
        -o "${EXEPATH_ROOT}/test_executable_path"; then
        echo "  -> ÉCHEC (compilation du harnais executable_path)"
        test9_ok=0
    else
        t9_out=$(LD_PRELOAD="${EXEPATH_ROOT}/readlink_full.so" \
            "${EXEPATH_ROOT}/test_executable_path" 2>&1)
        t9_rc=$?
        if [ ${t9_rc} -eq 0 ] \
            && echo "${t9_out}" | grep -q "EXECUTABLE_PATH_DYNAMIC_OK"; then
            echo "  -> readlink plein : buffer agrandi sans troncature : OK"
        else
            echo "  -> ÉCHEC chemin dynamique (rc=${t9_rc}, sortie=${t9_out})"
            test9_ok=0
        fi
    fi
    rm -rf "${EXEPATH_ROOT}"
fi

if [ ${test9_ok} -eq 1 ]; then
    echo "  -> Test 9 : OK"
    modes_ok=$((modes_ok + 1))
else
    echo "  -> Test 9 : ÉCHEC"
fi
echo ""

# --- 4. Bilan -------------------------------------------------------
echo "=========================================="
echo "Bilan : ${modes_ok}/${modes_total} modes OK"
echo "=========================================="

if [ ${modes_ok} -eq ${modes_total} ]; then
    exit 0
else
    exit 1
fi
