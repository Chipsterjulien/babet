> **English** | [Français](../../fr/modules/workers.md)

# WORKERS — OS threads, isolated Lua states, and message queues

`babet.workers` executes Lua code in real POSIX threads. Each worker owns a
separate `lua_State`, receives a serialized copy of its initial arguments, and
communicates with the parent through two bounded message queues.

The module covers:

- starting a Lua chunk in an OS thread;
- passing an initial argument table;
- blocking or non-blocking retrieval of the first return value;
- a parent-to-worker inbox and a worker-to-parent outbox;
- timeouts and capacity-based backpressure;
- cooperative channel closing;
- loading Babet, bundled, and user modules in each state;
- Lua-memory isolation between threads.

It does not provide shared Lua memory, forced termination, a timeout for
`join()`, a global pool, or direct worker-to-worker channels.

## Module contents

- [Essential conventions](#workers-conventions)
- [API overview](#workers-api-summary)
- [`spawn(code, args?, opts?)`](#workers-spawn)
  - [`code`](#workers-code)
  - [`args` and `worker.args`](#workers-args)
  - [Queue capacities](#workers-capacities)
  - [When `setenv` and `chdir` become locked](#workers-process-lock)
- [Transferable values](#workers-transfer)
  - [Scalars and strings](#workers-transfer-scalars)
  - [List and object tables](#workers-transfer-tables)
  - [Rejected values](#workers-transfer-rejected)
  - [Copies, identity, and depth](#workers-transfer-copy)
- [Final worker result](#workers-result)
  - [`join()` — wait and consume](#workers-join)
  - [`poll()` — check and consume](#workers-poll)
  - [Do not call `join()` after completed `poll()`](#workers-consumption)
- [Parent-to-worker messages](#workers-parent-send)
- [Worker-to-parent messages](#workers-parent-recv)
- [`worker.send` and `worker.recv`](#workers-worker-side)
- [Timeouts and failure reasons](#workers-timeouts)
- [`close()` and queue lifecycle](#workers-close)
- [Module loading and worker environment](#workers-state)
- [Complete examples](#workers-examples)
  - [Simple calculation with `join`](#workers-example-join)
  - [Structured arguments](#workers-example-args)
  - [Non-blocking progress with `poll`](#workers-example-poll)
  - [Persistent request/response worker](#workers-example-service)
  - [Sending and receiving `nil`](#workers-example-nil)
  - [Close, then drain the outbox](#workers-example-drain)
  - [Backpressure and timeout](#workers-example-backpressure)
  - [Cooperative cancellation](#workers-example-cancel)
  - [Correct bounded pool](#workers-example-pool)
- [Deadlocks to avoid](#workers-deadlocks)
- [Error contract](#workers-errors)
- [Garbage collection and destruction](#workers-gc)
- [Signals, environment, and concurrency](#workers-concurrency)
- [Features not provided](#workers-not-provided)

<a id="workers-conventions"></a>
## Essential conventions

### Each worker owns a separate Lua state

A table, global, or module changed in the parent is not shared with a worker.
Data crosses state boundaries only through serialization:

- `args` during `spawn`;
- `job:send` and `worker.recv`;
- `worker.send` and `job:recv`;
- the chunk's first return value.

There can therefore be no data race on Lua objects themselves. External side
effects — files, sockets, databases, and processes — remain system resources
and must still be coordinated by the application.

### Results use a `pcall`-like convention

`join()` returns:

```lua
true, business_value
false, error_message
```

This lets a worker legitimately return `nil`:

```lua
local ok, value = job:join()
if ok then
    -- value may be nil.
else
    io.stderr:write(value, "\n")
end
```

Queue methods also return a boolean first, so a `nil` message is unambiguous.

### The final result can be consumed once

As soon as `join()` retrieves the result, or `poll()` returns `"done"` or
`"error"`, that result is consumed. A later `join()` or `poll()` reports
`result already consumed`.

<a id="workers-api-summary"></a>
## API overview

### Parent side

```lua
local job, err = babet.workers.spawn(code, args?, opts?)

local ok, value = job:join()
local state, value = job:poll()

local ok, err = job:send(value, timeout?)
local ok, value_or_err = job:recv(timeout?)
local ok, err = job:close()
```

| API | Main result | Blocking |
| --- | --- | --- |
| `spawn` | `job` or `(nil, err)` | creation only |
| `job:join()` | `(true, result)` or `(false, err)` | yes, no timeout |
| `job:poll()` | `("running", nil)`, `("done", result)`, or `("error", err)` | no |
| `job:send(v, t?)` | `(true, nil)`, `(false, reason)`, or `(nil, err)` | depends on `t` |
| `job:recv(t?)` | `(true, value)` or `(false, reason)` | depends on `t` |
| `job:close()` | `(true, nil)` | no |

### Worker side

The chunk receives a global `worker` table:

```lua
worker.args
worker.send(value, timeout?)
worker.recv(timeout?)
```

| API | Result |
| --- | --- |
| `worker.args` | copy of `args`, or `nil` |
| `worker.send(v, t?)` | `(true, nil)` or `(false, reason_or_error)` |
| `worker.recv(t?)` | `(true, value)` or `(false, reason)` |

<a id="workers-spawn"></a>
## `spawn(code, args?, opts?)`

```lua
local job, err = babet.workers.spawn(code, args?, opts?)
```

On success, `spawn` returns only the `job` userdata. The thread may still be
running, may already have completed, or may already have failed by the time the
parent receives the userdata.

Chunk load or runtime errors occur **inside** the worker: `spawn` may succeed,
then `join()` or `poll()` reports the error.

```lua
local job = assert(babet.workers.spawn("this is not valid Lua"))
local ok, err = job:join()
assert(not ok)
```

<a id="workers-code"></a>
### `code`

`code` is required and must be an actual Lua string. Numbers are not coerced.

```lua
local job = assert(babet.workers.spawn([[
    return 6 * 7
]]))
```

The source is loaded as a text chunk in a fresh state. It is not a closure that
captures parent upvalues.

```lua
local factor = 3

-- factor does not exist in the worker: pass it through args.
local job = assert(babet.workers.spawn([[
    return worker.args.value * worker.args.factor
]], {
    value = 14,
    factor = factor,
}))
```

The binding does not truncate NUL bytes in `code`, but a NUL normally makes the
source invalid for the Lua parser. Use ordinary Lua source text.

<a id="workers-args"></a>
### `args` and `worker.args`

`args` is optional. It must be a table or `nil`.

```lua
local job = assert(babet.workers.spawn([[
    return worker.args.left + worker.args.right
]], {
    left = 20,
    right = 22,
}))
```

Inside the worker:

- `worker.args` contains a deserialized copy of the table;
- without `args`, `worker.args == nil`;
- modifying `worker.args` never changes the parent's table;
- metatables and subtable identity do not cross the boundary.

A direct scalar is not accepted as the second argument:

```lua
babet.workers.spawn("return worker.args", 42) -- raises a Lua error
```

Wrap it in a table:

```lua
babet.workers.spawn("return worker.args.value", { value = 42 })
```

<a id="workers-capacities"></a>
### Queue capacities

`opts` can define:

```lua
{
    inbox_capacity = 64,
    outbox_capacity = 64,
}
```

- `inbox_capacity`: maximum queued parent-to-worker messages;
- `outbox_capacity`: maximum queued worker-to-parent messages;
- default: 64 messages for each queue;
- allowed range: integer from `1` to `1,000,000`;
- the value must be an actual Lua number, not the string `"64"`;
- capacity counts **messages**, not bytes.

```lua
local job = assert(babet.workers.spawn(code, nil, {
    inbox_capacity = 8,
    outbox_capacity = 32,
}))
```

A larger capacity may consume more memory and does not replace a draining
strategy. A small capacity applies backpressure earlier.

Unknown `opts` fields are currently ignored.

<a id="workers-process-lock"></a>
### When `setenv` and `chdir` become locked

After validating types and capacities, the first `spawn` marks the process as
having used workers. From then on:

- `babet.setenv(...)` is permanently rejected;
- `babet.chdir(...)` is permanently rejected;
- the restriction remains after `join()`;
- it remains even if `args` serialization, queue initialization, or
  `pthread_create` later fails.

A call rejected **before** this mark — for example `spawn(42)` or a non-integer
capacity — does not lock the environment.

Configure the current directory and environment before the first worker.

<a id="workers-transfer"></a>
## Transferable values

The internal transport format is JSON. The same rules apply to:

- `args`;
- messages in either direction;
- the worker's first return value.

<a id="workers-transfer-scalars"></a>
### Scalars and strings

| Lua value | Transferable | Note |
| --- | --- | --- |
| `nil` | yes | becomes JSON `null`, then `nil` again |
| boolean | yes | identity preserved |
| integer | yes | normally restored as a Lua integer |
| finite floating-point number | yes | `NaN`, `+Inf`, and `-Inf` rejected |
| text string | yes | must pass the UTF-8 validator and contain no NUL |

Unlike several filesystem and socket APIs, worker messages are **not
binary-safe**. A string containing `\0` or bytes rejected by the UTF-8 validator
cannot be transferred.

<a id="workers-transfer-tables"></a>
### List and object tables

A table is transferable in one of two shapes.

#### Non-empty dense list

```lua
{ "a", "b", "c" }
```

All keys must be consecutive integers `1..n`, with no holes and no other key.

#### String-keyed object

```lua
{
    name = "alice",
    age = 30,
}
```

All keys must be strings accepted by the text validator.

An empty table is serialized as an **empty object** `{}`, not an empty array.
There is no equivalent of `babet.json.empty_array` in the worker transport.

Sparse or mixed tables are rejected:

```lua
{ [1] = "a", [3] = "c" }      -- hole
{ [1] = "a", label = "x" }   -- list + map
{ [0] = "zero" }              -- numeric key outside 1..n
```

<a id="workers-transfer-rejected"></a>
### Rejected values

These values do not cross Lua states:

- functions and closures;
- userdata: socket, SQLite statement, watcher, job, file, and so on;
- Lua coroutines/threads;
- cyclic tables;
- sparse or mixed tables;
- non-string keys in object tables;
- `NaN` or infinite numbers;
- strings with NUL or bytes rejected as UTF-8;
- structures beyond the nesting limit.

Pass a path, URL, or serializable configuration instead of the system object
itself. The worker then opens its own resource.

```lua
-- Wrong: socket is userdata.
babet.workers.spawn(code, { socket = peer })

-- Correct: pass connection parameters.
babet.workers.spawn(code, {
    host = "127.0.0.1",
    port = 9000,
})
```

<a id="workers-transfer-copy"></a>
### Copies, identity, and depth

Transport copies values:

- no Lua reference is shared;
- metatables are lost;
- two references to the same subtable become two separate tables;
- cycles are rejected;
- maximum nesting is 32 levels according to the internal serialization
  counter.

```lua
local shared = { value = 1 }
local args = { a = shared, b = shared }

-- In the worker, worker.args.a and worker.args.b have equal content,
-- but are not the same table.
```

The limit protects the C++ and Lua stacks from pathological structures.

<a id="workers-result"></a>
## Final worker result

When the chunk completes normally, only its **first** return value is
serialized.

```lua
return "first", "second", "third"
```

The parent receives only `"first"`.

Return a table to transport several fields:

```lua
return {
    value = 42,
    elapsed = 0.12,
}
```

With no `return`, or `return nil`, the business result is `nil`.

An uncaught Lua error becomes the `error` state. The transferred text is a
useful diagnostic, but Babet does not automatically add a traceback. A worker
can use `xpcall(..., debug.traceback)` when it wants to build one.

<a id="workers-join"></a>
### `join()` — wait and consume

```lua
local ok, value = job:join()
```

`join()`:

- waits without a timeout for the pthread to finish;
- does not close either queue before waiting;
- permanently consumes the result;
- returns `(true, value)` after normal completion;
- returns `(false, err)` for Lua errors, internal errors, or invalid results.

```lua
local ok, value = job:join()
if ok then
    print("result", value)
else
    io.stderr:write("worker: ", value, "\n")
end
```

Even when the result is `nil`, success remains identifiable through
`ok == true`.

<a id="workers-poll"></a>
### `poll()` — check and consume

```lua
local state, value = job:poll()
```

| `state` | `value` | Consumed |
| --- | --- | --- |
| `"running"` | `nil` | no |
| `"done"` | result, possibly `nil` | yes |
| `"error"` | message | yes |

```lua
while true do
    local state, value = job:poll()
    if state == "running" then
        babet.sleep(10, "ms")
    elseif state == "done" then
        print("completed", value)
        break
    else
        io.stderr:write("worker: ", value, "\n")
        break
    end
end
```

Once the state is no longer `running`, `poll()` quickly joins the already
completed pthread and consumes the result.

<a id="workers-consumption"></a>
### Do not call `join()` after completed `poll()`

This sequence is wrong:

```lua
local state = job:poll()
if state ~= "running" then
    local ok, result = job:join() -- result already consumed
end
```

Use both values from `poll()` directly:

```lua
local state, value = job:poll()
if state == "done" then
    use_result(value)
elseif state == "error" then
    report_error(value)
end
```

Alternatively, use `poll()` only while it returns `running`, and design another
mechanism that tells code when to call `join()` without first consuming the
result. In most event loops, polling through the final result is simpler.

<a id="workers-parent-send"></a>
## Parent-to-worker messages

```lua
local ok, err = job:send(value, timeout?)
```

`job:send` serializes `value`, then appends it to the worker inbox in FIFO
order.

Results:

- `(true, nil)`: message accepted;
- `(false, "full")`: full queue with timeout `0`;
- `(false, "timeout")`: queue stayed full until the deadline;
- `(false, "closed")`: inbox closed;
- `(nil, err)`: non-transferable value or internal serialization failure.

```lua
local ok, err = job:send({ command = "scan", path = "/tmp" }, 1)
if not ok then
    io.stderr:write("send: ", err, "\n")
end
```

Success means the message entered the queue, not that the worker has already
processed it.

<a id="workers-parent-recv"></a>
## Worker-to-parent messages

```lua
local ok, value_or_err = job:recv(timeout?)
```

`job:recv` removes the oldest message from the outbox.

Results:

- `(true, value)`: message received; `value` may be `nil`;
- `(false, "empty")`: empty queue with timeout `0`;
- `(false, "timeout")`: no message before the deadline;
- `(false, "closed")`: queue closed and fully drained.

When a queue is closed but still contains messages, those messages are
returned before `"closed"`.

```lua
while true do
    local ok, message = job:recv(0)
    if ok then
        process(message)
    elseif message == "empty" then
        break
    elseif message == "closed" then
        break
    else
        error(message)
    end
end
```

<a id="workers-worker-side"></a>
## `worker.send` and `worker.recv`

Inside the chunk:

```lua
local ok, message_or_err = worker.recv(timeout?)
local ok, err = worker.send(value, timeout?)
```

`worker.recv` reads the inbox filled by `job:send`. `worker.send` writes the
outbox read by `job:recv`.

FIFO ordering, capacities, timeouts, and closing are symmetric.

Serialization-error convention differs slightly:

- `job:send` returns `(nil, err)`;
- `worker.send` returns `(false, err)`.

This keeps a boolean status convention inside worker code.

```lua
local job = assert(babet.workers.spawn([[
    while true do
        local ok, message = worker.recv()
        if not ok then
            return "inbox closed"
        end

        local sent, err = worker.send({ echo = message })
        if not sent then
            return { send_error = err }
        end
    end
]]))
```

<a id="workers-timeouts"></a>
## Timeouts and failure reasons

All four message methods share the same contract:

| Lua `timeout` | Behavior |
| --- | --- |
| omitted or `nil` | wait indefinitely |
| `0` | immediate, non-blocking attempt |
| `0 < t <= 86400` | wait at most `t` seconds |
| negative, NaN, Inf, or `> 86400` | raises a Lua error |
| other type, including `"1"` | raises a Lua error |

Internal resolution is one millisecond. A strictly positive duration is rounded
up: `0.0005` second waits at least 1 ms and is not turned into non-blocking
mode.

Queue reasons are:

| Reason | Meaning |
| --- | --- |
| `"full"` | immediate send, queue full |
| `"empty"` | immediate receive, queue empty |
| `"timeout"` | positive deadline reached |
| `"closed"` | send to closed queue, or receive from closed and empty queue |

Internal diagnostics such as `"out of memory"` or `"internal mutex error"` may
exceptionally appear instead.

<a id="workers-close"></a>
## `close()` and queue lifecycle

```lua
local ok, err = job:close()
```

`job:close()`:

- closes only the parent-to-worker **inbox**;
- is idempotent;
- returns `(true, nil)`;
- wakes a waiting `worker.recv()`, which gets `(false, "closed")` once already
  queued messages are drained;
- makes future `job:send()` calls fail with `(false, "closed")`;
- leaves the outbox open so the parent can still receive final worker messages.

It does not forcibly terminate the thread and does not consume its final
result.

The worker automatically closes **both** queues when it completes, whether
successfully or with an error. The parent can still drain messages already in
the outbox before receiving `"closed"`.

To cleanly finish a worker that waits for commands:

```lua
assert(job:close())
local ok, result = job:join()
```

The worker must treat `worker.recv() == false, "closed"` as an exit condition.

<a id="workers-state"></a>
## Module loading and worker environment

Each thread creates a fresh Lua state and:

- opens the standard Lua libraries;
- registers the complete `babet` namespace;
- exposes bundled modules through `require`;
- configures user-module loading like the parent project, in directory or
  embedded mode;
- exposes `worker.args`, `worker.send`, and `worker.recv`;
- does not copy the parent's global `arg` table: `arg == nil` in the worker.

```lua
local job = assert(babet.workers.spawn([[
    local inspect = require("inspect")
    local mymod = require("mymod")
    return inspect({ answer = mymod.answer() })
]]))
```

Lua states are isolated, but threads belong to the same process:

- same PID;
- same process-wide current directory;
- same process-wide environment;
- same filesystem and accessible external resources;
- Lua memory measured separately in each state.

Babet rejects cwd and environment mutations after the first `spawn`, stabilizing
those two global states.

<a id="workers-examples"></a>
## Complete examples

<a id="workers-example-join"></a>
### Simple calculation with `join`

```lua
local job, err = babet.workers.spawn([[
    return 21 * 2
]])
assert(job, err)

local ok, result = job:join()
assert(ok, result)
print(result) -- 42
```

<a id="workers-example-args"></a>
### Structured arguments

```lua
local job = assert(babet.workers.spawn([[
    local total = 0
    for _, value in ipairs(worker.args.values) do
        total = total + value
    end
    return {
        name = worker.args.name,
        total = total,
    }
]], {
    name = "batch A",
    values = { 10, 20, 12 },
}))

local ok, result = job:join()
assert(ok, result)
print(result.name, result.total)
```

<a id="workers-example-poll"></a>
### Non-blocking progress with `poll`

```lua
local job = assert(babet.workers.spawn([[
    babet.sleep(200, "ms")
    return "ready"
]]))

while true do
    local state, value = job:poll()

    if state == "running" then
        update_ui()
        babet.sleep(10, "ms")
    elseif state == "done" then
        print(value)
        break
    else
        error(value)
    end
end
```

Do not call `join()` after the `done` or `error` branch: `poll()` has already
consumed the result.

<a id="workers-example-service"></a>
### Persistent request/response worker

```lua
local job = assert(babet.workers.spawn([[
    while true do
        local ok, request = worker.recv()
        if not ok then
            return "parent closed inbox"
        end

        if request.op == "stop" then
            return "stopped"
        elseif request.op == "square" then
            local sent, err = worker.send({
                id = request.id,
                value = request.value * request.value,
            })
            if not sent then
                return { error = err }
            end
        end
    end
]], nil, {
    inbox_capacity = 16,
    outbox_capacity = 16,
}))

for i = 1, 5 do
    assert(job:send({ id = i, op = "square", value = i }))
end

for _ = 1, 5 do
    local ok, response = job:recv(2)
    assert(ok, response)
    print(response.id, response.value)
end

assert(job:send({ op = "stop" }))
local ok, result = job:join()
assert(ok, result)
print(result)
```

<a id="workers-example-nil"></a>
### Sending and receiving `nil`

The status boolean distinguishes a real `nil` message from an empty queue.

```lua
local job = assert(babet.workers.spawn([[
    local ok, value = worker.recv()
    assert(ok)
    assert(value == nil)

    assert(worker.send(nil))
    return "done"
]]))

assert(job:send(nil))

local got, value = job:recv()
assert(got == true)
assert(value == nil)

local ok, result = job:join()
assert(ok and result == "done")
```

<a id="workers-example-drain"></a>
### Close, then drain the outbox

```lua
local job = assert(babet.workers.spawn([[
    assert(worker.send("ready"))

    local ok, reason = worker.recv()
    assert(not ok and reason == "closed")

    assert(worker.send("closing"))
    return "finished"
]]))

local ok, first = job:recv(1)
assert(ok and first == "ready")

assert(job:close()) -- closes the inbox only

local got, last = job:recv(1)
assert(got and last == "closing")

local joined, result = job:join()
assert(joined and result == "finished")
```

<a id="workers-example-backpressure"></a>
### Backpressure and timeout

```lua
local job = assert(babet.workers.spawn([[
    babet.sleep(500, "ms")
    while true do
        local ok, message = worker.recv()
        if not ok then return "closed" end
        if message == "stop" then return "done" end
    end
]], nil, {
    inbox_capacity = 2,
}))

assert(job:send("one", 0))
assert(job:send("two", 0))

local ok, reason = job:send("three", 0)
assert(ok == false and reason == "full")

local waited, why = job:send("three", 0.1)
assert(waited == false and why == "timeout")

job:close()
job:join()
```

<a id="workers-example-cancel"></a>
### Cooperative cancellation

There is no `job:cancel()`. The parent sends a command and the worker checks it
periodically.

```lua
local job = assert(babet.workers.spawn([[
    local total = 0

    for i = 1, worker.args.limit do
        total = total + expensive_step(i)

        if i % 1000 == 0 then
            local ok, message = worker.recv(0)
            if ok and message == "stop" then
                return {
                    cancelled = true,
                    partial = total,
                }
            elseif not ok and message == "closed" then
                return {
                    cancelled = true,
                    partial = total,
                }
            end
        end
    end

    return { cancelled = false, total = total }
]], { limit = 1000000 }))

-- Later:
local sent, err = job:send("stop", 0.5)
if not sent then
    io.stderr:write("cancel: ", err, "\n")
end

local ok, result = job:join()
assert(ok, result)
```

Cancellation remains cooperative: a worker stuck in a non-interruptible call,
or one that never checks its queue, does not stop because of this message.

<a id="workers-example-pool"></a>
### Correct bounded pool

This loop bounds simultaneous pthreads and directly uses the `poll()` result,
without calling `join()` afterward.

```lua
local function map_parallel(items, code, max_concurrent)
    max_concurrent = max_concurrent or 4

    local next_index = 1
    local active = {}
    local results = {}

    while next_index <= #items or #active > 0 do
        while next_index <= #items and #active < max_concurrent do
            local job, err = babet.workers.spawn(code, {
                item = items[next_index],
            })
            assert(job, err)

            active[#active + 1] = {
                index = next_index,
                job = job,
            }
            next_index = next_index + 1
        end

        for i = #active, 1, -1 do
            local entry = active[i]
            local state, value = entry.job:poll()

            if state == "done" then
                results[entry.index] = value
                table.remove(active, i)
            elseif state == "error" then
                results[entry.index] = { error = value }
                table.remove(active, i)
            end
        end

        if #active > 0 then
            babet.sleep(10, "ms")
        end
    end

    return results
end
```

Every `spawn` still creates a new thread and Lua state. This pattern bounds
concurrency; it does not reuse persistent workers.

<a id="workers-deadlocks"></a>
## Deadlocks to avoid

### Worker waits for inbox while parent calls `join()`

```lua
-- Worker
local ok, message = worker.recv() -- waits indefinitely

-- Parent
job:join() -- waits for worker
```

Both sides wait. Close the inbox or send a command first:

```lua
job:close()
job:join()
```

### Worker blocks on a full outbox

If the worker calls `worker.send()` with no timeout, the outbox is full, and
the parent calls `join()` without draining it, neither side can progress.

Solutions:

- parent regularly calls `job:recv()`;
- worker uses a finite timeout;
- outbox capacity matches the protocol;
- message and join phases are clearly separated.

### Forgetting that `poll()` consumes

Code that waits for `poll() ~= "running"` and then calls `join()` does not
deadlock, but loses the real result and gets `already consumed`. Use both
values from `poll()`.

### Potentially blocking GC

Dropping the last reference to an active worker can run `__gc`, which closes
queues and then waits for the thread. Queue waits are released, but GC cannot
interrupt infinite computation or an unbounded external syscall.

<a id="workers-errors"></a>
## Error contract

### Lua errors raised for invalid use

These include:

- missing or non-string `code`;
- `args` other than table or `nil`;
- `opts` other than table or `nil`;
- non-numeric, non-integer, or out-of-range capacities;
- non-numeric, negative, non-finite, or greater-than-86,400-second timeout;
- method call on a value that is not a job.

```lua
local ok, err = pcall(function()
    babet.workers.spawn(42)
end)
assert(not ok)
```

### Failures returned by `spawn`

`spawn` returns `(nil, err)` for runtime failures before or during creation:

- non-transferable `args`;
- JSON serialization failure;
- queue initialization failure;
- `pthread_create` failure.

```lua
local job, err = babet.workers.spawn("return 1", {
    fn = function() end,
})
assert(job == nil)
```

### Final worker errors

`join()` returns `(false, err)` and `poll()` returns `("error", err)` for:

- invalid Lua syntax;
- uncaught Lua error;
- non-transferable return value;
- caught internal C++ exception;
- internal result deserialization corruption or failure.

The diagnostic does not automatically contain a complete traceback.

### Message serialization

- `job:send`: `(nil, err)` when the value cannot be serialized;
- `worker.send`: `(false, err)` for the same case;
- `recv`: `(false, err)` on an internal deserialization anomaly.

<a id="workers-gc"></a>
## Garbage collection and destruction

The userdata has a safety-net `__gc`. When collected:

1. inbox and outbox are closed;
2. queue waiters are awakened;
3. Babet calls `pthread_join` when needed;
4. pthread primitives and internal strings are destroyed.

This prevents freeing state still used by a thread. It can nevertheless block
when the worker cannot terminate.

Do not use GC as the normal synchronization mechanism. Keep the job, finish
the protocol, then call `join()` or consume the result through `poll()`.

`tostring(job)` returns an indication such as:

```text
Worker(running)
Worker(done)
Worker(error)
```

This reflects instantaneous internal status, not whether the result has
already been consumed.

<a id="workers-concurrency"></a>
## Signals, environment, and concurrency

### Signals

All six signals managed by `babet.signal` are blocked in worker pthreads.
`babet.signal.handle`, `ignore`, and `default` raise inside a worker. The main
thread remains the only owner of POSIX callbacks.

### Environment and cwd

`setenv` and `chdir` change process-wide state that cannot safely be mutated
while other threads use it. Babet therefore rejects both after the first
`spawn`.

### External resources

Two workers can open distinct files, SQLite databases, or sockets. When they
target the same external resource, worker serialization provides no automatic
lock.

For SQLite, each worker should open its own connection. `wal = true` and a
suitable `busy_timeout` can improve concurrency, but do not replace sound
transaction design.

### Cost

Each `spawn` creates:

- a pthread;
- a complete Lua state;
- Babet modules;
- two queues and their buffers;
- JSON copies of transferred data.

Avoid a worker for tiny operations. Batch work or use a few persistent workers
when the protocol allows it.

<a id="workers-not-provided"></a>
## Features not provided

The module currently does not provide:

- `job:join(timeout)`;
- `job:cancel()` or forced termination;
- `worker.cancelled()`;
- `job:done()` — use `poll()`;
- `babet.workers.cpu_count()`;
- a reusable global pool;
- direct worker-to-worker channels;
- shared Lua memory;
- transfer of functions, userdata, or coroutines;
- a binary message format;
- automatic transfer of multiple return values.

Cooperative cancellation and a bounded pool can be built in Lua using the
examples on this page. CPU count can be queried through an external program
such as `babet.exec("nproc")`, after checking its result table.
