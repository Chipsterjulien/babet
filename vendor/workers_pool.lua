-- workers_pool.lua — pool borné de workers persistants pour Babet.
--
-- Ce module n'est pas exposé par require(). Il est embarqué dans le binaire et
-- appelé par register_workers() pour installer babet.workers.pool(). Le pool
-- réutilise les primitives natives workers.spawn() et workers.channel() : les
-- pthreads et leurs états Lua restent vivants entre plusieurs tâches.

return function(workers, babet)
    local MAX_CAPACITY = 1000000
    local MAX_TIMEOUT = 86400
    local WAIT_SLICE = 0.05
    local INTERNAL_TASKS = "__babet_pool_tasks"
    local INTERNAL_RESULTS = "__babet_pool_results"

    local function arity_error(name, expected)
        error(name .. ": expected " .. expected, 3)
    end

    local function strict_integer(value, name, minimum, maximum)
        if type(value) ~= "number" or math.type(value) ~= "integer" then
            error(name .. " must be an integer", 3)
        end
        if value < minimum or value > maximum then
            error(string.format(
                "%s must be between %d and %d", name, minimum, maximum), 3)
        end
        return value
    end

    local function strict_timeout(value, name)
        if value == nil then
            return nil
        end
        if type(value) ~= "number" or value ~= value
            or value == math.huge or value == -math.huge then
            error(name .. " must be a finite number", 3)
        end
        if value < 0 or value > MAX_TIMEOUT then
            error(name .. " must be between 0 and 86400 seconds", 3)
        end
        return value
    end

    local function monotonic()
        local now, err = babet.monotonic()
        if now == nil then
            error("workers.pool: monotonic clock failed: " .. tostring(err), 3)
        end
        return now
    end

    local function make_deadline(timeout)
        if timeout == nil then
            return nil
        end
        return monotonic() + timeout
    end

    local function remaining(deadline)
        if deadline == nil then
            return nil
        end
        local value = deadline - monotonic()
        if value <= 0 then
            return 0
        end
        return value
    end

    local function slice_timeout(deadline)
        local left = remaining(deadline)
        if left == nil or left > WAIT_SLICE then
            return WAIT_SLICE
        end
        return left
    end

    local POOL_WORKER_CODE = [=[
local tasks = assert(worker.channels.__babet_pool_tasks)
local results = assert(worker.channels.__babet_pool_results)
local public_channels = {}

local function safe_text(value)
    local ok, text = pcall(tostring, value)
    if ok then
        return text
    end
    return "<non-string worker error>"
end

for name, channel in pairs(worker.channels) do
    if name ~= "__babet_pool_tasks"
        and name ~= "__babet_pool_results" then
        public_channels[name] = channel
    end
end

while true do
    local received, message = tasks:recv()
    if not received then
        if message == "closed" or message == "cancelled" then
            return message
        end
        error("workers.pool: task channel receive failed: " .. tostring(message))
    end

    if message.kind == "stop" then
        return true
    end

    local task_channels = {}
    for name, channel in next, public_channels do
        task_channels[name] = channel
    end
    local task_worker = {
        args = message.args,
        channels = task_channels,
        cancelled = worker.cancelled,
    }
    local environment = { worker = task_worker }
    environment._G = environment
    setmetatable(environment, { __index = _G })

    local chunk, load_error = load(
        message.code,
        "pool-task-" .. tostring(message.id),
        "t",
        environment)

    local response
    if chunk == nil then
        response = {
            id = message.id,
            ok = false,
            error = safe_text(load_error),
        }
    else
        local succeeded, value = pcall(chunk)
        if succeeded then
            response = {
                id = message.id,
                ok = true,
                value = value,
            }
        else
            response = {
                id = message.id,
                ok = false,
                error = safe_text(value),
            }
        end
    end

    local sent, send_reason = results:send(response)
    if sent == nil then
        sent, send_reason = results:send({
            id = message.id,
            ok = false,
            error = "workers.pool: task result serialization failed: "
                .. safe_text(send_reason),
        })
    end
    if not sent then
        if send_reason == "closed" or send_reason == "cancelled" then
            return send_reason
        end
        error("workers.pool: result channel send failed: "
            .. safe_text(send_reason))
    end
end
]=]

    local pool_methods = {}
    local task_methods = {}
    local pool_meta = { __index = pool_methods }
    local task_meta = { __index = task_methods }

    local function check_pool(self, method)
        if getmetatable(self) ~= pool_meta then
            error("workers.pool." .. method .. ": invalid pool", 3)
        end
        return self
    end

    local function check_task(self, method)
        if getmetatable(self) ~= task_meta then
            error("workers.pool.task." .. method .. ": invalid task", 3)
        end
        return self
    end

    function pool_methods:_fail_pending(reason)
        for _, task in pairs(self._tasks_by_id) do
            if task._state == "running" then
                task._state = "error"
                task._value = reason
            end
        end
        self._tasks_by_id = {}
        self._pending = 0
    end

    function pool_methods:_break(reason)
        if self._broken == nil then
            self._broken = reason
        end
        self._accepting = false
        self:_fail_pending(self._broken)
        self._tasks:close()
        for _, job in ipairs(self._workers) do
            job:cancel()
        end
        return nil, self._broken
    end

    function pool_methods:_check_workers(allow_done)
        local running = 0
        local done = 0
        for index, job in ipairs(self._workers) do
            local status = job:status()
            if status == "error" then
                local _, detail = job:poll()
                self._worker_joined[index] = true
                return self:_break(string.format(
                    "workers.pool: worker %d failed: %s",
                    index, tostring(detail)))
            end
            if status == "running" then
                running = running + 1
            elseif status == "done" then
                done = done + 1
                if not allow_done then
                    local _, detail = job:poll()
                    self._worker_joined[index] = true
                    return self:_break(string.format(
                        "workers.pool: worker %d exited unexpectedly: %s",
                        index, tostring(detail)))
                end
            end
        end

        -- Hors annulation, un worker ne doit terminer qu'après avoir reçu
        -- l'un des marqueurs stop déjà envoyés par close(). Cette borne
        -- distingue une sortie normale d'un retour prématuré du loop interne.
        if allow_done and not self._cancelled and done > self._stops_sent then
            return self:_break(
                "workers.pool: a worker exited before its stop marker")
        end
        return true, running
    end

    function pool_methods:_apply_result(message)
        if type(message) ~= "table" or math.type(message.id) ~= "integer"
            or type(message.ok) ~= "boolean" then
            return self:_break("workers.pool: malformed result message")
        end

        local task = self._tasks_by_id[message.id]
        if task == nil then
            -- Un résultat peut arriver après cancel(), quand les tâches ont
            -- déjà été marquées localement. Il est alors volontairement jeté.
            return true
        end

        self._tasks_by_id[message.id] = nil
        self._pending = self._pending - 1
        if message.ok then
            task._state = "done"
            task._value = message.value
        else
            task._state = "error"
            task._value = tostring(message.error)
        end
        return true
    end

    function pool_methods:_collect_one(deadline, allow_done)
        while true do
            if self._broken ~= nil then
                return nil, self._broken
            end

            local healthy, running_or_error = self:_check_workers(allow_done)
            if not healthy then
                return nil, running_or_error
            end

            -- Si tous les workers ont fini, les derniers résultats peuvent
            -- encore être déjà en file. On effectue donc un dernier recv(0)
            -- avant de déclarer une perte de résultat.
            local timeout = running_or_error == 0 and 0
                or slice_timeout(deadline)
            local received, message = self._results:recv(timeout)
            if received then
                local applied, apply_error = self:_apply_result(message)
                if not applied then
                    return nil, apply_error
                end
                return true
            end

            if message == "timeout" or message == "empty" then
                if running_or_error == 0 and self._pending > 0 then
                    return self:_break(
                        "workers.pool: all workers exited with pending tasks")
                end
                if deadline ~= nil and remaining(deadline) == 0 then
                    return false, "timeout"
                end
            elseif message == "closed" then
                if self._pending == 0 then
                    return false, "closed"
                end
                return self:_break(
                    "workers.pool: result channel closed with pending tasks")
            else
                return self:_break(
                    "workers.pool: result receive failed: " .. tostring(message))
            end
        end
    end

    function pool_methods:_drain_ready()
        if self._broken ~= nil then
            return nil, self._broken
        end
        while self._pending > 0 do
            local received, message = self._results:recv(0)
            if received then
                local applied, apply_error = self:_apply_result(message)
                if not applied then
                    return nil, apply_error
                end
            elseif message == "empty" or message == "timeout" then
                break
            elseif message == "closed" then
                return self:_break(
                    "workers.pool: result channel closed with pending tasks")
            else
                return self:_break(
                    "workers.pool: result receive failed: " .. tostring(message))
            end
        end
        local healthy, running_or_error = self:_check_workers(
            self._closing or self._cancelled or self._stops_sent > 0)
        if not healthy then
            return nil, running_or_error
        end
        if self._pending > 0 and running_or_error == 0 then
            return self:_break(
                "workers.pool: all workers exited with pending tasks")
        end
        return true
    end

    function pool_methods:_send_message(message, deadline, allow_done)
        while true do
            if self._broken ~= nil then
                return nil, self._broken
            end

            local healthy, running_or_error = self:_check_workers(allow_done)
            if not healthy then
                return nil, running_or_error
            end
            if allow_done and running_or_error == 0 then
                return self:_break(
                    "workers.pool: no worker remains to receive a stop marker")
            end

            local timeout = slice_timeout(deadline)
            local sent, reason = self._tasks:send(message, timeout)
            if sent then
                return true
            end
            if reason == "timeout" or reason == "full" then
                local drained, drain_error = self:_drain_ready()
                if not drained then
                    return nil, drain_error
                end
                if deadline ~= nil and remaining(deadline) == 0 then
                    return false, "timeout"
                end
            elseif reason == "closed" or reason == "cancelled" then
                return false, reason
            else
                return nil, "workers.pool: task send failed: "
                    .. tostring(reason)
            end
        end
    end

    function pool_methods:submit(code, args, timeout, ...)
        check_pool(self, "submit")
        if select("#", ...) > 0 then
            arity_error("workers.pool.submit", "self, code, optional args and timeout")
        end
        if type(code) ~= "string" then
            error("workers.pool.submit: code must be a string", 2)
        end
        if args ~= nil and type(args) ~= "table" then
            error("workers.pool.submit: args must be a table or nil", 2)
        end
        timeout = strict_timeout(timeout, "workers.pool.submit: timeout")

        if not self._accepting then
            return nil, self._broken or "closed"
        end

        local deadline = make_deadline(timeout)
        local drained, drain_error = self:_drain_ready()
        if not drained then
            return nil, drain_error
        end

        while self._pending >= self._max_pending do
            local collected, reason = self:_collect_one(deadline, false)
            if not collected then
                return nil, reason
            end
        end

        local id = self._next_id
        self._next_id = id + 1
        local task = setmetatable({
            _pool = self,
            _id = id,
            _state = "running",
            _value = nil,
            _consumed = false,
        }, task_meta)

        -- Keep the registry and pending counter in lockstep even while
        -- _send_message() drains results or checks worker health. A failed
        -- send rolls both changes back together. _break() may already have
        -- cleared the registry through _fail_pending(), hence the identity
        -- check before decrementing.
        self._tasks_by_id[id] = task
        self._pending = self._pending + 1
        local sent, reason = self:_send_message({
            kind = "task",
            id = id,
            code = code,
            args = args,
        }, deadline, false)
        if not sent then
            if self._tasks_by_id[id] == task then
                self._tasks_by_id[id] = nil
                self._pending = self._pending - 1
            end
            return nil, reason
        end

        return task, nil
    end

    function pool_methods:close(timeout, ...)
        check_pool(self, "close")
        if select("#", ...) > 0 then
            arity_error("workers.pool.close", "self and an optional timeout")
        end
        timeout = strict_timeout(timeout, "workers.pool.close: timeout")

        if self._cancelled then
            return false, "cancelled"
        end
        if self._broken ~= nil then
            return false, self._broken
        end
        if self._stops_sent == self._size then
            self._closing = true
            self._accepting = false
            return true, nil
        end

        self._accepting = false
        local deadline = make_deadline(timeout)
        while self._stops_sent < self._size do
            local sent, reason = self:_send_message(
                { kind = "stop" }, deadline, true)
            if not sent then
                return false, reason
            end
            self._stops_sent = self._stops_sent + 1
        end
        self._closing = true
        return true, nil
    end

    function pool_methods:cancel(...)
        check_pool(self, "cancel")
        if select("#", ...) > 0 then
            arity_error("workers.pool.cancel", "only self")
        end
        if self._cancelled then
            return true, nil
        end

        self._accepting = false
        self._cancelled = true
        self._closing = true
        self._tasks:close()
        self:_fail_pending("cancelled")
        for _, job in ipairs(self._workers) do
            job:cancel()
        end
        return true, nil
    end

    function pool_methods:join(timeout, ...)
        check_pool(self, "join")
        if select("#", ...) > 0 then
            arity_error("workers.pool.join", "self and an optional timeout")
        end
        timeout = strict_timeout(timeout, "workers.pool.join: timeout")

        if self._joined then
            return false, "workers.pool: already joined"
        end

        local deadline = make_deadline(timeout)
        -- _break() ferme la file de travail et annule déjà les workers. Même
        -- dans cet état, join() doit rejoindre les pthreads au lieu de
        -- retourner immédiatement et de déléguer le nettoyage au futur __gc.
        if self._broken == nil then
            if not self._closing and not self._cancelled then
                local closed, close_reason = self:close(remaining(deadline))
                if not closed then
                    if close_reason == "timeout" then
                        return nil, "timeout"
                    end
                    return false, close_reason
                end
            elseif not self._cancelled and self._stops_sent < self._size then
                local closed, close_reason = self:close(remaining(deadline))
                if not closed then
                    if close_reason == "timeout" then
                        return nil, "timeout"
                    end
                    return false, close_reason
                end
            end
        end

        while self._pending > 0 do
            local collected, reason = self:_collect_one(deadline, true)
            if not collected then
                if reason == "timeout" then
                    return nil, "timeout"
                end
                return false, reason
            end
        end

        for index, job in ipairs(self._workers) do
            if not self._worker_joined[index] then
                local ok, result = job:join(remaining(deadline))
                if ok == nil then
                    -- Les workers déjà joints restent mémorisés. Un nouvel
                    -- appel reprend au premier pthread encore actif sans
                    -- tenter de consommer une seconde fois leurs résultats.
                    return nil, "timeout"
                end
                self._worker_joined[index] = true
                if not ok and self._join_error == nil then
                    self._join_error = string.format(
                        "workers.pool: worker %d failed: %s",
                        index, tostring(result))
                end
            end
        end

        self._results:close()
        self._joined = true
        if self._join_error ~= nil then
            self._broken = self._broken or self._join_error
        end
        if self._broken ~= nil then
            return false, self._broken
        end
        return true, nil
    end

    function pool_methods:stats(...)
        check_pool(self, "stats")
        if select("#", ...) > 0 then
            arity_error("workers.pool.stats", "only self")
        end
        local drained, drain_error = self:_drain_ready()
        if not drained then
            return nil, drain_error
        end
        return {
            size = self._size,
            queue_capacity = self._queue_capacity,
            max_pending = self._max_pending,
            pending = self._pending,
            accepting = self._accepting,
            closing = self._closing,
            cancelled = self._cancelled,
            joined = self._joined,
        }, nil
    end

    function task_methods:done(...)
        check_task(self, "done")
        if select("#", ...) > 0 then
            arity_error("workers.pool.task.done", "only self")
        end
        if self._state == "running" then
            local ok, err = self._pool:_drain_ready()
            if not ok then
                self._state = "error"
                self._value = err
            end
        end
        return self._state ~= "running"
    end

    function task_methods:status(...)
        check_task(self, "status")
        if select("#", ...) > 0 then
            arity_error("workers.pool.task.status", "only self")
        end
        self:done()
        return self._state
    end

    local function consume_task(task)
        if task._consumed then
            return false, "workers.pool: task result already consumed"
        end
        task._consumed = true
        if task._state == "done" then
            return true, task._value
        end
        return false, task._value
    end

    function task_methods:poll(...)
        check_task(self, "poll")
        if select("#", ...) > 0 then
            arity_error("workers.pool.task.poll", "only self")
        end
        if self._consumed then
            return "error", "workers.pool: task result already consumed"
        end
        if not self:done() then
            return "running", nil
        end
        local ok, value = consume_task(self)
        return ok and "done" or "error", value
    end

    function task_methods:join(timeout, ...)
        check_task(self, "join")
        if select("#", ...) > 0 then
            arity_error("workers.pool.task.join", "self and an optional timeout")
        end
        timeout = strict_timeout(timeout, "workers.pool.task.join: timeout")
        if self._consumed then
            return false, "workers.pool: task result already consumed"
        end

        local deadline = make_deadline(timeout)
        while self._state == "running" do
            local collected, reason = self._pool:_collect_one(
                deadline, self._pool._closing or self._pool._cancelled
                    or self._pool._stops_sent > 0)
            if not collected then
                if reason == "timeout" then
                    return nil, "timeout"
                end
                self._state = "error"
                self._value = reason
                break
            end
        end
        return consume_task(self)
    end

    function pool_meta:__tostring()
        return string.format(
            "WorkerPool(size=%d,pending=%d,%s)",
            self._size,
            self._pending,
            self._joined and "joined"
                or (self._accepting and "open" or "closed"))
    end

    function task_meta:__tostring()
        return string.format(
            "WorkerPoolTask(id=%d,status=%s)", self._id, self._state)
    end

    local function create_pool(opts, ...)
        if select("#", ...) > 0 then
            arity_error("workers.pool", "zero or one options table")
        end
        if opts ~= nil and type(opts) ~= "table" then
            error("workers.pool: opts must be a table or nil", 2)
        end
        opts = opts or {}

        for name in next, opts do
            if type(name) ~= "string" then
                error("workers.pool: option names must be strings", 2)
            end
            if name ~= "size" and name ~= "queue_capacity"
                and name ~= "channels" then
                error("workers.pool: unknown option '" .. name .. "'", 2)
            end
        end

        local size = rawget(opts, "size")
        if size == nil then
            size = math.min(workers.cpu_count(), 1024)
        else
            size = strict_integer(size, "workers.pool: opts.size", 1, 1024)
        end

        local queue_capacity = rawget(opts, "queue_capacity")
        if queue_capacity == nil then
            queue_capacity = math.max(64, size * 4)
            if queue_capacity > MAX_CAPACITY then
                queue_capacity = MAX_CAPACITY
            end
        else
            queue_capacity = strict_integer(
                queue_capacity,
                "workers.pool: opts.queue_capacity",
                1,
                MAX_CAPACITY)
        end

        local user_channels = rawget(opts, "channels")
        if user_channels ~= nil and type(user_channels) ~= "table" then
            error("workers.pool: opts.channels must be a table or nil", 2)
        end

        local max_pending = queue_capacity + size
        if max_pending > MAX_CAPACITY then
            max_pending = MAX_CAPACITY
        end
        local tasks, task_error = workers.channel({ capacity = queue_capacity })
        if not tasks then
            return nil, task_error
        end
        local results, result_error = workers.channel({ capacity = max_pending })
        if not results then
            tasks:close()
            return nil, result_error
        end

        local channels = {
            [INTERNAL_TASKS] = tasks,
            [INTERNAL_RESULTS] = results,
        }
        if user_channels ~= nil then
            for name, channel in next, user_channels do
                if type(name) ~= "string" or name == "" then
                    error("workers.pool: channel names must be non-empty strings", 2)
                end
                if name == INTERNAL_TASKS or name == INTERNAL_RESULTS then
                    error("workers.pool: reserved channel name '" .. name .. "'", 2)
                end
                channels[name] = channel
            end
        end

        local pool = setmetatable({
            _size = size,
            _queue_capacity = queue_capacity,
            _max_pending = max_pending,
            _tasks = tasks,
            _results = results,
            _workers = {},
            _worker_joined = {},
            _join_error = nil,
            _tasks_by_id = {},
            _next_id = 1,
            _pending = 0,
            _stops_sent = 0,
            _accepting = true,
            _closing = false,
            _cancelled = false,
            _joined = false,
            _broken = nil,
        }, pool_meta)

        for index = 1, size do
            local call_ok, job, spawn_error = pcall(
                workers.spawn,
                POOL_WORKER_CODE,
                nil,
                {
                    inbox_capacity = 1,
                    outbox_capacity = 1,
                    channels = channels,
                })
            if not call_ok then
                spawn_error = job
                job = nil
            end
            if job == nil then
                pool:_break(string.format(
                    "workers.pool: failed to start worker %d: %s",
                    index, tostring(spawn_error)))
                for _, started in ipairs(pool._workers) do
                    started:join(2)
                end
                results:close()
                return nil, pool._broken
            end
            pool._workers[index] = job
        end

        return pool, nil
    end

    workers.pool = create_pool
end
