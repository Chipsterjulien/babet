> **English** | [Français](../../fr/modules/argparse.md)

# `argparse` — command-line arguments

`argparse` is a pure-Lua module bundled with Babet. It builds a declarative
parser for flags, valued options, and positional arguments:

```lua
local argparse = require("argparse")
local parser = argparse("my-script", "Optional description")
```

The module never calls `print` or `os.exit`. Help and errors are returned to
the script, which decides how to display them and which exit code to use.

## Module contents

- [Loading and metadata](#argparse-loading)
- [API](#argparse-api)
- [Declaring flags and options](#argparse-declare-options)
- [Declaring positionals](#argparse-positionals)
- [The `opts` table](#argparse-opts)
  - [Common fields](#argparse-opts-common)
  - [Value-only fields](#argparse-opts-values)
  - [Destination](#argparse-destination)
- [Argument source](#argparse-source)
  - [Global `arg` table](#argparse-global-arg)
  - [Explicit array](#argparse-explicit-array)
- [Recognized forms](#argparse-forms)
- [Defaults, choices, and conversion](#argparse-defaults)
- [`parse` results](#argparse-results)
  - [Normal success](#argparse-result-success)
  - [Built-in help](#argparse-result-help)
  - [User-input error](#argparse-result-user-error)
  - [Programming error](#argparse-result-programming-error)
- [Complete example](#argparse-example)
- [Text produced by `get_usage`](#argparse-usage)
- [Current limitations](#argparse-limits)

<a id="argparse-loading"></a>
## Loading and metadata

```lua
local argparse = require("argparse")

print(argparse._VERSION)      -- "babet argparse 1.1.0"
print(argparse._DESCRIPTION)  -- English description
```

`require("argparse")` returns a callable table. The constructor accepts zero,
one, or two arguments:

```lua
argparse()                         -- displayed program: "prog"
argparse("tool")                   -- program name
argparse("tool", "Description")  -- name and description
```

`prog` and `description` must be strings when supplied. An extra argument or
a wrong type raises a Lua error: this is a programming error, not a
command-line error.

<a id="argparse-api"></a>
## API

| Method | Result | Purpose |
| --- | --- | --- |
| `parser:flag(spec [, opts])` | `parser` | Declare a flag with no value. |
| `parser:option(spec [, opts])` | `parser` | Declare an option that consumes a value. |
| `parser:argument(name [, opts])` | `parser` | Declare a positional argument. |
| `parser:parse([src])` | `res, err` | Parse `src` or the global `arg` table. |
| `parser:get_usage()` | string | Generate the help text. |

Builder methods are chainable:

```lua
local parser = argparse("copy")
    :flag("-v --verbose")
    :option("-o --output")
    :argument("source")
```

Arities are strict. For example,
`parser:option("-o", {}, "extra")` and `parser:get_usage(true)` raise a Lua
error.

<a id="argparse-declare-options"></a>
## Declaring flags and options

`spec` is one string containing one or more whitespace-separated names:

```lua
parser:flag("-v")
parser:flag("--verbose")
parser:flag("-v --verbose")
parser:option("-o --output")
```

Each name must:

- start with one or two dashes;
- contain at least one character after the dashes;
- contain no `=`;
- not be duplicated in the same spec or parser.

The following names are reserved and cannot be declared:

- `-`: treated as a literal positional;
- `--`: ends option parsing;
- `-h` and `--help`: built-in help.

A triple-dash name such as `---verbose` is rejected as well.

All validation happens before the parser is modified. If a builder error is
caught with `pcall`, no partial option or alias remains registered.

<a id="argparse-positionals"></a>
## Declaring positionals

```lua
parser:argument("input")
parser:argument("output", { required = false })
```

The name must be a non-empty string with no whitespace and no leading dash.
Positionals are assigned strictly from left to right.

A positional is required by default. It becomes optional when:

- `required = false` is specified; or
- a `default` is supplied without an explicit `required` field.

All required positionals must precede optional ones. The builder therefore
rejects this ambiguous declaration:

```lua
parser
    :argument("optional", { required = false })
    :argument("required") -- Lua error
```

<a id="argparse-opts"></a>
## The `opts` table

`opts` must be a table or `nil`. Unknown fields and fields with a wrong type
raise a Lua error immediately. This catches a typo such as `hlep` instead of
`help`.

<a id="argparse-opts-common"></a>
### Common fields

| Field | Type | Effect |
| --- | --- | --- |
| `help` | string | Text appended by `get_usage()`. |
| `default` | any Lua value | Value used when the item is absent. |
| `dest` | non-empty string | Key used in the result table. |
| `required` | boolean | Require the item to be present. |

These four fields are accepted by `flag`, `option`, and `argument`.

<a id="argparse-opts-values"></a>
### Value-only fields

| Field | Type | Effect |
| --- | --- | --- |
| `choices` | dense array of strings | Allow only selected raw values. |
| `convert` | function | Convert the raw string to a Lua value. |

`choices` and `convert` are accepted by `option` and `argument`, but not by
`flag`, since a flag consumes no value.

The builder copies the `choices` array. Mutating the original table later
does not change the parser.

<a id="argparse-destination"></a>
### Destination

Without `dest`, the destination is:

1. the first long name without `--`, when present;
2. otherwise the first short name without its first `-`.

```lua
parser:option("-o --output") -- destination: "output"
parser:flag("-v")            -- destination: "v"
```

A destination must be unique across the parser. `help` and `usage` are
reserved for the built-in help result.

```lua
parser:flag("-q", { dest = "quiet" })
```

<a id="argparse-source"></a>
## Argument source

<a id="argparse-global-arg"></a>
### Global `arg` table

With no argument, `parse()` reads the global `arg` table at indices `1`, `2`,
and so on up to the first hole:

```lua
local result, err = parser:parse()
```

Index `0` and negative indices are ignored. `parse(nil)` is equivalent to
`parse()`.

Every encountered value must be a string. If `arg` is not a table, the parser
uses an empty argument list.

<a id="argparse-explicit-array"></a>
### Explicit array

For tests or programmatically built input:

```lua
local result, err = parser:parse({ "-v", "input.txt" })
```

The table must be a dense array indexed from `1` to `n`, with no holes, no
extra keys, and string values only. An invalid source is a parsing error and
returns `(nil, err)`; it does not raise.

<a id="argparse-forms"></a>
## Recognized forms

A valued option accepts:

```text
--long value
--long=value
-s value
-s=value
```

An empty inline value is valid:

```lua
parser:parse({ "--output=" }) -- output == ""
```

Options remain active after a positional until `--` is encountered:

```text
input.txt --verbose
```

`--` ends option parsing. Every following token becomes positional, even if
it starts with `-`:

```lua
parser:parse({ "--", "-5" })
```

Before `--`, a token such as `-5` is interpreted as an option name. A negative
number used as an option value needs no delimiter:

```lua
parser:parse({ "--count", "-5", "input.txt" })
```

The token following a valued option is always consumed literally, even when
it looks like an option or equals `--`:

```lua
parser:parse({ "--output", "--verbose" })
-- output == "--verbose"; verbose is not enabled
```

A lone `-` is positional. Repeated options are accepted and the last value
wins. A repeated flag simply remains `true`.

The following forms are not supported:

- combined short options, such as `-abc` for three flags;
- attached short values, such as `-ofile.txt`;
- variadic positionals.

A literal declared name `-abc` is still a normal option when the spec contains
that exact name; it is never split.

<a id="argparse-defaults"></a>
## Defaults, choices, and conversion

A user-supplied value is processed in this order:

1. check `choices` against the raw string;
2. call `convert` with that string.

```lua
parser:option("-n --count", {
    choices = { "1", "2", "3" },
    convert = tonumber,
})
```

Every choice is a string. If the raw value is absent from the array,
`parse()` returns `(nil, err)` without calling the converter.

A converter may:

- return any non-`nil` value, including `false`, to succeed;
- return `nil` to fail with the generic `invalid value` message;
- return `nil, "reason"` to supply a reason;
- raise, which is caught and reported as `conversion error`.

`default` values are already prepared Lua values: they are neither checked by
`choices` nor passed through `convert`. They keep their type and, for a table,
their identity. An option with `required = true` remains required even when a
`default` exists.

For a flag:

- when absent, it equals `default` if supplied, otherwise `false`;
- when present, it always equals `true`.

An absent option or positional with a `nil` default has no observable key in
the result table, as expected for Lua tables.

<a id="argparse-results"></a>
## `parse` results

<a id="argparse-result-success"></a>
### Normal success

```lua
local result, err = parser:parse()
-- result: table
-- err:    nil
```

The table is indexed by declared destinations.

<a id="argparse-result-help"></a>
### Built-in help

Before `--`, `-h` or `--help` stops parsing immediately and returns:

```lua
{
    help = true,
    usage = "...",
}, nil
```

Required options, missing positionals, and later tokens are not validated.
After `--`, `-h` and `--help` are ordinary positionals.

Help is a success and is not merged into a normal result table. Destinations
`help` and `usage` are reserved to avoid ambiguity in calling code.

<a id="argparse-result-user-error"></a>
### User-input error

Command-line errors return `(nil, message)`:

```text
unknown option '--bad'
option '--output' requires a value
flag '-v' does not take a value
missing required option '--output'
missing required argument 'input'
argument 'mode': invalid choice 'other'
option '--count': invalid value
unexpected argument 'extra'
```

`parse()` catches errors raised by `convert`, so a user value never propagates
the converter's exception.

<a id="argparse-result-programming-error"></a>
### Programming error

The constructor and builder raise a Lua error for:

- wrong arity;
- wrong type;
- an empty or unusable spec;
- a reserved name or destination;
- a duplicate name or destination;
- an unknown `opts` field;
- an invalid `choices` array;
- a required positional after an optional positional.

Wrong `parse` arity is also a programming error. In contrast, a malformed
`src` table returns `(nil, err)`.

<a id="argparse-example"></a>
## Complete example

```lua
local argparse = require("argparse")

local parser = argparse("convert", "Convert a file.")
    :flag("-v --verbose", { help = "Show more detail" })
    :option("-o --output", { default = "out.txt" })
    :option("-n --count", {
        choices = { "1", "2", "3" },
        convert = tonumber,
        default = 1,
    })
    :argument("input")

local args, err = parser:parse()
if args and args.help then
    print(args.usage)
    return
end
if not args then
    io.stderr:write("error: ", err, "\n")
    io.stderr:write(parser:get_usage(), "\n")
    os.exit(2)
end

print(args.input, args.output, args.count, args.verbose)
```

<a id="argparse-usage"></a>
## Text produced by `get_usage`

`get_usage()` returns a string and writes nothing. The section labels and the
built-in help message are fixed in English: `Usage`, `Arguments`, `Options`,
and `show this help`. There is no localization, column-width, or visual-group
API yet.

The text lists positionals and declared help strings, but it does not
automatically show defaults, choices, or the required status of options.

<a id="argparse-limits"></a>
## Current limitations

The module does not expose:

- subcommands;
- variadic positionals (`nargs`);
- mutually exclusive groups;
- repeatable options accumulated into an array;
- combined short options;
- help localization or customization;
- a way to disable built-in help.
