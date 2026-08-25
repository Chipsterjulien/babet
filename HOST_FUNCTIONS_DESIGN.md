# Babet host-function design contract — Lot 10

This document defines the first public Lua -> host C/C++ callback boundary.
It is intentionally small and is derived from the concrete limitations exposed
by the Lot 9 FLTK prototype rather than from a hypothetical plugin system.

## 1. Goal

The supported direction becomes bidirectional:

```text
host C/C++ --babet_context_call_global()--> Lua
host C/C++ <--babet.host.<name>(...)------- Lua
```

The new direction must let Lua ask its embedding host to perform a small native
action such as changing a GUI label, reading a device value, or invoking a
vendor SDK wrapper without exposing `lua_State *` or C++ implementation types.

## 2. Public C-only boundary

The public header adds only:

- opaque `babet_host_call`;
- `babet_host_function` callback type;
- `babet_context_register_host_function()`;
- `babet_host_call_argument_count()` / `babet_host_call_arguments()`;
- `babet_host_call_set_result()`;
- `babet_host_call_set_error()`;
- `BABET_STATUS_REENTRANT_CALL`.

No `lua_State`, STL object, C++ class, exception, RTTI object or allocator-owned
C++ object crosses this boundary. A callback may be implemented internally in
C++, but Babet catches every C++ exception before control returns to Lua.

## 3. Lua namespace and names

A registered name `foo` is published as:

```lua
babet.host.foo(...)
```

The first API accepts a simple ASCII Lua identifier only:
`[A-Za-z_][A-Za-z0-9_]*`, excluding Lua reserved keywords. Dotted names are
intentionally not interpreted. Rejecting keywords keeps every accepted name
usable with the promised `babet.host.<name>` syntax. Babet copies the name at registration time, rejects duplicate registrations, and refuses to overwrite a
non-nil field already present at the target `babet.host` key.

The `babet.host` table is a reserved embedding namespace. Trusted Lua code can
technically mutate normal Lua tables, but doing so is outside the host-function
contract.

## 4. Registration lifetime and ownership

`babet_context_register_host_function()` may be called on the context owner
thread before execution or between Lua execution calls. Registration is not
frozen by the first run.

The callback and its `userdata` remain registered until the context is
destroyed. Babet copies the function name but does **not** own, copy or destroy
`userdata`. The host must therefore keep `userdata` valid for the whole context
lifetime.

There is deliberately no unregister operation in Lot 10. Removing a callback
while Lua can still retain the closure would create a lifetime problem that the
current GUI consumer does not need.

## 5. Callback thread and execution model

A host callback is synchronous. Lua calls `babet.host.<name>()`; Babet converts
the scalar arguments and invokes the registered callback immediately on the
same thread that is executing the embedded Lua state.

Because an embedded context is owner-thread-bound, host callbacks therefore run
on that same owner thread. This is exactly what the FLTK prototype needs: the
GUI thread owns `Fl::run()`, invokes Lua, and Lua can synchronously request a
widget update on the same GUI thread.

Host callbacks are installed only in the main embedded Lua state. Worker states
do not inherit them. A worker must communicate through the existing worker
mechanisms instead of gaining implicit access to arbitrary host/GUI state.

## 6. Scalar arguments and results

Lot 10 reuses the existing `babet_value` contract without adding a second value
system. Lua arguments accepted by a host callback are exactly:

- nil;
- boolean;
- signed 64-bit integer;
- double;
- byte string with explicit length.

Tables, functions, userdata and threads fail before the host callback is
entered.

`babet_host_call_argument_count()` and `babet_host_call_arguments()` expose a
borrowed array valid only for the duration of the callback. String data in that
array is likewise borrowed only for the callback duration.

A callback returns nil by default. To return another scalar it calls
`babet_host_call_set_result()`. The setter copies string data immediately into
Babet-owned storage, so a C callback may safely point the source value at a
stack/local temporary buffer. The last successful result setter wins.

## 7. Host errors

A callback returns a `babet_status`:

- `BABET_STATUS_OK` means success;
- any non-OK status means host-function failure.

Before returning a failure status the callback may call
`babet_host_call_set_error()` with a human-readable message. That message is
copied while the callback is active.

A host-function failure becomes a normal Lua error. If the surrounding Lua code
catches it with `pcall`, execution can continue. If it escapes to
`babet_context_run()` or `babet_context_call_global()`, the outer embedding call
returns `BABET_STATUS_LUA_ERROR` with the host-function name, returned status and
diagnostic in `babet_context_last_error()`.

If a C++ callback throws, Babet catches `std::bad_alloc`, `std::exception` and
unknown exceptions at the callback boundary and converts them to the same Lua
error path. No C++ exception crosses Lua or the C ABI.

## 8. Reentrancy

Lot 10 deliberately forbids re-entering the public context API from inside a
host callback. A callback that retained the context pointer in `userdata` and
tries to call `babet_context_run()`, `set_global()`, `get_global()`,
`call_global()`, another registration, search-root mutation or destruction
receives `BABET_STATUS_REENTRANT_CALL`.

This keeps Lua stack ownership, diagnostics, borrowed strings, callback
lifetime and destruction rules simple. A future need for nested host/Lua calls
must be designed explicitly rather than accidentally supported.

`babet_context_last_error()` remains a read-only diagnostic accessor and does
not itself enter Lua.

## 9. Longjmp and C++ cleanup rule

Lua can longjmp on allocation/error paths. The host-function implementation must
therefore preserve the same invariant used by the rest of Babet: no live C++
RAII object may depend on unwinding across a Lua longjmp.

Argument vectors, callback result string storage and callback diagnostic storage
are context-owned. Lua result emission happens only after the C++ callback has
returned and all host exceptions have been contained. Lua errors are raised from
frames that hold only trivial/local pointer state.

## 10. FLTK consumer

The Lot 9 prototype is reworked to register one public host function:

```text
babet.host.set_button_label(text)
```

A button event still travels FLTK -> C++ -> `babet_context_call_global()` -> Lua.
On successful clicks, Lua now calls `babet.host.set_button_label()` to change the
widget. The old workaround where C++ interpreted Lua's scalar return and updated
the label itself is removed.

The second click still raises the deliberate Lua error from Lot 9; it never
reaches the host label callback. The third click must succeed and update the
widget through the new public API, proving recovery in both directions.

## 11. Plugin foundation consumed by Lot 11

Lot 10 itself does **not** define a plugin ABI or load `.so` files. Lot 11 now
reuses this exact scalar callback type in a separate versioned C plugin
descriptor returned by `babet_plugin_query_v1()`. Plugin functions are exposed
through the local table returned by `babet.plugin.load()` rather than injected
into the embedding-only `babet.host` namespace.

The important groundwork remains unchanged: value passage is scalar/C-only,
`lua_State *` stays private and result strings are copied at the boundary. The
Lot 11 ABI additionally forbids C++ exceptions/objects crossing between an
independently built plugin and the Babet executable. See
`NATIVE_PLUGIN_DESIGN.md`.
