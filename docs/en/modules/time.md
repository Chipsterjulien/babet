> **English** | [Français](../../fr/modules/time.md)

# `babet` time — monotonic and realtime clocks

Two clocks with sub-second precision and a sleep that honors
`s`/`ms`/`us` units and signals. Fills the gaps in `os.time` /
`os.clock`. The three historical functions live directly on
`babet`; the date and duration utilities live under the `babet.time`
sub-table (which also exposes the first three as aliases).

## Why

Lua's `os.time()` only gives seconds, and `os.clock()` measures
CPU time, not wall time. Neither is appropriate for measuring real
durations (request latency, retry backoff, timeouts). And `os` has
no portable sub-second sleep.

`babet.monotonic()` and `babet.now()` expose
`CLOCK_MONOTONIC` (durations) and `CLOCK_REALTIME` (timestamps),
with `babet.sleep()` honouring signal interruption.

## API

| Function | Returns |
| --- | --- |
| `babet.monotonic()` | `number` — seconds since arbitrary epoch (immune to clock changes) |
| `babet.now()` | `number` — POSIX time (seconds since 1970-01-01 UTC) |
| `babet.sleep(amount, unit?)` | `(true, nil)` \| `(nil, "interrupted")` |

`unit` for `sleep` is one of `"s"` (default), `"ms"`, `"us"`.
Floats are accepted. (No `"ns"`: nanosleep doesn't guarantee that
granularity anyway, and the code does not accept it.)

## API — date and duration utilities (v1.8.0+)

Added under the `babet.time` sub-table. The three flat
functions above are also aliased there (`babet.time.now`,
`babet.time.monotonic`, `babet.time.sleep`) for ergonomy.

| Function | Returns |
| --- | --- |
| `babet.time.iso(ts?)` | `string` — `"YYYY-MM-DDTHH:MM:SSZ"` (UTC). Without arg, formats the current time. |
| `babet.time.parse_iso(s)` | `(integer, nil)` \| `(nil, "parse_iso: ...")` — Unix timestamp in seconds. |
| `babet.time.parse_duration(s)` | `(integer, nil)` \| `(nil, "parse_duration: ...")` — number of seconds. |
| `babet.time.format_duration(n)` | `string` — `"1d2h3m4s"` style, compact, with zero components omitted. |

**ISO 8601 format accepted by `parse_iso`** — pragmatic, but with
one strict rule : **a timezone suffix is required**.

- Date and time separator : `T` or space.
- Timezone : `Z` (UTC), `+HH:MM`, or `-HH:MM`. **No** `+0200`,
  `+02`, or trailing absence — these are all rejected. Hours
  `00..23`, minutes `00..59`.
- Fractional seconds (`.123`) are accepted but ignored.
- A string without timezone is rejected explicitly rather than
  interpreted as UTC, because most real-world timestamps without
  a `Z` are local, not UTC, and silent misinterpretation is a
  common bug source.

**Duration format accepted by `parse_duration`** :

- Units : `s`, `m` (minute), `h`, `d`. No `w`, `mo`, `y`, `ms`,
  `us`, `ns` in v1.
- Compose unit chunks without whitespace : `"1h30m"`, `"2d12h"`,
  `"45m30s"`, `"1d1h1m1s"`.
- Units must appear in **strictly decreasing order** (`d > h > m
  > s`). `"30m1h"` is rejected.
- No duplicate unit : `"1h1h"` is rejected.
- No sign, no spaces. Empty string is rejected. A bare number
  without unit (`"5"`) is rejected.
- `"0s"` is the only canonical representation of zero (matches
  `format_duration(0)`).

**Round-trip invariant** : for every integer `n >= 0`,
`parse_duration(format_duration(n)) == n`. This is checked in
the test suite over a representative sample.

## Quick example

```lua
-- Measure a duration safely (immune to NTP / DST jumps)
local t0 = babet.monotonic()
do_something()
local elapsed = babet.monotonic() - t0
print(string.format("took %.3f s", elapsed))

-- Timestamp an event
local now = babet.now()
db:exec("INSERT INTO events (ts, kind) VALUES (?, ?)", { now, "ping" })

-- Sleep 100 ms, but wake up on a signal
local ok, err = babet.sleep(100, "ms")
if not ok and err == "interrupted" then
    print("woken by a signal")
end

-- ISO 8601 timestamp for logs (always UTC)
print("event at " .. babet.time.iso())          -- "2026-06-17T14:32:01Z"
print(babet.time.iso(0))                        -- "1970-01-01T00:00:00Z"

-- Parse a log line back to a Unix timestamp
local ts = assert(babet.time.parse_iso("2026-06-17T10:00:00+02:00"))
-- ts is 1781683200 (which is 2026-06-17T08:00:00Z)

-- Human-readable durations
local cache_ttl = babet.time.parse_duration("2h30m")  -- 9000
print("cache valid for " .. babet.time.format_duration(cache_ttl))
-- "cache valid for 2h30m"
```

## Error contract

- **`monotonic()` / `now()`** : never fail. Always return a number.
- **`sleep(amount, unit)`** :
  - `(true, nil)` if the sleep completed normally.
  - `(nil, "interrupted")` if a handled signal arrived during the
    sleep (see [`signal`](signal.md)).
- **NaN / Inf / negative amount** → raises via `luaL_error`.
- **Unknown unit string** → raises via `luaL_error`.

## Design decisions

- **Two clocks, two functions, no flag**. `monotonic()` for
  durations, `now()` for timestamps. Conflating them in one
  function with a parameter would invite the wrong choice.
- **`now()` for realtime**, not `realtime()` — shorter, and the
  natural English meaning matches what's expected (current time).
- **Signal-aware `sleep`**. A 60-second sleep that ignores
  `SIGTERM` is the classic graceful-shutdown bug. `sleep()`
  returns `(nil, "interrupted")` so the caller can exit cleanly.
- **No "format date" helper**. `os.date(format, babet.now())`
  works fine, and a duplicate function would just be a wrapper.

## Not in v1

- `babet.boottime()` (`CLOCK_BOOTTIME` — includes suspend).
  Rarely needed, easy to add later.
- `babet.utcnow()` / `localnow()` helpers that return
  pre-formatted strings. Trivial in Lua, no value-add.
