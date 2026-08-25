return function(test, context)
    local _ENV = test:environment(context)
print("")
print("=== workers ===")

-- Régression (revue Gemini post-audit v21) : lua_to_json et
-- json_to_lua (sérialisation spawn/join) ne réservaient pas la pile.
-- 30 niveaux (sous MAX_SERIALIZATION_DEPTH = 32) traversent les 4
-- conversions : args parent->json, json->worker, retour worker->json,
-- json->parent.
do
    local t = { v = 42 }
    for _ = 1, 29 do t = { c = t } end
    local job = babet.workers.spawn("return worker.args", t)
    if job then
        local okj, result = job:join()
        local n, d = result, 0
        while type(n) == "table" and n.c do n = n.c; d = d + 1 end
        ok("workers : aller-retour 30 niveaux (checkstack)",
            okj == true and d == 29
            and type(n) == "table" and n.v == 42,
            "ok=" .. tostring(okj) .. " d=" .. tostring(d))
    else
        ok("workers : spawn 30 niveaux", false)
    end
end

-- Option A (validée) : dès le premier spawn — définitivement, même
-- après join — les mutations d'état process-wide sont verrouillées.
do
    local sv, se = babet.setenv("BABET_AFTER_SPAWN", "x")
    ok_fail("setenv après le premier spawn -> (nil, err)", sv, se)
    ok("  message mentions 'workers'",
        type(se) == "string" and se:find("workers", 1, true) ~= nil,
        tostring(se))
    local cv, ce = babet.chdir(babet.currentDir())
    ok_fail("chdir après le premier spawn -> (nil, err)", cv, ce)
end
do
    local W = babet.workers

    -- ----- contrat de base ----------------------------------------

    ok("babet.workers is a table", type(W) == "table")
    ok("workers.spawn is a function", type(W.spawn) == "function")
    ok("workers.channel is a function", type(W.channel) == "function")

    run_raw_table_access_regressions(W)
    run_raw_table_access_regressions = nil

    do
        local job, spawn_err = W.spawn([[
            local db = assert(babet.sqlite.open(
                ":memory:", { foreign_keys = true }))
            assert(db:exec(
                "CREATE TABLE t(id INTEGER PRIMARY KEY, value TEXT)"))
            assert(db:exec("INSERT INTO t(value) VALUES ('worker')"))
            local foreign_keys
            for row in db:query("PRAGMA foreign_keys") do
                foreign_keys = row.foreign_keys
            end
            local rowid = db:last_insert_rowid()
            local changes = db:changes()
            local total = db:total_changes()
            local savepoint_ok, savepoint_value = db:savepoint(function(tx)
                assert(tx:exec(
                    "INSERT INTO t(value) VALUES ('savepoint-worker')"))
                return tx:changes()
            end)
            return {
                rowid = rowid,
                changes = changes,
                total = total,
                foreign_keys = foreign_keys,
                savepoint_ok = savepoint_ok,
                savepoint_value = savepoint_value,
                total_after_savepoint = db:total_changes(),
            }
        ]])
        local joined, result = false, spawn_err
        if job then
            joined, result = job:join()
        end
        ok("SQLite 2.12 counters and foreign_keys work in a worker",
            joined == true and type(result) == "table"
            and result.rowid == 1 and result.changes == 1
            and result.total == 1 and result.foreign_keys == 1,
            tostring(result))
        ok("SQLite 2.13 savepoints work in a worker",
            joined == true and type(result) == "table"
            and result.savepoint_ok == true
            and result.savepoint_value == 1
            and result.total_after_savepoint == 2,
            tostring(result))
    end

    do
        local job, err = W.spawn("return true", {
            value = babet.sqlite.NULL,
        })
        ok("workers reject sqlite.NULL with an explicit diagnostic",
            job == nil and type(err) == "string"
            and err:find("babet.sqlite.NULL", 1, true) ~= nil,
            tostring(err))

        local channel = assert(W.channel({ capacity = 1 }))
        local sent, send_err = channel:send(babet.sqlite.NULL, 0)
        local marker_ok = channel:send("after-null", 0)
        local received, marker = channel:recv(0)
        ok("channels reject sqlite.NULL atomically with an explicit diagnostic",
            sent == nil and type(send_err) == "string"
            and send_err:find("babet.sqlite.NULL", 1, true) ~= nil
            and marker_ok == true and received == true
            and marker == "after-null",
            tostring(send_err))
        channel:close()
    end

    -- ----- budgets de sérialisation et fidélité numérique ---------

    local function make_shared_tree(depth, leaf)
        local value = leaf
        for _ = 1, depth do
            value = { value, value }
        end
        return value
    end

    local function make_string_amplifier(copies)
        local shared = string.rep("x", 1000000)
        local value = {}
        for i = 1, copies do
            value[i] = shared
        end
        return value
    end

    local function exact_integer_list(actual, expected)
        if type(actual) ~= "table" then
            return false, "actual=" .. type(actual)
        end
        for i = 1, #expected do
            if actual[i] ~= expected[i]
                or math.type(actual[i]) ~= "integer" then
                return false,
                    "index=" .. i
                    .. " expected=" .. tostring(expected[i])
                    .. " actual=" .. tostring(actual[i])
                    .. " type=" .. tostring(math.type(actual[i]))
            end
        end
        if #actual ~= #expected then
            return false,
                "length=" .. tostring(#actual)
                .. " expected=" .. tostring(#expected)
        end
        return true, nil
    end

    local integer_probes = {
        math.maxinteger,
        math.mininteger,
        1 << 53,
        (1 << 53) + 1,
        (1 << 53) + 2,
        -(1 << 53) - 1,
    }

    do
        local job = assert(W.spawn("return worker.args", integer_probes))
        local joined, back = job:join(5)
        local exact, detail = exact_integer_list(back, integer_probes)
        ok("workers integers: spawn args -> return stays exact",
            joined == true and exact,
            "joined=" .. tostring(joined) .. " " .. tostring(detail))
    end

    do
        local job = assert(W.spawn([[
            local received, value = worker.recv(2)
            if not received then return { recv_error = value } end
            return value
        ]]))
        local sent, send_err = job:send(integer_probes, 1)
        local joined, back = job:join(5)
        local exact, detail = exact_integer_list(back, integer_probes)
        ok("workers integers: job.send -> worker.recv stays exact",
            sent == true and send_err == nil
            and joined == true and exact,
            "sent=" .. tostring(sent)
            .. " joined=" .. tostring(joined)
            .. " " .. tostring(detail))
    end

    do
        local job = assert(W.spawn([[
            local sent, err = worker.send(worker.args, 1)
            return { sent = sent, err = err }
        ]], integer_probes))
        local received, back = job:recv(5)
        local joined, status = job:join(5)
        local exact, detail = exact_integer_list(back, integer_probes)
        ok("workers integers: worker.send -> job.recv stays exact",
            received == true and exact
            and joined == true and type(status) == "table"
            and status.sent == true and status.err == nil,
            "received=" .. tostring(received)
            .. " joined=" .. tostring(joined)
            .. " " .. tostring(detail))
    end

    do
        local channel = assert(W.channel({ capacity = 1 }))
        local sent, send_err = channel:send(integer_probes, 0)
        local received, back = channel:recv(0)
        local exact, detail = exact_integer_list(back, integer_probes)
        ok("workers integers: channel round-trip stays exact",
            sent == true and send_err == nil
            and received == true and exact,
            "sent=" .. tostring(sent)
            .. " received=" .. tostring(received)
            .. " " .. tostring(detail))
    end

    do
        local labels = { "NaN", "+Inf", "-Inf" }
        local values = { 0 / 0, math.huge, -math.huge }
        local all_rejected = true
        local details = {}
        for i, value in ipairs(values) do
            local job, err = W.spawn("return true", { value = value })
            local good = job == nil and type(err) == "string"
                and err:find("NaN or Inf", 1, true) ~= nil
            all_rejected = all_rejected and good
            details[#details + 1] = labels[i] .. "=" .. tostring(err)
        end
        ok("workers non-finite: spawn args rejects NaN and infinities",
            all_rejected, table.concat(details, " | "))
    end

    do
        local codes = {
            "return 0 / 0",
            "return math.huge",
            "return -math.huge",
        }
        local all_rejected = true
        local details = {}
        for i, code in ipairs(codes) do
            local job = assert(W.spawn(code))
            local joined, err = job:join(5)
            local good = joined == false and type(err) == "string"
                and err:find("NaN or Inf", 1, true) ~= nil
            all_rejected = all_rejected and good
            details[#details + 1] = i .. "=" .. tostring(err)
        end
        ok("workers non-finite: worker return rejects NaN and infinities",
            all_rejected, table.concat(details, " | "))
    end

    do
        local job = assert(W.spawn([[
            local received, value = worker.recv(2)
            if not received then return { recv_error = value } end
            return value
        ]]))
        local values = { 0 / 0, math.huge, -math.huge }
        local all_rejected = true
        local details = {}
        for i, value in ipairs(values) do
            local sent, err = job:send(value, 0)
            local good = sent == nil and type(err) == "string"
                and err:find("NaN or Inf", 1, true) ~= nil
            all_rejected = all_rejected and good
            details[#details + 1] = i .. "=" .. tostring(err)
        end
        local marker_sent = job:send("after-non-finite", 1)
        local joined, result = job:join(5)
        ok("workers non-finite: job.send rejects without publishing",
            all_rejected and marker_sent == true
            and joined == true and result == "after-non-finite",
            table.concat(details, " | "))
    end

    do
        local job = assert(W.spawn([[
            local values = { 0 / 0, math.huge, -math.huge }
            local results = {}
            for i, value in ipairs(values) do
                local sent, err = worker.send(value, 0)
                results[i] = { sent = sent, err = err }
            end
            return results
        ]]))
        local joined, results = job:join(5)
        local all_rejected = joined == true and type(results) == "table"
        local details = {}
        for i = 1, 3 do
            local entry = type(results) == "table" and results[i] or nil
            local good = type(entry) == "table"
                and entry.sent == false and type(entry.err) == "string"
                and entry.err:find("NaN or Inf", 1, true) ~= nil
            all_rejected = all_rejected and good
            details[#details + 1] = i .. "="
                .. tostring(entry and entry.err)
        end
        local received, reason = job:recv(0)
        ok("workers non-finite: worker.send rejects without publishing",
            all_rejected and received == false and reason == "closed",
            table.concat(details, " | "))
    end

    do
        local channel = assert(W.channel({ capacity = 1 }))
        local values = { 0 / 0, math.huge, -math.huge }
        local all_rejected = true
        local details = {}
        for i, value in ipairs(values) do
            local sent, err = channel:send(value, 0)
            local good = sent == nil and type(err) == "string"
                and err:find("NaN or Inf", 1, true) ~= nil
            all_rejected = all_rejected and good
            details[#details + 1] = i .. "=" .. tostring(err)
        end
        local marker_sent = channel:send("after-non-finite", 0)
        local received, result = channel:recv(0)
        ok("workers non-finite: channel rejects without publishing",
            all_rejected and marker_sent == true
            and received == true and result == "after-non-finite",
            table.concat(details, " | "))
    end

    -- Test lourd activé une seule fois par run_tests.sh : le tableau plat
    -- franchit le plafond d'un seul nœud avec peu d'allocations C++.
    if os.getenv("BABET_TEST_WORKERS_NODE_LIMIT") == "1" then
        do
            local flat = {}
            for i = 1, 1000000 do
                flat[i] = true
            end

            local job, err = W.spawn("return true", flat)
            ok_in("single-run", "workers budget: spawn args hits node limit",
                job == nil and type(err) == "string"
                and err:find("serialization node budget", 1, true) ~= nil,
                tostring(err))
        end
        collectgarbage("collect")
    end

    do
        local accepted = make_shared_tree(14, true)
        local channel = assert(W.channel({ capacity = 1 }))
        local sent, send_err = channel:send(accepted, 0)
        local received, back = channel:recv(5)
        local cursor = back
        local shape_ok = received == true
        for level = 1, 14 do
            shape_ok = shape_ok and type(cursor) == "table"
            if not shape_ok then break end

            if level < 14 then
                shape_ok = type(cursor[1]) == "table"
                    and type(cursor[2]) == "table"
            else
                shape_ok = cursor[1] == true and cursor[2] == true
            end
            if not shape_ok then break end
            cursor = cursor[1]
        end
        ok("workers budget: shared tree below limits round-trips",
            sent == true and send_err == nil and shape_ok
            and cursor == true and back[1] ~= back[2],
            "sent=" .. tostring(sent)
            .. " received=" .. tostring(received))
    end

    do
        local job, err = W.spawn("return true", make_string_amplifier(12))
        ok("workers budget: spawn args hits byte limit",
            job == nil and type(err) == "string"
            and err:find("serialization byte budget", 1, true) ~= nil,
            tostring(err))
    end

    do
        local job = assert(W.spawn([[
            local shared = string.rep("x", 1000000)
            local value = {}
            for i = 1, 12 do value[i] = shared end
            return value
        ]]))
        local joined, err = job:join(30)
        ok("workers budget: worker return hits byte limit",
            joined == false and type(err) == "string"
            and err:find("serialization byte budget", 1, true) ~= nil,
            tostring(err))
    end

    do
        local job = assert(W.spawn([[
            local received, value = worker.recv()
            if not received then return { recv_error = value } end
            return value
        ]]))
        local sent, err = job:send(make_string_amplifier(12), 0)
        local marker_sent = job:send("after-budget", 1)
        local joined, result = job:join(5)
        ok("workers budget: job.send rejects atomically",
            sent == nil and type(err) == "string"
            and err:find("serialization byte budget", 1, true) ~= nil
            and marker_sent == true
            and joined == true and result == "after-budget",
            tostring(err))
    end

    do
        local job = assert(W.spawn([[
            local shared = string.rep("x", 1000000)
            local value = {}
            for i = 1, 12 do value[i] = shared end
            local sent, err = worker.send(value, 0)
            return { sent = sent, err = err }
        ]]))
        local joined, result = job:join(30)
        local received, reason = job:recv(0)
        ok("workers budget: worker.send rejects atomically",
            joined == true and type(result) == "table"
            and result.sent == false and type(result.err) == "string"
            and result.err:find("serialization byte budget", 1, true) ~= nil
            and received == false and reason == "closed",
            tostring(result and result.err))
    end

    do
        local channel = assert(W.channel({ capacity = 1 }))
        local sent, err = channel:send(make_string_amplifier(12), 0)
        local marker_sent = channel:send("after-budget", 0)
        local received, result = channel:recv(0)
        ok("workers budget: channel send rejects atomically",
            sent == nil and type(err) == "string"
            and err:find("serialization byte budget", 1, true) ~= nil
            and marker_sent == true
            and received == true and result == "after-budget",
            tostring(err))
    end

    -- ----- channels directs entre parent et workers ---------------

    do
        local channel = assert(W.channel())
        ok("channel userdata is created", type(channel) == "userdata")
        ok("channel exposes send", type(channel.send) == "function")
        ok("channel exposes recv", type(channel.recv) == "function")
        ok("channel exposes close", type(channel.close) == "function")
        ok("channel exposes is_closed",
            type(channel.is_closed) == "function")
        ok("new channel is open", channel:is_closed() == false)
        ok("channel tostring reports open",
            tostring(channel):find("open", 1, true) ~= nil)

        local sent, send_err = channel:send({ id = 7, value = "hello" }, 0)
        ok("channel parent send succeeds",
            sent == true and send_err == nil)
        local received, value = channel:recv(0)
        ok("channel parent recv restores a table",
            received == true and type(value) == "table"
            and value.id == 7 and value.value == "hello")

        local nil_sent, nil_send_err = channel:send(nil, 0)
        local nil_received, nil_value = channel:recv(0)
        ok("channel transports nil unambiguously",
            nil_sent == true and nil_send_err == nil
            and nil_received == true and nil_value == nil)
    end

    do
        local channel = assert(W.channel())
        local metatable = assert(getmetatable(channel))
        local finalizer = assert(metatable.__gc)
        finalizer(channel)
        finalizer(channel)
        ok("channel manual finalizer is idempotent",
            getmetatable(channel) == nil)
    end

    do
        local channel = assert(W.channel({ capacity = 1 }))
        assert(channel:send("first", 0))
        local full, full_reason = channel:send("second", 0)
        ok("capacity-one channel reports full immediately",
            full == false and full_reason == "full")

        local first_ok, first = channel:recv(0)
        ok("capacity-one channel preserves the queued value",
            first_ok == true and first == "first")

        local empty, empty_reason = channel:recv(0)
        ok("empty channel reports empty immediately",
            empty == false and empty_reason == "empty")

        local timeout, timeout_reason = channel:recv(0.01)
        ok("bounded channel recv reports timeout after waiting",
            timeout == false and timeout_reason == "timeout")
    end

    do
        local channel = assert(W.channel({ capacity = 2 }))
        assert(channel:send("one"))
        assert(channel:send("two"))
        local close_ok, close_err = channel:close()
        local close_again_ok, close_again_err = channel:close()
        ok("channel close is idempotent",
            close_ok == true and close_err == nil
            and close_again_ok == true and close_again_err == nil)
        ok("is_closed is true before draining",
            channel:is_closed() == true)
        ok("channel tostring reports closed",
            tostring(channel):find("closed", 1, true) ~= nil)

        local one_ok, one = channel:recv()
        local two_ok, two = channel:recv()
        local drained, drained_reason = channel:recv()
        local after_close, after_close_reason = channel:send("three", 0)
        ok("closed channel drains existing messages in FIFO order",
            one_ok == true and one == "one"
            and two_ok == true and two == "two")
        ok("closed and drained channel reports closed",
            drained == false and drained_reason == "closed")
        ok("send after channel close reports closed",
            after_close == false and after_close_reason == "closed")
    end

    ok_raises("workers.channel rejects excess arguments",
        function() return W.channel(nil, "extra") end,
        "expected")
    ok_raises("workers.channel rejects non-table opts",
        function() return W.channel(42) end,
        "opts")
    ok_raises("workers.channel rejects unknown options",
        function() return W.channel({ capcity = 4 }) end,
        "unknown option")
    ok_raises("workers.channel rejects non-string option names",
        function() return W.channel({ [1] = 4 }) end,
        "must be strings")
    ok_raises("workers.channel rejects option names containing NUL",
        function()
            return W.channel({ ["capacity\0ignored"] = 4 })
        end, "NUL")
    ok_raises("workers.channel rejects capacity zero",
        function() return W.channel({ capacity = 0 }) end,
        "between 1 and 1000000")
    ok_raises("workers.channel rejects capacity above maximum",
        function() return W.channel({ capacity = 1000001 }) end,
        "between 1 and 1000000")
    ok_raises("workers.channel rejects floating-point capacity",
        function() return W.channel({ capacity = 4.0 }) end,
        "integer")

    do
        local channel = assert(W.channel())
        ok_raises("channel send requires a value",
            function() return channel:send() end,
            "expected")
        ok_raises("channel recv rejects extra arguments",
            function() return channel:recv(0, "extra") end,
            "expected")
        ok_raises("channel close rejects extra arguments",
            function() return channel:close("extra") end,
            "expected")
        ok_raises("channel is_closed rejects extra arguments",
            function() return channel:is_closed("extra") end,
            "expected")
        ok_raises("channel send rejects negative timeout",
            function() return channel:send("x", -1) end,
            ">= 0")
        ok_raises("channel recv rejects non-numeric timeout",
            function() return channel:recv("1") end,
            "number")
    end

    do
        local channel = assert(W.channel())
        local value, err = channel:send(function() end, 0)
        ok("channel send rejects functions as runtime data error",
            value == nil and type(err) == "string"
            and err:find("workers.channel.send", 1, true) ~= nil
            and err:find("function", 1, true) ~= nil,
            tostring(err))

        local channel_value, channel_err = channel:send(channel, 0)
        ok("a channel cannot be sent as a channel message",
            channel_value == nil and type(channel_err) == "string"
            and channel_err:find("userdata", 1, true) ~= nil,
            tostring(channel_err))
    end

    do
        local no_channels = assert(W.spawn([[
            return type(worker.channels) == "table"
                and next(worker.channels) == nil
        ]]))
        local joined, value = no_channels:join()
        ok("worker.channels always exists as a table",
            joined == true and value == true)
    end

    do
        local channel = assert(W.channel())
        ok_raises("workers.spawn rejects non-table opts.channels",
            function()
                return W.spawn("return true", nil, { channels = 42 })
            end, "opts.channels")
        ok_raises("workers.spawn rejects numeric channel names",
            function()
                return W.spawn("return true", nil, {
                    channels = { [1] = channel },
                })
            end, "channel names")
        ok_raises("workers.spawn rejects empty channel names",
            function()
                return W.spawn("return true", nil, {
                    channels = { [""] = channel },
                })
            end, "non-empty")
        ok_raises("workers.spawn rejects NUL channel names",
            function()
                return W.spawn("return true", nil, {
                    channels = { ["tasks\0hidden"] = channel },
                })
            end, "without NUL")
        ok_raises("workers.spawn rejects invalid UTF-8 channel names",
            function()
                return W.spawn("return true", nil, {
                    channels = { [string.char(0xC0, 0x80)] = channel },
                })
            end, "UTF-8")
        ok_raises("workers.spawn rejects non-channel values",
            function()
                return W.spawn("return true", nil, {
                    channels = { tasks = {} },
                })
            end, "created by babet.workers.channel")
    end

    do
        local tasks = assert(W.channel({ capacity = 4 }))
        local worker_job = assert(W.spawn([[
            local ok_recv, task = worker.channels.tasks:recv(2)
            if not ok_recv then return task end
            return task.value * 2
        ]], nil, {
            channels = { tasks = tasks },
        }))
        assert(tasks:send({ value = 21 }, 2))
        local joined, value = worker_job:join(2)
        ok("parent sends directly through a channel to a worker",
            joined == true and value == 42,
            "joined=" .. tostring(joined) .. " value=" .. tostring(value))
    end

    do
        local results = assert(W.channel({ capacity = 4 }))
        local worker_job = assert(W.spawn([[
            local ok_send, send_err = worker.channels.results:send({
                answer = 42,
            }, 2)
            return ok_send == true and send_err == nil
        ]], nil, {
            channels = { results = results },
        }))
        local received, value = results:recv(2)
        local joined, worker_value = worker_job:join(2)
        ok("worker sends directly through a channel to the parent",
            received == true and value.answer == 42
            and joined == true and worker_value == true)
    end

    do
        local shared = assert(W.channel({ capacity = 2 }))
        local worker_job = assert(W.spawn([[
            assert(worker.channels.left:send("same-object", 1))
            local ok_recv, value = worker.channels.right:recv(1)
            return ok_recv and value == "same-object"
        ]], nil, {
            channels = {
                left = shared,
                right = shared,
            },
        }))
        local joined, value = worker_job:join(2)
        ok("two worker channel names may reference the same channel",
            joined == true and value == true)
    end

    do
        local tasks = assert(W.channel({ capacity = 16 }))
        local results = assert(W.channel({ capacity = 16 }))

        local producer = assert(W.spawn([[
            for i = 1, 10 do
                local ok_send, send_err = worker.channels.tasks:send({
                    id = i,
                    value = i * 10,
                }, 2)
                if not ok_send then return send_err end
            end
            return "producer done"
        ]], nil, {
            channels = { tasks = tasks },
        }))

        local consumer = assert(W.spawn([[
            for _ = 1, 10 do
                local ok_recv, task = worker.channels.tasks:recv(2)
                if not ok_recv then return task end
                local ok_send, send_err = worker.channels.results:send({
                    id = task.id,
                    result = task.value * 2,
                }, 2)
                if not ok_send then return send_err end
            end
            return "consumer done"
        ]], nil, {
            channels = {
                tasks = tasks,
                results = results,
            },
        }))

        local direct_ok = true
        for expected = 1, 10 do
            local ok_recv, result = results:recv(2)
            if not ok_recv
                or result.id ~= expected
                or result.result ~= expected * 20 then
                direct_ok = false
                break
            end
        end
        local producer_ok, producer_result = producer:join(2)
        local consumer_ok, consumer_result = consumer:join(2)
        ok("worker A sends directly to worker B in FIFO order",
            direct_ok
            and producer_ok == true and producer_result == "producer done"
            and consumer_ok == true and consumer_result == "consumer done")
    end

    do
        local tasks = assert(W.channel({ capacity = 32 }))
        local results = assert(W.channel({ capacity = 256 }))
        local jobs = {}

        for producer_id = 1, 2 do
            jobs[#jobs + 1] = assert(W.spawn([[
                for i = 1, 100 do
                    local ok_send, send_err = worker.channels.tasks:send({
                        producer = worker.args.producer,
                        sequence = i,
                    }, 5)
                    if not ok_send then return send_err end
                end
                return true
            ]], { producer = producer_id }, {
                channels = { tasks = tasks },
            }))
        end

        for _ = 1, 2 do
            jobs[#jobs + 1] = assert(W.spawn([[
                for _ = 1, 100 do
                    local ok_recv, task = worker.channels.tasks:recv(5)
                    if not ok_recv then return task end
                    local ok_send, send_err = worker.channels.results:send(
                        task, 5)
                    if not ok_send then return send_err end
                end
                return true
            ]], nil, {
                channels = {
                    tasks = tasks,
                    results = results,
                },
            }))
        end

        local seen = { [1] = {}, [2] = {} }
        local received_all = true
        for _ = 1, 200 do
            local ok_recv, item = results:recv(5)
            if not ok_recv
                or type(item) ~= "table"
                or not seen[item.producer]
                or seen[item.producer][item.sequence] then
                received_all = false
                break
            end
            seen[item.producer][item.sequence] = true
        end

        local all_jobs_ok = true
        for _, job in ipairs(jobs) do
            local joined, value = job:join(5)
            if joined ~= true or value ~= true then
                all_jobs_ok = false
            end
        end
        for producer_id = 1, 2 do
            for sequence = 1, 100 do
                if not seen[producer_id][sequence] then
                    received_all = false
                end
            end
        end
        ok("channel is safe with multiple producers and consumers",
            received_all and all_jobs_ok)
    end

    do
        local channel = assert(W.channel())
        local blocked = assert(W.spawn([[
            local ok_recv, reason = worker.channels.channel:recv()
            return { ok = ok_recv, reason = reason }
        ]], nil, {
            channels = { channel = channel },
        }))
        babet.sleep(20, "ms")
        assert(channel:close())
        local joined, result = blocked:join(2)
        ok("closing a channel wakes a blocked receiver",
            joined == true and result.ok == false
            and result.reason == "closed")
    end

    do
        local channel = assert(W.channel({ capacity = 1 }))
        assert(channel:send("already full"))
        local blocked = assert(W.spawn([[
            local ok_send, reason = worker.channels.channel:send(
                "blocked", 10)
            return { ok = ok_send, reason = reason }
        ]], nil, {
            channels = { channel = channel },
        }))
        babet.sleep(20, "ms")
        assert(channel:close())
        local joined, result = blocked:join(2)
        local queued_ok, queued = channel:recv(0)
        local drained, drained_reason = channel:recv(0)
        ok("closing a channel wakes a blocked sender",
            joined == true and result.ok == false
            and result.reason == "closed")
        ok("close during blocked send preserves the existing message",
            queued_ok == true and queued == "already full"
            and drained == false and drained_reason == "closed")
    end

    do
        local channel = assert(W.channel())
        local blocked = assert(W.spawn([[
            local ok_recv, reason = worker.channels.channel:recv()
            return { ok = ok_recv, reason = reason }
        ]], nil, {
            channels = { channel = channel },
        }))
        babet.sleep(20, "ms")
        assert(blocked:cancel())
        local joined, result = blocked:join(2)
        local still_open = not channel:is_closed()
        local parent_send = channel:send("parent still owns it", 0)
        local parent_recv, parent_value = channel:recv(0)
        ok("cancelling a worker wakes its blocked channel recv",
            joined == true and result.ok == false
            and result.reason == "cancelled")
        ok("worker cancellation does not close the shared channel",
            still_open and parent_send == true
            and parent_recv == true
            and parent_value == "parent still owns it")
    end

    do
        local channel = assert(W.channel({ capacity = 1 }))
        assert(channel:send("queued"))
        local blocked = assert(W.spawn([[
            local ok_send, reason = worker.channels.channel:send(
                "blocked", 10)
            return { ok = ok_send, reason = reason }
        ]], nil, {
            channels = { channel = channel },
        }))
        babet.sleep(20, "ms")
        assert(blocked:cancel())
        local joined, result = blocked:join(2)
        local queued_ok, queued = channel:recv(0)
        ok("cancelling a worker wakes its blocked channel send",
            joined == true and result.ok == false
            and result.reason == "cancelled")
        ok("cancelled channel send preserves the queued message",
            channel:is_closed() == false
            and queued_ok == true and queued == "queued")
    end

    do
        local channel = assert(W.channel())
        local worker_job = assert(W.spawn([[
            local ok_send, send_err = worker.channels.channel:send(
                "still alive", 1)
            return ok_send == true and send_err == nil
        ]], nil, {
            channels = { channel = channel },
        }))
        channel = nil
        collectgarbage("collect")
        local joined, value = worker_job:join(2)
        ok("collecting the parent handle does not invalidate worker handle",
            joined == true and value == true)
    end

    do
        local channel = assert(W.channel())
        local worker_job = assert(W.spawn([[
            return worker.channels.channel:send("persist", 1)
        ]], nil, {
            channels = { channel = channel },
        }))
        local joined, sent = worker_job:join(2)
        local received, value = channel:recv(0)
        ok("worker destruction does not invalidate the parent handle",
            joined == true and sent == true
            and received == true and value == "persist")
    end

    -- Tous les sous-modules babet.* sont enregistrés dans chaque état Lua.
    do
        local w = W.spawn([[
            local source = string.char(0, 1, 2, 251, 255)
            local encoded, encode_err = babet.base64.encode(source, {
                url_safe = true,
                padding = false,
            })
            if not encoded then return false end
            local decoded, decode_err = babet.base64.decode(encoded, {
                url_safe = true,
                allow_unpadded = true,
            })
            return encode_err == nil and decode_err == nil
                and decoded == source
        ]])
        local joined, value = w:join()
        ok("base64 is available and binary-safe inside a worker",
            joined == true and value == true,
            "joined=" .. tostring(joined) .. " value=" .. tostring(value))
    end


    do
        local worker_path = sb("atomic-worker.dat")
        local w = W.spawn([[
            local ok_write, write_err = babet.writeFileAtomic(
                worker.args.path,
                "worker\0binary\255",
                { permissions = tonumber("600", 8) }
            )
            if not ok_write then return write_err end
            return true
        ]], { path = worker_path })
        local joined, value = w:join()
        local file = io.open(worker_path, "rb")
        local contents = file and file:read("*a") or nil
        if file then file:close() end
        ok("writeFileAtomic is available and binary-safe inside a worker",
            joined == true and value == true
            and contents == "worker\0binary\255",
            "joined=" .. tostring(joined) .. " value=" .. tostring(value))
    end


    do
        local race_path = sb("atomic-worker-race.dat")
        local code = [[
            local ok_write, write_err = babet.writeFileAtomic(
                worker.args.path, worker.args.value)
            return {
                written = ok_write == true,
                error = write_err,
                value = worker.args.value,
            }
        ]]
        local first = assert(W.spawn(code, {
            path = race_path,
            value = "first",
        }))
        local second = assert(W.spawn(code, {
            path = race_path,
            value = "second",
        }))
        local ok_first, result_first = first:join()
        local ok_second, result_second = second:join()
        local winners = 0
        if ok_first and result_first.written then winners = winners + 1 end
        if ok_second and result_second.written then winners = winners + 1 end
        local file = io.open(race_path, "rb")
        local final = file and file:read("*a") or nil
        if file then file:close() end
        ok("writeFileAtomic no-overwrite publication has one concurrent winner",
            ok_first == true and ok_second == true and winners == 1,
            "winners=" .. tostring(winners))
        ok("writeFileAtomic concurrent winner published complete content",
            final == "first" or final == "second",
            "final=" .. tostring(final))
    end

    do
        local race_path = sb("atomic-worker-overwrite-race.dat")
        assert(babet.writeFileAtomic(race_path, "initial"))
        local code = [[
            local ok_write, write_err = babet.writeFileAtomic(
                worker.args.path, worker.args.value, { overwrite = true })
            return ok_write == true and write_err == nil
        ]]
        local first = assert(W.spawn(code, {
            path = race_path,
            value = "overwrite-first",
        }))
        local second = assert(W.spawn(code, {
            path = race_path,
            value = "overwrite-second",
        }))
        local ok_first, result_first = first:join()
        local ok_second, result_second = second:join()
        local file = io.open(race_path, "rb")
        local final = file and file:read("*a") or nil
        if file then file:close() end
        ok("writeFileAtomic concurrent overwrite writers both complete",
            ok_first == true and result_first == true
            and ok_second == true and result_second == true)
        ok("writeFileAtomic concurrent overwrite leaves one complete version",
            final == "overwrite-first" or final == "overwrite-second",
            "final=" .. tostring(final))
    end

    -- ----- mauvais usage : luaL_error -----------------------------

    ok("spawn() without args raises",
        pcall(function() return W.spawn() end) == false)
    ok("spawn({}) raises (code not a string)",
        pcall(function() return W.spawn({}) end) == false)
    ok("DOC 3 spawn(42) raises (strict code string)",
        pcall(function() return W.spawn(42) end) == false)
    ok("spawn('code', 42) raises (args not a table)",
        pcall(function() return W.spawn("return 1", 42) end) == false)
    ok("spawn('code', nil, 42) raises (opts not a table)",
        pcall(function() return W.spawn("return 1", nil, 42) end)
        == false)

    ok("LOT 11 workers.spawn rejects excess arguments",
        pcall(function()
            return W.spawn("return 1", nil, nil, "extra")
        end) == false)

    ok_raises("workers.spawn rejects unknown options",
        function()
            return W.spawn("return 1", nil, { inbox_capcity = 8 })
        end, "unknown option")
    ok_raises("workers.spawn rejects non-string option names",
        function()
            return W.spawn("return 1", nil, { [1] = 8 })
        end, "must be strings")
    ok_raises("workers.spawn rejects option names containing NUL",
        function()
            return W.spawn("return 1", nil, {
                ["inbox_capacity\0ignored"] = 8,
            })
        end, "NUL")

    -- ----- refus de sérialisation : function ----------------------

    do
        local v, e = W.spawn("return 1", { fn = function() end })
        ok_fail("spawn(code, {fn=function}) -> (nil, err)", v, e)
        ok("  err prefixed with 'workers: '",
            type(e) == "string"
            and e:find("workers: ", 1, true) == 1)
        ok("  err mentions 'function'",
            type(e) == "string"
            and e:find("function", 1, true) ~= nil)
    end

    -- ----- refus de sérialisation : userdata ----------------------

    do
        local s = babet.socket.listen("127.0.0.1", 0)
        if s then
            local v, e = W.spawn("return 1", { sock = s })
            ok_fail("spawn(code, {sock=userdata}) -> (nil, err)",
                v, e)
            ok("  err mentions 'userdata'",
                type(e) == "string"
                and e:find("userdata", 1, true) ~= nil)
            s:close()
        end
    end

    -- ----- refus de sérialisation : thread (coroutine) ------------

    do
        local co = coroutine.create(function() end)
        local v, e = W.spawn("return 1", { co = co })
        ok_fail("spawn(code, {co=coroutine}) -> (nil, err)", v, e)
        ok("  err mentions 'coroutine'",
            type(e) == "string"
            and e:find("coroutine", 1, true) ~= nil)
    end

    -- ----- refus de sérialisation : cycle (via profondeur max) ----

    do
        local t = {}
        t.self = t
        local v, e = W.spawn("return 1", { cycle = t })
        ok_fail("spawn(code, {cycle=self_ref}) -> (nil, err)", v, e)
        ok("  err mentions 'nested' or 'cycle' or 'deep'",
            type(e) == "string"
            and (e:find("nested", 1, true) ~= nil
                or e:find("cycle", 1, true) ~= nil
                or e:find("deep", 1, true) ~= nil))
    end

    -- ----- formes de tables et chaînes transférables -------------

    do
        local sparse, sparse_err = W.spawn("return 1", { [2] = "x" })
        ok_fail("DOC 3 workers: sparse args table rejected",
            sparse, sparse_err)

        local mixed, mixed_err = W.spawn("return 1",
            { [1] = "x", name = "mixed" })
        ok_fail("DOC 3 workers: mixed list/map args rejected",
            mixed, mixed_err)

        local nul_value, nul_value_err = W.spawn("return 1",
            { value = "a\0b" })
        ok_fail("DOC 3 workers: NUL string in args rejected",
            nul_value, nul_value_err)
    end

    -- ----- spawn + join : retours simples -------------------------

    do
        local w = W.spawn("return 42")
        local jok, val = w:join()
        ok("join: integer -> (true, 42)", jok == true and val == 42)

        w = W.spawn("return 'hello'")
        jok, val = w:join()
        ok("join: string -> (true, 'hello')",
            jok == true and val == "hello")

        w = W.spawn("return true")
        jok, val = w:join()
        ok("join: boolean -> (true, true)",
            jok == true and val == true)

        -- Convention pcall : nil returned != error
        w = W.spawn("return nil")
        jok, val = w:join()
        ok("join: nil returned -> (true, nil) -- pcall convention",
            jok == true and val == nil)

        -- Pas de return = nil implicite
        w = W.spawn("local x = 1")
        jok, val = w:join()
        ok("join: no return -> (true, nil)",
            jok == true and val == nil)

        -- Limitation : seul le 1er return est transmis. Documenté
        -- in the README (post-ChatGPT review).
        w = W.spawn("return 10, 20, 30")
        jok, val = w:join()
        ok("join: return multi -> only the 1st crosses (val == 10)",
            jok == true and val == 10)
    end

    -- ----- spawn + join: returned table -------------------------

    do
        local w = W.spawn("return { name = 'alice', age = 30 }")
        local jok, val = w:join()
        ok("join: table -> (true, table)",
            jok == true and type(val) == "table")
        ok("  table.name == 'alice'",
            type(val) == "table" and val.name == "alice")
        ok("  table.age == 30",
            type(val) == "table" and val.age == 30)

        -- Séquence imbriquée
        w = W.spawn("return { 'a', 'b', 'c' }")
        jok, val = w:join()
        ok("join: sequence -> 1..n indexed table",
            jok == true and type(val) == "table"
            and #val == 3 and val[1] == "a" and val[3] == "c")
    end

    -- ----- spawn + join : worker-side error ----------------------

    do
        local w = W.spawn("error('boom')")
        local jok, val = w:join()
        ok("join: error() -> (false, msg)",
            jok == false and type(val) == "string")
        ok("  msg contains 'boom'",
            type(val) == "string"
            and val:find("boom", 1, true) ~= nil)

        w = W.spawn("error({ code = 42 })")
        jok, val = w:join()
        ok("LOT 5B worker non-string error has a useful diagnostic",
            jok == false and type(val) == "string"
            and (val:find("table:", 1, true) ~= nil
                 or val:find("type table", 1, true) ~= nil),
            "ok=" .. tostring(jok) .. " val=" .. tostring(val))

        -- Code Lua invalid -> chargement échoue
        w = W.spawn("this is not valid lua %%%")
        jok, val = w:join()
        ok("join: invalid Lua code -> (false, msg)",
            jok == false and type(val) == "string")

        -- Une chaîne invalide pour le transport doit être refusée avant
        -- json.dump(). Depuis la factorisation du sérialiseur des channels,
        -- ce cas n'atteint donc plus le filet catch C++ : il produit une
        -- erreur de transfert précise, sans quitter la pthread.
        w = W.spawn("return string.char(0xc0, 0x80)")
        jok, val = w:join()
        ok("worker return: invalid UTF-8 is rejected explicitly",
            jok == false and type(val) == "string"
            and val:find("not transferable", 1, true) ~= nil
            and val:find("non-UTF-8", 1, true) ~= nil,
            "ok=" .. tostring(jok) .. " val=" .. tostring(val))
        ok("  process remains alive after rejected worker return",
            babet.pid() > 0)
    end

    -- ----- worker.args : argument transmission ---------------

    do
        local w = W.spawn(
            "return worker.args.x + worker.args.y",
            { x = 10, y = 20 })
        local jok, val = w:join()
        ok("worker.args : addition (10+20) -> 30",
            jok == true and val == 30)

        -- worker.args = nil quand pas d'args
        w = W.spawn("return (worker.args == nil)")
        jok, val = w:join()
        ok("worker.args == nil when no args passed",
            jok == true and val == true)

        -- arg = nil worker side (décision W-7)
        w = W.spawn("return (arg == nil)")
        jok, val = w:join()
        ok("arg == nil in worker (no inheritance from parent)",
            jok == true and val == true)
    end

    -- ----- status + join(timeout) + annulation coopérative -------

    do
        local w = assert(W.spawn([[
            babet.sleep(400, "ms")
            return "finished"
        ]]))

        ok("job.status is a function", type(w.status) == "function")
        ok("job.cancel is a function", type(w.cancel) == "function")
        ok("status() starts at running",
            w:status() == "running")

        local joined_now, reason_now = w:join(0)
        ok("join(0) while running -> (nil, 'timeout')",
            joined_now == nil and reason_now == "timeout",
            "got=(" .. tostring(joined_now) .. ", "
                .. tostring(reason_now) .. ")")
        ok("join(0) timeout does not consume result",
            w:status() == "running")

        local joined_short, reason_short = w:join(0.02)
        ok("join(timeout) expiry -> (nil, 'timeout')",
            joined_short == nil and reason_short == "timeout",
            "got=(" .. tostring(joined_short) .. ", "
                .. tostring(reason_short) .. ")")

        local joined_final, value_final = w:join(2)
        ok("join after timeout can still consume the result",
            joined_final == true and value_final == "finished",
            "got=(" .. tostring(joined_final) .. ", "
                .. tostring(value_final) .. ")")
        ok("status() remains done after result consumption",
            w:status() == "done")
    end

    do
        local w = assert(W.spawn("return 99"))
        local deadline = babet.monotonic() + 2
        while w:status() == "running" and babet.monotonic() < deadline do
            babet.sleep(1, "ms")
        end
        ok("status() reports done without consuming a successful result",
            w:status() == "done")
        local joined, value = w:join(0)
        ok("join(0) consumes a successful result observed by status()",
            joined == true and value == 99)
    end

    do
        local w = assert(W.spawn([[
            local ok_recv, value = worker.recv(2)
            if not ok_recv then
                return "recv failed: " .. tostring(value)
            end
            return value
        ]]))
        local joined, reason = w:join(0.01)
        ok("join timeout leaves worker messaging usable",
            joined == nil and reason == "timeout")
        local sent, send_err = w:send("after-timeout", 1)
        local joined_after, value_after = w:join(2)
        ok("send and later join still work after join timeout",
            sent == true and send_err == nil
            and joined_after == true and value_after == "after-timeout",
            "sent=" .. tostring(sent)
                .. " joined=" .. tostring(joined_after)
                .. " value=" .. tostring(value_after))
    end

    do
        local w = assert(W.spawn("error('status boom')"))
        local deadline = babet.monotonic() + 2
        while w:status() == "running" and babet.monotonic() < deadline do
            babet.sleep(1, "ms")
        end
        ok("status() reports error without consuming result",
            w:status() == "error")
        local joined, message = w:join(0)
        ok("join(0) consumes an already failed worker",
            joined == false and type(message) == "string"
            and message:find("status boom", 1, true) ~= nil)
        ok("status() still reports error after join",
            w:status() == "error")
    end

    do
        local w = assert(W.spawn([[
            local ok_recv, reason = worker.recv()
            if ok_recv then
                return "unexpected message"
            end
            local was_cancelled = worker.cancelled()
            local sent, send_err = worker.send({
                reason = reason,
                cancelled = was_cancelled,
            })
            if not sent then
                return "final send failed: " .. tostring(send_err)
            end
            return reason
        ]]))

        babet.sleep(20, "ms")
        local cancelled, cancel_err = w:cancel()
        ok("cancel() -> (true, nil)",
            cancelled == true and cancel_err == nil)
        local cancelled_again, cancel_err_again = w:cancel()
        ok("cancel() is idempotent",
            cancelled_again == true and cancel_err_again == nil)

        local send_ok, send_reason = w:send("late command", 0)
        ok("send after cancel -> (false, 'cancelled')",
            send_ok == false and send_reason == "cancelled",
            "got=(" .. tostring(send_ok) .. ", "
                .. tostring(send_reason) .. ")")

        local recv_ok, final_message = w:recv(2)
        ok("outbox remains drainable after cancel",
            recv_ok == true and type(final_message) == "table"
            and final_message.reason == "cancelled"
            and final_message.cancelled == true,
            "recv_ok=" .. tostring(recv_ok))

        local joined, result = w:join(2)
        ok("cancelled worker terminates cooperatively",
            joined == true and result == "cancelled",
            "got=(" .. tostring(joined) .. ", "
                .. tostring(result) .. ")")
        ok("cooperative cancellation keeps final state done",
            w:status() == "done")
    end

    do
        local w = assert(W.spawn([[
            assert(worker.send("ready"))
            babet.sleep(100, "ms")
            local ok_recv, value = worker.recv()
            return { ok = ok_recv, value = value }
        ]]))
        local ready_ok, ready = w:recv(2)
        assert(ready_ok and ready == "ready")
        assert(w:send("queued-before-cancel"))
        assert(w:cancel())
        local joined, result = w:join(2)
        ok("cancel prevents queued inbox commands from being delivered",
            joined == true and type(result) == "table"
            and result.ok == false and result.value == "cancelled",
            "joined=" .. tostring(joined)
                .. " value=" .. tostring(result and result.value))
    end

    do
        local w = assert(W.spawn([[
            while not worker.cancelled() do
                babet.sleep(1, "ms")
            end
            return "observed"
        ]]))
        assert(w:cancel())
        local joined, result = w:join(2)
        ok("worker.cancelled() observes parent cancellation",
            joined == true and result == "observed")
    end

    do
        local w = assert(W.spawn("return 1"))
        ok("join rejects a negative timeout",
            pcall(function() return w:join(-1) end) == false)
        ok("join rejects a non-number timeout",
            pcall(function() return w:join("0.1") end) == false)
        ok("join rejects NaN",
            pcall(function() return w:join(0 / 0) end) == false)
        ok("join rejects infinity",
            pcall(function() return w:join(math.huge) end) == false)
        ok("join rejects excess arguments",
            pcall(function() return w:join(0, "extra") end) == false)
        ok("status rejects excess arguments",
            pcall(function() return w:status("extra") end) == false)
        ok("cancel rejects excess arguments",
            pcall(function() return w:cancel("extra") end) == false)
        local arity_worker = assert(W.spawn([[
            local ok_call = pcall(function()
                return worker.cancelled("extra")
            end)
            return ok_call
        ]]))
        local arity_ok, arity_result = arity_worker:join(2)
        ok("worker.cancelled rejects arguments",
            arity_ok == true and arity_result == false)
        local joined, value = w:join()
        ok("worker remains joinable after rejected lifecycle calls",
            joined == true and value == 1)
    end

    -- ----- poll : running / done / error --------------------------

    do
        -- poll() consomme le résultat dès qu'il renvoie done/error.
        -- Le premier appel peut déjà voir done sur une machine rapide :
        -- dans ce cas, on utilise immédiatement sa valeur et on ne poll
        -- pas une deuxième fois comme si le résultat était encore présent.
        local w = W.spawn(
            "babet.sleep(300, 'ms'); return 'ok'")
        local state, value = w:poll()
        ok("poll right after spawn: 'running' or 'done'",
            state == "running" or state == "done",
            "state=" .. tostring(state))

        if state == "running" then
            babet.sleep(500, "ms")
            state, value = w:poll()
        end
        ok("poll final state: 'done'",
            state == "done",
            "state=" .. tostring(state))
        ok("  val == 'ok'", value == "ok")

        local joined_after_poll, join_err = w:join()
        ok("DOC 3 join after poll(done) reports already consumed",
            joined_after_poll == false
            and type(join_err) == "string"
            and join_err:find("already consumed", 1, true) ~= nil)

        -- poll sur worker en erreur
        local w2 = W.spawn("error('bad')")
        babet.sleep(200, "ms")
        local state3, val3 = w2:poll()
        ok("poll after error: 'error'",
            state3 == "error",
            "state=" .. tostring(state3))
        ok("  val contains 'bad'",
            type(val3) == "string"
            and val3:find("bad", 1, true) ~= nil)
    end

    -- ----- worker = mini-Babet complet -------------------------

    do
        -- Accès à babet.* depuis le worker
        local w = W.spawn(
            "return babet.json.encode({ a = 1, b = 2 })")
        local jok, val = w:join()
        ok("worker can use babet.json.encode",
            jok == true and type(val) == "string"
            and val:find('"a":1', 1, true) ~= nil)

        -- Accès aux modules bundlés via require()
        w = W.spawn(
            "local insp = require('inspect'); "
            .. "return type(insp({1,2,3}))")
        jok, val = w:join()
        ok("worker can require('inspect') (bundled module)",
            jok == true and val == "string")

        -- Modules utilisateur via require() : même searcher
        -- (package.path en mode dossier, embedded searcher en mode
        -- packagé). mymod/init.lua fournit hello() qui returns
        -- "init.lua loaded !".
        w = W.spawn(
            "local m = require('mymod'); return m.hello()")
        jok, val = w:join()
        ok("worker can require('mymod') (user module)",
            jok == true and type(val) == "string"
            and val:find("init.lua", 1, true) ~= nil,
            "val=" .. tostring(val))
    end

    -- ===== TEST CRUCIAL : VRAI PARALLÉLISME =======================
    -- 4 workers qui font chacun sleep(700ms). En parallèle, le temps
    -- wall-clock is close to 700ms (= 0 or 1 second depending on timing).
    -- En série, ce serait 4 × 700 = 2.8s, mesurable via os.time().
    --
    -- Pourquoi pas os.clock() : os.clock() mesure le CPU du process
    -- parent SLEEPING in pthread_join. It would return ~0 in
    -- deux cas (parallèle ET série), donc ne distingue rien. Seul
    -- os.time() (wall-clock) discrimine.

    do
        local N = 4
        local sleep_ms = 700
        local t_start = os.time()
        local workers = {}
        for i = 1, N do
            workers[i] = W.spawn(string.format(
                "babet.sleep(%d, 'ms'); return %d",
                sleep_ms, i))
        end
        local results = {}
        for i = 1, N do
            local jok, val = workers[i]:join()
            results[i] = jok and val or nil
        end
        local elapsed = os.time() - t_start

        ok("parallelism: 4 workers all completed",
            #results == N
            and results[1] == 1 and results[2] == 2
            and results[3] == 3 and results[4] == 4)
        ok("parallelism: wall-clock < 2s "
            .. "(serial = ~3s, parallel = ~1s)",
            elapsed < 2,
            "elapsed=" .. tostring(elapsed) .. "s")
        print(string.format(
            "[INFO] workers: 4 x %dms sleep, wall-clock = %ds "
            .. "(parallel: 0-1, serial: 3+)",
            sleep_ms, elapsed))
    end

    -- ----- lot 2 : SIGPIPE reste process-wide intact -------------
    -- Ancien bug : chaque babet.exec() faisait temporairement
    -- sigaction(SIGPIPE, SIG_IGN). Deux exec concurrents pouvaient
    -- s'entrelacer ainsi : A sauve le handler, B sauve SIG_IGN,
    -- A restaure le handler, puis B restaure SIG_IGN définitivement.
    --
    -- Les deux shells sont bloqués par des fichiers de libération pour
    -- imposer exactement cet ordre, sans dépendre du scheduler.
    do
        local marker_a = sb("lot2_sigpipe_a_started")
        local marker_b = sb("lot2_sigpipe_b_started")
        local release_a = sb("lot2_sigpipe_a_release")
        local release_b = sb("lot2_sigpipe_b_release")

        local function wait_file(path, timeout)
            local deadline = babet.monotonic() + timeout
            while babet.monotonic() < deadline do
                local exists = babet.fileExists(path)
                if exists == true then return true end
                babet.sleep(10, "ms")
            end
            return false
        end

        local pipe_fired = false
        local handler_ok = babet.signal.handle("PIPE", function()
            pipe_fired = true
        end)
        ok("LOT 2 SIGPIPE: handler installé", handler_ok == true)

        local worker_code = [[
            local command = "printf x > " .. worker.args.marker
                .. "; while [ ! -e " .. worker.args.release
                .. " ]; do sleep 0.01; done"
            local result, err = babet.exec(
                "sh", { "-c", command }, { timeout = 5 })
            if not result then return { ok = false, err = err } end
            return { ok = result.code == 0, code = result.code }
        ]]

        local wa = W.spawn(worker_code,
            { marker = marker_a, release = release_a })
        local a_started = wa ~= nil and wait_file(marker_a, 2)
        ok("LOT 2 SIGPIPE: exec A actif", a_started)

        local wb
        local b_started = false
        if a_started then
            wb = W.spawn(worker_code,
                { marker = marker_b, release = release_b })
            b_started = wb ~= nil and wait_file(marker_b, 2)
        end
        ok("LOT 2 SIGPIPE: exec B actif pendant A", b_started)

        -- A se termine d'abord, puis B : ordre qui laissait SIGPIPE
        -- définitivement ignoré dans l'ancienne implémentation.
        babet.touch(release_a)
        local a_ok, a_result = false, nil
        if wa then a_ok, a_result = wa:join() end

        babet.touch(release_b)
        local b_ok, b_result = false, nil
        if wb then b_ok, b_result = wb:join() end

        ok("LOT 2 SIGPIPE: deux exec concurrents terminés",
            a_ok == true and type(a_result) == "table" and a_result.ok
            and b_ok == true and type(b_result) == "table" and b_result.ok)

        -- os.execute est utilisé volontairement : appeler babet.exec ici
        -- masquerait le bug historique en modifiant lui-même SIGPIPE.
        if handler_ok == true then
            os.execute("kill -PIPE " .. tostring(babet.pid()))

            -- Le module signal distribue les callbacks via un hook Lua.
            -- Cette boucle exécute assez d'instructions pour le déclencher.
            local dispatch_deadline = babet.monotonic() + 1
            while not pipe_fired
                and babet.monotonic() < dispatch_deadline do
                local accumulator = 0
                for i = 1, 20000 do accumulator = accumulator + i end
            end
        end

        ok("LOT 2 SIGPIPE: handler préservé après exec concurrents",
            handler_ok == true and pipe_fired == true)
        if handler_ok == true then
            babet.signal.handle("PIPE", nil)
        end
    end

    -- ----- poll after join : "already consumed" -------------------

    do
        local w = W.spawn("return 1")
        local jok, _ = w:join()
        ok("join initial OK", jok == true)
        local state, _ = w:poll()
        ok("poll after join: 'error' (already consumed)",
            state == "error")
        local jok2, _ = w:join()
        ok("join after join: (false, already consumed)",
            jok2 == false)
    end
    end
end
