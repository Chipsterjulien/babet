# Babet optional GUI design

Status: post-2.23.0 design contract.  This document replaces the earlier
FLTK companion-host study as the active GUI direction.

## Product contract

`babet.gui` is an optional, system-dependent GUI feature. Its absence must not
change the behaviour of the Babet runtime or the autonomy of applications that
do not use it.

A generated application that uses `babet.gui` is still published as exactly one
application file by `--create-exe`, but it is no longer deployable by arbitrary
simple copy: the requested GUI runtime must already be present on the target
machine. This is an explicit and accepted exception limited to GUI use.

The first and only supported backend in the initial Linux implementation is
**GTK 4**. The public namespace is called `babet.gui` because it is Babet's GUI
API, not because Babet promises interchangeable toolkit backends. The API should
avoid needless GTK-specific leakage so another backend is not architecturally
forbidden, but no FLTK, wxWidgets, Qt, or other backend is currently promised.

## Loading model

The normal Babet build must not link GTK, download GTK, require GTK development
headers, or require `pkg-config gtk4`.

GTK 4 is discovered lazily only when the Lua program explicitly initializes the
GUI. The implementation opens the system GTK runtime with `dlopen()` and resolves
only the narrow set of C symbols it actually uses with `dlsym()`. Every imported
symbol is permanent maintenance surface; do not build a generic GTK binding or
mirror all of GTK.

The expected Linux runtime soname for the first implementation is
`libgtk-4.so.1`. Missing GTK, a missing required symbol, or failure to initialize
the display must become a controlled Lua-visible diagnostic, never a process
abort. Diagnostics should identify GTK 4 and may give install examples for
common distributions, for example Debian/Ubuntu, Arch Linux, and Fedora.

Native plugins are not the GUI backend mechanism. A `babet-gtk.so` companion
would violate the generated application's one-file contract. The GUI bridge
lives in Babet itself while the heavy GUI toolkit remains a system dependency.
No extraction of a helper DSO to `/tmp` or another temporary directory is
allowed.

## GTK initialization and process state

GTK initialization is main-thread only. The implementation must call
`gtk_disable_setlocale()` before GTK initialization so optional GUI use does not
silently change Babet's process-global locale.

Use `gtk_init_check()`, never `gtk_init()`: inability to initialize a display is
a recoverable Babet error and must not terminate the process from inside GTK.
GTK 4 removed the old `gtk_main()` API; the initial implementation must drive
the default GLib main context explicitly rather than depending on removed GTK 3
main-loop entry points.

## Main-loop ownership

At any instant only one interactive subsystem owns the main-thread interactive
loop. The initial owner classes are normal Babet execution, ncurses, and GUI.
An active ncurses session and an active GUI session are mutually exclusive.
Attempting to start one while the other owns the interactive session must fail
cleanly before toolkit state is mutated.

All GTK/widget operations are main-thread only. Workers may perform non-GUI work
but must never touch GTK objects directly. A later worker-to-GUI notification
mechanism must marshal work onto the GTK/main thread, for example through a GLib
main-context wakeup/idle source; it must not weaken the owner-thread rule.

## Lua callback boundary

A GTK callback must never allow a Lua longjmp or a C++ exception to cross the
foreign GTK/GLib stack. Lua callbacks are invoked through a protected Lua call.
A normal Lua callback error is captured and reported by Babet; the GUI loop
remains structurally valid and can continue unless an explicit application
policy requests termination.

Do not keep binding-owned C++ RAII objects alive across an unprotected Lua API
operation that may raise. The existing Babet Lua/C++ exception and protected-
builder discipline applies unchanged to the GUI binding.

## Widget lifetime

Lua-facing widget handles do not keep destroyed native widgets artificially
alive. A handle records native identity and validity. When GTK destroys the
underlying widget, every associated Lua handle is invalidated. Any later method
call on a dead handle must raise a controlled Lua error such as "widget has
already been destroyed", never dereference a stale pointer.

Parent/child ownership and GTK floating-reference semantics must be dealt with
inside the bridge; they are not exposed as Lua reference-counting rules.
Callbacks connected to a widget must not outlive the Lua/GTK state they target.
Shutdown ordering must disconnect or neutralize callbacks and invalidate native
handles before the Lua state is closed.

## Initial API slice

The first runtime implementation is intentionally small. The target surface is:

- `babet.gui.available()`
- `babet.gui.init()`
- `babet.gui.window()`
- `babet.gui.box()`
- `babet.gui.label()`
- `babet.gui.button()`
- `container:add()`
- `widget:setText()`
- `button:onClick()`
- `window:show()`
- `window:close()`
- `babet.gui.run()`
- `babet.gui.quit()`

The runtime MVP now freezes the following shapes after red structural tests:
`window({title=?, width=?, height=?})`, `box({orientation=?, spacing=?})`,
`label(text)`, and `button(text)`. Mutating operations return Babet's usual
`true, nil` success pair; controlled runtime failures return `nil, diagnostic`.
GTK-facing strings reject embedded NUL bytes. Do not add checkboxes, menus, tree
views, dialogs, clipboard, CSS, drag-and-drop, OpenGL, or a generic GObject
surface before this slice is proven in folder mode and through `--create-exe`.

Typed GTK constructors/functions are preferred over generic variadic creation
such as `g_object_new()`. GObject Introspection is deliberately out of scope:
loading typelibs, generic dynamic conversion and libffi would create a larger
binding framework than Babet needs.

## Validation status before widening the API

The first GTK runtime lot is validated on the maintainer x86_64 Linux machine as
of 2026-08-26. The regression suite proves all of the following:

1. Babet builds and runs on a machine with no GTK development package.
2. A non-GUI script does not attempt to load GTK.
3. Missing `libgtk-4.so.1` produces a controlled diagnostic only when GUI is
   requested.
4. A minimal real/fake GTK fixture exercises window/button/callback lifecycle.
5. A deliberate Lua error inside a GUI callback is contained.
6. GUI and ncurses ownership conflicts are rejected deterministically.
7. Dead widget handles fail safely.
8. `--create-exe` publishes exactly one file for a GUI project, that file runs
   after the source project is removed, and it uses the target system GTK.
9. The normal Babet binary has no direct GTK `DT_NEEDED` dependency.
10. The complete existing Babet harness remains green.

The dedicated GUI runtime regression is green at 9 PASS / 0 FAIL, while the
complete Babet campaign remains 3810/0 in folder mode, 3796/0 embedded, 3796/0
embedded-via-PATH, and 9/9 top-level modes. The stripped CLI measures
15,559,496 bytes, only 36,864 bytes (+0.24%) above the published 2.23.0 CLI
measurement. Only a concrete application need can now justify a wider widget
surface or a second GUI backend.
