#!/bin/bash
# Contrats structurels de l'implémentation ncursesw (Lot 5).
set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}" || exit 1

pass=0
fail=0
ok() { echo "[PASS] $1"; pass=$((pass + 1)); }
ko() { echo "[FAIL] $1"; fail=$((fail + 1)); }
require() {
    local label="$1" file="$2" pattern="$3"
    if grep -Eq -- "${pattern}" "${file}"; then ok "${label}"; else ko "${label}"; fi
}
forbid() {
    local label="$1" file="$2" pattern="$3"
    if grep -Eq -- "${pattern}" "${file}"; then ko "${label}"; else ok "${label}"; fi
}

require "ncurses 6.6 is checksum-pinned" build_local.sh \
    'NCURSES_VERSION="6\.6"'
require "ncurses source checksum is fixed" build_local.sh \
    'NCURSES_SHA256="355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11"'
require "wide-character ncurses is built" build_local.sh '--enable-widec'
require "ncurses is built without shared libraries" build_local.sh '--without-shared'
require "optional GPM runtime integration is disabled" build_local.sh '--without-gpm'
require "ncurses build profile records GPM-disabled configuration" build_local.sh 'gpm=OFF'
sigwinch_disable_count=$(grep -c -- '--disable-sigwinch' build_local.sh || true)
if [ "${sigwinch_disable_count}" -eq 2 ]; then
    ok "bootstrap and final ncurses builds disable internal SIGWINCH handling"
else
    ko "bootstrap and final ncurses builds disable internal SIGWINCH handling"
fi
forbid "ncurses SIGWINCH handling is never explicitly re-enabled" build_local.sh '--enable-sigwinch'
require "ncurses build profile records Babet-owned SIGWINCH" build_local.sh 'sigwinch=OFF'
require "partial ncurses source trees are not reused" tools/build_dependency_utils.sh \
    'babet_ncurses_source_complete'
require "ncurses configure auxiliaries are part of source completeness" tools/build_dependency_utils.sh \
    'install-sh'
require "ncurses configure is invoked through a space-safe relative source path" build_local.sh \
    '"\.\./\$\{NCURSES_DIR\}/configure"'
require "fallback terminfo set is compiled in" build_local.sh \
    'NCURSES_FALLBACKS="linux,vt100,xterm,xterm-256color,screen,screen-256color,tmux,tmux-256color"'
require "fallback generation uses self-built ncurses tic" build_local.sh \
    '--with-tic-path="\$\{NCURSES_FINAL_WORKSPACE\}/tools/tic"'
require "fallback generation uses self-built ncurses infocmp" build_local.sh \
    '--with-infocmp-path="\$\{NCURSES_FINAL_WORKSPACE\}/tools/infocmp"'
require "ncurses bootstrap tools are built before final fallbacks" build_local.sh \
    'NCURSES_BOOTSTRAP_TIC=.*progs/tic'
require "final fallback build has a space-free workspace" tools/build_dependency_utils.sh \
    'mktemp -d /tmp/babet-ncurses-final\.XXXXXX'
require "final fallback build runs outside the checkout" build_local.sh \
    'cd "\$\{NCURSES_FINAL_WORKSPACE\}/build"'
require "final ncurses source is exposed through a space-free symlink" tools/build_dependency_utils.sh \
    'ln -s "\$\{source_dir\}" "\$\{workspace\}/source"'
require "completed ncurses artifacts are published only after final build" build_local.sh \
    'NCURSES_PUBLISH_DIR=.*\.build-publish'
forbid "ncurses C++ ABI probing is not disabled" build_local.sh '--without-cxx([[:space:]\\]|$)'
require "CMake requires the local static ncurses archive" CMakeLists.txt \
    'NCURSES_LIB.*NCURSES_INCLUDE'
require "Babet links the pinned ncurses archive" CMakeLists.txt '\$\{NCURSES_LIB\}'
require "ncurses licence is shipped with binary notices" THIRD_PARTY_NOTICES.md '^## ncursesw licence'

require "curses uses setupterm with errret" src/lua_bindings/curses.cpp \
    'setupterm\(term, STDOUT_FILENO, &errret\)'
require "curses uses newterm" src/lua_bindings/curses.cpp 'newterm\(term, stdout, stdin\)'
forbid "curses never uses initscr" src/lua_bindings/curses.cpp '\binitscr\s*\('
require "KEY_RESIZE compatibility is conditional when ncurses SIGWINCH is disabled" src/lua_bindings/curses.cpp '#ifdef KEY_RESIZE'
require "Babet resize path uses resize_term without ncurses event injection" src/lua_bindings/curses.cpp '::resize_term\('
forbid "Babet resize path never calls resizeterm which queues KEY_RESIZE" src/lua_bindings/curses.cpp '::resizeterm\('
require "curses API uses the common C++ exception boundary" src/lua_bindings/curses.cpp \
    'lua_cfunction_exception_boundary<Fn>'
require "curses is registered under babet" src/project_core/runtime_registration.cpp 'babet_curses::register_curses\(L\)'
require "shared Lua close services terminal before curses cleanup" src/project_core/runtime_registration.cpp \
    'babet_curses::service_terminal_events\(\);'
require "folder diagnostics are emitted only after Lua/curses cleanup" src/main.cpp \
    'loadLuaFile\(L, scriptPath, script_error\);'
require "packaged diagnostics are captured before Lua/curses cleanup" src/main.cpp \
    'const std::string execution_error'
require "Lua file loader no longer prints before terminal cleanup" src/project_core/loadLuaFile.cpp \
    'error = "Failed to load "'
forbid "Lua file loader does not write stderr directly" src/project_core/loadLuaFile.cpp \
    'std::cerr'

require "terminal registry exposes the four owner states" src/lua_bindings/process_terminal_internal.hpp \
    'terminal_reclaimed_curses_pending'
require "interactive launch prepares curses handoff" src/lua_bindings/process_common.cpp \
    'prepare_reserved_terminal_handoff'
require "interactive launch snapshots shell termios after curses suspension" src/lua_bindings/process_common.cpp \
    'cannot snapshot terminal after curses suspension'
require "foreground resume prepares curses handoff" src/lua_bindings/process.cpp \
    'prepare_foreground_resume'
require "worker/main identity is centralized" src/lua_bindings/main_thread.cpp \
    'pthread_equal'
require "signal hook services terminal events on the main thread" src/lua_bindings/signal.cpp \
    'babet_curses::service_terminal_events\(\);'
require "blocking wait safe-points also service deferred terminal signals" src/lua_bindings/signal.cpp \
    'wait/sleep/socket bloque'
require "blocking curses reads use bounded internal signal polling" src/lua_bindings/curses.cpp \
    'signal_poll_slice_ms = 50'
require "curses read polling uses a monotonic public timeout deadline" src/lua_bindings/curses.cpp \
    'using monotonic_clock = std::chrono::steady_clock'
require "curses read polling services terminal signals before each wait" src/lua_bindings/curses.cpp \
    'const bool handled_pending = signal_any_handled_pending\(\);'
require "controlled suspend advances a main-thread generation" src/lua_bindings/curses.cpp \
    '\+\+g_suspend_generation;'
require "controlled suspend explicitly blocks SIGTSTP before re-raising it" src/lua_bindings/curses.cpp \
    'pthread_sigmask\(SIG_BLOCK, &tstp_mask, &previous_mask\)'
require "controlled suspend explicitly unblocks pending SIGTSTP" src/lua_bindings/curses.cpp \
    'pthread_sigmask\(SIG_UNBLOCK, &tstp_mask, nullptr\)'
require "controlled suspend restores the caller signal mask after resume" src/lua_bindings/curses.cpp \
    'pthread_sigmask\(SIG_SETMASK, &previous_mask, nullptr\)'
require "curses read detects suspend/resume across safe-points" src/lua_bindings/curses.cpp \
    'g_suspend_generation != suspend_generation'
require "curses read polling preserves zero-timeout nonblocking input" src/lua_bindings/curses.cpp \
    'zero_timeout_polled'

# Le moniteur POSIX doit rester indépendant de ncurses. Extraire uniquement son
# corps évite qu'une référence valide située ailleurs dans le fichier ne masque
# une régression.
monitor_body="$(awk '
    /void \*terminal_exit_monitor_main\(void \*raw\)/ { in_body=1 }
    in_body { print }
    in_body && /^}/ { exit }
' src/lua_bindings/process_terminal_internal.cpp)"
if printf '%s\n' "${monitor_body}" | grep -Eq 'endwin|doupdate|reset_prog_mode|resizeterm|newterm|setupterm'; then
    ko "terminal exit monitor never calls ncurses"
else
    ok "terminal exit monitor never calls ncurses"
fi

forbid "curses stop does not reject a child-owned terminal" \
    src/lua_bindings/curses.cpp 'curses\.stop: an interactive child process owns the terminal'
require "curses cleanup never calls endwin while a child owns the terminal" \
    src/lua_bindings/curses.cpp 'owner != babet_process::detail::TerminalOwnerState::child_process'
require "UTF-8 locale is thread-local" src/lua_bindings/curses.cpp 'uselocale\('
forbid "curses never changes the process-global locale" src/lua_bindings/curses.cpp '\bsetlocale\s*\('
require "OOM standalone regression links curses-neutral test stubs" tools/test_lua_longjmp_oom.sh \
    'lua_longjmp_oom_curses_stubs\.cpp'
require "OOM curses stubs keep terminal handoff inactive" tools/lua_longjmp_oom_curses_stubs.cpp \
    'HandoffPrepareResult::not_active'
require "PTY child shell snippets use collision-safe Lua long brackets" tools/test_curses_pty.sh \
    '\[=\[printf .*CURSES_CHILD_PROMPT'
forbid "PTY child shell snippets avoid ambiguous triple-close long brackets" tools/test_curses_pty.sh \
    '\[\[printf .*\]\]\],'
require "generated curses Lua fixtures are syntax-checked before PTY execution" tools/test_curses_pty.sh \
    'local chunk, err = loadfile\(path\)'
require "PTY resize injection waits until keyboard-timeout validation completed" tools/test_curses_pty.sh \
    'if b"CURSES_TIMEOUT_OK" in out and not state\.get\("resize"\):'
require "PTY resize uses TIOCSWINSZ as the single SIGWINCH source" tools/test_curses_pty.sh \
    'set_size\(master, 31, 101\)'
if awk '/def basic_driver\(/,/^run_case\(/' tools/test_curses_pty.sh | grep -Eq 'os\.kill\(pid, signal\.SIGWINCH\)'; then
    ko "PTY resize does not double-send SIGWINCH after TIOCSWINSZ"
else
    ok "PTY resize does not double-send SIGWINCH after TIOCSWINSZ"
fi
require "PTY Ctrl-Z uses a shell-like same-session supervisor" tools/test_curses_pty.sh \
    'def exec_job_control_child\(argv, env\):'
require "PTY Ctrl-Z foregrounds a distinct Babet process group" tools/test_curses_pty.sh \
    'os\.tcsetpgrp\(0, child\)'
require "PTY Ctrl-Z stop observation comes from child WIFSTOPPED" tools/test_curses_pty.sh \
    '__BABET_JOB_STOPPED__'
require "PTY Ctrl-Z scenario enables real job-control topology" tools/test_curses_pty.sh \
    'require_stop=True, job_control=True'

printf 'ncurses runtime structural contracts: %d PASS / %d FAIL\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
