> **English** | [Français](../../fr/modules/logging.md)

# `logging` — leveled logging

`logging` is a pure-Lua module bundled with Babet. Load it with
`require("logging")`; it is not a member of the `babet` table.

```lua
local log = require("logging")
```

It exposes five levels:

| Level | Value |
| --- | ---: |
| `log.TRACE` | `10` |
| `log.DEBUG` | `20` |
| `log.INFO` | `30` |
| `log.WARN` | `40` |
| `log.ERROR` | `50` |

There is no `fatal` level.

## Module contents

- [Emitting a message](#logging-emit)
  - [No-propagation guarantee](#logging-no-propagation)
- [Output format](#logging-format)
- [Threshold](#logging-threshold)
- [Destination](#logging-output)
- [ANSI colors](#logging-colors)
- [Module state](#logging-state)
- [Error contract](#logging-errors)
- [Limitations](#logging-limits)

<a id="logging-emit"></a>
## Emitting a message

```lua
log.trace(...)
log.debug(...)
log.info(...)
log.warn(...)
log.error(...)
```

Each function accepts zero or more values and returns no values. A message is
emitted when the function's level is greater than or equal to the current
threshold.

The initial threshold is `log.INFO`, so `trace` and `debug` are filtered by
default.

Arguments are converted with `tostring` and joined with one space:

```lua
log.info("user=", 42, "active=", true)
-- ... [INFO ] user= 42 active= true
```

Calling a log function with no arguments emits a line with an empty message.
Embedded NUL bytes and newlines are neither removed nor escaped. A multiline
message therefore produces several physical lines, but only the start of the
call has the logger prefix.

<a id="logging-no-propagation"></a>
### No-propagation guarantee

The five emission functions never raise. The whole pipeline is protected:

- argument conversion through `tostring`;
- timestamp creation through `os.date`;
- the sink's `write` call.

If any of these operations fails, the message is silently lost and the script
continues. Arguments of a filtered message are not passed to `tostring`.

<a id="logging-format"></a>
## Output format

Without colors, each line uses this format:

```text
YYYY-MM-DD HH:MM:SS [LEVEL] message\n
```

Example:

```text
2026-07-13 21:45:02 [WARN ] attempt 3 of 5
```

The timestamp uses the machine's **local time**. It includes neither a time
zone nor milliseconds. Labels occupy five characters: `[TRACE]`, `[DEBUG]`,
`[INFO ]`, `[WARN ]`, `[ERROR]`.

<a id="logging-threshold"></a>
## Threshold

```lua
log.set_level(level)
local level = log.get_level()
```

`set_level` requires exactly one argument and returns no values. `get_level`
accepts no arguments and returns the current threshold.

The level may be:

- one of `"trace"`, `"debug"`, `"info"`, `"warn"`, `"error"`,
  case-insensitively;
- any finite number, allowing an intermediate threshold such as `25.5`.

```lua
log.set_level("DEBUG")
log.set_level(log.WARN)
log.set_level(25.5)
```

Numeric strings are not coerced and whitespace is not trimmed: `"30"` and
`" info "` are rejected. `NaN`, `+inf`, and `-inf` are rejected as well.

<a id="logging-output"></a>
## Destination

```lua
log.set_output(out)
local out = log.get_output()
```

The initial destination is `io.stderr`.

`set_output` requires exactly one table or userdata exposing a callable
`write` method. A method supplied through `__index` is accepted. The method is
then called as `out:write(line)`.

```lua
local file, err = io.open("app.log", "a")
if not file then
    log.error("cannot open log file:", err)
else
    log.set_output(file)
end
```

The module:

- performs no write during `set_output`;
- never closes the destination;
- never calls `flush`;
- ignores the value returned by `write`;
- swallows write errors during emission.

A closed file still exposes a `write` method and can therefore be installed;
subsequent writes will fail silently. Sink lifetime management belongs to the
script.

`get_output` accepts no arguments and returns the exact installed object.

<a id="logging-colors"></a>
## ANSI colors

```lua
log.set_color(true)
local enabled = log.get_color()
```

Colors are disabled by default. `set_color` requires exactly one boolean and
returns no values. `get_color` accepts no arguments and returns a boolean.

When colors are enabled:

- `trace`: ANSI dim;
- `debug`: cyan;
- `info`: no color;
- `warn`: yellow;
- `error`: red.

The ANSI reset is written before the `\n`. The module does not detect whether
the sink is a terminal; enabling colors is always explicit.

<a id="logging-state"></a>
## Module state

`require("logging")` returns the same table until `package.loaded.logging` is
removed. The threshold, sink, and color setting are therefore shared by every
user of the module within **one Lua state**.

Each Babet worker owns a separate Lua state, so its logging settings are
independent from the main thread and from other workers.

The initial values are:

```lua
log.set_level(log.INFO)
log.set_output(io.stderr)
log.set_color(false)
```

The module also exposes:

```lua
log._VERSION      -- "babet logging 1.1.0"
log._DESCRIPTION  -- textual description
```

<a id="logging-errors"></a>
## Error contract

Setters and getters raise a Lua error on wrong arity or an invalid value. They
do not return `(nil, err)`.

`trace`, `debug`, `info`, `warn`, and `error` never raise and return no values.

<a id="logging-limits"></a>
## Limitations

The module does not provide:

- named or hierarchical loggers;
- per-module thresholds;
- multiple destinations;
- custom or JSON formatting;
- UTC timestamps or sub-second precision;
- file rotation;
- buffered or asynchronous writes;
- protection against a recursive sink that calls the logger again;
- automatic terminal detection.

Use an external tool such as `logrotate` for rotation. For more advanced
needs, wrap the module or replace its functions in the script.
