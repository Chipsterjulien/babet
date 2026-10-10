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

GTK 4 is discovered lazily only when the Lua program explicitly probes it with
`babet.gui.available()` or initializes the GUI. The implementation opens the
system GTK runtime with `dlopen()` and resolves only the narrow set of C symbols
it actually uses with `dlsym()`. Once a GTK DSO has been opened successfully, it
is kept resident until process exit, including when required-symbol validation
fails. The load result is memoized so later probes do not reopen GTK. Every
imported symbol is permanent maintenance surface; do not build a generic GTK
binding or mirror all of GTK.

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

Before the first `dlopen` attempt, freeze Babet's Lua mutations of environment,
current directory and process locale using the same serialized guard as
`workers.spawn`. This includes `gui.available()`: native constructors can run
during loading. Release the guard before calling native code. Keep the freeze
on load/symbol/display failure and after GUI or embedding teardown; do not
assume partially initialized native state or background threads disappear.
Queries remain available. Invalid calls rejected before loading do not freeze
state. Arbitrary native plugin/host libc calls remain their own responsibility.

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

All GTK/widget operations are main-thread only. `babet.gui.run()` is stricter:
it must be entered from the main Lua thread itself, not from a Lua coroutine
resumed on the same OS thread. Workers may perform non-GUI work but must never
touch GTK objects directly. A later worker-to-GUI notification
mechanism must marshal work onto the GTK/main thread, for example through a GLib
main-context wakeup/idle source; it must not weaken the owner-thread rule.

## Lua callback boundary

A GTK callback must never allow a Lua longjmp or a C++ exception to cross the
foreign GTK/GLib stack. Lua callbacks are invoked through a protected Lua call.
A normal Lua callback error is captured and reported by Babet; the GUI loop
remains structurally valid and can continue unless an explicit application
policy requests termination.

Entry text setters, SpinButton value setters and Calendar date setters may emit
callbacks synchronously. Dispatch them on the calling Lua thread, keep the native
object and logical state alive until the setter returns, and contain
errors/attempted yields. `Entry:setText()` has the stronger Babet contract added
in 2.28.1: suppress the native GtkEditable delete/insert signal burst while the
setter is active, then invoke the Lua `onChanged` handler exactly once with the
final value if it differs from the initial snapshot, and not at all if it is
identical. User-driven GTK `changed` events remain uncoalesced, including
intermediate states such as a temporary empty string when typing over a
selection. A callback may close the window, replace itself or reenter a setter.
Event-loop callbacks run
on the main Lua thread. Callback storage belongs to the widget userdata; the
native bridge resolves it through weak Lua handles so self-capturing callback
cycles remain collectable.

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
A native signal handler that needs independent `WidgetState` lifetime retains
that state when connected and releases it through `GClosureNotify` when the
handler is disconnected and no longer used. Shutdown ordering must disconnect
or neutralize callbacks and invalidate native handles before the Lua state is
closed.

## Initial API slice

The first runtime implementation is intentionally small. The target surface is:

- `babet.gui.available()`
- `babet.gui.init()`
- `babet.gui.window()`
- `babet.gui.box()`
- `babet.gui.label()`
- `babet.gui.button()`
- `babet.gui.entry()`
- `babet.gui.drawingArea()`
- `babet.gui.scrolledWindow()` / `babet.gui.spinButton()` / `babet.gui.calendar()`
- `babet.gui.setCss()`
- `container:add()` / Box and ScrolledWindow `remove()` / `clear()`
- `widget:setText()` and common layout/state/CSS-class setters
- `button:onClick()` / `drawingArea:onClick()`
- `entry:getText()` / `entry:setPlaceholder()` / `entry:setEditable()`
- `entry:onChanged()` / `entry:onActivate()`
- `window:show()`
- `window:close()`
- `babet.gui.run()`
- `babet.gui.quit()`

The runtime MVP now freezes the following shapes after red structural tests:
`window({title=?, width=?, height=?})`, `box({orientation=?, spacing=?})`,
`label(text)`, `button(text)`, and `entry({text=?, placeholder=?, editable=?})`.
Entry callback registration accepts a function or explicit `nil` to remove
that handler; `getText()` returns one copied string. Mutating operations return Babet's usual
`true, nil` success pair; controlled runtime failures return `nil, diagnostic`.
GTK-facing strings reject embedded NUL bytes. Do not add checkboxes, menus, tree
views, dialogs, clipboard, drag-and-drop, OpenGL, or a generic GObject surface
without a concrete application need and dedicated runtime tests. CSS remains the
narrow `setCss` plus widget-class surface described below.

Typed GTK constructors/functions are preferred over generic variadic creation
such as `g_object_new()`. GObject Introspection is deliberately out of scope:
loading typelibs, generic dynamic conversion and libffi would create a larger
binding framework than Babet needs.

## Incremental input and drawing roadmap

The next application need is a native desktop weight log using Lua, SQLite and
GTK, without a browser, HTTP service or JavaScript. It justifies generic GUI
primitives, not weight-specific runtime functions. The planned primitive lots are
implemented in order: Entry (2.25.0), DrawingArea plus Box/ScrolledWindow,
SpinButton, Calendar and common widget properties (2.26.0), DrawingArea click
selection (2.27.0), and application CSS/classes (2.28.0). Version 2.28.1
hardens these contracts against real GTK behavior. Keep the existing camelCase
public method convention.

Box/ScrolledWindow removal must reacquire a native reference before GTK
unparents a child, then remove the parent's Lua root. A surviving child handle
therefore remains valid and can be reparented. ScrolledWindow owns at most one
logical child. SpinButton exposes finite numeric range/value options, `getValue`,
`setValue` and the shared `onChanged` callback contract. Calendar exposes strict
Gregorian `year/month/day`, `getDate`, `setDate` and `onChanged`, while permitting
past dates. Common widget setters are `setMargins`, `setHExpand`, `setVExpand`,
`setVisible` and `setSensitive`.

The weight-log application must preserve SQLite row identity during edits/deletions,
allow several measurements per day (no UNIQUE constraint on the date), and allow
past dates. Its graph must sort chronologically, position points using actual date
intervals and derive the vertical range from the data. These remain application
requirements rather than weight-specific runtime behavior.

## Drawing callback contract

`drawingArea({width=?, height=?})` requests a positive content size (default
320 x 200). `onDraw(fn_or_nil)` replaces/removes the handler and requests repaint;
`queueDraw()` requests an asynchronous repaint. The callback gets a borrowed
typed context and the actual width/height. No native pointer is public.

Protect context/argument allocation and the user callback separately with
`lua_pcall`. Keep the context rooted until its native pointer is invalidated,
including on callback error or OOM. Methods reject an expired context. Cairo's
graphics state is saved/restored; the path is cleared before/after drawing.
Numbers must be finite; colors are in [0, 1], line/font size positive, radius
non-negative. Text is strict UTF-8 without NUL; the toy Cairo text API is only
for simple labels, not a Pango or rich-text replacement.

GTK widget mutation is prohibited throughout a draw callback. Read-only Entry
text queries and `gui.quit()` remain allowed. Lua finalizers may run inside
drawing; detach their handles immediately and defer native widget destruction
through an allocation-free queue drained after GTK returns to Babet. A native
draw destroy-notifier retains/releases WidgetState; callback functions still
belong to the Lua widget handle and self-capturing cycles remain collectable.

`DrawingArea:onClick(fn_or_nil)` is an ordinary event callback, independent of
`onDraw`. It receives `(x, y, button, n_press)`, where `n_press` is the consecutive
press count supplied by `GtkGestureClick`. It may mutate widgets and request a
redraw. The gesture controller is owned for the full native DrawingArea lifetime;
replacing/removing the Lua callback must not recreate or leak the controller.

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

## Styling surface

The optional GTK backend exposes one application CSS provider plus per-widget CSS classes. This remains a narrow styling layer (`gui.setCss`, `widget:addClass`, `widget:removeClass`), not generic GObject introspection or a complete GTK property binding. Prefer `gtk_css_provider_load_from_string()` when the runtime exports it (GTK 4.12+); otherwise fall back to `gtk_css_provider_load_from_data()` so GTK 4.0-4.10 remain supported. At least one loader symbol is required, but neither is a direct link-time dependency.

The deterministic fake GTK remains the fault-injection harness, but release validation also includes an optional system-GTK probe under Xvfb with `G_DEBUG=fatal-criticals`. Missing GTK/Xvfb/X11/XTest is a documented SKIP; when present, failures are release-test failures. This second layer exists specifically to catch semantic drift between the fake runtime and real GTK.

