#!/bin/bash
# run_tests.sh — compile le projet puis teste les deux modes d'exécution
# (mode dossier et mode exécutable embarqué), avec un bilan global.
#
# Code de sortie : 0 si les deux modes passent, 1 sinon.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="babet"
TEST_DIR="${SCRIPT_DIR}/test"
EXAMPLES_DIR="${SCRIPT_DIR}/examples"

# --- 1. Compilation -------------------------------------------------
echo "### Compilation ###"
if ! bash "${SCRIPT_DIR}/build_local.sh"; then
    echo "ÉCHEC : la compilation a échoué."
    exit 1
fi
echo ""

BINARY="${TEST_DIR}/${PROJECT_NAME}"
if [ ! -f "${BINARY}" ]; then
    echo "ÉCHEC : binaire introuvable après compilation (${BINARY})."
    exit 1
fi

modes_ok=0
modes_total=0

# --- 2. Test mode dossier ------------------------------------------
echo "### Test 1/2 : mode dossier ###"
modes_total=$((modes_total + 1))

dir_output=$(cd "${TEST_DIR}" && ./"${PROJECT_NAME}" . __ARG__a __ARG__b 2>&1)
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
        emb_output=$(cd "${ISOLATED_DIR}" && ./babet_embedded __ARG__a __ARG__b 2>&1)
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
        emb_path_output=$(cd "${PATH_TEST_CWD}" && PATH="${ISOLATED_DIR}:$PATH" babet_embedded __ARG__a __ARG__b 2>&1)
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
# Deux bugs corrigés dans zip_utils.cpp :
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

# --- 4. Bilan -------------------------------------------------------
echo "=========================================="
echo "Bilan : ${modes_ok}/${modes_total} modes OK"
echo "=========================================="

if [ ${modes_ok} -eq ${modes_total} ]; then
    exit 0
else
    exit 1
fi
