# Babet 2.18.0 — persistent bounded worker pools

Babet 2.18.0 adds a reusable bounded pool to `babet.workers`, together with
CPU-aware sizing and a non-consuming completion check for existing jobs.

## Persistent worker pool

```lua
local pool = assert(babet.workers.pool({
    size = math.min(4, babet.workers.cpu_count()),
    queue_capacity = 64,
}))

local task = assert(pool:submit([[
    return worker.args.value * 2
]], { value = 21 }))

local ok, result = task:join(2)
assert(ok and result == 42)
assert(pool:join(2))
```

A pool owns a fixed number of pthreads and Lua states. Those workers remain
alive across several submitted tasks instead of rebuilding the complete worker
runtime for every operation.

The pool provides:

- a bounded work queue and a bound on all outstanding tasks;
- monotonic submission, close, task-join, and pool-join timeouts;
- task handles with `done()`, `status()`, `poll()`, and `join()`;
- result demultiplexing by task identifier;
- registry and pending-task accounting kept synchronized throughout submission,
  with atomic rollback when a send fails;
- FIFO graceful shutdown through `pool:close()`;
- retryable timed `pool:join()` calls without double-consuming joined workers;
- cooperative cancellation through `pool:cancel()`;
- optional user channels shared with every task;
- task-local load, runtime, and result-serialization errors.

Each task receives a fresh global environment, so ordinary globals do not leak
between tasks. Libraries and `package.loaded` remain intentionally reused
inside each persistent worker state.

Pool tasks expose:

```lua
worker.args
worker.channels
worker.cancelled()
```

There is no `pthread_cancel()` and no forced termination.

## CPU count and job completion

`babet.workers.cpu_count()` returns the CPU count available to the current Linux
process, preferring its effective CPU affinity and falling back to the online
processor count.

`job:done()` reports whether a regular `workers.spawn()` job has completed
without joining the pthread or consuming its result.

## Validation scope

The 2.18 regression additions cover pool creation, strict options, bounded
backpressure, zero and positive timeouts, task result ordering, errors,
unserializable results, failed-submission rollback, graceful close, automatic
close during join, retry after a join timeout, cooperative cancellation, shared
channels, fresh global environments, and actual Lua-state reuse.

`babet.exec()` now also reuses the common raw dense-array argument parser used
by the other process APIs. Stored arguments are authoritative: `__len` and
`__index` metamethods cannot alter the command line, and sparse or extended
argument tables are rejected consistently.

The same raw-sequence contract now covers the table form of
`babet.joinPath()` and explicit source lists passed to
`babet.archive.create()`. Only values actually stored at indices `1..n` are
read; `__len` and `__index` are never invoked. A global structural preflight
rejects any future `luaL_len()` or `lua_geti()` call in the Lua bindings.

Babet remains focused exclusively on Linux.
