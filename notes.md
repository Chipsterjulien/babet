# Notes - known deferred work

This file lists known topics intentionally left outside Babet 2.4.0. They are
not hidden defects: each item records the current behavior, the remaining risk,
and the reason it was not included in the release.

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

## 2. Independent worker-to-worker channels

**Current state**: workers expose parent-to-worker and worker-to-parent queues.
Two workers communicate through the parent.

**Limitation**: parent-mediated routing can become a bottleneck for complex
pipelines or pub/sub topologies.

**Possible extension**: add `workers.channel()` and pass channel handles to
multiple workers.

**Why deferred**: the current design covers the intended scripting, bot, and
parallel-job use cases. A new synchronization primitive should be driven by a
concrete application rather than speculative API growth.

## 3. Forced worker termination

**Current state**: there is no `worker:kill()`. A worker stops cooperatively,
usually after `close()` wakes its inbox or after an operation with a timeout
returns.

**Limitation**: a worker blocked forever in an external operation without a
timeout cannot be safely stopped from another thread. Garbage collection or a
join can then wait for it.

**Why no `pthread_cancel`**: asynchronous thread cancellation can strand
mutexes, file descriptors, Lua state, and OpenSSL objects in inconsistent
states. A safe design would require explicit cancellation points throughout the
runtime.

**Mitigation**: use bounded socket/process operations and make worker loops poll
or receive with timeouts when they must remain externally stoppable.

## 4. macOS and BSD portability

**Current state**: Babet targets Linux/glibc. It uses Linux facilities such as
inotify, `/proc/self/exe`, `accept4`, and `SOCK_CLOEXEC`.

**Impact**: compilation or runtime behavior is not supported on macOS or BSD.

**Possible work**: provide portability helpers for close-on-exec sockets,
replace inotify, abstract executable-path discovery, and add tested CI targets.

**Why deferred**: no supported user or contributor currently requires those
platforms. A portability patch should be tested on the target OS rather than
written blind.

## 5. Archive convenience bindings

**Current state**: Babet internally reads and writes ZIP data for embedded
executables, but does not expose general-purpose Lua `zip`, `unzip`, `tar`, or
`untar` helpers.

**Why deferred**: archive extraction has a large security surface (path
traversal, symlinks, permissions, resource limits). A public API needs its own
threat model and test campaign instead of reusing the embedded-package code
without review.

## Validation note

Valgrind is not a release requirement. Babet 2.4.0 is validated with ASan and
UBSan, followed by a clean normal rebuild and network smoke tests through:

```sh
./run_tests.sh --release
```
