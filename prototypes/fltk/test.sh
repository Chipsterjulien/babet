#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
FLTK_TEST_LOG="${ROOT}/babet-fltk-tests.txt"

# The optional GUI validation is intentionally outside run_tests.sh, so it owns
# a separate stable log. A top-level invocation captures the complete bootstrap,
# configure, build and runtime transcript, strips terminal escape sequences, and
# atomically replaces babet-fltk-tests.txt. The recursive invocation performs
# the real work without creating a nested log.
run_with_log() {
    local raw_log=""
    local clean_log=""
    local test_command=""
    local -a pipeline_status=()
    local test_rc=1
    local tee_rc=1
    local clean_rc=0

    raw_log=$(mktemp "${TMPDIR:-/tmp}/babet-fltk-tests-log.XXXXXX") || {
        echo "ÉCHEC : impossible de créer le journal FLTK temporaire." >&2
        return 1
    }
    clean_log=$(mktemp "${FLTK_TEST_LOG}.tmp.XXXXXX") || {
        echo "ÉCHEC : impossible de préparer ${FLTK_TEST_LOG}." >&2
        rm -f -- "${raw_log}"
        return 1
    }
    trap 'rm -f -- "${raw_log}" "${clean_log}"' EXIT

    printf -v test_command '%q ' bash "${BASH_SOURCE[0]}" "$@"

    echo "Journal FLTK sans couleurs : ${FLTK_TEST_LOG}"
    echo

    export BABET_FLTK_TEST_LOG_ACTIVE=1
    # The recursive validation is allowed to fail: the wrapper must still
    # publish its complete transcript before returning that failure status.
    set +e
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
    set -e
    unset BABET_FLTK_TEST_LOG_ACTIVE

    LC_ALL=C sed -E \
        -e $'s/\x1B\\][^\a]*(\a|\x1B\\\\)//g' \
        -e $'s/\x1B\\[[0-?]*[ -\\/]*[@-~]//g' \
        -e $'s/\r//g' \
        "${raw_log}" > "${clean_log}" || clean_rc=$?

    if [[ ${clean_rc} -eq 0 ]]; then
        if ! mv -f -- "${clean_log}" "${FLTK_TEST_LOG}"; then
            clean_rc=1
        fi
    fi

    rm -f -- "${raw_log}"
    [[ ! -f "${clean_log}" ]] || rm -f -- "${clean_log}"
    trap - EXIT

    echo
    if [[ ${clean_rc} -eq 0 ]]; then
        echo "Journal FLTK sans couleurs enregistré : ${FLTK_TEST_LOG}"
    else
        echo "ÉCHEC : impossible d'enregistrer le journal FLTK sans couleurs." >&2
    fi

    if [[ ${test_rc} -ne 0 ]]; then
        return "${test_rc}"
    fi
    if [[ ${tee_rc} -ne 0 ]]; then
        echo "ÉCHEC : la copie du flux de validation FLTK a échoué." >&2
        return "${tee_rc}"
    fi
    return "${clean_rc}"
}

if [[ "${BABET_FLTK_TEST_LOG_ACTIVE:-0}" -ne 1 ]]; then
    run_with_log "$@"
    exit $?
fi

SDK_DIR="${BABET_SDK_DIR:-${ROOT}/build/embedding-sdk}"
HOST_BUILD="${ROOT}/build/fltk-prototype/host-build"
PREFIX_DIR="${ROOT}/build/fltk-prototype/fltk-prefix"

if [[ ! -f "${SDK_DIR}/include/babet/babet.h" || ! -f "${SDK_DIR}/lib/libbabet.a" ]]; then
    echo "Erreur : SDK libbabet absent dans ${SDK_DIR}." >&2
    echo "Lancez d'abord ./build_local.sh ou ./run_tests.sh." >&2
    exit 2
fi

if [[ ! -f "${PREFIX_DIR}/.babet-fltk-1.4.5" ]]; then
    "${SCRIPT_DIR}/bootstrap_fltk.sh"
fi

rm -rf "${HOST_BUILD}"
cmake -S "${SCRIPT_DIR}" -B "${HOST_BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBABET_SDK_DIR="${SDK_DIR}" \
    -DCMAKE_PREFIX_PATH="${PREFIX_DIR}"
cmake --build "${HOST_BUILD}" --parallel

BIN="${HOST_BUILD}/babet_fltk_prototype"
if [[ ! -x "${BIN}" ]]; then
    echo "Erreur : prototype FLTK non produit." >&2
    exit 1
fi

RUN_LOG="${HOST_BUILD}/self-test.log"
if command -v xvfb-run >/dev/null 2>&1; then
    FLTK_BACKEND=x11 xvfb-run -a "${BIN}" --self-test >"${RUN_LOG}" 2>&1
elif [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
    "${BIN}" --self-test >"${RUN_LOG}" 2>&1
else
    echo "Erreur : aucun affichage disponible pour le self-test FLTK." >&2
    echo "Installez xvfb ou lancez le test dans une session graphique." >&2
    exit 2
fi

cat "${RUN_LOG}"
grep -Fq 'intentional Lot 9 callback failure' "${RUN_LOG}"
grep -Fq 'LOT9_FLTK_SELFTEST_OK attempts=3 successes=2 lua_errors=1 last=3' "${RUN_LOG}"
echo '[PASS] FLTK event loop survives a Lua callback error and recovers'
echo '[PASS] FLTK callbacks are disabled before GUI/context destruction'

STRIPPED="${HOST_BUILD}/babet_fltk_prototype.stripped"
cp "${BIN}" "${STRIPPED}"
strip "${STRIPPED}"
SIZE="$(stat -c '%s' "${STRIPPED}")"
echo "[INFO] stripped FLTK prototype: ${SIZE} bytes"

echo '[INFO] FLTK prototype dynamic dependencies:'
ldd "${BIN}"
if ldd "${BIN}" | grep -Eqi 'libfltk[^ ]*\.so'; then
    echo 'Erreur : le prototype utilise un FLTK partagé au lieu du FLTK statique prévu.' >&2
    exit 1
fi

echo '[PASS] prototype has no dynamic FLTK runtime dependency'

if [[ -x "${ROOT}/test/babet" ]]; then
    if ldd "${ROOT}/test/babet" | grep -Eqi 'fltk|libX11|wayland|pango|cairo'; then
        echo 'Erreur : le CLI Babet normal a acquis une dépendance GUI.' >&2
        exit 1
    fi
    echo '[PASS] normal Babet CLI retains zero GUI runtime dependency'
fi
