> **English** | [Français](../../fr/modules/sys.md)

# `babet` sys — system utilities

Process and host introspection helpers : PID, hostname, kernel
info, executable lookup, environment variables.

## Why

Lua's standard library has `os.getenv` and `os.execute`, but
nothing for the PID, hostname, kernel info, or a portable `which`.
These are universal scripting needs that don't deserve a roundabout
via `popen` calls.

These functions live directly on `babet` (flat, no sub-table)
because they predate the per-module convention used by recent
additions.

## API

| Function | Returns |
| --- | --- |
| `babet.pid()` | `integer` — current process ID |
| `babet.hostname()` | `string` \| `(nil, err)` — system hostname |
| `babet.uname()` | `table` with `sysname`, `nodename`, `release`, `version`, `machine` |
| `babet.which(cmd)` | `string` (absolute path) \| `(nil, "not found")` |
| `babet.env(name)` | `string` \| `nil` — like `os.getenv`, but consistent |
| `babet.setenv(name, value)` | `(true, nil)` \| `(nil, err)` |
| `babet.getMemoryUsage()` | `integer` — Lua VM memory in bytes (after a full GC) |
| `babet.getDetailedMemoryUsage()` | `(integer, integer)` — currently both equal the GC count in bytes ; kept as two returns for API stability |

## Runtime constants

The same `babet` table also exposes constants describing the
Babet binary that's running the script. Useful for logging,
gating features behind a minimum version, or sanity-checking the
runtime.

| Constant | Type | Example |
| --- | --- | --- |
| `babet.VERSION` | `string` | `"1.7.1"` |
| `babet.VERSION_MAJOR` | `integer` | `1` |
| `babet.VERSION_MINOR` | `integer` | `7` |
| `babet.VERSION_PATCH` | `integer` | `1` |

The string version is what `babet --version` prints. The
integer components are there for programmatic comparison without
parsing the string.

```lua
-- Log the runtime
print("running under Babet " .. babet.VERSION)

-- Gate a feature behind a minimum version
local need_minor = 7
if babet.VERSION_MAJOR < 1
   or (babet.VERSION_MAJOR == 1 and babet.VERSION_MINOR < need_minor) then
    error("this script needs Babet >= 1." .. need_minor)
end
```

## Quick example

```lua
print("Running on:", babet.hostname(), "PID:", babet.pid())

local u = babet.uname()
print("Kernel:", u.sysname, u.release, u.machine)

-- Find a binary
local sh, err = babet.which("bash")
if sh then
    babet.exec({ sh, "-c", "echo hello" })
end

-- Read/write env
print("HOME:", babet.env("HOME"))
babet.setenv("MY_VAR", "value")

-- Memory introspection (forces a full GC first)
print("Lua VM memory:", babet.getMemoryUsage(), "bytes")
local a, b = babet.getDetailedMemoryUsage()
print("Detailed:", a, b)
```

## Error contract

- **`pid()`** : never fails, always returns an integer.
- **`hostname()`** / **`which()`** : `(value, nil)` on success,
  `(nil, err_string)` on failure.
- **`env(name)`** : `value` if set, `nil` if unset. Never raises.
- **`setenv(name, value)`** : `(true, nil)` on success,
  `(nil, err)` on failure (rare — usually OOM or invalid name).
- **`uname()`** : never fails on any supported system, always
  returns the full table.
- **Wrong argument types** (e.g. `which(42)`) → raises via
  `luaL_error` after string coercion as per Lua convention. Pass a
  table or boolean to force a real error.

## Design decisions

- **`env(name)` returns `nil`, not `""`, for unset variables**.
  Matches `os.getenv` semantics. Tests should use
  `env("X") == nil`, not `env("X") == ""`.
- **`which` returns the absolute path**, not just "yes/no". This
  is more useful : you can `exec` the returned path directly. For
  a boolean check, use `which(cmd) ~= nil`.
- **`uname()` returns a table, not multiple values**. Makes it
  forward-compatible if a field is ever added (e.g. `domainname`).
- **`setenv` and workers don't mix** (v21 audit ; rule now
  **enforced by the runtime** since the cross-review). POSIX does
  not synchronize `setenv`/`getenv` across threads : a
  `babet.setenv` while a worker — or the runtime itself (DNS
  resolution, locale, `exec`) — reads the environment is a data
  race. `babet.setenv` (and `babet.chdir` — the working directory
  is also shared process-wide) therefore return `(nil, err)` once a
  `workers.spawn` has happened — permanently, even after `join`,
  even if the spawn later failed. The transition is serialized by
  the same lock as the mutations : no worker can be born during a
  `setenv`/`chdir`. Set environment and working directory
  **before** the first worker.

## Not in v1

Additive — could be added later :

- `unsetenv` (just `setenv(name, nil)` could work too).
- `getuid` / `getgid` / `getppid` / `getlogin`.
- Full environment dump as a table.

For user lookups (UID → name, etc.) see the dedicated
[`user`](user.md) module — that uses NSS, which is the right
backend for that question.
