#!/bin/bash
# Régression : un enfant spawné avec les trois flux hérités doit pouvoir lire
# depuis le terminal après une première lecture du parent Lua. Le test contrôle
# aussi SIGINT, la suspension/reprise après SIGTSTP, la restitution
# asynchrone après sortie, le rafraîchissement d'état et les attributs termios.
set -u

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /chemin/vers/babet" >&2
    exit 2
fi

BINARY="$1"
if [ ! -x "${BINARY}" ]; then
    echo "ÉCHEC : binaire Babet introuvable ou non exécutable (${BINARY})." >&2
    exit 1
fi
BINARY="$(cd "$(dirname "${BINARY}")" && pwd)/$(basename "${BINARY}")"
printf 'Binaire PTY : %s\n' "${BINARY}"
if command -v sha256sum >/dev/null 2>&1; then
    printf 'SHA-256     : %s\n' "$(sha256sum "${BINARY}" | awk '{print $1}')"
fi

SUDO_PTY_TEST=0
if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO_PTY_TEST=1
fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babet-spawn-pty.XXXXXX") || exit 1
trap 'rm -rf -- "${ROOT}"' EXIT

cat > "${ROOT}/main.lua" <<'LUA'
io.write("PARENT_PROMPT\n")
io.flush()

local first = io.read("*l")
if first ~= "parent" then
    io.stderr:write("unexpected parent answer: " .. tostring(first) .. "\n")
    os.exit(10)
end

local process, spawn_err = babet.spawn("sh", {
    "-c",
    "printf 'CHILD_PROMPT\\n'; "
        .. "IFS= read -r answer; "
        .. "if [ \"$answer\" = child ]; then "
        .. "printf 'CHILD_ACCEPTED\\n'; exit 0; "
        .. "else exit 11; fi",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})

if not process then
    io.stderr:write("spawn failed: " .. tostring(spawn_err) .. "\n")
    os.exit(12)
end

local result, wait_err = process:wait(2.0)
if not result then
    process:kill()
    process:close()
    io.stderr:write("interactive child did not finish: "
        .. tostring(wait_err) .. "\n")
    os.exit(13)
end

process:close()
if result.code ~= 0 then
    io.stderr:write("interactive child exit code: "
        .. tostring(result.code) .. "\n")
    os.exit(14)
end

local timeout_process, timeout_spawn_err = babet.spawn("sh", {
    "-c",
    "printf 'TIMEOUT_PROMPT\\n'; "
        .. "IFS= read -r answer; "
        .. "if [ \"$answer\" = after-timeout ]; then "
        .. "printf 'TIMEOUT_CHILD_ACCEPTED\\n'; exit 0; "
        .. "else exit 18; fi",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not timeout_process then
    io.stderr:write("timeout spawn failed: "
        .. tostring(timeout_spawn_err) .. "\n")
    os.exit(18)
end

local early_result, early_err = timeout_process:wait(0.05)
if early_result ~= nil or early_err ~= "timeout" then
    timeout_process:kill()
    timeout_process:close()
    io.stderr:write("interactive wait did not time out as expected: "
        .. tostring(early_err) .. "\n")
    os.exit(19)
end
print("WAIT_TIMEOUT_OK")

local timeout_result, timeout_wait_err = timeout_process:wait(2.0)
if not timeout_result then
    timeout_process:kill()
    timeout_process:close()
    io.stderr:write("child could not resume after wait timeout: "
        .. tostring(timeout_wait_err) .. "\n")
    os.exit(20)
end
timeout_process:close()
if timeout_result.code ~= 0 then
    io.stderr:write("post-timeout child exit code: "
        .. tostring(timeout_result.code) .. "\n")
    os.exit(21)
end

local signal_process, signal_spawn_err = babet.spawn("sh", {
    "-c",
    "stty -echo; printf 'SIGNAL_PROMPT\\n'; exec sleep 30",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not signal_process then
    io.stderr:write("signal spawn failed: "
        .. tostring(signal_spawn_err) .. "\n")
    os.exit(15)
end

local signal_result, signal_wait_err = signal_process:wait(2.0)
if not signal_result then
    signal_process:kill()
    signal_process:close()
    io.stderr:write("terminal SIGINT was not delivered: "
        .. tostring(signal_wait_err) .. "\n")
    os.exit(16)
end
signal_process:close()
if signal_result.code ~= 130
        or signal_result.signaled ~= true
        or signal_result.signal ~= 2 then
    io.stderr:write("unexpected SIGINT result: code="
        .. tostring(signal_result.code)
        .. ", signaled=" .. tostring(signal_result.signaled)
        .. ", signal=" .. tostring(signal_result.signal) .. "\n")
    os.exit(17)
end
print("SIGNAL_RESULT_OK")

io.write("RESTORED_PROMPT\n")
io.flush()
local restored = io.read("*l")
if restored ~= "restored" then
    io.stderr:write("terminal was not restored to parent: "
        .. tostring(restored) .. "\n")
    os.exit(22)
end

local stop_process, stop_spawn_err = babet.spawn("sh", {
    "-c",
    "stty -echo; printf 'STOP_PROMPT\\n'; "
        .. "IFS= read -r answer; "
        .. "if [ \"$answer\" = resumed-child ]; then "
        .. "printf 'RESUMED_CHILD_ACCEPTED\\n'; exit 0; "
        .. "else exit 37; fi",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not stop_process then
    io.stderr:write("stop spawn failed: "
        .. tostring(stop_spawn_err) .. "\n")
    os.exit(23)
end

local stop_result, stop_wait_err = stop_process:wait(2.0)
if stop_result ~= nil or stop_wait_err ~= "stopped" then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("stopped child was not reported immediately: "
        .. tostring(stop_wait_err) .. "\n")
    os.exit(24)
end

local stopped_state, state_err = stop_process:state()
if stopped_state ~= "stopped" then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("unexpected stopped state: "
        .. tostring(stopped_state) .. " / " .. tostring(state_err) .. "\n")
    os.exit(25)
end
local still_running, running_err = stop_process:is_running()
if still_running ~= true then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("stopped child is_running mismatch: "
        .. tostring(still_running) .. " / " .. tostring(running_err) .. "\n")
    os.exit(26)
end
print("STOPPED_STATE_OK")

io.write("STOP_RESTORED_PROMPT\n")
io.flush()
local stop_restored = io.read("*l")
if stop_restored ~= "stop-restored" then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("terminal was not restored after stopped child: "
        .. tostring(stop_restored) .. "\n")
    os.exit(27)
end

local resumed, resume_err = stop_process:resume()
if not resumed then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("cannot resume stopped child: "
        .. tostring(resume_err) .. "\n")
    os.exit(28)
end
print("RESUME_SENT")

local resumed_result, resumed_wait_err = stop_process:wait(2.0)
if not resumed_result then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("resumed child did not finish: "
        .. tostring(resumed_wait_err) .. "\n")
    os.exit(29)
end
stop_process:close()
if resumed_result.code ~= 0 then
    io.stderr:write("resumed child exit code: "
        .. tostring(resumed_result.code) .. "\n")
    os.exit(30)
end
print("STOP_RESUME_OK")

io.write("RESUME_RESTORED_PROMPT\n")
io.flush()
local resume_restored = io.read("*l")
if resume_restored ~= "resume-restored" then
    io.stderr:write("terminal was not restored after resumed child: "
        .. tostring(resume_restored) .. "\n")
    os.exit(31)
end

local async_process, async_spawn_err = babet.spawn("sh", {
    "-c",
    "printf 'ASYNC_CHILD_DONE\\n'; sleep 0.1; exit 0",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not async_process then
    io.stderr:write("async spawn failed: "
        .. tostring(async_spawn_err) .. "\n")
    os.exit(32)
end

-- Aucun wait(), is_running(), state() ni close() avant cette lecture : le
-- moniteur natif doit rendre le terminal dès la sortie de l'enfant.
assert(babet.sleep(300, "ms"))
io.write("ASYNC_RECLAIM_PROMPT\n")
io.flush()
local async_restored = io.read("*l")
if async_restored ~= "async-restored" then
    async_process:kill()
    async_process:close()
    io.stderr:write("terminal was not reclaimed asynchronously: "
        .. tostring(async_restored) .. "\n")
    os.exit(33)
end
local async_result, async_wait_err = async_process:wait(2.0)
if not async_result or async_result.code ~= 0 then
    async_process:close()
    io.stderr:write("async child result mismatch: "
        .. tostring(async_wait_err) .. "\n")
    os.exit(34)
end
async_process:close()
print("ASYNC_RECLAIM_OK")

-- Élargit volontairement la fenêtre entre la sortie de l'enfant A et le
-- réveil de son moniteur. Le spawn B doit reconnaître le transfert devenu
-- obsolète, restaurer le parent puis recevoir le terminal sans appeler au
-- préalable wait(), state(), is_running() ou close() sur A.
assert(babet.setenv("BABET_TEST_TERMINAL_MONITOR_DELAY_MS", "1500"))
local race_a, race_a_err = babet.spawn("sh", {
    "-c", "printf 'RACE_A_DONE\\n'; exit 0",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not race_a then
    io.stderr:write("race A spawn failed: " .. tostring(race_a_err) .. "\n")
    os.exit(35)
end
assert(babet.setenv("BABET_TEST_TERMINAL_MONITOR_DELAY_MS", "0"))
assert(babet.sleep(500, "ms"))

local race_b, race_b_err = babet.spawn("sh", {
    "-c",
    "printf 'RACE_B_PROMPT\\n'; "
        .. "IFS= read -r answer; "
        .. "if [ \"$answer\" = race-child ]; then "
        .. "printf 'RACE_B_ACCEPTED\\n'; exit 0; "
        .. "else exit 38; fi",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not race_b then
    race_a:close()
    io.stderr:write("race B spawn failed: " .. tostring(race_b_err) .. "\n")
    os.exit(36)
end

local race_b_result, race_b_wait_err = race_b:wait(2.0)
if not race_b_result then
    race_b:kill()
    race_b:close()
    race_a:close()
    io.stderr:write("successive interactive spawn lost terminal: "
        .. tostring(race_b_wait_err) .. "\n")
    os.exit(37)
end
race_b:close()
if race_b_result.code ~= 0 then
    race_a:close()
    io.stderr:write("race B exit code: "
        .. tostring(race_b_result.code) .. "\n")
    os.exit(38)
end

local race_a_result, race_a_wait_err = race_a:wait(2.0)
if not race_a_result or race_a_result.code ~= 0 then
    race_a:close()
    io.stderr:write("race A result mismatch: "
        .. tostring(race_a_wait_err) .. "\n")
    os.exit(39)
end
race_a:close()
print("SUCCESSIVE_SPAWN_OK")

local status_process, status_spawn_err = babet.spawn("sh", {
    "-c",
    "printf 'STATUS_CHILD_DONE\\n'; exit 0",
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not status_process then
    io.stderr:write("status spawn failed: "
        .. tostring(status_spawn_err) .. "\n")
    os.exit(30)
end

local status_observed = false
for _ = 1, 200 do
    local running, running_err = status_process:is_running()
    if running == false then
        status_observed = true
        break
    end
    if running == nil then
        status_process:kill()
        status_process:close()
        io.stderr:write("status refresh failed: "
            .. tostring(running_err) .. "\n")
        os.exit(31)
    end
    assert(babet.sleep(10, "ms"))
end
if not status_observed then
    status_process:kill()
    status_process:close()
    io.stderr:write("finished child was not observed by is_running()\n")
    os.exit(32)
end
status_process:close()
print("STATUS_REFRESH_OK")

if os.getenv("BABET_TEST_SUDO_PTY") == "1" then
    local sudo_process, sudo_spawn_err = babet.spawn("sudo", {
        "-n", "sh", "-c",
        "printf 'SUDO_CHILD_PROMPT\\n'; "
            .. "IFS= read -r answer; "
            .. "if [ \"$answer\" = sudo-child ]; then "
            .. "printf 'SUDO_CHILD_ACCEPTED\\n'; exit 0; "
            .. "else exit 34; fi",
    }, {
        stdin = "inherit",
        stdout = "inherit",
        stderr = "inherit",
    })
    if not sudo_process then
        io.stderr:write("sudo PTY spawn failed: "
            .. tostring(sudo_spawn_err) .. "\n")
        os.exit(34)
    end
    local sudo_result, sudo_wait_err = sudo_process:wait(2.0)
    if not sudo_result then
        sudo_process:kill()
        sudo_process:close()
        io.stderr:write("sudo PTY child did not finish: "
            .. tostring(sudo_wait_err) .. "\n")
        os.exit(35)
    end
    sudo_process:close()
    if sudo_result.code ~= 0 then
        io.stderr:write("sudo PTY child exit code: "
            .. tostring(sudo_result.code) .. "\n")
        os.exit(36)
    end
    print("SUDO_PTY_OK")
end

io.write("STATUS_RESTORED_PROMPT\n")
io.flush()
local status_restored = io.read("*l")
if status_restored ~= "status-restored" then
    io.stderr:write("terminal was not restored after status refresh: "
        .. tostring(status_restored) .. "\n")
    os.exit(33)
end

-- Babet 2.17 : une réservation de terminal détenue par un autre thread ne
-- doit jamais bloquer indéfiniment ni laisser lancer un enfant sans terminal.
local busy_marker = os.getenv("BABET_TEST_TERMINAL_BUSY_MARKER")
local busy_parasite = os.getenv("BABET_TEST_TERMINAL_BUSY_PARASITE")
if not busy_marker or not busy_parasite then
    io.stderr:write("terminal busy fixture paths are missing\n")
    os.exit(40)
end
os.remove(busy_marker)
os.remove(busy_parasite)
assert(babet.setenv("BABET_TEST_TERMINAL_RESERVATION_MARKER", busy_marker))
assert(babet.setenv("BABET_TEST_TERMINAL_RESERVATION_DELAY_MS", "800"))

local busy_worker, busy_worker_err = babet.workers.spawn([[
    local process, spawn_err = babet.spawn("sh", {
        "-c", "stty -echo; sleep 0.2; exit 0",
    }, {
        stdin = "inherit",
        stdout = "inherit",
        stderr = "inherit",
    })
    if not process then
        return { spawned = false, error = spawn_err }
    end
    local result, wait_err = process:wait(3.0)
    process:close()
    return {
        spawned = true,
        code = result and result.code or nil,
        wait_error = wait_err,
    }
]])
if not busy_worker then
    io.stderr:write("terminal busy worker failed: "
        .. tostring(busy_worker_err) .. "\n")
    os.exit(41)
end

local reservation_observed = false
for _ = 1, 200 do
    local exists, exists_err = babet.fileExists(busy_marker)
    if exists == true then
        reservation_observed = true
        break
    end
    if exists == nil then
        io.stderr:write("terminal busy marker check failed: "
            .. tostring(exists_err) .. "\n")
        os.exit(42)
    end
    assert(babet.sleep(5, "ms"))
end
if not reservation_observed then
    io.stderr:write("terminal reservation was not observed\n")
    os.exit(43)
end

local busy_started = babet.monotonic()
local blocked_process, blocked_err = babet.spawn("sh", {
    "-c", [[printf launched > "$BABET_TEST_TERMINAL_BUSY_PARASITE"]],
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
    launch_timeout = 0.15,
})
local busy_elapsed = babet.monotonic() - busy_started
if blocked_process then
    blocked_process:kill()
    blocked_process:close()
    io.stderr:write("busy terminal unexpectedly launched a child\n")
    os.exit(44)
end
if type(blocked_err) ~= "string"
        or blocked_err:find("terminal handoff is busy", 1, true) == nil
        or busy_elapsed > 1.0 then
    io.stderr:write("unexpected terminal busy result: "
        .. tostring(blocked_err) .. " dt=" .. tostring(busy_elapsed) .. "\n")
    os.exit(45)
end
print("TERMINAL_BUSY_TIMEOUT_OK")

local parasite_exists, parasite_err = babet.fileExists(busy_parasite)
if parasite_exists ~= false then
    io.stderr:write("terminal busy launch left a child: "
        .. tostring(parasite_err) .. "\n")
    os.exit(46)
end
print("TERMINAL_BUSY_NO_CHILD_OK")

local joined, worker_result = busy_worker:join(4.0)
if joined ~= true or type(worker_result) ~= "table"
        or worker_result.spawned ~= true or worker_result.code ~= 0
        or worker_result.wait_error ~= nil then
    io.stderr:write("terminal busy worker result mismatch: "
        .. tostring(joined) .. " / " .. tostring(worker_result) .. "\n")
    os.exit(47)
end
print("TERMINAL_BUSY_WORKER_OK")

local recovery_process, recovery_err = babet.spawn("sh", {
    "-c", [[printf 'BUSY_RECOVERY_PROMPT\n'; IFS= read -r answer; if [ "$answer" = busy-recovered ]; then printf 'BUSY_RECOVERY_ACCEPTED\n'; exit 0; else exit 48; fi]],
}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
})
if not recovery_process then
    io.stderr:write("terminal busy recovery spawn failed: "
        .. tostring(recovery_err) .. "\n")
    os.exit(48)
end
local recovery_result, recovery_wait_err = recovery_process:wait(2.0)
if not recovery_result then
    recovery_process:kill()
    recovery_process:close()
    io.stderr:write("terminal busy recovery did not finish: "
        .. tostring(recovery_wait_err) .. "\n")
    os.exit(49)
end
recovery_process:close()
if recovery_result.code ~= 0 then
    io.stderr:write("terminal busy recovery exit code: "
        .. tostring(recovery_result.code) .. "\n")
    os.exit(50)
end
print("TERMINAL_BUSY_RECOVERY_OK")

print("PTY_SPAWN_OK")
LUA

python3 - "${BINARY}" "${ROOT}" "${SUDO_PTY_TEST}" <<'PY'
import errno
import os
import pty
import select
import signal
import sys
import time

binary, project, sudo_enabled = sys.argv[1:4]
environment = os.environ.copy()
environment["BABET_TEST_SUDO_PTY"] = sudo_enabled
environment["BABET_TEST_TERMINAL_BUSY_MARKER"] = os.path.join(
    project, "terminal-busy-reserved.marker")
environment["BABET_TEST_TERMINAL_BUSY_PARASITE"] = os.path.join(
    project, "terminal-busy-parasite.marker")
pid, master = pty.fork()
if pid == 0:
    os.execve(binary, [binary, project], environment)

os.set_blocking(master, False)
deadline = time.monotonic() + 24.0
output = bytearray()
sent_parent = False
sent_child = False
sent_timeout_answer = False
sent_signal = False
sent_restored = False
sent_stop = False
sent_stop_restored = False
sent_resumed_child = False
sent_resume_restored = False
sent_async_restored = False
sent_race_child = False
sent_status_restored = False
sent_busy_recovery = False
sent_sudo_child = False
status = None

try:
    while time.monotonic() < deadline:
        readable, _, _ = select.select([master], [], [], 0.05)
        if readable:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    chunk = b""
                else:
                    raise
            if chunk:
                output.extend(chunk)

        if not sent_parent and b"PARENT_PROMPT" in output:
            os.write(master, b"parent\n")
            sent_parent = True
        if sent_parent and not sent_child and b"CHILD_PROMPT" in output:
            os.write(master, b"child\n")
            sent_child = True
        if (sent_child and not sent_timeout_answer
                and b"WAIT_TIMEOUT_OK" in output):
            os.write(master, b"after-timeout\n")
            sent_timeout_answer = True
        if (sent_timeout_answer and not sent_signal
                and b"SIGNAL_PROMPT" in output):
            os.write(master, b"\x03")
            sent_signal = True
        if sent_signal and not sent_restored and b"RESTORED_PROMPT" in output:
            os.write(master, b"restored\n")
            sent_restored = True
        if sent_restored and not sent_stop and b"STOP_PROMPT" in output:
            os.write(master, b"\x1a")
            sent_stop = True
        if (sent_stop and not sent_stop_restored
                and b"STOP_RESTORED_PROMPT" in output):
            os.write(master, b"stop-restored\n")
            sent_stop_restored = True
        if (sent_stop_restored and not sent_resumed_child
                and b"RESUME_SENT" in output):
            os.write(master, b"resumed-child\n")
            sent_resumed_child = True
        if (sent_resumed_child and not sent_resume_restored
                and b"RESUME_RESTORED_PROMPT" in output):
            os.write(master, b"resume-restored\n")
            sent_resume_restored = True
        if (sent_resume_restored and not sent_async_restored
                and b"ASYNC_RECLAIM_PROMPT" in output):
            os.write(master, b"async-restored\n")
            sent_async_restored = True
        if (sent_async_restored and not sent_race_child
                and b"RACE_B_PROMPT" in output):
            os.write(master, b"race-child\n")
            sent_race_child = True
        if (sudo_enabled == "1" and not sent_sudo_child
                and b"SUDO_CHILD_PROMPT" in output):
            os.write(master, b"sudo-child\n")
            sent_sudo_child = True
        if (sent_async_restored and not sent_status_restored
                and b"STATUS_RESTORED_PROMPT" in output):
            os.write(master, b"status-restored\n")
            sent_status_restored = True
        if (sent_status_restored and not sent_busy_recovery
                and b"BUSY_RECOVERY_PROMPT" in output):
            os.write(master, b"busy-recovered\n")
            sent_busy_recovery = True

        waited, current = os.waitpid(pid, os.WNOHANG)
        if waited == pid:
            status = current
            break

    if status is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _, status = os.waitpid(pid, 0)
        sys.stderr.write(output.decode("utf-8", "replace"))
        sys.stderr.write("PTY regression timed out\n")
        sys.exit(1)

    while True:
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EAGAIN):
                break
            raise
        if not chunk:
            break
        output.extend(chunk)
finally:
    os.close(master)

text = output.decode("utf-8", "replace")
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    sys.stderr.write(text)
    sys.stderr.write(f"Babet exited abnormally: status={status}\n")
    sys.exit(1)

required = (
    "PARENT_PROMPT",
    "CHILD_PROMPT",
    "CHILD_ACCEPTED",
    "TIMEOUT_PROMPT",
    "WAIT_TIMEOUT_OK",
    "TIMEOUT_CHILD_ACCEPTED",
    "SIGNAL_PROMPT",
    "SIGNAL_RESULT_OK",
    "RESTORED_PROMPT",
    "restored",
    "STOP_PROMPT",
    "STOPPED_STATE_OK",
    "STOP_RESTORED_PROMPT",
    "stop-restored",
    "RESUME_SENT",
    "RESUMED_CHILD_ACCEPTED",
    "STOP_RESUME_OK",
    "RESUME_RESTORED_PROMPT",
    "resume-restored",
    "ASYNC_CHILD_DONE",
    "ASYNC_RECLAIM_PROMPT",
    "async-restored",
    "ASYNC_RECLAIM_OK",
    "RACE_A_DONE",
    "RACE_B_PROMPT",
    "RACE_B_ACCEPTED",
    "SUCCESSIVE_SPAWN_OK",
    "STATUS_CHILD_DONE",
    "STATUS_REFRESH_OK",
    "STATUS_RESTORED_PROMPT",
    "status-restored",
    "TERMINAL_BUSY_TIMEOUT_OK",
    "TERMINAL_BUSY_NO_CHILD_OK",
    "TERMINAL_BUSY_WORKER_OK",
    "BUSY_RECOVERY_PROMPT",
    "busy-recovered",
    "BUSY_RECOVERY_ACCEPTED",
    "TERMINAL_BUSY_RECOVERY_OK",
    "PTY_SPAWN_OK",
)
if sudo_enabled == "1":
    required += ("SUDO_CHILD_PROMPT", "SUDO_CHILD_ACCEPTED", "SUDO_PTY_OK")

missing = [marker for marker in required if marker not in text]
if missing:
    sys.stderr.write(text)
    sys.stderr.write("Missing PTY markers: " + ", ".join(missing) + "\n")
    sys.exit(1)

if sudo_enabled == "1":
    print("spawn inherited-terminal PTY regression: 2 PASS / 0 FAIL")
else:
    print("spawn inherited-terminal PTY regression: 1 PASS / 0 FAIL / 1 SKIP (sudo -n unavailable)")
PY
