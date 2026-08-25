# Native plugins — experimental Lot 11 API

Babet can load a deliberately small class of trusted Linux `.so` extensions in
normal CLI folder/file mode. This API is experimental and intentionally not a
package ecosystem.

Lot 11 was maintainer-validated on Linux on 2026-08-25. The API remains
experimental even though its current runtime and rejection contracts are green.

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
    {"echo", echo, NULL},
};

static const babet_plugin_descriptor_v1 descriptor = {
    BABET_PLUGIN_ABI_VERSION_V1,
    (uint32_t)sizeof(babet_plugin_descriptor_v1),
    "example",
    "1.0.0",
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
entry point is declared `noexcept` in C++, and callbacks must contain their own
exceptions before returning.

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
valid for the process lifetime.

## Security

Plugins are fully trusted process code, not scripts in a sandbox. Only load
`.so` files you trust as much as the Babet executable itself.

## Deliberate limitations

Native loading is available only in the normal Babet CLI main state. Workers,
external embedding hosts and generated `--create-exe` applications reject it.
There is no package manager, downloader, automatic discovery, dependency
resolver, temporary extraction or plugin packaging.

See `NATIVE_PLUGIN_DESIGN.md` for the complete architectural contract.
