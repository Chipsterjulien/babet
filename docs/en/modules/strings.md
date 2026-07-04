> **English** | [Français](../../fr/modules/strings.md)

# `babet` strings — string manipulation

A single function : split a string by a separator into a table.
Predates the sub-namespace convention, lives directly on
`babet`.

## Why

Splitting a string by a delimiter is one of the most common
string operations, and Lua's standard library doesn't have one
out of the box (`string.gmatch` works but requires pattern
escaping). A dedicated function is more discoverable and avoids
the pattern-escaping trap.

## API

| Function | Returns |
| --- | --- |
| `babet.split(s [, sep [, max_splits]])` | `table` (array) of substrings |

- `s` : the string to split. Binary-safe: NUL bytes are preserved.
- `sep` : optional separator — a **single character**, literal (no
  patterns). An empty string, or omitting the argument, switches to
  **character mode**: `s` is split into individual characters. More
  than one character → raises.
- `max_splits` : maximum number of cuts, optional (default `-1` =
  unlimited). The uncut remainder lands in the last element, so `0`
  returns `{ s }`. Ignored in character mode.

If `sep` doesn't appear in `s`, the result is a one-element table
containing the whole `s`.

Empty-string edge cases (historical behavior, frozen and tested):

- `babet.split("", sep)` returns `{ "" }` — one empty entry, not an
  empty table.
- `babet.split("")` (character mode) returns `{}` — an empty table.

## Quick example

```lua
local parts = babet.split("a,b,c,d", ",")
-- parts == { "a", "b", "c", "d" }

local one = babet.split("hello", ",")
-- one == { "hello" }

-- Character mode (sep omitted or empty)
local chars = babet.split("abc")
-- chars == { "a", "b", "c" }

-- Bounded number of cuts: remainder in the last element
local kv = babet.split("key,val,ue", ",", 1)
-- kv == { "key", "val,ue" }
```

## Error contract

- **Wrong argument types** → raises via `luaL_error`.
- **`sep` longer than one character** → raises.
- **`max_splits` not an integer or < -1** → raises.
- Otherwise always succeeds.

## Design decisions

- **Literal separator, not Lua pattern**. The common case is
  splitting CSV-like data, where you want `.` to mean a literal
  dot, not "any character". If you need pattern matching, fall
  back to `string.gmatch`.
- **Empty entries are preserved**. `"a,,b"` splits into
  `{"a", "", "b"}`. Consumers who want to filter empty strings
  do it in one line of Lua.
- **`split("", sep)` returns `{ "" }`**. This is the natural
  consequence of the "empty entries are preserved" rule (zero
  separators found → one element, the whole string — which happens
  to be empty). Observable since v1, so frozen rather than changed.
- **Character mode when `sep` is omitted or empty**. There is no
  default separator: without one, the only coherent reading of a
  split is character by character. Note: the split is per **byte**,
  not per Unicode code point — a multi-byte UTF-8 character will be
  torn apart.

## Not in v1

- Pattern-based splitting (with escape rules). Use `string.gmatch`
  if needed.
- Multi-character separators.
- `joinTable(t, sep)` mirror — `table.concat` already exists in the
  stdlib.
