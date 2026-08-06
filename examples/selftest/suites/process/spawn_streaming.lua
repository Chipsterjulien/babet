return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== process streaming ===")

do
    local function read_both(process, timeout)
        local stdout_chunks, stderr_chunks = {}, {}
        local stdout_closed, stderr_closed = false, false
        local deadline = babet.monotonic() + (timeout or 5)

        while not stdout_closed or not stderr_closed do
            if not stdout_closed then
                local data, err = process:read_stdout(65536, 0.05)
                if data then
                    stdout_chunks[#stdout_chunks + 1] = data
                elseif err == "closed" then
                    stdout_closed = true
                elseif err ~= "timeout" then
                    return nil, nil, err
                end
            end

            if not stderr_closed then
                local data, err = process:read_stderr(65536, 0.05)
                if data then
                    stderr_chunks[#stderr_chunks + 1] = data
                elseif err == "closed" then
                    stderr_closed = true
                elseif err ~= "timeout" then
                    return nil, nil, err
                end
            end

            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        return table.concat(stdout_chunks), table.concat(stderr_chunks), nil
    end

    local function write_all(process, data)
        local offset = 1
        while offset <= #data do
            local written, err = process:write(data:sub(offset), 1)
            if not written then
                return nil, err
            end
            if written == 0 then
                return nil, "zero-byte write"
            end
            offset = offset + written
        end
        return true
    end

    local function read_stdout_all(process, timeout)
        local chunks = {}
        local deadline = babet.monotonic() + (timeout or 5)
        while true do
            local data, err = process:read_stdout(65536, 0.05)
            if data then
                chunks[#chunks + 1] = data
            elseif err == "closed" then
                return table.concat(chunks), nil
            elseif err ~= "timeout" then
                return nil, err
            end
            if babet.monotonic() >= deadline then
                return nil, "test timeout"
            end
        end
    end


    local function read_test_file(path)
        local file, err = io.open(path, "rb")
        if not file then return nil, err end
        local data = file:read("a")
        local closed, close_err = file:close()
        if not closed then return nil, close_err end
        return data
    end

    ok("babet.spawn is a function", type(babet.spawn) == "function")
    ok("spawn() without command raises",
        pcall(function() babet.spawn() end) == false)
    ok("spawn command is a strict string",
        pcall(function() babet.spawn(42) end) == false)

    local p, e = babet.spawn("echo", "bad")
    ok_fail("spawn args must be a table", p, e)
    p, e = babet.spawn("echo", { [2] = "bad" })
    ok_fail("spawn args must be a dense array", p, e)
    p, e = babet.spawn("echo", { true })
    ok_fail("spawn args contain strings only", p, e)
    p, e = babet.spawn("echo", {}, "bad")
    ok_fail("spawn opts must be a table", p, e)
    p, e = babet.spawn("echo", {}, { unknown = true })
    ok_fail("spawn rejects unknown options", p, e)
    p, e = babet.spawn("echo", {}, { launch_timeout = 0 })
    ok_fail("spawn launch_timeout must be > 0", p, e)
    p, e = babet.spawn("echo", {}, { launch_timeout = "1" })
    ok_fail("spawn launch_timeout is a strict number", p, e)
    p, e = babet.spawn("echo", {}, { stdin = "stdout" })
    ok_fail("spawn stdin rejects unsupported modes", p, e)
    p, e = babet.spawn("echo", {}, { stdin = {} })
    ok_fail("spawn stdin rejects file tables", p, e)
    p, e = babet.spawn("echo", {}, { stdout = "stdout" })
    ok_fail("spawn stdout rejects stderr-only merge mode", p, e)
    p, e = babet.spawn("echo", {}, { stdout = 42 })
    ok_fail("spawn stdout mode is strict", p, e)
    p, e = babet.spawn("echo", {}, { stdout = {} })
    ok_fail("spawn file redirection requires file", p, e)
    p, e = babet.spawn("echo", {}, {
        stdout = { file = true },
    })
    ok_fail("spawn redirection file is a strict string", p, e)
    p, e = babet.spawn("echo", {}, {
        stdout = { file = sb("spawn.log"), append = "yes" },
    })
    ok_fail("spawn redirection append is a strict boolean", p, e)
    p, e = babet.spawn("echo", {}, {
        stdout = { file = sb("spawn.log"), permissions = 512.5 },
    })
    ok_fail("spawn redirection permissions are a strict integer", p, e)
    p, e = babet.spawn("echo", {}, {
        stdout = { file = sb("spawn.log"), permissions = 1024 },
    })
    ok_fail("spawn redirection permissions stay within 0777", p, e)
    p, e = babet.spawn("echo", {}, {
        stderr = { file = sb("spawn.log"), unknown = true },
    })
    ok_fail("spawn file redirection rejects unknown options", p, e)
    p, e = babet.spawn("echo", {}, {
        stdout = { file = sb("bad\0path") },
    })
    ok_fail("spawn redirection rejects NUL paths", p, e)
    p, e = babet.spawn("__babet_missing_command__")
    ok_fail("spawn missing command -> (nil, err)", p, e)

    local spawn_path_dir = sb("spawn_path")
    assert(babet.mkdir(spawn_path_dir))
    local spawn_path_tool = spawn_path_dir .. "/private-spawn-tool"
    assert(write_test_file(spawn_path_tool, "#!/bin/sh\nprintf spawn-path"))
    assert(babet.setMode(spawn_path_tool, "755"))
    p, e = babet.spawn("private-spawn-tool", {}, {
        env = { PATH = spawn_path_dir },
    })
    ok("spawn lookup uses opts.env.PATH", p ~= nil and e == nil, tostring(e))
    if p then
        local spawn_path_output, spawn_path_read_err = read_stdout_all(p, 3)
        local spawn_path_result, spawn_path_wait_err = p:wait(2)
        ok("spawn PATH command executes successfully",
            spawn_path_output == "spawn-path"
            and spawn_path_read_err == nil
            and spawn_path_result and spawn_path_result.code == 0
            and spawn_path_wait_err == nil,
            tostring(spawn_path_read_err or spawn_path_wait_err))
        p:close()
    end

    -- Redirections de fichiers : troncature, ajout, permissions et fusion.
    local result, wait_err
    local stdout_file = sb("spawn stdout $; '*.log")
    assert(write_test_file(stdout_file, "OLD"))
    local existing_mode_before = babet.getMode(stdout_file)
    p, e = babet.spawn("sh", {
        "-c", "printf 'OUT'; printf 'ERR' >&2",
    }, {
        stdin = "null",
        stdout = {
            file = stdout_file,
            permissions = tonumber("640", 8),
        },
        stderr = "stdout",
    })
    ok("spawn accepts combined file redirection", p ~= nil and e == nil,
        tostring(e))
    local not_piped_data, not_piped_err = p:read_stdout(1, 0)
    ok("read_stdout reports not_piped for file redirection",
        not_piped_data == nil and not_piped_err == "not_piped")
    not_piped_data, not_piped_err = p:read_stderr(1, 0)
    ok("read_stderr reports not_piped when merged into stdout",
        not_piped_data == nil and not_piped_err == "not_piped")
    local not_piped_write, not_piped_write_err = p:write("x", 0)
    ok("write reports not_piped for null stdin",
        not_piped_write == nil and not_piped_write_err == "not_piped")
    local not_piped_close, not_piped_close_err = p:close_stdin()
    ok("close_stdin reports not_piped for null stdin",
        not_piped_close == nil and not_piped_close_err == "not_piped")
    result, wait_err = p:wait(2)
    local redirected_data, redirected_read_err = read_test_file(stdout_file)
    local existing_mode_after = babet.getMode(stdout_file)
    ok("spawn truncates and merges stdout/stderr into one file",
        result and result.code == 0 and redirected_data == "OUTERR",
        tostring(redirected_read_err))
    ok("spawn does not chmod an existing redirection file",
        existing_mode_before == existing_mode_after,
        "before=" .. tostring(existing_mode_before)
        .. " after=" .. tostring(existing_mode_after))
    p:close()

    p, e = babet.spawn("sh", { "-c", "printf '+APPEND'" }, {
        stdout = { file = stdout_file, append = true },
        stderr = "null",
    })
    ok("spawn accepts append file redirection", p ~= nil and e == nil,
        tostring(e))
    result, wait_err = p:wait(2)
    redirected_data, redirected_read_err = read_test_file(stdout_file)
    ok("spawn appends without truncating existing data",
        result and result.code == 0
        and redirected_data == "OUTERR+APPEND",
        tostring(redirected_read_err))
    p:close()

    local permissions_file = sb("spawn_permissions.log")
    p, e = babet.spawn("printf", { "permissions" }, {
        stdout = {
            file = permissions_file,
            permissions = tonumber("640", 8),
        },
        stderr = "null",
    })
    result, wait_err = p and p:wait(2)
    local permissions_mode = babet.getMode(permissions_file)
    ok("spawn applies permissions when creating a redirection file",
        p ~= nil and result and result.code == 0
        and (permissions_mode & tonumber("777", 8)) == tonumber("640", 8),
        "spawn=" .. tostring(e) .. " mode=" .. tostring(permissions_mode))
    if p then p:close() end

    local stderr_file = sb("spawn_stderr.log")
    p, e = babet.spawn("sh", {
        "-c", "printf 'PIPE'; printf 'FILEERR' >&2",
    }, {
        stdout = "pipe",
        stderr = { file = stderr_file },
    })
    ok("spawn redirects stderr independently", p ~= nil and e == nil,
        tostring(e))
    local stdout_only, stdout_only_err = read_stdout_all(p, 3)
    result, wait_err = p:wait(2)
    local stderr_data, stderr_read_err = read_test_file(stderr_file)
    ok("spawn keeps stdout pipe while stderr uses a file",
        stdout_only == "PIPE" and stdout_only_err == nil
        and result and result.code == 0 and stderr_data == "FILEERR",
        tostring(stderr_read_err))
    p:close()

    -- /dev/null fournit EOF sur stdin et supprime les sorties.
    p, e = babet.spawn("sh", {
        "-c", "if read value; then exit 9; else exit 0; fi",
    }, {
        stdin = "null",
        stdout = "null",
        stderr = "null",
    })
    ok("spawn supports null on all standard streams", p ~= nil and e == nil,
        tostring(e))
    result, wait_err = p:wait(2)
    ok("null stdin reaches immediate EOF",
        result and result.code == 0 and wait_err == nil)
    not_piped_data, not_piped_err = p:read_stdout(1, 0)
    ok("null stdout remains not_piped after process exit",
        not_piped_data == nil and not_piped_err == "not_piped")
    p:close()

    -- inherit ne crée aucun pipe parent. `true` évite de polluer le terminal.
    p, e = babet.spawn("true", {}, {
        stdin = "inherit",
        stdout = "inherit",
        stderr = "inherit",
    })
    ok("spawn supports inherited standard streams", p ~= nil and e == nil,
        tostring(e))
    result, wait_err = p:wait(2)
    not_piped_data, not_piped_err = p:read_stderr(1, 0)
    ok("inherit exposes no readable parent pipe",
        result and result.code == 0
        and not_piped_data == nil and not_piped_err == "not_piped")
    p:close()

    p, e = babet.spawn("sh", { "-c", "sleep 10" }, {
        stdin = "null",
        stdout = "null",
        stderr = "null",
    })
    ok("spawn terminate works without any parent pipe",
        p ~= nil and e == nil, tostring(e))
    result, wait_err = p:terminate(0.2)
    ok("redirected process terminate returns a signaled result",
        result and wait_err == nil and result.signaled == true
        and (result.code == 143 or result.code == 137),
        tostring(wait_err))
    p:close()

    -- Une erreur d'ouverture doit survenir avant fork/exec.
    local side_effect = sb("spawn_should_not_run")
    p, e = babet.spawn("sh", { "-c", "touch '" .. side_effect .. "'" }, {
        stdout = { file = sb("missing_parent/out.log") },
    })
    local side_effect_exists = babet.fileExists(side_effect)
    ok("spawn file-open failure prevents child launch",
        p == nil and type(e) == "string" and side_effect_exists == false,
        tostring(e))

    p, e = babet.spawn("true", {}, {
        stdout = { file = SB },
    })
    ok_fail("spawn refuses a directory as output destination", p, e)

    local fifo_path = sb("spawn_output.fifo")
    local fifo_result = babet.exec("mkfifo", { fifo_path })
    if fifo_result and fifo_result.code == 0 then
        local fifo_started = babet.monotonic()
        p, e = babet.spawn("true", {}, {
            stdout = { file = fifo_path },
        })
        local fifo_elapsed = babet.monotonic() - fifo_started
        ok("spawn refuses a FIFO without blocking during open",
            p == nil and type(e) == "string" and fifo_elapsed < 1,
            "err=" .. tostring(e) .. " elapsed=" .. tostring(fifo_elapsed))
        babet.remove(fifo_path)
    else
        ok("spawn FIFO fixture is available", false,
            fifo_result and fifo_result.stderr or "mkfifo failed")
    end

    -- La destination finale ne peut pas être un lien symbolique.
    local symlink_target = sb("spawn_symlink_target.log")
    local symlink_output = sb("spawn_symlink_output.log")
    assert(write_test_file(symlink_target, "TARGET"))
    assert(babet.link("spawn_symlink_target.log", symlink_output))
    p, e = babet.spawn("printf", { "ESCAPE" }, {
        stdout = { file = symlink_output },
    })
    local symlink_target_data = read_test_file(symlink_target)
    ok("spawn refuses a symlinked output destination",
        p == nil and type(e) == "string"
        and symlink_target_data == "TARGET", tostring(e))

    -- La fusion fonctionne aussi lorsque stdout reste un pipe parent.
    p, e = babet.spawn("sh", {
        "-c", "printf 'OUT'; printf 'ERR' >&2",
    }, {
        stderr = "stdout",
    })
    ok("spawn merges stderr into a piped stdout", p ~= nil and e == nil,
        tostring(e))
    local merged_pipe, merged_pipe_err = read_stdout_all(p, 3)
    local merged_stderr, merged_stderr_err = p:read_stderr(1, 0)
    result, wait_err = p:wait(2)
    ok("merged pipe preserves both sequential writes",
        merged_pipe == "OUTERR" and merged_pipe_err == nil
        and merged_stderr == nil and merged_stderr_err == "not_piped"
        and result and result.code == 0, tostring(wait_err))
    p:close()

    p, e = babet.spawn("sh", {
        "-c",
        "printf 'OUT'; printf 'ERR' >&2; sleep 0.2",
    })
    ok("spawn basic process returns userdata", p ~= nil and e == nil,
        tostring(e))
    ok("process tostring is informative",
        tostring(p):find("babet.process", 1, true) ~= nil)
    ok("process pid() returns an integer",
        math.type(p:pid()) == "integer" and p:pid() > 0)
    ok("process is_running() initially true", p:is_running() == true)
    ok("process state() initially running", p:state() == "running")

    local out, errout, stream_err = read_both(p, 3)
    ok("stream stdout is captured progressively",
        out == "OUT" and stream_err == nil, tostring(stream_err))
    ok("stream stderr is captured separately",
        errout == "ERR" and stream_err == nil, tostring(stream_err))

    result, wait_err = p:wait(2)
    ok("process wait returns a result table",
        type(result) == "table" and wait_err == nil)
    ok("process normal exit code == 0",
        result and result.code == 0 and result.exited == true
        and result.signaled == false)
    ok("process is_running() false after wait", p:is_running() == false)
    ok("process state() after wait is exited", p:state() == "exited")
    local result2, wait_err2 = p:wait(0)
    ok("process wait is idempotent",
        result2 and result2.code == 0 and wait_err2 == nil)
    ok_act("process close() succeeds", p:close())
    ok_act("process close() is idempotent", p:close())
    ok("process state() after close is closed", p:state() == "closed")
    local closed_data, closed_err = p:read_stdout(1, 0)
    ok("read_stdout after close -> closed",
        closed_data == nil and closed_err == "closed")

    -- cwd + env overlay.
    p, e = babet.spawn("sh", {
        "-c", "printf '%s|%s' \"$PWD\" \"$BABET_SPAWN_ENV\"",
    }, {
        cwd = "/tmp",
        env = { BABET_SPAWN_ENV = "ok" },
    })
    ok("spawn accepts cwd and env", p ~= nil and e == nil, tostring(e))
    out, errout, stream_err = read_both(p, 3)
    result = p:wait(2)
    ok("spawn cwd/env reach the child",
        out == "/tmp|ok" and errout == "" and result.code == 0,
        tostring(out))
    p:close()

    -- Les états intermédiaires sont explicites : wait() rend "stopped",
    -- is_running() reste vrai et resume(false) poursuit le groupe sans
    -- transfert de terminal pour ce processus raccordé à des pipes.
    p, e = babet.spawn("sh", {
        "-c", "kill -STOP $$; printf resumed",
    })
    ok("spawn stopped-state fixture", p ~= nil and e == nil, tostring(e))
    local stopped_result, stopped_err = p:wait(2)
    ok("process wait reports a stopped child",
        stopped_result == nil and stopped_err == "stopped",
        tostring(stopped_err))
    ok("process state() reports stopped", p:state() == "stopped")
    ok("process is_running() stays true while stopped",
        p:is_running() == true)
    local resumed, resume_err = p:resume(false)
    ok("process resume(false) continues a stopped child",
        resumed == true and resume_err == nil, tostring(resume_err))
    out, errout, stream_err = read_both(p, 3)
    result, wait_err = p:wait(2)
    ok("resumed process completes normally",
        out == "resumed" and errout == "" and stream_err == nil
        and result and result.code == 0 and wait_err == nil,
        tostring(stream_err or wait_err))
    p:close()

    -- Lecture non bloquante et wait borné ne tuent pas le processus.
    p, e = babet.spawn("sh", { "-c", "sleep 0.4; printf done" })
    ok("spawn delayed-output fixture", p ~= nil and e == nil, tostring(e))
    local t0 = babet.monotonic()
    local no_data, timeout_err = p:read_stdout(16, 0.05)
    local dt = babet.monotonic() - t0
    ok("read_stdout timeout is typed and bounded",
        no_data == nil and timeout_err == "timeout" and dt < 0.5,
        "err=" .. tostring(timeout_err) .. " dt=" .. tostring(dt))
    local no_wait, no_wait_err = p:wait(0)
    ok("wait(0) is non-blocking",
        no_wait == nil and no_wait_err == "timeout")
    ok("wait timeout does not terminate the process", p:is_running() == true)
    out, errout, stream_err = read_both(p, 3)
    result = p:wait(2)
    ok("process remains usable after timeouts",
        out == "done" and errout == "" and result.code == 0,
        tostring(stream_err))
    p:close()

    -- stdin binary-safe et écriture progressive.
    p, e = babet.spawn("cat")
    ok("spawn cat for streaming stdin", p ~= nil and e == nil, tostring(e))
    local binary = "alpha\0beta\n"
    local wrote, write_err = write_all(p, binary)
    ok("process write_all accepts binary data", wrote == true,
        tostring(write_err))
    local zero_written, zero_err = p:write("", 0)
    ok("process write empty string returns 0",
        zero_written == 0 and zero_err == nil)
    ok_act("process close_stdin succeeds", p:close_stdin())
    ok_act("process close_stdin is idempotent", p:close_stdin())
    out, errout, stream_err = read_both(p, 3)
    result = p:wait(2)
    ok("process stdin/stdout round-trip is binary-safe",
        out == binary and errout == "" and result.code == 0,
        tostring(stream_err))
    local write_closed, write_closed_err = p:write("x", 0)
    ok("write after close_stdin -> closed",
        write_closed == nil and write_closed_err == "closed")
    p:close()

    -- Gros flux sur stdout ET stderr : les deux doivent être drainés.
    p, e = babet.spawn("sh", {
        "-c",
        "head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2",
    })
    ok("spawn large dual-stream fixture", p ~= nil and e == nil, tostring(e))
    out, errout, stream_err = read_both(p, 5)
    result = p:wait(2)
    ok("large stdout streaming does not deadlock",
        out and #out == 262144 and result.code == 0,
        "size=" .. tostring(out and #out) .. " err=" .. tostring(stream_err))
    ok("large stderr streaming does not deadlock",
        errout and #errout == 262144,
        "size=" .. tostring(errout and #errout))
    p:close()

    -- terminate / kill ciblent le groupe et rendent un code 128+signal.
    p, e = babet.spawn("sh", { "-c", "sleep 10" })
    ok("spawn terminate fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:terminate(0.2)
    ok("process terminate returns a signaled result",
        result and wait_err == nil and result.signaled == true
        and (result.code == 143 or result.code == 137),
        tostring(wait_err))
    p:close()

    p, e = babet.spawn("sh", { "-c", "sleep 10" })
    ok("spawn kill fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:kill()
    ok("process kill returns code 137",
        result and wait_err == nil and result.code == 137
        and result.signal == 9)
    p:close()

    -- close() nettoie automatiquement un processus encore actif.
    p, e = babet.spawn("sh", { "-c", "sleep 10" })
    ok("spawn close cleanup fixture", p ~= nil and e == nil, tostring(e))
    local cleanup_pid = p:pid()
    ok_act("process close terminates an active child", p:close())
    ok("closed process reports not running", p:is_running() == false)
    local probe = babet.exec("sh", {
        "-c", "kill -0 " .. tostring(cleanup_pid) .. " 2>/dev/null",
    })
    ok("closed child is no longer alive",
        type(probe) == "table" and probe.code ~= 0)

    -- Arity / value guards on methods.
    p, e = babet.spawn("cat")
    ok("spawn validation-method fixture", p ~= nil and e == nil, tostring(e))
    ok("read_stdout rejects max_bytes <= 0",
        pcall(function() p:read_stdout(0) end) == false)
    ok("read_stdout rejects max_bytes > 16 MiB",
        pcall(function() p:read_stdout(16 * 1024 * 1024 + 1) end) == false)
    local bad_timeout, bad_timeout_err = p:read_stdout(1, -1)
    ok("read_stdout rejects negative timeout cleanly",
        bad_timeout == nil and type(bad_timeout_err) == "string")
    ok("write requires a string",
        pcall(function() p:write(42) end) == false)
    ok("pid rejects extra arguments",
        pcall(function() p:pid(true) end) == false)
    ok("state rejects extra arguments",
        pcall(function() p:state(true) end) == false)
    local resume_running, resume_running_err = p:resume(false)
    ok("resume rejects a process that is not stopped",
        resume_running == nil and resume_running_err == "not_stopped")
    ok("resume foreground must be a strict boolean",
        pcall(function() p:resume(1) end) == false)
    ok("resume rejects extra arguments",
        pcall(function() p:resume(false, true) end) == false)
    ok("wait rejects extra arguments",
        pcall(function() p:wait(0, 1) end) == false)
    p:close()
end

-- =====================================================================
end
