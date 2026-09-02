#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-gui-loader.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

compile_fake() {
    local source="$1" outdir="$2"
    mkdir -p "$outdir"
    cc -std=c99 -Wall -Wextra -Werror -fPIC -shared \
        -Wl,-soname,libgtk-4.so.1 \
        "$ROOT/$source" -o "$outdir/libgtk-4.so.1"
}

if ! c++ -std=c++23 -Wall -Wextra -Werror -pedantic \
    -I"$ROOT/src/lua_bindings" \
    "$ROOT/tests/gui/gtk_loader_probe.cpp" \
    "$ROOT/src/lua_bindings/gui_gtk_loader.cpp" \
    -ldl -o "$TMP/probe"; then
    echo "[FAIL] GTK loader standalone probe compiles"
    exit 1
fi
pass "GTK loader standalone probe compiles without GTK headers"

compile_fake tests/gui/fake_gtk4_good.c "$TMP/good" || exit 1
compile_fake tests/gui/fake_gtk4_init_fail.c "$TMP/init-fail" || exit 1
compile_fake tests/gui/fake_gtk4_missing_symbol.c "$TMP/missing" || exit 1

LOG="$TMP/good.log"
OUT="$(LD_LIBRARY_PATH="$TMP/good" BABET_FAKE_GTK_LOG="$LOG" "$TMP/probe" load 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "LOAD_OK" ]; then
    pass "lazy loader accepts a complete GTK4 runtime"
else
    fail "lazy loader accepts a complete GTK4 runtime"
fi
if [ ! -e "$LOG" ]; then
    pass "availability/load does not initialize GTK"
else
    fail "availability/load does not initialize GTK"
fi

LOG="$TMP/init.log"
OUT="$(LD_LIBRARY_PATH="$TMP/good" BABET_FAKE_GTK_LOG="$LOG" "$TMP/probe" init 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "INIT_OK" ]; then
    pass "GTK4 initialization succeeds through resolved functions"
else
    fail "GTK4 initialization succeeds through resolved functions"
fi
if [ "$(cat "$LOG" 2>/dev/null)" = $'disable_setlocale\ninit_check' ]; then
    pass "locale protection runs before GTK initialization"
else
    fail "locale protection runs before GTK initialization"
fi

LOG="$TMP/fail.log"
set +e
OUT="$(LD_LIBRARY_PATH="$TMP/init-fail" BABET_FAKE_GTK_LOG="$LOG" "$TMP/probe" init 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 3 ] && grep -Fq 'no usable graphical display' <<<"$OUT"; then
    pass "gtk_init_check failure is recoverable and diagnosed"
else
    fail "gtk_init_check failure is recoverable and diagnosed"
fi
if [ "$(cat "$LOG" 2>/dev/null)" = $'disable_setlocale\ninit_check' ]; then
    pass "failed initialization still protects locale first"
else
    fail "failed initialization still protects locale first"
fi

set +e
OUT="$(LD_LIBRARY_PATH="$TMP/missing" "$TMP/probe" load 2>&1)"
RC=$?
set -e
if [ "$RC" -eq 2 ] && grep -Fq "missing GTK 4 dependency symbol 'gtk_init_check'" <<<"$OUT"; then
    pass "missing required GTK symbol fails closed"
else
    fail "missing required GTK symbol fails closed"
fi
if grep -Fq 'apt install libgtk-4-1' <<<"$OUT" \
    && grep -Fq 'pacman -S gtk4' <<<"$OUT" \
    && grep -Fq 'dnf install gtk4' <<<"$OUT"; then
    pass "GTK loader diagnostic carries common distro install examples"
else
    fail "GTK loader diagnostic carries common distro install examples"
fi

LOADER_LOG="$TMP/missing-loader.log"
set +e
OUT="$(LD_LIBRARY_PATH="$TMP/missing" BABET_FAKE_GTK_LOADER_LOG="$LOADER_LOG" \
    "$TMP/probe" load-twice 2>&1)"
RC=$?
set -e

if [ "$RC" -eq 4 ] \
    && grep -Fq "missing GTK 4 dependency symbol 'gtk_init_check'" <<<"$OUT"; then
    pass "failed GTK symbol validation is memoized"
else
    fail "failed GTK symbol validation is memoized"
fi

if [ "$(grep -c '^load$' "$LOADER_LOG" 2>/dev/null || true)" -eq 1 ]; then
    pass "failed GTK runtime is opened only once per process"
else
    fail "failed GTK runtime is opened only once per process"
fi

echo "GTK4 lazy-loader regression: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
