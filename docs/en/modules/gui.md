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

`available()` loads and validates the narrow GTK/GLib symbol surface but does
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
- `container:add(child)` for windows and boxes
- `label:setText(text)` / `button:setText(text)` / `entry:setText(text)`
- `button:onClick(function)`
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

## Event loop and callbacks

GTK operations are main-thread only. A live GUI session and an active
`babet.curses` session are mutually exclusive. `gui.run()` owns the interactive
main loop until all windows are destroyed or `gui.quit()` is called. `gui.run()`
must be entered from the main Lua thread itself; calling it from a Lua coroutine
is rejected even when that coroutine is resumed on Babet's main OS thread.

Babet inserts a small bounded GLib wake source so its deferred Unix-signal
callbacks continue to be serviced while GTK owns the loop. Workers may continue
to perform non-GUI work, but they must not call GUI methods directly.

Lua button and entry callbacks execute under `lua_pcall`. An error is reported to stderr
with a `babet.gui callback error:` prefix and does not unwind across GTK's C
stack; the event loop remains usable.

## Lifetime rules

Lua handles are validated on every method call. Parent Lua handles keep child
handles alive, while GTK owns a child widget after `add()`. GTK's `destroy`
signal invalidates the corresponding Babet handle. Any later operation on that
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
