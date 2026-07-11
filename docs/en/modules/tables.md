> **English** | [Français](../../fr/modules/tables.md)

# `babet` tables — table manipulation helpers

Two helpers that fill obvious gaps in the Lua standard library : a
proper deep copy, and a multi-source merge.

## Why

Lua's standard library has no built-in deep copy and no multi-source
table merge. Both are routine needs : merging config from defaults +
overrides, snapshotting a table before mutation, copying a tree of
options. Writing them per-script is repetitive and error-prone
(missing the metatable, cycles, etc.).

These two functions live directly on the `babet` table (no
sub-namespace) because they predate the per-module convention used
by recent additions.

## API

| Function | Returns |
| --- | --- |
| `babet.mergeTables(t1, t2, ...)` | new `table` — string keys merged (last writer wins), numeric keys appended in order |
| `babet.deepCopyTable(t)` | new `table`, recursively copied |

`mergeTables` is variadic — **two tables minimum** (fewer :
raises), as many as you want beyond that. The inputs
are not mutated. The merge has two rules :

- **String keys** : later tables overwrite earlier ones at the
  same key (last writer wins). Replacement is **shallow** : a
  table value overwrites the previous one **wholesale**, nested
  sections are not merged recursively. And values are
  **referenced, not copied** — the result shares its subtables
  with the inputs ; combine with `deepCopyTable` if you need an
  independent result.
- **Numeric keys (array part)** : concatenated in the order tables
  are passed, then in 1..n order within each table. So
  `mergeTables({1, 2}, {3, 4})` gives `{1, 2, 3, 4}`, not
  `{3, 4}`.

`deepCopyTable` copies nested tables recursively. Cycles are
detected (no infinite loop), and shared subtables are copied only
once (the structure is preserved, not duplicated). The
**metatable** of each copied table is set as-is on the copy
(shared reference — the metatable itself is not duplicated).
Non-table values (numbers, strings, booleans, functions, userdata)
are referenced as-is. Maximum depth : **75 levels** (beyond :
raises `"Table is too deep to copy (max depth 75 exceeded)"`).

## Quick example

```lua
-- String keys : last writer wins
local defaults = { port = 8080, host = "localhost", debug = false }
local user_cfg = { port = 9000, debug = true }
local cfg = babet.mergeTables(defaults, user_cfg)
-- cfg.port  == 9000      (user_cfg overrode)
-- cfg.host  == "localhost"
-- cfg.debug == true

-- Numeric keys : append in order
local a = { 1, 2 }
local b = { 3, 4 }
local merged = babet.mergeTables(a, b)
-- merged == { 1, 2, 3, 4 }   (NOT { 3, 4 })

-- Deep copy : snapshot before mutation
local snapshot = babet.deepCopyTable(cfg)
cfg.port = 9999             -- does NOT affect snapshot
print(snapshot.port)        -- still 9000
```

## Error contract

- **Wrong argument types** (passing a non-table to either function)
  → raises via `luaL_error`.
- Neither function returns errors via `(nil, err)`. They either
  succeed or raise.

## Design decisions

- **Shallow values are referenced, not deep-copied**, in
  `deepCopyTable`. Copying functions or userdata makes no sense,
  and copying immutable values (numbers, strings, booleans)
  changes nothing. Only tables are recursively duplicated.
- **Metatables are not copied** in `deepCopyTable`. This is a
  conscious choice : preserving a metatable across a copy can
  surprise callers (the copy still triggers `__index` callbacks
  that mutate the original). If you need to copy with metatable,
  do it explicitly with `setmetatable(babet.deepCopyTable(t),
  getmetatable(t))`.
- **`mergeTables` is shallow**. If two source tables share a sub-
  table at the same string key, the result references the last
  one unchanged — it does not recurse into it. Combine with
  `deepCopyTable` if you need merge-then-isolate semantics.
- **Numeric keys are appended, not overwritten**. The choice
  comes from the most common Lua use case : combining
  list-shaped tables (`{1, 2}` + `{3, 4}` → `{1, 2, 3, 4}`).
  If you wanted overwriting semantics on numeric keys, build a
  destination table and assign explicitly.

## Not in v1

Additive — could be added later without breaking SemVer :

- A `deepMergeTables` that recurses into nested tables when both
  sources have a table at the same key. Common request, but the
  semantics around lists vs maps gets ambiguous, hence not in v1.
- An `equalsTables` for deep structural comparison. Easy to write
  in pure Lua, hasn't surfaced as a real need yet.
