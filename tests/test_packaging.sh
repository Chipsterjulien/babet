#!/bin/bash
# Runtime contracts for Babet --create-exe.
# Usage: tests/test_packaging.sh /absolute/path/to/babet

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="${1:-}"
PASS=0
FAIL=0

pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "[FAIL] $1${2:+ - $2}"
    FAIL=$((FAIL + 1))
}

finish() {
    echo "packaging regression: ${PASS} PASS / ${FAIL} FAIL"
    [ "${FAIL}" -eq 0 ]
}

if [ -z "${BINARY}" ] || [ ! -x "${BINARY}" ]; then
    fail "Babet test binary is available" "${BINARY:-missing argument}"
    finish
    exit $?
fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babet-packaging.XXXXXX") || {
    fail "temporary packaging sandbox can be created"
    finish
    exit $?
}
trap 'rm -rf -- "${ROOT}"' EXIT

PROJECT="${ROOT}/project"
TARGET="${ROOT}/target"
COPY_TARGET="${ROOT}/copy-target"
ISOLATED_CWD="${ROOT}/isolated-cwd"
EMPTY_PATH="${ROOT}/empty-path"
LOGS="${ROOT}/logs"
mkdir -p "${PROJECT}" "${TARGET}" "${COPY_TARGET}" \
         "${ISOLATED_CWD}" "${EMPTY_PATH}" "${LOGS}"

cat > "${PROJECT}/main.lua" <<'LUA'
if arg and arg[1] == "__run__" then
    print("PACKAGING_AUTONOMOUS_OK")
elseif arg and arg[1] == "__plugin__" then
    local plugin, err = babet.plugin.load(arg[2] or "/tmp/not-a-plugin.so")
    if plugin ~= nil then error("generated application unexpectedly loaded a plugin") end
    print("PACKAGING_PLUGIN_REFUSAL:" .. tostring(err))
else
    print("PACKAGING_MAIN_EXECUTED:" .. tostring(arg and arg[1]))
end
LUA
printf 'return "HELPER_FROM_EMBEDDED_ZIP"\n' > "${PROJECT}/helper.lua"

APP="${TARGET}/application"
BUILD_STDOUT="${LOGS}/build.stdout"
BUILD_STDERR="${LOGS}/build.stderr"

# Strong use-time check: there is no command at all in PATH while Babet builds
# the executable. This catches accidental gcc/clang/ld/cmake/zip/etc. lookup
# without depending on which toolchains happen to be installed on the host.
if PATH="${EMPTY_PATH}" "${BINARY}" --create-exe "${PROJECT}" "${APP}" \
        >"${BUILD_STDOUT}" 2>"${BUILD_STDERR}"; then
    if [ -x "${APP}" ]; then
        pass "original Babet builds with an empty PATH (no external toolchain lookup)"
    else
        fail "original Babet builds with an empty PATH (no external toolchain lookup)" \
             "output is not executable"
    fi
else
    fail "original Babet builds with an empty PATH (no external toolchain lookup)" \
         "$(cat "${BUILD_STDERR}")"
fi

# Exactly one output file must be needed on the application side. The project,
# logs and test machinery deliberately live elsewhere.
shopt -s nullglob dotglob
target_entries=("${TARGET}"/*)
shopt -u nullglob dotglob
if [ "${#target_entries[@]}" -eq 1 ] && [ "${target_entries[0]}" = "${APP}" ]; then
    pass "--create-exe publishes exactly one application file"
else
    fail "--create-exe publishes exactly one application file" \
         "target contains ${#target_entries[@]} entries"
fi

# A generated executable is an application, never another builder. It must
# reject both public spellings before executing the embedded main.lua.
for flag in --create-exe -c; do
    nested="${ROOT}/nested-${flag#-}"
    stdout_file="${LOGS}/refuse-${flag#-}.stdout"
    stderr_file="${LOGS}/refuse-${flag#-}.stderr"

    "${APP}" "${flag}" "${PROJECT}" "${nested}" \
        >"${stdout_file}" 2>"${stderr_file}"
    rc=$?

    if [ "${rc}" -ne 0 ] \
        && grep -Fq -- "--create-exe n'est pas disponible dans un exécutable généré" \
            "${stderr_file}" \
        && grep -Fq -- "Utilisez le binaire Babet original" "${stderr_file}" \
        && ! grep -Fq -- "PACKAGING_MAIN_EXECUTED" "${stdout_file}" \
        && [ ! -e "${nested}" ]; then
        pass "generated application refuses ${flag} before running main.lua"
    else
        fail "generated application refuses ${flag} before running main.lua" \
             "rc=${rc}; stdout=$(cat "${stdout_file}"); stderr=$(cat "${stderr_file}")"
    fi
done

# Generated applications retain babet.plugin.load only as a controlled refusal.
PLUGIN_REFUSAL_OUTPUT="$("${APP}" __plugin__ "${ROOT}/not-present.so" 2>&1)"
PLUGIN_REFUSAL_RC=$?
if [ "${PLUGIN_REFUSAL_RC}" -eq 0 ] \
    && grep -Fq 'PACKAGING_PLUGIN_REFUSAL:' <<<"${PLUGIN_REFUSAL_OUTPUT}" \
    && grep -Fq 'unavailable in generated --create-exe applications' \
        <<<"${PLUGIN_REFUSAL_OUTPUT}"; then
    pass "generated application refuses native plugin loading without extraction"
else
    fail "generated application refuses native plugin loading without extraction" \
         "rc=${PLUGIN_REFUSAL_RC}; output=${PLUGIN_REFUSAL_OUTPUT}"
fi

# Copying/renaming the real Babet binary must not change its identity. It has no
# embedded main.lua, so the same builder code remains available under any name.
RENAMED="${ROOT}/totally-renamed-babet"
cp -- "${BINARY}" "${RENAMED}"
COPY_APP="${COPY_TARGET}/application-from-copy"
if "${RENAMED}" --create-exe "${PROJECT}" "${COPY_APP}" \
        >"${LOGS}/copy.stdout" 2>"${LOGS}/copy.stderr" \
        && [ -x "${COPY_APP}" ]; then
    pass "copied/renamed original Babet remains a builder"
else
    fail "copied/renamed original Babet remains a builder" \
         "$(cat "${LOGS}/copy.stderr" 2>/dev/null)"
fi

# Remove the source project completely, then execute only the generated file
# from an unrelated empty directory. This proves the normal application path
# does not depend on source files or a neighbouring Babet installation.
rm -rf -- "${PROJECT}"
autonomous_output=$(cd "${ISOLATED_CWD}" && "${APP}" __run__ 2>&1)
autonomous_rc=$?
if [ "${autonomous_rc}" -eq 0 ] \
    && [ "${autonomous_output}" = "PACKAGING_AUTONOMOUS_OK" ]; then
    pass "generated application runs standalone after source project removal"
else
    fail "generated application runs standalone after source project removal" \
         "rc=${autonomous_rc}; output=${autonomous_output}"
fi

finish
