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
ENABLE_SANITIZERS=0
RELEASE_VALIDATION=0
BUILD_FAILURE_EXIT_CODE=2

# Exécute la validation pré-release dans un pseudo-terminal afin que les
# outils qui colorent uniquement leur sortie interactive conservent leurs
# couleurs à l'écran. Le flux brut est enregistré temporairement, puis les
# séquences ANSI et les retours chariot du pseudo-terminal sont retirés avant
# la publication atomique du journal texte.
run_release_with_log() {
    local release_log=""
    local raw_log=""
    local clean_log=""
    local release_command=""
    local -a pipeline_status=()
    local release_rc=1
    local tee_rc=1
    local clean_rc=0

    # Le nom reste volontairement identique d'une version à l'autre afin que
    # le journal à transmettre soit toujours évident. Chaque validation
    # --release remplace atomiquement le journal précédent.
    release_log="${SCRIPT_DIR}/${PROJECT_NAME}-tests.txt"
    raw_log=$(mktemp "${TMPDIR:-/tmp}/${PROJECT_NAME}-release-log.XXXXXX") || {
        echo "ÉCHEC : impossible de créer le journal temporaire."
        return 1
    }
    clean_log=$(mktemp "${release_log}.tmp.XXXXXX") || {
        echo "ÉCHEC : impossible de préparer ${release_log}."
        rm -f -- "${raw_log}"
        return 1
    }
    trap 'rm -f -- "${raw_log}" "${clean_log}"' EXIT

    # %q protège le chemin du script et tous les arguments lors du passage par
    # l'option --command de util-linux script.
    printf -v release_command '%q ' bash "${BASH_SOURCE[0]}" "$@"

    echo "Journal sans couleurs : ${release_log}"
    echo

    export BABET_RELEASE_LOG_ACTIVE=1
    if command -v script >/dev/null 2>&1; then
        script --quiet --return --flush \
            --command "${release_command}" /dev/null \
            | tee "${raw_log}"
        pipeline_status=("${PIPESTATUS[@]}")
        release_rc=${pipeline_status[0]}
        tee_rc=${pipeline_status[1]}
    else
        echo "AVERTISSEMENT : commande 'script' introuvable ; " \
             "les couleurs automatiques peuvent être désactivées."
        bash "${BASH_SOURCE[0]}" "$@" 2>&1 | tee "${raw_log}"
        pipeline_status=("${PIPESTATUS[@]}")
        release_rc=${pipeline_status[0]}
        tee_rc=${pipeline_status[1]}
    fi
    unset BABET_RELEASE_LOG_ACTIVE

    # Retire les séquences OSC (notamment les hyperliens), les séquences CSI
    # (dont les couleurs SGR) et les CR ajoutés par le pseudo-terminal.
    LC_ALL=C sed -E \
        -e $'s/\x1B\\][^\a]*(\a|\x1B\\\\)//g' \
        -e $'s/\x1B\\[[0-?]*[ -\\/]*[@-~]//g' \
        -e $'s/\r//g' \
        "${raw_log}" > "${clean_log}" || clean_rc=$?

    if [ ${clean_rc} -eq 0 ]; then
        if ! mv -f -- "${clean_log}" "${release_log}"; then
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
        echo "Journal sans couleurs enregistré : ${release_log}"
    else
        echo "ÉCHEC : impossible d'enregistrer le journal sans couleurs."
    fi

    if [ ${release_rc} -ne 0 ]; then
        return "${release_rc}"
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
            ENABLE_SANITIZERS=1
            ;;
        --release)
            RELEASE_VALIDATION=1
            ;;
        --help|-h)
            echo "Usage: $0 [--sanitizers|--release]"
            echo "  (par défaut)   Build normal + tests complets"
            echo "  --sanitizers   Build ASan/UBSan + tests compatibles avec les sanitizers"
            echo "  --release      Validation pré-release complète + journal texte sans couleurs"
            exit 0
            ;;
        *)
            echo "Argument inconnu : $arg"
            echo "Voir $0 --help"
            exit 1
            ;;
    esac
done

if [ "${RELEASE_VALIDATION}" -eq 1 ]; then
    if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
        echo "Les options --release et --sanitizers ne peuvent pas être combinées."
        exit 1
    fi

    if [ "${BABET_RELEASE_LOG_ACTIVE:-0}" -ne 1 ]; then
        run_release_with_log "$@"
        exit $?
    fi

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

print_preflight_stage "Préflight — orchestration de validation"
if ! bash "${SCRIPT_DIR}/tools/test_release_fail_fast.sh"; then
    echo "ÉCHEC : le préflight de l'orchestration de validation a échoué."
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
if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
    BUILD_ARGS+=(--sanitizers)
    # Les valeurs fournies par l'utilisateur restent prioritaires.
    export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1}"
    export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
fi

# --- 1. Compilation -------------------------------------------------
if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
    echo "### Compilation (ASan + UBSan) ###"
else
    echo "### Compilation ###"
fi
if ! bash "${SCRIPT_DIR}/build_local.sh" "${BUILD_ARGS[@]}"; then
    echo "ÉCHEC : la compilation a échoué."
    exit "${BUILD_FAILURE_EXIT_CODE}"
fi
echo ""

BINARY="${TEST_DIR}/${PROJECT_NAME}"
if [ ! -f "${BINARY}" ]; then
    echo "ÉCHEC : binaire introuvable après compilation (${BINARY})."
    exit "${BUILD_FAILURE_EXIT_CODE}"
fi

print_preflight_stage "Régression — nettoyage OOM Lua / RAII C++"
OOM_ARGS=()
if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
    OOM_ARGS+=(--sanitizers)
fi
if ! bash "${SCRIPT_DIR}/tools/test_lua_longjmp_oom.sh" "${OOM_ARGS[@]}"; then
    echo "ÉCHEC : le test OOM Lua / RAII C++ a échoué."
    exit 1
fi

print_preflight_stage "Régression — spawn interactif sous pseudo-terminal"
if ! bash "${SCRIPT_DIR}/tools/test_spawn_pty.sh" "${BINARY}"; then
    echo "ÉCHEC : le test PTY de babet.spawn a échoué."
    exit 1
fi

# Les tests 4, 6 et 8 injectent une bibliothèque de test avec LD_PRELOAD.
# Pour un binaire ASan, le runtime AddressSanitizer doit rester le premier
# objet chargé ; sinon le loader arrête le processus avant même main().
ASAN_RUNTIME=""
if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
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

modes_ok=0
modes_total=0

# --- 2. Test mode dossier ------------------------------------------
echo "### Test 1/2 : mode dossier ###"
modes_total=$((modes_total + 1))

# Le test d'intégration du plafond de nœuds workers matérialise près d'un
# million de valeurs JSON. Il s'exécute une seule fois : mode dossier du build
# normal. Les autres modes forcent explicitement la variable à vide pour qu'un
# environnement utilisateur ne puisse pas répéter ce test lourd.
if [ "${ENABLE_SANITIZERS}" -eq 0 ]; then
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
        t6_out=$(LD_PRELOAD="$(babet_test_preload "${EXEC_ROOT}/slow_chdir.so")" \
            BABET_TEST_SLOW_CHDIR=1 \
            BABET_TEST_SLOW_CHDIR_TARGET="${EXEC_ROOT}/slow_cwd" \
            "${BINARY}" "${EXEC_ROOT}/test.lua" 2>&1)
        t6_rc=$?
        if [ ${t6_rc} -eq 0 ] \
            && echo "${t6_out}" | grep -q "EXEC_PRELAUNCH_TIMEOUT_OK" \
            && echo "${t6_out}" | grep -q "PIPELINE_PRELAUNCH_TIMEOUT_OK" \
            && echo "${t6_out}" | grep -q "SPAWN_PIPELINE_PRELAUNCH_TIMEOUT_OK"; then
            echo "  -> timeout de lancement exec/pipeline/spawnPipeline : OK"
            echo "  -> rollback d'un pipeline partiellement lancé : OK"
        else
            echo "  -> ÉCHEC (rc=${t6_rc}, sortie=${t6_out})"
            test6_ok=0
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

        if [ "${ENABLE_SANITIZERS}" -eq 1 ]; then
            # Le runtime ASan intercepte poll() avant les bibliothèques de
            # test chargées ensuite par LD_PRELOAD. Forcer notre hook avant
            # ASan fait au contraire refuser le démarrage du processus.
            #
            # Ce test d'injection artificielle n'est donc pas fiable dans
            # un processus ASan. La commande --release l'exécute
            # obligatoirement à l'étape 3 avec le build normal, tandis que
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
local link = babet.exec("readlink", { target })

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
