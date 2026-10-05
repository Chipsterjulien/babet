> **English** | [Français](../../fr/modules/tables.md)

# `babet` tables — merging and copying Lua tables

Two historical helpers live directly on the `babet` table:

- `babet.mergeTables(...)` builds a new table from several sources;
- `babet.deepCopyTable(t)` recursively copies **values** that are tables.

They operate on entries actually stored in Lua tables. The `__pairs` and
`__index` metamethods therefore do not provide virtual fields to merge or copy.

## Module contents

- [API](#tables-api)
- [`babet.mergeTables(t1, t2, ...)`](#tables-merge)
  - [Positive integer keys: concatenation](#tables-positive-keys)
  - [Every other key: last writer wins](#tables-other-keys)
  - [Shallow merge](#tables-shallow)
- [`babet.deepCopyTable(t)`](#tables-deep-copy)
  - [Values and shared graph structure](#tables-values)
  - [Keys are not copied](#tables-keys)
  - [Metatables and raw traversal](#tables-metatables)
  - [Maximum depth](#tables-depth)
- [Error contract](#tables-errors)
- [Limits and design choices](#tables-limits)
- [Not in v1](#tables-not-exposed)

<a id="tables-api"></a>
## API

| Function | Returns |
| --- | --- |
| `babet.mergeTables(t1, t2, ...)` | one new table |
| `babet.deepCopyTable(t)` | one new table |

Both functions return exactly one value on success. They never return
`(nil, err)`: call errors and depth errors are raised.

<a id="tables-merge"></a>
## `babet.mergeTables(t1, t2, ...)`

At least two arguments are required and every argument must be a table. The API
sets no additional arity limit beyond Lua's general limits.

Sources are not mutated. The result is a plain table without a metatable, even
when source tables have one.

<a id="tables-positive-keys"></a>
### Positive integer keys: concatenation

Every key represented by Lua as an integer `>= 1` is treated as a list
position. This includes a key written as `2.0`, which Lua canonicalizes to an
integer.

Within each source, such keys are visited in ascending numeric order, then their
values are appended to the result. Holes and original indices are compacted:

```lua
local r = babet.mergeTables(
    { [4] = "d", [2] = "b" },
    { [7] = "g", [1] = "a" }
)

-- r == { "b", "d", "a", "g" }
```

The same list position appearing in several sources is not overwritten: every
value is appended.

<a id="tables-other-keys"></a>
### Every other key: last writer wins

String, boolean, table, function, thread, userdata and light userdata keys, along with floating,
zero and negative numeric keys, keep their original identity. A later source
overwrites an earlier value for the same key:

```lua
local key = {}
local r = babet.mergeTables(
    { mode = "safe", [key] = 1, [0] = "a" },
    { mode = "fast", [key] = 2, [0] = "b" }
)

-- r.mode == "fast"
-- r[key]  == 2
-- r[0]    == "b"
```

<a id="tables-shallow"></a>
### Shallow merge

Values are never copied. A subtable placed in the result is the same table as
in the source:

```lua
local nested = { enabled = false }
local r = babet.mergeTables({ nested = nested }, {})

r.nested.enabled = true
-- nested.enabled == true
```

To obtain an independent graph for table values afterwards, use:

```lua
local isolated = babet.deepCopyTable(
    babet.mergeTables(defaults, overrides)
)
```

<a id="tables-deep-copy"></a>
## `babet.deepCopyTable(t)`

The function requires exactly one table. It creates a new table for the root and
for every **value** that is itself a table.

<a id="tables-values"></a>
### Values and shared graph structure

Cycles reached through values are supported and graph identity is preserved:

```lua
local shared = { value = 42 }
local source = { a = shared, b = shared }
source.self = source

local copy = babet.deepCopyTable(source)

-- copy ~= source
-- copy.a ~= shared
-- copy.a == copy.b
-- copy.self == copy
```

Non-table values — numbers, strings, booleans, functions, threads, userdata and
light userdata — are reused as-is.

<a id="tables-keys"></a>
### Keys are not copied

Every key keeps its original value and identity. In particular, a table used as
a key remains the source table:

```lua
local key = { id = 1 }
local source = {
    [key] = "value",
    key_as_value = key,
}
local copy = babet.deepCopyTable(source)

-- copy[key] == "value"          -- original key retained
-- copy.key_as_value ~= key      -- table value copied
-- copy[copy.key_as_value] == nil
```

The function is therefore a deep copy of **table values**, not a structural copy
of table keys.

<a id="tables-metatables"></a>
### Metatables and raw traversal

The actual metatable of every copied table is attached to its copy **by
reference**. It is not duplicated. Mutating that metatable therefore affects
both source and copy.

Only actually stored pairs are traversed. A field returned through `__index` or
invented by `__pairs` is not materialized in the copy. Once the shared
metatable is attached, its behavior naturally remains active on the copy.

<a id="tables-depth"></a>
### Maximum depth

The root is at depth `0`. Up to **75 descents into new table values** are
accepted, for at most 76 tables along one root-inclusive path. A 76th descent
into a previously unseen table raises:

```text
Table is too deep to copy (max depth 75 exceeded)
```

A reference to an already copied table does not create a new level, so a cycle
may close exactly at the boundary.

<a id="tables-errors"></a>
## Error contract

Errors are raised through the Lua API for:

- fewer than two arguments to `mergeTables`;
- any non-table argument to `mergeTables`;
- an argument count other than one for `deepCopyTable`;
- a non-table argument to `deepCopyTable`;
- exceeding the maximum depth.

```lua
local ok, err = pcall(babet.deepCopyTable, 42)
-- ok == false; err contains "Argument must be a table"
```

<a id="tables-limits"></a>
## Limits and design choices

- `mergeTables` is not a deep merge: a later subtable replaces the earlier
  reference wholesale.
- Source metatables are ignored by `mergeTables`; its result has none.
- `deepCopyTable` shares metatables and table keys with the source.
- A weak metatable (`__mode`) remains weak on the copy because it is shared.
- Map-key order is undefined. Only the positive-integer ordering of
  `mergeTables` is guaranteed.
- `mergeTables` copies dense positive integer keys `1..n` directly. Sparse
  positive keys are sorted in temporary storage owned by Lua, which remains
  reclaimable after an allocation error. For a source with `m` entries and
  `k` positive integer keys, the traversal costs O(m) for dense keys and
  O(m + k log k) for sparse keys, with O(k) temporary storage in the latter case.

<a id="tables-not-exposed"></a>
## Not in v1

Features such as `deepMergeTables` or deep structural comparison could be added
separately. They are not part of the current API.
