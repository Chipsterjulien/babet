> **English** | [Français](../../fr/modules/exec.md)

# `babet.exec` — run an external program

Spawn a subprocess, capture its stdout / stderr, and get its
exit code back as structured data. Where `os.execute` gives you
just an integer, `babet.exec` gives you a result table with
everything you actually need.

## Why

Almost every non-trivial script eventually shells out — to `git`,
`useradd`, `convert`, `ffmpeg`, whatever. `os.execute` is too
crude (no captured output, shell quoting hazards), and
`io.popen` doesn't let you both write to stdin and read stdout
cleanly, doesn't expose the exit code without parsing, and has
no timeout.

`babet.exec` is the structured alternative : argv passed as a
list (no shell, no quoting bugs), output captured into memory
with a bounded cap, optional timeout, separate stdout/stderr.

## API

```lua
result, err = babet.exec(cmd, args?, opts?)
```

| Argument | Type             | Notes                                                                                |
| -------- | ---------------- | ------------------------------------------------------------------------------------ |
| `cmd`    | string           | Program to run. PATH is searched.                                                    |
| `args`   | table (optional) | Array of string arguments — each one becomes a separate argv slot, no shell parsing. |
| `opts`   | table (optional) | See below.                                                                           |

`opts` fields :

| Field        | Type                       | Default    | Notes                                                                                                                                                                                     |
| ------------ | -------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cwd`        | string                     | inherit    | Working directory for the child.                                                                                                                                                          |
| `env`        | table `{KEY = value, ...}` | inherit    | **Merged** with the parent environment, never replacing it. Override : pass the key. Empty : pass `""` (the child sees it empty). Omitting a key = **inherit** ; there is no unset in v1. |
| `stdin`      | string                     | `""`       | Data sent to the child's stdin.                                                                                                                                                           |
| `timeout`    | number (s)                 | none       | On expiry : **SIGTERM to the whole process group** (clean shutdown possible), 2 s grace, then **SIGKILL**.                                                                                |
| `max_output` | integer (bytes)            | **10 MiB** | Hard cap **per stream** on captured output (upper bound : 2 GiB). Excess is silently dropped and signalled via `*_truncated`.                                                             |

Result table on successful launch :

```lua
{
    stdout = "...",           -- captured stdout, up to max_output bytes
    stderr = "...",           -- captured stderr, up to max_output bytes
    code = 0,                 -- exit code (0..255)
    timed_out = false,        -- true if killed by the timeout
    stdout_truncated = false, -- true if more than max_output was produced
    stderr_truncated = false,
}
```

## Quick examples

```lua
-- Basic capture
local r = assert(babet.exec("git", { "rev-parse", "HEAD" }))
if r.code == 0 then
    print("HEAD:", r.stdout:gsub("\n$", ""))
end

-- Non-zero exit is NOT an error
local r = assert(babet.exec("grep", { "needle", "/etc/passwd" }))
if r.code == 0 then
    print("found:", r.stdout)
elseif r.code == 1 then
    print("not found")
else
    print("grep failed:", r.stderr)
end

-- Pipe data to stdin
local r = assert(babet.exec("sha256sum", { "-" }, {
    stdin = "hello world\n",
}))
print(r.stdout)
-- a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447  -

-- Augment env (not replace)
local r = assert(babet.exec("env", nil, {
    env = { MY_FLAG = "yes" },
}))
-- Child sees MY_FLAG=yes plus everything the parent already had.

-- Timeout + truncation
local r = assert(babet.exec("yes", nil, {
    timeout = 0.5,
    max_output = 1024,
}))
print(r.timed_out, r.stdout_truncated)  -- true   true

-- Different cwd
local r = assert(babet.exec("ls", nil, { cwd = "/var/log" }))
```

## Error contract

- **`(nil, err)`** only if the launch itself fails : program
  not found, `cwd` doesn't exist, fork failed, OOM, etc.
- **`(result, nil)`** for every other case, including :
  - The program ran and exited non-zero → `result.code > 0`.
  - The program was killed by the timeout → `result.timed_out`
    is `true`, `result.code` reflects the signal exit.
  - The program produced more output than `max_output` → the
    relevant `*_truncated` flag is `true`, captured data stops
    at the cap.
- **`opts` validation** : invalid types (`opts.cwd` not a string,
  `opts.env` not a table, `opts.env` keys with `=` or NUL,
  `opts.timeout` ≤ 0 or NaN/Inf, `opts.max_output` non-integer or
  > 2 GiB) → raise via `luaL_error`. These are caller bugs.

## Design decisions

- **Exit code ≠ error**. The most common bug with `os.execute` /
  `exec`-wrappers is treating non-zero exit as an exception.
  Many programs use exit codes for meaningful state (`grep`
  returns 1 when no match, `diff` returns 1 when files differ,
  etc.). The caller decides what counts as failure.
- **No shell**. `args` is an array, each element is one argv
  slot, no quoting needed and no `$(rm -rf $HOME)` surprises.
  If you really want a shell, pass `"sh"` + `{ "-c", "your
  command" }`.
- **`env` merges with parent**. Replacing the full environment
  is rarely what you want and usually breaks programs that
  expect `PATH` or `LANG`. To override one variable, pass it.
  To unset one, pass it as the empty string and the child will
  see it empty (POSIX doesn't have "unset" semantics at exec
  time without extra effort).
- **SIGTERM first, SIGKILL second**. On timeout, the whole
  process group (the child creates its own via `setpgid`) gets
  SIGTERM — well-behaved programs can flush and exit — then
  SIGKILL after a 2 s grace period. `kill(-pid)` also covers
  descendants (a forked `sh -c`, for instance).
- **`max_output` is per stream, not total**. 10 MiB stdout + 10
  MiB stderr is the cap. Large enough to capture most build
  logs, small enough that a runaway subprocess can't OOM the
  Babet process.
- **Hard 2 GiB cap on `max_output`**. Pretty much anything that
  needs more than 2 GiB of captured stdout should redirect to
  a file via `opts.stdin` + a shell wrapper, or via
  `exec("sh", { "-c", "your-cmd > /tmp/log" })`.
- **`stdin` is a string, not a callback**. Streaming gigabytes
  into a child is rare and out of scope ; the common case is
  "feed this small input and read the answer".

## Not in v1

- **Interruption by `babet.signal` while running**. `exec` is not
  signal-aware : a handled signal received while a child runs does
  not return `(nil, "interrupted")` — the callback is dispatched
  after `exec` returns. Use `opts.timeout` to bound long runs.
- Streaming stdout / stderr (line-by-line callback during
  execution). Currently the whole capture is returned at once.
- Stdin streaming (callback that produces input chunks).
- Direct fd redirection (`stdout = "/tmp/log"`). Easy to add
  later if needed ; the shell-wrapper workaround above covers
  most cases.
- Process group management beyond the child. The current
  implementation does correctly tear down the child's process
  group on timeout / interrupt — see [`security`](../security.md).
