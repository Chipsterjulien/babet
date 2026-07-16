# Notes - known deferred work

This file lists known topics intentionally left outside Babet 2.6.0. They are
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

## 5. Standalone compressed streams

**Current state**: Babet 2.6.0 creates, lists, extracts, and selectively extracts
ZIP archives plus plain, gzip-, xz-, bzip2-, and zstd-compressed TAR archives.
Archive readers detect format and compression from the contents. TAR operations
use the statically linked libarchive stack and retain the bounded, pinned-source,
confined-destination, atomic-publication, and worker guarantees documented by
`babet.archive`.

**Deliberate boundary**: standalone `.gz`, `.xz`, `.bz2`, and `.zst` streams
that contain one raw payload rather than a TAR archive are not accepted by the
public archive API.

**Why deferred**: a raw compressed stream has no portable entry name or archive
metadata and therefore needs a separate API contract for destination naming,
limits, overwrite behavior, result metadata, and concatenated-member handling.
Silently treating it as a one-entry archive would make those decisions implicit.

## 6. Archive creation from lists and exclusion rules

**Current state**: `babet.archive.create(source_directory, archive, opts)` walks
one real source directory through pinned descriptors, refuses source symlinks
and unsupported filesystem objects, orders entries deterministically, and
publishes the completed archive atomically.

**Deliberate boundary**: 2.6.0 does not accept an arbitrary list of unrelated
source paths and does not expose include/exclude pattern rules.

**Why deferred**: lists and exclusions require a stable policy for archive root
names, collisions, paths outside a common root, symlinks, empty directories,
and interaction with deterministic ordering. The directory API already covers
the intended release use cases without adding an ambiguous second creation
model.

## 7. Linear-time or otherwise bounded pattern matching

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

## 8. Shared strict Lua argument validators

**Current state**: 2.6.0 provides shared allocation-free helpers for exact and
bounded arity, strict Lua strings, numbers, integers and booleans, optional
`nil`, and strings passed to NUL-terminated native APIs. Public bindings use
those helpers to avoid accidental number-to-string coercion and silent numeric
truncation while retaining their documented error contracts.

**Maintenance rule**: future bindings should validate with the shared helpers
before conversion and should avoid `luaL_error` while non-trivial C++ objects
that require destruction are alive.

## Validation note

Valgrind is not a release requirement. Babet 2.6.0 is validated with ASan and
UBSan, followed by a clean normal rebuild and network smoke tests through:

```sh
./run_tests.sh --release
```
