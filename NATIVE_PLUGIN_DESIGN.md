# Babet native plugin design contract — Lot 11

This document defines the first deliberately small native plugin experiment.
It is Linux-only, explicit, trusted and built on the scalar host-call boundary
validated in Lot 10.

Status: implemented and maintainer-validated on Linux on 2026-08-25. The public
ABI remains experimental; Lot 11 validation covers C/C++ fixtures, explicit
loading/rejection paths, generated-application refusal and absence of a runtime
`libbabet.so` dependency.

## 1. Why plugins exist

Native plugins are reopened for extension cases that should not become Babet
core: specialised/vendor SDK wrappers, site-specific hardware libraries and
third-party/private native extensions that should not require a Babet fork.

Binary-size reduction is explicitly **not** a motivation. The normal Babet CLI
keeps its existing static feature set and autonomy.

## 2. Trust model

A native plugin is fully trusted in-process code. Loading a `.so` gives that
code the same process privileges as Babet. There is no sandbox, memory-safety
boundary, capability system or crash isolation. A malformed or hostile plugin
can corrupt memory, terminate the process, open files or perform any other
operation available to the host process.

## 3. ABI v1

The public declaration lives in `include/babet/plugin.h` and is C-only.
A v1 plugin exports exactly one query symbol:

```c
const babet_plugin_descriptor_v1 *babet_plugin_query_v1(void);
```

The returned static descriptor contains:

- `abi_version == BABET_PLUGIN_ABI_VERSION_V1`;
- `struct_size` for forward-compatible descriptor growth;
- static plugin name and version strings;
- a bounded array of function declarations;
- each function declaration contains a simple Lua identifier,
  `babet_host_function`, and plugin-owned `userdata`.

The host copies descriptor strings and function names while loading. Callback
`userdata` remains plugin-owned and must stay valid for the process lifetime.

## 4. Pure C boundary

No `lua_State`, C++ class, STL/RTTI object, exception or allocator-owned C++
object belongs to the ABI. Plugin internals may be C++ but exported/query
functions and callbacks must obey the C ABI. In C++ the query entry point is
`noexcept`; plugin callbacks must not let exceptions cross the boundary.

A C++ plugin may freely use `std::string`, containers, vendor C++ SDKs and other
implementation details internally, provided it converts at the boundary and
returns before destroying temporary storage. `babet_host_call_set_result()`
copies string results immediately.

## 5. Scalar callback reuse from Lot 10

Plugin functions use the exact Lot 10 callback type and helpers:

- `babet_host_call_argument_count()`;
- `babet_host_call_arguments()`;
- `babet_host_call_set_result()`;
- `babet_host_call_set_error()`.

The value set remains nil, boolean, signed 64-bit integer, double and
length-delimited byte string. Tables, functions, userdata and threads are not
part of the v1 plugin value boundary.

This deliberately avoids a second marshalling system and keeps Lua internals
private.

## 6. Explicit Lua loading

The normal Babet CLI exposes:

```lua
local plugin, err = babet.plugin.load("./my-plugin.so")
```

The path is explicit. Babet resolves it to a canonical regular file and v1
requires a `.so` suffix. There is no plugin-name search path and no automatic
`require()` discovery.

On success the returned table contains:

```text
plugin.name
plugin.version
plugin.abi
plugin.path
plugin.functions.<declared_name>
```

Function tables are local to the returned plugin object; native plugins do not
silently inject names into `babet.host` or the Lua global namespace.

## 7. ELF loading and symbol boundary

The original Babet executable loads successful plugins with
`dlopen(..., RTLD_NOW | RTLD_LOCAL)`. A plugin does not link a shared
`libbabet.so`. Instead, the Babet executable exports only the narrow C callback
surface required by v1 plugins (`babet_host_call_*`, plus version/status helper
symbols).

Plugins may naturally have their own ELF `DT_NEEDED` dependencies, including a
vendor SDK. Resolving and deploying those libraries is the plugin author's or
system administrator's responsibility; Babet does not become a dependency
resolver.

## 8. Lifetime and no unload

A successfully loaded plugin is deliberately never `dlclose()`'d. Its code and
plugin-owned callback userdata remain valid until process exit, even if the Lua
plugin table is garbage-collected.

The same canonical `.so` path cannot be loaded twice in one Lua runtime. Lot 11
has no unload/reload operation. A failed probe before publication may be
`dlclose()`'d because no callback has escaped.

## 9. Runtime scopes

Lot 11 enables native loading only in the normal Babet CLI main state.

It is explicitly unavailable in:

- generated `--create-exe` applications;
- worker Lua states;
- external embedding hosts using `libbabet`.

Generated applications therefore keep the one-file application contract and
never extract or search for native plugins. Embedding-host plugin loading can be
studied later if a real host needs it; this lot does not silently force an ELF
symbol-export policy onto arbitrary external host executables.

## 10. What is intentionally absent

Lot 11 does **not** add:

- package manager or registry;
- dependency resolver;
- Internet downloader;
- automatic `require()` discovery;
- recursive plugin directories;
- `/tmp` extraction;
- `--create-exe` plugin packaging;
- unload/reload;
- sandboxing;
- `lua_State` exposure;
- structured/table marshalling;
- Windows dynamic-library support.

Those are future design questions only if concrete use cases justify them.
