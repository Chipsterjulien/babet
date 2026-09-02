#!/usr/bin/env bash
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BINARY="${1:-}"
if [ -z "$BINARY" ] || [ ! -x "$BINARY" ]; then
    echo "Usage: $0 /path/to/babet" >&2
    exit 2
fi
BINARY="$(cd -- "$(dirname -- "$BINARY")" && pwd -P)/$(basename -- "$BINARY")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/babet-gui-runtime.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0
FAIL=0
pass(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
fail(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

mkdir -p "$TMP/lib" "$TMP/missing-lib" "$TMP/project" "$TMP/missing-project" \
    "$TMP/coroutine-project" "$TMP/out"
if ! cc -std=c99 -Wall -Wextra -Werror -fPIC -shared \
    -Wl,-soname,libgtk-4.so.1 \
    "$ROOT/tests/gui/fake_gtk4_runtime.c" -o "$TMP/lib/libgtk-4.so.1"; then
    echo "[FAIL] fake GTK4 runtime compiles"
    exit 1
fi
pass "fake GTK4 runtime compiles"

if ! cc -std=c99 -Wall -Wextra -Werror -fPIC -shared \
    -Wl,-soname,libgtk-4.so.1 \
    "$ROOT/tests/gui/fake_gtk4_missing_symbol.c" -o "$TMP/missing-lib/libgtk-4.so.1"; then
    echo "[FAIL] incomplete fake GTK4 runtime compiles"
    exit 1
fi
pass "incomplete fake GTK4 runtime compiles"

cat > "$TMP/missing-project/main.lua" <<'LUA'
local ok, err = babet.gui.available()
assert(ok == nil, "incomplete GTK unexpectedly accepted")
assert(type(err) == "string" and err:find("GTK 4", 1, true), tostring(err))
assert(err:find("apt install libgtk%-4%-1") or err:find("apt install libgtk-4-1", 1, true), tostring(err))
print("BABET_GUI_MISSING_GTK_OK")
LUA

if LD_LIBRARY_PATH="$TMP/missing-lib" "$BINARY" "$TMP/missing-project" \
        >"$TMP/missing.out" 2>"$TMP/missing.err" \
        && grep -Fq 'BABET_GUI_MISSING_GTK_OK' "$TMP/missing.out"; then
    pass "Lua-facing missing GTK dependency fails cleanly with install guidance"
else
    fail "Lua-facing missing GTK dependency fails cleanly with install guidance"
fi

cat > "$TMP/coroutine-project/main.lua" <<'LUA'
local gui = babet.gui

local ok, err = gui.init()
assert(ok, err)

local win = gui.window({
    title = "Coroutine guard",
    width = 160,
    height = 80,
})
local button = gui.button("quit")

assert(win:add(button))

-- Cette callback permet à l'ancienne implémentation incorrecte de sortir
-- proprement de gui.run() au lieu de bloquer le test.
assert(button:onClick(function()
    assert(gui.quit())
end))

assert(win:show())

local co = coroutine.create(function()
    return gui.run()
end)

local resumed, coroutine_err = coroutine.resume(co)

assert(not resumed, "gui.run unexpectedly accepted a Lua coroutine")
assert(
    tostring(coroutine_err):find("main Lua thread", 1, true),
    tostring(coroutine_err)
)

assert(win:close())

print("BABET_GUI_COROUTINE_REJECTED")
LUA

if LD_LIBRARY_PATH="$TMP/lib" "$BINARY" "$TMP/coroutine-project" \
        >"$TMP/coroutine.out" 2>"$TMP/coroutine.err" \
        && grep -Fq 'BABET_GUI_COROUTINE_REJECTED' "$TMP/coroutine.out"; then
    pass "gui.run rejects invocation from a Lua coroutine"
else
    fail "gui.run rejects invocation from a Lua coroutine"
fi

cat > "$TMP/project/main.lua" <<'LUA'
local gui = babet.gui
local ok, err = gui.init()
assert(ok, err)

local win = gui.window({title = "Babet GUI", width = 320, height = 160})
local box = gui.box({orientation = "vertical", spacing = 4})
local label = gui.label("initial")
local first = gui.button("first")
local second = gui.button("second")

assert(win:add(box))
assert(box:add(label))
assert(box:add(first))
assert(box:add(second))

local curses_ok, curses_err = pcall(function() babet.curses.start() end)
assert(not curses_ok and tostring(curses_err):find("GUI session is already active", 1, true),
       tostring(curses_err))

assert(first:onClick(function()
    error("intentional GUI callback sentinel")
end))

assert(second:onClick(function()
    assert(label:setText("clicked"))
    assert(gui.quit())
end))

assert(win:show())
assert(gui.run())
assert(label:setText("after-run"))
assert(win:close())

local alive, dead_err = pcall(function() label:setText("must-fail") end)
assert(not alive and tostring(dead_err):find("has already been destroyed", 1, true),
       tostring(dead_err))
print("BABET_GUI_RUNTIME_OK")
LUA

run_folder() {
    local stdout="$1" stderr="$2" log="$3"
    LD_LIBRARY_PATH="$TMP/lib" BABET_FAKE_GTK_LOG="$log" \
        "$BINARY" "$TMP/project" >"$stdout" 2>"$stderr"
}
run_app() {
    local executable="$1" stdout="$2" stderr="$3" log="$4"
    LD_LIBRARY_PATH="$TMP/lib" BABET_FAKE_GTK_LOG="$log" \
        "$executable" >"$stdout" 2>"$stderr"
}

if run_folder "$TMP/folder.out" "$TMP/folder.err" "$TMP/folder.log" < /dev/null; then
    if grep -Fq 'BABET_GUI_RUNTIME_OK' "$TMP/folder.out" \
        && grep -Fq 'intentional GUI callback sentinel' "$TMP/folder.err" \
        && grep -Fq 'label:clicked' "$TMP/folder.log" \
        && grep -Fq 'label:after-run' "$TMP/folder.log" \
        && grep -Fq 'closure-notify:clicked' "$TMP/folder.log"; then
        pass "folder GUI executes GTK events, contains callback error, and recovers"
    else
        fail "folder GUI executes GTK events, contains callback error, and recovers"
    fi
else
    fail "folder GUI executes GTK events, contains callback error, and recovers"
fi

APP="$TMP/out/gui-app"
if "$BINARY" --create-exe "$TMP/project" "$APP" >"$TMP/build.out" 2>"$TMP/build.err" \
        && [ -x "$APP" ]; then
    pass "--create-exe builds the GUI project"
else
    fail "--create-exe builds the GUI project"
fi

# The generated application must not need the source project after publication.
rm -rf -- "$TMP/project"
if run_app "$APP" "$TMP/app.out" "$TMP/app.err" "$TMP/app.log" < /dev/null; then
    if grep -Fq 'BABET_GUI_RUNTIME_OK' "$TMP/app.out" \
        && grep -Fq 'intentional GUI callback sentinel' "$TMP/app.err" \
        && grep -Fq 'label:clicked' "$TMP/app.log" \
        && grep -Fq 'closure-notify:clicked' "$TMP/app.log"; then
        pass "generated one-file GUI app runs after source removal"
    else
        fail "generated one-file GUI app runs after source removal"
    fi
else
    fail "generated one-file GUI app runs after source removal"
fi

shopt -s nullglob dotglob
entries=("$TMP/out"/*)
shopt -u nullglob dotglob
if [ "${#entries[@]}" -eq 1 ] && [ "${entries[0]}" = "$APP" ]; then
    pass "GUI --create-exe publishes exactly one application file"
else
    fail "GUI --create-exe publishes exactly one application file"
fi

if ! ldd "$BINARY" 2>/dev/null | grep -Eiq 'gtk|gobject|glib-2'; then
    pass "normal Babet has no direct GTK/GObject/GLib GUI dependency"
else
    fail "normal Babet has no direct GTK/GObject/GLib GUI dependency"
fi

if grep -Fq 'disable_setlocale' "$TMP/app.log" \
    && grep -Fq 'init_check' "$TMP/app.log"; then
    pass "generated GUI app protects locale before GTK initialization"
else
    fail "generated GUI app protects locale before GTK initialization"
fi

echo "GUI runtime regression: ${PASS} PASS / ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
