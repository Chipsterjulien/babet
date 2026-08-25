#!/bin/bash
# Régressions ncursesw sous vrai pseudo-terminal (Lot 5).
set -u

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /chemin/vers/babet" >&2
    exit 2
fi
BINARY="$1"
if [ ! -x "${BINARY}" ]; then
    echo "ÉCHEC : binaire Babet introuvable (${BINARY})." >&2
    exit 1
fi
BINARY="$(cd "$(dirname "${BINARY}")" && pwd)/$(basename "${BINARY}")"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babet-curses-pty.XXXXXX") || exit 1
trap 'rm -rf -- "${ROOT}"' EXIT

cat > "${ROOT}/basic.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
local rows, cols = babet.curses.size()
assert(rows > 0 and cols > 0)
assert(babet.curses.clear())
assert(babet.curses.move(1, 1))
assert(babet.curses.write("CURSES_UTF8_é_Ω\n"))
assert(babet.curses.write("CURSES_READY_KEY\n"))
assert(babet.curses.refresh())
local no_key, timeout_err = babet.curses.readKey(0.02)
assert(no_key == nil and timeout_err == "timeout")
assert(babet.curses.write("CURSES_TIMEOUT_OK\n"))
assert(babet.curses.refresh())
local key, key_err = babet.curses.readKey(3.0)
assert(key == "resize", tostring(key) .. "/" .. tostring(key_err))
assert(babet.curses.write("CURSES_RESIZE_OK\n"))
assert(babet.curses.refresh())
local letter, letter_err = babet.curses.readKey(3.0)
assert(letter == "x", tostring(letter) .. "/" .. tostring(letter_err))

local caught = pcall(function() error("caught on purpose") end)
assert(caught == false)
assert(babet.curses.write("CURSES_PCALL_OK\n"))
assert(babet.curses.refresh())

local worker = assert(babet.workers.spawn([[
    local start_ok, start_err = pcall(function()
        return babet.curses.start()
    end)
    if start_ok then
        return { ok = false, why = "worker started curses" }
    end

    local interactive, interactive_err = babet.spawn("sh", {"-c", "exit 0"}, {
        stdin = "inherit", stdout = "inherit", stderr = "inherit",
    })
    if interactive then
        interactive:kill()
        interactive:close()
        return { ok = false, why = "worker got interactive terminal" }
    end

    local plain, plain_err = babet.spawn("sh", {"-c", "exit 0"}, {
        stdin = "pipe", stdout = "pipe", stderr = "pipe",
    })
    if not plain then
        return { ok = false, why = "noninteractive spawn failed: " .. tostring(plain_err) }
    end
    local result, wait_err = plain:wait(2.0)
    plain:close()
    return {
        ok = result ~= nil and result.code == 0,
        start_err = tostring(start_err),
        interactive_err = tostring(interactive_err),
        wait_err = wait_err,
    }
]]))
local joined, wr = worker:join(4.0)
assert(joined == true and type(wr) == "table" and wr.ok == true,
       "worker regression: " .. tostring(wr and wr.why))
assert(wr.start_err:find("main thread", 1, true))
assert(wr.interactive_err:find("worker while curses", 1, true))
assert(babet.curses.write("CURSES_WORKERS_OK\n"))
assert(babet.curses.refresh())

local child, spawn_err = babet.spawn("sh", {
    "-c", [=[printf 'CURSES_CHILD_PROMPT\n'; IFS= read -r a; [ "$a" = child ]]=],
}, { stdin = "inherit", stdout = "inherit", stderr = "inherit" })
assert(child, spawn_err)
local child_result, child_wait_err = child:wait(3.0)
assert(child_result and child_result.code == 0, child_wait_err)
child:close()
assert(babet.curses.write("CURSES_CHILD_RESTORED\n"))
assert(babet.curses.refresh())

local stopped, stopped_err = babet.spawn("sh", {
    "-c", [=[printf 'CURSES_STOP_CHILD\n'; kill -TSTP $$; printf 'CURSES_RESUME_PROMPT\n'; IFS= read -r a; [ "$a" = resumed-child ]]=],
}, { stdin = "inherit", stdout = "inherit", stderr = "inherit" })
assert(stopped, stopped_err)
local stopped_result, stopped_wait_err = stopped:wait(3.0)
assert(stopped_result == nil and stopped_wait_err == "stopped", stopped_wait_err)
assert(babet.curses.write("CURSES_STOP_RECLAIMED\n"))
assert(babet.curses.refresh())
assert(stopped:resume(true))
local resumed_result, resumed_wait_err = stopped:wait(3.0)
assert(resumed_result and resumed_result.code == 0, resumed_wait_err)
stopped:close()
assert(babet.curses.write("CURSES_RESUME_RESTORED\n"))
assert(babet.curses.refresh())

assert(babet.curses.stop())
-- A complete second session catches stale SCREEN/signal/locale state.
assert(babet.curses.start())
assert(babet.curses.write("CURSES_RESTART_OK\n"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
print("CURSES_BASIC_OK")
LUA

cat > "${ROOT}/stop_during_child.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
local child, err = babet.spawn("sh", {
    "-c", [=[printf 'CURSES_STOP_CANCEL_CHILD\n'; IFS= read -r a; [ "$a" = continue-child ]]=],
}, { stdin = "inherit", stdout = "inherit", stderr = "inherit" })
assert(child, err)
-- Le TTY appartient ici à l'enfant. stop() doit annuler la reprise curses,
-- sans tcsetpgrp vers Babet et sans réactiver le mode programme.
assert(babet.curses.stop())
local result, wait_err = child:wait(3.0)
assert(result and result.code == 0, wait_err)
child:close()
print("CURSES_STOP_DURING_CHILD_OK")
LUA

cat > "${ROOT}/start_error.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
local ok, err = pcall(babet.curses.start)
assert(ok == false)
print("CURSES_START_ERROR=" .. tostring(err))
LUA

cat > "${ROOT}/fallback.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_FALLBACK_ACTIVE\n"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
print("CURSES_FALLBACK_OK")
LUA

cat > "${ROOT}/uncaught.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_UNCAUGHT_READY\n"))
assert(babet.curses.refresh())
error("uncaught curses regression")
LUA

cat > "${ROOT}/terminate.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_TERM_READY\n"))
assert(babet.curses.refresh())
while true do babet.curses.readKey() end
LUA

cat > "${ROOT}/blocked_wait_signal.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_WAIT_SIGNAL_READY\n"))
assert(babet.curses.refresh())
local child = assert(babet.spawn("sh", {"-c", "sleep 2"}, {
    stdin = "pipe", stdout = "pipe", stderr = "pipe",
}))
child:wait()
error("blocked wait unexpectedly returned")
LUA

cat > "${ROOT}/handled_signal.lua" <<'LUA'
local handled = false
assert(babet.signal.handle("TERM", function() handled = true end))
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_HANDLER_READY\n"))
assert(babet.curses.refresh())
for _ = 1, 50 do
    babet.curses.readKey(0.1)
    if handled then break end
end
assert(handled)
assert(babet.curses.write("CURSES_HANDLER_OK\n"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
print("CURSES_HANDLER_EXIT_OK")
LUA

cat > "${ROOT}/suspend.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_TSTP_READY\n"))
assert(babet.curses.refresh())
babet.curses.readKey()
assert(babet.curses.write("CURSES_TSTP_RESUMED\n"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
print("CURSES_TSTP_OK")
LUA

# Projet packagé : le même runtime curses doit rester présent dans l'unique
# fichier généré, y compris avec les bases terminfo système masquées.
mkdir -p "${ROOT}/packaged-project"
cat > "${ROOT}/packaged-project/main.lua" <<'LUA'
print("PRE_CURSES_READY")
assert(io.read("*l") == "go")
assert(babet.curses.start())
assert(babet.curses.write("CURSES_PACKAGED_ACTIVE\n"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
print("CURSES_PACKAGED_OK")
LUA
cat > "${ROOT}/syntax_check.lua" <<'LUA'
local path = assert(arg[1], "missing path")
local chunk, err = loadfile(path)
if not chunk then
    io.stderr:write(err, "\n")
    os.exit(1)
end
LUA

syntax_fail=0
for lua_file in "${ROOT}"/*.lua "${ROOT}/packaged-project/main.lua"; do
    [ "${lua_file}" = "${ROOT}/syntax_check.lua" ] && continue
    if ! "${BINARY}" "${ROOT}/syntax_check.lua" "${lua_file}" >/dev/null 2>&1; then
        echo "[FAIL] generated curses Lua syntax: $(basename "${lua_file}")" >&2
        "${BINARY}" "${ROOT}/syntax_check.lua" "${lua_file}" >/dev/null
        syntax_fail=1
    fi
done
if [ "${syntax_fail}" -ne 0 ]; then
    exit 1
fi
echo "[PASS] generated curses Lua syntax"

PACKAGED="${ROOT}/packaged-curses"
if ! "${BINARY}" --create-exe "${ROOT}/packaged-project" "${PACKAGED}" >/dev/null; then
    echo "ÉCHEC : impossible de créer le fixture curses embarqué." >&2
    exit 1
fi
rm -rf "${ROOT}/packaged-project"

python3 - "${BINARY}" "${ROOT}" "${PACKAGED}" <<'PY'
import copy
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

binary, root, packaged = sys.argv[1:4]

def set_size(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def read_available(master, output):
    while True:
        ready, _, _ = select.select([master], [], [], 0)
        if not ready:
            return
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EAGAIN):
                return
            raise
        if not chunk:
            return
        output.extend(chunk)

def exec_job_control_child(argv, env):
    # pty.fork() makes this helper the session leader and controlling-terminal
    # owner. Keep it alive as a tiny shell-like parent so the Babet process
    # group is not orphaned: SIGTSTP then has real shell job-control semantics.
    shell_pgid = os.getpgrp()
    child = os.fork()
    if child == 0:
        os.setpgid(0, 0)
        os.execve(argv[0], argv, env)

    try:
        os.setpgid(child, child)
    except OSError:
        pass

    # A shell must be able to reclaim the controlling TTY while it is in the
    # background process group. Ignoring SIGTTOU is the normal job-control
    # technique for tcsetpgrp(). The launched Babet child did not inherit it.
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    os.tcsetpgrp(0, child)

    while True:
        waited, status = os.waitpid(child, os.WUNTRACED)
        if waited != child:
            continue
        if os.WIFSTOPPED(status):
            os.tcsetpgrp(0, shell_pgid)
            os.write(1, b"__BABET_JOB_STOPPED__\n")

            # Wait for the outer PTY driver to validate shell-mode termios
            # while Babet is genuinely stopped before foregrounding it again.
            line = bytearray()
            while b"\n" not in line:
                chunk = os.read(0, 1024)
                if not chunk:
                    os._exit(125)
                line.extend(chunk)

            os.tcsetpgrp(0, child)
            os.killpg(child, signal.SIGCONT)
            continue
        if os.WIFEXITED(status):
            try:
                os.tcsetpgrp(0, shell_pgid)
            except OSError:
                pass
            os._exit(os.WEXITSTATUS(status))
        if os.WIFSIGNALED(status):
            try:
                os.tcsetpgrp(0, shell_pgid)
            except OSError:
                pass
            os._exit(128 + os.WTERMSIG(status))

def run_case(name, argv, env, driver=None, expect_exit=0, expect_signal=None,
             required=(), timeout=12.0, require_stop=False, job_control=False):
    pid, master = pty.fork()
    if pid == 0:
        if job_control:
            exec_job_control_child(argv, env)
            os._exit(125)
        os.execve(argv[0], argv, env)

    os.set_blocking(master, False)
    set_size(master, 24, 80)
    output = bytearray()
    baseline = None
    final_status = None
    sent_go = False
    stopped_seen = False
    state = {}
    deadline = time.monotonic() + timeout

    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.03)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        chunk = b""
                    else:
                        raise
                if chunk:
                    output.extend(chunk)

            if not sent_go and b"PRE_CURSES_READY" in output:
                baseline = copy.deepcopy(termios.tcgetattr(master))
                os.write(master, b"go\n")
                sent_go = True

            if job_control and b"__BABET_JOB_STOPPED__" in output and not stopped_seen:
                stopped_seen = True
                state["stopped"] = True
                if baseline is not None:
                    stopped_attrs = termios.tcgetattr(master)
                    if stopped_attrs != baseline:
                        raise AssertionError(
                            f"{name}: terminal attributes not restored while stopped")

            if driver:
                driver(pid, master, output, state)

            while True:
                waited, status = os.waitpid(
                    pid, os.WNOHANG | os.WUNTRACED | os.WCONTINUED)
                if waited == 0:
                    break
                if os.WIFSTOPPED(status):
                    stopped_seen = True
                    state["stopped"] = True
                    if baseline is not None:
                        stopped_attrs = termios.tcgetattr(master)
                        if stopped_attrs != baseline:
                            raise AssertionError(
                                f"{name}: terminal attributes not restored while stopped")
                    if driver:
                        driver(pid, master, output, state)
                    break
                if os.WIFCONTINUED(status):
                    state["continued"] = True
                    break
                final_status = status
                break
            if final_status is not None:
                break

        if final_status is None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            _, final_status = os.waitpid(pid, 0)
            raise AssertionError(f"{name}: timeout\n" + output.decode("utf-8", "replace"))

        read_available(master, output)
        text = output.decode("utf-8", "replace")
        if expect_signal is not None:
            if not os.WIFSIGNALED(final_status) or os.WTERMSIG(final_status) != expect_signal:
                raise AssertionError(f"{name}: expected signal {expect_signal}, status={final_status}\n{text}")
        else:
            if not os.WIFEXITED(final_status) or os.WEXITSTATUS(final_status) != expect_exit:
                raise AssertionError(f"{name}: expected exit {expect_exit}, status={final_status}\n{text}")
        if require_stop and not stopped_seen:
            raise AssertionError(f"{name}: process was never observed stopped\n{text}")
        for marker in required:
            if marker not in text:
                raise AssertionError(f"{name}: missing marker {marker!r}\n{text}")
        if baseline is None:
            raise AssertionError(f"{name}: PRE_CURSES_READY was never observed\n{text}")
        after = termios.tcgetattr(master)
        if after != baseline:
            raise AssertionError(f"{name}: terminal attributes were not restored after exit\n{text}")
        print(f"[PASS] {name}")
    finally:
        try:
            os.close(master)
        except OSError:
            pass

base_env = os.environ.copy()
base_env["TERM"] = "xterm-256color"
base_env.setdefault("LC_ALL", "C.UTF-8")

def stop_during_child_driver(pid, master, out, state):
    if b"CURSES_STOP_CANCEL_CHILD" in out and not state.get("continue_child"):
        os.write(master, b"continue-child\n")
        state["continue_child"] = True

def basic_driver(pid, master, out, state):
    if b"CURSES_TIMEOUT_OK" in out and not state.get("resize"):
        # Linux TIOCSWINSZ sends SIGWINCH to the foreground process group.
        # Do not also os.kill(SIGWINCH): two standard signals can be observed
        # separately if the first one is consumed before the second is sent.
        set_size(master, 31, 101)
        state["resize"] = True
    if b"CURSES_RESIZE_OK" in out and not state.get("x"):
        os.write(master, b"x")
        state["x"] = True
    if b"CURSES_CHILD_PROMPT" in out and not state.get("child"):
        os.write(master, b"child\n")
        state["child"] = True
    if b"CURSES_RESUME_PROMPT" in out and not state.get("resumed_child"):
        os.write(master, b"resumed-child\n")
        state["resumed_child"] = True

run_case(
    "curses UTF-8/resize/workers/spawn/stop-resume",
    [binary, os.path.join(root, "basic.lua")], base_env.copy(),
    driver=basic_driver,
    required=("CURSES_UTF8_é_Ω", "CURSES_TIMEOUT_OK", "CURSES_RESIZE_OK",
              "CURSES_PCALL_OK", "CURSES_WORKERS_OK", "CURSES_CHILD_RESTORED",
              "CURSES_STOP_RECLAIMED", "CURSES_RESUME_RESTORED",
              "CURSES_RESTART_OK", "CURSES_BASIC_OK"), timeout=20.0)

run_case(
    "curses stop during child cancels restore without stealing TTY",
    [binary, os.path.join(root, "stop_during_child.lua")], base_env.copy(),
    driver=stop_during_child_driver,
    required=("CURSES_STOP_CANCEL_CHILD", "CURSES_STOP_DURING_CHILD_OK"),
    timeout=12.0)

missing_env = base_env.copy(); missing_env.pop("TERM", None)
run_case("missing TERM is a Lua error",
         [binary, os.path.join(root, "start_error.lua")], missing_env,
         required=("TERM is missing or empty",))

unknown_env = base_env.copy(); unknown_env["TERM"] = "babet-no-such-terminal-xyz"
run_case("unknown TERM is a Lua error",
         [binary, os.path.join(root, "start_error.lua")], unknown_env,
         required=("unknown or too generic",))

fallback_env = base_env.copy()
fallback_env["TERMINFO"] = os.path.join(root, "no-terminfo")
fallback_env["TERMINFO_DIRS"] = os.path.join(root, "no-terminfo-dirs")
fallback_env["HOME"] = os.path.join(root, "empty-home")
os.makedirs(fallback_env["HOME"], exist_ok=True)
run_case("compiled xterm-256color terminfo fallback",
         [binary, os.path.join(root, "fallback.lua")], fallback_env,
         required=("CURSES_FALLBACK_ACTIVE", "CURSES_FALLBACK_OK"))

run_case("uncaught Lua error restores terminal",
         [binary, os.path.join(root, "uncaught.lua")], base_env.copy(),
         expect_exit=1, required=("uncaught curses regression",))

def terminating_driver(sig):
    def driver(pid, master, out, state):
        if b"CURSES_TERM_READY" in out and not state.get("sent"):
            os.kill(pid, sig); state["sent"] = True
    return driver

for sig, label in ((signal.SIGINT, "SIGINT"),
                   (signal.SIGTERM, "SIGTERM"),
                   (signal.SIGHUP, "SIGHUP")):
    run_case(f"default {label} restores terminal then terminates",
             [binary, os.path.join(root, "terminate.lua")], base_env.copy(),
             driver=terminating_driver(sig), expect_signal=sig,
             required=("CURSES_TERM_READY",))

def wait_term_driver(pid, master, out, state):
    if b"CURSES_WAIT_SIGNAL_READY" in out and not state.get("sent"):
        os.kill(pid, signal.SIGTERM); state["sent"] = True
run_case("default SIGTERM interrupts process:wait and restores curses",
         [binary, os.path.join(root, "blocked_wait_signal.lua")], base_env.copy(),
         driver=wait_term_driver, expect_signal=signal.SIGTERM,
         required=("CURSES_WAIT_SIGNAL_READY",))

def handled_driver(pid, master, out, state):
    if b"CURSES_HANDLER_READY" in out and not state.get("term"):
        os.kill(pid, signal.SIGTERM); state["term"] = True
run_case("babet.signal handler remains authoritative during curses",
         [binary, os.path.join(root, "handled_signal.lua")], base_env.copy(),
         driver=handled_driver,
         required=("CURSES_HANDLER_OK", "CURSES_HANDLER_EXIT_OK"))

def suspend_driver(pid, master, out, state):
    if b"CURSES_TSTP_READY" in out and not state.get("ctrlz"):
        os.write(master, b"\x1a"); state["ctrlz"] = True
    if state.get("stopped") and not state.get("continued_sent"):
        # The shell-like supervisor is now foreground and waiting for this
        # acknowledgement after observing WIFSTOPPED on the Babet child.
        os.write(master, b"continue\n"); state["continued_sent"] = True
run_case("Ctrl-Z/CONT restores and re-enters curses",
         [binary, os.path.join(root, "suspend.lua")], base_env.copy(),
         driver=suspend_driver, require_stop=True, job_control=True,
         required=("CURSES_TSTP_RESUMED", "CURSES_TSTP_OK"), timeout=15.0)

run_case("generated executable retains autonomous curses runtime",
         [packaged], fallback_env.copy(),
         required=("CURSES_PACKAGED_ACTIVE", "CURSES_PACKAGED_OK"))
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    exit "$rc"
fi

# Le runtime ncurses doit être incorporé statiquement au binaire Babet.
if ldd "${BINARY}" 2>/dev/null | grep -Eq 'lib(ncurses|tinfo)'; then
    echo "[FAIL] ncurses/tinfo appears as a dynamic runtime dependency" >&2
    exit 1
fi
echo "[PASS] ncursesw/terminfo add no dynamic runtime dependency"

# Mesure informative du coût sur le binaire courant. Le baseline officiel est
# celui de BINARY_SIZE.md ; les lots 0-3 ont aussi ajouté quelques octets, donc
# ce delta est volontairement un indicateur de dérive et non un budget exact.
if command -v strip >/dev/null 2>&1; then
    STRIPPED="${ROOT}/babet-stripped"
    cp "${BINARY}" "${STRIPPED}"
    if strip --strip-all "${STRIPPED}" 2>/dev/null; then
        current_size=$(stat -c '%s' "${STRIPPED}")
        baseline=14997128
        delta=$((current_size - baseline))
        echo "[INFO] stripped current Babet: ${current_size} bytes (delta vs v2.22.2 official baseline: ${delta} bytes)"
    fi
fi

echo "curses PTY/runtime regression: PASS"
