#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <babet-binary>" >&2
    exit 1
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BABET="$1"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-size-audit-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
REPORT="$TMP/report.txt"

bash "$ROOT/tools/analyze_link_map.sh" \
    "$ROOT/tools/fixtures/size_link.map" "$BABET" "$REPORT" >/dev/null

PASS=0
FAIL=0
if grep -Fq "Linker script and memory map" "$ROOT/tools/fixtures/size_link.map"; then
    echo "[FAIL] fixture exercises a localized/non-English linker-map heading"
    FAIL=$((FAIL+1))
else
    echo "[PASS] fixture exercises a localized/non-English linker-map heading"
    PASS=$((PASS+1))
fi
check(){
    local pattern="$1" label="$2"
    if grep -Fq "$pattern" "$REPORT"; then
        echo "[PASS] $label"; PASS=$((PASS+1))
    else
        echo "[FAIL] $label"; FAIL=$((FAIL+1))
    fi
}
check "GUI bridge (Babet code)" "link-map analyser classifies GUI bridge"
check "SQLite" "link-map analyser classifies SQLite"
check "OpenSSL crypto/TLS (shared)" "link-map analyser classifies shared OpenSSL"
check "RE2/Abseil dependencies" "link-map analyser classifies RE2/Abseil"
check "ncursesw (static dependency)" "link-map analyser classifies ncursesw"
check "Packaging/--create-exe" "link-map analyser classifies packaging"
check "CLI main" "link-map analyser classifies CLI main"
check "NOT removable-size deltas" "link-map report preserves non-additive warning"

echo "size attribution runtime regression: ${PASS} PASS / ${FAIL} FAIL"
[[ ${FAIL} -eq 0 ]]
