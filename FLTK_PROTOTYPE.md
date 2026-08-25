# FLTK companion prototype — Lots 9–10

Status: Lots 9 and 10 runtime validation completed by the maintainer. Lot 10
rewrites the same prototype onto the public Lua -> host function API and the full
FLTK -> Lua -> host-function -> FLTK round trip is now validated.

## Purpose

This is deliberately **not** a Babet GUI product. It is a tiny separate C++ host
used to validate the architecture selected in `GUI_STUDY.md` and to make the
embedding boundary concrete before any larger GUI API is designed.

The normal `babet` executable, its CMake project, `build_local.sh` and
`--create-exe` do not link, download or know about FLTK.

Lot 9 proved the host -> Lua direction with `babet_context_call_global()`. Lot 10
keeps that path and adds the missing reverse direction through the public,
C-only host-function API documented in `HOST_FUNCTIONS_DESIGN.md`.

## Scope

The prototype still contains exactly one window and one button. A button
activation now follows the complete round trip:

1. a C++ FLTK callback runs on the GUI/main thread;
2. it calls the Lua global `on_counter_click(attempt)` through
   `babet_context_call_global()`;
3. Lua calls `babet.host.set_button_label(text)`;
4. the registered C/C++ host callback receives one scalar string through
   `babet_host_call` and updates the FLTK button;
5. Lua returns the integer counter to the original C++ callback.

The embedded Lua fixture intentionally fails on the second call **before** the
Lua -> host update. The host logs the Lua error and returns normally to the FLTK
event loop. The third callback must succeed and update the button again. This
proves that one failing Lua callback neither unwinds through nor terminates
`Fl::run()`, and that the public host-function bridge remains usable afterwards.

No polling, `babet_context_get_global()` loop, shared control globals, private
`lua_State *` access or prototype-only Lua -> widget bridge is used.

## The Lot 10 host-function use

The prototype registers exactly one function:

```text
babet.host.set_button_label(text)
```

Registration uses `babet_context_register_host_function()`. The callback:

- accepts exactly one `BABET_VALUE_STRING` argument;
- rejects embedded NUL bytes because FLTK labels are C strings;
- updates the existing button on the GUI thread;
- returns `BABET_STATUS_OK` on success;
- attaches a copied diagnostic with `babet_host_call_set_error()` before a
  non-OK return.

The `HostState *` userdata stays owned by the C++ application and remains valid
until the Babet context is destroyed. There is no unregister operation in this
first API, so shutdown makes callbacks inert before destroying either side.

The prototype does **not** use this narrow mechanism to create a generic FLTK
binding. Widget classes, FLTK pointers and toolkit types never cross the public
Babet ABI.

## Event loop and thread rule

FLTK owns `Fl::run()` on the same thread that creates, uses and destroys the
single `babet_context`. All FLTK/widget operations and all registered Babet host
callbacks in this prototype happen on that thread.

Future background work must notify the GUI thread rather than manipulating
widgets directly. FLTK provides mechanisms such as `Fl::awake()` for that
pattern, but this prototype does not need worker threads.

GUI callbacks execute on the event-loop thread and should stay short. Long or
blocking work (HTTP, sleeps, process waits, heavy computation) would freeze the
UI and must eventually be moved away from this loop.

## Error policy

A Lua callback failure is an application event failure, not a reason to unwind
through FLTK:

- `babet_context_call_global()` status is checked inside the C++ FLTK callback;
- the context diagnostic is logged to stderr;
- the callback returns normally;
- the event loop remains usable;
- a later callback can call Lua and the host API again.

A registered host function follows the public Lot 10 contract: a non-OK
`babet_status` becomes a Lua error, and the optional diagnostic set through
`babet_host_call_set_error()` is copied by Babet. C++ exceptions escaping from a
C++ host callback are contained by `libbabet` before control returns to Lua.

The outer FLTK callback itself remains a no-throw boundary and contains any
unexpected C++ exception before returning to FLTK.

## Reentrancy

A host function is entered synchronously while Babet is executing Lua. It must
not call back into the mutating `babet_context_*` API. Such nested calls are
rejected with `BABET_STATUS_REENTRANT_CALL` rather than recursively entering the
same Lua state. The FLTK host callback therefore changes only its host-owned
widget; it does not call `babet_context_run()`, `call_global()` or another
context operation.

## Destruction order

The prototype uses this explicit shutdown sequence:

1. mark callbacks disabled;
2. detach FLTK callbacks;
3. destroy the FLTK window/widgets that retain the host-state pointer;
4. destroy `babet_context` (which also releases the registration that borrows
   the same host-state pointer);
5. null the context pointer.

A callback guard checks both `callbacks_enabled` and widget availability. The
automated self-test invokes the FLTK guard after context destruction as a
regression against use-after-destroy logic.

## Building and testing

First build Babet normally so the standalone SDK exists:

```bash
./build_local.sh
```

Then run the **separate optional** prototype test:

```bash
./prototypes/fltk/test.sh
```

Each top-level invocation publishes the complete optional GUI validation
transcript (bootstrap/configure/build/self-test/size/`ldd`) to the separate
stable file `babet-fltk-tests.txt`, atomically replacing the previous FLTK log.
This never reuses or overwrites the normal `babet-tests.txt` journal. The log is
still published when FLTK validation fails.

Only this explicit prototype command bootstraps FLTK if necessary. It downloads
the pinned FLTK 1.4.5 source archive, verifies SHA-256, builds static FLTK, then
builds the companion against `build/embedding-sdk`.

The FLTK source build still needs the normal Linux GUI development headers. On
Debian/Ubuntu, FLTK upstream lists the X11 development set and, for the hybrid
Wayland backend, additional Pango/Wayland/xkbcommon packages. If the optional
FLTK configure step reports a missing system dependency, install that
development package and rerun the prototype test; none of these packages are
prerequisites for building or running the normal Babet CLI.

The normal Babet build/test pipeline never calls this bootstrap.

The test runs `--self-test` under `xvfb-run` when available (forced X11) or in
the current graphical session otherwise. It verifies the full
FLTK -> Lua -> public host-function -> FLTK round trip, reports the stripped
prototype size and prints the full `ldd` closure. Static FLTK is expected, but
system graphical/text libraries can remain dynamic: the companion needs a
compatible X11/Wayland graphical environment and is not subject to Babet CLI's
headless deployment expectations.

Final Lot 10 maintainer validation on 2026-08-25 reports
`LOT10_FLTK_HOST_API_SELFTEST_OK attempts=3 successes=2 lua_errors=1 host_updates=2 last=3`.
The stripped companion measures 15,316,744 bytes in that environment, links FLTK
statically, and keeps the normal Babet CLI free of GUI runtime dependencies.

## What Lot 9 revealed and Lot 10 now solves

The Lot 9 prototype deliberately stopped at the hard boundary instead of hiding
it with polling. Lot 10 addresses that observed list as follows:

1. **Lua can now call an explicitly registered host function** under
   `babet.host.<name>`.
2. **Lua can request a host-side action directly.** The prototype uses this to
   change the button label instead of returning a value for C++ to interpret.
3. **Scalar argument/result and error semantics now exist** and reuse
   `babet_value`; strings crossing from a callback setter are copied by Babet.
4. **Lifetime, owner-thread and reentrancy rules are explicit.** Registration
   lasts until context destruction, workers do not inherit host callbacks and
   nested context entry is rejected.
5. **The public boundary remains C-only.** No `lua_State`, FLTK pointer or C++
   toolkit type enters the SDK ABI.

## Still deliberately out of scope

The narrow host-function mechanism is a foundation, not a complete GUI binding.
This prototype therefore still does not attempt to:

- expose arbitrary FLTK widgets or toolkit classes to Lua;
- let Lua create/destroy GUI objects through a generic object model;
- define a public opaque widget-ID registry;
- provide asynchronous callbacks, futures or event queues;
- permit nested Lua/context entry from a host callback;
- expose structured Lua tables through the C ABI;
- unregister a host function before context destruction.

A later GUI product should add only whichever of these capabilities is justified
by a concrete application. The Lot 10 API itself should remain useful to
non-GUI hosts and to the future minimal native-plugin experiment.

## FLTK version and deployment note

The prototype pins FLTK 1.4.5, the stable 1.4 release selected for Lot 9. The
default FLTK 1.4 Linux configuration can support Wayland and X11 in a hybrid
build; exact enabled backends depend on the development packages present when
FLTK is configured.

This companion is optional desktop software. A successfully linked executable
still needs a compatible X11/Wayland graphical environment and whatever system
libraries appear in its measured `ldd` closure. That does not alter the normal
Babet CLI autonomy contract.
