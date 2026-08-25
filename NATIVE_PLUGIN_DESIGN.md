# Babet native plugin design contract — Lot 11

This document defines the first deliberately small native plugin experiment.
It is Linux-only, explicit, trusted and built on the scalar host-call boundary
validated in Lot 10.

Status: Lots 10/11 and their post-audit hardening were maintainer-validated on
Linux on 2026-08-25. A second independent audit rechecked the original findings,
confirmed the hardening and concluded the code was ready to publish. Three
non-blocking contract nits from that review were then closed and await one final
maintainer regression. The public ABI remains experimental.

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
- `function_struct_size`, the byte stride of each declaration;
- length-delimited plugin name and version views;
- a bounded array of function declarations;
- each function declaration contains a length-delimited simple Lua identifier,
  `babet_plugin_callback_v1`, and plugin-owned `userdata`.

The host validates declared lengths before copying metadata/function names. A
terminating NUL is not required. Declared lengths are part of the trusted
contract: Babet bounds them but cannot prove that a plugin-provided pointer has
that many readable bytes. `function_struct_size` lets Babet index only the v1
prefix even when a future declaration appends fields. The v1 `reserved` field
must be zero so an older host fails closed if a future ABI gives it meaning.
Callback `userdata` remains plugin-owned and must stay valid for the process
lifetime.

## 4. Pure C boundary

No `lua_State`, C++ class, STL/RTTI object, exception or allocator-owned C++
object belongs to the ABI. Plugin internals may be C++ but exported/query
functions and callbacks must obey the C ABI. In C++ both the query entry point
and `babet_plugin_callback_v1` are `noexcept`; the callback function-pointer type
makes forgetting `noexcept` a compile-time error.

This is a correctness requirement, not merely style. The official Babet binary
links libgcc/libstdc++ statically, while an ordinary C++ plugin normally uses
shared runtimes. Babet therefore does **not** promise to catch a C++ exception
that escapes a plugin DSO. A C++ plugin must catch every exception internally
and translate it to `babet_host_call_set_error()` plus a non-OK `babet_status`.

A C++ plugin may freely use `std::string`, containers, vendor C++ SDKs and other
implementation details internally, provided it converts at the boundary and
returns before destroying temporary storage. `babet_host_call_set_result()`
copies string results immediately.

## 5. Scalar callback reuse from Lot 10

Plugin functions reuse the Lot 10 `babet_host_call` object and helpers, but use
the plugin-specific `babet_plugin_callback_v1` function-pointer type so C++ can
enforce `noexcept` across the DSO boundary:

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

The path is explicit. Babet resolves it to a canonical regular file. Linux
shared-object spellings ending in `.so` or a numeric dotted version such as
`.so.1` / `.so.1.2.3` are accepted, so a normal `libvendor.so.1` file (or a `.so`
symlink resolving to it) does not need to be renamed. Suffixes such as
`.so.txt` or `.so.bak` are rejected. There is no plugin-name search path and no
automatic `require()` discovery.

`babet.plugin.load()` and the returned plugin functions are callable from normal
Lua coroutines belonging to the same global Lua state. Runtime identity is
validated through the shared Lua registry rather than by requiring the current
coroutine pointer to equal the main `lua_State *`.

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

The Babet build probes linker support for `--export-dynamic-symbol` before using
it. A linker without that capability is rejected at CMake configure time with a
clear diagnostic rather than failing later during the final link.

## 8. Lifetime and no unload

A successfully loaded plugin is deliberately never `dlclose()`'d. Its code and
plugin-owned callback userdata remain valid until process exit, even if the Lua
plugin table is garbage-collected.

The same shared object cannot be published twice in one Lua runtime. Babet first
checks canonical path / underlying-file equivalence (covering hardlinks), then
checks the actual `dlopen()` handle identity before creating a second Lua table.
This mirrors the loader's real DSO identity instead of assuming pathname identity
is sufficient. Lot 11 has no unload/reload operation.

A failed probe before publication may be `dlclose()`'d because no callback has
escaped. Consequently a plugin constructor must not start a thread or publish a
resource that assumes the DSO will stay mapped if descriptor validation later
fails. Successful plugins remain mapped for process lifetime.

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
