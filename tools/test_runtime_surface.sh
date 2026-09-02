#!/bin/bash
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-}"
if [ -z "${BINARY}" ] || [ ! -x "${BINARY}" ]; then
    echo "runtime surface: missing Babet binary" >&2
    exit 1
fi
output="$("${BINARY}" "${ROOT}/tools/test_runtime_surface.lua" 2>&1)"
rc=$?
if [ ${rc} -eq 0 ] && grep -Eq '^BABET_RUNTIME_SURFACE_OK:[0-9]+$' <<<"${output}"; then
    echo "[PASS] exact babet.* top-level runtime surface: ${output}"
    exit 0
fi
echo "[FAIL] exact babet.* top-level runtime surface - rc=${rc}; output=${output}" >&2
exit 1
