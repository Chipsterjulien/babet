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

## 3. macOS and BSD portability

**Current state**: Babet targets Linux/glibc. It uses Linux facilities such as
inotify, `/proc/self/exe`, `accept4`, and `SOCK_CLOEXEC`.

**Impact**: compilation or runtime behavior is not supported on macOS or BSD.

**Possible work**: provide portability helpers for close-on-exec sockets,
replace inotify, abstract executable-path discovery, and add tested CI targets.

**Why deferred**: no supported user or contributor currently requires those
platforms. A portability patch should be tested on the target OS rather than
written blind.

## 4. Linear-time or otherwise bounded pattern matching

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

## 5. Shared strict Lua argument validators

**Current state**: since 2.6.0, Babet provides shared allocation-free helpers for exact and
bounded arity, strict Lua strings, numbers, integers and booleans, optional
`nil`, and strings passed to NUL-terminated native APIs. Public bindings use
those helpers to avoid accidental number-to-string coercion and silent numeric
truncation while retaining their documented error contracts.

**Maintenance rule**: future bindings should validate with the shared helpers
before conversion and should avoid `luaL_error` while non-trivial C++ objects
that require destruction are alive.

## 6. Bounded in-memory archive entry reads

**Current state**: `babet.archive.extractFile()` securely selects one regular
entry and publishes it atomically to a caller-chosen destination.
`babet.archive.list()` and `babet.archive.test()` cover metadata inspection and
full validation without extraction.

**Possible extension**: add `babet.archive.read(archive, entry [, opts])` to
return a small regular entry as a binary Lua string under a strict default and
hard `max_size` ceiling. It would need duplicate-name refusal, the same whole-
archive limits, ZIP/TAR parity, worker support, and a precisely documented
allocation failure contract.

**Why deferred**: the 2.8.0 inspection, testing, selective extraction, and
`dry_run` goals are complete without loading archive contents into Lua memory.
A new API should be driven by a concrete manifest/configuration use case rather
than added speculatively at the end of an audited release.

## Validation note

Valgrind is not a release requirement. Babet release candidates are validated
with ASan and UBSan, followed by a clean normal rebuild and network smoke tests
through:

```sh
./run_tests.sh --release
```
