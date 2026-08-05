# Notes - known deferred work

This file lists known topics intentionally left outside the current Babet
development roadmap. They are not hidden defects: each item records the current
behavior, the remaining risk, and the reason it is deferred.

## 1. Resolve PATH in the parent and use only `execve`

**Current state**: `exec.cpp` uses glibc `execvpe()` after `fork()`. Arguments,
environment storage, pipes, and most launch preparation are built in the parent.

**Remaining theoretical risk**: `execvpe()` resolves `$PATH` in the child and
reads the process environment. On glibc this is a simple lookup and no concrete
failure has been observed, but `getenv` is not formally listed as
async-signal-safe by POSIX.

**Possible hardening**: resolve the executable path in the parent, then call
`execve(path, argv, envp)` in the child.

**Why deferred**: the demonstrated multithreaded hazards were removed. The
remaining concern is theoretical on the supported Linux/glibc target and does
not justify another path-resolution implementation without a real use case.

## 2. Forced worker termination

**Current state**: there is no `worker:kill()`. A worker stops cooperatively
through `job:cancel()` / `worker.cancelled()`, after `close()` wakes its inbox,
or after a bounded operation returns. Cancellation also wakes a channel wait
owned by that worker without closing the shared channel for other participants.

**Limitation**: a worker blocked forever in an external operation without a
timeout cannot be safely stopped from another thread. Garbage collection or a
join can then wait for it.

**Why no `pthread_cancel`**: asynchronous thread cancellation can strand
mutexes, file descriptors, Lua state, and OpenSSL objects in inconsistent
states. A safe design would require explicit cancellation points throughout the
runtime.

**Mitigation**: use bounded socket/process operations, call `job:cancel()`, and
make worker loops check `worker.cancelled()` or return to cancellation-aware
`worker.recv()` / channel operations when they must remain externally stoppable.

## 3. Linear-time or otherwise bounded pattern matching

**Current state**: `babet.find()` offers bounded `glob`, `iglob`, `path_glob`,
and `path_iglob` filters implemented by a small non-recursive matcher with a
polynomial runtime bound and a 4096-byte pattern ceiling. The historical
`name`, `iname`, and `path` fields are backed by RE2 instead of `std::regex`.
They keep their full-match/full-match/partial-search behaviour, use Latin-1 byte
mode for Linux paths, reject patterns above 4096 bytes, and assign a 1 MiB
memory budget to each compiled expression.

RE2 intentionally does not implement constructs whose matching cost cannot be
kept linear, notably backreferences and look-around assertions. Scripts that
need only wildcard filename filtering should prefer the simpler glob fields.

## 4. Shared strict Lua argument validators

**Current state**: since 2.6.0, Babet provides shared allocation-free helpers for exact and
bounded arity, strict Lua strings, numbers, integers and booleans, optional
`nil`, and strings passed to NUL-terminated native APIs. Public bindings use
those helpers to avoid accidental number-to-string coercion and silent numeric
truncation while retaining their documented error contracts.

**Maintenance rule**: future bindings should validate with the shared helpers
before conversion and should avoid `luaL_error` while non-trivial C++ objects
that require destruction are alive.

## Platform scope

Babet is intentionally a Linux/glibc project. macOS and BSD ports are not part
of the roadmap while no target machines and maintainers are available to build,
run, and validate them. Platform-specific code must therefore remain explicit
rather than introducing untested portability abstractions.

## Direct-child terminal monitor scope

The asynchronous terminal monitor follows the direct child created by
`babet.spawn()`, not an arbitrary shell job tree. When that direct child exits,
Babet restores the parent foreground group and terminal attributes even if
descendants remain in the child's process group. A remaining descendant that
later attempts terminal input is then a background process and may receive
`SIGTTIN`.

This is an intentional boundary rather than an unfinished shell feature:
Babet does not maintain a jobs table, track arbitrary process-group membership,
or wait for an entire shell job before returning terminal ownership.

## Validation note

Valgrind is not a release requirement. Babet release candidates are validated
with ASan and UBSan, followed by a clean normal rebuild and network smoke tests
through:

```sh
./run_tests.sh --release
```
