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
- `container:add(child)` for windows and boxes
- `label:setText(text)` / `button:setText(text)`
- `button:onClick(function)`
- `window:show()` / `window:close()`
- `babet.gui.run()` / `babet.gui.quit()`

`window` options currently accept `title`, positive integer `width`, and positive
integer `height`. `box` options accept `orientation = "vertical"|"horizontal"`
and a non-negative integer `spacing`. GTK-facing strings reject embedded NUL
bytes because the toolkit APIs consume C strings.

## Event loop and callbacks

GTK operations are main-thread only. A live GUI session and an active
`babet.curses` session are mutually exclusive. `gui.run()` owns the interactive
main loop until all windows are destroyed or `gui.quit()` is called. `gui.run()`
must be entered from the main Lua thread itself; calling it from a Lua coroutine
is rejected even when that coroutine is resumed on Babet's main OS thread.

Babet inserts a small bounded GLib wake source so its deferred Unix-signal
callbacks continue to be serviced while GTK owns the loop. Workers may continue
to perform non-GUI work, but they must not call GUI methods directly.

Lua button callbacks execute under `lua_pcall`. An error is reported to stderr
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
