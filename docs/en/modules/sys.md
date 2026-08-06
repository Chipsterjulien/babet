> **English** | [Français](../../fr/modules/sys.md)

# SYS - process, host, environment, executables, version, and Lua memory

The functions in this chapter are exposed directly on the global `babet`
table. There is no `babet.sys` subtable: this flat namespace is historical and
is part of the stable API.

SYS covers:

- the identity of the Babet process;
- the hostname and kernel information;
- reading and changing environment variables;
- locating an executable program;
- runtime version constants;
- memory used by the current Lua state.

The current working directory is also process-global state, but `currentDir`
and `chdir` are documented under
[FS - Current working directory](fs.md#fs-cwd), alongside path operations.

## Module contents

- [General conventions](#sys-conventions)
- [API overview](#sys-api-summary)
- [Version constants](#sys-version)
- [Identify the process and host](#sys-process-host)
  - [`pid`](#pid)
  - [`hostname`](#hostname)
  - [`uname`](#uname)
- [Locate an executable](#sys-which)
  - [`PATH` lookup](#which-path)
  - [Direct path](#which-direct)
  - [Missing or non-executable program](#which-errors)
- [Environment variables](#sys-environment)
  - [`env`](#env)
  - [`setenv`](#setenv)
  - [Empty value versus missing variable](#env-empty-unset)
  - [Interaction with workers](#env-workers)
- [Lua VM memory](#sys-memory)
  - [`getMemoryUsage`](#getmemoryusage)
  - [`getDetailedMemoryUsage`](#getdetailedmemoryusage)
  - [What is and is not measured](#memory-scope)
- [Error contract](#sys-errors)
- [Design decisions and limits](#sys-design)

<a id="sys-conventions"></a>
## General conventions

### Flat functions

All functions are called directly from `babet`:

```lua
local pid = babet.pid()
local home = babet.env("HOME")
```

The following forms do not exist:

```lua
-- Incorrect: there is no babet.sys subtable
-- babet.sys.pid()
-- babet.sys.env("HOME")
```

### Strict strings

`env`, `setenv`, and `which` require actual Lua strings. Numbers are not
converted automatically.

```lua
local ok, err = pcall(function()
    return babet.env(42)
end)

-- ok == false; err describes an invalid call
```

An embedded NUL byte is always rejected. This prevents a Lua string from being
silently truncated when passed to a C API.

### Process-global state

The environment and current working directory belong to the **whole process**,
not to a single script or worker.

- `setenv` changes the environment seen by the runtime and future programs
  launched through `babet.exec`;
- `chdir` changes how all relative paths are resolved;
- both mutations are permanently forbidden after the first
  `babet.workers.spawn()`.

This restriction prevents data races between threads.

<a id="sys-api-summary"></a>
## API overview

| Function or constant | Result |
| --- | --- |
| `babet.VERSION` | runtime `major.minor.patch` string |
| `babet.VERSION_MAJOR` | integer major component |
| `babet.VERSION_MINOR` | integer minor component |
| `babet.VERSION_PATCH` | integer patch component |
| `babet.pid()` | process PID as an integer |
| `babet.hostname()` | hostname, or `(nil, err)` |
| `babet.uname()` | system table, or `(nil, err)` |
| `babet.which(name)` | executable path, or `(nil, err)` |
| `babet.env(name)` | variable value, or `nil` when missing |
| `babet.setenv(name, value)` | `(true, nil)` or `(nil, err)` |
| `babet.getMemoryUsage()` | current Lua-state memory in bytes |
| `babet.getDetailedMemoryUsage()` | two currently identical integers |

<a id="sys-version"></a>
## Version constants

The four constants describe the Babet binary running the script.

```lua
print(babet.VERSION)       -- for example "2.18.0"
print(babet.VERSION_MAJOR) -- for example 2
print(babet.VERSION_MINOR) -- for example 15
print(babet.VERSION_PATCH) -- for example 0
```

`babet.VERSION` matches the output of:

```text
babet --version
```

The integer components let code compare versions without parsing a string.

```lua
local function version_at_least(major, minor, patch)
    local current = {
        babet.VERSION_MAJOR,
        babet.VERSION_MINOR,
        babet.VERSION_PATCH,
    }
    local wanted = { major, minor, patch }

    for i = 1, 3 do
        if current[i] ~= wanted[i] then
            return current[i] > wanted[i]
        end
    end
    return true
end

assert(version_at_least(2, 9, 0), "Babet >= 2.9.0 is required")
```

The following consistency is covered by tests:

```lua
assert(babet.VERSION == string.format(
    "%d.%d.%d",
    babet.VERSION_MAJOR,
    babet.VERSION_MINOR,
    babet.VERSION_PATCH
))
```

<a id="sys-process-host"></a>
## Identify the process and host

<a id="pid"></a>
### `babet.pid()`

Returns the Babet process ID as a strictly positive integer. The call cannot
fail on a supported POSIX system.

```lua
local pid = babet.pid()
print("Babet PID:", pid)
```

Workers are threads in the same process. They therefore see the same PID as the
main thread; `pid()` cannot identify an individual worker.

```lua
local main_pid = babet.pid()
local worker = assert(babet.workers.spawn([[
    return babet.pid()
]]))

local joined, worker_pid = worker:join()
assert(joined and worker_pid == main_pid)
```

<a id="hostname"></a>
### `babet.hostname()`

Returns the hostname configured for the machine.

```lua
local host, err = babet.hostname()
assert(host, err)
print("Host:", host)
```

Signature:

```lua
local host, err = babet.hostname()
```

Results:

- success: `host` is a non-empty string and `err` is `nil`;
- system failure: `(nil, "hostname: ...")`.

The hostname is not necessarily a fully qualified DNS name. It may be a short
locally configured name.

<a id="uname"></a>
### `babet.uname()`

Returns the five main POSIX `uname(2)` fields in a table.

```lua
local info, err = babet.uname()
assert(info, err)

print("System :", info.sysname)
print("Node   :", info.nodename)
print("Kernel :", info.release)
print("Version:", info.version)
print("Machine:", info.machine)
```

Returned table:

```lua
{
    sysname  = "Linux",
    nodename = "workstation",
    release  = "6.12.0-arch1-1",
    version  = "#1 SMP PREEMPT_DYNAMIC ...",
    machine  = "x86_64",
}
```

| Field | Meaning |
| --- | --- |
| `sysname` | operating system or kernel name |
| `nodename` | network node name, often close to the hostname |
| `release` | kernel release string |
| `version` | detailed kernel build string |
| `machine` | hardware architecture reported by the kernel |

If `uname(2)` fails, the function returns `(nil, "uname: ...")`. This is very
rare, but it is part of the real contract.

<a id="sys-which"></a>
## Locate an executable

Signature:

```lua
local path, err = babet.which(name)
```

`name` must be a string without an embedded NUL byte.

<a id="which-path"></a>
### `PATH` lookup

When `name` contains no `/`, Babet scans the `PATH` environment variable from
left to right and returns the first candidate that is:

- a regular file;
- executable by the current process.

```lua
local shell, err = babet.which("sh")
assert(shell, err)
print(shell) -- usually /usr/bin/sh or /bin/sh
```

The returned path is normalized to an absolute path whenever the system allows
it.

To perform a simple availability check:

```lua
if babet.which("ffmpeg") then
    print("ffmpeg is available")
end
```

`PATH` is read at call time. A change made with `setenv` before workers is
therefore visible to later calls.

```lua
local old_path = babet.env("PATH")
assert(babet.setenv("PATH", "/opt/my-app/bin:/usr/bin"))
local tool = babet.which("my-tool")
```

An empty `PATH` component, as in `:/usr/bin` or `/bin::/usr/bin`, represents the
current working directory, following the historical Unix convention.

<a id="which-direct"></a>
### Direct path

When the argument contains `/`, `PATH` is not consulted. The path is tested
directly.

```lua
local sh, err = babet.which("/bin/sh")
assert(sh, err)
```

A relative path containing `/` is accepted too:

```lua
local tool, err = babet.which("./bin/my-tool")
assert(tool, err)
```

A valid symlink to an executable regular file is accepted because inspection
follows the target.

<a id="which-errors"></a>
### Missing or non-executable program

When no valid executable is found:

```lua
local path, err = babet.which("missing-program")
-- path == nil
-- err  == "which: 'missing-program' not found in PATH"
```

A file that exists but is not executable is treated as not found:

```lua
local path, err = babet.which("./script-without-x-bit")
assert(path == nil)
print(err)
```

The following are rejected too:

- directories;
- broken symlinks;
- non-regular files;
- files the current process cannot execute.

<a id="sys-environment"></a>
## Environment variables

<a id="env"></a>
### `babet.env(name)`

Reads a process environment variable.

```lua
local home = babet.env("HOME")
if home then
    print("HOME:", home)
end
```

Signature:

```lua
local value = babet.env(name)
```

Results:

- defined variable: its value as a string;
- missing variable: `nil` only, with no error message.

This enables the common idiom:

```lua
local port = babet.env("APP_PORT") or "8080"
```

`name` must be a string. The following forms raise a Lua error:

```lua
-- babet.env()       -- missing argument
-- babet.env(42)     -- no automatic conversion
-- babet.env({})     -- wrong type
-- babet.env("A\0B") -- embedded NUL
```

<a id="setenv"></a>
### `babet.setenv(name, value)`

Creates an environment variable or replaces its existing value.

```lua
local ok, err = babet.setenv("APP_MODE", "production")
assert(ok, err)
assert(babet.env("APP_MODE") == "production")
```

A later call overwrites the value:

```lua
assert(babet.setenv("APP_MODE", "test"))
assert(babet.env("APP_MODE") == "test")
```

`name` and `value` must both be actual Lua strings.

Caller errors, which raise a Lua error:

```lua
-- babet.setenv()
-- babet.setenv("APP_MODE")
-- babet.setenv(42, "test")
-- babet.setenv("APP_MODE", 42)
```

Runtime validation errors return `(nil, err)`:

```lua
local ok, err = babet.setenv("BAD=NAME", "x")
-- ok == nil; err reports an invalid name
```

An empty name, a name containing `=`, or an embedded NUL byte is rejected. A NUL
byte in the value is rejected as well.

<a id="env-empty-unset"></a>
### Empty value versus missing variable

An empty value is still defined:

```lua
assert(babet.setenv("APP_OPTION", ""))
assert(babet.env("APP_OPTION") == "")
```

It is therefore different from a missing variable:

```lua
local value = babet.env("MISSING_VARIABLE")
assert(value == nil)
```

Babet does not currently expose `unsetenv`. A variable cannot be removed with
`setenv(name, nil)`: `nil` is a wrong type and the call raises a Lua error.

<a id="env-workers"></a>
### Interaction with workers

`setenv` is allowed only before the first `workers.spawn()`.

```lua
assert(babet.setenv("APP_MODE", "production"))

local worker = assert(babet.workers.spawn([[
    return babet.env("APP_MODE")
]]))

local joined, value = worker:join()
assert(joined and value == "production")
```

After the first spawn, even when the worker has already finished:

```lua
local ok, err = babet.setenv("APP_MODE", "test")
-- ok == nil
-- err explains that the shared environment can no longer be changed
```

The restriction lasts for the whole process, including when the first spawn
failed. Prepare `PATH`, application variables, and the current directory before
starting workers.

<a id="sys-memory"></a>
## Lua VM memory

Both functions first perform a full Lua garbage-collection cycle. The result
therefore reflects memory still in use after collection, and the call may cause
a pause proportional to the size of the Lua state.

<a id="getmemoryusage"></a>
### `babet.getMemoryUsage()`

Returns the number of bytes currently accounted for by the memory manager of
the current Lua state.

```lua
local bytes = babet.getMemoryUsage()
print(string.format("Lua uses %d bytes", bytes))
```

The result is a positive integer.

Example before/after comparison:

```lua
local before = babet.getMemoryUsage()

local values = {}
for i = 1, 10000 do
    values[i] = string.rep("x", 100)
end

local after = babet.getMemoryUsage()
print("Lua change:", after - before, "bytes")
```

This is not a precise profiling tool: allocator behavior, string interning, and
GC optimizations may change the result.

<a id="getdetailedmemoryusage"></a>
### `babet.getDetailedMemoryUsage()`

Returns two integers:

```lua
local used, total = babet.getDetailedMemoryUsage()
```

In the current version, both values are **strictly identical**:

```lua
assert(used == total)
```

The second return value is kept only for API stability. Lua does not expose a
separate reliable measurement of fragmentation or reserved-but-unused memory.

New code that needs one measurement should prefer:

```lua
local bytes = babet.getMemoryUsage()
```

<a id="memory-scope"></a>
### What is and is not measured

The measurement covers memory managed by **the Lua state performing the call**.

It does not represent:

- total process RSS;
- the native stack;
- C++ runtime allocations;
- OpenSSL, SQLite, HTTP, or socket buffers;
- executable code and shared libraries;
- Lua states belonging to other workers.

Inside a worker, the function measures only that worker's isolated Lua state.
To measure the whole process, use a system facility such as `/proc`, `ps`,
`smem`, Valgrind, or an appropriate profiler.

<a id="sys-errors"></a>
## Error contract

| Situation | Behavior |
| --- | --- |
| missing argument or wrong type | Lua error, recoverable with `pcall` |
| NUL in `env`, `setenv`, or `which` | Lua error for `env`, `(nil, err)` for `setenv` and `which` |
| missing variable in `env` | `nil` only |
| executable not found | `(nil, err)` |
| `hostname` or `uname` system error | `(nil, err)` |
| invalid `setenv` or mutation after a worker | `(nil, err)` |
| `pid` | always an integer |
| memory functions | always one or two integers after a full GC |

An unexpected C++ exception in `which`, `env`, `setenv`, `hostname`, `uname`,
or `pid` is stopped by the shared boundary and becomes
`(nil, "sys: out of memory")`, `(nil, "sys: internal failure")`, or
`(nil, "sys: unknown internal failure")`.

This is an internal safety boundary, not a new expected runtime state. The
ordinary `env` missing-variable result remains one `nil`, and `pid` remains one
integer.

Handling a runtime failure:

```lua
local tool, err = babet.which("optional-tool")
if not tool then
    print("Feature disabled:", err)
end
```

Handling an invalid call:

```lua
local ok, err = pcall(function()
    return babet.env(42)
end)

if not ok then
    print("Programming error:", err)
end
```

<a id="sys-design"></a>
## Design decisions and limits

- Historical functions remain directly under `babet` to avoid breaking
  existing scripts.
- `which` returns the first executable found, not every candidate.
- `which` observes the process `PATH` and current-process permissions; its
  result may differ between users or environments.
- `env` distinguishes a missing variable (`nil`) from a variable defined as an
  empty string (`""`).
- `setenv` always overwrites an existing value.
- No `unsetenv` function or complete environment dump is exposed.
- `pid` is the process PID shared by all workers.
- Memory helpers deliberately run a full GC and do not measure the whole
  process.
- For system accounts, see [User - system users](user.md).
