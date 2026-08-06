return function(test, context)
    local _ENV = test:environment(context)
    local W = babet.workers
    -- ============================================================
    -- Babet 2.18 : cpu_count, job:done et pool borné persistant
    -- ============================================================
    do
        ok("workers.cpu_count is a function",
            type(W.cpu_count) == "function")
        ok("workers.pool is a function",
            type(W.pool) == "function")

        local cpu_count = W.cpu_count()
        ok("workers.cpu_count returns a positive integer",
            math.type(cpu_count) == "integer" and cpu_count >= 1,
            "count=" .. tostring(cpu_count))
        ok("workers.cpu_count rejects arguments",
            pcall(W.cpu_count, true) == false)

        do
            local job = assert(W.spawn(
                "babet.sleep(100, 'ms'); return 18"))
            ok("job:done() is false while the worker runs",
                job:done() == false)
            local joined, value = job:join(2)
            ok("job:done() becomes true without consuming status",
                joined == true and value == 18 and job:done() == true)
            ok("job:done rejects excess arguments",
                pcall(function() job:done(true) end) == false)
        end

        do
            local pool, pool_err = W.pool({ size = 2, queue_capacity = 2 })
            ok("workers.pool creates a fixed reusable pool",
                pool ~= nil and pool_err == nil, tostring(pool_err))
            if pool then
                local stats = assert(pool:stats())
                ok("pool:stats exposes fixed size and bounded capacity",
                    stats.size == 2 and stats.queue_capacity == 2
                    and stats.max_pending == 4 and stats.pending == 0
                    and stats.accepting == true)

                local first = assert(pool:submit(
                    "return worker.args.value * 2", { value = 21 }))
                local second = assert(pool:submit(
                    "return worker.args.left .. worker.args.right",
                    { left = "ba", right = "bet" }))
                local first_ok, first_value = first:join(2)
                local second_state, second_value = second:poll()
                if second_state == "running" then
                    local second_ok
                    second_ok, second_value = second:join(2)
                    second_state = second_ok and "done" or "error"
                end
                ok("pool tasks return independent results",
                    first_ok == true and first_value == 42
                    and second_state == "done" and second_value == "babet")
                ok("pool task result is consumed exactly once",
                    select(1, first:join(0)) == false)

                local failed = assert(pool:submit("error('pool-boom')"))
                local failed_ok, failed_error = failed:join(2)
                ok("pool task errors stay local to the task",
                    failed_ok == false and type(failed_error) == "string"
                    and failed_error:find("pool%-boom") ~= nil,
                    tostring(failed_error))

                local close_ok, close_err = pool:close(2)
                local joined_ok, joined_err = pool:join(2)
                ok("pool closes and joins all persistent workers",
                    close_ok == true and close_err == nil
                    and joined_ok == true and joined_err == nil,
                    tostring(close_err or joined_err))
                local after_close, after_close_err =
                    pool:submit("return true", nil, 0)
                ok("pool rejects submissions after close",
                    after_close == nil and after_close_err == "closed")
            end
        end

        do
            local pool = assert(W.pool({ size = 1, queue_capacity = 1 }))
            local before = assert(pool:stats())
            local invariant_held = false

            -- Force a deterministic send failure after submit() has made the
            -- task visible. This verifies the internal invariant during the
            -- send itself, not only the final public state.
            pool._send_message = function(self, message, deadline, allow_done)
                invariant_held = self._tasks_by_id[message.id] ~= nil
                    and self._pending == 1
                return false, "synthetic-send-failure"
            end

            local rejected, reject_reason = pool:submit("return 1", nil, 0)
            pool._send_message = nil
            local after = assert(pool:stats())
            local following = assert(pool:submit("return 73"))
            local following_ok, following_value = following:join(2)

            ok("pool submit keeps registry/pending invariant and rolls back send failures",
                invariant_held == true
                and rejected == nil
                and reject_reason == "synthetic-send-failure"
                and before.pending == 0 and after.pending == 0
                and before.accepting == true and after.accepting == true
                and next(pool._tasks_by_id) == nil
                and following_ok == true and following_value == 73,
                tostring(reject_reason or following_value))
            assert(pool:join(2))
        end

        do
            local pool = assert(W.pool({ size = 1, queue_capacity = 2 }))
            local set_global = assert(pool:submit(
                "pool_leak = 99; return pool_leak"))
            local read_global = assert(pool:submit(
                "return pool_leak"))
            local set_ok, set_value = set_global:join(2)
            local read_ok, read_value = read_global:join(2)
            ok("pool gives every task a fresh global environment",
                set_ok == true and set_value == 99
                and read_ok == true and read_value == nil)

            local mark_state = assert(pool:submit([[
                package.loaded.__babet_pool_reuse = 41
                return true
            ]]))
            local read_state = assert(pool:submit([[
                local value = package.loaded.__babet_pool_reuse
                package.loaded.__babet_pool_reuse = nil
                return value + 1
            ]]))
            local mark_ok = select(1, mark_state:join(2))
            local reuse_ok, reuse_value = read_state:join(2)
            ok("pool reuses the Lua state of a persistent worker",
                mark_ok == true and reuse_ok == true and reuse_value == 42)
            assert(pool:join(2))
        end

        do
            local events = assert(W.channel({ capacity = 2 }))
            local pool = assert(W.pool({
                size = 1,
                queue_capacity = 1,
                channels = { events = events },
            }))
            local task = assert(pool:submit([[
                assert(worker.channels.events:send(worker.args))
                return "sent"
            ]], { source = "pool" }))
            local received, message = events:recv(2)
            local task_ok, task_value = task:join(2)
            ok("pool tasks receive explicitly shared channels",
                received == true and type(message) == "table"
                and message.source == "pool"
                and task_ok == true and task_value == "sent")
            assert(pool:join(2))
            events:close()
        end

        do
            local pool = assert(W.pool({ size = 1, queue_capacity = 1 }))
            local first = assert(pool:submit(
                "babet.sleep(250, 'ms'); return 1"))
            local second = assert(pool:submit(
                "babet.sleep(250, 'ms'); return 2"))
            local third, third_err = pool:submit("return 3", nil, 0)
            ok("pool bounds queued plus running tasks",
                third == nil and third_err == "timeout",
                tostring(third_err))
            local timeout_ok, timeout_err = first:join(0)
            ok("pool task join supports a non-blocking timeout",
                timeout_ok == nil and timeout_err == "timeout")
            local first_ok, first_value = first:join(2)
            local second_ok, second_value = second:join(2)
            ok("bounded tasks complete after backpressure",
                first_ok == true and first_value == 1
                and second_ok == true and second_value == 2)
            assert(pool:join(2))
        end

        do
            local pool = assert(W.pool({ size = 1, queue_capacity = 1 }))
            local task = assert(pool:submit(
                "babet.sleep(150, 'ms'); return 'retry-ok'"))
            local first_join, first_reason = pool:join(0)
            local second_join, second_reason = pool:join(2)
            local task_ok, task_value = task:join(0)
            ok("pool join timeout is retryable without double consumption",
                first_join == nil and first_reason == "timeout"
                and second_join == true and second_reason == nil
                and task_ok == true and task_value == "retry-ok",
                tostring(first_reason or second_reason or task_value))
        end

        do
            local pool = assert(W.pool({ size = 1, queue_capacity = 1 }))
            local bad_result = assert(pool:submit("return function() end"))
            local result_ok, result_err = bad_result:join(2)
            ok("pool converts an unserializable task result into task error",
                result_ok == false and type(result_err) == "string"
                and result_err:find("serialization", 1, true) ~= nil,
                tostring(result_err))
            assert(pool:join(2))
        end

        do
            local pool = assert(W.pool({ size = 1, queue_capacity = 1 }))
            local task = assert(pool:submit([[
                while not worker.cancelled() do
                    babet.sleep(10, "ms")
                end
                return "cancelled"
            ]]))
            local cancel_ok, cancel_err = pool:cancel()
            local task_ok, task_err = task:join(0)
            local join_ok, join_err = pool:join(2)
            ok("pool cancellation is cooperative and wakes persistent workers",
                cancel_ok == true and cancel_err == nil
                and task_ok == false and task_err == "cancelled"
                and join_ok == true and join_err == nil,
                tostring(task_err or join_err))
        end

        ok("workers.pool rejects non-table options",
            pcall(W.pool, 42) == false)
        ok("workers.pool rejects unknown options",
            pcall(W.pool, { threads = 2 }) == false)
        ok("workers.pool rejects invalid size",
            pcall(W.pool, { size = 0 }) == false)
        ok("workers.pool rejects invalid queue capacity",
            pcall(W.pool, { queue_capacity = 0 }) == false)
        ok("workers.pool rejects reserved channel names",
            pcall(W.pool, { channels = {
                __babet_pool_tasks = assert(W.channel()),
            } }) == false)
    end
end
