# Babet 2.14.0 — Exception boundaries and interactive spawn

Babet 2.14.0 hardens the four remaining public binding modules and fixes
interactive terminal ownership in `babet.spawn`, without adding or removing any
Lua API.

## Seventeen protected registrations

Every Lua C function registered by these modules now enters through an audited
C++ exception boundary:

- `babet.compression`: `compress`, `decompress`;
- flat SYS API: `which`, `env`, `setenv`, `hostname`, `uname`, `pid`;
- `babet.user`: `get`, `exists`;
- `babet.inotify`: `new`, `add`, `read`, `remove`, `close`, `__tostring`, and
  the non-throwing `__gc` cleanup path.

Lua 5.5 is compiled as C inside Babet. A C++ exception crossing those C frames
would be undefined behaviour. The new shared core classifies failures before
they reach Lua:

- `std::bad_alloc` becomes `(nil, "<module>: out of memory")`;
- another `std::exception` becomes `(nil, "<module>: internal failure")`;
- an unknown exception becomes `(nil, "<module>: unknown internal failure")`.

The caught C++ exception is destroyed before Babet asks Lua to push that
diagnostic. This avoids a Lua allocation failure leaving an active C++
exception handler through a long jump.

This boundary addresses C++ exceptions crossing Lua's C frames. A separate
2.15.0 audit will examine Lua allocation failures while binding-owned C++ RAII
objects are still alive; that broader `longjmp` concern is not claimed as
solved by this release.

The inotify garbage collector uses a dedicated catch-all boundary and returns
no diagnostic, because a `__gc` cleanup path must not allocate while handling
an exception.

## Interactive `babet.spawn` terminal handoff

A child launched in its own process group could display through inherited
streams but could not read from the terminal: the kernel treated it as a
background group and stopped it with `SIGTTIN`. This was visible with nested
interactive commands such as a Lua frontend launching `pacman`.

When inherited stdin is Babet's controlling terminal and Babet owns the
foreground, 2.14.0 now:

- keeps the child in its separate process group, preserving descendant-wide
  `terminate()`, `kill()`, and `close()` behavior;
- waits until that group exists, transfers the foreground terminal with
  `tcsetpgrp()`, and only then releases the child through a `CLOEXEC`
  synchronization pipe;
- blocks `SIGTTOU` only around foreground-group changes;
- saves the original terminal attributes and restores both the foreground
  group and `termios` state after normal exit, signals, explicit cleanup, or a
  launch failure;
- leaves captured streams and inherited non-terminal stdin unchanged.

Terminal-generated `Ctrl+C` is delivered to the foreground child group and the
existing result convention remains intact (`code = 130`, `signal = 2`).

Babet 2.14.0 intentionally does not implement full shell job control. A child
suspended with `Ctrl+Z` remains stopped in the foreground until the script
resumes or terminates it, and terminal reclamation occurs when Babet observes
child completion through the process object rather than asynchronously. The
FR/EN references document the bounded cleanup pattern and clarify that
`spawnPipeline()` remains a non-interactive pipe API.

## Existing contracts preserved

Ordinary calls behave exactly as in 2.13.0:

- invalid argument count or type still follows the documented Lua-error path;
- expected runtime failures still return their existing `(nil, err)` values;
- compression keeps atomic publication and removes unpublished temporary files
  through RAII;
- inotify keeps timeout and signal-interruption results;
- `user.exists` still returns a strict boolean for normal NSS outcomes;
- SYS environment mutation remains forbidden after the first worker starts.

Only an unexpected C++ failure uses the new stable module diagnostic.

## Tests

The release adds the exception-boundary preflight plus a real PTY regression
for `babet.spawn`:

- the PTY scenario performs one read in the Lua parent, a second read in an
  inherited-stream child, verifies that `wait(timeout)` leaves that child able
  to continue, sends `Ctrl+C` to another child, checks code 130, suspends a
  child with `Ctrl+Z` and recovers through bounded `kill()`, verifies
  restoration after `is_running()` observes an already-finished child,
  deliberately changes terminal echo, and checks that Babet restores it;
- every PTY run has a hard deadline so a `SIGTTIN` regression cannot block the
  remaining suite.

The exception-boundary preflight keeps two complementary checks:

- a standalone C++ executable exercises normal completion,
  `std::bad_alloc`, another standard exception, and an unknown exception, and
  verifies that reporting starts only after the active catch has been cleared;
- a structural sweep requires all 17 registrations to use the new boundaries
  and rejects every previous direct registration.

No fault-injection hook is compiled into the Babet production binary. Existing
functional tests continue to verify all ordinary module contracts in folder,
embedded, and embedded-via-`PATH` modes.

Dependencies and the Linux-only platform scope are unchanged from 2.13.0.
