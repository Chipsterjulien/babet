> **English** | [Français](../../fr/modules/pipeline.md)

# Process pipelines

Babet provides two complementary APIs for connecting programs through POSIX
pipes without invoking a shell:

- `babet.pipeline()` runs the whole pipeline and captures its streams;
- `babet.spawnPipeline()` immediately returns a streaming process object.

In both cases, each stage's stdout is connected directly to the next stage's
stdin. The parent only owns the first stage's stdin, the last stage's stdout,
and one separate stderr stream per stage.

## Shared command syntax

```lua
local commands = {
    { "printf", { "orange\napple\norange\n" } },
    { "grep", { "orange" } },
    { "sort", { "-u" } },
}
```

`commands` must be a dense array containing 2 to 32 stages. Each stage has one
of these forms:

```lua
{ command }
{ command, args }
{ command, args, opts }
```

To provide `opts` without arguments, explicitly use `{ command, {}, opts }`;
sparse arrays are rejected.

- `command` is a non-empty string without a NUL byte;
- `args` is a dense array of strings without NUL bytes;
- `opts.cwd` sets this stage's working directory;
- `opts.env` adds or replaces environment variables for this stage.

No string is parsed by a shell: globbing, redirection, variables, quoting and
operators such as `|`, `&&` or `>` have no special meaning.

Global `cwd` and `env` options provide defaults. A local `cwd` replaces the
global one. Local environment entries are merged last and win on duplicate
names. Every command is validated before the first `fork()`.

As with `exec()` and `spawn()`, when a command contains no `/`, lookup uses the
stage's final environment after merging the inherited environment, global
options, and local options. An empty or relative `PATH` component is interpreted
from that stage's effective `cwd`. Every ordered candidate list, `argv`, and `envp` is prepared before the first
`fork()`; each child then traverses only that list with `execve()`, without
parsing `PATH` or allocating memory.

# `babet.pipeline()` — complete execution

## Signature

```lua
result, err = babet.pipeline(commands [, opts])
```

Example:

```lua
local result, err = babet.pipeline({
    { "printf", { "orange\napple\norange\n" } },
    { "grep", { "orange" } },
    { "sort", { "-u" } },
}, {
    timeout = 10,
    max_output = 16 * 1024 * 1024,
})

assert(result, err)
print(result.stdout)
```

## Options

| Option | Type | Description |
|---|---|---|
| `cwd` | string | Default working directory for every stage. |
| `env` | string-to-string table | Variables merged with Babet's environment. |
| `stdin` | binary string | Data progressively written to the first stage, then stdin is closed. |
| `timeout` | finite positive number, at most `10^12` | Global timeout in seconds, including launch, I/O and final wait. |
| `max_output` | integer from 1 to 2 GiB | Separate limit for final stdout and each stderr; default: 10 MiB. |

Unknown keys are rejected. `stdin`, stdout and stderr are binary-safe and may
contain NUL bytes. Timeout resolution is one millisecond; values above `10^12`
seconds are rejected.

## Result

Once every stage has launched, a non-zero exit or signal is a process result,
not an API error. Babet returns:

```lua
{
    stdout = "...",
    stderr = { "stage 1 stderr", "stage 2 stderr", ... },
    stages = {
        {
            launched = true,
            code = 0,
            exited = true,
            signaled = false,
            signal = nil,
        },
        -- ...
    },
    code = 0,
    all_succeeded = true,
    failed_index = nil,
    timed_out = false,
    stdout_truncated = false,
    stderr_truncated = { false, false, ... },
}
```

`code` is the last stage's code, matching Unix pipeline convention. It is the
normal exit status or `128 + signal_number`. In the pathological case where a
status remains unavailable after bounded timeout cleanup, it is `-1` for that
stage. `all_succeeded` is true only when every stage succeeded. `failed_index`
identifies the first non-zero stage even when the last one succeeds.

A non-zero intermediate stage does not artificially stop the other programs.
Normal POSIX pipe behaviour applies; an upstream producer may receive
`SIGPIPE` after a downstream consumer closes its input.

## Timeout, large streams and truncation

`pipeline()`'s timeout covers launch, stdin writes, stdout/stderr draining and
the final wait. If it expires before every stage completes `chdir` and `exec`,
the call returns `nil, err` with the message `"pipeline: launch timed out"`
after rolling back stages already created. After a complete launch, expiry returns a result table with
`timed_out == true`: Babet closes stdin, sends `SIGTERM` to every stage process
group, then `SIGKILL` to survivors, and reaps direct children.

Descriptors are non-blocking and driven with `poll()`. The first stdin, final
stdout and all stderr streams progress concurrently, preventing the usual
large-volume deadlocks. Once `max_output` is reached, extra bytes are discarded
but the stream continues to be drained, and the matching truncation flag is
set.

# `babet.spawnPipeline()` — streaming

## Signature

```lua
pipeline, err = babet.spawnPipeline(commands [, opts])
```

Global options:

| Option | Type | Description |
|---|---|---|
| `cwd` | string | Default working directory for every stage. |
| `env` | string-to-string table | Variables merged with Babet's environment. |
| `launch_timeout` | finite positive number | Deadline covering only creation and complete launch of all stages, at most `INT_MAX` milliseconds (about 24.8 days). |

`spawnPipeline()` accepts no `stdin`, `timeout`, or `max_output` option: the
script streams data and applies its own limits. Success returns a userdata and
`nil`; validation or launch failure returns `nil, err` after cleaning up any
stage that was already created.

This API is intended for commands connected by pipes, not interactive
programs. The first stage's standard input is always Babet's managed pipe, and
no foreground-terminal handoff occurs. A stage that explicitly opens
`/dev/tty` and tries to read from it may therefore be stopped by POSIX
background-process-group rules. Use `babet.spawn()` with `stdin`, `stdout`, and
`stderr` set to `"inherit"` for a tool that must interact directly with the
user.

```lua
local pipeline, err = babet.spawnPipeline({
    { "cat" },
    { "tr", { "a-z", "A-Z" } },
})
assert(pipeline, err)

local written, write_err = pipeline:write("hello\n")
assert(written, write_err)
assert(pipeline:close_stdin())

local chunks = {}
while true do
    local data, read_err = pipeline:read_stdout(64 * 1024, 1)
    if data then
        chunks[#chunks + 1] = data
    elseif read_err == "closed" then
        break
    elseif read_err ~= "timeout" then
        error(read_err)
    end
end

local status, wait_err = pipeline:wait(5)
assert(status, wait_err)
assert(status.code == 0)
print(table.concat(chunks))
```

## Read methods

```lua
data, err = pipeline:read_stdout([max_bytes [, timeout]])
data, err = pipeline:read_stderr(stage [, max_bytes [, timeout]])
```

- `max_bytes` defaults to 64 KiB and must be between 1 and 16 MiB;
- `timeout` is in seconds, defaults to zero, and must be finite and non-negative;
- `stage` ranges from 1 to the number of stages;
- invalid arity, stage index, or `max_bytes` raises a Lua error, matching `babet.spawn()` methods;
- an invalid timeout returns `nil, err`;
- success returns a non-empty binary string and `nil`;
- no immediately available data returns `nil, "timeout"`;
- EOF, or reading an already closed stream, returns `nil, "closed"`.

Each call reads at most one chunk. There is no hidden capture: the script must
retain, limit, or discard received data itself. Stderr streams remain
independent, so every stream capable of filling its pipe must be drained.

## Writing and closing stdin

```lua
count, err = pipeline:write(data [, timeout])
ok, err = pipeline:close_stdin()
```

`write()` accepts a binary string and may write only part of it; `count` is the
number of bytes actually transmitted. An empty string returns `0, nil`. A
timeout leaves the object reusable. Stdin closed by the script or downstream
process returns `nil, "closed"` without delivering `SIGPIPE` to Babet itself.

`close_stdin()` closes the first stage's input and is idempotent. Call it after
the last byte, otherwise a program waiting for EOF may never terminate.

Complete-write pattern:

```lua
local offset = 1
while offset <= #data do
    local count, err = pipeline:write(data:sub(offset), 1)
    if count then
        offset = offset + count
    elseif err ~= "timeout" then
        error(err)
    end
    -- Drain stdout and stderr during large transfers as well.
end
assert(pipeline:close_stdin())
```

## State and identifiers

```lua
running = pipeline:is_running([stage])
pids = pipeline:pids()
```

Without an index, `is_running()` is true while at least one direct stage has not
been reaped. With an index, it describes only that stage. It refreshes statuses
through `waitpid(..., WNOHANG)` without consuming the final result: `wait()`
remains available afterwards.

`pids()` returns direct PIDs in stage order. They are diagnostic values; scripts
must not assume that a PID remains valid after the pipeline exits.

## Waiting and final status

```lua
status, err = pipeline:wait([timeout])
```

Without a timeout, `wait()` waits for every direct child. With a finite
non-negative timeout, `nil, "timeout"` leaves the pipeline intact and reusable.
Once every status is known, subsequent calls are idempotent and return the same
result:

```lua
{
    stages = {
        { launched = true, code = 0, exited = true,
          signaled = false, signal = nil },
        -- ...
    },
    code = 0,
    all_succeeded = true,
    failed_index = nil,
}
```

`wait()` **does not drain** stdout or stderr. A pipeline that fills a pipe may
therefore block before exiting. Streams must be read while it runs, exactly as
with `babet.spawn()`.

## Explicit termination

```lua
status, err = pipeline:terminate([grace_period])
status, err = pipeline:kill()
```

`terminate()` sends `SIGTERM` to every process group, gives processes
`grace_period` seconds—2 seconds by default—to exit, then sends `SIGKILL` to
survivors. The grace period must fit within `INT_MAX` milliseconds, about 24.8
days. `kill()` sends `SIGKILL` immediately. Both close stdin and return the same
status table as `wait()` after direct children are reaped.

Each stage owns its own process group. Before reaping the direct process, Babet
removes descendants that still remain in that group, including normal completion
where a command exits without waiting for a background child. The leader PID
therefore remains reserved until signalling and cannot be recycled for an
unrelated process.

For `terminate()`, every group member receives `SIGTERM` at the beginning of
the grace period. Direct leaders that have already exited deliberately remain
unreaped for the whole period: their PID, which is also used as the PGID,
cannot be recycled before the optional final `SIGKILL` sent to the group. A
stage that deliberately creates a new session or process group escapes this
POSIX guarantee. A script that knows its processes are cooperative may select a
shorter grace period, for example `pipeline:terminate(0.05)`.

## `close()`, GC and Lua `<close>`

```lua
ok, err = pipeline:close()
```

`close()` is idempotent. It closes descriptors, attempts `SIGTERM`, uses
`SIGKILL` when necessary, and reaps direct children. After closure, reads and
writes return `nil, "closed"`, and `is_running()` returns `false`. A fully
collected status remains available from `wait()`.

The same cleanup is used by `__gc` and `__close`. Recommended use:

```lua
local pipeline <close> = assert(babet.spawnPipeline({
    { "producer" },
    { "consumer" },
}))
```

GC is a safety net, not a synchronization mechanism. Use `wait()`,
`terminate()`, or `close()` explicitly when cleanup timing matters.

## Launch errors and reuse

Validation, pipe, `fork`, `chdir`, `exec`, and `launch_timeout` failures return
`nil, err`. When a stage fails during launch, every already-created stage is
terminated and reaped; Lua never receives a partially valid object. The
launcher itself enforces the public 32-stage limit independently of the Lua
binding's validation.

After the first `fork()`, and throughout synchronous `pipeline()` capture,
Babet retains an emergency owner for descriptors and direct children. If an
internal C++ exception occurs, emergency cleanup closes streams, immediately
sends `SIGKILL` only to groups whose leader has not already been reaped, and
then performs a bounded reap attempt. `terminate()`'s grace period is not used
during stack unwinding. For `spawnPipeline()`, resources are transferred to the
userdata only after launch has completed successfully.

Non-destructive `"timeout"` and `"interrupted"` errors allow another call.
`"closed"` means the relevant stream or object can no longer perform that
operation. Other system errors are returned as text and should be handled as
such.
