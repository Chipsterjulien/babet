> **English** | [Français](../../fr/modules/workers.md)

# WORKERS — OS threads, isolated Lua states, queues, and channels

`babet.workers` executes Lua code in real POSIX threads. Each worker owns a
separate `lua_State`, receives a serialized copy of its initial arguments, and
communicates with the parent through two bounded message queues. Shared
channels can also connect the parent and several workers, or workers directly,
without relaying messages through the parent's inbox/outbox.

The module covers:

- starting a Lua chunk in an OS thread;
- passing an initial argument table;
- blocking or non-blocking retrieval of the first return value;
- a parent-to-worker inbox and a worker-to-parent outbox;
- direct bounded FIFO multi-producer/multi-consumer channels;
- timeouts and capacity-based backpressure;
- closing with drainage and wake-up of blocked calls;
- loading Babet, bundled, and user modules in each state;
- Lua-memory isolation between threads;
- a bounded pool of persistent workers that reuses pthreads and Lua states
  across several tasks.

It does not provide shared Lua memory, forced termination, or channels between
distinct OS processes. Available cancellation is strictly cooperative.

## Module contents

- [Essential conventions](#workers-conventions)
- [API overview](#workers-api-summary)
- [`spawn(code, args?, opts?)`](#workers-spawn)
  - [`code`](#workers-code)
  - [`args` and `worker.args`](#workers-args)
  - [Queue capacities](#workers-capacities)
  - [Passing channels through `opts.channels`](#workers-spawn-channels)
  - [When `setenv` and `chdir` become locked](#workers-process-lock)
- [Transferable values](#workers-transfer)
  - [Scalars and strings](#workers-transfer-scalars)
  - [List and object tables](#workers-transfer-tables)
  - [Rejected values](#workers-transfer-rejected)
  - [Copies, identity, depth, and budgets](#workers-transfer-copy)
- [Final worker result](#workers-result)
  - [`status()` — observe without consuming](#workers-status)
  - [`done()` — non-consuming boolean test](#workers-done)
  - [`join(timeout?)` — wait and consume](#workers-join)
  - [`poll()` — check and consume](#workers-poll)
  - [Do not call `join()` after completed `poll()`](#workers-consumption)
- [Parent-to-worker messages](#workers-parent-send)
- [Worker-to-parent messages](#workers-parent-recv)
- [`worker.send`, `worker.recv`, and `worker.cancelled`](#workers-worker-side)
- [Direct shared channels](#workers-channels)
  - [Creating a channel and choosing capacity](#workers-channel-create)
  - [`send` and `recv`](#workers-channel-send-recv)
  - [`close` and `is_closed`](#workers-channel-close)
  - [Concurrency, ordering, and lifetime](#workers-channel-lifetime)
- [Timeouts and failure reasons](#workers-timeouts)
- [`close()` and queue lifecycle](#workers-close)
- [`cancel()` and cooperative cancellation](#workers-cancel)
- [Module loading and worker environment](#workers-state)
- [Available CPU count](#workers-cpu-count)
- [Reusable bounded pool](#workers-pool)
  - [Creation and options](#workers-pool-create)
  - [Submission and tasks](#workers-pool-submit)
  - [State isolation and reuse](#workers-pool-isolation)
  - [Backpressure and timeouts](#workers-pool-backpressure)
  - [Close, cancellation, and join](#workers-pool-lifecycle)
  - [Shared channels in tasks](#workers-pool-channels)
- [Complete examples](#workers-examples)
  - [Simple calculation with `join`](#workers-example-join)
  - [Structured arguments](#workers-example-args)
  - [Non-blocking progress with `poll`](#workers-example-poll)
  - [Persistent request/response worker](#workers-example-service)
  - [Sending and receiving `nil`](#workers-example-nil)
  - [Close, then drain the outbox](#workers-example-drain)
  - [Backpressure and timeout](#workers-example-backpressure)
  - [Parent to worker through a channel](#workers-example-channel-parent-worker)
  - [Worker to worker without parent relay](#workers-example-channel-worker-worker)
  - [Multiple producers and consumers](#workers-example-channel-mpmc)
  - [Cooperative cancellation](#workers-example-cancel)
  - [Native pool for many tasks](#workers-example-pool)
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
- shared channel `send` and `recv` methods;
- the chunk's first return value.

There can therefore be no data race on Lua objects themselves. External side
effects — files, sockets, databases, and processes — remain system resources
and must still be coordinated by the application.

### Results use a `pcall`-like convention

`join(timeout?)` returns:

```lua
true, business_value
false, error_message
nil, "timeout"
```

The third state only means the worker is still active. The result is neither
joined nor consumed.

This lets a worker legitimately return `nil`:

```lua
local ok, value = job:join(0.5)
if ok == true then
    -- value may be nil.
elseif ok == false then
    io.stderr:write(value, "\n")
else
    assert(value == "timeout")
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
local channel, err = babet.workers.channel(opts?)
local cpu_count = babet.workers.cpu_count()
local pool, err = babet.workers.pool(opts?)

local state = job:status()
local finished = job:done()
local ok, value_or_reason = job:join(timeout?)
local state, value = job:poll()
local ok, err = job:cancel()

local ok, err = job:send(value, timeout?)
local ok, value_or_err = job:recv(timeout?)
local ok, err = job:close()

local ok, err = channel:send(value, timeout?)
local ok, value_or_reason = channel:recv(timeout?)
local ok, err = channel:close()
local closed = channel:is_closed()
```

| API | Main result | Blocking |
| --- | --- | --- |
| `spawn` | `job` or `(nil, err)` | creation only |
| `job:status()` | `"running"`, `"done"`, or `"error"` | no, never consumes |
| `job:done()` | boolean | no, never consumes |
| `job:join(t?)` | `(true, result)`, `(false, err)`, or `(nil, "timeout")` | depends on `t` |
| `job:poll()` | `("running", nil)`, `("done", result)`, or `("error", err)` | no |
| `job:cancel()` | `(true, nil)` | no |
| `job:send(v, t?)` | `(true, nil)`, `(false, reason)`, or `(nil, err)` | depends on `t` |
| `job:recv(t?)` | `(true, value)` or `(false, reason)` | depends on `t` |
| `job:close()` | `(true, nil)` | no |
| `workers.channel(opts?)` | `channel` or `(nil, err)` | creation only |
| `channel:send(v, t?)` | `(true, nil)`, `(false, reason)`, or `(nil, err)` | depends on `t` |
| `channel:recv(t?)` | `(true, value)`, `(false, reason)`, or `(nil, err)` | depends on `t` |
| `channel:close()` | `(true, nil)` | no |
| `channel:is_closed()` | boolean | no |
| `workers.cpu_count()` | positive integer | no |
| `workers.pool(opts?)` | `pool` or `(nil, err)` | creates persistent workers |
| `pool:submit(code, args?, t?)` | `task` or `(nil, reason)` | depends on `t` |
| `task:done()` | boolean | no, never consumes |
| `task:status()` | `"running"`, `"done"`, or `"error"` | no |
| `task:join(t?)` | `(true, result)`, `(false, err)`, or `(nil, "timeout")` | depends on `t` |
| `task:poll()` | `("running", nil)`, `("done", result)`, or `("error", err)` | no |
| `pool:close(t?)` | `(true, nil)` or `(false, reason)` | depends on `t` |
| `pool:cancel()` | `(true, nil)` | no; cooperative cancellation |
| `pool:join(t?)` | `(true, nil)`, `(false, err)`, or `(nil, "timeout")` | depends on `t` |
| `pool:stats()` | `(table, nil)` or `(nil, err)` | no |

### Worker side

The chunk receives a global `worker` table:

```lua
worker.args
worker.channels
worker.send(value, timeout?)
worker.recv(timeout?)
worker.cancelled()
```

| API | Result |
| --- | --- |
| `worker.args` | copy of `args`, or `nil` |
| `worker.channels` | table of handles passed through `opts.channels` |
| `worker.send(v, t?)` | `(true, nil)` or `(false, reason_or_error)` |
| `worker.recv(t?)` | `(true, value)` or `(false, reason)` |
| `worker.cancelled()` | boolean, no side effect |

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
- metatables and subtable identity do not cross the boundary;
- serialization reads raw entries and invokes neither `__len` nor `__index`.

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
- the value must be an actual Lua integer; the string `"64"` and the floating-point value `64.0` are rejected;
- capacity counts **messages**, not bytes.

```lua
local job = assert(babet.workers.spawn(code, nil, {
    inbox_capacity = 8,
    outbox_capacity = 32,
}))
```

Every unknown `opts` key raises a Lua error, catching typos immediately:

```lua
babet.workers.spawn("return 1", nil, {
    inbox_capcity = 16, -- error: unknown option
})
```

Option names must be real strings with no hidden NUL suffix; numeric keys are
also rejected.

A larger capacity may consume more memory and does not replace a draining
strategy. A small capacity applies backpressure earlier.


<a id="workers-spawn-channels"></a>
### Passing channels through `opts.channels`

A channel is a special shared resource. It never crosses the JSON
serialization used for `worker.args` and cannot be sent as a message. Pass it
explicitly through the `channels` field:

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
local results = assert(babet.workers.channel({ capacity = 16 }))

local job = assert(babet.workers.spawn([[
    local ok, task = worker.channels.tasks:recv(2)
    if not ok then return task end

    assert(worker.channels.results:send({
        id = task.id,
        result = task.value * 2,
    }, 2))

    return true
]], nil, {
    channels = {
        tasks = tasks,
        results = results,
    },
}))
```

In the new Lua state:

- `worker.channels` always exists and is an empty table when no channel was
  passed;
- each `opts.channels` key becomes a field of `worker.channels`;
- several names may reference the same channel;
- the parent and all workers hold distinct userdata pointing to the same C++
  queue;
- names must be non-empty UTF-8 strings containing no NUL;
- every value must be a channel created by `babet.workers.channel()`.

A channel placed in `args` remains non-serializable userdata and is rejected.

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
- messages sent through channels;
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
- userdata: channel, socket, SQLite statement, watcher, job, file, and so on;
- the SQLite-only lightuserdata sentinel `babet.sqlite.NULL`;
- Lua coroutines/threads;
- cyclic tables;
- sparse or mixed tables;
- non-string keys in object tables;
- `NaN` or infinite numbers;
- strings with NUL or bytes rejected as UTF-8;
- structures beyond the depth, node, or byte budgets.

Pass a path, URL, or serializable configuration instead of the system object
itself. The worker then opens its own resource.

The NULL sentinel is rejected with a diagnostic that explicitly names
`babet.sqlite.NULL`. Translate it to a domain value such as
`{ kind = "sql-null" }` if that intent must cross a worker or channel boundary.

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
### Copies, identity, depth, and budgets

Transport copies values:

- no Lua reference is shared;
- metatables are lost;
- two references to the same subtable become two separate tables;
- cycles are rejected;
- maximum nesting is 32 levels according to the internal serialization
  counter;
- one operation may expand to at most **1,000,000 JSON values**;
- the estimated representation must remain within a conservative **64 MiB**
  budget.

```lua
local shared = { value = 1 }
local args = { a = shared, b = shared }

-- In the worker, worker.args.a and worker.args.b have equal content,
-- but are not the same table.
```

The depth limit protects the C++ and Lua stacks. The two additional budgets
prevent a small Lua structure from expanding into an exponential amount of
data when the same subtable or string is referenced repeatedly.

Every expanded value consumes exactly one node and a fixed cost of 32 bytes.
Every string occurrence, including an object key, also consumes an upper bound
of `6 × byte_length + 2`. The factor of six covers the worst JSON escaping of a
control byte. The two ceilings deliberately overlap: together they bound both
the number of objects in the JSON DOM and the expanded text payload.

The limits apply independently to each operation: `spawn` arguments, final
result, `job:send`, `worker.send`, or `channel:send`. A rejected value is not
added to the queue. The identical receive-side check validates message
consistency; the primary memory bound is applied by the sender before strings
are copied and before the internal JSON is published.

These ceilings are part of the public contract. Lowering them in a later
release could reject transfers that used to succeed and should be announced as
an incompatible change.

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

<a id="workers-status"></a>
### `status()` — observe without consuming

```lua
local state = job:status()
```

`status()` returns exactly one of these strings:

| State | Meaning |
| --- | --- |
| `"running"` | the chunk or its cleanup is still running |
| `"done"` | the worker completed normally |
| `"error"` | the worker completed with an error |

The method does not block, join the pthread, or consume the result. It remains
usable before and after `join()`:

```lua
while job:status() == "running" do
    update_interface()
    babet.sleep(10, "ms")
end

local ok, result = job:join()
assert(ok, result)
assert(job:status() == "done")
```

`status()` intentionally does not expose a separate cancelling state: until the
chunk ends, it remains `"running"`.

<a id="workers-done"></a>
### `done()` — non-consuming boolean test

```lua
if job:done() then
    print("the worker has finished")
end
```

`done()` returns `false` while the internal status is `"running"`, then `true`
for both `"done"` and `"error"`. It does not join the pthread, deserialize the
result, or consume it. It is suitable for event loops that only need to know
whether a final `join()` or `poll()` can now be attempted.

<a id="workers-join"></a>
### `join(timeout?)` — wait and consume

```lua
local ok, value_or_reason = job:join(timeout?)
```

The timeout uses the same seconds contract as message queues:

- omitted or `nil`: wait indefinitely;
- `0`: immediate test;
- finite positive number up to `86400`: bounded wait;
- negative value, NaN, infinity, numeric string, or an extra argument: raises a
  Lua error.

There are three return states:

```lua
true, result       -- normal completion, result consumed
false, err         -- failed completion, error consumed
nil, "timeout"     -- worker still active, nothing consumed
```

Retry after an expiry:

```lua
local ok, value = job:join(0.05)

if ok == nil then
    assert(value == "timeout")
    print("worker is still running")

    -- The same job remains fully usable.
    ok, value = job:join(2)
end

if ok then
    print("result", value)
else
    io.stderr:write("worker: ", value, "\n")
end
```

A timeout:

- closes no queue;
- requests no cancellation;
- does not join the pthread;
- consumes neither result nor error;
- still allows `status`, `send`, `recv`, `close`, `cancel`, and another `join`.

The timeout bounds only this call to `join()`. If the worker remains active and
its last reference is later collected, notably while the Lua state is closing,
its `__gc` must still perform an unbounded `pthread_join()` and can therefore
block program termination.

Even when the worker legitimately returns `nil`, success is distinguishable by
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
- `(false, "cancelled")`: cancellation requested through `cancel()`;
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
## `worker.send`, `worker.recv`, and `worker.cancelled`

Inside the chunk:

```lua
local ok, message_or_err = worker.recv(timeout?)
local ok, err = worker.send(value, timeout?)
local cancelled = worker.cancelled()
```

`worker.recv` reads the inbox filled by `job:send`. `worker.send` writes the
outbox read by `job:recv`. `worker.cancelled()` reads, without blocking, the
flag set by `job:cancel()`.

After cancellation:

- `worker.cancelled()` returns `true`;
- the next `worker.recv()` returns `(false, "cancelled")` and no longer
  delivers commands still waiting in the inbox; when cancellation becomes
  visible immediately after a successful queue pop, that extracted command is
  deliberately discarded rather than delivered after the protocol boundary;
  a command already returned to Lua may naturally still be processing;
- `worker.send()` remains available for a final result, diagnostic, or stop
  acknowledgement when the outbox already has space; a send blocked on a full
  outbox is awakened and returns `(false, "cancelled")`;
- the chunk decides when and how to finish.

FIFO ordering, capacities, timeouts, and closing remain symmetric outside this
cancellation case.

Serialization-error convention differs slightly:

- `job:send` returns `(nil, err)`;
- `worker.send` returns `(false, err)`.

This keeps a boolean status convention inside worker code.

```lua
local job = assert(babet.workers.spawn([[
    while not worker.cancelled() do
        local ok, message = worker.recv(0.2)

        if ok then
            process(message)
        elseif message == "cancelled" then
            break
        elseif message ~= "timeout" then
            return { error = message }
        end
    end

    worker.send({ stopped = true })
    return "cancelled"
]]))
```


<a id="workers-channels"></a>
## Direct shared channels

A channel is a bounded queue shared by the parent and any number of workers.
Unlike a job inbox or outbox, it is not owned by one worker: every handle for
the same channel may produce or consume messages.

Channels are thread-safe, bounded by message count, multi-producer,
multi-consumer, FIFO by effective insertion order, and explicitly closed with
draining of already queued messages.

<a id="workers-channel-create"></a>
### Creating a channel and choosing capacity

```lua
local channel, err = babet.workers.channel(opts?)
```

The only option is `capacity`, which defaults to 64 messages and must be a
strict Lua integer between 1 and 1,000,000. Capacity counts messages, not bytes.

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
```

Unknown options, non-string keys, names containing NUL, and out-of-range
capacities raise a Lua error. Allocation or initialization failures return
`(nil, err)`.

<a id="workers-channel-send-recv"></a>
### `send` and `recv`

```lua
local ok, err = channel:send(value, timeout?)
local ok, value_or_reason = channel:recv(timeout?)
```

`send` returns `(true, nil)`,
`(false, "full"|"timeout"|"closed"|"cancelled")`, or `(nil, err)` when
serialization or an internal operation fails.

`recv` returns `(true, value)`,
`(false, "empty"|"timeout"|"closed"|"cancelled")`, or `(nil, err)` for an
internal deserialization anomaly. A `nil` message is unambiguous because the
first result is `true`.

```lua
local channel = assert(babet.workers.channel({ capacity = 1 }))
assert(channel:send(nil, 0))

local ok, value = channel:recv(0)
assert(ok == true and value == nil)
```

Channels use the same JSON transfer rules as workers. Channel handles and other
userdata cannot themselves be sent as messages; neither can
`babet.sqlite.NULL`. A rejected send publishes nothing to the channel. For
binary Selenium screenshots, prefer a file path, or keep Base64 text and decode it with
`babet.base64.decode()` at the consumer.

Inside a worker, `job:cancel()` also wakes a blocked `channel:send()` or
`channel:recv()` for **that worker only**. The call returns
`(false, "cancelled")` without closing the shared channel or disturbing other
participants. New channel sends and receives from that cancelled worker also
return `"cancelled"`; use `worker.send()` for a final acknowledgement to the
parent.

<a id="workers-channel-close"></a>
### `close` and `is_closed`

`close()` is global and idempotent. It rejects future sends, makes
`is_closed()` return `true`, wakes blocked senders and receivers, and preserves
already queued messages. Once those messages are drained, `recv()` returns
`(false, "closed")`.

```lua
local channel = assert(babet.workers.channel({ capacity = 2 }))
assert(channel:send("one"))
assert(channel:send("two"))
assert(channel:close())
assert(channel:is_closed())

assert(select(2, channel:recv()) == "one")
assert(select(2, channel:recv()) == "two")
local ok, reason = channel:recv()
assert(not ok and reason == "closed")
```

<a id="workers-channel-lifetime"></a>
### Concurrency, ordering, and lifetime

All handles for a channel reference the same C++ object, while each Lua state
owns a separate userdata. Collecting one local handle does not close the
channel for the others. Explicit `close()` affects every handle. When the last
reference disappears, Babet closes the queue, wakes waiters, and destroys any
remaining messages.

FIFO refers to effective insertion order. Concurrent sends from different
producers have no deterministic relative order, while sequential sends from a
single producer remain ordered.

Capacity does not limit individual message size. JSON serialization creates
copies, so large messages can consume substantial memory. Publishing binary
data atomically to a file and sending its path is usually preferable.

<a id="workers-timeouts"></a>
## Timeouts and failure reasons

All four message methods and `join(timeout?)` share the same timeout
validation rules:

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
| `"cancelled"` | `job:send`, `worker.recv`, or a channel method called in a cancelled worker |

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

<a id="workers-cancel"></a>
## `cancel()` and cooperative cancellation

```lua
local ok, err = job:cancel()
```

`job:cancel()`:

- sets an atomic flag visible through `worker.cancelled()`;
- closes the inbox to wake a blocked `worker.recv()` immediately;
- also wakes the channel `send` or `recv` currently blocked in that worker,
  without closing the global channel;
- makes future `job:send()` calls return `(false, "cancelled")`;
- leaves the outbox open, allows a final message when space is immediately
  available, and wakes a `worker.send()` blocked on a full outbox with
  `(false, "cancelled")`;
- does not join the thread;
- does not consume the final result;
- is idempotent and always returns `(true, nil)` for a valid job.

```lua
assert(job:cancel())

local got, final = job:recv(1)
if got then
    print("final message", final)
end

local ok, result = job:join(2)
if ok == nil then
    error("worker did not cooperate before the deadline")
end
assert(ok, result)
```

This mechanism never uses `pthread_cancel()` and never abruptly interrupts Lua,
SQLite, a C++ lock, or a transaction. A worker must therefore check
`worker.cancelled()` or regularly return to `worker.recv()`.

A worker blocked in a non-interruptible system call or in a loop that never
checks the flag can remain active. Babet channel waits and a `worker.send()`
waiting for space in the outbox are awakened by cancellation. `join(timeout)`
keeps the parent bounded in every other case, but Babet does not force
termination.

`close()` and `cancel()` differ:

- `close()` means “no more commands” and allows already queued commands to
  drain; `worker.recv()` eventually returns `"closed"`;
- `cancel()` means “abandon current work as soon as possible”; queued inbox
  commands are no longer delivered and `worker.recv()` returns `"cancelled"`.
  A command already removed before cancellation may still be processing: the
  stop remains cooperative.

<a id="workers-state"></a>
## Module loading and worker environment

Each thread creates a fresh Lua state and:

- opens the standard Lua libraries;
- registers the complete `babet` namespace;
- exposes bundled modules through `require`;
- configures user-module loading like the parent project, in directory or
  embedded mode;
- exposes `worker.args`, `worker.channels`, `worker.send`, `worker.recv`, and
  `worker.cancelled`;
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

<a id="workers-cpu-count"></a>
## Available CPU count

```lua
local count = babet.workers.cpu_count()
assert(math.type(count) == "integer" and count >= 1)
```

`cpu_count()` returns the number of CPUs available to the current process. On
Linux, Babet first reads the effective affinity with `sched_getaffinity()`, so
CPU sets imposed on the process are respected. If that information is
unavailable, `_SC_NPROCESSORS_ONLN` is used, with a final fallback to `1`.

The function accepts no arguments. It is also the default size source for
`workers.pool()`.

<a id="workers-pool"></a>
## Reusable bounded pool

`workers.pool()` creates a fixed number of persistent workers. Each worker
creates one pthread and one `lua_State`, then processes several tasks received
through an internal channel. The pool avoids a complete `workers.spawn()` for
every small operation while keeping strict bounds on concurrency and
outstanding tasks.

The pool is implemented as embedded Lua on top of the native `workers.spawn()`
and `workers.channel()` primitives. It therefore keeps the same serialization,
depth, memory-budget, and cooperative-cancellation limits.

<a id="workers-pool-create"></a>
### Creation and options

```lua
local pool, err = babet.workers.pool({
    size = math.min(babet.workers.cpu_count(), 8),
    queue_capacity = 64,
    channels = {
        progress = progress_channel,
    },
})
assert(pool, err)
```

Accepted options:

| Option | Default | Contract |
| --- | ---: | --- |
| `size` | `min(cpu_count(), 1024)` | integer from `1` to `1024` |
| `queue_capacity` | `max(64, size * 4)` | integer from `1` to `1,000,000` |
| `channels` | none | name-to-channel table shared with every task |

`__babet_pool_tasks` and `__babet_pool_results` are reserved for the two
internal channels. Unknown options and invalid names are rejected immediately.

The maximum number of accepted but not yet collected tasks is:

```text
min(queue_capacity + size, 1,000,000)
```

This bound includes running tasks and tasks still waiting in the queue.

<a id="workers-pool-submit"></a>
### Submission and tasks

```lua
local task, err = pool:submit([[
    return worker.args.left + worker.args.right
]], { left = 20, right = 22 }, 1.0)
assert(task, err)

local ok, result = task:join(2)
assert(ok and result == 42)
```

`submit(code, args?, timeout?)` accepts the same text chunk and serializable
argument table as `workers.spawn()`. The timeout applies to admission into the
pool: submission may need to wait for a slot in the outstanding-task bound or
in the work channel.

A task exposes:

- `task:done()`: non-consuming boolean;
- `task:status()`: `"running"`, `"done"`, or `"error"`;
- `task:poll()`: non-blocking check that consumes a completed result;
- `task:join(timeout?)`: wait for and consume the result.

As with a normal job, only the first return value crosses the state boundary and
the result can be consumed once. A task load error or Lua exception becomes an
error for that task without stopping the persistent worker. An unserializable
return value is also converted into a task error, after which the worker keeps
processing later tasks.

<a id="workers-pool-isolation"></a>
### State isolation and reuse

Each task receives a fresh global table whose `_G` points to itself. Ordinary
global assignment therefore does not leak to the next task:

```lua
local first = assert(pool:submit("temporary = 42; return temporary"))
local second = assert(pool:submit("return temporary"))

assert(select(2, first:join()) == 42)
assert(select(2, second:join()) == nil)
```

Libraries and the `package.loaded` cache still belong to the persistent worker
state. Explicitly mutating a shared module table, `package.loaded`, a C module's
registry state, or an external resource can therefore be visible to a later
task on the same worker. The pool isolates ordinary globals; it does not create
a complete Lua state per task.

Inside a pool task, `worker` intentionally exposes only:

```lua
worker.args
worker.channels
worker.cancelled()
```

The private `worker.send()` and `worker.recv()` inbox/outbox APIs are not part
of the pool-task contract. Use `opts.channels` for additional persistent
communication.

<a id="workers-pool-backpressure"></a>
### Backpressure and timeouts

```lua
local pool = assert(babet.workers.pool({
    size = 1,
    queue_capacity = 1,
}))

local a = assert(pool:submit("babet.sleep(1); return 'a'"))
local b = assert(pool:submit("babet.sleep(1); return 'b'"))
local c, reason = pool:submit("return 'c'", nil, 0)
assert(c == nil and reason == "timeout")
```

With one worker and one queue slot, at most two tasks are outstanding: one
running and one waiting. A zero timeout is non-blocking. A positive value up to
`86400` uses a monotonic deadline and may return `"timeout"`. An omitted timeout
waits while the workers remain healthy.

The pool collects results while waiting to submit or close. The result channel
capacity matches the outstanding-task bound, so a worker does not remain
blocked merely because the parent has not joined every task yet.

<a id="workers-pool-lifecycle"></a>
### Close, cancellation, and `join`

`pool:close(timeout?)` rejects new submissions and enqueues one stop marker per
worker **after** all accepted tasks. FIFO ordering therefore guarantees normal
processing before thread shutdown.

`pool:join(timeout?)` automatically calls `close()` when needed, collects all
pending results, and joins every persistent worker. A timeout consumes neither
pending task results nor already completed worker joins; the same pool can be
joined again to finish the cleanup:

```lua
local task = assert(pool:submit("return 42"))
assert(pool:join(5))
assert(select(2, task:join(0)) == 42)
```

`pool:cancel()` immediately closes admission, marks outstanding tasks as
`"cancelled"`, closes the work channel, and requests cancellation of every
worker. A running task can stop only by returning or checking
`worker.cancelled()`. There is no `pthread_cancel()` and no forced shutdown.

A joined pool cannot be joined a second time. `pool:stats()` reports `size`,
`queue_capacity`, `max_pending`, `pending`, `accepting`, `closing`, `cancelled`,
and `joined`.

<a id="workers-pool-channels"></a>
### Shared channels in tasks

```lua
local progress = assert(babet.workers.channel({ capacity = 16 }))
local pool = assert(babet.workers.pool({
    size = 2,
    channels = { progress = progress },
}))

local task = assert(pool:submit([[
    assert(worker.channels.progress:send({ percent = 100 }))
    return "done"
]]))

local received, message = progress:recv(2)
assert(received and message.percent == 100)
assert(task:join(2))
assert(pool:join(2))
```

Handles are shared with all pool workers and keep the normal bounded FIFO
multi-producer/multi-consumer channel contract. The pool never automatically
closes user-provided channels.

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


<a id="workers-example-channel-parent-worker"></a>
### Parent to worker through a channel

```lua
local tasks = assert(babet.workers.channel({ capacity = 8 }))

local job = assert(babet.workers.spawn([[
    local ok, task = worker.channels.tasks:recv(2)
    assert(ok, task)
    return task.left + task.right
]], nil, {
    channels = { tasks = tasks },
}))

assert(tasks:send({ left = 20, right = 22 }, 2))
local ok, result = job:join(2)
assert(ok and result == 42)
```

<a id="workers-example-channel-worker-worker"></a>
### Worker to worker without parent relay

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
local results = assert(babet.workers.channel({ capacity = 16 }))

local producer = assert(babet.workers.spawn([[
    for i = 1, 10 do
        assert(worker.channels.tasks:send({ id = i, value = i * 10 }, 2))
    end
    return "producer done"
]], nil, { channels = { tasks = tasks } }))

local consumer = assert(babet.workers.spawn([[
    for _ = 1, 10 do
        local ok, task = worker.channels.tasks:recv(2)
        assert(ok, task)
        assert(worker.channels.results:send({
            id = task.id,
            result = task.value * 2,
        }, 2))
    end
    return "consumer done"
]], nil, { channels = { tasks = tasks, results = results } }))

for expected = 1, 10 do
    local ok, item = results:recv(2)
    assert(ok and item.id == expected and item.result == expected * 20)
end

assert(producer:join(2))
assert(consumer:join(2))
```

Producer-to-consumer messages never pass through the parent.

<a id="workers-example-channel-mpmc"></a>
### Multiple producers and consumers

The same channel can be passed to several producers and consumers. Each message
is removed by exactly one consumer, but distribution among consumers depends on
thread scheduling and is not predictable. Close the task channel only after all
producers have completed, then let consumers drain it until they receive
`"closed"`.

<a id="workers-example-cancel"></a>
### Native cooperative cancellation

```lua
local job = assert(babet.workers.spawn([[
    local total = 0

    for i = 1, worker.args.limit do
        total = total + expensive_step(i)

        if i % 1000 == 0 and worker.cancelled() then
            worker.send({
                stopped = true,
                partial = total,
            })
            return {
                cancelled = true,
                partial = total,
            }
        end
    end

    return { cancelled = false, total = total }
]], { limit = 1000000 }))

-- Later:
assert(job:cancel())

-- The outbox remains drainable after cancel().
local got, progress = job:recv(0.5)
if got then
    print("partial", progress.partial)
end

local ok, result = job:join(2)
if ok == nil then
    error("cancellation was not observed within two seconds")
end
assert(ok, result)
```

Combined `worker.recv()` and flag example:

```lua
local job = assert(babet.workers.spawn([[
    while not worker.cancelled() do
        local ok, command = worker.recv(0.1)

        if ok then
            execute(command)
        elseif command == "cancelled" then
            break
        elseif command ~= "timeout" then
            return { error = command }
        end
    end

    worker.send({ stopped = true })
    return "cancelled"
]]))

assert(job:cancel())
local ok, result = job:join(2)
assert(ok and result == "cancelled")
```

Cancellation remains cooperative: it does not arbitrarily interrupt a system
call or code that never checks the flag.

<a id="workers-example-pool"></a>
### Native pool for many tasks

```lua
local pool = assert(babet.workers.pool({
    size = math.min(4, babet.workers.cpu_count()),
    queue_capacity = 16,
}))

local tasks = {}
for index = 1, 100 do
    tasks[index] = assert(pool:submit([[
        return worker.args.value * worker.args.value
    ]], { value = index }))
end

assert(pool:close(5))

local results = {}
for index, task in ipairs(tasks) do
    local ok, value = task:join(5)
    assert(ok, value)
    results[index] = value
end

assert(pool:join(5))
assert(results[10] == 100)
```

The pthread count remains fixed across all one hundred tasks. `close()` may be
called before collecting results: the pool processes every accepted submission,
while each `task:join()` retrieves its result by identifier.

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
- message and join phases are clearly separated;
- during cancellation, call `job:cancel()` before the bounded `join()`:
  cancellation now wakes the blocked outbox send without discarding messages
  that were already queued.

### Producers blocked on a full channel

A bounded channel can create the same wait cycle as a full outbox: producers
wait for space while the parent calls `join()` before consumers have drained
the queue. Define who consumes, who closes the channel, and when. Long-running
protocols should use finite timeouts or a shutdown strategy so one failed
participant cannot block all others.

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
- method call on a value that is not the expected job or channel;
- invalid `workers.channel()` arity, options, or capacity;
- invalid `opts.channels`, empty/non-UTF-8/NUL name, or non-channel value.

```lua
local ok, err = pcall(function()
    babet.workers.spawn(42)
end)
assert(not ok)
```

### Failures returned by `spawn`

`spawn` returns `(nil, err)` for runtime failures before or during creation:

- non-transferable `args`;
- serialization-budget exhaustion;
- JSON serialization failure;
- queue or completion-signal initialization failure;
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
- `channel:send`: `(nil, err)` for the same case;
- `job:recv` and `worker.recv`: `(false, err)` on an internal anomaly;
- `channel:recv`: `(nil, err)` on an internal anomaly.

<a id="workers-gc"></a>
## Garbage collection and destruction

The userdata has a safety-net `__gc`. When collected:

1. the cancellation flag is set;
2. inbox and outbox are closed;
3. queue waiters are awakened;
4. Babet calls `pthread_join` when needed;
5. pthread primitives, the completion signal, and internal strings are
   destroyed.

This prevents freeing state still used by a thread. It can nevertheless block
when the worker cannot terminate.

Do not use GC as the normal synchronization mechanism. Keep the job, finish
the protocol, then call `join()` or consume the result through `poll()`.

A pool is a Lua object that owns several worker userdata values. Dropping the
last pool and task references without `pool:join()` eventually delegates every
thread to those userdata finalizers and can therefore block collection or Lua
state shutdown. Normal code should explicitly `close()` or `cancel()`, then
retry `pool:join()` until it completes.

Channel handles also have a `__gc`, but its scope is local: it only releases
the reference owned by that Lua state. It never replaces `channel:close()` and
does not close the resource while other handles remain.

`tostring(channel)` returns `WorkerChannel(open)` or `WorkerChannel(closed)`
from the instantaneous global state.

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
- handles for explicitly passed channels;
- JSON copies of transferred data.

Avoid a worker for tiny operations. Batch work or use a few persistent workers
when the protocol allows it.

<a id="workers-not-provided"></a>
## Features not provided

The module currently does not provide:

- forced worker termination;
- individual forced cancellation of a pool task;
- dynamic resizing of a pool after creation;
- channels between distinct OS processes;
- shared Lua memory;
- transfer of functions, userdata, or coroutines;
- a binary message format;
- automatic transfer of multiple return values.

The 2.18 pool is local to the Lua state that created it. It is not a global
scheduler shared by separate Babet processes, and it does not migrate a task
that has already started from one worker to another.
