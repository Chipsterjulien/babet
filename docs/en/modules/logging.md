> **English** | [Français](../../fr/modules/logging.md)

# `logging` — leveled logger (Lua module)

A standard leveled logger : `debug`, `info`, `warn`, `error`,
`fatal`. Bundled as a pure-Lua module, loaded via
`require("logging")`. Not in the `babet` namespace — it's a
library module, like `inspect`.

## Why

Every non-trivial script ends up reinventing some flavour of
"levels + timestamps + optional file output". Standardising it
removes the bikeshed and makes log output consistent across
Babet scripts.

## API

```lua
local log = require("logging")
```

| Function                                                                               | Returns                                                                                                                |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `log.trace(...)`, `log.debug(...)`, `log.info(...)`, `log.warn(...)`, `log.error(...)` | nothing — each emits if its level is ≥ the current threshold. **Never raise** (even if the sink breaks)                |
| `log.set_level(lvl)`                                                                   | `lvl` = name (`"trace"`…`"error"`, case-insensitive) **or** constant (`log.INFO`). Unknown → raises                    |
| `log.set_output(out)`                                                                  | `out` = **any object answering `:write`** (`io.open` handle, custom table). Default : `io.stderr`. Wrong type → raises |
| `log.set_color(bool)`                                                                  | enables/disables ANSI colors (default : **off**). Strict non-boolean → raises                                          |
| `log.TRACE` … `log.ERROR`                                                              | numeric level constants (10, 20, 30, 40, 50)                                                                           |

> An earlier version of this page documented a `fatal` level that
> never existed (calling `log.fatal` crashes : nil call) and
> omitted `trace` and `set_color`. The five real levels :
> `trace=10`, `debug=20`, `info=30` (default threshold), `warn=40`,
> `error=50`.

Messages are prefixed `YYYY-MM-DD HH:MM:SS [LEVEL]` (level padded
to 5 characters : `[INFO ]`, `[ERROR]`). Multiple arguments are
joined with spaces, like `print`. Colors (opt-in via
`set_color(true)`) : trace grey, debug cyan, **info uncolored**
(the nominal case stays neutral), warn yellow, error red.

## Quick example

```lua
local log = require("logging")
log.set_level("info")   -- trace and debug become no-ops

log.info("starting, pid =", babet.pid())
log.warn("attempt", 3, "of", 5)
log.error("connection failed:", err)

-- Optional : route to a file (a :write-able object)
local f = io.open("/var/log/myapp.log", "a")
if not f then
    log.error("cannot open log file; staying on stderr")
else
    log.set_output(f)
end
```

Output :

```
2026-06-11 14:32:01 [INFO ] starting, pid = 12345
2026-06-11 14:32:05 [WARN ] attempt 3 of 5
2026-06-11 14:32:05 [ERROR] connection failed: timeout
```

## Error contract

- **`set_level` / `set_output` / `set_color`** : invalid argument
  (unknown level, object without `:write`, non-boolean) →
  **raises** via `error()` — that's a programmer bug, not a runtime
  condition.
- **The emit functions never raise** : the write is wrapped in a
  `pcall` — a sink that breaks midway (disk full, closed file)
  loses the message silently, never crashes the script.

## Design decisions

- **Pure-Lua module**. No C++ needed, and being in Lua means
  scripts can monkey-patch it (e.g. add JSON-format output) at
  the call site without rebuilding Babet.
- **Five levels, `trace` to `error` — no `fatal`**. `error` plus
  an explicit `os.exit(1)` beats a level that kills the process
  quietly ; and five levels are enough for almost everyone.
- **Colors are opt-in, `info` always neutral**. The nominal case
  shouldn't shout ; only deviations (warn, error) stand out.
- **Single global sink**. Multiple loggers / hierarchical loggers
  / per-module levels are a feature creep trap. If you need
  multiple destinations, write a wrapper.

## Not in v1

- JSON / structured logging output. Easy to bolt on at the
  script level if needed.
- Log rotation. Use `logrotate(8)` on the file output.
- Async / buffered output. Premature optimisation for typical use.
