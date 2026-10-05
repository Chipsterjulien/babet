> **English** | [Français](../../fr/modules/curses.md)

# CURSES — terminal user interfaces

`babet.curses` provides a small UTF-8 terminal UI API backed by statically linked
**ncursesw**. It is intended for interactive, full-screen terminal programs while
preserving Babet's one-file deployment model.

The first API deliberately stays small: one process-wide screen, no windows,
panels, menus, forms, or exposed ncurses pointers/constants.

## API overview

```lua
babet.curses.start()                 -- true
babet.curses.stop()                  -- true (also safe when inactive)
babet.curses.clear()                 -- true
babet.curses.refresh()               -- true
local rows, cols = babet.curses.size()
babet.curses.move(row, column)       -- true; coordinates are 1-based
babet.curses.write(text)             -- true; text must be valid UTF-8
local key, err = babet.curses.readKey([timeout_seconds])
```

All calls raise a Lua error for invalid arguments or terminal/curses failures.
`readKey(timeout)` is the exception for an ordinary timeout: it returns
`nil, "timeout"`. A blocking read interrupted without a delivered key may return
`nil, "interrupted"`.

## Starting and stopping

```lua
assert(babet.curses.start())
assert(babet.curses.clear())
assert(babet.curses.move(1, 1))
assert(babet.curses.write("Hello é Ω"))
assert(babet.curses.refresh())
local key = babet.curses.readKey()
assert(babet.curses.stop())
```

`start()` requires `stdin` and `stdout` to be the **same TTY**, a non-empty
`TERM`, and a usable UTF-8 `LC_CTYPE` locale. It must run on Babet's main thread.
Starting a second session raises an error.

A successful `start()` enables the shared signal/terminal Lua hook on demand
on the main Lua thread and the calling coroutine. New coroutines inherit their
creator's hook; other existing coroutines are not changed. Start curses before
creating coroutines that must service events during pure Lua loops. The hook
remains installed after `stop()`; see its [contract and cost](signal.md#signal-debug-hook).

`stop()` is idempotent. If an interactive child currently owns the terminal,
`stop()` ends the logical curses session **without taking the TTY back from the
child**. The normal process handoff code later restores the parent terminal when
that child exits or stops.

Normal completion, uncaught Lua errors, controlled C++ exceptions, and default
`SIGINT`/`SIGTERM`/`SIGHUP` termination restore terminal mode before Babet exits.
A fatal crash or `SIGKILL` cannot provide this guarantee; `reset` is the usual
manual recovery command for a damaged terminal.

In the CLI and generated executables, `os.exit(...)` also restores curses,
even without requesting Lua state closure. Exit status codes are preserved.
See the [exit contract](../runtime-exit.md) for finalizers, active workers and
native callbacks.

## Screen operations

`size()` returns `(rows, columns)` as positive integers.

`move(row, column)` uses **1-based** coordinates. Positions outside the current
screen raise an error.

`write(text)` writes valid UTF-8 at the current cursor position. Embedded NUL
bytes and invalid UTF-8 are rejected. Drawing is not automatically flushed;
call `refresh()` when the update should become visible.

`clear()` erases the standard screen and `refresh()` publishes pending changes.

## Keyboard input

```lua
local key, err = babet.curses.readKey(0.5)
if not key and err == "timeout" then
    -- no input during 500 ms
elseif key == "up" then
    -- arrow key
elseif key == "resize" then
    local rows, cols = babet.curses.size()
end
```

Ordinary characters are returned as UTF-8 Lua strings. Special keys are stable
symbolic names rather than ncurses numeric constants:

`up`, `down`, `left`, `right`, `home`, `end`, `page_up`, `page_down`,
`backspace`, `delete`, `insert`, `enter`, `resize`, and `f1` through `f63`.
An otherwise recognized ncurses special key is returned as `"special"`.

`SIGWINCH` is coalesced and handled on the main thread. After the terminal size
has been applied, `readKey()` reports the symbolic `"resize"` event.

If a signal callback calls `curses.stop()` during `readKey`, the read returns
`nil, "interrupted"`, including without a timeout. It no longer accesses the
released screen, even if a key was read immediately before the callback.

## Interactive child processes

Babet keeps **one interactive terminal owner at a time**. During a curses
session this works transparently on the main thread:

```lua
assert(babet.curses.start())

local p = assert(babet.spawn("sh", {}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
}))
local result = assert(p:wait())
p:close()

-- curses has been restored on the main thread here
assert(babet.curses.write("child exited"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
```

Before an interactive child receives the TTY, Babet saves curses program mode
and leaves curses. The existing process terminal manager gives the foreground
TTY to the child's process group. After the child exits or stops, the monitor
thread performs only the POSIX reclaim; curses restoration itself happens later
on the main thread.

A stopped interactive process can be resumed in the foreground with
`process:resume(true)` and uses the same suspend/reclaim path.

## Workers

Ncurses calls are main-thread-only. In a worker:

- every `babet.curses.*` operation is rejected;
- an interactive inherited-terminal `babet.spawn()` is rejected while the main
  curses session is active;
- non-interactive worker processes using pipes/files/null remain supported.

This avoids cross-thread ncurses access and ambiguous foreground ownership.

## Signals

Babet remains responsible for signal policy while curses is active:

- `SIGWINCH` becomes a deferred `"resize"` event;
- Ctrl-Z (`SIGTSTP`) restores normal terminal mode before suspension, then
  re-enters curses after `SIGCONT`;
- `babet.signal` handlers for `INT`, `TERM`, and `HUP` remain authoritative;
- when those signals keep their OS default, Babet restores curses on the main
  thread before re-raising the signal with its default disposition.

No ncurses function is called from a fatal signal handler.

## TERM and terminfo

Babet uses the system terminfo database first. Its statically linked ncursesw
also embeds fallbacks for:

```text
linux, vt100, xterm, xterm-256color,
screen, screen-256color, tmux, tmux-256color
```

This lets common terminals work even when a system terminfo tree is unavailable
and keeps generated applications self-contained. Babet never silently changes
an unknown `TERM` to another terminal type. Missing/unknown `TERM` or unusable
terminfo raises a normal Lua error rather than allowing ncurses to terminate the
process.

## Deployment

ncursesw is linked statically into the normal Babet runtime. `--create-exe`
therefore needs no compiler, linker, `libncursesw.so`, or external terminfo
folder at application-build time or runtime. A generated application gets the
same curses runtime as the original Babet binary.
