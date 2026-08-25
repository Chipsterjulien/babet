#!/bin/bash
# Vérifie hermétiquement que validate_release.sh interrompt la campagne après
# un échec de compilation, tout en conservant le diagnostic complémentaire du
# build normal après un simple échec de test sous sanitizers.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babet-release-flow.XXXXXX") || exit 1
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

pass_count=0
fail_count=0

pass() {
    echo "[PASS] $1"
    pass_count=$((pass_count + 1))
}

fail() {
    echo "[FAIL] $1"
    fail_count=$((fail_count + 1))
}

prepare_fixture() {
    local dir="$1"
    mkdir -p "${dir}/test"
    cp "${SCRIPT_DIR}/validate_release.sh" "${dir}/validate_release.sh"

    cat > "${dir}/run_tests.sh" <<'SH'
#!/bin/bash
printf 'run_tests:%s\n' "$*" >> "${BABET_FLOW_LOG}"
if [ "${1:-}" = "--sanitizers" ]; then
    exit "${BABET_FAKE_SANITIZERS_RC:-0}"
fi
exit "${BABET_FAKE_NORMAL_RC:-0}"
SH

    cat > "${dir}/smoke_test_network.sh" <<'SH'
#!/bin/bash
printf 'network:%s\n' "$*" >> "${BABET_FLOW_LOG}"
exit "${BABET_FAKE_NETWORK_RC:-0}"
SH

    chmod +x "${dir}/validate_release.sh" \
        "${dir}/run_tests.sh" "${dir}/smoke_test_network.sh"
}

run_fixture() {
    local name="$1"
    local sanitizer_rc="$2"
    local normal_rc="$3"
    local network_rc="$4"
    local dir="${TMP_ROOT}/${name}"
    local output="${dir}/output.txt"
    local flow="${dir}/flow.txt"
    local rc=0

    prepare_fixture "${dir}"
    : > "${flow}"
    BABET_FLOW_LOG="${flow}" \
    BABET_FAKE_SANITIZERS_RC="${sanitizer_rc}" \
    BABET_FAKE_NORMAL_RC="${normal_rc}" \
    BABET_FAKE_NETWORK_RC="${network_rc}" \
        bash "${dir}/validate_release.sh" > "${output}" 2>&1 || rc=$?

    printf '%s\n%s\n%s\n' "${rc}" "${flow}" "${output}"
}

# Toute invocation top-level de run_tests.sh doit produire le journal stable
# babet-tests.txt, tandis que les appels internes d'une campagne --release
# héritent du garde et ne créent pas de journal imbriqué.
if grep -q 'test_log="${SCRIPT_DIR}/${PROJECT_NAME}-tests.txt"' "${SCRIPT_DIR}/run_tests.sh" \
    && grep -q 'BABET_TEST_LOG_ACTIVE' "${SCRIPT_DIR}/run_tests.sh" \
    && grep -q 'run_with_log "\$@"' "${SCRIPT_DIR}/run_tests.sh"; then
    pass "all top-level run_tests modes publish the stable text log"
else
    fail "all top-level run_tests modes publish the stable text log"
fi

# run_tests.sh doit exposer un code distinct pour les échecs de build.
if grep -q '^BUILD_FAILURE_EXIT_CODE=2$' "${SCRIPT_DIR}/run_tests.sh" \
    && grep -q 'exit "${BUILD_FAILURE_EXIT_CODE}"' "${SCRIPT_DIR}/run_tests.sh"; then
    pass "run_tests exposes a dedicated compilation failure exit code"
else
    fail "run_tests exposes a dedicated compilation failure exit code"
fi

# Une compilation sanitizer échouée doit arrêter avant le build normal.
mapfile -t result < <(run_fixture compile_failure 2 0 0)
rc=${result[0]}
flow=${result[1]}
output=${result[2]}
if [ "${rc}" -eq 1 ] \
    && [ "$(cat "${flow}")" = "run_tests:--sanitizers" ] \
    && grep -q "build normal : IGNORÉ" "${output}"; then
    pass "sanitizer compilation failure stops normal build and network stages"
else
    fail "sanitizer compilation failure stops normal build and network stages"
fi

# Un simple échec de test sanitizer conserve le passage normal de diagnostic.
mapfile -t result < <(run_fixture sanitizer_test_failure 1 0 0)
rc=${result[0]}
flow=${result[1]}
if [ "${rc}" -eq 1 ] \
    && [ "$(wc -l < "${flow}")" -eq 3 ] \
    && [ "$(sed -n '1p' "${flow}")" = "run_tests:--sanitizers" ] \
    && [ "$(sed -n '2p' "${flow}")" = "run_tests:" ] \
    && grep -q '^network:' "${flow}"; then
    pass "sanitizer test failure still restores and validates the normal build"
else
    fail "sanitizer test failure still restores and validates the normal build"
fi

# Une compilation normale échouée doit empêcher les smoke tests réseau.
mapfile -t result < <(run_fixture normal_compile_failure 0 2 0)
rc=${result[0]}
flow=${result[1]}
output=${result[2]}
expected=$'run_tests:--sanitizers\nrun_tests:'
if [ "${rc}" -eq 1 ] \
    && [ "$(cat "${flow}")" = "${expected}" ] \
    && grep -q "compilation du build normal a échoué" "${output}"; then
    pass "normal compilation failure skips network smoke tests"
else
    fail "normal compilation failure skips network smoke tests"
fi

# Le chemin nominal reste intégralement exécuté.
mapfile -t result < <(run_fixture success 0 0 0)
rc=${result[0]}
flow=${result[1]}
if [ "${rc}" -eq 0 ] \
    && [ "$(wc -l < "${flow}")" -eq 3 ] \
    && [ "$(sed -n '1p' "${flow}")" = "run_tests:--sanitizers" ] \
    && [ "$(sed -n '2p' "${flow}")" = "run_tests:" ] \
    && grep -q '^network:' "${flow}"; then
    pass "successful release validation still runs all three stages"
else
    fail "successful release validation still runs all three stages"
fi

echo "release validation orchestration: ${pass_count} PASS / ${fail_count} FAIL"
[ "${fail_count}" -eq 0 ]
