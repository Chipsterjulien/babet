#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANITIZERS=0
BINARY=""

for arg in "$@"; do
    case "$arg" in
        --sanitizers)
            SANITIZERS=1
            ;;
        *)
            if [ -n "${BINARY}" ]; then
                echo "Usage: $0 [babet-binary] [--sanitizers]" >&2
                exit 1
            fi
            BINARY="$arg"
            ;;
    esac
done

if [ -z "${BINARY}" ]; then
    BINARY="${ROOT}/test/babet"
fi

if [ "${SANITIZERS}" -eq 1 ]; then
    BUILD_DIR="${ROOT}/build/project_build_sanitizers"
else
    BUILD_DIR="${ROOT}/build/project_build"
fi
LIB="${BUILD_DIR}/libbabet.a"
HOST="${BUILD_DIR}/babet_embedding_smoke"
CPP_HOST="${BUILD_DIR}/babet_embedding_cpp_callback_smoke"
SDK_DIR="${ROOT}/build/embedding-sdk"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

max_glibc_requirement()
{
    local file="$1"
    if ! command -v objdump >/dev/null 2>&1 || [ ! -f "${file}" ]; then
        return 1
    fi
    objdump -T "${file}" 2>/dev/null \
        | sed -n 's/.*GLIBC_\([0-9][0-9.]*\).*/\1/p' \
        | sort -uV \
        | tail -1
}

if [ ! -f "${BINARY}" ]; then
    echo "ÉCHEC : binaire Babet introuvable : ${BINARY}"
    exit 1
fi
if [ ! -d "${BUILD_DIR}" ]; then
    echo "ÉCHEC : build CMake introuvable : ${BUILD_DIR}"
    exit 1
fi

if cmake --build "${BUILD_DIR}" --target babet_embedding_smoke babet_embedding_cpp_callback_smoke; then
    if [ "${SANITIZERS}" -eq 1 ]; then
        pass "C embedding host builds against the sanitizer libbabet target"
    else
        pass "C embedding host builds against the in-tree libbabet target"
    fi
else
    if [ "${SANITIZERS}" -eq 1 ]; then
        fail "C embedding host builds against the sanitizer libbabet target"
    else
        fail "C embedding host builds against the in-tree libbabet target"
    fi
fi

if [ -f "${LIB}" ] && ar t "${LIB}" >/dev/null 2>&1; then
    pass "libbabet.a is a valid static archive"
else
    fail "libbabet.a is a valid static archive"
fi

if [ -f "${LIB}" ] && nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_create$'; then
    pass "libbabet.a exports the C embedding entry points"
else
    fail "libbabet.a exports the C embedding entry points"
fi

if [ -f "${LIB}" ] && nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_set_search_root$'; then
    pass "libbabet.a exports the search-root entry point"
else
    fail "libbabet.a exports the search-root entry point"
fi

if [ -f "${LIB}" ] &&
   nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_set_global$' &&
   nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_get_global$'; then
    pass "libbabet.a exports the scalar value entry points"
else
    fail "libbabet.a exports the scalar value entry points"
fi

if [ -f "${LIB}" ] && nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_call_global$'; then
    pass "libbabet.a exports the scalar call entry point"
else
    fail "libbabet.a exports the scalar call entry point"
fi

if [ -f "${LIB}" ] &&
   nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_register_host_function$' &&
   nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_host_call_set_result$' &&
   nm -g --defined-only "${LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_host_call_set_error$'; then
    pass "libbabet.a exports the narrow host-function entry points"
else
    fail "libbabet.a exports the narrow host-function entry points"
fi

if [ -x "${HOST}" ] && "${HOST}"; then
    pass "C embedding host exercises create/run/error/thread/destroy lifecycle"
else
    fail "C embedding host exercises create/run/error/thread/destroy lifecycle"
fi

if [ -x "${CPP_HOST}" ] && "${CPP_HOST}"; then
    pass "C++ host callback exceptions are contained and the context recovers"
else
    fail "C++ host callback exceptions are contained and the context recovers"
fi

if ldd "${BINARY}" 2>/dev/null | grep -Eq 'libbabet\.so'; then
    fail "official Babet binary has no dynamic libbabet dependency"
else
    pass "official Babet binary has no dynamic libbabet dependency"
fi

# The relocatable SDK is a normal-build release artifact. Sanitizer runs still
# exercise the actual instrumented in-tree library above, but do not attempt to
# redistribute/link it without sanitizer flags.
if [ "${SANITIZERS}" -eq 0 ]; then
    SDK_HEADER="${SDK_DIR}/include/babet/babet.h"
    SDK_LIB="${SDK_DIR}/lib/libbabet.a"
    if [ -f "${SDK_HEADER}" ] && [ -f "${SDK_LIB}" ] &&
       ar t "${SDK_LIB}" >/dev/null 2>&1; then
        pass "standalone embedding SDK contains a public header and valid flattened libbabet.a"
    else
        fail "standalone embedding SDK contains a public header and valid flattened libbabet.a"
    fi

    if [ -f "${SDK_LIB}" ] &&
       nm -g --defined-only "${SDK_LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_create$' &&
       nm -g --defined-only "${SDK_LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_call_global$' &&
       nm -g --defined-only "${SDK_LIB}" 2>/dev/null | grep -Eq '[[:space:]]babet_context_register_host_function$'; then
        pass "standalone SDK archive retains the public embedding symbols"
    else
        fail "standalone SDK archive retains the public embedding symbols"
    fi

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/babet-embedding-external.XXXXXX")" || exit 1
    trap 'rm -rf -- "${TMP_DIR}"' EXIT
    MOVED_SDK="${TMP_DIR}/sdk moved with spaces"
    mkdir -p "${MOVED_SDK}"
    cp -a "${SDK_DIR}/." "${MOVED_SDK}/"
    cp -- "${ROOT}/tests/embedding_external_smoke.c" "${TMP_DIR}/host.c"

    CC_BIN="${CC:-cc}"
    CXX_BIN="${CXX:-c++}"
    EXTERNAL_BUILD_OK=1
    if ! "${CC_BIN}" -std=c99 -Wall -Wextra -Werror \
        -I"${MOVED_SDK}/include" -c "${TMP_DIR}/host.c" \
        -o "${TMP_DIR}/host.o"; then
        EXTERNAL_BUILD_OK=0
    fi

    SYSTEM_LIBS=(-ldl -pthread -lm)
    if [ "$(getconf LONG_BIT 2>/dev/null || printf '64')" = "32" ]; then
        SYSTEM_LIBS+=(-latomic)
    fi
    if [ "${EXTERNAL_BUILD_OK}" -eq 1 ] &&
       ! "${CXX_BIN}" "${TMP_DIR}/host.o" "${MOVED_SDK}/lib/libbabet.a" \
            "${SYSTEM_LIBS[@]}" -o "${TMP_DIR}/external-host"; then
        EXTERNAL_BUILD_OK=0
    fi

    if [ "${EXTERNAL_BUILD_OK}" -eq 1 ]; then
        pass "external C host compiles and links using only the moved standalone SDK"
    else
        fail "external C host compiles and links using only the moved standalone SDK"
    fi

    if [ "${EXTERNAL_BUILD_OK}" -eq 1 ] && "${TMP_DIR}/external-host"; then
        pass "external C host runs against the standalone static SDK"
    else
        fail "external C host runs against the standalone static SDK"
    fi

    EXAMPLES_BUILD="${TMP_DIR}/examples-build"
    if cmake -S "${MOVED_SDK}/examples/embedding" -B "${EXAMPLES_BUILD}" \
            -DBABET_SDK_DIR="${MOVED_SDK}" &&
       cmake --build "${EXAMPLES_BUILD}"; then
        pass "standalone SDK documentation examples configure and build out of tree"
        if ctest --test-dir "${EXAMPLES_BUILD}" --output-on-failure; then
            pass "standalone SDK documentation examples execute successfully"
        else
            fail "standalone SDK documentation examples execute successfully"
        fi
    else
        fail "standalone SDK documentation examples configure and build out of tree"
        fail "standalone SDK documentation examples execute successfully"
    fi

    BABET_GLIBC="$(max_glibc_requirement "${BINARY}" || true)"
    HOST_GLIBC="$(max_glibc_requirement "${TMP_DIR}/external-host" || true)"
    if [ -n "${BABET_GLIBC}" ]; then
        echo "[INFO] highest GLIBC_* requirement of maintained Babet binary: GLIBC_${BABET_GLIBC}"
    else
        echo "[INFO] GLIBC_* requirement of maintained Babet binary unavailable"
    fi
    if [ -n "${HOST_GLIBC}" ]; then
        echo "[INFO] highest GLIBC_* requirement of freshly linked SDK host: GLIBC_${HOST_GLIBC}"
    else
        echo "[INFO] GLIBC_* requirement of freshly linked SDK host unavailable"
    fi

    rm -rf -- "${TMP_DIR}"
    trap - EXIT
else
    echo "[INFO] standalone embedding SDK smoke skipped for sanitizer build"
fi

echo "embedding runtime regression: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
