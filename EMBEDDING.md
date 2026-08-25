# Embedding Babet from C/C++

This guide is the developer-oriented companion to [`EMBEDDING_DESIGN.md`](EMBEDDING_DESIGN.md).
The design document explains *why* the embedding boundary has its current shape;
this guide explains how to use it.

The embedding API is still **experimental**. Lot 8 deliberately exercises it with
small standalone programs before any ABI-stability promise is made.

## 1. What the SDK contains

A normal Babet build creates:

```text
build/embedding-sdk/
├── include/babet/babet.h
├── lib/libbabet.a
├── EMBEDDING.md
├── EMBEDDING.fr.md
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

## 8. Thread and process-wide rules

The first embedding API intentionally allows **one live context per process**.
A second simultaneous `babet_context_create()` returns `BABET_STATUS_BUSY`.
Calls made from a thread other than the creating thread return
`BABET_STATUS_WRONG_THREAD` where the API can associate the call with a context.

See [`examples/embedding/06_lifecycle_threads.c`](examples/embedding/06_lifecycle_threads.c).

Embedding is not a sandbox. Babet APIs that change the current directory,
environment, signal policy, child processes or interactive terminal affect the
host process. The host owns that consequence just as the normal Babet CLI does.

## 9. C++ hosts

Include the same public header from C++:

```cpp
#include <babet/babet.h>
```

The header uses `extern "C"` automatically when compiled as C++. Keep C++
objects and exceptions on the host side. The public Babet boundary consists of
C types and status codes; no exception is specified to cross it.

## 10. Linux/glibc compatibility

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

## 11. What is deliberately not supported yet

The first API intentionally does not expose:

- host functions callable from Lua;
- structured table/container marshalling;
- arbitrary Lua function handles/callbacks;
- dotted method lookup;
- multiple return values;
- multiple simultaneous contexts;
- a shared `libbabet.so` ABI;
- a generic native-plugin ABI.

These are deferred until a concrete consumer demonstrates the need. The next
planned consumer is the separate FLTK prototype, which will use the existing
host-to-Lua call path first and record exactly what is missing in the opposite
direction.

## 12. Executable examples

The SDK ships these intentionally small programs:

| Example | Purpose |
| --- | --- |
| `01_hello.c` | create/run/destroy minimum |
| `02_search_root.c` | `require()` from an explicit host module root |
| `03_values.c` | scalar globals and binary-safe strings |
| `04_call.c` | direct scalar Lua function call |
| `05_errors.c` | Lua diagnostics and recovery |
| `06_lifecycle_threads.c` | BUSY and WRONG_THREAD lifecycle rules |

They are documentation **and** regression material: the Babet validation harness
compiles and runs them against a moved standalone SDK.
