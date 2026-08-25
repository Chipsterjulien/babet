# FLTK companion prototype — Lot 9

Status: runtime prototype validated by the maintainer; dedicated full-log publication pending one maintainer rerun.

## Purpose

This is deliberately **not** a Babet GUI product. It is a tiny separate C++
host used to validate the architecture selected in `GUI_STUDY.md` and to expose
what the current embedding API cannot express before Lot 10 is designed.

The normal `babet` executable, its CMake project, `build_local.sh` and
`--create-exe` do not link, download or know about FLTK.

## Scope

The prototype contains exactly one window and one button. A button activation:

1. enters a C++ FLTK callback on the GUI/main thread;
2. calls the Lua global `on_counter_click(attempt)` through the existing
   `babet_context_call_global()` API;
3. expects one integer result;
4. lets the C++ host update the button label from that returned scalar.

The embedded Lua fixture intentionally fails on the second call. The host logs
the Lua error and returns normally to the FLTK event loop. The third callback
must succeed, proving that one failing Lua callback does not unwind through or
terminate `Fl::run()`.

No polling, `babet_context_get_global()` loop, shared control globals, private
`lua_State *` access or temporary Lua -> widget bridge is used.

## Event loop and thread rule

FLTK owns `Fl::run()` on the same thread that creates, uses and destroys the
single `babet_context`. All FLTK/widget operations in this prototype happen on
that thread.

Future background work must notify the GUI thread rather than manipulating
widgets directly. FLTK provides mechanisms such as `Fl::awake()` for that
pattern, but Lot 9 does not need worker threads.

GUI callbacks execute on the event-loop thread and should stay short. Long or
blocking work (HTTP, sleeps, process waits, heavy computation) would freeze the
UI and must eventually be moved away from this loop.

## Callback error policy

A Lua callback failure is an application event failure, not a reason to unwind
through FLTK:

- `babet_context_call_global()` status is checked inside the C++ callback;
- the context diagnostic is logged to stderr;
- the callback returns normally;
- the event loop remains usable;
- a later callback can call Lua again.

The C++ FLTK callback itself is also a no-throw boundary and contains any
unexpected C++ exception before returning to FLTK.

## Destruction order

The prototype uses this explicit shutdown sequence:

1. mark callbacks disabled;
2. detach FLTK callbacks;
3. destroy the FLTK window/widgets that retain the host-state pointer;
4. destroy `babet_context`;
5. null the context pointer.

A callback guard checks both `callbacks_enabled` and `ctx`. The automated
self-test invokes this guard after context destruction as a regression against
use-after-destroy logic.

## Building and testing

First build Babet normally so the standalone SDK exists:

```bash
./build_local.sh
```

Then run the **separate optional** prototype test:

```bash
./prototypes/fltk/test.sh
```

Each top-level invocation publishes the complete optional GUI validation transcript
(bootstrap/configure/build/self-test/size/`ldd`) to the separate stable file
`babet-fltk-tests.txt`, atomically replacing the previous FLTK log. This never
reuses or overwrites the normal `babet-tests.txt` journal. The log is still
published when the FLTK validation fails, so the failure can be diagnosed from
the complete transcript.

Only this explicit prototype command bootstraps FLTK if necessary. It downloads
the pinned FLTK 1.4.5 source archive, verifies SHA-256, builds static FLTK, then
builds the companion against `build/embedding-sdk`.

The FLTK source build still needs the normal Linux GUI development headers. On
Debian/Ubuntu, FLTK upstream lists the X11 development set and, for the hybrid
Wayland backend, additional Pango/Wayland/xkbcommon packages. If the optional
FLTK configure step reports a missing system dependency, install that development
package and rerun the prototype test; none of these packages are prerequisites
for building or running the normal Babet CLI.

The normal Babet build/test pipeline never calls this bootstrap.

The test runs `--self-test` under `xvfb-run` when available (forced X11) or in
the current graphical session otherwise. It also reports the stripped prototype
size and full `ldd` closure. Static FLTK is expected, but system graphical/text
libraries can remain dynamic: a GUI requires a compatible graphical runtime and
is not subject to Babet CLI's headless deployment expectations.

## What Lot 9 deliberately cannot express

This list is the input to Lot 10. Do not work around it inside the prototype.

1. **Lua cannot call a host function.** The current public API only lets the host
   call Lua globals.
2. **Lua cannot create or destroy GUI objects.** Window/button creation remains
   hard-coded in C++.
3. **Lua cannot change a widget property on demand.** The button label changes
   only because C++ interprets the scalar return value of a callback.
4. **Lua cannot address host objects by an opaque ID.** There is no public
   host-function registration mechanism that could consume such IDs.
5. **Lua cannot request a host action outside a host-initiated callback.** Doing
   this through polled globals/timers would hide rather than solve the missing
   API and is intentionally forbidden here.
6. **Host callback result/error semantics do not exist yet.** Lot 10 must define
   how a registered C function receives scalar arguments, returns a scalar or
   error, owns strings, and interacts with context diagnostics.
7. **Host callback lifetime/reentrancy/thread rules do not exist yet.** Lot 10
   must define registration lifetime, context destruction behavior, same-thread
   requirements and whether nested host/Lua calls are allowed.

These are concrete limitations observed from a real consumer. Lot 10 should add
only the smallest C-only host-function surface needed to remove them.

## FLTK version and deployment note

The prototype pins FLTK 1.4.5, the current stable 1.4 release at implementation
time. The default FLTK 1.4 Linux configuration can support Wayland and X11 in a
hybrid build; exact enabled backends depend on the development packages present
when FLTK is configured.

This companion is optional desktop software. A successfully linked executable
still needs a compatible X11/Wayland graphical environment and whatever system
libraries appear in its measured `ldd` closure. That does not alter the normal
Babet CLI autonomy contract.
