> **English** | [Français](../../fr/modules/signal.md)

# `babet.signal` — POSIX signals

Register Lua callbacks for POSIX signals (`SIGTERM`, `SIGINT`,
`SIGHUP`, …) so long-running scripts can shut down gracefully or
reload configuration on demand.

## Why

Long-running Babet scripts (bots, daemons, watchers) need to
handle signals properly :

- `SIGTERM` from `systemctl stop` should trigger a clean shutdown.
- `SIGINT` from Ctrl-C should do the same.
- `SIGHUP` is the conventional "reload config" signal.

Without explicit handlers, these signals just kill the process,
leaving open files, half-written databases, and orphaned children.

## API

| Function | Returns |
| --- | --- |
| `babet.signal.handle(name, fn)` | `(true, nil)` \| `(nil, err)` — install Lua callback |
| `babet.signal.ignore(name)` | `(true, nil)` \| `(nil, err)` — set to `SIG_IGN` |
| `babet.signal.default(name)` | `(true, nil)` \| `(nil, err)` — back to OS default |
| `babet.signal.kill(pid, name)` | `(true, nil)` \| `(nil, err)` — send signal to PID |
| `babet.signal.list()` | `table` of all supported signal names |
| `babet.signal.is_pending()` | `boolean` — any handled signal queued ? |

Signal names accepted (string, case-sensitive) :

`"HUP"`, `"INT"`, `"QUIT"`, `"USR1"`, `"USR2"`, `"PIPE"`,
`"ALRM"`, `"TERM"`, `"CHLD"`, `"CONT"`, `"TSTP"`, `"TTIN"`,
`"TTOU"`, `"WINCH"`. Other signals (`KILL`, `STOP`) cannot be
caught — POSIX forbids it.

## Quick example

```lua
local sig = babet.signal
local running = true

sig.handle("TERM", function()
    print("got SIGTERM, shutting down")
    running = false
end)
sig.handle("INT", function()
    print("got SIGINT, shutting down")
    running = false
end)
sig.handle("HUP", function()
    print("got SIGHUP, reloading config")
    cfg = load_config()
end)

while running do
    local line, err = sock:recv_line(1.0)
    if not line then
        if err == "interrupted" then
            -- A handled signal arrived during recv ; the callback
            -- already fired. Re-check the loop condition.
        else
            break
        end
    else
        process(line)
    end
end

print("clean exit")
```

## How callbacks run

When a signal arrives :

1. The kernel sets a pending flag (no Lua code runs from the
   signal handler itself — async-signal-safe restrictions).
2. If the script is in a blocking call (`recv`, `sleep`,
   `inotify.read`, `accept`, …), the call returns
   `(nil, "interrupted")`.
3. Before returning, Babet dispatches all pending callbacks
   in registration order, in the main Lua thread.
4. The script continues normally — the callback can have
   modified globals (`running = false` is the typical pattern).

This means callbacks always run in Lua context, never from inside
a signal handler. They can use any Lua features (no async-signal-
safety restrictions).

**Interaction with `debug.sethook`** (v21 audit) : outside blocking
calls, dispatch relies on a Lua debug hook (`lua_sethook`, fired
periodically by instruction count). Consequences : a
`debug.sethook(...)` installed by the script **overwrites** this
mechanism — callbacks will then only be dispatched when the script
enters a babet blocking call — and conversely, the first
`signal.handle(...)` replaces any user hook already installed.
Avoid mixing `babet.signal` and `debug.sethook` in the same
script.

## Error contract

- **Unknown signal name** → `(nil, "signal: unknown name 'XYZ'")`.
- **Calls forbidden inside a worker thread** → `(nil, "signal: not
  available in worker threads")`. Signals are process-global ;
  only the main thread manages them.
- **Wrong argument types** → raises via `luaL_error`.
- **`kill(pid, name)`** for a PID that doesn't exist or isn't
  yours → `(nil, "kill: …")`.

## Design decisions

- **Callbacks run in the Lua main thread, not from the signal
  handler**. POSIX async-signal-safety rules forbid most useful
  operations from inside a real handler. By marking the signal as
  pending and dispatching from the next safe point, callbacks can
  do anything Lua can do.
- **Blocking calls return `"interrupted"` on a handled signal**.
  Without this, a `recv_line` waiting on the network would block
  until timeout regardless of `SIGTERM` arriving. With it, the
  shutdown can complete in milliseconds.
- **No re-entrance**. While a callback is running, additional
  signals are queued and dispatched after.
- **Forbidden in worker threads**. Signals are process-wide ; only
  one thread can sensibly own them. Workers must use channels for
  inter-thread communication.

## Not in v1

- `sigprocmask` / fine-grained signal masking. Not commonly
  needed at script level.
- `signalfd`-based polling integration. The current dispatch model
  is simpler and covers the typical cases.
