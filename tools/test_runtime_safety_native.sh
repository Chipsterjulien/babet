#!/bin/bash
set -eu
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LUA_VERSION="$(awk -F'"' '/^LUA_VERSION="/ { print $2; exit }' "${ROOT_DIR}/build_local.sh")"
LUA_ROOT="${ROOT_DIR}/build/lua_build/lua-${LUA_VERSION}/src"
NCURSES_ROOT="${ROOT_DIR}/build/ncurses/build"
if [ ! -f "${LUA_ROOT}/liblua.a" ] || [ ! -f "${NCURSES_ROOT}/lib/libncursesw.a" ]; then
    echo "[FAIL] Runtime safety tests require the project's built Lua and ncurses." >&2
    exit 1
fi
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-runtime-safety.XXXXXX")"
trap 'rm -rf -- "${TMP_ROOT}"' EXIT
FLAGS=(-std=c++23 -Wall -Wextra -Wpedantic -Werror -pthread -ffunction-sections -fdata-sections -Wl,--gc-sections)
case "${1:-}" in
    --sanitizers) FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer) ;;
    --ubsan) FLAGS+=(-fsanitize=undefined -fno-omit-frame-pointer) ;;
    "") ;;
    *) echo "Usage: $0 [--sanitizers|--ubsan]" >&2; exit 1 ;;
esac
SYSTEM_LIBS=(-ldl -lm -pthread)
if [ "$(getconf LONG_BIT 2>/dev/null || printf '64')" = "32" ]; then SYSTEM_LIBS+=(-latomic); fi
"${CXX:-c++}" "${FLAGS[@]}" -I"${ROOT_DIR}/src" \
    "${ROOT_DIR}/tools/secure_source_selftest.cpp" \
    "${ROOT_DIR}/src/lua_bindings/secure_destination.cpp" \
    -Wl,--wrap=open -Wl,--wrap=renameat "${SYSTEM_LIBS[@]}" -o "${TMP_ROOT}/source"
"${TMP_ROOT}/source"
"${CXX:-c++}" "${FLAGS[@]}" -I"${ROOT_DIR}/src" -I"${LUA_ROOT}" -I"${NCURSES_ROOT}/include" \
    "${ROOT_DIR}/tools/curses_stop_selftest.cpp" \
    "${ROOT_DIR}/src/lua_bindings/curses.cpp" \
    "${ROOT_DIR}/src/lua_bindings/signal.cpp" \
    "${ROOT_DIR}/src/lua_bindings/main_thread.cpp" \
    "${ROOT_DIR}/src/lua_bindings/process_terminal_internal.cpp" \
    "${LUA_ROOT}/liblua.a" "${NCURSES_ROOT}/lib/libncursesw.a" \
    -Wl,--wrap=_Z26signal_any_handled_pendingv -Wl,--wrap=wget_wch \
    "${SYSTEM_LIBS[@]}" -o "${TMP_ROOT}/curses-stop"
python3 - "${TMP_ROOT}" <<'PY'
import errno, os, pty, select, signal, sys, time
from pathlib import Path
root = Path(sys.argv[1])


def run_pty(command, timeout=15):
    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.environ['TERM'] = 'xterm'
            os.execv(str(command[0]), [str(arg) for arg in command])
        except BaseException:
            os._exit(127)
    output = bytearray()
    status = None
    eof = False
    try:
        deadline = time.monotonic() + timeout
        # Closing the last slave FD and becoming waitable are distinct events.
        # EIO/EOF ends PTY reading, not the bounded wait for the child's status.
        # Conversely, drain the PTY even if waitpid sees the exit first.
        while status is None or not eof:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f'PTY timeout after {timeout:g}s: {command!r}\n'
                                   + output.decode(errors='replace'))
            readable, _, _ = select.select([] if eof else [fd], [], [],
                                           min(0.05, remaining))
            if readable:
                try:
                    block = os.read(fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    block = b''
                if block:
                    output.extend(block)
                else:
                    eof = True
            if status is None:
                got, code = os.waitpid(pid, os.WNOHANG)
                if got:
                    status = code
        return os.waitstatus_to_exitcode(status), bytes(output)
    finally:
        if status is None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(fd)


# Reproduce the EOF-before-exit ordering independently of ASan/host scheduling.
# Success, failure and a genuinely stuck child must remain distinguishable.
for expected in (0, 37, None):
    fixture = ('import os, time; os.write(1, b"PTY_CLOSED_BEFORE_EXIT\\n"); '
               'os.close(0); os.close(1); os.close(2); '
               + f'time.sleep({30 if expected is None else 0.2}); '
               + f'os._exit({expected or 0})')
    command = [sys.executable, '-c', fixture]
    if expected is None:
        try:
            run_pty(command, timeout=2)
        except TimeoutError as error:
            assert '\nPTY_CLOSED_BEFORE_EXIT' in str(error)
        else:
            raise AssertionError('PTY watchdog accepted a stuck child')
    else:
        status, output = run_pty(command)
        assert status == expected, (status, output)
        assert b'PTY_CLOSED_BEFORE_EXIT' in output, output
    print(f'[PASS] PTY closure before exit: {expected if expected is not None else "timeout"}',
          flush=True)
print('PTY exit supervision: 3 PASS / 0 FAIL', flush=True)

scenarios = [(1, '', False, False), (2, '', False, False),
             (2, '0', False, False), (2, '0.5', True, False), (1, '', False, True)]
for index, (injection, timeout, key, callback_error) in enumerate(scenarios):
    script = root / f'case-{index}.lua'
    script.write_text('assert(debug.gethook()==nil); assert(babet.curses.start()); '
        'assert(debug.gethook()~=nil); local hits=0; '
        'assert(babet.signal.handle("USR1",function() hits=hits+1; assert(babet.curses.stop()); '
        + ('error("expected callback error"); ' if callback_error else '') + 'end)); '
        + ('queue_key(); ' if key else '') + f'arm_race({injection}); '
        + f'local key,err=babet.curses.readKey({timeout}); '
        + 'assert(key==nil and err=="interrupted",tostring(key).."/"..tostring(err)); '
        + 'assert(hits==1); assert(debug.gethook()~=nil)\n')
    status, output = run_pty([root/'curses-stop', script])
    if status or b'CURSES_STOP_RACE_OK' not in output:
        raise AssertionError(f'curses stop race case {index}, exit {status}:\n'
                             + output.decode(errors='replace'))
    print(f'[PASS] curses callback stop: dispatch={injection} timeout={timeout or "none"} key={key} error={callback_error}', flush=True)
print('curses stop race: 5 PASS / 0 FAIL')
PY
