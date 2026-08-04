# Babet 2.15.0 - Lua OOM/RAII audit, worker cancellation, and lazy iteration

Babet 2.15.0 hardens the boundary between Lua allocation failures and C++
resource ownership. It also fixes a worker cancellation deadlock and makes the
filesystem iterator genuinely lazy.

## Lua allocation failures no longer bypass audited RAII owners

Lua is compiled as C in Babet. When an allocating Lua API fails, it may use a
non-local jump rather than a C++ exception, so an ordinary `catch (...)` does
not protect C++ objects that are still alive around `lua_pushlstring`,
`lua_newtable`, or equivalent operations.

2.15.0 introduces two complementary mechanisms:

- result emitters run under `lua_pcall`; after `LUA_ERRMEM`, an allocation-free
  C++ marker unwinds every binding-owned RAII object before the original Lua
  error is re-raised;
- native state that must remain alive until Lua copies the result is attached
  to a temporary userdata with a cleanup path owned by Lua.

The audit covers JSON, TOML, HTTP, Archive, Socket, SQLite, Workers, Base64,
CRC32, MD5, SHA-1, SHA-2, SHA-3, and BLAKE2 result construction. The protected
TOML snapshot now dispatches from the exact parsed node kind instead of using
`value<T>()` as a discriminator, preserving booleans inside scalar values,
quoted dotted keys, heterogeneous arrays, and nested sections. Ordinary API
contracts and expected `(nil, err)` results are unchanged.

The final audit pass also covers every public `spawn` process and pipeline
registration. Process/pipeline userdata allocation and status/result tables now
use the protected builder, while their finalizer cleanup is allocation-free and
enters through silent `noexcept` boundaries. Socket and Worker userdata carry an
explicit constructed flag, preventing a placement-new failure from exposing an
unconstructed object to `__gc`. Channel, Worker, HTTP request-state, and
FileIterator finalizers are now guarded consistently. The Signal API and
`json.as_array` remain direct by design because they keep no non-trivial C++
owner alive across an allocating Lua call.

The final hardening pass also replaces the last fifteen direct `push_fail()`
builders in Archive and Socket with protected result construction. `Sock`
default construction is now guarded by a compile-time `noexcept` contract
because it runs inside a `noexcept` protected builder. Worker construction may
legitimately allocate through its queues and strings, so it remains behind the
C++/Lua exception boundary with `constructed == false` until completion; its
Lua finalizer instead enforces a compile-time non-throwing destruction contract.

A dedicated test uses a failing Lua allocator instead of a simulated C++
exception. It verifies destruction of stack RAII owners, cleanup of Lua-owned
userdata, and the real `exec`, `listFiles`, and `deepCopyTable` paths under
allocator failure. The closing audit also protects `exec`, `find`, `listFiles`,
`deepCopyTable`, SYS, Compression, and Inotify result construction. Native
filesystem traversal is completed before Lua table emission, the source table
is explicitly forwarded into `deepCopyTable`'s protected call frame, registry
references are released on every path, and all historical flat registrations
enter through a shared C++ boundary. The protected parser runner forwards the
complete original Lua argument frame with unchanged indices, preserving
`exec`, `find`, Compression, and `joinPath` behavior while guarding their C++
outputs. Archive source/options parsing and `user.get` passwd-table emission
are protected as well. Main-runtime and worker-runtime setup now run under
`lua_pcall`, so an allocation failure becomes a normal startup or worker error
instead of a Lua panic.

Worker channel handles now use explicit constructed-state userdata too: `__gc`
is armed before the `shared_ptr` starts its lifetime, and ownership is copied
only after construction has committed. The structural preflight now checks 161
audited contracts and rejects any direct `push_fail()` or
`push_action_result()` builder in binding sources.

## Cleaner GCC 16 / C++23 builds

The vendored `toml++` 3.4.0 header still declares its user-defined literals
with the pre-C++23 spacing accepted by older compilers. Its include directory
is now marked `SYSTEM` in CMake, so GCC 16 no longer emits third-party
`-Wdeprecated-literal-operator` warnings. Babet's own warning diagnostics are
not disabled.

## Worker cancellation cannot deadlock on a full outbox

Previously, this sequence could wait forever:

1. a worker filled its outbox;
2. another `worker.send()` blocked waiting for space;
3. the parent called `cancel()` and then `join()`.

Cancellation now wakes the outbox wait. If space already exists, the worker may
still publish one final diagnostic. If the send would remain blocked, it
returns `(false, "cancelled")`. Messages already queued remain drainable, and
cancellation remains cooperative - Babet still does not use `pthread_cancel()`.

A deterministic capacity-one regression proves the blocked second send exits,
the bounded join completes, and the first message remains available.

## `createFileIterator` is now truly lazy

The old implementation traversed the complete tree at construction and stored
every path in a vector. The userdata now owns the native directory iterator and
advances only on `next()`.

`iterator:next()` returns:

- `(path, nil)` for a regular-file entry;
- `(nil, err)` for a deferred inspection or traversal error;
- `(nil, nil)` at normal end.

Existing code that reads only the first return value stays compatible, while
new code can distinguish an error from end of iteration. Large trees no longer
need memory proportional to the total number of files before the first result.

## Interactive-spawn diagnostic status

The 2.14 terminal engine is unchanged in this release. Direct PTY coverage and
an optional controlled `sudo` layer do not reproduce another foreground-group
failure. The test now prints the canonical executable path and SHA-256, which
makes stale copied or embedded runtimes visible.

A real yaourt-to-pacman interactive block has nevertheless been reported and
remains open. Babet 2.15.0 deliberately does not claim that nested wrapper case
as fixed until a red reproducer identifies the process group that actually owns
the terminal.

## Validation

Run the complete release campaign on the exact source tree:

```sh
./run_tests.sh --release
```

It now includes the allocator-driven OOM/RAII test and the expanded PTY
identity diagnostics before the normal folder, embedded, embedded-via-PATH,
and network checks.

Dependency versions and the Linux-only platform scope are unchanged from
2.14.0.
