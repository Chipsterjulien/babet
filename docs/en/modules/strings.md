> **English** | [Français](../../fr/modules/strings.md)

# `babet` strings — splitting strings

Babet exposes one string-manipulation function: `babet.split`. It is
registered directly on the `babet` table, without a sub-namespace, to preserve
the historical API.

## Module contents

- [API](#strings-api)
- [Separator mode](#strings-separator)
  - [Limiting the number of cuts](#strings-max-splits)
- [Byte mode](#strings-bytes)
- [Binary strings and NUL bytes](#strings-binary)
- [Empty subject](#strings-empty)
- [Error contract](#strings-errors)
- [Limits and design choices](#strings-limits)

<a id="strings-api"></a>
## API

```lua
local parts = babet.split(s [, sep [, max_splits]])
```

The function requires **one to three arguments** and returns exactly one value:
a dense table indexed from `1` to `n`.

| Argument | Type and behavior |
| --- | --- |
| `s` | Required Lua string. Numbers are not converted implicitly. Embedded NUL bytes are preserved. |
| `sep` | Optional Lua string. Omitted or empty: byte mode. Otherwise it must contain exactly **one byte**, used literally. |
| `max_splits` | Optional Lua integer greater than or equal to `-1`. `-1` means unlimited and `0` prevents every cut. Used only when `sep` contains one byte. |

`nil` is not a placeholder for an optional argument:
`babet.split("abc", nil)` raises an error. To supply `max_splits` in byte mode,
pass `""` explicitly as the second argument.

<a id="strings-separator"></a>
## Separator mode

When `sep` contains exactly one byte, every occurrence of that byte produces a
cut. The separator is **literal**: it is neither a Lua pattern nor a regular
expression.

```lua
babet.split("a,b,c", ",")
-- { "a", "b", "c" }

babet.split("a.b.c", ".")
-- { "a", "b", "c" }  -- the dot is not a wildcard
```

Empty fields are preserved at the beginning, between adjacent separators, and
at the end:

```lua
babet.split(",a", ",")
-- { "", "a" }

babet.split("a,,b", ",")
-- { "a", "", "b" }

babet.split("a,", ",")
-- { "a", "" }
```

If the separator does not occur, the result contains the whole subject:

```lua
babet.split("hello", ",")
-- { "hello" }
```

<a id="strings-max-splits"></a>
### Limiting the number of cuts

`max_splits` counts **cuts**, not produced elements. The uncut remainder is
stored verbatim in the last element.

```lua
babet.split("a,b,c,d", ",", 2)
-- { "a", "b", "c,d" }

babet.split("a,b,c", ",", 0)
-- { "a,b,c" }

babet.split("a,b,c", ",", -1)
-- { "a", "b", "c" }
```

Any value greater than the number of available separators has the same effect
as `-1`.

<a id="strings-bytes"></a>
## Byte mode

If `sep` is omitted or is `""`, the subject is split byte by byte. There is
therefore **no default space separator**.

```lua
babet.split("ab c")
-- { "a", "b", " ", "c" }

babet.split("abc", "")
-- { "a", "b", "c" }
```

When supplied in this mode, `max_splits` is still validated but is not used:

```lua
babet.split("abc", "", 0)
-- { "a", "b", "c" }
```

This mode works on **bytes**, not Unicode code points. A multi-byte UTF-8
character is therefore returned as several one-byte strings:

```lua
local bytes = babet.split("é")
-- #bytes == 2 in UTF-8
-- table.concat(bytes) == "é"
```

Likewise, a multi-byte UTF-8 separator such as `"é"` is rejected because
`sep` must contain zero or one byte. Use Lua code (`string.find`,
`string.gmatch`, and so on) or a dedicated function to split on a multi-byte
string.

<a id="strings-binary"></a>
## Binary strings and NUL bytes

The subject, separator, and output elements are handled with their exact Lua
length. A NUL byte never truncates the data:

```lua
local parts = babet.split("a\0b,c", ",")
-- { "a\0b", "c" }

local parts2 = babet.split("a\0b", "\0")
-- { "a", "b" }
```

UTF-8 content also stays intact when split with an ASCII byte:

```lua
babet.split("été:ok", ":")
-- { "été", "ok" }
```

<a id="strings-empty"></a>
## Empty subject

Two different historical behaviors are preserved:

```lua
babet.split("", ",")
-- { "" }

babet.split("")
-- {}

babet.split("", "")
-- {}
```

In separator mode, finding zero separators means returning one element with the
whole subject, even when it is empty. In byte mode, a zero-byte subject
produces no elements.

<a id="strings-errors"></a>
## Error contract

Every failure is a raised Lua error; `split` has no `(nil, err)` return path.

The function raises in particular when:

- fewer than one or more than three arguments are supplied;
- `s` is not an actual Lua string;
- `sep` is present but is not an actual Lua string;
- `sep` contains more than one byte;
- `max_splits` is not a Lua integer;
- `max_splits` is less than `-1`.

Implicit number-to-string conversions are not accepted:

```lua
babet.split(123, ",")          -- error
babet.split("123", 2)          -- error
babet.split("a,b", ",", "1") -- error
```

<a id="strings-limits"></a>
## Limits and design choices

- This is not a CSV parser: quoting, escaping, and records are not handled.
- Multi-byte separators and Lua patterns are not supported.
- Empty fields are intentionally preserved.
- No `join` counterpart is exposed because Lua's standard `table.concat`
  already provides it.
