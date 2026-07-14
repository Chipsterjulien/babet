> **English** | [Français](../../fr/modules/sqlite.md)

# `babet.sqlite` — embedded SQL database

`babet.sqlite` embeds SQLite 3.53.1 and exposes a deliberately small Lua API:
open a connection, execute SQL, and lazily iterate over results. Prepared
statements remain internal; `prepare`, `step`, and `finalize` are not exposed.

## Module contents

- [API](#sqlite-api)
  - [Opening and closing](#sqlite-open-close)
  - [Execution](#sqlite-exec)
  - [SQL parameters](#sqlite-parameters)
  - [SQL text and NUL bytes](#sqlite-sql-text)
- [Row reading and type mapping](#sqlite-rows)
- [Lifetime](#sqlite-lifetime)
- [Error contract](#sqlite-errors)
- [Complete example](#sqlite-example)
- [Not exposed in v1](#sqlite-not-exposed)

<a id="sqlite-api"></a>
## API

<a id="sqlite-open-close"></a>
### Opening and closing

| Function | Returns |
| --- | --- |
| `babet.sqlite.open(path, opts?)` | `db` (userdata) \| `(nil, err)` |
| `db:close()` | `(true, nil)` — idempotent |

`open` opens or creates a read/write database. The special path `":memory:"`
creates an in-memory database which is lost on close. The path must be a string
without NUL bytes.

`opts` is an optional table:

| Field | Type | Default |
| --- | --- | --- |
| `wal` | boolean — requests `PRAGMA journal_mode=WAL` | `false` |
| `busy_timeout` | integer from `0` to `3600000` ms | `0` — no wait |

`wal = true` requests WAL mode, but SQLite may keep another mode when WAL is not
applicable. This notably happens with `":memory:"`, which keeps its in-memory
journal mode without making `open` fail.

`busy_timeout` asks SQLite to retry for the requested duration when the database
is locked. A value of `0` lets `SQLITE_BUSY` surface immediately.

<a id="sqlite-exec"></a>
### Execution

| Function | Returns |
| --- | --- |
| `db:exec(sql)` | `(true, nil)` \| `(nil, err)` — multiple statements accepted |
| `db:exec(sql, params)` | `(true, nil)` \| `(nil, err)` — **one** statement only |
| `db:query(sql, params?)` | `stmt` (callable iterator) \| `(nil, err)` — **one** statement only |
| `stmt:close()` | `(true, nil)` — idempotent |

#### `db:exec`

Without a `params` table, `exec` accepts multiple semicolon-separated
statements. They are prepared and executed in order. Execution stops at the
first error; earlier effects remain unless the statements were inside an
explicit transaction.

With a `params` table, only one statement is accepted. A second statement
returns `(nil, err)`. Trailing whitespace, semicolons, and SQL comments
(`-- ...` or `/* ... */`) do not count as a second statement.

A `SELECT` passed to `exec` is stepped to completion, but its rows are ignored.
Use `query` to read them.

An empty SQL string, or one containing only separators/comments, is a successful
no-op with `exec(sql)` or `exec(sql, {})`. A non-empty `params` table without an
SQL statement raises a Lua error.

#### `db:query`

`query` immediately prepares one statement and returns a **callable iterator**.
The statement is not executed until the iterator is called for the first time:

```lua
local stmt = assert(db:query("SELECT id, name FROM users ORDER BY id"))

local first = stmt() -- first sqlite3_step() call
while first do
    print(first.id, first.name)
    first = stmt()
end
```

The idiomatic form is:

```lua
for row in db:query("SELECT id, name FROM users ORDER BY id") do
    print(row.id, row.name)
end
```

Each row is a table keyed by column name. The iterator returns `nil` once
exhausted and finalizes the statement at that point. `stmt:close()` releases it
earlier; later calls to `stmt()` simply return `nil`. Garbage collection also
finalizes an abandoned iterator, for example after a `break`.

`query` is not restricted to `SELECT`. A DDL or DML statement is executed on
the iterator's first call, then the iterator ends without yielding a row.

A query with no matching rows returns an iterator that immediately yields
`nil`. Empty or comment-only SQL likewise returns an already-exhausted iterator.

Multiple statements are rejected. Trailing whitespace, semicolons, and comments
remain valid:

```lua
local stmt = assert(db:query("SELECT 1 AS value; -- trailing comment"))
print(stmt().value)
```

<a id="sqlite-parameters"></a>
### SQL parameters

The following forms are supported:

| Placeholder | Lua value |
| --- | --- |
| `?` | `params[1]`, `params[2]`, etc., in `?` appearance order |
| `:name`, `@name`, `$name` | `params.name` — prefix removed |

Positional and named parameters may be mixed:

```lua
assert(db:exec(
    "INSERT INTO events VALUES (?, :kind, ?)",
    { 42, 1700000000, kind = "start" }
))
```

The table must match the placeholders exactly. Missing or extra parameters,
sparse numeric indexes, non-integer numeric indexes, and unsupported value types
raise a Lua error. Passing `nil` as the third argument is equivalent to omitting
the table.

Numbered `?NNN` placeholders are not part of the public contract. Use `?` or a
named placeholder.

Accepted bind types:

| Lua type | SQLite value |
| --- | --- |
| boolean | INTEGER `0` or `1` |
| integer | INTEGER |
| non-integer number | REAL |
| string | TEXT, including strings containing NUL bytes |

A Lua string is **always** bound with `sqlite3_bind_text`, even when the target
column is declared `BLOB`. Version 1 exposes neither a BLOB constructor nor a
sentinel for binding `NULL`. Use the SQL literal `NULL` when needed.

<a id="sqlite-sql-text"></a>
### SQL text and NUL bytes

The SQL text must be a string without NUL bytes. SQLite would treat the NUL as
end-of-string and could execute only a prefix, so Babet rejects it before
preparing anything. SQL length is also limited to `INT_MAX` bytes, matching the
`sqlite3_prepare_v2` API.

This restriction applies only to the **SQL text**. Bound strings are binary-safe
and may contain NUL bytes.

<a id="sqlite-rows"></a>
## Row reading and type mapping

| SQLite type read | Lua type |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | binary-safe string, including an empty BLOB |
| NULL | absent key (`row.col == nil` and not visible through `pairs`) |

When multiple result columns have the same name, each assignment overwrites the
previous one: the last column wins. Use aliases to retain every value:

```sql
SELECT users.id AS user_id, orders.id AS order_id
FROM users
JOIN orders ON orders.user_id = users.id;
```

<a id="sqlite-lifetime"></a>
## Lifetime

`db:close()` is idempotent. After closing, every new `db:exec` or `db:query`
call returns `(nil, "sqlite: connection closed")`.

An iterator created **before** `db:close()` remains usable. Babet uses
`sqlite3_close_v2`, so SQLite temporarily keeps a "zombie" connection until the
last active statement has been finalized.

```lua
local stmt = assert(db:query("SELECT id FROM users ORDER BY id"))
assert(db:close())

for row in stmt do
    print(row.id) -- remains valid
end
```

<a id="sqlite-errors"></a>
## Error contract

Errors fall into two categories:

- Operational errors detected by `open`, `close`, `exec`, or while preparing a
  `query` return `(nil, "sqlite: <description>")`. The message contains a
  description but does not guarantee a numeric SQLite error code.
- Wrong argument types, invalid `params` tables, and errors occurring while an
  iterator is called raise a Lua error. Wrap the iteration in `pcall` when such
  errors must be caught.

Without a `params` table, placeholders are checked in **every** statement passed
to `exec`. Babet returns an explicit error instead of allowing SQLite to bind
`NULL` silently.

<a id="sqlite-example"></a>
## Complete example

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
}))

assert(db:exec([[
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS users_active_idx ON users(active);
]]))

assert(db:exec(
    "INSERT INTO users (name) VALUES (?)",
    { "alice" }
))

for row in db:query(
    "SELECT id, name FROM users WHERE active = ? ORDER BY id",
    { 1 }
) do
    print(row.id, row.name)
end

assert(db:exec("BEGIN"))
local ok, err = db:exec(
    "UPDATE users SET active = 0 WHERE name = :name",
    { name = "alice" }
)
if ok then
    assert(db:exec("COMMIT"))
else
    db:exec("ROLLBACK")
    error(err)
end

assert(db:close())
```

<a id="sqlite-not-exposed"></a>
## Not exposed in v1

The following items are not implemented:

- `db:prepare`, `stmt:exec`, and `stmt:finalize`;
- `db:transaction(fn)` and `db:in_transaction()`;
- `db:last_insert_rowid()` and `db:changes()`;
- `opts.readonly` and `opts.foreign_keys`;
- a `db.NULL` sentinel or `sqlite.blob(data)` constructor;
- the `sqlite3_blob_open` streaming BLOB API;
- the `sqlite3_backup_init` backup API.

Transactions, `last_insert_rowid`, `changes`, foreign keys, and `VACUUM INTO`
remain available through raw SQL. FTS5 and R-Tree are not enabled in the current
embedded build.
