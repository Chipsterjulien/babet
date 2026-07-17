> **English** | [Français](../../fr/modules/base64.md)

# `babet.base64` — binary Base64 encoding and decoding

The `babet.base64` module implements the RFC 4648 Base64 alphabets without
starting an external program. Inputs and outputs are **binary** Lua strings:
NUL bytes, non-UTF-8 data, and every value from `0` through `255` are preserved
exactly.

The decoder is deliberately strict. It validates the selected alphabet,
padding placement, final-quantum length, and unused bits in the last symbol. A
non-canonical representation is therefore not silently accepted.

## Module contents

- [API](#base64-api)
- [Standard encoding](#base64-encode-standard)
- [URL-safe alphabet](#base64-url-safe)
- [Padding](#base64-padding)
- [Strict decoding](#base64-strict-decode)
- [ASCII whitespace](#base64-whitespace)
- [Output limit](#base64-max-output)
- [Binary data and files](#base64-binary)
- [Using the module in a worker](#base64-worker)
- [Error contract](#base64-errors)
- [Limits and design choices](#base64-limits)

<a id="base64-api"></a>
## API

| Function | Contract |
| --- | --- |
| `babet.base64.encode(data [, opts])` | Returns `text, nil` or `nil, err` |
| `babet.base64.decode(text [, opts])` | Returns `data, nil` or `nil, err` |

`data` and `text` must be actual Lua strings. Numbers are never implicitly
converted to text.

Encoding options:

```lua
{
    url_safe = false,
    padding = true,
}
```

Decoding options:

```lua
{
    url_safe = false,
    allow_unpadded = false,
    ignore_whitespace = false,
    max_output = nil,
}
```

Unknown options are rejected. Boolean options require actual Lua booleans;
`max_output` must be a non-negative integer.

<a id="base64-encode-standard"></a>
## Standard encoding

Without options, `encode()` uses the standard Base64 alphabet: letters, digits,
`+`, and `/`, with canonical `=` padding when the final group contains fewer
than three bytes.

```lua
local encoded, err = babet.base64.encode("hello")
assert(encoded, err)
assert(encoded == "aGVsbG8=")
```

The classic RFC 4648 vectors are preserved:

```lua
assert(babet.base64.encode("")       == "")
assert(babet.base64.encode("f")      == "Zg==")
assert(babet.base64.encode("fo")     == "Zm8=")
assert(babet.base64.encode("foo")    == "Zm9v")
assert(babet.base64.encode("foob")   == "Zm9vYg==")
assert(babet.base64.encode("fooba")  == "Zm9vYmE=")
assert(babet.base64.encode("foobar") == "Zm9vYmFy")
```

`encode()` adds no line breaks and does not produce 76-column MIME Base64.

<a id="base64-url-safe"></a>
## URL-safe alphabet

`url_safe = true` selects the RFC 4648 URL/file-name-safe alphabet: `-`
replaces `+`, and `_` replaces `/`.

```lua
local binary = string.char(251, 255)
local encoded, err = babet.base64.encode(binary, {
    url_safe = true,
})
assert(encoded, err)
assert(encoded == "-_8=")
```

Decoding must select the same alphabet:

```lua
local decoded, err = babet.base64.decode("-_8=", {
    url_safe = true,
})
assert(decoded, err)
assert(decoded == string.char(251, 255))
```

The alphabets are not mixed automatically:

```lua
assert(babet.base64.decode("-_8=") == nil)
assert(babet.base64.decode("+/8=", { url_safe = true }) == nil)
```

This strict choice prevents the same input from being accepted in multiple
forms when a protocol requires one precise alphabet.

<a id="base64-padding"></a>
## Padding

### Producing output without `=`

`padding = false` removes only trailing `=` characters. The useful content is
unchanged.

```lua
local encoded, err = babet.base64.encode("hello", {
    padding = false,
})
assert(encoded, err)
assert(encoded == "aGVsbG8")
```

When the source length is a multiple of three, no padding is needed even with
the default option:

```lua
assert(babet.base64.encode("foo") == "Zm9v")
```

### Accepting unpadded input

The decoder rejects an incomplete final group without `=` by default:

```lua
local decoded, err = babet.base64.decode("aGVsbG8")
assert(decoded == nil)
assert(type(err) == "string")
```

Enable `allow_unpadded` explicitly when the protocol uses this form:

```lua
local decoded, err = babet.base64.decode("aGVsbG8", {
    allow_unpadded = true,
})
assert(decoded, err)
assert(decoded == "hello")
```

`allow_unpadded` does not relax other rules: a one-symbol final group remains
truncated, and non-zero unused bits remain invalid.

### Combined URL-safe, unpadded example

This form is common in protocol identifiers and some JSON fields:

```lua
local source = string.char(0, 1, 2, 251, 255)

local token, err = babet.base64.encode(source, {
    url_safe = true,
    padding = false,
})
assert(token, err)

local restored
restored, err = babet.base64.decode(token, {
    url_safe = true,
    allow_unpadded = true,
})
assert(restored, err)
assert(restored == source)
```

<a id="base64-strict-decode"></a>
## Strict decoding

The decoder checks, among other rules:

- every character belongs exactly to the selected alphabet;
- `=` appears only at the end;
- no more than two padding characters are present;
- padded length is a multiple of four;
- an unpadded tail contains two or three symbols, never one;
- unused bits in the final symbol are zero.

These inputs are therefore rejected:

```lua
local invalid = {
    "%%%",   -- characters outside the alphabet
    "AA=A",  -- padding in the middle
    "A===",  -- too much padding
    "Zg=",   -- invalid padded length
    "Zh==",  -- non-zero unused bits
    "Zm9=",  -- non-zero unused bits
}

for _, text in ipairs(invalid) do
    local value, err = babet.base64.decode(text)
    assert(value == nil)
    assert(type(err) == "string")
end
```

Positions reported by `invalid character`, `invalid padding`, or
`non-zero trailing bits` errors are one-based byte positions in the original
input string.

<a id="base64-whitespace"></a>
## ASCII whitespace

Whitespace is an invalid character by default:

```lua
local value, err = babet.base64.decode("Zm9v\nYmFy")
assert(value == nil)
```

`ignore_whitespace = true` ignores the six classic ASCII whitespace bytes:
space, tab, line feed, vertical tab, form feed, and carriage return.

```lua
local value, err = babet.base64.decode(" Zm9v\tYmFy\r\n", {
    ignore_whitespace = true,
})
assert(value, err)
assert(value == "foobar")
```

The option removes no other Unicode or control byte. It also does not permit
bad padding or the wrong alphabet.

When whitespace is ignored, an error position still refers to the original
string, including whitespace.

<a id="base64-max-output"></a>
## Output limit

`max_output` bounds the exact decoded result size. The limit is checked after complete lexical and canonical Base64
validation, then before the decoded output string is allocated.

```lua
local value, err = babet.base64.decode("Zm9v", {
    max_output = 2,
})
assert(value == nil)
assert(err == "base64: decoded output exceeds max_output")
```

The limit is inclusive:

```lua
local value, err = babet.base64.decode("Zm9v", {
    max_output = 3,
})
assert(value, err)
assert(value == "foo")
```

`max_output = 0` accepts only empty output:

```lua
assert(babet.base64.decode("", { max_output = 0 }) == "")
assert(babet.base64.decode("Zg==", { max_output = 0 }) == nil)
```

Set a protocol-appropriate limit for untrusted Base64 values:

```lua
local png, err = babet.base64.decode(response.value, {
    max_output = 32 * 1024 * 1024,
})
assert(png, err)
```

The limit applies to decoded output, not to Base64 text length.

<a id="base64-binary"></a>
## Binary data and files

Base64 imposes no UTF-8 requirement. Lua strings containing arbitrary bytes are
accepted:

```lua
local original = "\0\1\2abc\255"
local encoded = assert(babet.base64.encode(original))
local decoded = assert(babet.base64.decode(encoded))
assert(decoded == original)
```

To encode a file:

```lua
local file = assert(io.open("screenshot.png", "rb"))
local data = assert(file:read("*a"))
assert(file:close())

local text, err = babet.base64.encode(data)
assert(text, err)
```

To write a decoded value:

```lua
local data, err = babet.base64.decode(text, {
    max_output = 32 * 1024 * 1024,
})
assert(data, err)

local ok
ok, err = babet.writeFileAtomic("screenshot-restored.png", data, {
    overwrite = true,
    permissions = tonumber("600", 8),
})
assert(ok, err)
```

`babet.writeFileAtomic()` publishes the decoded bytes from a private
same-directory temporary file and does not expose a partially written image.

<a id="base64-worker"></a>
## Using the module in a worker

The submodule is registered in every worker Lua state:

```lua
local job = assert(babet.workers.spawn([[
    local encoded = assert(babet.base64.encode("hello"))
    local decoded = assert(babet.base64.decode(encoded))
    return decoded == "hello"
]]))

local ok, result = job:join()
assert(ok and result == true)
```

The current `worker.args`, result, and worker-queue transport still uses JSON
and rejects strings containing a NUL byte. Base64 can turn binary data into
transportable text, at a size cost of roughly one third.

```lua
local encoded = assert(babet.base64.encode(binary_data))
local job = assert(babet.workers.spawn([[
    return assert(babet.base64.decode(worker.args.encoded))
]], { encoded = encoded }))
```

If the decoded result contains a NUL, it cannot be returned directly through
the current JSON worker transport. The worker must process it, write it to a
file, or re-encode it before returning it.

<a id="base64-errors"></a>
## Error contract

### Call errors: Lua exception

Programming errors raise a Lua error:

- wrong argument count;
- non-string data or text;
- non-table options;
- non-string option key;
- unknown option;
- wrongly typed boolean option;
- non-integer or negative `max_output`.

```lua
local ok, err = pcall(function()
    babet.base64.decode("Zm9v", { max_output = -1 })
end)
assert(ok == false)
```

### Data errors: `nil, err`

Invalid Base64 or an exceeded limit returns `nil, err`:

```lua
local value, err = babet.base64.decode("%%%")
assert(value == nil)
assert(type(err) == "string")
assert(err:find("base64:", 1, true) == 1)
```

The main message forms are:

- `base64: invalid character at byte N`;
- `base64: invalid padding at byte N`;
- `base64: truncated input`;
- `base64: non-zero trailing bits at byte N`;
- `base64: decoded output exceeds max_output`;
- `base64: out of memory`;
- `base64: encoded output too large` or `decoded output too large`.

The `internal ... mismatch` and `unexpected internal error` diagnostics are
defensive guards. They should not occur for ordinary valid or invalid user
input; report them as a Babet defect if they appear.

Only depend on documented reasons when code needs to distinguish a limit from
invalid data. Allocation wording and positional detail may be enriched later.

<a id="base64-limits"></a>
## Limits and design choices

The module processes a complete string in memory. It does not currently
provide:

- streaming encoders or decoders;
- direct file input/output;
- MIME line wrapping;
- automatic standard-versus-URL-safe alphabet detection;
- a permissive mode accepting non-canonical padding or trailing bits.

These exclusions are deliberate. The API stays small, deterministic, and
suited to Selenium screenshots, tokens, JSON payloads, small binary resources,
and exchanges with external tools.
