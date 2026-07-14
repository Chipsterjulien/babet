> **English** | [Français](../../fr/modules/signal.md)

# SIGNAL — graceful shutdown, reloads, and POSIX signals

`babet.signal` lets the main script install a Lua callback for a small set of
POSIX signals, ignore a signal, or restore its operating-system default.

The module covers:

- graceful shutdown on `TERM` and `INT`;
- configuration reload requests on `HUP`;
- two application-defined signals, `USR1` and `USR2`;
- explicitly ignoring or restoring a signal;
- interruption of selected blocking Babet calls;
- deferred, safe callback dispatch in the main Lua thread.

It does not send signals, expose a pending-signal queue, configure POSIX masks,
or allow handlers to be installed from a worker.

## Module contents

- [Essential conventions](#signal-conventions)
- [API overview](#signal-api-summary)
- [Supported signals](#signal-supported)
- [`handle(name, fn)` — install or replace](#signal-handle)
- [`handle(name, nil)` — remove a callback](#signal-handle-remove)
- [`ignore(name)` — ignore](#signal-ignore)
- [`default(name)` — restore the OS default](#signal-default)
- [Callback execution](#signal-dispatch)
  - [Main thread and safe context](#signal-main-thread)
  - [Dispatch order](#signal-order)
  - [Occurrence coalescing](#signal-coalescing)
  - [Callback errors](#signal-callback-errors)
- [Interaction with blocking calls](#signal-blocking)
- [Interaction with `debug.sethook`](#signal-debug-hook)
- [Complete examples](#signal-examples)
  - [Graceful shutdown on `TERM` and `INT`](#signal-example-shutdown)
  - [Reload configuration with `HUP`](#signal-example-reload)
  - [Interrupt a socket wait](#signal-example-socket)
  - [Temporarily ignore `PIPE`](#signal-example-ignore)
  - [Observe callback errors](#signal-example-pcall)
- [Error contract](#signal-errors)
- [Workers, concurrency, and limitations](#signal-workers)
- [Features not provided](#signal-not-provided)

<a id="signal-conventions"></a>
## Essential conventions

### Success returns one value

All three functions return only the boolean `true` on success. They do not
return a second `nil`.

```lua
local ok = babet.signal.ignore("PIPE")
assert(ok == true)
```

A rare `sigaction(2)` failure instead returns two values:

```lua
local ok, err = babet.signal.ignore("PIPE")
if not ok then
    io.stderr:write(err, "\n")
end
```

### Names are strict

A signal name must be an actual Lua string, with no NUL byte, in the exact case
shown by this documentation.

```lua
assert(babet.signal.handle("TERM", function() end))
```

These forms are invalid:

```lua
babet.signal.handle("term", function() end) -- wrong case
babet.signal.handle(15, function() end)     -- number, not string
babet.signal.handle("TERM\0X", function() end)
```

### A callback receives no arguments

The callback is invoked with no parameters. Install a distinct function for
each signal when code needs to know which signal arrived.

```lua
babet.signal.handle("USR1", function()
    print("USR1")
end)
```

<a id="signal-api-summary"></a>
## API overview

```lua
local ok, err = babet.signal.handle(name, callback_or_nil)
local ok, err = babet.signal.ignore(name)
local ok, err = babet.signal.default(name)
```

| Function | Success | Rare system failure | Invalid call |
| --- | --- | --- | --- |
| `handle(name, fn)` | `true` | `(nil, err)` | raises a Lua error |
| `handle(name, nil)` | `true` | `(nil, err)` | raises a Lua error |
| `ignore(name)` | `true` | `(nil, err)` | raises a Lua error |
| `default(name)` | `true` | `(nil, err)` | raises a Lua error |

`handle(name)` without a second argument is intentionally rejected. Write
`handle(name, nil)` explicitly to remove a callback.

<a id="signal-supported"></a>
## Supported signals

| Babet name | POSIX signal | Common use | Usual OS default |
| --- | --- | --- | --- |
| `"TERM"` | `SIGTERM` | graceful shutdown request, notably from systemd | terminate the process |
| `"INT"` | `SIGINT` | keyboard interruption, usually Ctrl-C | terminate the process |
| `"HUP"` | `SIGHUP` | configuration reload request | often terminate the process |
| `"USR1"` | `SIGUSR1` | free application event | terminate the process |
| `"USR2"` | `SIGUSR2` | second free application event | terminate the process |
| `"PIPE"` | `SIGPIPE` | writing to a closed pipe or socket | terminate the process |

`KILL` and `STOP` cannot be exposed: POSIX does not allow them to be caught or
ignored.

Dangerous signals or signals reserved for other internal mechanisms — such as
`SEGV`, `BUS`, `FPE`, `ILL`, `CHLD`, and `ALRM` — are not in the allowlist.

<a id="signal-handle"></a>
## `handle(name, fn)` — install or replace

```lua
local ok, err = babet.signal.handle(name, fn)
```

- `name` is one of the six supported names;
- `fn` must be a Lua function;
- the previous POSIX disposition is replaced;
- an existing Lua callback for the same signal is replaced;
- the callback is retained in the Lua registry until removed.

```lua
local stopping = false

assert(babet.signal.handle("TERM", function()
    stopping = true
end))
```

Replacing a callback:

```lua
assert(babet.signal.handle("USR1", function()
    print("first version")
end))

assert(babet.signal.handle("USR1", function()
    print("new version")
end))
```

After the second call, only the new function can run.

<a id="signal-handle-remove"></a>
## `handle(name, nil)` — remove a callback

```lua
local ok, err = babet.signal.handle(name, nil)
```

This form:

1. removes the associated Lua callback;
2. restores `SIG_DFL`, the operating-system default.

```lua
assert(babet.signal.handle("HUP", reload_config))

-- Later: explicit removal.
assert(babet.signal.handle("HUP", nil))
```

`handle("TERM")` without a second argument is **not** shorthand: it raises an
error, preventing accidental removal caused by a missing argument.

<a id="signal-ignore"></a>
## `ignore(name)` — ignore

```lua
local ok, err = babet.signal.ignore(name)
```

`ignore` installs `SIG_IGN` and removes any previously associated Lua callback.
The kernel then ignores that signal.

```lua
assert(babet.signal.ignore("PIPE"))
```

This is useful when an application prefers normal write errors over process
termination caused by `SIGPIPE`.

The ignore disposition remains active until a later `handle`, `default`, or
`handle(name, nil)` call for the same signal.

<a id="signal-default"></a>
## `default(name)` — restore the OS default

```lua
local ok, err = babet.signal.default(name)
```

`default` installs `SIG_DFL` and removes any Lua callback. For `TERM`, `INT`,
`HUP`, `USR1`, `USR2`, and usually `PIPE`, the next matching signal terminates
the process according to operating-system rules.

```lua
assert(babet.signal.ignore("PIPE"))
-- ... section where SIGPIPE should be ignored ...
assert(babet.signal.default("PIPE"))
```

`handle(name, nil)` and `default(name)` have the same system effect. `default`
is more explicit when no callback is involved.

<a id="signal-dispatch"></a>
## Callback execution

The real POSIX handler never invokes Lua. It only sets a `sig_atomic_t` flag,
which is safe in asynchronous signal context.

The Lua callback runs later from a safe point:

1. a supported signal arrives;
2. the C handler marks that signal pending;
3. the main thread notices the flag from the instruction hook or when an
   interrupted blocking call returns;
4. Babet clears the flag;
5. Babet invokes the Lua callback with zero arguments.

<a id="signal-main-thread"></a>
### Main thread and safe context

The callback always runs in the main Lua state, never in the POSIX handler and
never in a worker. It can therefore use ordinary Lua and Babet APIs.

```lua
babet.signal.handle("USR1", function()
    -- Runs in normal Lua context.
    local now = babet.time.now()
    print("USR1 at", now)
end)
```

That freedom does not mean a callback should be long. A short function that
sets a flag or schedules an action remains easier to reason about.

<a id="signal-order"></a>
### Dispatch order

When several distinct signals are pending at the same dispatch point, Babet
processes them in the fixed order of its allowlist:

1. `TERM`;
2. `INT`;
3. `HUP`;
4. `USR1`;
5. `USR2`;
6. `PIPE`.

This is neither callback registration order nor a guarantee of exact kernel
arrival order.

For example, if `USR1` and then `TERM` arrive before the next dispatch, the
`TERM` callback runs before the `USR1` callback.

<a id="signal-coalescing"></a>
### Occurrence coalescing

Babet stores one flag per signal type, not a counter or queue. Multiple
identical occurrences received before the next dispatch are therefore
coalesced into one callback invocation.

```text
USR1, USR1, USR1 before dispatch -> one USR1 callback invocation
```

A new identical signal received **while** its callback runs can set the flag
again and be processed during a later dispatch.

Do not use this module as a reliable event counter. Use a queue, pipe, socket,
or another message mechanism when every business event must be retained.

<a id="signal-callback-errors"></a>
### Callback errors

Babet invokes callbacks through `lua_pcall`. An uncaught error is removed from
the stack and silently ignored; it is not propagated to the code that was
running.

```lua
babet.signal.handle("USR1", function()
    error("invisible to the caller")
end)
```

Protect the body explicitly to log failures:

```lua
babet.signal.handle("USR1", function()
    local ok, err = pcall(function()
        refresh_metrics()
    end)
    if not ok then
        io.stderr:write("USR1: ", tostring(err), "\n")
    end
end)
```

<a id="signal-blocking"></a>
## Interaction with blocking calls

Babet installs handlers without `SA_RESTART`. Selected internal blocking calls
can therefore be interrupted by a handled signal. When the main thread sees a
pending Babet signal, it dispatches callbacks and generally returns a typed
`"interrupted"` error.

Integrated call families currently include, among others:

- `babet.sleep(...)`;
- Inotify `watcher:read(...)`;
- TCP connection, accept, and receive waits;
- TLS handshakes and waits.

Example:

```lua
local data, err = peer:recv(4096, 30)
if not data then
    if err == "interrupted" then
        -- A callback has already run: re-check application state.
    elseif err == "timeout" then
        -- No bytes arrived before the deadline.
    else
        -- Close or network error.
    end
end
```

Not every Babet function is interruptible through this mechanism. `babet.exec`,
for example, applies its own timeout and does not expose an `"interrupted"`
result for handled signals.

A syscall can also receive `EINTR` while no Babet-managed signal is pending. In
that case internal loops resume waiting instead of reporting a false
`"interrupted"`.

<a id="signal-debug-hook"></a>
## Interaction with `debug.sethook`

Outside integrated blocking functions, Babet uses a Lua count hook, triggered
about every 10,000 instructions, to inspect pending flags.

Lua supports only one active hook per state. Consequently:

- the first `signal.handle(...)` replaces an existing user hook;
- a later `debug.sethook(...)` replaces Babet's hook;
- after that replacement, callbacks are no longer dispatched by instruction
  count, though they may still be dispatched when integrated blocking calls
  return;
- removing every callback with `handle(name, nil)`, `ignore(name)`, or
  `default(name)` does not uninstall Babet's hook and does not restore a user
  hook that was previously replaced. The hook remains active, but does nothing
  while no Babet callback is registered.

Avoid combining `babet.signal` and a custom debug hook in the same Lua state
unless this interaction is deliberate and understood.

<a id="signal-examples"></a>
## Complete examples

<a id="signal-example-shutdown"></a>
### Graceful shutdown on `TERM` and `INT`

```lua
local running = true

local function request_stop()
    running = false
end

assert(babet.signal.handle("TERM", request_stop))
assert(babet.signal.handle("INT", request_stop))

while running do
    do_one_iteration()

    local slept, err = babet.sleep(250, "ms")
    if not slept and err ~= "interrupted" then
        io.stderr:write(tostring(err), "\n")
        break
    end
    -- On "interrupted", the callback has already run and the loop
    -- re-checks running.
end

close_resources()
```

For a network loop, use the socket's direct `"interrupted"` result instead of
`pcall`.

<a id="signal-example-reload"></a>
### Reload configuration with `HUP`

It is often better for the callback to set a flag only. Full loading then
happens in the normal loop.

```lua
local running = true
local reload_requested = false

assert(babet.signal.handle("TERM", function()
    running = false
end))

assert(babet.signal.handle("HUP", function()
    reload_requested = true
end))

while running do
    if reload_requested then
        reload_requested = false
        local new_config, err = load_config()
        if new_config then
            config = new_config
        else
            io.stderr:write("reload: ", err, "\n")
        end
    end

    do_one_iteration(config)
end
```

<a id="signal-example-socket"></a>
### Interrupt a socket wait

```lua
local running = true

assert(babet.signal.handle("TERM", function()
    running = false
end))

while running do
    local client, err = server:accept(60)
    if client then
        serve(client)
    elseif err == "interrupted" then
        -- The TERM callback may have set running to false.
    elseif err ~= "timeout" then
        io.stderr:write("accept: ", err, "\n")
    end
end

server:close()
```

<a id="signal-example-ignore"></a>
### Temporarily ignore `PIPE`

```lua
assert(babet.signal.ignore("PIPE"))

local sent, err = socket:send(payload)
if not sent then
    io.stderr:write("send: ", err, "\n")
end

assert(babet.signal.default("PIPE"))
```

Warning: restoring default `SIGPIPE` behavior means a later write to a closed
pipe may terminate the process.

<a id="signal-example-pcall"></a>
### Observe callback errors

```lua
local function safe_handler(label, fn)
    return function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            io.stderr:write(label, ": ", tostring(err), "\n")
        end
    end
end

assert(babet.signal.handle("USR2", safe_handler("USR2", function()
    rotate_logs()
end)))
```

<a id="signal-errors"></a>
## Error contract

### Raised Lua errors

These situations immediately raise a Lua error:

- call from a worker;
- missing, non-string, or NUL-containing `name`;
- unsupported name or wrong case;
- `handle` without a second argument;
- handler other than a function or `nil`.

```lua
local ok, err = pcall(function()
    babet.signal.handle("TERM")
end)
assert(not ok)
```

An unsupported name also raises; it does not return `(nil, err)`.

```lua
local ok, err = pcall(function()
    babet.signal.ignore("QUIT")
end)
```

### Returned system error

If `sigaction(2)` fails, the function returns:

```lua
nil, "signal: sigaction failed: ..."
```

This is rare with the six allowed signals, but callers may retain the
`(ok, err)` convention when they need to handle it.

<a id="signal-workers"></a>
## Workers, concurrency, and limitations

Signal dispositions are process-wide, not thread-local. Babet therefore
enforces these rules:

- `handle`, `ignore`, and `default` are restricted to the main thread;
- using them from a worker raises an explicit error;
- workers block all six supported signals so they remain owned by the main
  thread;
- workers cannot observe or consume the parent's pending flags.

Control a worker through message queues, not `babet.signal`:

```lua
local job = assert(babet.workers.spawn([[
    while true do
        local ok, message = worker.recv()
        if not ok then
            return "closed"
        end
        if message == "stop" then
            return "stopped"
        end
    end
]]))

-- The main handler converts the signal into an application message.
babet.signal.handle("TERM", function()
    job:send("stop", 0)
end)
```

Keep this callback short. A full queue can make the non-blocking send fail; a
robust application also keeps a fallback flag.

<a id="signal-not-provided"></a>
## Features not provided

The module currently does not provide:

- `kill(pid, name)` to send a signal;
- `list()` to retrieve supported names;
- `is_pending()` or an occurrence counter;
- `sigprocmask` or per-thread masks;
- `signalfd`;
- signals beyond the six listed names;
- a debug hook that can be chained with the user's hook.

An external program can send a signal from Lua:

```lua
local result, err = babet.exec("kill", {
    "-TERM",
    tostring(pid),
})
assert(result, err)
assert(result.code == 0, result.stderr)
```

Reception remains subject to ordinary POSIX rules and the dispatch model
described on this page.
