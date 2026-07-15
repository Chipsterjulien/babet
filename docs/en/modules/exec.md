> **English** | [Français](../../fr/modules/exec.md)

# EXEC - external programs, capture, and streaming

Babet provides two complementary APIs for starting an external program without
an implicit shell:

- `babet.exec` optionally sends complete input, captures `stdout` and `stderr`
  in memory, then waits for completion;
- `babet.spawn` immediately returns a controllable process object so streams can
  be read and written progressively without automatic RAM accumulation.

EXEC covers:

- looking up a program through `PATH`;
- building `argv` safely, without shell parsing;
- selecting a working directory for the child process;
- merging a custom environment with Babet's environment;
- sending a binary string to standard input;
- capturing binary `stdout` and `stderr`;
- applying one timeout to launch, I/O, and final wait;
- enforcing a separate memory limit for each output stream;
- terminating the child's process group after a timeout.

It does not provide direct file redirection or an implicit command interpreter.
To connect several programs without a shell, use
[`babet.pipeline()` or `babet.spawnPipeline()`](pipeline.md).

## Module contents

- [Essential conventions](#exec-conventions)
- [API overview](#exec-api-summary)
- [Signature and arguments](#exec-signature)
  - [`cmd` and program lookup](#exec-command)
  - [`args` and shell-free execution](#exec-args)
  - [Using a shell explicitly](#exec-shell)
- [Options](#exec-options)
  - [`cwd`](#exec-cwd)
  - [`env`](#exec-env)
  - [`stdin`](#exec-stdin)
  - [`timeout`](#exec-timeout)
  - [`max_output`](#exec-max-output)
- [Result table](#exec-result)
  - [Normal exit code](#exec-exit-code)
  - [Signal termination](#exec-signal-code)
  - [Timeout](#exec-result-timeout)
  - [Truncation](#exec-result-truncation)
- [Complete examples](#exec-examples)
  - [Basic capture](#exec-example-basic)
  - [Arguments containing spaces](#exec-example-argv)
  - [Handling a non-zero code](#exec-example-nonzero)
  - [Capturing `stderr`](#exec-example-stderr)
  - [Sending text or binary stdin](#exec-example-stdin)
  - [Changing the environment](#exec-example-env)
  - [Changing the working directory](#exec-example-cwd)
  - [Bounding execution time](#exec-example-timeout)
  - [Bounding captured output](#exec-example-output)
  - [Building an application helper](#exec-example-helper)
- [Streaming processes with `babet.spawn`](#spawn-overview)
  - [Signature and options](#spawn-signature)
  - [Process methods](#spawn-methods)
  - [Reading stdout and stderr](#spawn-reading)
  - [Writing stdin](#spawn-writing)
  - [Waiting, terminating, and closing](#spawn-lifecycle)
  - [Streaming loop example](#spawn-example)
  - [Limits and deadlock prevention](#spawn-limits)
- [Error contract](#exec-errors)
- [Processes, signals, and security](#exec-process-security)
- [Design and limitations](#exec-design)

<a id="exec-conventions"></a>
## Essential conventions

### No implicit shell

This call:

```lua
local result, err = babet.exec("printf", { "%s\n", "hello world" })
```

starts `printf` directly. Every `args` element becomes a separate `argv` slot.
Spaces, `$`, `*`, `;`, `>`, quotes, and other shell characters are not
interpreted.

This avoids most quoting mistakes and command-injection issues.

### A non-zero exit is not a launch error

A program that starts successfully and exits with code `1`, `2`, or `127`
still produces a result table. The caller decides which codes are acceptable.

```lua
local result, err = babet.exec("grep", { "needle", "data.txt" })
assert(result, err)

if result.code == 0 then
    print("match found")
elseif result.code == 1 then
    print("no match")
else
    error(result.stderr)
end
```

`assert(babet.exec(...))` only checks that Babet could launch and monitor the
program. It does not check `result.code`.

### Data strings are binary-safe

`opts.stdin`, `result.stdout`, and `result.stderr` are binary-safe Lua strings.
They may contain NUL bytes and do not need to be UTF-8 text.

Strings passed to POSIX APIs that require C strings - `cmd`, `args` elements,
`cwd`, and environment names and values - cannot contain a NUL byte.

<a id="exec-api-summary"></a>
## API overview

```lua
local result, err = babet.exec(cmd, args?, opts?)
```

| Element | Type | Default | Purpose |
| --- | --- | --- | --- |
| `cmd` | strict string | required | program name or path |
| `args` | string sequence | no arguments | `argv[1]..argv[n]` |
| `opts.cwd` | string | inherited current directory | child working directory |
| `opts.env` | string-to-string table | inherited environment | variables to add or replace |
| `opts.stdin` | binary string | stdin closed immediately | data sent to the child |
| `opts.timeout` | finite number > 0 | no limit | global budget in seconds |
| `opts.max_output` | integer `1..2 GiB` | 10 MiB | cap per captured stream |

Main outcomes:

| Situation | Return value |
| --- | --- |
| program launched and completed | `(result, nil)` |
| program launched then timed out | `(result, nil)` with `timed_out = true` |
| non-zero exit status | `(result, nil)` with `code ~= 0` |
| program not found or invalid `cwd` | `(nil, err)` |
| invalid `args` or `opts` | `(nil, err)` |
| missing or non-string `cmd` | raised Lua error |

<a id="exec-signature"></a>
## Signature and arguments

<a id="exec-command"></a>
### `cmd` and program lookup

`cmd` must be an actual Lua string.

```lua
local result, err = babet.exec("git", { "status", "--short" })
```

When `cmd` contains no `/`, Babet asks the C library to search for it through
the Babet process's `PATH`.

```lua
local result = assert(babet.exec("python3", { "--version" }))
```

When `cmd` contains `/`, it is treated as a direct path.

```lua
local result = assert(babet.exec("/usr/bin/id", { "-u" }))
```

A relative path containing `/` is resolved in the child's directory after
`opts.cwd` has been applied.

```lua
local result = assert(babet.exec("./tool", {}, {
    cwd = "/opt/my-app/bin",
}))
```

#### `PATH` and `opts.env` nuance

The child may receive a replacement `PATH` through `opts.env`. However, the
current Linux implementation uses `execvpe`, whose initial lookup of `cmd` uses
the Babet process's `PATH`, not `opts.env.PATH`.

```lua
local result, err = babet.exec("my-private-tool", {}, {
    env = { PATH = "/opt/private/bin" },
})
```

This does not guarantee that `/opt/private/bin/my-private-tool` will be found.
Use a direct path:

```lua
local result, err = babet.exec("/opt/private/bin/my-private-tool", {}, {
    env = { PATH = "/opt/private/bin" },
})
```

The replacement `PATH` is still visible **inside** the child and to commands it
starts later.

<a id="exec-args"></a>
### `args` and shell-free execution

`args` is optional. It must be a dense `1..n` sequence of strings.

```lua
local result = assert(babet.exec("cp", {
    "--",
    "file with spaces.txt",
    "destination/",
}))
```

Babet reads only the Lua sequence part, from `1` through `#args`. For predictable
behavior:

- use consecutive indexes starting at `1`;
- do not leave holes;
- do not store metadata in the same table;
- use strings only.

```lua
-- Correct
local args = { "-c", "print('ok')" }

-- Invalid: numeric element
local result, err = babet.exec("lua", { "-e", 42 })
-- result == nil; err says all arguments must be strings
```

`argv[0]` is set to `cmd` automatically. The first `args` element becomes
`argv[1]`.

<a id="exec-shell"></a>
### Using a shell explicitly

Operators such as `|`, `>`, `&&`, `;`, variables such as `$NAME`, and globs are
only interpreted when you explicitly start a shell.

```lua
local result = assert(babet.exec("sh", {
    "-c",
    "printf '%s\n' \"$HOME\" | sed 's#^#home=#'",
}))
```

Values embedded in shell source must then follow shell quoting rules. For
untrusted data, pass values through `args`, `stdin`, or `env` instead of
concatenating them into the `-c` script.

<a id="exec-options"></a>
## Options

The third argument is optional. When present, it must be a table. Unknown fields
are currently ignored; a typo such as `timeot = 5` therefore does not raise an
error. Use the exact names below.

<a id="exec-cwd"></a>
### `opts.cwd`

Sets the child's current directory without changing the Babet process's current
directory.

```lua
local result, err = babet.exec("pwd", {}, {
    cwd = "/var/tmp",
})
assert(result, err)
print(result.stdout) -- /var/tmp
```

The child performs `chdir` before launching the program. It affects:

- relative paths used by the program;
- a relative `cmd` containing `/`;
- relative entries in the `PATH` used for lookup.

If the directory does not exist or is inaccessible, Babet returns `(nil, err)`.
The parent current directory is unchanged.

<a id="exec-env"></a>
### `opts.env`

`env` is a table whose keys and values must be strings. It is **merged** with
the Babet process's environment.

```lua
local result = assert(babet.exec("sh", {
    "-c", "printf '%s' \"$APP_MODE\"",
}, {
    env = { APP_MODE = "production" },
}))

assert(result.stdout == "production")
```

Rules:

- a supplied key replaces the inherited variable of the same name;
- an omitted key remains inherited;
- `""` creates or keeps a defined-but-empty variable;
- there is no option to remove a variable completely;
- a key must be non-empty and cannot contain `=`;
- keys and values reject NUL bytes;
- non-string keys and values are rejected.

Defined-but-empty is different from absent:

```lua
local result = assert(babet.exec("sh", { "-c", [[
    if [ "${TOKEN+x}" = x ] && [ -z "$TOKEN" ]; then
        printf 'defined-empty'
    fi
]] }, {
    env = { TOKEN = "" },
}))

assert(result.stdout == "defined-empty")
```

The environment is built in the parent before `fork`, avoiding `setenv` calls in
a child of a multithreaded process.

<a id="exec-stdin"></a>
### `opts.stdin`

`stdin` is one string sent completely to the program's standard input.

```lua
local result = assert(babet.exec("sha256sum", { "-" }, {
    stdin = "hello world\n",
}))
print(result.stdout)
```

It is binary-safe:

```lua
local payload = "A\0B\0C"
local result = assert(babet.exec("cat", {}, { stdin = payload }))
assert(result.stdout == payload)
```

When `stdin` is absent or `nil`, Babet closes the input pipe immediately, so the
child sees EOF. An empty string also produces EOF after the normal pipe setup.

Babet writes stdin while reading both output pipes, preventing deadlocks with a
program that produces substantial output before consuming all its input.

<a id="exec-timeout"></a>
### `opts.timeout`

`timeout` is a finite, strictly positive number of seconds.

```lua
local result = assert(babet.exec("sleep", { "30" }, {
    timeout = 0.5,
}))

assert(result.timed_out)
```

The budget starts before launch preparation and covers:

1. environment preparation;
2. `fork`;
3. the child `chdir`;
4. the `exec` call;
5. stdin transfer;
6. stdout and stderr capture;
7. the final process wait.

Internal resolution is one millisecond. Values below `0.001` therefore act as
an almost immediate deadline and should not be used for precise timing.

The value must fit within `INT_MAX` milliseconds, about 24.8 days. Zero,
negative, NaN, infinite, and larger values return `(nil, err)`.

After expiry once the child has launched:

1. Babet sends `SIGTERM` to the process group;
2. it allows up to 2 seconds for a clean exit;
3. it sends `SIGKILL` if needed;
4. it continues draining output for a bounded window.

<a id="exec-max-output"></a>
### `opts.max_output`

`max_output` limits retained bytes **for each stream**.

```lua
local result = assert(babet.exec("yes", {}, {
    timeout = 0.2,
    max_output = 4096,
}))

assert(#result.stdout == 4096)
assert(result.stdout_truncated)
```

Values:

- default: `10 * 1024 * 1024`, or 10 MiB;
- minimum: 1 byte;
- maximum: `2 * 1024 * 1024 * 1024`, or 2 GiB;
- type: integral Lua number.

The cap is independent: up to 10 MiB of stdout **and** 10 MiB of stderr by
default.

After reaching the cap, Babet keeps reading and discarding excess bytes. This is
necessary to avoid filling the pipe and blocking the child. The first bytes are
retained; the final bytes are lost.

<a id="exec-result"></a>
## Result table

After a successful launch, the first return value is always a table with six
fields:

```lua
{
    stdout = "...",
    stderr = "...",
    code = 0,
    timed_out = false,
    stdout_truncated = false,
    stderr_truncated = false,
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `stdout` | binary string | first retained bytes from standard output |
| `stderr` | binary string | first retained bytes from standard error |
| `code` | integer | normal code, signal convention, or `-1` if unavailable |
| `timed_out` | boolean | Babet initiated termination after deadline expiry |
| `stdout_truncated` | boolean | stdout exceeded `max_output` |
| `stderr_truncated` | boolean | stderr exceeded `max_output` |

<a id="exec-exit-code"></a>
### Normal exit code

When the program calls `exit(n)` or returns from `main`, `code` is the POSIX
status `0..255`.

```lua
local result = assert(babet.exec("sh", { "-c", "exit 7" }))
assert(result.code == 7)
assert(not result.timed_out)
```

<a id="exec-signal-code"></a>
### Signal termination

When the process is terminated by a signal, Babet uses:

```text
code = 128 + signal_number
```

For example, `SIGKILL` is normally 9 on Linux, giving `code == 137`. This is a
useful convention but there is no separate result field containing the signal.

<a id="exec-result-timeout"></a>
### Timeout

`timed_out == true` means Babet reached its deadline and started termination.
`code` depends on how the child eventually stopped:

- an application-defined code if it handles `SIGTERM` and exits cleanly;
- often `143` for `SIGTERM`;
- often `137` after `SIGKILL`;
- exceptionally `-1` if status could not be obtained within bounded cleanup.

Do not test only `code == 137` to detect a timeout; use `timed_out`.

Output produced before expiry is retained up to `max_output`.

<a id="exec-result-truncation"></a>
### Truncation

`stdout_truncated` and `stderr_truncated` only mean that the corresponding stream
exceeded `max_output`.

```lua
if result.stdout_truncated then
    print("stdout is incomplete: increase max_output or redirect to a file")
end
```

In an extremely pathological kernel/process-group case, a descendant may keep a
pipe open after `SIGKILL` and force Babet to abandon draining rather than block
forever. This rare cause is not represented by the truncation flags, which are
reserved for the memory cap.

<a id="exec-examples"></a>
## Complete examples

<a id="exec-example-basic"></a>
### Basic capture

```lua
local result, err = babet.exec("git", { "rev-parse", "HEAD" })
assert(result, err)

if result.code ~= 0 then
    error("git failed: " .. result.stderr)
end

local commit = result.stdout:gsub("%s+$", "")
print(commit)
```

<a id="exec-example-argv"></a>
### Arguments containing spaces

```lua
local filename = "July 2026 report.txt"
local result = assert(babet.exec("printf", {
    "name=<%s>\n",
    filename,
}))

assert(result.stdout == "name=<July 2026 report.txt>\n")
```

No additional quoting is needed around `filename`: the Lua table already
represents the argument boundary.

<a id="exec-example-nonzero"></a>
### Handling a non-zero code

```lua
local result, err = babet.exec("diff", {
    "--brief",
    "config.old",
    "config.new",
})
assert(result, err)

if result.code == 0 then
    print("files are identical")
elseif result.code == 1 then
    print("files differ")
else
    error("diff failed: " .. result.stderr)
end
```

<a id="exec-example-stderr"></a>
### Capturing `stderr`

```lua
local result = assert(babet.exec("sh", {
    "-c", "printf out; printf err >&2",
}))

assert(result.stdout == "out")
assert(result.stderr == "err")
```

<a id="exec-example-stdin"></a>
### Sending text or binary stdin

```lua
local csv = "name,score\nAlice,18\nBob,15\n"
local result = assert(babet.exec("sort", {}, { stdin = csv }))
print(result.stdout)
```

```lua
local bytes = string.char(0x00, 0x01, 0xFE, 0xFF)
local result = assert(babet.exec("cat", {}, { stdin = bytes }))
assert(result.stdout == bytes)
```

<a id="exec-example-env"></a>
### Changing the environment

```lua
local result = assert(babet.exec("sh", { "-c", [[
    printf 'mode=%s lang=%s' "$APP_MODE" "$LANG"
]] }, {
    env = {
        APP_MODE = "test",
        LANG = "C",
    },
}))

print(result.stdout)
```

Only supplied keys are replaced. Other variables, including `HOME`, remain
inherited.

<a id="exec-example-cwd"></a>
### Changing the working directory

```lua
local result = assert(babet.exec("find", {
    ".", "-maxdepth", "1", "-type", "f",
}, {
    cwd = "/var/log",
}))

print(result.stdout)
```

The main script's current directory is unchanged.

<a id="exec-example-timeout"></a>
### Bounding execution time

```lua
local result, err = babet.exec("sh", {
    "-c", "printf started; sleep 30",
}, {
    timeout = 1.0,
})
assert(result, err)

if result.timed_out then
    print("command exceeded its budget")
    print("available output:", result.stdout)
end
```

<a id="exec-example-output"></a>
### Bounding captured output

```lua
local result = assert(babet.exec("sh", {
    "-c", "yes log-line | head -n 100000",
}, {
    max_output = 64 * 1024,
}))

if result.stdout_truncated then
    print("only the first 64 KiB were retained")
end
```

For gigabytes, do not capture into memory. Explicitly start a shell and redirect
to a carefully selected file:

```lua
local result = assert(babet.exec("sh", {
    "-c", "my-command > /var/tmp/my-command.log 2>&1",
}, {
    timeout = 600,
}))
```

<a id="exec-example-helper"></a>
### Building an application helper

```lua
local function run_checked(cmd, args, opts)
    local result, err = babet.exec(cmd, args, opts)
    if not result then
        return nil, err
    end
    if result.timed_out then
        return nil, string.format("%s: timeout", cmd)
    end
    if result.code ~= 0 then
        local detail = result.stderr ~= "" and result.stderr or result.stdout
        return nil, string.format(
            "%s: exit code %d: %s",
            cmd,
            result.code,
            detail
        )
    end
    return result
end

local result, err = run_checked("git", { "status", "--short" }, {
    cwd = "/srv/project",
    timeout = 10,
})
assert(result, err)
print(result.stdout)
```

<a id="spawn-overview"></a>
## Streaming processes with `babet.spawn`

`babet.spawn` uses the same secure launch engine as `babet.exec`, but it does
not capture streams automatically and does not wait for completion. It returns
a userdata representing the child process:

```lua
local process, err = babet.spawn("yt-dlp", {
    "--newline",
    "https://example.invalid/video",
})
assert(process, err)
```

The process owns three non-blocking pipes for stdin, stdout, and stderr. The
script decides when to read, write, wait, or terminate the process group. This
API is intended for long-running programs, large outputs, and real-time
progress display.

<a id="spawn-signature"></a>
### Signature and options

```lua
local process, err = babet.spawn(command, args?, opts?)
```

| Element | Type | Default | Purpose |
| --- | --- | --- | --- |
| `command` | strict string | required | program name or path |
| `args` | dense string array | no arguments | `argv[1]..argv[n]` |
| `opts.cwd` | string | inherited directory | child working directory |
| `opts.env` | string-to-string table | inherited environment | variables to add/replace |
| `opts.launch_timeout` | finite number > 0 | unlimited wait | bounds `chdir` + `exec` launch |

Unlike `babet.exec`, unknown options are rejected. `spawn` does not accept
`stdin`, `timeout`, or `max_output`: stdin is sent through `process:write()`,
lifetime is controlled with `wait()`/`terminate()`, and outputs are read
progressively.

`launch_timeout` only covers the launch phase before the new executable is
established. It is not a total process-lifetime limit.

`PATH` lookup, paths containing `/`, environment merging, and shell-free
execution follow the same rules as `exec`.

<a id="spawn-methods"></a>
### Process methods

| Method | Return | Purpose |
| --- | --- | --- |
| `process:read_stdout([max_bytes [, timeout]])` | `(data, nil)` or `(nil, reason)` | read at most `max_bytes` from stdout |
| `process:read_stderr([max_bytes [, timeout]])` | `(data, nil)` or `(nil, reason)` | read at most `max_bytes` from stderr |
| `process:write(data [, timeout])` | `(bytes_written, nil)` or `(nil, reason)` | write part of `data` to stdin |
| `process:close_stdin()` | `(true, nil)` | close stdin idempotently |
| `process:is_running()` | `boolean` or `(nil, err)` | check state without blocking |
| `process:pid()` | integer | return the assigned PID |
| `process:wait([timeout])` | `(result, nil)` or `(nil, reason)` | wait without killing on timeout |
| `process:terminate([grace_period])` | `(result, nil)` or `(nil, err)` | SIGTERM, then SIGKILL if needed |
| `process:kill()` | `(result, nil)` or `(nil, err)` | SIGKILL the process group |
| `process:close()` | `(true, nil)` | clean pipes and any active child |

Short reasons `"timeout"`, `"closed"`, and `"interrupted"` are typed, like
socket errors. Other diagnostics use a `process:` or `spawn:` prefix.

The table returned by `wait`, `terminate`, and `kill` contains:

```lua
{
    code = 0,          -- normal code, or 128 + signal
    exited = true,     -- normal exit/_exit termination
    signaled = false,  -- terminated by a signal
    signal = nil,      -- signal number when signaled == true
}
```

Calling `wait()` again after completion returns the same result because the
status is cached after the first `waitpid`.

<a id="spawn-reading"></a>
### Reading stdout and stderr

Reads are binary-safe. By default they read at most 64 KiB and are
non-blocking (`timeout = 0`). The maximum size per call is 16 MiB.

```lua
local chunk, err = process:read_stdout(64 * 1024, 0.25)

if chunk then
    io.write(chunk)
elseif err == "timeout" then
    -- nothing became available for 250 ms
elseif err == "closed" then
    -- final EOF on stdout
else
    error(err)
end
```

`"closed"` is EOF for that stream, not necessarily process completion. A child
may close stdout and keep working.

Drain both stdout **and** stderr. Reading only one while the other fills can
block the child when the kernel pipe becomes full.

<a id="spawn-writing"></a>
### Writing stdin

`write` accepts a binary Lua string, including NUL bytes. The pipe is
non-blocking, so the call may write only part of the string even after it
became writable. Use the returned byte count to resume at the next byte.

```lua
local function write_all(process, data)
    local offset = 1
    while offset <= #data do
        local written, err = process:write(data:sub(offset), 1)
        assert(written, err)
        offset = offset + written
    end
end

write_all(process, payload)
assert(process:close_stdin())
```

An empty string returns `(0, nil)`. After `close_stdin`, `write` returns
`(nil, "closed")`. Closing stdin is often required for tools such as `cat`,
`sort`, or `ffmpeg` to know the input is complete.

<a id="spawn-lifecycle"></a>
### Waiting, terminating, and closing

`wait()` without an argument waits for process completion. `wait(timeout)`
returns `(nil, "timeout")` when the budget expires without sending a signal or
invalidating the object.

```lua
local result, err = process:wait(0)
if not result and err == "timeout" then
    -- process is still running
end
```

`terminate(grace_period)` sends SIGTERM to the whole group. If the group does
not exit before the grace period ends, Babet sends SIGKILL. The default grace
period is two seconds. `kill()` sends SIGKILL directly.

`close()` is idempotent. If the child is still running, it is terminated and
reaped with bounded waits, then all three pipes are closed. The garbage
collector and Lua `__close` metamethod perform the same cleanup:

```lua
local process <close> = assert(babet.spawn("long-job"))
-- automatic cleanup when leaving the scope
```

Explicit close is still recommended because garbage-collection timing is not
deterministic.

<a id="spawn-example"></a>
### Streaming loop example

```lua
local process, err = babet.spawn("yt-dlp", {
    "--newline",
    "-f", "bestvideo+bestaudio/best",
    url,
})
assert(process, err)

local stdout_open, stderr_open = true, true

while stdout_open or stderr_open do
    if stdout_open then
        local data, read_err = process:read_stdout(64 * 1024, 0.1)
        if data then
            io.write(data)
            io.flush()
        elseif read_err == "closed" then
            stdout_open = false
        elseif read_err ~= "timeout" then
            error(read_err)
        end
    end

    if stderr_open then
        local data, read_err = process:read_stderr(64 * 1024, 0)
        if data then
            io.stderr:write(data)
            io.stderr:flush()
        elseif read_err == "closed" then
            stderr_open = false
        elseif read_err ~= "timeout" then
            error(read_err)
        end
    end
end

local result, wait_err = process:wait(5)
assert(result, wait_err)
process:close()

if result.code ~= 0 then
    error("yt-dlp exited with code " .. result.code)
end
```

<a id="spawn-limits"></a>
### Limits and deadlock prevention

- `wait()` does not drain output. Calling it immediately on a very verbose child
  can block when its pipes fill. Drain both streams while it runs, or use
  `babet.exec` for small automatically captured output.
- Sending large input to a program that simultaneously emits large output
  requires alternating writes and reads. A single `write_all` before any read
  can fill pipes in both directions.
- A `babet.spawn()` object cannot be connected after launch to another process
  object. For a linear pipeline, use `babet.spawnPipeline()` directly.
- stdout and stderr remain separate. Babet does not merge them.
- `close()` and `terminate()` target the process group created at launch. A
  descendant that deliberately changes process group or session may escape,
  just as with `babet.exec`.

<a id="exec-errors"></a>
## Error contract

### Raised Lua errors

Only the first argument's signature raises:

```lua
babet.exec()   -- raises: missing command
babet.exec(42) -- raises: cmd must be a string
```

Use `pcall` only when an invalid signature can come from uncontrolled data.

### Returned `(nil, err)` errors

The following validations return `(nil, err)` rather than raising:

- `args` is neither a table nor `nil`;
- an `args` element is not a string;
- `opts` is neither a table nor `nil`;
- `cwd`, `stdin`, `timeout`, `max_output`, or `env` has the wrong type;
- an environment key is empty, contains `=`, or contains NUL;
- an environment value contains NUL;
- timeout is zero, negative, non-finite, or too large;
- `max_output` is zero, negative, fractional, or above 2 GiB;
- program not found or not executable;
- invalid `cwd`;
- `pipe`, `fork`, `poll`, `waitpid`, or another internal system failure.

```lua
local result, err = babet.exec("echo", "hello")
assert(result == nil)
print(err) -- args must be a table
```

### Situations returning a table

These are not API errors:

- non-zero program exit;
- output written to `stderr`;
- timeout during or after launch;
- output exceeding `max_output`.

<a id="exec-process-security"></a>
## Processes, signals, and security

### Process group

The child creates its own process group. On timeout, Babet signals the group,
not only the direct PID. This normally covers descendants started by a shell or
by the program.

A descendant that deliberately calls `setsid` or changes process group can
escape this strategy. `babet.exec` is not a sandbox and does not replace
systemd, cgroups, namespaces, or resource limits.

### Interaction with `babet.signal`

`babet.exec` is not signal-aware. A handled signal received while the call is
running does not return `(nil, "interrupted")`. The C handler records a pending
flag; the Lua callback can only be dispatched after control returns to the Lua
VM, normally through SIGNAL's instruction hook.

Use `opts.timeout` to bound a long-running command. For externally requested
cancellation, design another protocol or run the command under a supervisor.

### Memory

The script already holds `stdin` in memory, and stdout/stderr are captured in
memory up to the selected limits. The defaults permit about 20 MiB of captured
output in total, in addition to application and Lua-string allocations.

<a id="exec-design"></a>
## Design and limitations

- Linux/POSIX only: the implementation uses `fork`, `execvpe`, `poll`, process
  groups, and signals.
- No implicit shell.
- One `exec` call still represents one command; native pipelines use
  `babet.pipeline()` or `babet.spawnPipeline()`.
- One complete stdin string, no streaming producer.
- Complete capture returned at the end, no line callback.
- No native stdin/stdout/stderr redirection to files or descriptors.
- No separate `signal` field in the result table.
- No full environment replacement or unset operation: `env` merges and an empty
  string remains a defined variable.
- Unknown `opts` fields are ignored.
- Initial `PATH` lookup currently follows the Babet process environment even
  when `opts.env.PATH` is replaced.
- `babet.signal` callbacks are not dispatched during the call.

See [`Security`](../security.md) for the general security model.
