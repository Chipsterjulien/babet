# Embedding Babet from C/C++

This guide is the developer-oriented companion to [`EMBEDDING_DESIGN.md`](EMBEDDING_DESIGN.md).
The design document explains *why* the embedding boundary has its current shape;
this guide explains how to use it.

The embedding API is still **experimental**. Lot 8 deliberately exercises it with
small standalone programs before any ABI-stability promise is made.

## 1. What the SDK contains

A normal Babet build creates:

```text
build/sdk/
├── include/babet/babet.h
├── lib/libbabet.a
├── EMBEDDING.md
├── EMBEDDING.fr.md
├── HOST_FUNCTIONS_DESIGN.md
└── examples/embedding/
```

`libbabet.a` is a flattened static archive containing the Babet runtime and the
pinned static third-party archives required by that runtime. The official
`babet` CLI remains autonomous and does not depend on a `libbabet.so`.

The public boundary is C, even when the host is C++. No Lua or C++ implementation
type is exposed by `babet.h`.

## 2. Minimal build

For a C host:

```sh
cc -std=c99 -Wall -Wextra -Werror \
  -I/path/to/sdk/include -c host.c -o host.o
c++ host.o /path/to/sdk/lib/libbabet.a \
  -ldl -pthread -lm -o host
```

Use a **C++ linker driver** for the final link because Babet itself is implemented
in C++. On a 32-bit Linux target, add `-latomic`.

The SDK also ships a small CMake project under `examples/embedding/`:

```sh
cmake -S /path/to/sdk/examples/embedding -B build \
  -DBABET_SDK_DIR=/path/to/sdk
cmake --build build
ctest --test-dir build --output-on-failure
```

## 3. Smallest useful program

[`examples/embedding/01_hello.c`](examples/embedding/01_hello.c) demonstrates the
complete minimum lifecycle:

1. `babet_context_create()`;
2. `babet_context_run()`;
3. `babet_context_destroy()`.

A context is an opaque handle. Exactly one context may be alive in a process at
a time, and it must be used and destroyed by the thread that created it.

## 4. Status codes and diagnostics

Every operation returns a `babet_status`. Use `babet_status_name()` for a stable
symbolic name. When an operation associated with a live context has a detailed
diagnostic, `babet_context_last_error()` returns it.

Typical handling is:

```c
babet_status status = babet_context_run(ctx, code, code_len, "my-chunk");
if (status != BABET_STATUS_OK) {
    fprintf(stderr, "%s: %s\n",
            babet_status_name(status),
            babet_context_last_error(ctx));
}
```

Do not assume that every argument/lifecycle rejection has a detailed string.
The status code is authoritative; `last_error()` is additional context when
available. A later mutating call may replace the stored diagnostic.

`babet_status` and the `babet_value.type` discriminator are fixed-width 32-bit
ABI tags. Unknown numeric values are representable so Babet can reject them
cleanly; applications should still use only the published `BABET_STATUS_*` and
`BABET_VALUE_*` constants.

[`examples/embedding/05_errors.c`](examples/embedding/05_errors.c) deliberately
runs a failing Lua chunk, prints the diagnostic, then proves that the same
context can continue executing valid Lua afterwards.

## 5. Module search root

Embedding starts without an on-disk Lua module root. Configure one explicitly
with `babet_context_set_search_root()` **before the first execution call**.

The root is resolved to an absolute directory and prepended to `package.path`
with the same semantics as Babet folder mode:

```text
<root>/?.lua
<root>/?/init.lua
```

The same root is propagated to Babet workers created by that context.

Only one search root can be configured in the current API. A missing path, a
regular file, a second configuration, or an attempt after execution has begun
is rejected.

See [`examples/embedding/02_search_root.c`](examples/embedding/02_search_root.c)
and its module fixture under `examples/embedding/modules/`.

## 6. Scalar values C -> Lua and Lua -> C

`babet_value` supports exactly five value kinds:

| C API type | Lua value |
| --- | --- |
| `BABET_VALUE_NIL` | `nil` |
| `BABET_VALUE_BOOLEAN` | boolean |
| `BABET_VALUE_INTEGER` | signed 64-bit integer |
| `BABET_VALUE_NUMBER` | number (`double`) |
| `BABET_VALUE_STRING` | byte string |

Use `babet_context_set_global()` to publish a scalar global to Lua and
`babet_context_get_global()` to read one back.

Strings are length-delimited and may contain embedded NUL bytes. For an input
string, `data == NULL` is valid only when `length == 0`.

For a string returned by `get_global()` or `call_global()`, the data pointer is
**borrowed from the context**. It remains valid only until the next mutating
context call or context destruction. Copy it if the host needs a longer
lifetime.

Tables, functions, userdata and threads are intentionally not marshalled and
return `BABET_STATUS_UNSUPPORTED_VALUE`.

See [`examples/embedding/03_values.c`](examples/embedding/03_values.c), including
a binary string containing NUL bytes.

## 7. Calling a Lua global function

`babet_context_call_global()` looks up one function directly in the main Lua
global table, passes zero or more scalar arguments and requests exactly one
result.

Current semantics:

- no Lua result -> `nil`;
- more than one Lua result -> extra results are discarded;
- structured result -> `BABET_STATUS_UNSUPPORTED_VALUE`;
- missing/non-function target or Lua error -> `BABET_STATUS_LUA_ERROR`;
- dotted method lookup such as `object.method` is not part of this first API.

See [`examples/embedding/04_call.c`](examples/embedding/04_call.c).

## 8. Registering host functions callable from Lua

Lot 10 adds the reverse direction without exposing `lua_State *`:

```c
static babet_status host_greet(babet_host_call *call, void *userdata)
{
    const size_t count = babet_host_call_argument_count(call);
    const babet_value *args = babet_host_call_arguments(call);
    if (count != 1 || args == NULL || args[0].type != BABET_VALUE_STRING) {
        (void)babet_host_call_set_error(call, "greet expects one string");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    babet_value result = {0};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = "hello from C";
    result.as.string.length = 12;
    return babet_host_call_set_result(call, &result);
}

babet_context_register_host_function(ctx, "greet", host_greet, userdata);
```

Lua then calls:

```lua
local message = babet.host.greet("Lua")
```

The registration name is copied and must be a simple ASCII Lua identifier; Lua reserved keywords are rejected so the name is always callable as `babet.host.<name>`.
`userdata` is borrowed from the host and must remain valid until the context is
destroyed; Lot 10 intentionally has no unregister operation.

Host-function arguments use the same five scalar `babet_value` kinds as the rest
of the embedding API. The argument array and its strings are borrowed only for
the callback duration. `babet_host_call_set_result()` copies string results
immediately, so a callback may safely use a temporary/local source buffer. If no
result is set, Lua receives `nil`.

To fail a host call, optionally copy a diagnostic with
`babet_host_call_set_error()` and return a non-OK `babet_status`. Lua receives a
normal error that can be caught with `pcall`; if it escapes, the outer
`babet_context_run()` / `call_global()` returns `BABET_STATUS_LUA_ERROR` and the
context diagnostic contains the host function name/status/message.

Callbacks execute synchronously on the context owner thread and are installed
only in the main embedded state, not worker states. Re-entering the public
`babet_context_*` API from inside a host callback is deliberately rejected with
`BABET_STATUS_REENTRANT_CALL`. A C++ callback may use C++ internally, but any
exception is contained by Babet before returning to Lua.

See [`examples/embedding/07_host_functions.c`](examples/embedding/07_host_functions.c)
and [`HOST_FUNCTIONS_DESIGN.md`](HOST_FUNCTIONS_DESIGN.md).

## 9. Thread and process-wide rules

The first embedding API intentionally allows **one live context per process**.
A second simultaneous `babet_context_create()` returns `BABET_STATUS_BUSY`.
Calls made from a thread other than the creating thread return
`BABET_STATUS_WRONG_THREAD` where the API can associate the call with a context.

See [`examples/embedding/06_lifecycle_threads.c`](examples/embedding/06_lifecycle_threads.c).

Embedding is not a sandbox. Babet APIs that change the current directory,
environment, signal policy, child processes or interactive terminal affect the
host process. The host owns that consequence just as the normal Babet CLI does.

## 10. C++ hosts

Include the same public header from C++:

```cpp
#include <babet/babet.h>
```

The header uses `extern "C"` automatically when compiled as C++. Keep C++
objects and exceptions on the host side. The public Babet boundary consists of
C types and status codes; no exception is specified to cross it.

## 11. Linux/glibc compatibility

`file` may print a phrase such as `for GNU/Linux 3.2.0`. That is **not** a glibc
minimum-version promise. It reflects ELF/kernel ABI metadata.

To inspect the highest versioned glibc symbol required by a final executable:

```sh
objdump -T ./host \
  | grep 'GLIBC_' \
  | sed -n 's/.*GLIBC_\([0-9][0-9.]*\).*/\1/p' \
  | sort -uV \
  | tail -1
```

Run that command on both the official `babet` binary and on the host executable
that you link against the SDK. The two values may differ.

The SDK is a **static archive**, so the compatibility of the final host is
influenced by the host compiler, linker, libc and build environment. Babet does
not currently promise a fixed `glibc >= X` baseline for arbitrary SDK-built
programs. If deployment to older distributions matters, build and test with a
suitably old controlled build environment/sysroot instead of assuming that a
binary linked on a current rolling distribution will run on an older stable one.

The embedding runtime regression prints the measured highest `GLIBC_*` version
for the maintained Babet binary and its freshly linked external SDK smoke host
when `objdump` is available. Those measurements describe that build; they are
not an ABI guarantee for every future host.

## 12. What is deliberately not supported yet

The first API intentionally does not expose:

- structured table/container marshalling for host functions or direct calls;
- unregistering/replacing host callbacks while the context is live;
- reentrant nested `babet_context_*` calls from a host callback;
- arbitrary Lua function handles/callbacks;
- dotted method lookup;
- multiple return values;
- multiple simultaneous contexts;
- a shared `libbabet.so` ABI;
- loading native plugins from an external embedding context.

These embedding capabilities remain deferred until a concrete consumer demonstrates the need.
Lot 11 separately defines a narrow native-plugin ABI for the original Babet CLI;
it does not widen the embedding loader boundary. The retired 2.23.0 FLTK prototype was the first real consumer of the public
host-function API: Lua changed a button label through
`babet.host.set_button_label()` instead of relying on a private bridge. The
non-GUI SDK examples remain the maintained embedding consumers after that
prototype was removed from the active source tree.

## 13. Executable examples

The SDK ships these intentionally small programs:

| Example | Purpose |
| --- | --- |
| `01_hello.c` | create/run/destroy minimum |
| `02_search_root.c` | `require()` from an explicit host module root |
| `03_values.c` | scalar globals and binary-safe strings |
| `04_call.c` | direct scalar Lua function call |
| `05_errors.c` | Lua diagnostics and recovery |
| `06_lifecycle_threads.c` | BUSY and WRONG_THREAD lifecycle rules |
| `07_host_functions.c` | register a C callback callable as `babet.host.*` |

They are documentation **and** regression material: the Babet validation harness
compiles and runs them against a moved standalone SDK.

### Native plugin boundary (Lot 11)

The developer SDK also ships `include/babet/plugin.h` and native-plugin examples
because both reuse the public scalar `babet_host_call_*` surface. This does not
mean an arbitrary embedding host can load Babet plugins in Lot 11: inside an
embedded Lua context `babet.plugin.load()` returns a controlled "unavailable in
embedding hosts" error. The first native loader is intentionally limited to the
original Babet CLI executable, whose ELF export policy Babet controls.
