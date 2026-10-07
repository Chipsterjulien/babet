# GUI — optional GTK 4 desktop interface

`babet.gui` is Babet's optional desktop-GUI API. It is deliberately different
from `babet.curses`: the GUI toolkit is **not** linked into Babet. On Linux the
initial and only supported backend is GTK 4, loaded lazily from the target
system when GUI use is requested.

A script that never uses `babet.gui` keeps Babet's normal deployment contract.
A generated GUI application is still exactly one file, but GTK 4 must already
be installed on the target machine.

## Availability and initialization

```lua
local gui = babet.gui

local available, why = gui.available()
if not available then
    print(why)
    return
end

local ok, err = gui.init()
assert(ok, err)
```

`available()` loads and validates the narrow GTK/GLib/Cairo symbol surface but does
not initialize a display. Once a GTK DSO has been opened successfully, it is
kept resident until process exit, including when validation of a required symbol
fails. The load result is memoized, so later calls do not reopen GTK. `init()`
disables GTK's process-global locale change and then uses the recoverable GTK
initialization path. Both calls are restricted to Babet's main OS thread.

The first GTK loading attempt, through `available()` or `init()`, permanently
freezes process-wide mutations: `babet.setenv` and `babet.chdir` return
`nil, err`, and `os.setlocale(locale, category)` raises when `locale` is not
`nil`. Configure the environment, current directory and locale **before**
these calls. `babet.env`, `babet.currentDir` and
`os.setlocale(nil, category)` remain available as queries.

The freeze precedes `dlopen`: loading and initializing GTK can execute native
code and create threads independently of Babet workers. It remains even if
GTK is absent, a symbol is missing, or display initialization fails, and after
windows close or an embedding context is recreated. A call rejected before
loading (invalid arguments or wrong thread) does not trigger this freeze.

The guard covers Babet's Lua entry points. Hosts and native plugins must also
coordinate their own mutations and threads; Babet does not intercept direct
libc calls. See [GLib's threading and global-state guidance](https://docs.gtk.org/glib/threads.html).

If GTK 4 is absent, the diagnostic identifies the missing runtime and includes
installation examples for common Debian/Ubuntu, Arch Linux, and Fedora systems.
If GTK is installed but no graphical display can be initialized, `init()`
returns a display-specific diagnostic instead of terminating the process.

## Minimal widget API

```lua
local gui = babet.gui
assert(gui.init())

local window = gui.window {
    title = "Babet GUI",
    width = 480,
    height = 240,
}

local column = gui.box {
    orientation = "vertical", -- or "horizontal"
    spacing = 8,
}

local label = gui.label("Ready")
local button = gui.button("Run")

assert(window:add(column))
assert(column:add(label))
assert(column:add(button))

assert(button:onClick(function()
    assert(label:setText("Clicked"))
    assert(gui.quit())
end))

assert(window:show())
assert(gui.run())
assert(window:close())
```

The initial surface is intentionally small:

- `babet.gui.available()`
- `babet.gui.init()`
- `babet.gui.window([options])`
- `babet.gui.box([options])`
- `babet.gui.label(text)`
- `babet.gui.button(text)`
- `babet.gui.entry([options])`
- `babet.gui.drawingArea([options])`
- `babet.gui.scrolledWindow()`
- `babet.gui.spinButton([options])`
- `babet.gui.calendar([options])`
- `container:add(child)` for windows, boxes and ScrolledWindow
- `box:remove(child)` / `box:clear()`
- `scrolledWindow:remove(child)` / `scrolledWindow:clear()`
- `label:setText(text)` / `button:setText(text)` / `entry:setText(text)`
- `button:onClick(function)`
- `drawingArea:onClick(function_or_nil)`
- `spinButton:getValue()` / `spinButton:setValue(number)` / `spinButton:onChanged(function_or_nil)`
- `calendar:getDate()` / `calendar:setDate(year, month, day)` / `calendar:onChanged(function_or_nil)`
- common properties: `setMargins`, `setHExpand`, `setVExpand`, `setVisible`, `setSensitive`
- `window:show()` / `window:close()`
- `babet.gui.run()` / `babet.gui.quit()`

`window` options currently accept `title`, positive integer `width`, and positive
integer `height`. `box` options accept `orientation = "vertical"|"horizontal"`
and a non-negative integer `spacing`. GTK-facing strings reject embedded NUL
bytes because the toolkit APIs consume C strings.

## Entry: single-line text input

```lua
local entry = assert(gui.entry {
    text = "",             -- default: empty
    placeholder = "Name", -- default: empty
    editable = true,        -- default: true
})
assert(column:add(entry))

assert(entry:onChanged(function()
    print("Current text:", entry:getText())
end))
assert(entry:onActivate(function()
    print("Submitted:", entry:getText())
end))
```

Create the entry after `gui.init()` and keep its window alive while running the
event loop. `entry()` and `entry(nil)` use the defaults. Options are read from
the table itself, without invoking `__index`.

| Method | Contract |
| --- | --- |
| `entry:getText()` | Returns one Lua string: a snapshot of the current text. |
| `entry:setText(text)` | Replaces the text; may synchronously invoke `onChanged`. |
| `entry:setPlaceholder(text)` | Sets the hint for an empty, unfocused entry; `""` clears it. |
| `entry:setEditable(boolean)` | Enables/disables user editing; programmatic `setText` remains allowed. |
| `entry:onChanged(function_or_nil)` | Replaces the text-change callback; explicit `nil` removes it. |
| `entry:onActivate(function_or_nil)` | Replaces the activation callback, normally triggered by Enter; explicit `nil` removes it. |

Setters and callback registrations return `true, nil`. Creation returns a widget,
or `nil, diagnostic` on a controlled runtime failure. Invalid arguments or a
destroyed/wrong widget raise a Lua error. Text and placeholder must be strings
containing UTF-8 suitable for GTK, without embedded NUL bytes; numbers are not
converted to strings. `editable` requires an actual boolean. These operations
do not parse numbers or validate application data.

Callbacks receive no arguments: capture the entry and call `getText()` when
needed. The two callbacks are independent, and registering one does not invoke
it. A `setText()` notification runs before the setter returns, on the calling
Lua thread (including a coroutine resumed on the main OS thread). Events
processed by `gui.run()` use the main Lua thread. Callbacks cannot yield across
the GTK boundary. Errors, including an attempted yield, are reported and
contained. A callback may replace/remove itself or close its window; native
and Lua state remain valid until an active setter has returned. Changing text
from `onChanged` can trigger another notification: avoid unconditional recursive
updates, or temporarily remove the handler.

See [`examples/gui_entry/main.lua`](../../../examples/gui_entry/main.lua) for a
complete example with live text, Enter submission and a read-only toggle:

```sh
babet examples/gui_entry
babet --create-exe examples/gui_entry ./gui-entry-app
./gui-entry-app
```

## DrawingArea: native curves and click selection

`DrawingArea` can draw through Cairo and receive user clicks without an external
charting library.

```lua
local area = assert(gui.drawingArea {width = 640, height = 300})
assert(column:add(area))
assert(area:onDraw(function(ctx, width, height)
    assert(ctx:setSourceRGB(1, 1, 1))
    assert(ctx:rectangle(0, 0, width, height))
    assert(ctx:fill())
    assert(ctx:setSourceRGB(0.1, 0.4, 0.8))
    assert(ctx:setLineWidth(2))
    assert(ctx:moveTo(20, height - 20))
    assert(ctx:lineTo(width - 20, 20))
    assert(ctx:stroke())
    assert(ctx:setFontSize(14))
    assert(ctx:text(20, 22, "Native curve"))
end))
-- From a button/Entry callback, after changing the data:
assert(area:queueDraw())

assert(area:onClick(function(x, y, button)
    print("click", x, y, button)
end))
-- nil removes only the click callback:
assert(area:onClick(nil))
```

`drawingArea()` and `drawingArea(nil)` use 320 x 200 logical pixels. Options
`width` and `height` must be positive integers no greater than `INT_MAX`; they
request content size, not a fixed or maximum allocation. Options use raw table
access. GTK passes the actual allocation to `onDraw(ctx, width, height)`.

`area:onDraw(function_or_nil)` replaces the handler; explicit `nil` removes it.
Registration/removal schedules a redraw. `area:queueDraw()` requests a later
redraw; it does not call the handler synchronously. GTK may combine several
requests. Both methods return `true, nil` and are only for DrawingArea handles.

`area:onClick(function_or_nil)` replaces or removes the click callback. The callback
receives exactly `x`, `y`, `button`: the first two are Lua numbers in widget
allocation coordinates, and `button` is an integer (`1` for the primary button).
Unlike `onDraw`, this is an ordinary event callback: it may mutate widgets and
call `queueDraw()`. Errors are protected and reported to stderr like the other
GUI callbacks.

The context is borrowed and valid **only during that invocation of `onDraw`**.
A saved context raises a Lua error after return, failure or attempted yield.
Drawing runs on the main Lua thread; a synchronously resumed main-OS-thread
coroutine may use the context while that invocation is active. Workers cannot.
Callback argument allocation and user code are both protected against Lua
errors, including out-of-memory failures. Errors go to stderr; the loop survives.

During `onDraw`, draw from existing data. Widget creation, mutation, callback
registration and `queueDraw()` are rejected, even on other widgets. Prepare data
and request updates from an input callback instead. `entry:getText()` and
`gui.quit()` remain allowed; `quit()` only asks the loop to stop after GTK returns.
Widget finalizers triggered during drawing are deferred until GTK returns to
Babet. These rules respect [GTK's drawing-stage restrictions](https://docs.gtk.org/gtk4/method.DrawingArea.set_draw_func.html).

All methods below return `true, nil`. Invalid types, arity, ranges, expired
contexts and Cairo failures raise a Lua error. Numeric parameters must be actual,
finite Lua numbers; numeric strings, NaN and infinity are rejected.

| Context method | Meaning |
| --- | --- |
| `ctx:newPath()` | Clear the current path. |
| `ctx:moveTo(x, y)` | Start a subpath at the given point. |
| `ctx:lineTo(x, y)` | Add a straight segment. |
| `ctx:closePath()` | Join the current subpath back to its start. |
| `ctx:rectangle(x, y, width, height)` | Add a rectangle; signed dimensions are allowed. |
| `ctx:arc(x, y, radius, start, finish)` | Add an arc; non-negative radius, angles in radians, increasing angle direction. |
| `ctx:stroke()` | Draw and clear the path using the current line width and color. |
| `ctx:fill()` | Fill and clear the path using the current color. |
| `ctx:setLineWidth(width)` | Set a strictly positive line width. |
| `ctx:setSourceRGB(r, g, b)` | Opaque color; each component must be in [0, 1]. |
| `ctx:setSourceRGBA(r, g, b, a)` | Color with alpha; every component must be in [0, 1]. |
| `ctx:setFontSize(size)` | Set a strictly positive font size. |
| `ctx:text(x, y, text)` | Draw at a baseline position; valid UTF-8 string without NUL. |

Coordinates are GTK logical pixels, with the origin at the top left and Y
increasing downwards. Cairo preserves GTK's clipping and scale. Babet saves and
restores Cairo graphics state around the callback and clears the drawing path.
`arc` may connect to the current point; call `newPath()` for an independent arc.
`text` uses Cairo's minimal text API and changes the current point: finish a
line path before labeling it. It suits chart labels, not rich text, multiline
layout or complex script shaping. It does not expose a native pointer, retained
surface, image exporter or general Cairo binding.

See [`examples/gui_drawing/main.lua`](../../../examples/gui_drawing/main.lua):
an illustrative weight curve with unequal date intervals, automatic Y bounds
and a button that changes the data. It is a drawing demo, without persistence.

```sh
babet examples/gui_drawing
babet --create-exe examples/gui_drawing ./gui-drawing-app
./gui-drawing-app
```

## Refreshable containers: Box and ScrolledWindow (unreleased GUI lot 3)

A `Box` can now remove one child or clear all children:

```lua
assert(column:remove(old_widget))
assert(column:clear())
```

`remove(child)` requires the child to belong to that container. `clear()` removes
all children. In both cases, a child whose Lua handle is still held remains valid
and may be added to another `Box` or `ScrolledWindow`; the old parent stops
rooting it in Lua. This makes refreshable histories/lists possible without
rebuilding the whole window. `Window` deliberately does not expose
`remove()`/`clear()` in this surface.

`gui.scrolledWindow()` creates a native GTK scrolling container. It accepts one
logical child through `add(child)`; adding a second child before removing or
clearing the first is an error. Put a Box inside it for an arbitrary number of
rows.

## SpinButton: numeric input (unreleased GUI lot 4)

```lua
local weight = assert(gui.spinButton {
    min = 30, max = 250, step = 0.1, value = 91.4, digits = 1,
})
assert(weight:onChanged(function()
    print("Weight:", weight:getValue())
end))
assert(weight:setValue(90.8))
```

Defaults are `min = 0`, `max = 100`, `step = 1`, `value = 0`, `digits = 0`.
With a custom range and no explicit `value`, the initial value is `min`, matching
GTK's native range constructor. Numeric options must be finite Lua numbers;
`step` must be strictly positive and an explicitly supplied initial value must be
inside the range. `digits` is an integer from 0 to 20. Options use raw table
access. The SpinButton is configured for numeric input.

`getValue()` returns one Lua number. `setValue(number)` passes the value to GTK,
which constrains it to the SpinButton range. `onChanged(function_or_nil)` replaces
or removes the handler. A programmatic value change may call it synchronously
before `setValue()` returns. Native and logical state are pinned across that call,
including when the callback closes its window.

## Calendar: selecting and editing dates (unreleased GUI lot 5)

```lua
local date = assert(gui.calendar {year = 2026, month = 10, day = 7})
assert(date:onChanged(function()
    local year, month, day = date:getDate()
    print(year, month, day)
end))
assert(date:setDate(2025, 12, 31)) -- past dates are allowed
```

`calendar()` and `calendar(nil)` keep GTK's default selected date. To set a date
at construction, `year`, `month` and `day` must all be present, must be integers,
and must form a valid Gregorian date with year 1..9999. `getDate()` returns
exactly three values: `year, month, day`. `setDate(year, month, day)` also accepts
past dates. `onChanged(function_or_nil)` has the same protected, replaceable
callback contract as SpinButton and Entry.

The binding uses the Calendar API available since early GTK 4 instead of
requiring much newer setters, preserving compatibility with GTK 4 runtimes older
than 4.20.

## Common widget properties (unreleased GUI lot 6)

Every live widget exposes these methods:

| Method | Effect |
| --- | --- |
| `widget:setMargins(margin)` | Use the same non-negative integer margin on all four sides. |
| `widget:setMargins(top, end_, bottom, start_)` | Set the four GTK margins separately, in this order. |
| `widget:setHExpand(boolean)` | Enable/disable horizontal expansion. |
| `widget:setVExpand(boolean)` | Enable/disable vertical expansion. |
| `widget:setVisible(boolean)` | Show or hide the widget. |
| `widget:setSensitive(boolean)` | Enable or disable user interaction with the widget. |

Margins must be integers from 0 through `INT_MAX`; the other methods require
actual Lua booleans. They return `true, nil`. As with other GTK mutations, these
methods are rejected during `onDraw`. Read-only `entry:getText()`,
`spinButton:getValue()` and `calendar:getDate()` remain non-mutating operations.

## Event loop and callbacks

GTK operations are main-thread only. A live GUI session and an active
`babet.curses` session are mutually exclusive. `gui.run()` owns the interactive
main loop until all windows are destroyed or `gui.quit()` is called. `gui.run()`
must be entered from the main Lua thread itself; calling it from a Lua coroutine
is rejected even when that coroutine is resumed on Babet's main OS thread.

Babet inserts a small bounded GLib wake source so its deferred Unix-signal
callbacks continue to be serviced while GTK owns the loop. Workers may continue
to perform non-GUI work, but they must not call GUI methods directly.

Lua button, Entry, SpinButton and Calendar callbacks execute under `lua_pcall`.
An error is reported to stderr with a `babet.gui callback error:` prefix and does
not unwind across GTK's C
stack; the event loop remains usable.

## Lifetime rules

Lua handles are validated on every method call. Parent Lua handles keep child
handles alive, while GTK owns a child widget after `add()`. `remove()` and
`clear()` acquire a native reference before GTK unparents the child, then drop
the parent's Lua root; a child handle still held by the script therefore remains
valid and reusable. GTK's `destroy` signal invalidates the corresponding Babet
handle. Any later operation on that
handle raises a controlled Lua error rather than dereferencing a stale native
pointer.

Dropping an unparented widget handle releases its construction reference.
Dropping a top-level window handle destroys that window. During Lua-state
shutdown, GUI callback ownership is neutralized before `lua_close()`.

Callbacks belong to their Lua widget handle. Capturing that same widget in its
callback does not permanently root it: an unreachable widget/callback cycle is
collectable. A live parent still keeps its child handles and callbacks alive.

## `--create-exe`

No special packaging command is needed:

```sh
babet --create-exe ./my-gui-project my-gui-app
```

The result is one application file. Unlike a non-GUI Babet application, that
file is intentionally dependent on the GTK 4 runtime installed on its target
Linux system. No `babet-gtk.so` helper, extracted temporary DSO, compiler, or
linker is required at application launch or `--create-exe` time.

This GUI-only exception does not change the autonomy of scripts and generated
applications that do not use `babet.gui`.
