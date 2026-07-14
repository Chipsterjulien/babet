> **English** | [Français](../../fr/modules/time.md)

# `babet` time - clocks, sleep, dates and durations

Babet exposes two sub-second clocks, interruptible sleep, and small utilities
for ISO 8601 timestamps and compact durations.

The historical functions remain available at the root:

- `babet.monotonic()`;
- `babet.now()`;
- `babet.sleep(amount [, unit])`.

The same functions are available under `babet.time`, together with four
additional utilities: `iso`, `parse_iso`, `parse_duration`, and
`format_duration`.

## Module contents

- [API](#time-api)
- [`monotonic()` and `now()`](#time-clocks)
- [`sleep(amount [, unit])`](#time-sleep)
- [`babet.time.iso([ts])`](#time-iso)
- [`babet.time.parse_iso(text)`](#time-parse-iso)
- [`babet.time.parse_duration(text)`](#time-parse-duration)
- [`babet.time.format_duration(seconds)`](#time-format-duration)
- [Error contract summary](#time-errors)
- [Limits and design choices](#time-limits)

<a id="time-api"></a>
## API

| Function | Result |
| --- | --- |
| `babet.monotonic()` | `number`, or exceptionally `(nil, err)` if `clock_gettime` fails |
| `babet.now()` | `number`, or exceptionally `(nil, err)` if `clock_gettime` fails |
| `babet.sleep(amount [, unit])` | `(true, nil)` or `(nil, err)` |
| `babet.time.iso([ts])` | UTC `string` |
| `babet.time.parse_iso(text)` | `(integer, nil)` or `(nil, "parse_iso: ...")` |
| `babet.time.parse_duration(text)` | `(integer, nil)` or `(nil, "parse_duration: ...")` |
| `babet.time.format_duration(seconds)` | compact `string`, for example `"1d2h3m4s"` |

The `babet.time.now`, `babet.time.monotonic`, and `babet.time.sleep` aliases
use exactly the same bindings and contract as their root names.

<a id="time-clocks"></a>
## `monotonic()` and `now()`

```lua
local started = babet.monotonic()
do_something()
local elapsed = babet.monotonic() - started
print(string.format("elapsed: %.3f s", elapsed))

local timestamp = babet.now()
print(timestamp)
```

`monotonic()` uses `CLOCK_MONOTONIC`. Its value starts at an arbitrary origin,
usually related to system boot. It is intended for measuring durations because
it does not suffer wall-clock jumps.

`now()` uses `CLOCK_REALTIME`. It returns POSIX time in seconds since
1970-01-01 UTC, including a fractional part. It is appropriate for timestamps,
but not for measuring durations because the wall clock may be adjusted.

Both functions:

- accept no arguments;
- return one `number` in normal operation;
- may theoretically return `(nil, err)` if the `clock_gettime` system call
  fails.

<a id="time-sleep"></a>
## `sleep(amount [, unit])`

```lua
assert(babet.sleep(250, "ms"))
assert(babet.time.sleep(0.5))       -- 0.5 second
assert(babet.sleep(1000, "us"))
```

`amount` must be an actual Lua `number`, finite and non-negative. Floating-point
values are accepted. A numeric string such as `"100"` is rejected.

`unit` must be an actual Lua `string`:

| Unit | Meaning |
| --- | --- |
| `"s"` | seconds, the default |
| `"ms"` | milliseconds |
| `"us"` | microseconds |

A zero duration succeeds immediately. An unknown textual unit keeps the
historical behavior:

```lua
local ok, err = babet.sleep(1, "minutes")
-- ok == nil
-- err == "Invalid time unit"
```

If a signal managed by [`babet.signal`](signal.md) arrives during the wait,
its Lua callback is dispatched and `sleep` then returns
`(nil, "interrupted")`. An unmanaged signal that causes `EINTR` does not
shorten the wait: Babet resumes with the remaining time.

Any other `nanosleep` failure returns `(nil, "sleep: <description>")`.

<a id="time-iso"></a>
## `babet.time.iso([ts])`

`iso` formats a Unix second in UTC:

```lua
print(babet.time.iso(0))
-- 1970-01-01T00:00:00Z

print(babet.time.iso())
-- current time, at whole-second precision
```

Without an argument, `iso()` uses the current time. With an argument:

- `ts` must be an actual Lua `number`;
- an integer or finite float is accepted;
- a fractional value is rounded toward negative infinity;
- the value must fit in a signed 64-bit integer.

The rounding matters before the Unix epoch:

```lua
babet.time.iso(0.9)   -- 1970-01-01T00:00:00Z
babet.time.iso(-0.5)  -- 1969-12-31T23:59:59Z
```

For ordinary years, the result has the form `YYYY-MM-DDTHH:MM:SSZ`. Extreme
valid `int64` timestamps may produce a signed year wider than four digits.
That extended result is not necessarily accepted by `parse_iso`, whose grammar
requires an exactly four-digit year.

`iso` applies neither locale nor local timezone and does not retain fractional
seconds.

<a id="time-parse-iso"></a>
## `babet.time.parse_iso(text)`

The parser intentionally accepts a small, deterministic subset:

```text
YYYY-MM-DDTHH:MM:SSZ
YYYY-MM-DD HH:MM:SSZ
YYYY-MM-DDTHH:MM:SS.fraction+HH:MM
YYYY-MM-DDTHH:MM:SS.fraction-HH:MM
```

Exact rules:

- `text` must be an actual Lua `string`;
- the year contains exactly four digits and ranges from `0001` to `9999`;
- the Gregorian calendar is validated, including leap years;
- the separator is uppercase `T` or one space;
- hours `00..23`, minutes `00..59`, seconds `00..59`;
- leap seconds written as `:60` are rejected;
- a fraction is optional, but the dot must be followed by at least one digit;
  all fraction digits are ignored, without rounding;
- a timezone is required: uppercase `Z`, `+HH:MM`, or `-HH:MM`;
- accepted offsets range from `00:00` through `23:59`;
- `+0200`, `+02`, lowercase `z`, leading or trailing whitespace, and trailing
  data are rejected;
- an embedded NUL byte is never truncated: it makes the string invalid.

Example:

```lua
local ts = assert(babet.time.parse_iso(
    "2026-06-17T10:00:00+02:00"))

assert(ts == babet.time.parse_iso("2026-06-17T08:00:00Z"))
```

A syntactically or calendrically invalid string returns
`(nil, "parse_iso: ...")`. A wrong type or argument count raises a Lua error.

<a id="time-parse-duration"></a>
## `babet.time.parse_duration(text)`

The format is a whitespace-free sequence of `number + unit` chunks:

```lua
assert(babet.time.parse_duration("45s") == 45)
assert(babet.time.parse_duration("1h30m") == 5400)
assert(babet.time.parse_duration("2d12h") == 216000)
```

Available units:

| Unit | Seconds |
| --- | ---: |
| `d` | 86400 |
| `h` | 3600 |
| `m` | 60 |
| `s` | 1 |

Each unit may occur at most once and units must be in strict order
`d > h > m > s`. Signs, decimal values, whitespace, and the units `w`, `ms`,
`us`, or `ns` are rejected. An embedded NUL byte is not truncated and also
produces a parse error.

Components are not normalized: `"1h90m"` is valid and equals 9000 seconds.
Leading zeroes and ordered zero-valued chunks are also accepted, for example
`"0001s"` and `"0d0h0m0s"`.

The total must remain between `0` and `math.maxinteger` on Babet's 64-bit
configuration. Overflow returns a parse error.

An invalid string returns `(nil, "parse_duration: ...")`. A wrong type or
argument count raises a Lua error.

<a id="time-format-duration"></a>
## `babet.time.format_duration(seconds)`

```lua
babet.time.format_duration(0)      -- "0s"
babet.time.format_duration(90)     -- "1m30s"
babet.time.format_duration(90061)  -- "1d1h1m1s"
```

`seconds` must be an actual Lua `number` with a non-negative integer value. A
floating-point value such as `3.0` is accepted; `3.7`, `"3"`, NaN, infinity,
and negative values raise a Lua error.

The output is Babet's canonical representation:

- units in `d`, `h`, `m`, `s` order;
- zero components omitted;
- zero represented as `"0s"`.

For every valid integer `n >= 0`:

```lua
assert(babet.time.parse_duration(
    babet.time.format_duration(n)) == n)
```

The textual reverse is not guaranteed because the parser also accepts
non-normalized forms such as `"90m"` or `"0h"`.

<a id="time-errors"></a>
## Error contract summary

| Situation | Behavior |
| --- | --- |
| Wrong type or wrong argument count | Lua error |
| NaN, infinity, negative duration, or out-of-range numeric value | Lua error |
| Unknown textual unit in `sleep` | `(nil, "Invalid time unit")` |
| Managed signal during `sleep` | `(nil, "interrupted")` after callback dispatch |
| Invalid ISO or duration text | `(nil, "parse_iso: ...")` or `(nil, "parse_duration: ...")` |
| Clock or sleep system failure | `(nil, err)` |

<a id="time-limits"></a>
## Limits and design choices

- Use `monotonic()` for durations and `now()` for timestamps.
- `iso` is a fixed UTC formatter, not a general replacement for `os.date`.
- No named timezone, daylight-saving rule, locale, or calendar arithmetic is
  provided.
- ISO fractions are discarded and are not emitted by `iso`.
- `parse_duration` works with whole seconds only.
- `CLOCK_BOOTTIME`, negative durations, and week/month/year units are not
  exposed.
