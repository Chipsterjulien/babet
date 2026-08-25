#!/bin/bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="${ROOT}/NCURSES_DESIGN.md"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

require_pattern() {
    local pattern="$1"
    local label="$2"
    if grep -Eq -- "$pattern" "${DOC}"; then pass "${label}"; else fail "${label}"; fi
}

forbid_pattern() {
    local pattern="$1"
    local label="$2"
    if grep -Eq -- "$pattern" "${DOC}"; then fail "${label}"; else pass "${label}"; fi
}

if [ -f "${DOC}" ]; then
    pass "ncurses design contract exists"
else
    fail "ncurses design contract exists"
    echo "ncurses design contracts: ${PASS} PASS / ${FAIL} FAIL"
    exit 1
fi

require_pattern 'ncursesw' "wide-character ncursesw is the selected backend"
require_pattern 'process_terminal_internal\.cpp' "existing process terminal registry remains the ownership source"
require_pattern 'normal.*curses.*child_process.*terminal_reclaimed_curses_pending|terminal_reclaimed_curses_pending' "one-owner state model is documented"
require_pattern 'must \*\*not call `initscr\(\)`\*\*|must \*\*not call `initscr' "initscr uncontrolled-exit path is forbidden"
require_pattern 'setupterm.*errret' "setupterm error classification is required"
require_pattern 'newterm\(\)' "newterm initialization is required"
require_pattern 'Every ncurses function call runs on Babet.s main thread|Every ncurses function call runs on Babet' "all ncurses calls are main-thread only"
require_pattern 'service_terminal_events_on_main_thread' "central main-thread restoration helper is specified"
require_pattern 'must \*\*not\*\* call any ncurses function' "terminal monitor is forbidden from calling ncurses"
require_pattern 'worker operation that would take the interactive terminal.*fails|worker.*foreground-resume rejection' "worker interactive handoff is rejected while curses is active"
require_pattern 'SIGWINCH' "SIGWINCH policy is explicit"
require_pattern 'SIGTSTP / SIGCONT|SIGTSTP.*SIGCONT' "SIGTSTP/SIGCONT policy is explicit"
require_pattern 'SIGINT / SIGTERM / SIGHUP|SIGINT.*SIGTERM.*SIGHUP' "SIGINT/SIGTERM/SIGHUP policy is explicit"
require_pattern 'SIGSEGV.*SIGABRT' "fatal signals explicitly forbid ncurses cleanup"
require_pattern 'with-fallbacks' "embedded terminfo fallback strategy is documented"
require_pattern 'missing `TERM`|missing/empty `TERM`' "missing TERM is a controlled error"
require_pattern 'unknown `TERM`|unknown or generic terminal' "unknown TERM is a controlled error"
require_pattern 'thread-local `LC_CTYPE`|thread-local.*locale' "UTF-8 locale handling avoids process-global mutation"
require_pattern 'Lot 5 test matrix' "implementation test matrix is documented"

# The design deliberately does not freeze raw ncurses C handles as public API.
require_pattern 'no public API exposes raw `WINDOW \*`, `SCREEN \*`' "raw ncurses handles are not public ABI"

# The design must never suggest that the monitor performs curses restoration.
forbid_pattern 'monitor (thread )?(calls|must call) `?(reset_prog_mode|doupdate)' "monitor never owns curses restoration"

echo "ncurses design contracts: ${PASS} PASS / ${FAIL} FAIL"
[ "${FAIL}" -eq 0 ]
