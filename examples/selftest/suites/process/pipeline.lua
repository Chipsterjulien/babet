return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== process pipelines ===")

local function pipeline_test_pid_is_running(pid)
    local probe = babet.exec("ps", { "-o", "stat=", "-p", tostring(pid) })
    if type(probe) ~= "table" or probe.code ~= 0 then
        return false
    end
    local state = probe.stdout:match("%S+")
    return state ~= nil and state:sub(1, 1) ~= "Z"
end

local function pipeline_test_read_pid(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local pid = tonumber(file:read("*l"))
    file:close()
    return pid
end

do
    ok("babet.pipeline is a function", type(babet.pipeline) == "function")
    ok("pipeline without commands raises",
        pcall(function() babet.pipeline() end) == false)
    ok("pipeline commands must be a table",
        pcall(function() babet.pipeline("bad") end) == false)
    ok_raises("pipeline rejects extra arguments",
        function() babet.pipeline({}, {}, true) end,
        "pipeline expects a commands table and optional opts")

    local max_stages = {}
    for i = 1, 32 do max_stages[i] = { "true" } end
    local r, e = babet.pipeline(max_stages)
    ok("pipeline accepts exactly 32 stages",
        type(r) == "table" and e == nil and #r.stages == 32)
    local too_many = {}
    for i = 1, 33 do too_many[i] = { "true" } end
    r, e = babet.pipeline(too_many)
    ok_fail("pipeline rejects more than 32 stages", r, e)
    r, e = babet.pipeline({ [1] = { "true" }, [3] = { "true" } })
    ok_fail("pipeline commands must be dense", r, e)
    r, e = babet.pipeline({ "true", { "cat" } })
    ok_fail("pipeline stage must be a table", r, e)
    r, e = babet.pipeline({ { "true", {}, {}, "extra" }, { "cat" } })
    ok_fail("pipeline stage rejects extra fields", r, e)
    r, e = babet.pipeline({ { 42 }, { "cat" } })
    ok_fail("pipeline command must be a string", r, e)
    r, e = babet.pipeline({ { "" }, { "cat" } })
    ok_fail("pipeline command must not be empty", r, e)
    r, e = babet.pipeline({ { "echo", "bad" }, { "cat" } })
    ok_fail("pipeline args must be a table", r, e)
    r, e = babet.pipeline({ { "echo", { true } }, { "cat" } })
    ok_fail("pipeline args contain strings only", r, e)
    r, e = babet.pipeline({ { "echo", { "x\0bad" } }, { "cat" } })
    ok_fail("pipeline argument rejects NUL", r, e)

    r, e = babet.pipeline({ { "echo" }, { "cat" } }, "bad")
    ok_fail("pipeline opts must be a table", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { cwd = 42 })
    ok_fail("pipeline cwd must be a string", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { cwd = "/tmp\0bad" })
    ok_fail("pipeline cwd rejects NUL", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = "bad" })
    ok_fail("pipeline env must be a table", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { [1] = "bad" } })
    ok_fail("pipeline env keys must be strings", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { BAD = true } })
    ok_fail("pipeline env values must be strings", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { [""] = "x" } })
    ok_fail("pipeline env key must not be empty", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { ["A=B"] = "x" } })
    ok_fail("pipeline env key rejects '='", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { ["A\0B"] = "x" } })
    ok_fail("pipeline env key rejects NUL", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { env = { A = "x\0y" } })
    ok_fail("pipeline env value rejects NUL", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { stdin = true })
    ok_fail("pipeline stdin must be a string", r, e)

    for _, invalid in ipairs({ 0, -1, math.huge, -math.huge }) do
        r, e = babet.pipeline({ { "echo" }, { "cat" } }, { timeout = invalid })
        ok_fail("pipeline rejects invalid timeout " .. tostring(invalid), r, e)
    end
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { timeout = 0 / 0 })
    ok_fail("pipeline rejects NaN timeout", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, {
        timeout = 1000000000001,
    })
    ok_fail("pipeline rejects timeout above 10^12 seconds", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { max_output = 1.5 })
    ok_fail("pipeline max_output must be an integer", r, e)
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { max_output = 0 })
    ok_fail("pipeline rejects max_output zero", r, e)
    r, e = babet.pipeline({ { "printf", { "x" } }, { "cat" } }, {
        max_output = 2147483648,
    })
    ok("pipeline accepts max_output at 2 GiB boundary",
        type(r) == "table" and e == nil and r.stdout == "x")
    r, e = babet.pipeline({ { "echo" }, { "cat" } }, { max_output = 2147483649 })
    ok_fail("pipeline rejects max_output above 2 GiB", r, e)
    r, e = babet.pipeline({ { "echo", {}, { cwd = 42 } }, { "cat" } })
    ok_fail("pipeline stage cwd must be a string", r, e)
    r, e = babet.pipeline({ { "echo", {}, { env = "bad" } }, { "cat" } })
    ok_fail("pipeline stage env must be a table", r, e)

    r, e = babet.pipeline({ { "cat" } })
    ok_fail("pipeline requires at least two stages", r, e)

    r, e = babet.pipeline({ { "printf", { "hello\nworld\n" } }, { "grep", { "world" } } })
    ok("pipeline basic stdout", type(r) == "table" and e == nil
        and r.stdout == "world\n" and r.code == 0
        and r.all_succeeded == true and r.failed_index == nil
        and #r.stages == 2 and #r.stderr == 2)

    r, e = babet.pipeline({ { "cat" }, { "tr", { "a-z", "A-Z" } } }, {
        stdin = "abc\0def\n",
    })
    ok("pipeline binary stdin/stdout", type(r) == "table" and e == nil
        and r.stdout == "ABC\0DEF\n")

    r, e = babet.pipeline({
        { "sh", { "-c", "printf first 1>&2; printf x" } },
        { "sh", { "-c", "cat; printf second 1>&2" } },
    })
    ok("pipeline separates stderr per stage", type(r) == "table" and e == nil
        and r.stdout == "x" and r.stderr[1] == "first"
        and r.stderr[2] == "second")

    r, e = babet.pipeline({
        { "sh", { "-c", "exit 7" } },
        { "cat" },
    })
    ok("pipeline exposes intermediate failure", type(r) == "table" and e == nil
        and r.code == 0 and r.all_succeeded == false
        and r.failed_index == 1 and r.stages[1].code == 7
        and r.stages[2].code == 0)

    r, e = babet.pipeline({
        { "printf", { "x\n" } },
        { "sh", { "-c", "cat >/dev/null; exit 5" } },
    })
    ok("pipeline global code is last stage code", type(r) == "table" and e == nil
        and r.code == 5 and r.failed_index == 2)

    r, e = babet.pipeline({
        { "pwd", {}, { cwd = "/tmp" } },
        { "cat" },
    })
    ok("pipeline per-stage cwd", type(r) == "table" and e == nil
        and r.stdout == "/tmp\n")

    r, e = babet.pipeline({
        { "sh", { "-c", "printf %s \"$BABET_PIPE_VAR\"" }, {
            env = { BABET_PIPE_VAR = "local" },
        } },
        { "cat" },
    }, { env = { BABET_PIPE_VAR = "global" } })
    ok("pipeline local env overrides global env", type(r) == "table" and e == nil
        and r.stdout == "local")

    local pipeline_path_dir = sb("pipeline_path")
    assert(babet.mkdir(pipeline_path_dir))
    local pipeline_path_tool = pipeline_path_dir .. "/private-tool"
    local pipeline_path_file = assert(io.open(pipeline_path_tool, "w"))
    pipeline_path_file:write("#!/bin/sh\nprintf pipeline-path")
    pipeline_path_file:close()
    assert(babet.setMode(pipeline_path_tool, "755"))
    r, e = babet.pipeline({ { "private-tool" }, { "cat" } }, {
        env = { PATH = pipeline_path_dir .. ":/usr/bin:/bin" },
    })
    ok("pipeline lookup uses opts.env.PATH",
        type(r) == "table" and e == nil and r.stdout == "pipeline-path")
    r, e = babet.pipeline({ { pipeline_path_tool }, { "cat" } }, {
        env = { PATH = pipeline_path_dir .. ":/usr/bin:/bin" },
    })
    ok("pipeline explicit command path uses overridden child environment",
        type(r) == "table" and e == nil and r.stdout == "pipeline-path")

    r, e = babet.pipeline({
        { "printf", { "abcdef" } },
        { "cat" },
    }, { max_output = 3 })
    ok("pipeline stdout truncation", type(r) == "table" and e == nil
        and r.stdout == "abc" and r.stdout_truncated == true)

    r, e = babet.pipeline({
        { "sh", { "-c", "printf abcdef 1>&2" } },
        { "cat" },
    }, { max_output = 3 })
    ok("pipeline stderr truncation", type(r) == "table" and e == nil
        and r.stderr[1] == "abc" and r.stderr_truncated[1] == true)

    local large = string.rep("pipeline-large-data\n", 20000)
    r, e = babet.pipeline({ { "cat" }, { "cat" }, { "cat" } }, {
        stdin = large,
        max_output = #large + 1,
        timeout = 10,
    })
    ok("pipeline large data has no deadlock", type(r) == "table" and e == nil
        and r.stdout == large and r.timed_out == false)

    r, e = babet.pipeline({
        { "sh", { "-c", "sleep 30 & wait" } },
        { "cat" },
    }, { timeout = 0.3 })
    ok("pipeline timeout kills all process groups", type(r) == "table" and e == nil
        and r.timed_out == true and r.all_succeeded == false)

    r, e = babet.pipeline({
        { "yes" },
        { "head", { "-n", "1" } },
    }, { timeout = 5, max_output = 1024 })
    ok("pipeline handles SIGPIPE from upstream", type(r) == "table" and e == nil
        and r.stdout == "y\n" and r.code == 0
        and r.stages[1].signaled == true)

    r, e = babet.pipeline({ { "printf", { "x" } }, { "__babet_missing_pipeline__" } })
    ok_fail("pipeline launch failure is returned", r, e)

    r, e = babet.pipeline({ { "pwd" }, { "cat" } }, { cwd = "/does/not/exist" })
    ok_fail("pipeline invalid global cwd is returned", r, e)

    r, e = babet.pipeline({ { "echo", { "x" } }, { "cat" } }, { unknown = true })
    ok_fail("pipeline rejects unknown global option", r, e)

    r, e = babet.pipeline({ { "echo", { "x" }, { unknown = true } }, { "cat" } })
    ok_fail("pipeline rejects unknown stage option", r, e)

    r, e = babet.pipeline({ { "echo", { [2] = "x" } }, { "cat" } })
    ok_fail("pipeline args must be dense", r, e)

    r, e = babet.pipeline({ { "echo\0bad" }, { "cat" } })
    ok_fail("pipeline command rejects NUL", r, e)

    r, e = babet.pipeline({ { "printf", { "ok" } }, { "cat" } })
    ok("pipeline default result exposes complete non-truncated shape",
        type(r) == "table" and e == nil and r.stdout == "ok"
        and r.timed_out == false and r.stdout_truncated == false
        and #r.stderr_truncated == 2
        and r.stderr_truncated[1] == false
        and r.stderr_truncated[2] == false
        and r.stages[1].launched == true
        and r.stages[1].exited == true
        and r.stages[1].signaled == false
        and r.stages[1].signal == nil)

    local sync_pid_path = sb("pipeline_sync_descendant.pid")
    os.remove(sync_pid_path)
    r, e = babet.pipeline({
        { "sh", { "-c",
            "sleep 30 >/dev/null 2>&1 & echo $! > " .. sync_pid_path .. "; exit 0" } },
        { "cat" },
    }, { timeout = 5 })
    local sync_descendant_pid = pipeline_test_read_pid(sync_pid_path)
    local sync_descendant_running = sync_descendant_pid
        and pipeline_test_pid_is_running(sync_descendant_pid)
    ok("pipeline normal completion cleans background descendants",
        type(r) == "table" and e == nil and sync_descendant_pid ~= nil
        and not sync_descendant_running,
        "pid=" .. tostring(sync_descendant_pid))
    if sync_descendant_running then
        babet.exec("kill", { "-9", tostring(sync_descendant_pid) })
    end
end

-- =====================================================================
print("")
print("=== pipeline streaming ===")

do
    local function drain_pipeline(pipeline, stage_count, timeout)
        local stdout_chunks = {}
        local stderr_chunks = {}
        local stderr_closed = {}
        for i = 1, stage_count do
            stderr_chunks[i] = {}
            stderr_closed[i] = false
        end
        local stdout_closed = false
        local deadline = babet.monotonic() + (timeout or 5)

        while not stdout_closed do
            local data, err = pipeline:read_stdout(65536, 0.01)
            if data then
                stdout_chunks[#stdout_chunks + 1] = data
            elseif err == "closed" then
                stdout_closed = true
            elseif err ~= "timeout" then
                return nil, nil, err
            end

            for i = 1, stage_count do
                if not stderr_closed[i] then
                    data, err = pipeline:read_stderr(i, 65536, 0)
                    if data then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = data
                    elseif err == "closed" then
                        stderr_closed[i] = true
                    elseif err ~= "timeout" then
                        return nil, nil, err
                    end
                end
            end

            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local pending = true
        while pending do
            pending = false
            for i = 1, stage_count do
                if not stderr_closed[i] then
                    pending = true
                    local data, err = pipeline:read_stderr(i, 65536, 0.01)
                    if data then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = data
                    elseif err == "closed" then
                        stderr_closed[i] = true
                    elseif err ~= "timeout" then
                        return nil, nil, err
                    end
                end
            end
            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local stderr_result = {}
        for i = 1, stage_count do
            stderr_result[i] = table.concat(stderr_chunks[i])
        end
        return table.concat(stdout_chunks), stderr_result, nil
    end

    local function write_all_and_drain(pipeline, data, stage_count, timeout)
        local stdout_chunks = {}
        local stderr_chunks = {}
        local stderr_closed = {}
        for i = 1, stage_count do
            stderr_chunks[i] = {}
            stderr_closed[i] = false
        end
        local stdout_closed = false
        local stdin_closed = false
        local offset = 1
        local deadline = babet.monotonic() + (timeout or 8)

        while not stdout_closed do
            if offset <= #data then
                local last = math.min(offset + 32767, #data)
                local written, err = pipeline:write(data:sub(offset, last), 0.01)
                if written then
                    if written == 0 then
                        return nil, nil, "zero-byte write"
                    end
                    offset = offset + written
                elseif err ~= "timeout" then
                    return nil, nil, err
                end
            elseif not stdin_closed then
                local closed, close_err = pipeline:close_stdin()
                if not closed then
                    return nil, nil, close_err
                end
                stdin_closed = true
            end

            local chunk, read_err = pipeline:read_stdout(65536, 0)
            if chunk then
                stdout_chunks[#stdout_chunks + 1] = chunk
            elseif read_err == "closed" then
                stdout_closed = true
            elseif read_err ~= "timeout" then
                return nil, nil, read_err
            end

            for i = 1, stage_count do
                if not stderr_closed[i] then
                    chunk, read_err = pipeline:read_stderr(i, 65536, 0)
                    if chunk then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = chunk
                    elseif read_err == "closed" then
                        stderr_closed[i] = true
                    elseif read_err ~= "timeout" then
                        return nil, nil, read_err
                    end
                end
            end

            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local pending = true
        while pending do
            pending = false
            for i = 1, stage_count do
                if not stderr_closed[i] then
                    pending = true
                    local chunk, read_err =
                        pipeline:read_stderr(i, 65536, 0.01)
                    if chunk then
                        stderr_chunks[i][#stderr_chunks[i] + 1] = chunk
                    elseif read_err == "closed" then
                        stderr_closed[i] = true
                    elseif read_err ~= "timeout" then
                        return nil, nil, read_err
                    end
                end
            end
            if babet.monotonic() >= deadline then
                return nil, nil, "test timeout"
            end
        end

        local stderr_result = {}
        for i = 1, stage_count do
            stderr_result[i] = table.concat(stderr_chunks[i])
        end
        return table.concat(stdout_chunks), stderr_result, nil
    end

    ok("babet.spawnPipeline is a function",
        type(babet.spawnPipeline) == "function")
    ok_raises("spawnPipeline without commands raises",
        function() babet.spawnPipeline() end,
        "spawnPipeline expects a commands table and optional opts")
    ok_raises("spawnPipeline commands must be a table",
        function() babet.spawnPipeline("bad") end,
        "spawnPipeline expects a commands table and optional opts")
    ok_raises("spawnPipeline rejects extra arguments",
        function() babet.spawnPipeline({}, {}, true) end, "spawnPipeline expects a commands table and optional opts")

    local p, e = babet.spawnPipeline({ { "cat" } })
    ok_fail("spawnPipeline requires at least two stages", p, e)

    local too_many = {}
    for i = 1, 33 do too_many[i] = { "true" } end
    p, e = babet.spawnPipeline(too_many)
    ok_fail("spawnPipeline rejects more than 32 stages", p, e)

    p, e = babet.spawnPipeline({ [1] = { "true" }, [3] = { "true" } })
    ok_fail("spawnPipeline commands must be dense", p, e)
    p, e = babet.spawnPipeline({ "true", { "cat" } })
    ok_fail("spawnPipeline stage must be a table", p, e)
    p, e = babet.spawnPipeline({ { "true", {}, {}, "extra" }, { "cat" } })
    ok_fail("spawnPipeline stage rejects extra fields", p, e)
    p, e = babet.spawnPipeline({ { 42 }, { "cat" } })
    ok_fail("spawnPipeline command must be a string", p, e)
    p, e = babet.spawnPipeline({ { "" }, { "cat" } })
    ok_fail("spawnPipeline command must not be empty", p, e)
    p, e = babet.spawnPipeline({ { "echo\0bad" }, { "cat" } })
    ok_fail("spawnPipeline command rejects NUL", p, e)
    p, e = babet.spawnPipeline({ { "echo", "bad" }, { "cat" } })
    ok_fail("spawnPipeline args must be a table", p, e)
    p, e = babet.spawnPipeline({ { "echo", { [2] = "bad" } }, { "cat" } })
    ok_fail("spawnPipeline args must be dense", p, e)
    p, e = babet.spawnPipeline({ { "echo", { true } }, { "cat" } })
    ok_fail("spawnPipeline args contain strings only", p, e)
    p, e = babet.spawnPipeline({ { "echo", { "x\0bad" } }, { "cat" } })
    ok_fail("spawnPipeline argument rejects NUL", p, e)

    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, "bad")
    ok_fail("spawnPipeline opts must be a table", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, { unknown = true })
    ok_fail("spawnPipeline rejects unknown global option", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, { cwd = 42 })
    ok_fail("spawnPipeline cwd must be a string", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        cwd = "/tmp\0bad",
    })
    ok_fail("spawnPipeline cwd rejects NUL", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, { env = "bad" })
    ok_fail("spawnPipeline env must be a table", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { [1] = "bad" },
    })
    ok_fail("spawnPipeline env keys must be strings", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { BABET_BAD = true },
    })
    ok_fail("spawnPipeline env values must be strings", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { [""] = "bad" },
    })
    ok_fail("spawnPipeline env key must not be empty", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { ["A=B"] = "bad" },
    })
    ok_fail("spawnPipeline env key rejects '='", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { ["A\0B"] = "bad" },
    })
    ok_fail("spawnPipeline env key rejects NUL", p, e)
    p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
        env = { A = "x\0bad" },
    })
    ok_fail("spawnPipeline env value rejects NUL", p, e)

    for _, invalid in ipairs({ "1", 0, -1, 0 / 0, math.huge, 3000000 }) do
        p, e = babet.spawnPipeline({ { "echo" }, { "cat" } }, {
            launch_timeout = invalid,
        })
        ok_fail("spawnPipeline rejects invalid launch_timeout " .. tostring(invalid),
            p, e)
    end

    p, e = babet.spawnPipeline({
        { "echo", {}, { unknown = true } }, { "cat" },
    })
    ok_fail("spawnPipeline rejects unknown stage option", p, e)
    p, e = babet.spawnPipeline({
        { "echo", {}, { cwd = true } }, { "cat" },
    })
    ok_fail("spawnPipeline stage cwd must be a string", p, e)
    p, e = babet.spawnPipeline({
        { "echo", {}, { env = true } }, { "cat" },
    })
    ok_fail("spawnPipeline stage env must be a table", p, e)
    p, e = babet.spawnPipeline({
        { "printf", { "x" } }, { "__babet_missing_spawn_pipeline__" },
    })
    ok("spawnPipeline launch error identifies the failed stage",
        p == nil and type(e) == "string"
        and e:find("stage 2", 1, true) ~= nil, tostring(e))
    p, e = babet.spawnPipeline({ { "pwd" }, { "cat" } }, {
        cwd = "/does/not/exist",
    })
    ok_fail("spawnPipeline invalid cwd is returned", p, e)

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "cat; printf first-err >&2" } },
        { "sh", { "-c", "tr a-z A-Z; printf second-err >&2" } },
    })
    ok("spawnPipeline returns a userdata", p ~= nil and e == nil, tostring(e))
    ok("pipeline userdata tostring is informative",
        tostring(p):find("babet.pipeline_process", 1, true) ~= nil)
    local pids = p:pids()
    ok("pipeline pids() returns one PID per stage",
        type(pids) == "table" and #pids == 2)
    ok("pipeline pids are positive integers",
        math.type(pids[1]) == "integer" and pids[1] > 0
        and math.type(pids[2]) == "integer" and pids[2] > 0)
    ok("pipeline is_running() initially true", p:is_running() == true)
    ok("pipeline is_running(stage) initially true",
        p:is_running(1) == true and p:is_running(2) == true)
    ok_raises("pipeline pids rejects extra arguments",
        function() p:pids(true) end, "pipeline.pids expects no argument")
    ok_raises("pipeline is_running stage must be an integer",
        function() p:is_running("1") end, "stage must be an integer")
    ok_raises("pipeline is_running rejects stage zero",
        function() p:is_running(0) end, "stage out of range")
    ok_raises("pipeline is_running rejects stage above count",
        function() p:is_running(3) end, "stage out of range")
    ok_raises("pipeline read_stderr stage must be an integer",
        function() p:read_stderr("1") end, "stage must be an integer")
    ok_raises("pipeline read_stderr rejects stage zero",
        function() p:read_stderr(0) end, "stage out of range")
    ok_raises("pipeline read_stderr rejects stage above count",
        function() p:read_stderr(3) end, "stage out of range")

    local zero_written, zero_err = p:write("", 0)
    ok("pipeline write empty string returns 0",
        zero_written == 0 and zero_err == nil)
    local binary = "hello\0world"
    local offset = 1
    local write_error
    while offset <= #binary do
        local written
        written, write_error = p:write(binary:sub(offset), 1)
        if not written then break end
        offset = offset + written
    end
    ok("pipeline write accepts binary data",
        offset == #binary + 1 and write_error == nil, tostring(write_error))
    ok_act("pipeline close_stdin succeeds", p:close_stdin())
    ok_act("pipeline close_stdin is idempotent", p:close_stdin())

    local out, errs, stream_err = drain_pipeline(p, 2, 5)
    ok("pipeline stdout is streamed progressively",
        out == "HELLO\0WORLD" and stream_err == nil, tostring(stream_err))
    ok("pipeline stderr stage 1 remains separate",
        errs and errs[1] == "first-err", tostring(errs and errs[1]))
    ok("pipeline stderr stage 2 remains separate",
        errs and errs[2] == "second-err", tostring(errs and errs[2]))
    local result, wait_err = p:wait(2)
    ok("pipeline wait returns a result table",
        type(result) == "table" and wait_err == nil)
    ok("pipeline wait exposes the last-stage code",
        result and result.code == 0)
    ok("pipeline wait exposes all_succeeded",
        result and result.all_succeeded == true
        and result.failed_index == nil)
    ok("pipeline wait exposes every stage status",
        result and #result.stages == 2
        and result.stages[1].code == 0
        and result.stages[2].code == 0)
    local result2, wait_err2 = p:wait(0)
    ok("pipeline wait is idempotent",
        result2 and result2.code == 0 and wait_err2 == nil)
    ok("pipeline is_running() false after wait", p:is_running() == false)
    local eof_data, eof_err = p:read_stdout(1, 0)
    ok("pipeline read_stdout after EOF -> closed",
        eof_data == nil and eof_err == "closed")
    ok_act("pipeline close succeeds", p:close())
    ok_act("pipeline close is idempotent", p:close())
    local closed_write, closed_write_err = p:write("x", 0)
    ok("pipeline write after close -> closed",
        closed_write == nil and closed_write_err == "closed")

    local spawn_pipeline_path_dir = sb("spawn_pipeline_path")
    assert(babet.mkdir(spawn_pipeline_path_dir))
    local spawn_pipeline_path_tool =
        spawn_pipeline_path_dir .. "/private-spawn-pipeline-tool"
    local spawn_pipeline_path_file =
        assert(io.open(spawn_pipeline_path_tool, "w"))
    spawn_pipeline_path_file:write(
        "#!/bin/sh\nprintf spawn-pipeline-path")
    spawn_pipeline_path_file:close()
    assert(babet.setMode(spawn_pipeline_path_tool, "755"))
    p, e = babet.spawnPipeline({
        { "private-spawn-pipeline-tool" }, { "cat" },
    }, {
        env = { PATH = spawn_pipeline_path_dir .. ":/usr/bin:/bin" },
    })
    ok("spawnPipeline lookup uses opts.env.PATH",
        p ~= nil and e == nil, tostring(e))
    if p then
        local path_out, path_errs, path_stream_err = drain_pipeline(p, 2, 5)
        local path_result, path_wait_err = p:wait(2)
        ok("spawnPipeline PATH command executes successfully",
            path_out == "spawn-pipeline-path"
            and path_stream_err == nil
            and path_result and path_result.code == 0
            and path_wait_err == nil
            and path_errs[1] == "" and path_errs[2] == "",
            tostring(path_stream_err or path_wait_err))
        p:close()
    end

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "printf '%s|%s' \"$PWD\" \"$BABET_PIPE_ENV\"" }, {
            cwd = "/tmp",
            env = { BABET_PIPE_ENV = "local" },
        } },
        { "cat" },
    }, {
        cwd = "/",
        env = { BABET_PIPE_ENV = "global" },
    })
    ok("spawnPipeline accepts global and local cwd/env",
        p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("spawnPipeline local cwd/env override global values",
        out == "/tmp|local" and result.code == 0
        and errs[1] == "" and errs[2] == "", tostring(out))
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "exit 7" } }, { "cat" },
    })
    ok("spawnPipeline intermediate-failure fixture",
        p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("pipeline global code remains the last stage code",
        result and result.code == 0)
    ok("pipeline wait exposes intermediate failure",
        result and result.all_succeeded == false
        and result.failed_index == 1
        and result.stages[1].code == 7
        and result.stages[2].code == 0)
    p:close()

    local stream_pid_path = sb("pipeline_stream_descendant.pid")
    os.remove(stream_pid_path)
    p, e = babet.spawnPipeline({
        { "sh", { "-c",
            "sleep 30 >/dev/null 2>&1 & echo $! > " .. stream_pid_path .. "; exit 0" } },
        { "cat" },
    })
    ok("spawnPipeline background-descendant fixture",
        p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result, wait_err = p:wait(2)
    local stream_descendant_pid = pipeline_test_read_pid(stream_pid_path)
    local stream_descendant_running = stream_descendant_pid
        and pipeline_test_pid_is_running(stream_descendant_pid)
    ok("pipeline wait cleans descendants after direct stage exit",
        result and wait_err == nil and stream_descendant_pid ~= nil
        and not stream_descendant_running,
        "pid=" .. tostring(stream_descendant_pid))
    if stream_descendant_running then
        babet.exec("kill", { "-9", tostring(stream_descendant_pid) })
    end
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "sleep 0.3; printf done" } }, { "cat" },
    })
    ok("spawnPipeline delayed-output fixture", p ~= nil and e == nil, tostring(e))
    local t0 = babet.monotonic()
    local no_data, timeout_err = p:read_stdout(16, 0.03)
    local elapsed = babet.monotonic() - t0
    ok("pipeline read_stdout timeout is typed and bounded",
        no_data == nil and timeout_err == "timeout" and elapsed < 0.5,
        "err=" .. tostring(timeout_err) .. " dt=" .. tostring(elapsed))
    local no_wait, no_wait_err = p:wait(0)
    ok("pipeline wait(0) is non-blocking",
        no_wait == nil and no_wait_err == "timeout")
    ok("pipeline wait timeout does not terminate stages",
        p:is_running() == true)
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("pipeline remains usable after read/wait timeouts",
        out == "done" and result.code == 0 and stream_err == nil,
        tostring(stream_err))
    p:close()

    local large = string.rep("stream-pipeline-data\0", 25000)
    p, e = babet.spawnPipeline({ { "cat" }, { "cat" }, { "cat" } })
    ok("spawnPipeline large-stdin fixture", p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = write_all_and_drain(p, large, 3, 10)
    result = p:wait(3)
    ok("pipeline large stdin/stdout has no deadlock",
        out == large and result.code == 0 and stream_err == nil,
        "out=" .. tostring(out and #out) .. " err=" .. tostring(stream_err))
    ok("pipeline large binary transfer preserves byte count",
        out and #out == #large)
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "head -c 131072 /dev/zero >&2; printf x" } },
        { "sh", { "-c", "cat; head -c 131072 /dev/zero >&2" } },
    })
    ok("spawnPipeline large-stderr fixture", p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 8)
    result = p:wait(3)
    ok("pipeline drains stdout while both stderr streams are large",
        out == "x" and result.code == 0 and stream_err == nil,
        tostring(stream_err))
    ok("pipeline drains large stderr from stage 1",
        errs and #errs[1] == 131072, tostring(errs and #errs[1]))
    ok("pipeline drains large stderr from stage 2",
        errs and #errs[2] == 131072, tostring(errs and #errs[2]))
    p:close()

    p, e = babet.spawnPipeline({ { "yes" }, { "head", { "-n", "1" } } })
    ok("spawnPipeline SIGPIPE fixture", p ~= nil and e == nil, tostring(e))
    out, errs, stream_err = drain_pipeline(p, 2, 5)
    result = p:wait(2)
    ok("pipeline handles premature downstream close",
        out == "y\n" and result.code == 0 and stream_err == nil,
        tostring(stream_err))
    ok("pipeline records upstream SIGPIPE/non-zero status",
        result and result.all_succeeded == false
        and result.failed_index == 1
        and result.stages[1].code ~= 0)
    p:close()

    p, e = babet.spawnPipeline({ { "sleep", { "10" } }, { "cat" } })
    ok("spawnPipeline kill fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:kill()
    ok("pipeline kill returns per-stage signaled statuses",
        result and wait_err == nil and result.all_succeeded == false
        and result.stages[1].signaled == true)
    ok("pipeline kill uses signal-derived codes",
        result and result.stages[1].code == 137)
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "sleep 10 & wait" } }, { "cat" },
    })
    ok("spawnPipeline terminate fixture", p ~= nil and e == nil, tostring(e))
    result, wait_err = p:terminate(0.05)
    ok("pipeline terminate returns a complete status table",
        result and wait_err == nil and #result.stages == 2)
    ok("pipeline terminate makes the pipeline unsuccessful",
        result and result.all_succeeded == false)
    p:close()

    p, e = babet.spawnPipeline({
        { "sh", { "-c", "sleep 10 & wait" } }, { "cat" },
    })
    ok("spawnPipeline close-cleanup fixture", p ~= nil and e == nil, tostring(e))
    pids = p:pids()
    ok_act("pipeline close terminates active groups", p:close())
    local groups_dead = true
    for _, pid in ipairs(pids) do
        local probe = babet.exec("sh", {
            "-c", "kill -0 " .. tostring(pid) .. " 2>/dev/null",
        })
        groups_dead = groups_dead and type(probe) == "table" and probe.code ~= 0
    end
    ok("pipeline close reaps all direct children", groups_dead)
    ok("closed pipeline reports not running", p:is_running() == false)

    local auto_pids
    do
        local auto <close> = assert(babet.spawnPipeline({
            { "sleep", { "10" } }, { "cat" },
        }))
        auto_pids = auto:pids()
    end
    local auto_dead = true
    for _, pid in ipairs(auto_pids) do
        local probe = babet.exec("sh", {
            "-c", "kill -0 " .. tostring(pid) .. " 2>/dev/null",
        })
        auto_dead = auto_dead and type(probe) == "table" and probe.code ~= 0
    end
    ok("pipeline Lua <close> cleans active children", auto_dead)

    local gc_pids
    do
        local gc_pipeline = assert(babet.spawnPipeline({
            { "sleep", { "10" } }, { "cat" },
        }))
        gc_pids = gc_pipeline:pids()
        gc_pipeline = nil
    end
    collectgarbage("collect")
    collectgarbage("collect")
    local gc_dead = true
    for _, pid in ipairs(gc_pids) do
        gc_dead = gc_dead and not pipeline_test_pid_is_running(pid)
    end
    ok("pipeline GC cleans active direct children", gc_dead)
    if not gc_dead then
        for _, pid in ipairs(gc_pids) do
            babet.exec("kill", { "-9", tostring(pid) })
        end
    end

    p, e = babet.spawnPipeline({ { "cat" }, { "cat" } })
    ok("spawnPipeline method-validation fixture", p ~= nil and e == nil, tostring(e))
    ok_raises("pipeline read_stdout rejects extra arguments",
        function() p:read_stdout(1, 0, true) end, "expects optional max_bytes and timeout")
    ok_raises("pipeline read_stderr rejects extra arguments",
        function() p:read_stderr(1, 1, 0, true) end,
        "expects stage, optional max_bytes and timeout")
    ok_raises("pipeline write rejects extra arguments",
        function() p:write("x", 0, true) end, "pipeline.write expects data and optional timeout")
    ok_raises("pipeline is_running rejects extra arguments",
        function() p:is_running(1, true) end, "pipeline.is_running expects an optional stage")
    ok_raises("pipeline terminate rejects extra arguments",
        function() p:terminate(0, true) end, "pipeline.terminate expects an optional grace period")
    ok_raises("pipeline read_stdout rejects max_bytes <= 0",
        function() p:read_stdout(0) end, "max_bytes must be between 1 and")
    ok_raises("pipeline read_stdout rejects max_bytes > 16 MiB",
        function() p:read_stdout(16 * 1024 * 1024 + 1) end, "max_bytes must be between 1 and")
    ok_raises("pipeline read_stderr rejects max_bytes <= 0",
        function() p:read_stderr(1, 0) end, "max_bytes must be between 1 and")
    ok_raises("pipeline read_stderr rejects max_bytes > 16 MiB",
        function() p:read_stderr(1, 16 * 1024 * 1024 + 1) end, "max_bytes must be between 1 and")
    local bad_read, bad_read_err = p:read_stdout(1, -1)
    ok("pipeline read_stdout rejects negative timeout cleanly",
        bad_read == nil and type(bad_read_err) == "string")
    bad_read, bad_read_err = p:read_stdout(1, 3000000)
    ok("pipeline read_stdout rejects timeout above INT_MAX ms",
        bad_read == nil and type(bad_read_err) == "string")
    bad_read, bad_read_err = p:read_stderr(1, 1, -1)
    ok("pipeline read_stderr rejects negative timeout cleanly",
        bad_read == nil and type(bad_read_err) == "string")
    bad_read, bad_read_err = p:read_stderr(1, 1, 3000000)
    ok("pipeline read_stderr rejects timeout above INT_MAX ms",
        bad_read == nil and type(bad_read_err) == "string")
    ok_raises("pipeline write requires a string",
        function() p:write(42) end, "string expected")
    local bad_write, bad_write_err = p:write("x", -1)
    ok("pipeline write rejects negative timeout cleanly",
        bad_write == nil and type(bad_write_err) == "string")
    bad_write, bad_write_err = p:write("x", 3000000)
    ok("pipeline write rejects timeout above INT_MAX ms",
        bad_write == nil and type(bad_write_err) == "string")
    ok_raises("pipeline close_stdin rejects extra arguments",
        function() p:close_stdin(true) end, "pipeline.close_stdin expects no argument")
    ok_raises("pipeline wait rejects extra arguments",
        function() p:wait(0, 1) end, "pipeline.wait expects an optional timeout")
    local bad_wait, bad_wait_err = p:wait(-1)
    ok("pipeline wait rejects negative timeout cleanly",
        bad_wait == nil and type(bad_wait_err) == "string")
    bad_wait, bad_wait_err = p:wait(3000000)
    ok("pipeline wait rejects timeout above INT_MAX ms",
        bad_wait == nil and type(bad_wait_err) == "string")
    local bad_term, bad_term_err = p:terminate(-1)
    ok("pipeline terminate rejects negative grace cleanly",
        bad_term == nil and type(bad_term_err) == "string")
    bad_term, bad_term_err = p:terminate(3000000)
    ok("pipeline terminate rejects grace above INT_MAX ms",
        bad_term == nil and type(bad_term_err) == "string")
    ok_raises("pipeline kill rejects extra arguments",
        function() p:kill(true) end, "pipeline.kill expects no argument")
    ok_raises("pipeline close rejects extra arguments",
        function() p:close(true) end, "pipeline.close expects no argument")
    p:close()
end

-- =====================================================================
end
