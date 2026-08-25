# Native plugins — experimental Lot 11 API

Babet can load a deliberately small class of trusted Linux `.so` extensions in
normal CLI folder/file mode. This API is experimental and intentionally not a
package ecosystem.

Lot 11 was maintainer-validated on Linux on 2026-08-25, then reopened for
post-audit hardening before publication. The hardened ABI remains experimental
until a fresh maintainer campaign and second external audit are green.

## Quick start

Build a shared object against the public headers only:

```sh
cc -std=c11 -fPIC -shared -I/path/to/babet/include plugin.c -o plugin.so
```

The plugin does **not** link against `libbabet.so`.

Load it explicitly from Lua:

```lua
local plugin, err = babet.plugin.load("./plugin.so")
assert(plugin, err)

print(plugin.name, plugin.version)
print(plugin.functions.echo("hello"))
```

See `examples/native_plugin/` for complete C and C++ examples.

## Minimal C plugin

```c
#include "babet/plugin.h"

static babet_status echo(babet_host_call *call, void *userdata)
{
    (void)userdata;
    const babet_value *args = babet_host_call_arguments(call);
    if (babet_host_call_argument_count(call) != 1 ||
        !args || args[0].type != BABET_VALUE_STRING)
        return BABET_STATUS_INVALID_ARGUMENT;

    return babet_host_call_set_result(call, &args[0]);
}

static const babet_plugin_function_v1 functions[] = {
    {{"echo", sizeof("echo") - 1}, echo, NULL},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    (uint32_t)sizeof(babet_plugin_function_v1),
    0,
    {"example", sizeof("example") - 1},
    {"1.0.0", sizeof("1.0.0") - 1},
    functions,
    1,
};

const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void)
{
    return &descriptor;
}
```

## C++ implementation rule

C++ is allowed inside a plugin. The ABI is still C-only. Do not pass STL/RTTI
objects, C++ allocation ownership or exceptions across the boundary. The query
entry point and `babet_plugin_callback_v1` are declared `noexcept` in C++. A
potentially-throwing callback therefore fails to initialize a plugin descriptor
at compile time.

This is required because the official Babet executable statically links its GCC
C++ runtimes while a normal plugin commonly uses shared runtimes. Babet cannot
reliably catch an exception escaping that DSO boundary. Catch inside the plugin,
call `babet_host_call_set_error()`, and return a non-OK `babet_status`.

Temporary C++ strings are safe as callback results because
`babet_host_call_set_result()` copies their bytes synchronously.

## Value contract

Plugin functions receive only the Lot 10 scalar types: nil, boolean, signed
64-bit integer, double and binary-safe byte string. Unsupported Lua values fail
before the plugin callback is entered.

A callback returns `BABET_STATUS_OK` on success. It may set one scalar result.
For failure it may first call `babet_host_call_set_error()` and then return a
non-OK `babet_status`; Babet converts that failure into a Lua error.

## Lifetime

Successfully loaded plugins remain mapped until process exit. There is no
unload/reload in Lot 11. Callback `userdata` is plugin-owned and must remain
valid for the process lifetime. Duplicate loads are rejected even through a
hardlink/alternate pathname to the same DSO. A failed descriptor probe may be
`dlclose()`'d, so static constructors must not leave threads/resources assuming
the DSO will stay mapped when validation fails.

## Security

Plugins are fully trusted process code, not scripts in a sandbox. Only load
`.so` or numeric `.so.<version>` files (for example `.so.1` or `.so.1.2.3`) you trust as much as the Babet executable itself.
Plugin loading and calls are supported from normal Lua coroutines of the same
global Lua state.

## Deliberate limitations

Native loading is available only in the normal Babet CLI main state. Workers,
external embedding hosts and generated `--create-exe` applications reject it.
There is no package manager, downloader, automatic discovery, dependency
resolver, temporary extraction or plugin packaging.

See `NATIVE_PLUGIN_DESIGN.md` for the complete architectural contract.
