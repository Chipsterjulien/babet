#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${ROOT}/GUI_STUDY.md"
TODO="${ROOT}/todo"
INV="${ROOT}/INVARIANTS.md"
README="${ROOT}/README.md"
README_FR="${ROOT}/README.fr.md"

pass=0
fail=0

check() {
    local description="$1"
    shift
    if "$@"; then
        echo "[PASS] ${description}"
        pass=$((pass + 1))
    else
        echo "[FAIL] ${description}"
        fail=$((fail + 1))
    fi
}

contains() {
    local file="$1"
    local pattern="$2"
    grep -Fq -- "$pattern" "$file"
}

check "GUI study contract exists" test -f "$DOC"
check "GUI stays outside the normal Babet CLI" contains "$DOC" 'separate companion host'
check "normal CLI keeps zero GUI dependency cost" contains "$DOC" 'ordinary Babet CLI remains exactly zero'
check "GUI consumes the standalone libbabet SDK" contains "$DOC" 'built against the standalone `libbabet` SDK'
check "FLTK is the preferred first prototype" contains "$DOC" '**FLTK 1.4.x is the preferred first prototype backend.**'
check "wxWidgets is the first fallback" contains "$DOC" '**wxWidgets 3.2.x is the first fallback**'
check "GTK is compared but not preselected" contains "$DOC" '**Not selected as Babet'
check "Qt is rejected for the first GUI host" contains "$DOC" '**Rejected for the first Babet GUI host**'
check "SDL/ImGui-style stacks are not treated as conventional desktop widgets" contains "$DOC" 'Not a conventional desktop widget toolkit'
check "FLTK Linux study keeps Wayland/X11 hybrid support" contains "$DOC" 'hybrid Wayland/X11'
check "GUI toolkit calls stay on the main thread" contains "$DOC" 'GUI toolkit calls remain main-thread-only'
check "workers are forbidden from manipulating GUI widgets" contains "$DOC" 'must never manipulate GUI widgets'
check "GUI bridge remains narrow after Lot 10" contains "$DOC" 'Lot 10 implements only that observed requirement'
check "generic GUI object identity remains deferred" contains "$DOC" 'Opaque widget IDs'
check "initial event callback design reuses call_global" contains "$DOC" '`babet_context_call_global()`'
check "existing create-exe semantics remain unchanged" contains "$DOC" 'existing `babet --create-exe` contract does **not** change'
check "GUI builder packaging is kept separate" contains "$DOC" 'separate `babet-gui` build/release problem'
check "normal build must not download a GUI toolkit" contains "$DOC" 'no GUI toolkit download in the normal bootstrap'
check "study requires measuring the real prototype" contains "$DOC" 'Measure the actual prototype'
check "GUI integration does not use the native plugin loader" contains "$DOC" 'generic `.so` plugin loader'
check "Lua internals stay private for GUI integration" contains "$DOC" 'exposing `lua_State *` just to make a GUI binding convenient'
check "roadmap records completed GUI candidate comparison" contains "$TODO" '[x] Compare real GUI candidates'
check "roadmap records the separate-host decision" contains "$TODO" '[x] Keep GUI code out of the normal `babet` executable'
check "roadmap records FLTK as preferred prototype" contains "$TODO" '[x] Select FLTK 1.4.x as the preferred first prototype backend'
check "invariants keep optional GUI outside the CLI" contains "$INV" 'separate companion host consuming the standalone'
check "English README links the GUI study" contains "$README" '[`GUI_STUDY.md`](GUI_STUDY.md)'
check "French README links the GUI study" contains "$README_FR" '[`GUI_STUDY.md`](GUI_STUDY.md)'

echo "GUI study contracts: ${pass} PASS / ${fail} FAIL"
[ "$fail" -eq 0 ]
