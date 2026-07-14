> **English** | [Français](../../fr/modules/sqlite.md)

# `babet.sqlite` — embedded SQL database

`babet.sqlite` embeds SQLite 3.53.1 and exposes a compact but complete Lua API:
connections, direct SQL execution, lazy iterators, reusable prepared
statements, managed transactions, and explicit BLOB binding.

## Module contents

- [API](#sqlite-api)
  - [Opening and closing](#sqlite-open-close)
  - [Direct execution](#sqlite-direct)
  - [Reusable prepared statements](#sqlite-prepared)
  - [Managed transactions](#sqlite-transactions)
  - [SQL parameters](#sqlite-parameters)
  - [Explicit BLOB values](#sqlite-blobs)
  - [SQL text and NUL bytes](#sqlite-sql-text)
- [Row reading and type mapping](#sqlite-rows)
- [Lifetime](#sqlite-lifetime)
- [Error contract](#sqlite-errors)
- [Complete examples](#sqlite-examples)
- [Functions not exposed](#sqlite-not-exposed)

<a id="sqlite-api"></a>
## API

<a id="sqlite-open-close"></a>
### Opening and closing

| Function | Returns |
| --- | --- |
| `babet.sqlite.open(path, opts?)` | `db` userdata \| `(nil, err)` |
| `babet.sqlite.blob(data)` | opaque BLOB wrapper |
| `db:close()` | `(true, nil)` — idempotent |
| `db:in_transaction()` | boolean \| `(nil, err)` |

`open` opens or creates a read/write database. The special `":memory:"` path
creates a temporary in-memory database. The path must be a string without a
NUL byte.

Optional `opts` fields:

| Field | Type | Default |
| --- | --- | --- |
| `wal` | boolean — requests `PRAGMA journal_mode=WAL` | `false` |
| `busy_timeout` | integer from `0` to `3600000` ms | `0` |

`wal = true` requests WAL mode, but SQLite may keep another journal mode when
WAL is not applicable, notably for `":memory:"`.

`busy_timeout` asks SQLite to retry for the requested duration when the
database is locked. Zero reports `SQLITE_BUSY` immediately.

`db:in_transaction()` returns `true` whenever the connection is inside a
transaction, whether it was opened by `db:transaction()` or by manual SQL.

<a id="sqlite-direct"></a>
### Direct execution

| Function | Returns |
| --- | --- |
| `db:exec(sql)` | `(true, nil)` \| `(nil, err)` — multiple statements allowed |
| `db:exec(sql, params)` | `(true, nil)` \| `(nil, err)` — **one** statement |
| `db:query(sql, params?)` | callable temporary `stmt` \| `(nil, err)` |
| `stmt:close()` | `(true, nil)` — idempotent |

#### `db:exec`

Without `params`, `exec` accepts multiple semicolon-separated statements. They
are prepared and executed in order. Execution stops on the first error; earlier
statements remain committed unless they were inside an explicit transaction.

With `params`, exactly one statement is accepted. Trailing whitespace,
semicolons, and SQL comments do not count as another statement.

A `SELECT` passed to `exec` is stepped to completion and its rows are ignored.
Empty or comment-only SQL is a successful no-op with `exec(sql)` or
`exec(sql, {})`.

#### `db:query`

`query` prepares one statement immediately and returns a **single-use callable
iterator**. Execution starts on the first iterator call:

```lua
for row in db:query("SELECT id, name FROM users ORDER BY id") do
    print(row.id, row.name)
end
```

Each row is a table keyed by column name. The iterator returns `nil` when it is
exhausted and automatically finalizes its statement. `stmt:close()` releases it
earlier, and garbage collection finalizes an iterator abandoned after `break`.

`query` also accepts DDL and DML. Such a statement runs on the first call and
then ends without yielding a row.

Multiple statements are rejected. Empty or comment-only SQL returns an already
exhausted iterator.

<a id="sqlite-prepared"></a>
### Reusable prepared statements

| Function | Returns |
| --- | --- |
| `db:prepare(sql)` | `prepared` \| `(nil, err)` |
| `prepared:exec(params?)` | `(true, nil)` \| `(nil, err)` |
| `prepared:query(params?)` | the same `prepared` userdata \| `(nil, err)` |
| `prepared:reset()` | `(true, nil)` \| `(nil, err)` |
| `prepared:close()` | `(true, nil)` — idempotent |
| `prepared:finalize()` | alias of `close()` |

`db:prepare()` accepts exactly **one non-empty SQL statement**. Preparation is
immediate, so an unknown table or column is reported before the first run.

A statement can then be reused as many times as needed:

```lua
local insert = assert(db:prepare(
    "INSERT INTO files(path, digest) VALUES(?, ?)"
))

for _, file in ipairs(files) do
    assert(insert:exec({ file.path, file.digest }))
end

assert(insert:finalize())
```

`prepared:exec()` resets the statement before binding, steps it to
`SQLITE_DONE`, then clears its bindings. A `SELECT` is fully consumed and its
rows are ignored.

`prepared:query()` resets and binds the statement, then returns **the same
userdata**, whose metatable makes it callable:

```lua
local select_by_age = assert(db:prepare([[
    SELECT id, name FROM users
    WHERE age >= ?
    ORDER BY id
]]))

for row in select_by_age:query({ 18 }) do
    print(row.id, row.name)
end

for row in select_by_age:query({ 65 }) do
    print("senior", row.name)
end
```

Natural exhaustion automatically resets the statement and clears all bindings.
After breaking early, either call `prepared:reset()`, start another
`prepared:query(...)`, or call `prepared:exec(...)`. The latter two operations
also reset the previous partial iteration and discard its remaining rows. A
prepared statement can have only one active iteration: reusing the same
userdata from a nested loop therefore resets the outer loop.

Calling `prepared()` directly without an active `prepared:query()` simply
returns `nil`; it never executes SQL with cleared bindings.

`prepared:reset()` aborts the current run and clears bindings. `close()` and
`finalize()` permanently finalize the statement. Calling a closed prepared
userdata directly returns `nil`; execution methods return
`(nil, "sqlite: statement closed")`.

<a id="sqlite-transactions"></a>
### Managed transactions

```lua
local ok, result = db:transaction(function(tx)
    assert(tx:exec(
        "INSERT INTO accounts(name, balance) VALUES(?, ?)",
        { "alice", 100 }
    ))

    assert(tx:exec(
        "INSERT INTO audit(message) VALUES(?)",
        { "account created" }
    ))

    return "created"
end, "immediate")

assert(ok, result)
print(result) -- "created"
```

Signature:

```lua
ok, ...callback_results = db:transaction(callback [, mode])
-- or
nil, err = db:transaction(callback [, mode])
```

The callback receives the database connection as its only argument. `mode` is
one of:

- `"deferred"` — default;
- `"immediate"`;
- `"exclusive"`.

When the callback returns normally, Babet commits and returns `true` followed
by every callback result. A normal `nil` or `false` result **does not request a
rollback**. Only a Lua error triggers automatic rollback.

SQLite operations usually return `(nil, err)`, so use `assert` inside the
callback to convert operational failures into Lua errors:

```lua
local ok, err = db:transaction(function(tx)
    assert(tx:exec("INSERT INTO unique_names VALUES(?)", { "alice" }))
    assert(tx:exec("INSERT INTO unique_names VALUES(?)", { "alice" }))
end)

-- The second INSERT fails, assert raises, and both writes are rolled back.
```

Callback errors are caught: Babet attempts `ROLLBACK` and returns
`(nil, "sqlite: transaction callback failed: ...")` rather than rethrowing.
A failed `COMMIT` also returns `(nil, err)` after a best-effort rollback.

Intentional limitations:

- nested `db:transaction()` helpers are rejected;
- the helper is rejected while a manual SQL transaction is already active;
- `db:close()` is rejected during the callback;
- the callback must not issue its own `BEGIN`, `COMMIT`, or `ROLLBACK`.

Savepoints remain available through raw SQL.

<a id="sqlite-parameters"></a>
### SQL parameters

The following forms are supported by direct and prepared execution:

| Placeholder | Lua value |
| --- | --- |
| `?` | `params[1]`, `params[2]`, and so on in `?` order |
| `:name`, `@name`, `$name` | `params.name` with the prefix removed |

Positional and named parameters may be mixed:

```lua
assert(db:exec(
    "INSERT INTO events VALUES (?, :kind, ?)",
    { 42, 1700000000, kind = "start" }
))
```

The table must match all placeholders exactly. Missing or extra values, sparse
numeric indices, non-integer numeric indices, and unsupported value types raise
a Lua error. Explicit `nil` as the params argument is the same as omitting it.

Numbered `?NNN` placeholders are outside the public contract.

Accepted bind values:

| Lua type | SQLite value |
| --- | --- |
| boolean | INTEGER `0` or `1` |
| integer | INTEGER |
| non-integer number | REAL |
| string | TEXT, including embedded NUL bytes |
| `babet.sqlite.blob(data)` | binary-safe BLOB |

<a id="sqlite-blobs"></a>
### Explicit BLOB values

A normal Lua string is **always** bound with `sqlite3_bind_text`, even for a
column with BLOB affinity. `babet.sqlite.blob(data)` explicitly marks the same
bytes as a BLOB:

```lua
local insert = assert(db:prepare(
    "INSERT INTO assets(name, payload) VALUES(?, ?)"
))

assert(insert:exec({
    "icon",
    babet.sqlite.blob("\x89PNG\r\n\x1a\n...")
}))
```

The constructor accepts exactly one Lua string and returns an opaque userdata.
Embedded NUL bytes are preserved. `babet.sqlite.blob("")` creates a real
zero-byte BLOB rather than `NULL`.

The wrapper is only used for binding. Reading a BLOB column still returns a
binary-safe Lua string.

There is no explicit NULL sentinel yet; use the SQL literal `NULL` where
needed.

<a id="sqlite-sql-text"></a>
### SQL text and NUL bytes

SQL text must be a string without a NUL byte. SQLite would treat a NUL as the
end of the SQL string and could execute only a prefix, so Babet rejects it
before preparation. SQL text is also limited to `INT_MAX` bytes to match
`sqlite3_prepare_v2`.

This restriction applies only to **SQL text**. Bound strings and BLOB values
are binary-safe.

<a id="sqlite-rows"></a>
## Row reading and type mapping

| SQLite type | Lua type |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | binary-safe string, including an empty BLOB |
| NULL | absent table key (`row.col == nil` and absent from `pairs`) |

When multiple columns use the same name, the last column wins. Use aliases to
preserve every value.

SQLite `length()` counts characters for TEXT and may stop at an embedded NUL.
For diagnostic byte counts, use for example `length(CAST(col AS BLOB))`.

<a id="sqlite-lifetime"></a>
## Lifetime

`db:close()` is idempotent. After closing, new connection operations return
`(nil, "sqlite: connection closed")`.

An iterator or prepared statement created **before** `db:close()` remains
usable. Babet uses `sqlite3_close_v2`, so SQLite keeps a zombie connection until
the last active statement is finalized.

```lua
local stmt = assert(db:prepare("SELECT id FROM users ORDER BY id"))
assert(db:close())

for row in stmt:query() do
    print(row.id)
end

stmt:finalize()
```

Temporary `db:query` iterators and prepared statements both finalize their
handles from `__gc`. Explicit close/finalize is still preferable because it
releases locks and resources immediately.

<a id="sqlite-errors"></a>
## Error contract

Errors fall into two groups:

- operational failures (open, preparation, step, transaction, closed handle)
  generally return `(nil, "sqlite: <description>")`;
- wrong types, invalid arity, and invalid parameter tables raise a Lua error.

Errors raised while calling a query iterator (`db:query` or
`prepared:query`) are Lua errors because the iterator protocol cannot also
return a separate `(nil, err)` result.

When no params table is provided, placeholders are detected before execution.
Babet never lets SQLite silently bind them as `NULL`.

`db:transaction()` is the controlled exception: it catches callback Lua errors,
rolls back, and converts them to `(nil, err)`.

<a id="sqlite-examples"></a>
## Complete examples

### Prepared inserts and BLOB values

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
}))

assert(db:exec([[
    CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        digest BLOB NOT NULL
    )
]]))

local insert = assert(db:prepare([[
    INSERT INTO files(path, digest)
    VALUES(?, ?)
    ON CONFLICT(path) DO UPDATE SET digest = excluded.digest
]]))

for _, file in ipairs(files) do
    assert(insert:exec({
        file.path,
        babet.sqlite.blob(file.digest),
    }))
end

insert:finalize()
```

### Reusable query and managed transaction

```lua
local by_prefix = assert(db:prepare([[
    SELECT path, digest
    FROM files
    WHERE path LIKE ?
    ORDER BY path
]]))

local ok, count = db:transaction(function(tx)
    local n = 0
    for row in by_prefix:query({ "images/%" }) do
        assert(tx:exec(
            "INSERT INTO audit(path) VALUES(?)",
            { row.path }
        ))
        n = n + 1
    end
    return n
end, "immediate")

assert(ok, count)
print(count, "rows audited")

by_prefix:finalize()
assert(db:close())
```

<a id="sqlite-not-exposed"></a>
## Functions not exposed

The following are not implemented:

- an explicit `sqlite.NULL` bind sentinel;
- `db:last_insert_rowid()` and `db:changes()`;
- `opts.readonly` and `opts.foreign_keys`;
- a nested savepoint helper;
- the `sqlite3_blob_open` streaming BLOB API;
- the `sqlite3_backup_init` backup API.

`last_insert_rowid`, `changes`, foreign keys, savepoints, and `VACUUM INTO`
remain available through raw SQL. FTS5 and R-Tree are not enabled in the
current embedded build.
