> **English** | [Français](../../fr/modules/workers.md)

# `babet.workers` — parallel jobs

Run Lua code on real OS threads. Useful for I/O-bound work that
benefits from concurrency (fetching many URLs, scanning many
files, processing batches) and CPU-bound work on multi-core
hardware.

## Why

Lua has coroutines, but those run cooperatively on a single OS
thread — fine for state machines, not for using multiple cores.
And many tasks are I/O-bound : 100 HTTP requests that each take
500 ms still take 50 s sequentially, but ~500 ms in parallel.

`babet.workers` spawns real OS threads each running their own
isolated Lua state, communicating with the parent via passed-in
arguments and return values. No shared state means no locks,
no data races — just send work in, get results out.

## API

| Function | Returns |
| --- | --- |
| `babet.workers.spawn(code, args?, opts?)` | `job` (userdata) \| `(nil, err)` |
| `job:join()` | `(true, result)` \| `(false, err)` — **blocking**, see pitfall below |
| `job:poll()` | `string` — `"running"` \| `"done"` \| `"error"`, non-blocking |
| `job:send(v, timeout?)` | `(true)` \| `(false, err)` — into the worker's inbox |
| `job:recv(timeout?)` | `(true, v)` \| `(false, err)` — from the worker's outbox |
| `job:close()` | closes both queues ; unblocks worker and parent |

`opts` : `inbox_capacity` / `outbox_capacity` (integers, default
64) — message queue sizes.

`timeout` (seconds) for `send`/`recv` : omitted or `nil` = block
indefinitely ; `0` = non-blocking (`err == "full"` / `"empty"`) ;
otherwise bounded wait (`err == "timeout"`). A closed queue yields
`err == "closed"`. On the worker side, `worker.send(v, timeout?)`
and `worker.recv(timeout?)` are symmetrical.

**`join()` pitfall : possible deadlock.** `join()` waits for the
worker to finish, with no deadline. If the worker is blocked in a
`worker.recv()` without a timeout (waiting for a message that will
never come), `join()` never returns — parent and worker wait on
each other. Unlike the garbage collector (which closes the queues
before joining), `join()` closes nothing. Practical rules : call
`job:close()` before `join()` whenever the worker may be waiting
for a message ; or use finite timeouts in `worker.recv()` ; and
`job:poll()` to test without blocking.

### `code` argument

A Lua source string that runs in the worker. The full `babet`
namespace is available, plus a `worker` global with :

- `worker.args` — the second argument passed to `spawn`.
- `worker.send(v, timeout?)` / `worker.recv(timeout?)` — the
  message channel to/from the parent (same timeout conventions as
  the parent side, see table above).

The worker's last expression value (or `return value`) is what
`join()` returns as `result`.

### `args` argument

Any value that can be deep-copied between Lua states : `nil`,
booleans, numbers, strings, tables of the same. **Not** : functions,
userdata, threads, tables with cycles. Tables are deep-copied — no
sharing. Maximum depth : **32 nesting levels** (beyond :
`(nil, "workers: spawn: value too deeply nested")`). Same rules for
the worker's return value and for `send`/`recv` messages.

## Quick examples

### Parallel HTTP fetches

```lua
local urls = {
    "https://a.example/",
    "https://b.example/",
    "https://c.example/",
    "https://d.example/",
}

local jobs = {}
for i, url in ipairs(urls) do
    jobs[i] = babet.workers.spawn([[
        local url = worker.args.url
        local r, err = babet.http.get(url, { timeout = 10 })
        if not r then return { ok = false, err = err } end
        return { ok = true, status = r.status, length = #r.body }
    ]], { url = url })
end

for i, job in ipairs(jobs) do
    local ok, result = job:join()
    if ok then
        print(i, result.status or result.err)
    else
        print(i, "worker crashed:", result)
    end
end
```

### CPU-bound work with cancellation

Cancellation is **cooperative**, built on the message channel :
the parent sends `"stop"`, the worker checks its inbox
periodically with `worker.recv(0)` (non-blocking).

```lua
local jobs = {}
for i = 1, 4 do
    jobs[i] = babet.workers.spawn([[
        local chunk = worker.args.chunk
        local total = 0
        for x = chunk.from, chunk.to do
            if x % 1000 == 0 then
                local got, msg = worker.recv(0) -- non-blocking
                if got and msg == "stop" then
                    return { cancelled = true, partial = total }
                end
            end
            total = total + heavy_compute(x)
        end
        return { total = total }
    ]], { chunk = { from = i * 1000, to = (i + 1) * 1000 - 1 } })
end

-- ... later, if needed :
-- for _, j in ipairs(jobs) do j:send("stop") end
-- then join() to collect the partial results.
```

### Worker pool pattern

```lua
local function map_parallel(items, code, max_concurrent)
    -- no cpu_count() in v1 : pick a value, or detect :
    -- tonumber(babet.exec("nproc").stdout)
    max_concurrent = max_concurrent or 4
    local results = {}
    local i = 1
    local active = {}

    while i <= #items or next(active) do
        -- launch as many as we can
        while i <= #items and #active < max_concurrent do
            active[#active + 1] = {
                index = i,
                job = babet.workers.spawn(code, { item = items[i] }),
            }
            i = i + 1
        end
        -- harvest any finished
        for k = #active, 1, -1 do
            local entry = active[k]
            if entry.job:poll() ~= "running" then
                local ok, result = entry.job:join()
                results[entry.index] = ok and result or { err = result }
                table.remove(active, k)
            end
        end
        if next(active) then babet.sleep(10, "ms") end
    end
    return results
end
```

## Error contract

- **`spawn`** : `(nil, err)` if the OS thread can't be created
  (rare — usually resource limits).
- **`join`** :
  - `(true, result)` — worker completed normally ; `result` is
    its return value (or `nil` if it didn't return).
  - `(false, err)` — worker crashed with an uncaught error ;
    `err` is the error message + traceback.
  - `(false, "workers: join: result already consumed")` — `join`
    already called on this job.
  - `join()` has **no** timeout : it blocks until the worker ends
    (see the deadlock pitfall above).
- **Wrong argument types** → raises via `luaL_error`.

## Sharing data

Workers don't share Lua state. Communication is :

- **In** : via the `args` second argument to `spawn` (deep-copied
  into the worker's state).
- **Out** : via the worker's return value (deep-copied back).
- **Side effects** : a worker can write to a file, append to a
  log, query a database — but coordination through such side
  effects is the script's responsibility.

If two workers write to the same SQLite file, set `wal=true` on
`open` so they don't lock each other out. SQLite handles the
synchronisation correctly with WAL ; in `busy_timeout` you can
configure how long to wait on a busy db.

## Design decisions

- **One Lua state per worker, no sharing**. The alternative —
  shared state with locks — is a well-known source of subtle bugs
  and we don't think Lua-level locks are worth the design effort
  at this layer. Pure message-passing is simpler.
- **No global thread pool**. Each `spawn` creates a fresh OS
  thread, each `join` closes it. For tight loops, build a pool
  in Lua (see example above). The simpler model wins on
  legibility.
- **The first `spawn` locks `setenv` and `chdir`** — permanently,
  even after `join`. The environment and the working directory are
  process-wide state ; mutating them while a worker runs is a data
  race. Set them before the first worker. See the note in
  [sys](sys.md).
- **`babet.signal` is not available in workers**. Signals are
  process-wide ; only the main thread can sensibly own them.

## Not in v1

> Note (v21 audit) : the items below belong to the original design
> and are **not implemented today** — the previous version of this
> page wrongly presented them as available : `job:join(timeout)`,
> `job:done()` (use `job:poll()`), `job:cancel()` /
> `worker.cancelled()` (cooperative cancellation can be built today
> with `job:send("stop")` + a periodic `worker.recv(0)`), and
> `babet.workers.cpu_count()`.

- Channels **between workers** (worker↔worker — the
  parent↔worker channel already exists : `send`/`recv`). Add later if a use
  case shows the pattern is common.
- Shared memory (mmap). Same.
- Async I/O futures (`spawn().then(...)` style). Out of scope ;
  use a polling loop with `job:poll()`.
