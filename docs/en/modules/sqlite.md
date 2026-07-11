> **English** | [Français](../../fr/modules/sqlite.md)

# `babet.sqlite` — embedded SQL database

Wraps SQLite 3.53.1 (vendored), the most-deployed database engine
in the world. Zero-config persistence for any script that needs
more than a JSON file but less than a database server.

## Why

A script that needs to keep state across runs (a bot's seen-list,
a scraper's progress, accumulated metrics) shouldn't have to pull
in PostgreSQL or invent its own file format. SQLite is exactly
right at this scale : single file, transactional, fast, no daemon.

The Lua API mirrors the SQLite C API closely (open / exec /
prepare / step / finalize) with safer defaults and Lua-friendly
error returns.

## API

### Opening and closing

| Function | Returns |
| --- | --- |
| `babet.sqlite.open(path, opts?)` | `db` (userdata) \| `(nil, err)` |
| `db:close()` | `(true, nil)` — idempotent |

`opts` :

| Field          | Type                                                      | Default                                |
| -------------- | --------------------------------------------------------- | -------------------------------------- |
| `wal`          | boolean — enable WAL journal mode                         | `false`                                |
| `busy_timeout` | integer ms — automatic retry for this long on a locked db | `0` = **none** (immediate SQLITE_BUSY) |

> An earlier version of this page also documented `opts.readonly`
> and `opts.foreign_keys` : they don't exist — see "Not in v1".

Special path `":memory:"` opens an in-memory database (lost on
close). Use for tests or transient processing.

### Execution and queries

| Function                 | Returns                                                          |
| ------------------------ | ----------------------------------------------------------------- |
| `db:exec(sql)`           | `(true, nil)` \| `(nil, err)` — multi-statement accepted         |
| `db:exec(sql, params)`   | same, with bound parameters                                       |
| `db:query(sql, params?)` | `stmt` (iterator) \| `(nil, err)` — **one** statement only       |

`db:query` returns a **callable iterator**, not a table : each call
yields the next row (a table keyed by column names), then `nil`
once exhausted — the idiomatic use is `for row in db:query(...) do`.
Resources are released on exhaustion or garbage collection ;
`stmt:close()` releases earlier (iteration abandoned midway).

Multi-statement SQL passed to `query` returns
`(nil, "sqlite: query supports only one statement; …")` — for
multi-statement SQL, use `exec`.

## Type mapping

| SQLite type | Lua type |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | string (binary-safe) |
| NULL | read : **key absent** from the row (`row.col == nil`, but `pairs()` won't see it) ; write : use the SQL literal `NULL` (no sentinel in v1) |

## Quick examples

```lua
local db = assert(babet.sqlite.open("state.db", { wal = true }))

-- Schema (multi-statement : exec)
db:exec([[
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        active INTEGER DEFAULT 1
    );
]])

-- Insert with parameters
assert(db:exec("INSERT INTO users (name) VALUES (?)", { "alice" }))

-- Last rowid : via SQL (no dedicated method in v1)
for row in db:query("SELECT last_insert_rowid() AS id") do
    print("inserted with id", row.id)
end

-- Query : query returns an ITERATOR
for row in db:query("SELECT id, name FROM users WHERE active = ?",
                    { 1 }) do
    print(row.id, row.name)
end

-- Transaction : via SQL (no wrapper in v1)
db:exec("BEGIN")
local ok1 = db:exec("UPDATE users SET active = 0 WHERE name = ?",
                    { "alice" })
local ok2 = db:exec("UPDATE users SET active = 1 WHERE name = ?",
                    { "bob" })
if ok1 and ok2 then
    db:exec("COMMIT")
else
    db:exec("ROLLBACK")
end

db:close()
```

## Error contract

- All runtime errors → `(nil, "sqlite: <description>")` with the
  SQLite error code in the message.
- **`exec(sql)` with placeholders but no `params` argument** →
  `(nil, "sqlite: SQL contains placeholders but no params table
  provided; …")` — an explicit error instead of silently binding
  NULL. The guard applies to **every** statement of a
  multi-statement SQL string (v21 audit).
- **Supported placeholders** : `?` (positional, bound from
  `params[1]`, `params[2]`, …) and `:name` / `@name` / `$name`
  (named, bound from `params.name` — the prefix is ignored).
  Numbered **`?NNN` placeholders are not supported** : the binder
  would treat them as a "named" parameter whose name is `"NNN"`
  (string key), a trap more than a feature. Use `?` or `:name`.
- **Sparse keys in `params`** (e.g. `{[1] = "a", [3] = "c"}`) →
  `(nil, err)`.
- **Empty BLOB string** → stored correctly as empty BLOB
  (previously buggy in pre-1.5).
- **Methods after `close`** → `(nil, "sqlite: connection closed")`.
- **Wrong argument types** → raises via `luaL_error`.

## Design decisions

- **WAL is opt-in, not default**. WAL is strictly better for most
  use cases, but it creates `*-wal` and `*-shm` sidecar files
  that some users find surprising. Opt-in keeps the default
  surprise-free, but every long-running daemon should pass
  `wal=true`.
- **Placeholders without `params` is an error**, not a silent
  NULL bind. Catches a class of injection-adjacent bugs early.
- **Errors are returned, not raised**. Even malformed SQL returns
  `(nil, err)`. Scripts that don't check are noisy but not
  catastrophic.

## Not in v1

> The following items were wrongly presented as available in an
> earlier version of this page — they belong to the original design
> and are **not implemented** :
> `db:prepare` / `stmt:exec` / `stmt:finalize` (reusable prepared
> statements — `query` re-prepares on each call),
> `db:transaction(fn)` / `db:in_transaction()` (workaround :
> `exec("BEGIN"/"COMMIT"/"ROLLBACK")`, see example),
> `db:last_insert_rowid()` / `db:changes()` (workaround :
> `SELECT last_insert_rowid()` / `SELECT changes()`),
> `opts.readonly` / `opts.foreign_keys` (workaround :
> `PRAGMA foreign_keys = ON` via `exec`), and the `db.NULL` write
> sentinel.

- `BLOB` streaming I/O (`sqlite3_blob_open`). Use string
  serialisation if you fit in memory.
- Virtual tables / FTS5 / R-Tree. Available via raw SQL if the
  vendored SQLite is built with them ; no Lua-level API yet.
- Backup API (`sqlite3_backup_init`). For now, `VACUUM INTO
  'backup.db'` works as a one-liner.

For a higher-level ORM-like layer, build it in Lua on top of
this API.
