#!/bin/bash
# Régression : un enfant spawné avec les trois flux hérités doit pouvoir lire
# depuis le terminal après une première lecture du parent Lua. Le test contrôle
# aussi SIGINT, la récupération bornée après SIGTSTP, le rafraîchissement
# d'état après une sortie déjà survenue et la restitution du premier plan/termios.
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
    "stty -echo; printf 'STOP_PROMPT\\n'; exec sleep 30",
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

local stop_result, stop_wait_err = stop_process:wait(0.5)
if stop_result ~= nil or stop_wait_err ~= "timeout" then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("stopped child wait did not time out: "
        .. tostring(stop_wait_err) .. "\n")
    os.exit(24)
end

local status_path = "/proc/" .. tostring(stop_process:pid()) .. "/status"
local status_file, status_open_err = io.open(status_path, "rb")
if not status_file then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("cannot inspect stopped child: "
        .. tostring(status_open_err) .. "\n")
    os.exit(25)
end
local status_text = status_file:read("*a")
status_file:close()
if not status_text:match("State:%s+[Tt]") then
    stop_process:kill()
    stop_process:close()
    io.stderr:write("child was not stopped by terminal Ctrl+Z\n")
    os.exit(26)
end
print("STOPPED_STATE_OK")

local killed_result, killed_err = stop_process:kill()
if not killed_result then
    stop_process:close()
    io.stderr:write("cannot kill stopped child: "
        .. tostring(killed_err) .. "\n")
    os.exit(27)
end
stop_process:close()
if killed_result.code ~= 137
        or killed_result.signaled ~= true
        or killed_result.signal ~= 9 then
    io.stderr:write("unexpected stopped-child kill result: code="
        .. tostring(killed_result.code)
        .. ", signaled=" .. tostring(killed_result.signaled)
        .. ", signal=" .. tostring(killed_result.signal) .. "\n")
    os.exit(28)
end
print("STOP_RECOVERY_OK")

io.write("STOP_RESTORED_PROMPT\n")
io.flush()
local stop_restored = io.read("*l")
if stop_restored ~= "stop-restored" then
    io.stderr:write("terminal was not restored after stopped child: "
        .. tostring(stop_restored) .. "\n")
    os.exit(29)
end

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
pid, master = pty.fork()
if pid == 0:
    os.execve(binary, [binary, project], environment)

os.set_blocking(master, False)
deadline = time.monotonic() + 8.0
output = bytearray()
sent_parent = False
sent_child = False
sent_timeout_answer = False
sent_signal = False
sent_restored = False
sent_stop = False
sent_stop_restored = False
sent_status_restored = False
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
        if (sudo_enabled == "1" and not sent_sudo_child
                and b"SUDO_CHILD_PROMPT" in output):
            os.write(master, b"sudo-child\n")
            sent_sudo_child = True
        if (sent_stop_restored and not sent_status_restored
                and b"STATUS_RESTORED_PROMPT" in output):
            os.write(master, b"status-restored\n")
            sent_status_restored = True

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
    "STOP_RECOVERY_OK",
    "STOP_RESTORED_PROMPT",
    "stop-restored",
    "STATUS_CHILD_DONE",
    "STATUS_REFRESH_OK",
    "STATUS_RESTORED_PROMPT",
    "status-restored",
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
