#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SCRIPT="${ROOT}/clear_code.sh"
PASS=0
FAIL=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-clear-code-test.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

expect_absent() {
    local label="$1"
    local path="$2"
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then pass "$label"; else fail "$label"; fi
}

expect_present() {
    local label="$1"
    local path="$2"
    if [ -e "$path" ] || [ -L "$path" ]; then pass "$label"; else fail "$label"; fi
}

make_fixture() {
    local dir="$1"
    mkdir -p "$dir/src/third_party" "$dir/build/fltk-prototype" "$dir/test" \
        "$dir/downloads" "$dir/dist"
    cp "$SOURCE_SCRIPT" "$dir/clear_code.sh"
    chmod +x "$dir/clear_code.sh"
    printf 'normal\n' > "$dir/babet-tests.txt"
    printf 'fltk\n' > "$dir/babet-fltk-tests.txt"
    printf 'scratch\n' > "$dir/MODIFIED_FILES.txt"
    printf 'notes\n' > "$dir/GITHUB_RELEASE_test.md"
    printf 'keep me\n' > "$dir/user-backup.zip"
    printf 'keep me too\n' > "$dir/notes.md"
}

DEFAULT_FIXTURE="$TMP/default"
make_fixture "$DEFAULT_FIXTURE"
"$DEFAULT_FIXTURE/clear_code.sh" >/dev/null
expect_absent "default cleanup removes build tree" "$DEFAULT_FIXTURE/build"
expect_absent "default cleanup removes test tree" "$DEFAULT_FIXTURE/test"
expect_absent "default cleanup removes legacy third_party tree" "$DEFAULT_FIXTURE/src/third_party"
expect_present "default cleanup preserves downloads" "$DEFAULT_FIXTURE/downloads"
expect_present "default cleanup preserves dist" "$DEFAULT_FIXTURE/dist"
expect_present "default cleanup preserves normal validation log" "$DEFAULT_FIXTURE/babet-tests.txt"
expect_present "default cleanup preserves FLTK validation log" "$DEFAULT_FIXTURE/babet-fltk-tests.txt"
expect_present "default cleanup preserves release scratch" "$DEFAULT_FIXTURE/MODIFIED_FILES.txt"

ALL_FIXTURE="$TMP/all"
make_fixture "$ALL_FIXTURE"
"$ALL_FIXTURE/clear_code.sh" --all >/dev/null
expect_absent "--all removes build tree" "$ALL_FIXTURE/build"
expect_absent "--all removes test tree" "$ALL_FIXTURE/test"
expect_absent "--all removes legacy third_party tree" "$ALL_FIXTURE/src/third_party"
expect_absent "--all removes downloads" "$ALL_FIXTURE/downloads"
expect_absent "--all removes dist" "$ALL_FIXTURE/dist"
expect_absent "--all removes normal validation log" "$ALL_FIXTURE/babet-tests.txt"
expect_absent "--all removes FLTK validation log" "$ALL_FIXTURE/babet-fltk-tests.txt"
expect_absent "--all removes MODIFIED_FILES scratch" "$ALL_FIXTURE/MODIFIED_FILES.txt"
expect_absent "--all removes GITHUB_RELEASE scratch" "$ALL_FIXTURE/GITHUB_RELEASE_test.md"
expect_present "--all never deletes an unrelated ZIP" "$ALL_FIXTURE/user-backup.zip"
expect_present "--all never deletes an unrelated Markdown file" "$ALL_FIXTURE/notes.md"

if "$ALL_FIXTURE/clear_code.sh" --definitely-invalid >/dev/null 2>&1; then
    fail "unknown cleanup option is rejected"
else
    pass "unknown cleanup option is rejected"
fi

if "$ALL_FIXTURE/clear_code.sh" --help | grep -Fq 'journaux de tests et scratch release'; then
    pass "cleanup help documents full-reset scope"
else
    fail "cleanup help documents full-reset scope"
fi

echo "clear_code cleanup contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
