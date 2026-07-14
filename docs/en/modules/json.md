> **English** | [Français](../../fr/modules/json.md)

# `babet.json` — JSON encoding and decoding

The `babet.json` module is backed by **nlohmann/json 3.11.3**. It
converts Lua values to JSON text and back, with two sentinels that
represent JSON `null` and the empty array `[]` without ambiguity.

## Module contents

- [API](#json-api)
- [Type mapping](#json-types)
  - [Lua to JSON](#json-lua-to-json)
  - [JSON to Lua](#json-json-to-lua)
- [`null`](#json-null)
- [Empty object, empty array, and `as_array`](#json-empty-containers)
- [`encode` options](#json-encode-options)
- [Strings, UTF-8, and NUL bytes](#json-strings)
- [Numbers](#json-numbers)
- [Object order and duplicate keys](#json-order)
- [Error contract](#json-errors)
- [Limits](#json-limits)

<a id="json-api"></a>
## API

| Element | Contract |
| --- | --- |
| `babet.json.encode(value [, opts])` | Returns `text, nil` or `nil, err` |
| `babet.json.decode(text)` | Returns `value, nil` or `nil, err` |
| `babet.json.null` | Sentinel representing JSON `null` |
| `babet.json.empty_array` | Constant sentinel that encodes as `[]` |
| `babet.json.as_array(t)` | Tags `t` as a JSON array and returns the same table |

`encode` accepts exactly one or two arguments. `decode` requires
exactly **one Lua string**: a number is not implicitly converted to
text. `as_array` requires exactly one table.

<a id="json-types"></a>
## Type mapping

<a id="json-lua-to-json"></a>
### Lua to JSON

| Lua | JSON |
| --- | --- |
| `nil` passed directly to `encode` | `null` |
| `babet.json.null` | `null` |
| `babet.json.empty_array` | `[]` |
| boolean | boolean |
| Lua integer | JSON integer number |
| finite Lua float | JSON floating-point number |
| valid UTF-8 string | JSON string |
| untagged empty table | empty object `{}` |
| integer keys exactly `1..n` | JSON array |
| string keys only | JSON object |

Inside a Lua table, assigning `nil` removes the key before encoding
ever starts. Use `babet.json.null` to retain a key whose JSON value must
explicitly be `null`.

A table mixing string and integer keys, a sparse array, or a table with
an unrepresentable key (`0`, a negative integer, a float, a boolean, a
table, and so on) cannot be converted: `encode` returns `nil, err`.

<a id="json-json-to-lua"></a>
### JSON to Lua

| JSON | Lua |
| --- | --- |
| `null` | `babet.json.null` |
| boolean | boolean |
| signed integer in the Lua range | Lua integer |
| unsigned integer above `math.maxinteger` | Lua float |
| JSON floating-point number | Lua float |
| string | Lua string |
| array | sequential table `1..n` |
| object | string-keyed table |

A JSON integer too large for `lua_Integer` is converted to a float
instead of silently wrapping to a negative value. As with any IEEE 754
conversion, precision may be lost.

<a id="json-null"></a>
## `null`

Lua cannot retain a `nil` value in a table. The shared
`babet.json.null` sentinel fills that gap:

```lua
local J = babet.json

local value = assert(J.decode([[{"answer":null}]]))
assert(value.answer == J.null)

local text = assert(J.encode({ answer = J.null }))
-- text represents {"answer":null}
```

Compare the sentinel by identity with `==`. It is implemented as a
special table, but must not be used as a data table.

<a id="json-empty-containers"></a>
## Empty object, empty array, and `as_array`

An empty Lua table is ambiguous. Babet chooses a JSON object by default:

```lua
local J = babet.json

assert(J.encode({}) == "{}")
assert(J.encode(J.empty_array) == "[]")
assert(J.encode(J.as_array({})) == "[]")
```

`empty_array` is a shared sentinel for values that are not meant to be
modified. `as_array(t)` is preferable for a dynamically built array: it
tags the table with an internal metatable, leaves it mutable, and returns
that exact same table.

```lua
local tags = {}
-- table.insert(tags, ...) may never be called

local text = assert(J.encode({ tags = J.as_array(tags) }))
-- {"tags":[]}
```

Important details:

- `as_array` is idempotent;
- the tag **replaces any existing metatable** on the table;
- the shape is validated only when `encode` runs: a tagged table with
  string keys or holes returns `nil, err`;
- `as_array(J.null)` and `as_array(J.empty_array)` raise a Lua error;
- only a decoded **empty** JSON array receives the tag automatically. A
  decoded non-empty array that is later emptied becomes an ordinary
  empty table and therefore re-encodes as `{}`; call `as_array(t)` to
  retain `[]` in that case;
- ordinary writes to the sentinels are rejected. As with every Lua
  table, `rawset` bypasses metamethods: do not mutate the sentinels.

<a id="json-encode-options"></a>
## `encode` options

The optional table has one interpreted option:

```lua
local compact = assert(babet.json.encode({ a = 1 }))
local pretty  = assert(babet.json.encode({ a = 1 }, { indent = 4 }))
```

- `indent = 0..256` enables formatted output with line breaks;
- `indent = 0` adds no indentation spaces but keeps formatted-output
  line breaks;
- omitted, `nil`, or a negative integer: compact output;
- a non-integer value or a value above `256` raises a Lua error;
- other option fields are ignored. In particular, the previously and
  incorrectly documented `pretty` option does not exist.

<a id="json-strings"></a>
## Strings, UTF-8, and NUL bytes

JSON strings must contain valid UTF-8. Unicode characters are preserved
in output; Babet does not force them into `\uXXXX` escapes.

Lua strings may contain NUL bytes. They remain binary-safe on the Lua
side and are escaped according to JSON rules during encoding. The same
applies to object keys:

```lua
local J = babet.json
local original = "a\0b"
local text = assert(J.encode({ [original] = original }))
local back = assert(J.decode(text))
assert(back[original] == original)
```

A string or key containing invalid UTF-8 makes `encode` return
`nil, err`. JSON text containing an invalid UTF-8 string is likewise
rejected by `decode`.

<a id="json-numbers"></a>
## Numbers

Babet preserves the Lua numeric subtype when JSON permits it: `42`
decodes as a Lua integer, whereas `42.0` and `1e3` decode as floats.
When encoding, a Lua float such as `3.0` remains a JSON floating-point
number.

`NaN`, `+Inf`, and `-Inf` are not part of the JSON standard and return
`nil, err`.

<a id="json-order"></a>
## Object order and duplicate keys

JSON object member order has no semantic meaning and must not be treated
as an API contract. The current backend generally emits members in
lexicographic key order, but callers should compare decoded data rather
than raw text whenever an external format does not prescribe ordering.

When decoding a JSON object that repeats the same key, the last value
replaces earlier ones.

<a id="json-errors"></a>
## Error contract

Conversion and parsing failures are returned and do not raise a Lua
exception:

```lua
local value, err = babet.json.decode("{ invalid")
if not value then
    print(err) -- prefixed with "json:"
end
```

This includes, among other cases:

- invalid JSON, trailing data after the document, or invalid UTF-8;
- mixed tables, sparse arrays, or unrepresentable keys;
- a function, userdata, or thread that cannot be encoded;
- `NaN` or infinity;
- a cycle or excessive nesting depth.

API misuse does raise a Lua error:

- wrong argument count;
- a non-string argument to `decode`;
- an `encode` second argument that is neither a table nor `nil`;
- a non-integer `opts.indent` or one above `256`;
- an invalid argument to `as_array`.

Parsing errors produced by nlohmann/json include the failure position,
usually as a line and column.

<a id="json-limits"></a>
## Limits

Conversion depth is capped at **1000 levels** in both directions. This
also acts as the guard against cyclic Lua tables. The module builds the
whole document in memory and does not provide a streaming API.
