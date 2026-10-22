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
- `babet.gui.setCss(css_or_nil)`
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
- `calendar:markDay(day)` / `calendar:unmarkDay(day)` / `calendar:clearMarks()` / `calendar:onViewChanged(function_or_nil)`
- common properties: `setMargins`, `setHExpand`, `setVExpand`, `setVisible`, `setSensitive`, `addClass`, `removeClass`
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
| `entry:setText(text)` | Replaces the text. If the final value differs, invokes `onChanged` exactly once synchronously with the final text; identical text invokes no callback. |
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
it. For programmatic `setText()`, Babet deliberately hides GTK's internal
delete/insert notification burst and emits at most one `onChanged` after GTK
returns from the native setter: exactly one when the final text differs from the
initial snapshot, none when it is identical. The callback therefore observes the
final value, never an intermediate empty string caused by GTK's implementation.
That synthetic notification still runs before `setText()` returns, on the calling
Lua thread (including a coroutine resumed on the main OS thread). User edits
continue to follow GTK's ordinary `changed` events, including intermediate
states: for example, typing over a selection may briefly expose an empty
string. Only `entry:setText()` applies the coalescing described above. Events
processed by `gui.run()` use the main Lua thread. Callbacks cannot yield across the GTK
boundary. Errors, including an attempted yield, are reported and contained. A
callback may replace/remove itself or close its window; native and Lua state
remain valid until an active setter has returned. Changing text from `onChanged`
can trigger another notification: avoid unconditional recursive updates, or
temporarily remove the handler.

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

assert(area:onClick(function(x, y, button, n_press)
    print("click", x, y, button, n_press)
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
receives exactly `x`, `y`, `button`, `n_press`: the first two are Lua numbers in
widget allocation coordinates, `button` is an integer (`1` for the primary
button), and `n_press` is GTK's consecutive press count (`1` for a single click,
`2` for the second press of a double-click, and so on). Existing Lua functions
that declare only three parameters remain valid because Lua ignores extra
arguments.
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

## Refreshable containers: Box and ScrolledWindow

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

## SpinButton: numeric input

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

## Calendar: selecting and editing dates

```lua
local date = assert(gui.calendar {year = 2026, month = 10, day = 7})
assert(date:onChanged(function()
    local year, month, day = date:getDate()
    print(year, month, day)
end))
local daysByMonth = { ["2026-10"] = {7, 18}, ["2025-12"] = {31} }
local function refreshMarks()
    local year, month = date:getDate() -- only the displayed year/month
    assert(date:clearMarks())
    local key = string.format("%04d-%02d", year, month)
    for _, day in ipairs(daysByMonth[key] or {}) do
        assert(date:markDay(day))
    end
end
assert(date:onViewChanged(refreshMarks))
refreshMarks() -- initial display
assert(date:setDate(2025, 12, 31)) -- past dates are allowed
refreshMarks() -- setDate() does not invoke onViewChanged()
```

`calendar()` and `calendar(nil)` keep GTK's default selected date. To set a date
at construction, `year`, `month` and `day` must all be present, must be integers,
and must form a valid Gregorian date with year 1..9999. `getDate()` returns
exactly three values: `year, month, day`. `setDate(year, month, day)` also accepts
past dates. `onChanged(function_or_nil)` has the same protected, replaceable
callback contract as SpinButton and Entry.

Since Babet **2.30.0**, Calendar also exposes `markDay`, `unmarkDay`,
`clearMarks` and `onViewChanged`.

`markDay(day)` places GTK's native visual marker on a day number;
`unmarkDay(day)` removes it and `clearMarks()` removes all markers. `day` must
be an integer from 1 through 31. Markers remain attached to **day numbers** when
the displayed month changes: marking day 5 also marks day 5 in subsequent months.
For dated data, clear and rebuild the markers for each displayed month.

`onViewChanged(function_or_nil)` runs on native user navigation to the
previous/next month or year (header arrows, scrolling, keyboard or selection of
a greyed-out day in an adjacent month). **`setDate()` does not invoke it**, even
when changing the month or year. After a successful `setDate()`, call the same
marker-refresh function explicitly, as above; otherwise the previous markers
remain on the new month.

GTK navigation can also adjust the selected day **without `onChanged()`**.
For example, with GTK 4.14, moving forward from 31 January 2024 selects
29 February and emits only `onViewChanged`. Selecting a greyed-out day can
produce two stages: `onViewChanged` first sees the new month with an intermediate
day (29 February in this example), then `onChanged` sees the selected day
(e.g. 1 February).

Use only the **year and month** from `getDate()` when rebuilding markers in
`onViewChanged`; its day is not necessarily the final user selection. If the
application tracks the complete selected date, read `getDate()` in both
callbacks and again when confirming an operation. Do not assume that
`onChanged` alone reports every date change, or that every navigation is followed
by `onChanged`. Babet forwards these native GTK signals without synthesizing an
extra selection notification.

The binding uses the Calendar API available since early GTK 4 instead of
requiring much newer setters, preserving compatibility with GTK 4 runtimes older
than 4.20.

## CSS styling

Babet can install one application-level GTK CSS provider and attach CSS classes to individual widgets:

```lua
assert(gui.setCss([[
.card { background: #ffffff; border-radius: 12px; padding: 12px; }
.primary { background: #2563eb; color: white; }
]]))

local panel = assert(gui.box())
assert(panel:addClass("card"))
local button = assert(gui.button("Save"))
assert(button:addClass("primary"))
assert(button:removeClass("primary"))
assert(gui.setCss(nil))
```

`gui.setCss(css_or_nil)` replaces the application stylesheet for the current Lua GUI owner. `nil` removes it. `widget:addClass(name)` and `widget:removeClass(name)` work on every live widget; pass class names without a leading dot. CSS parsing diagnostics are reported by GTK. On GTK 4.12 and newer Babet uses `gtk_css_provider_load_from_string()`; on GTK 4.0–4.10 it falls back to the older `gtk_css_provider_load_from_data()` API. Neither symbol is a direct link-time dependency.

## Common widget properties

Every live widget exposes these methods:

| Method | Effect |
| --- | --- |
| `widget:setMargins(margin)` | Use the same non-negative integer margin on all four sides. |
| `widget:setMargins(top, end_, bottom, start_)` | Set the four GTK margins separately, in this order. |
| `widget:setHExpand(boolean)` | Enable/disable horizontal expansion. |
| `widget:setVExpand(boolean)` | Enable/disable vertical expansion. |
| `widget:setVisible(boolean)` | Show or hide the widget. |
| `widget:setSensitive(boolean)` | Enable or disable user interaction with the widget. |
| `widget:addClass(name)` | Add a GTK CSS class to the widget. |
| `widget:removeClass(name)` | Remove a GTK CSS class from the widget. |

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


## GTK4 additions — freely positioned notes (2.29.0)

These are **general-purpose** GUI components, with no built-in task database.
The application is responsible for storing note contents and positions.

* `gui.fixed()` is a free-position canvas: `canvas:put(child, x, y)`,
  `canvas:move(child, x, y)`, `canvas:remove(child)`, `canvas:clear()`.
* `gui.textView {text="...", editable=true}` supports `getText()`, `setText()`,
  `setEditable(boolean)`, `onChanged(callback or nil)`.
* `gui.checkButton {label="...", active=false}` supports `getActive()`,
  `setActive(boolean)`, `setText(label)`, `onChanged(callback or nil)`.
* `gui.progressBar()` supports `setFraction(0..1)`, `getFraction()`,
  `setShowText(boolean)`, `setText(label)`, `onClick(callback or nil)`.
* `gui.expander {label="...", expanded=false}` supports `add(child)` (one child),
  `remove(child)`, `clear()`, `setExpanded(boolean)`, `getExpanded()`, `setText(label)`.
* On a non-interactive label, box, drawingArea, fixed or progressBar, `onDrag(function(phase, x, y) ... end or nil)`
  installs a drag gesture. `"begin"` sends widget-local start coordinates;
  `"update"` and `"end"` send offsets from the drag start in stable GTK surface coordinates, even when the handle moves. The application
  moves the desired widget using `canvas:move(...)`. Install on a title/drag
  handle instead of on interactive controls (button, entry, checkButton, textView, expander, etc.).
* All widgets support `setSizeRequest(width, height)`; `-1` means automatic
  sizing. Canvas coordinates must be finite and between ±10,000,000.

A child removed from the fixed canvas remains usable. For a scrolling area,
put `gui.fixed()` inside `gui.scrolledWindow()` and request sufficient canvas
size. GTK4 does not automatically arrange children inside `GtkFixed`.

Working example: [`examples/gui_free_notes/main.lua`](../../../examples/gui_free_notes/main.lua).


## Native clickable progress bars and in-place list reordering

Babet exposes the real GTK4 `GtkProgressBar` and
`gtk_box_reorder_child_after()`; no custom drawing or remove/recreate
workarounds are needed.

- `progressBar:onClick(function_or_nil)` installs or clears a protected
  callback receiving `(x, y, button, n_press)` on **primary-button press**.
  Coordinates are widget-local. `n_press` is GTK's consecutive-click counter,
  **not** the total number of application steps. The application maintains its
  own step count and calls `setFraction(0..1)`. Automatic calculated progress
  remains fully supported. The label to the right is a separate `gui.label()`.
  A progress bar is not a keyboard-activatable button: when progression is an
  action rather than display-only feedback, provide an equivalent real button
  or another keyboard-accessible control as well.
- `box:reorder(child, previousChild_or_nil)` moves an **existing** child of
  the same `gui.box` natively and in place. The second argument is required:
  pass `nil` explicitly for first position;
  otherwise the widget goes immediately after `previousChild`. Ownership and
  callbacks are unchanged, and Babet's Lua child order stays in sync. Invalid
  children are rejected without mutation. A no-op succeeds.

```lua
local bar, text = assert(gui.progressBar()), assert(gui.label("The graphics"))
local row = assert(gui.box {orientation = "horizontal", spacing = 8})
assert(row:add(bar)); assert(row:add(text))
assert(bar:setHExpand(true))
local count = 0
assert(bar:onClick(function(x, y, button, n_press)
    count = math.min(4, count + 1)
    assert(bar:setFraction(count / 4))
    if count == 4 then assert(text:addClass("completed")) end
end))
-- Move the last checklist row immediately after the first one:
assert(list:reorder(last, first))
```

For native text strikethrough styling apply GTK CSS such as:
`label.completed, checkbutton.completed label { text-decoration-line: line-through; }`.
A check button's `onChanged()` handler can add/remove its `completed` class.

### Native GTK4 drag-and-drop for list rows

Since Babet **2.31.0**, native DND is available alongside `onDrag()`:

- `handle:setDragData(string_or_nil)` installs a real **`GtkDragSource`** on a
  non-interactive widget (`label`, `box`, `drawingArea`, `fixed` or
  `progressBar`). The UTF-8 string is the application payload; `nil` disables
  the source without rebuilding the widget. The string must be valid UTF-8 and
  embedded NUL bytes are rejected. MOVE remains the default action and the
  default drag icon shows the handle widget.
- `target:onDrop(function_or_nil)` installs a real **`GtkDropTarget`** on any
  non-window widget. The protected callback receives
  `(phase, payload, x, y, action)` for `"enter"`, `"motion"`, `"drop"` and
  `"leave"`. `action` is the currently preferred `"copy"`, `"move"` or
  `"link"`; `leave` receives nil payload/coordinates/action. During hover, a
  backend may not have preloaded the string yet, so `payload` can be nil on
  `enter`/`motion`; it is present on `drop`.
- Callbacks accept by default (`nil` or `true`). `false` or an error refuses the
  current notification. Returning `"copy"`, `"move"` or `"link"` accepts and
  explicitly prefers that enabled action **during `enter`/`motion`**. In `drop`,
  the action can no longer be changed: return `nil`, `true`, or the same action
  received by the callback to accept, and `false` to refuse. A different action
  string raises a contained callback error and rejects the transfer. For a
  transfer between Babet widgets, the source's `end` callback receives
  `delete_data=false` after a refusal. Validate the received action **before
  modifying the model**: refusing a transfer does not undo Lua-side changes.
  Refusing `enter`/`motion` **does not cancel the gesture**:
  further motion, `leave` and possibly `drop` can follow. Revalidate the ID and
  position in `drop`; return `false` if the operation is forbidden.
- `onDrop(nil)` disables the **native target** as well as its Lua callback and
  cancels an ongoing hover/preload. A disabled child no longer intercepts drops
  for a parent target or the widget's built-in text handling. Calling
  `onDrop(function)` enables the same controller again.
- Disabling inside a callback rejects the current transfer for that target.
  Re-enabling affects the next gesture, even when immediate. Existing model
  changes are not undone.
- The transfer owns its payload: changing or clearing `setDragData()` during a
  gesture affects subsequent gestures, not the ID already being transferred.
- MOVE is the compatibility default. `setDragActions(action_or_array)` and
  `setDropActions(action_or_array)` enable any combination of `copy`, `move`
  and `link`. Ctrl prefers COPY, Shift prefers MOVE, and Ctrl+Shift prefers LINK
  when the target allows it; the callback can override the preference by
  returning an enabled action string during `enter`/`motion`. Babet transports only the stable ID: the
  application still owns its model and performs the actual copy/move/link.
- `setDragIcon(widget_or_nil)` selects a custom live widget as the native drag
  preview. At each drag start, an unmapped, hidden, detached or destroyed preview
  falls back to the source handle. A standalone `gui.label("Preview")` is therefore
  not rendered off-screen; use a widget displayed in a window for a custom image.
  `nil` restores the handle. Babet keeps the chosen handle alive without reparenting it.
  `onDragState(function_or_nil)` reports `begin`, `end` and `cancel` as
  `(phase, detail, action)`; for `end`, `detail` is the boolean telling the
  source whether its data should be deleted, while `cancel` receives the native
  cancellation reason. After a refused local drop, GTK may still report the
  previously selected action and omit `cancel`: use the `end` boolean to decide
  whether to delete source data, not the action name alone. Babet vetoes this
  boolean when its local target refused the transfer, including callback errors.

Use a dedicated non-interactive handle. Avoid combining `onDrag()` and
`setDragData()` on the same widget: `onDrag` can start first, then lose the
sequence when native DND takes over at its drag threshold.

With nested targets, the parent also receives `enter`/`motion` while hovering
its child. If the parent accepts the hover, the child can still receive `drop`
even after returning `false` during hover. **Revalidate every final drop.**
Returning `false` from the child's `drop` does not forward it to the parent;
only disabling the child with `onDrop(nil)` makes it transparent.

**Do not wait for `leave` after a drop.** GTK may finish an accepted or refused
drop without emitting `leave`, including on the parent. In every `drop` handler,
clear the indicators on all participating targets before validating or updating
the model. Keep `leave` cleanup for a pointer exit/cancelled gesture:

```lua
local rows = { ["task-42"] = rowA }
local function clearDropIndicators()
    for _, widget in ipairs({list, rowA, rowB}) do
        assert(widget:removeClass("drop-target"))
    end
end
assert(handleA:setDragData("task-42"))
assert(rowB:onDrop(function(phase, payload, x, y)
    if phase == "enter" or phase == "motion" then
        assert(rowB:addClass("drop-target"))
    elseif phase == "leave" then
        assert(rowB:removeClass("drop-target"))
    elseif phase == "drop" then
        clearDropIndicators() -- shared by every drop handler, including list's
        local moved = rows[payload]
        if not moved or moved == rowB then return false end
        assert(list:reorder(moved, rowB)) -- move immediately after rowB
    end
end))
```

If the parent `list` also has an `onDrop` handler, call the same cleanup function
in its `drop` branch, including when rejecting the drop.

To insert before a target, pass the target's previous row from the application
model to `reorder()` (or explicit `nil` for first position). The insertion
indicator and persistence remain application concerns, but the gesture/drop path
itself is native `GtkDragSource`/`GtkDropTarget`, not an `onDrag()` simulation.


## Desktop-application primitives

Available since Babet **2.32.0**.

This layer is intentionally generic. It provides the GTK4 mechanics required by
rich desktop applications without adding note, task, tree or persistence models
to Babet.

### Split panes, menus and context popovers

- `gui.paned{orientation="horizontal"|"vertical", position=..., resizeStart=...,
  resizeEnd=..., shrinkStart=..., shrinkEnd=..., wideHandle=...}` wraps
  `GtkPaned`. It accepts exactly two children through `add()`. Use
  `getPosition()`, `setPosition(px)` and `onPositionChanged(function_or_nil)` to
  persist a sidebar width.
  Defaults: `orientation="horizontal"`, `resizeStart=false`, `resizeEnd=true`,
  `shrinkStart=true`, `shrinkEnd=true`, `wideHandle=false`; an omitted `position`
  leaves the initial divider placement to GTK. In particular, Babet defaults
  `resizeStart` to false (GTK itself defaults it to true).
- `gui.separator([orientation])` exposes a native `GtkSeparator`.
- `gui.menuButton{label="..."}` or `gui.menuButton{icon="..."}` plus
  `gui.popover{hasArrow=..., autohide=..., position="left|right|top|bottom"}`
  build menu bars and mark menus from ordinary Babet widgets. A popover has one
  content child. `menuButton:setPopover(popover_or_nil)`, `popup()` and
  `popdown()` manage an anchored menu.
  Avoid calling `popup()` immediately followed by `popdown()` in the same
  callback with `autohide=true`: GTK may swallow the next key event. Open
  the menu and close it in response to a later event.
- For a pointer-positioned context menu, call `popover:attachTo(widget)`,
  `setPointingTo(x,y[,width,height])`, then `popup()`. `attachTo(nil)` detaches
  the popover so it can be reused elsewhere. Direct attachment is deliberately
  limited to popovers; it is not a generic escape hatch for arbitrary GTK
  parenting. Destroying the parent detaches its context popovers; a retained
  popover handle can be attached to another live widget. Parenting cycles are
  rejected before mutation, including paths through menus and context popovers.

A top menu/toolbar can therefore remain ordinary GTK widgets: a horizontal
`gui.box()` containing `menuButton`, `button`, `image` and `separator` children.
`gui.image(iconName)` and `setIconName(iconName)` on images/buttons/menu buttons
use the target desktop's icon theme.

### Generic pointer, keyboard, focus and geometry

`widget:onPointer(function_or_nil)` installs native click and motion controllers.
The callback receives `(phase, x, y, button, n_press, modifiers)` where `phase`
is `press`, `release`, `enter`, `motion` or `leave`; `leave` has nil coordinates.
Unlike `onClick`, all mouse buttons are reported, so button 3 can open a context
menu. `widget:onKey(function_or_nil)` receives
`(phase, key_name_or_nil, keyval, keycode, modifiers)` for `press`/`release`; a
truthy return from `press` consumes the event. On a window, the controller runs
in GTK **capture** phase so application shortcuts such as `Ctrl+1` or `Escape`
are seen before a focused `TextView`/`Entry` can consume them.
On an `Entry` or `TextView` itself, GTK can consume text input before `onKey`
receives it. Do not use that callback to collect typed characters: use
`onChanged` for text and the window's `onKey` for application shortcuts.

Modifier masks are exported as `gui.MOD_SHIFT`, `gui.MOD_CONTROL`, `gui.MOD_ALT`
and `gui.MOD_SUPER`. Test masks with Lua 5.5 bitwise operators, e.g.
`(mods & gui.MOD_CONTROL) ~= 0`.

Common desktop helpers are:

- `setCursor(name_or_nil)` and `setTooltipText(text_or_nil)`;
- `grabFocus()` / `hasFocus()`;
- `getSize()` for the current allocated `(width,height)`;
- `translatePoint(target,x,y)` to express one widget point in another widget's
  coordinate system; it returns `nil` if GTK cannot translate between them;
- `pick(x,y)`, which performs native GTK hit-testing and walks back to the
  nearest Babet widget handle. This lets a free canvas distinguish a background
  click from a click on a child note;
- `setHAlign("fill|start|end|center|baseline")` and the equivalent `setVAlign`;
- `textView:setWrapMode("none|char|word|word-char")`; `wrap=` accepts the same
  values at construction time.

These primitives are sufficient for hover-only resize/move handles and precise
insertion indicators. The application decides hit zones and visual CSS; Babet
does not infer a note layout.

`getSize`, `translatePoint` and `pick` reflect the last completed GTK layout.
Immediately after `add`, `remove` or another layout change in the same callback,
their results may still describe the previous arrangement. Query them after GTK
has processed the next layout; returning from a callback alone does not force it.

### Desktop windows

`window:setTitle(text)`, `window:setIconName(iconName)`,
`window:setTransientFor(parent_or_nil)` and `window:setModal(boolean)` support
properties/dialog windows. `window:onCloseRequest(function_or_nil)` runs a
protected callback before a user close; returning `true` blocks that close. Use
this only for policy such as unsaved-change confirmation—programmatic
`window:close()` remains explicit.
If the close-request callback raises an error,
Babet reports it and allows the user-requested close to continue.
