# Babet 2.16.0 — process states, resume, and asynchronous terminal reclamation

Babet 2.16.0 completes the Linux terminal-lifecycle and limited job-control
audit for interactive processes launched with `babet.spawn()`.

The release adds explicit stopped-state handling and resumes suspended children
without turning Babet into a shell. It also returns the controlling terminal to
the parent as soon as an interactive child exits, even when Lua has not yet
queried or closed the process object.

## Explicit process states

Process handles now expose:

```lua
local state, err = process:state()
```

On success, `state()` returns one of:

- `"running"`;
- `"stopped"`;
- `"exited"`;
- `"closed"`.

`process:is_running()` remains `true` while a child is stopped because it has
not reached final exit.

## `wait()` reports stopped children

`process:wait([timeout])` now observes Linux stopped and continued child states
with `WUNTRACED` and `WCONTINUED`.

When an interactive child is suspended with `Ctrl+Z`, Babet:

1. records the child's terminal attributes;
2. returns the terminal foreground group to the parent;
3. restores the parent's saved `termios` state;
4. returns:

```lua
nil, "stopped"
```

An unbounded `wait()` therefore no longer remains blocked until the child is
continued or terminated.

## Resume a stopped process

A stopped child can be continued with:

```lua
assert(process:resume())
```

For an interactive terminal-backed child, the default behavior restores the
child's saved terminal attributes, gives its process group the foreground, and
then sends `SIGCONT`.

For a pipe-oriented background job:

```lua
assert(process:resume(false))
```

This sends `SIGCONT` without transferring terminal ownership. A background
process that attempts to read the terminal may be stopped again by the kernel.

`resume()` reports stable short reasons such as `"not_stopped"`,
`"not_interactive"`, `"exited"`, and `"closed"` when its preconditions are not
met.

## Asynchronous terminal reclamation after exit

Every interactive terminal handoff now owns a small detached native monitor.
On Linux, the monitor uses `pidfd_open` and `poll()` when available, with
`waitid(P_PID, ..., WEXITED | WNOWAIT)` as a non-reaping fallback.

When the direct child reaches final exit, the monitor restores the parent
foreground process group and saved terminal attributes even if Lua has not yet
called:

- `wait()`;
- `is_running()`;
- `state()`;
- `terminate()`;
- `kill()`;
- `close()`.

The monitor owns a duplicated close-on-exec terminal descriptor, while a
serialized native registry owns the copied restoration state. It never accesses
Lua userdata. Babet does not install a `SIGCHLD` handler for this work, so no
Lua API or non-async-signal-safe terminal operation runs in signal context.

The final child status remains available to the normal `wait()` path and is
cached exactly as before.

Terminal ownership transitions are serialized. If interactive child A exits
and interactive child B is launched before A's detached monitor is scheduled,
Babet detects A's final exit without reaping it, restores the exact saved
parent foreground group and terminal attributes, and then gives the terminal
to B. A's older monitor verifies that A still owns the terminal before doing
anything, so it cannot take the terminal back from B.

The monitor follows the direct child rather than a complete shell job. If the
direct child exits while descendants remain in its process group, Babet still
restores the parent terminal at that point. A descendant that later reads from
the terminal is a background process and may receive `SIGTTIN`. This is part
of the deliberately limited, non-shell job-control contract.

## Stopped-process cleanup

`terminate()` and internal graceful cleanup now send `SIGCONT` after `SIGTERM`
when the target is stopped. This lets a suspended process handle graceful
termination before the existing bounded SIGKILL fallback.

## Scope

Babet deliberately does not implement a full shell job-control layer:

- no jobs table;
- no `fg` or `bg` command model;
- no terminal transfer for `pipeline()` or `spawnPipeline()`.

Pipelines remain pipe-oriented and non-interactive.

Babet remains Linux-only. No macOS or BSD port is planned without target
machines and reproducible validation.

## Validation

The PTY regression now covers:

- direct interactive input;
- bounded waits;
- `Ctrl+C` delivery;
- `Ctrl+Z` stopped-state reporting;
- parent input while the child is stopped;
- foreground resume with restored terminal attributes;
- asynchronous terminal reclamation after child exit before any process query;
- two immediate interactive spawns with the first monitor deliberately delayed;
- ordinary later status refresh and cleanup.

The ordinary Lua suite also covers non-interactive `state()` and
`resume(false)` behavior. The structural process and exception preflight now
audits 182 contracts.

The real Babet → Yaourt → Pacman workflow fixed in Babet 2.15.0 has also been
validated successfully.
