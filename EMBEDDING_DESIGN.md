# Babet embedding design contract — Lots 6–11

For practical usage, build commands and executable examples, see [`EMBEDDING.md`](EMBEDDING.md) / [`EMBEDDING.fr.md`](EMBEDDING.fr.md). The Lua -> host callback contract added in Lot 10 is detailed separately in [`HOST_FUNCTIONS_DESIGN.md`](HOST_FUNCTIONS_DESIGN.md).

This document defines the first exercised host-facing embedding boundary for
Babet.  It is intentionally narrower than a general plugin ABI or a full Lua/C
marshalling layer.

## 1. Goal

The initial supported path is:

```text
C or C++ host
    -> experimental C header `babet/babet.h`
    -> static `libbabet.a`
    -> the same Babet/Lua runtime used by the official CLI
```

The official `babet` executable remains autonomous.  It may reuse the same
static runtime archive at link time, but it must not acquire a runtime
`libbabet.so` dependency.

## 2. Why static first

Babet's third-party dependencies are deliberately pinned and mostly linked as
static archives.  They are not yet built under a documented PIC contract, so
forcing a shared `libbabet.so` now would widen Lot 6 into a rebuild-policy and
shared-library deployment project before the host API has even been exercised.

The first embedding artifact is therefore `libbabet.a`.  This is a deliberate
staging decision, not a promise that the final embedding library can never be
shared.  A `.so` is reconsidered only after the C API has proved useful and the
PIC/dependency cost is known.

This first archive is an **in-tree development artifact**, not yet a standalone
SDK bundle: Babet/miniz/SQLite objects live in `libbabet.a`, while the CMake
target carries the remaining pinned static link dependencies to the host smoke
target.  Export/install metadata or a self-contained developer package is a
separate follow-up once the API shape has survived real use.

## 3. Public boundary

The host-facing surface is C, even when Babet itself is implemented in C++23.
The public header exposes:

- an opaque `babet_context`;
- `babet_status` values;
- `babet_version()`;
- `babet_status_name()`;
- `babet_context_create()`;
- `babet_context_set_search_root()`;
- `babet_context_run()`;
- the scalar `babet_value` tagged union;
- `babet_context_set_global()` / `babet_context_get_global()`;
- `babet_context_call_global()` for scalar arguments and one scalar result;
- opaque `babet_host_call` plus `babet_host_function`;
- `babet_context_register_host_function()` and the host-call scalar/result/error helpers;
- `babet_context_last_error()`;
- `babet_context_destroy()`.

No `lua_State`, STL type, exception, ncurses handle, process-internal type or C++
class crosses the public header.

`babet_status` and `babet_value_type` are fixed-width `uint32_t` ABI tags, not
C/C++ enum objects. Unknown numeric values therefore remain representable at
the C boundary and can be rejected explicitly without triggering C++ enum UB
under UBSan; the named constants remain the only supported values. The tradeoff
is deliberate: the two tag families have the same C integer representation, so
C++ no longer rejects an accidental assignment from one family to the other at
compile time, and `-Wswitch` cannot diagnose a newly added public constant. ABI
v1 therefore freezes every existing numeric value with compile-time assertions,
and the embedding structural preflight derives both public constant sets from
`babet.h` and requires exhaustive validators/names/converters to cover them. A
new tag cannot pass release validation until those handlers are updated.

This API remains **experimental through Lot 10**. Exercising each added slice
with real C/C++ hosts is required before treating the ABI as frozen.

## 4. First-context lifecycle

The first implementation supports exactly one live embedded context per
process.  The context is created, used and destroyed by one host thread.

Reasons are architectural rather than arbitrary:

- Babet's registered "main thread" identity is process-wide;
- POSIX signal dispositions are process-wide;
- interactive terminal ownership is process-wide;
- workers inherit process-wide execution context and environment policy.

A second simultaneous context returns `BABET_STATUS_BUSY`.  Running or
destroying a context from another thread returns `BABET_STATUS_WRONG_THREAD`.
Sequential recreation after destruction is supported.

Multiple independent contexts may be studied later only if a real host use case
justifies redesigning those process-wide contracts.

## 5. Runtime initialization

`babet_context_create()` creates a fresh Lua state and installs the same core
runtime surface as the CLI:

1. Lua standard libraries;
2. bundled `package.preload` modules (`inspect`, `argparse`, `logging`, ...);
3. the complete public `babet` table and userdata metatables.

An embedded context starts without an on-disk project directory. The host may
configure exactly one explicit module search root with
`babet_context_set_search_root()` before its first Lua execution call
(`babet_context_run()` or `babet_context_call_global()`). The
root is resolved to an absolute path at configuration time and prepended with
the same `?.lua` / `?/init.lua` `package.path` semantics as Babet folder mode.
The same absolute root is propagated to workers, so a module required by the
main embedded state is also visible to workers created from that context.

The one-shot, before-first-run rule is deliberate in the first API: worker
initialization context is process-wide, so changing it after arbitrary Lua has
started could race a worker or make parent/worker module resolution diverge.
Roots containing `;` or `?` are rejected because those characters are syntax in
Lua `package.path`; this first slice does not invent a second file searcher just
to escape them.
Missing paths and paths that resolve to a non-directory are host input errors and
return `BABET_STATUS_INVALID_ARGUMENT`; filesystem inspection failures that do
not simply mean “missing/not a directory” remain `BABET_STATUS_INTERNAL_ERROR`.

## 6. Execution and errors

`babet_context_run()` executes one text Lua chunk and discards returned Lua
values. Chunk execution therefore remains stack-neutral.

The first host/Lua value exchange is intentionally narrower than general
marshalling. `babet_context_set_global()` and `babet_context_get_global()` move
only five scalar types through the main embedded state's global table:

- nil;
- boolean;
- signed 64-bit integer;
- double;
- byte string with an explicit length, including embedded NUL bytes.

Tables, functions, userdata and threads are not stringified or traversed; reads
of those values return `BABET_STATUS_UNSUPPORTED_VALUE`. A string returned to
the host is copied into context-owned storage and remains valid until the next
mutating context call or destruction. `set_global()` copies a string input
before invalidating that borrowed storage, so a just-read byte string can be
round-tripped safely through the same context.

This scalar-global slice applies only to the main embedded Lua state and does not implicitly copy globals into workers: worker isolation and their existing
argument/result serialization remain unchanged.

The next exercised scalar slice adds `babet_context_call_global()`. It looks up
one function directly in the main Lua global table, copies zero or more
`babet_value` scalar arguments into protected call storage, invokes the function
under a Lua protected boundary and requests exactly one result. A function that
returns no values therefore yields `nil`; extra Lua results are discarded. The
result uses the same scalar conversion and context-owned binary-string storage
as `get_global()`. A missing/non-function global or a Lua exception returns
`BABET_STATUS_LUA_ERROR`; tables/functions/userdata/threads returned as the
selected result return `BABET_STATUS_UNSUPPORTED_VALUE`. Calling Lua counts as
execution for the one-shot module-root lifecycle. The first API deliberately does not resolve dotted method paths, expose Lua
functions as handles or accept structured table arguments. Lot 10 adds the
separate reverse direction through `babet_context_register_host_function()`:
registered callbacks appear as `babet.host.<name>`, receive only the same five
scalar kinds, and return nil or one scalar through an opaque `babet_host_call`.
String callback results and diagnostics are copied immediately into Babet-owned
storage. Host callbacks are synchronous on the context owner thread, are not
installed into worker states, and may not re-enter the public context API; such
attempts return `BABET_STATUS_REENTRANT_CALL`. Full lifetime/error rationale is
kept in `HOST_FUNCTIONS_DESIGN.md`.

Errors are returned as `babet_status`; detailed Lua diagnostics remain owned by
the context and are exposed through `babet_context_last_error()`. The pointer
is valid until the next mutating context call or destruction. A non-OK host
callback status becomes a Lua error; an uncaught host-function failure therefore
reaches the outer embedding call as `BABET_STATUS_LUA_ERROR` with the copied host
diagnostic.

No C++ exception may cross any C API function or host callback boundary.

A Lua error must leave the context reusable by a later successful call.

## 7. Process-wide side effects are not sandboxed

Embedding does not turn Babet into a VM sandbox. APIs whose documented meaning
is process-wide remain process-wide for the host process as well: current
directory changes, environment mutation, signal dispositions, child processes
and terminal ownership are real host-process effects.

The first slice does not attempt automatic rollback of arbitrary `chdir`,
`setenv` or `babet.signal` changes on context destruction. A host that uses such
APIs owns that policy (for example, restoring a signal disposition before
destroying the context). Automatic session rollback can be studied separately
if real embedding use shows it is needed.

## 8. Cleanup and terminal ownership

Embedding destruction uses the same terminal-aware close path as the CLI:

1. run Lua finalizers first so process userdata can release/reclaim interactive
   terminal state;
2. service deferred curses terminal events on the registered host thread;
3. finish curses cleanup only after the terminal registry is safe.

The embedding API must not introduce a second terminal manager.

## 9. Internal split justified by embedding

Lot 6 permits one targeted internal refactor: move `register_babet()` and the
shared terminal-aware Lua close helper out of `main.cpp` into reusable runtime
code.

This split is required because workers, the CLI and the embedding API need the
same registration/teardown implementation.  No broader CLI/runtime/builder
layering is performed unless a later embedding feature proves it necessary.

## 10. Build shape and relocatable SDK

CMake builds:

- the in-tree `libbabet.a` from runtime/binding/project-core sources plus
  miniz/SQLite implementation objects, with the CMake target propagating the
  remaining pinned static link dependencies;
- the official `babet` executable by statically linking that archive;
- an `EXCLUDE_FROM_ALL` C smoke host used only by the embedding regression.

After a normal build, `build_local.sh` also creates a relocatable static SDK in
`build/embedding-sdk/`. Its public surface is intentionally tiny:

- `include/babet/babet.h`;
- one flattened `libbabet.a` under `lib/` containing the Babet runtime plus the
  pinned static Lua, ncursesw, OpenSSL, libarchive, zlib, liblzma, libbz2,
  libzstd, RE2 and Abseil archives;
- a short `README.txt` documenting the final host link boundary;
- the embedding/host-function design documents and executable C examples.

The flattening step stages every archive under a space-free temporary name
before using `ar` MRI mode, so a checkout or SDK path containing spaces cannot
change the result. The SDK is a normal-build artifact only: ASan/UBSan builds
exercise the instrumented in-tree library but are not presented as a
redistributable SDK.

A C source can compile against the public header, but the final executable must
use a C++ linker driver because Babet itself is implemented in C++. On Linux the
remaining host-side system link boundary is `-ldl -pthread -lm` (plus `-latomic`
on 32-bit targets). No pinned Babet third-party archive path is required by the
external host.

The runtime regression copies this SDK to a new path containing spaces, copies a
small C host outside the source tree, compiles it only against the moved SDK and
runs it. This verifies that the standalone package does not accidentally depend
on CMake target propagation or build-tree archive locations.

The primary in-tree smoke host is written as C, not C++, to prove that the public
header is a real C boundary. It exercises:

- version/status access;
- context creation;
- rejection of a second simultaneous context;
- real `babet.base64`, `babet.json` and bundled-module use;
- an explicit host module search root used by both the parent state and a worker;
- a Babet worker created from the embedded runtime;
- scalar global exchange in both directions, including binary strings;
- a direct global Lua function call with all scalar argument kinds and one
  scalar result, plus bad-target/error recovery;
- Lua -> host scalar callbacks under `babet.host`, including binary strings,
  copied results, host failures, worker isolation, late registration and
  explicit reentrancy rejection;
- Lua-error diagnostics and reuse after failure;
- wrong-thread rejection;
- destruction and sequential recreation.

The normal Babet binary is checked with `ldd` to ensure no `libbabet.so`
dependency appears.

## 11. Explicitly deferred

The following are not part of the first embedding slice:

- a frozen ABI compatibility guarantee;
- shared `libbabet.so` packaging;
- multiple concurrent contexts;
- exposing `lua_State *`;
- host/Lua structured table/value marshalling beyond the scalar value contract;
- unregistering/replacing live host callbacks;
- reentrant nested context calls from host callbacks;
- retained Lua function handles;
- dotted/object method lookup and multiple returned values;
- multiple or mutable on-disk search roots after execution starts;
- loading native plugins from arbitrary embedding hosts;
- automatic module/dependency discovery;
- Windows DLL work;
- a product GUI layer (the FLTK prototype remains a separate optional host).

They are reconsidered only after the minimal C host path has been validated in
real use. Lot 11 separately adds a narrow native `.so` ABI to the original Babet
CLI; embedded contexts deliberately register `babet.plugin.load()` in refusal
mode and do not inherit that ELF loader policy.

## 12. Lot 6 validation status

The first static embedding path is maintainer-validated on Linux as of
2026-08-25. The normal validation builds the in-tree static runtime and the
relocatable SDK, moves the SDK to an unrelated path containing spaces, compiles
and links a fresh C host using only the moved public header/archive plus the
documented Linux system link boundary, and executes that host successfully.

The focused embedding regression finishes 12 PASS / 0 FAIL. The same run then
finishes the complete normal Babet campaign at 3810/0 in folder mode, 3796/0 in
embedded mode, 3796/0 in embedded-via-PATH mode, and 9/9 top-level modes. The
official CLI remains autonomous with no runtime `libbabet.so` dependency.

This closes Lot 6 without freezing the ABI or widening the deferred surface in
section 11.

## 13. Lot 10 validation status

Lot 10 adds the narrow Lua -> host callback surface and reworks the optional FLTK
prototype to consume it. Structural and local syntax checks are part of the
implementation candidate; final maintainer closure requires the normal Babet
validation plus the separate FLTK runtime test from a clean Linux build.
