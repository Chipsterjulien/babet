> **English** | [Français](../../fr/modules/toml.md)

# `babet.toml` - TOML decoding

The `babet.toml` module uses **toml++ 3.4.0** and decodes documents that
conform to **TOML 1.0.0**. Optional extensions outside the TOML 1.0 profile supported by this
toml++ version are disabled.

The v1 API only decodes a Lua string. It does not read a file for you and it
does not provide an encoder.

## Module contents

- [API](#toml-api)
- [Type mapping](#toml-types)
  - [Integers and floats](#toml-numbers)
- [Strings, UTF-8, and keys](#toml-strings)
- [Arrays and tables](#toml-containers)
  - [Empty-container ambiguity](#toml-empty-containers)
- [Dates and times](#toml-dates)
- [Ordering and discarded information](#toml-order)
- [Error contract](#toml-errors)
- [Limits](#toml-limits)
- [Not exposed in v1](#toml-not-exposed)

<a id="toml-api"></a>
## API

| Function | Contract |
| --- | --- |
| `babet.toml.decode(text)` | Returns `table, nil` or `nil, err` |

`decode` requires exactly **one argument**, and it must be an actual Lua
string. A number is not implicitly converted to text, and extra arguments
are rejected.

To read a file:

```lua
local file = assert(io.open("config.toml", "rb"))
local text = assert(file:read("*a"))
file:close()

local config, err = babet.toml.decode(text)
if not config then
    error(err)
end
```

A TOML document always has a table at its root. An empty string or a document
containing comments only therefore returns an empty Lua table.

<a id="toml-types"></a>
## Type mapping

| TOML | Lua |
| --- | --- |
| string | string |
| signed 64-bit integer | Lua integer |
| float | Lua number |
| boolean | boolean |
| array | `1..n` sequence table |
| table, inline table, or dotted table | table with string keys |
| array of tables | sequence table containing tables |
| local date/time and date-time | normalized string |

TOML has no value equivalent to Lua `nil` or JSON `null`.

<a id="toml-numbers"></a>
### Integers and floats

TOML integers cover the full signed 64-bit range, from `math.mininteger` to
`math.maxinteger`, and are preserved exactly. Decimal, hexadecimal, octal,
and binary notation all produce a Lua integer. A value outside that range is
a parse error.

Floats become Lua numbers. TOML also accepts these special values:

```lua
local values = assert(babet.toml.decode([[
positive = inf
negative = -inf
invalid  = nan
]]))

assert(values.positive == math.huge)
assert(values.negative == -math.huge)
assert(values.invalid ~= values.invalid) -- NaN property
```

As in Lua, `NaN` compares equal to no value, including itself.

<a id="toml-strings"></a>
## Strings, UTF-8, and keys

The TOML document must contain valid UTF-8. Basic, literal, and multiline
strings are decoded before they are returned to Lua: TOML escape sequences
become their corresponding characters.

Lua strings are binary-safe. A TOML sequence such as `\u0000` may therefore
produce a NUL byte in a value **or in a quoted key**, without truncation:

```lua
local value = assert(babet.toml.decode([[
"a\u0000b" = "x\u0000y"
]]))

assert(value["a\0b"] == "x\0y")
```

A raw NUL byte injected into the TOML text is not treated as the end of a C
string: the parser receives the whole buffer and rejects the document. The
same applies to invalid UTF-8.

Bare, quoted, and dotted keys follow TOML rules:

```lua
local value = assert(babet.toml.decode([[
"a.b" = 1
site."google.com" = true
physical.color = "orange"
]]))

assert(value["a.b"] == 1)              -- literal dot in a quoted key
assert(value.site["google.com"] == true)
assert(value.physical.color == "orange")
```

An empty quoted key (`""`) is valid TOML and becomes the Lua key `""`.

<a id="toml-containers"></a>
## Arrays and tables

TOML arrays become Lua sequences indexed from `1`. TOML 1.0 permits
heterogeneous arrays:

```lua
local value = assert(babet.toml.decode([[
items = [1, "two", true, { name = "three" }]
]]))

assert(value.items[1] == 1)
assert(value.items[2] == "two")
assert(value.items[3] == true)
assert(value.items[4].name == "three")
```

Sections, inline tables, and dotted keys all become ordinary Lua tables. The
original syntax is not retained.

<a id="toml-empty-containers"></a>
### Empty-container ambiguity

An empty array `[]` and an empty table `{}` both become an empty Lua table:

```lua
local value = assert(babet.toml.decode([[
a = []
b = {}
]]))

assert(type(value.a) == "table" and next(value.a) == nil)
assert(type(value.b) == "table" and next(value.b) == nil)
```

No metatable or sentinel remembers the original TOML type. This information
loss is usually harmless when reading configuration, but it prevents a
faithful round trip.

<a id="toml-dates"></a>
## Dates and times

TOML defines four temporal types. Since Lua has no native date type, Babet
converts them to strings:

| TOML type | Lua form |
| --- | --- |
| local date | `YYYY-MM-DD` |
| local time | `HH:MM:SS[.fraction]` |
| local date-time | `YYYY-MM-DDTHH:MM:SS[.fraction]` |
| offset date-time | `YYYY-MM-DDTHH:MM:SS[.fraction]Z` or `+/-HH:MM` |

```lua
local value = assert(babet.toml.decode([[
date = 1979-05-27
time = 07:32:00.1234
local_dt = 1979-05-27T07:32:00
utc_dt = 1979-05-27T07:32:00Z
]]))
```

The temporal value is retained, but its original **spelling** may be
normalized by toml++: canonical separator, fractional part, or UTC notation.
Comments and the exact source representation are not available. After
conversion, a TOML date is also indistinguishable from a TOML string
containing the same text.

<a id="toml-order"></a>
## Ordering and discarded information

A TOML table has no guaranteed semantic order, and Lua table iteration must
not be used as a proxy for source order. Decoding does not preserve:

- comments;
- lexical key order;
- whitespace and line breaks;
- the choice between sections, inline tables, and dotted keys;
- the original spelling of numbers and dates;
- the type of an empty container.

The module is intended to **read values**, not to edit and reproduce a TOML
document byte-for-byte.

<a id="toml-errors"></a>
## Error contract

A TOML syntax or value error returns:

```lua
local value, err = babet.toml.decode("answer = ")
assert(value == nil)
print(err) -- toml: ... (line ..., col ...)
```

The message is prefixed with `toml:` and includes the line and column reported
by toml++.

The following are returned as `(nil, err)`, among others:

- invalid syntax or a redefined key;
- integer outside the signed 64-bit range;
- invalid UTF-8 or a forbidden control character;
- an extension unavailable in the TOML 1.0 profile used by Babet.

API misuse raises a Lua error instead:

- missing argument;
- non-string argument;
- extra argument.

<a id="toml-limits"></a>
## Limits

The whole document is parsed and converted in memory. There is no streaming
API, `decode_file`, schema validation, or access to source positions for
individual values. Recursive conversion protects the Lua stack; a depth that
cannot be converted is returned as a `toml:` error.

<a id="toml-not-exposed"></a>
## Not exposed in v1

- `babet.toml.encode`;
- `babet.toml.decode_file`;
- parser options or extensions outside TOML 1.0;
- nodes retaining comments, order, and source positions;
- sentinels distinguishing empty arrays from empty tables;
- schema validation.
