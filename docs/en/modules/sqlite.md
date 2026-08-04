> **English** | [Français](../../fr/modules/sqlite.md)

# `babet.sqlite` — embedded SQL database

`babet.sqlite` embeds SQLite 3.53.1 and exposes a compact but complete Lua API:
read/write or read-only connections, per-connection foreign keys, change
counters, direct SQL execution, lazy iterators, reusable prepared statements,
managed transactions, nested savepoints, and explicit BLOB and `NULL` binding.

## Module contents

- [API](#sqlite-api)
  - [Opening and closing](#sqlite-open-close)
  - [Connection counters](#sqlite-counters)
  - [Direct execution](#sqlite-direct)
  - [Reusable prepared statements](#sqlite-prepared)
  - [Managed transactions](#sqlite-transactions)
  - [Nested savepoints](#sqlite-savepoints)
  - [SQL parameters](#sqlite-parameters)
  - [Explicit NULL values](#sqlite-nulls)
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
| `babet.sqlite.NULL` | exact lightuserdata sentinel used to bind SQL `NULL` |
| `db:close()` | `(true, nil)` — idempotent |
| `db:in_transaction()` | boolean \| `(nil, err)` |
| `db:transaction(callback, mode?)` | `true, ...callback_results` \| `(nil, err)` |
| `db:savepoint(callback)` | `true, ...callback_results` \| `(nil, err)` |
| `db:last_insert_rowid()` | integer \| `(nil, err)` |
| `db:changes()` | integer \| `(nil, err)` |
| `db:total_changes()` | integer \| `(nil, err)` |

By default, `open` opens or creates a read/write database. With
`readonly = true`, it opens an existing database without creating it and
SQLite rejects writes. The special `":memory:"` path creates a temporary
in-memory database. The path must be a string without a NUL byte.

Optional `opts` fields:

| Field | Type | Default |
| --- | --- | --- |
| `wal` | boolean — requests `PRAGMA journal_mode=WAL` | `false` |
| `busy_timeout` | integer from `0` to `3600000` ms | `0` |
| `readonly` | boolean — opens without creation or writes | `false` |
| `foreign_keys` | boolean — enforces foreign-key constraints | `false` |

`wal = true` requests WAL mode, but SQLite may keep another journal mode when
WAL is not applicable, notably for `":memory:"`.

`busy_timeout` asks SQLite to retry for the requested duration when the
database is locked. Zero reports `SQLITE_BUSY` immediately.

`readonly = true` uses native `SQLITE_OPEN_READONLY`. A missing database
returns `(nil, err)` without creating a file. Reads remain available; a write
statement returns `(nil, err)`. It combines with `busy_timeout` and
`foreign_keys`, but not with `wal = true`: that contradictory combination
raises a Lua error before opening the connection. This refusal applies only to
a request to **switch** the database to WAL mode. It does not prevent
`readonly = true` from opening a database that already uses WAL when
`wal = true` is omitted. SQLite must then be able to use the companion `-wal`
and `-shm` files; a fully read-only filesystem can fail when the required
`-shm` file does not already exist or cannot be used.

`foreign_keys = true` enables referential-integrity enforcement before the
connection's first statement. The setting belongs to each connection and does
not retroactively validate rows already stored. The `false` default preserves
Babet's historical SQLite behaviour.

Each option is useful independently. Set only a lock wait:

```lua
local db = assert(babet.sqlite.open("state.db", { busy_timeout = 2500 }))
```

Request WAL without changing the default lock wait:

```lua
local db = assert(babet.sqlite.open("state.db", { wal = true }))
```

Open for reads only:

```lua
local db = assert(babet.sqlite.open("state.db", { readonly = true }))
```

Enable foreign keys on a writer connection:

```lua
local db = assert(babet.sqlite.open("state.db", { foreign_keys = true }))
```

Combine WAL, lock waiting, and foreign keys:

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2500,
    foreign_keys = true,
}))
```

The `opts` table is strict: unknown fields, non-string option keys, wrong
types, and out-of-range timeouts raise a Lua error. Option lookup reads raw
table entries; an `__index` metamethod cannot supply or hide an option. Types
and incompatible combinations are checked before a native handle is acquired.
A contract error therefore creates neither a file nor a connection.

Combine all compatible reader options:

```lua
local db = assert(babet.sqlite.open("state.db", {
    readonly = true,
    busy_timeout = 2500,
    foreign_keys = true,
}))
```

`db:in_transaction()` returns `true` whenever the connection is inside a
transaction, whether it was opened by `db:transaction()`, by an outermost
`db:savepoint()`, or by manual SQL.

<a id="sqlite-counters"></a>
### Connection counters

The following methods read the connection state directly. They execute no SQL,
always return a Lua integer while the connection is open, and are available in
workers.

#### `db:last_insert_rowid()`

Returns the ROWID from the latest successful `INSERT` on this connection, or
`0` until a ROWID has been inserted. The value remains the latest relevant
`INSERT` value after a `SELECT`, `UPDATE`, or `DELETE`, and even after rolling
back an `INSERT` that had succeeded before the rollback.

```lua
local db = assert(babet.sqlite.open(":memory:"))
assert(db:exec("CREATE TABLE messages(id INTEGER PRIMARY KEY, body TEXT)"))
assert(db:exec("INSERT INTO messages(body) VALUES(?)", { "Hello" }))
local id = assert(db:last_insert_rowid())
print(id) -- 1
```

A successful statement did not necessarily insert a row. With
`INSERT OR IGNORE`, a constraint can be ignored and `last_insert_rowid()` then
retains the preceding ROWID. For a one-row insert that may be ignored, check
`changes() == 1` before using the ROWID:

```lua
assert(db:exec("INSERT OR IGNORE INTO messages(body) VALUES(?)",
    { "unique message" }))
assert(db:changes() == 1, "message was not inserted")
local id = assert(db:last_insert_rowid())
```

#### `db:changes()`

Returns the number of rows changed by the most recently completed `INSERT`,
`UPDATE`, or `DELETE` on this connection. Auxiliary changes from triggers,
foreign-key actions, or `REPLACE` conflict resolution are not included in this
latest-statement counter.

```lua
assert(db:exec(
    "UPDATE messages SET body = ? WHERE id IN (?, ?)",
    { "archived", 1, 2 }
))
print(assert(db:changes())) -- 0, 1, or 2 depending on existing rows
```

#### `db:total_changes()`

Returns the cumulative number of changed rows since this connection opened.
The total includes changes made by triggers and foreign-key actions, but not
internal `REPLACE` deletions. Each new connection starts from zero.

```lua
local before = assert(db:total_changes())
assert(db:exec("INSERT INTO messages(body) VALUES ('one'), ('two')"))
local delta = assert(db:total_changes()) - before
assert(delta == 2)
```

Use all three counters together after an insertion:

```lua
assert(db:exec("INSERT INTO messages(body) VALUES(?)", { "new" }))
local id = assert(db:last_insert_rowid())
local statement_rows = assert(db:changes())
local connection_rows = assert(db:total_changes())
print(id, statement_rows, connection_rows)
```

These values belong only to the current `db` handle: another connection,
including one in a different worker, has independent counters. After
`db:close()`, all three methods return
`(nil, "sqlite: connection closed")`.

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
A failed `COMMIT` also returns `(nil, err)` after a best-effort rollback. Any
values returned by the callback are discarded in that case.

After a successful `BEGIN`, Babet explicitly owns the transaction until
`COMMIT` or `ROLLBACK`. The Lua stack space required to call the callback is
reserved before `BEGIN`; an internal C++ exception also triggers an immediate
rollback attempt. Callback diagnostics are formatted only after that attempt,
so an unusual Lua error object cannot leave the connection in an intermediate
state.

If the normal rollback fails, the returned message contains both the original
failure and the rollback failure, followed by one final emergency rollback
attempt. After an error, `db:in_transaction()` can be used to verify explicitly
that the connection has returned to autocommit mode before continuing.

#### Example: failure during commit

A deferred constraint may be checked only by `COMMIT`:

```lua
local db = assert(babet.sqlite.open(
    ":memory:", { foreign_keys = true }))
assert(db:exec([[
    CREATE TABLE parent(id INTEGER PRIMARY KEY);
    CREATE TABLE child(
        id INTEGER PRIMARY KEY,
        parent_id INTEGER NOT NULL,
        FOREIGN KEY(parent_id) REFERENCES parent(id)
            DEFERRABLE INITIALLY DEFERRED
    )
]]))

local ok, err = db:transaction(function(tx)
    assert(tx:exec(
        "INSERT INTO child(id, parent_id) VALUES(?, ?)",
        { 1, 999 }))
    return "this result will not be forwarded"
end)

assert(ok == nil)
assert(type(err) == "string")
assert(db:in_transaction() == false)
```

The `INSERT` is rolled back and the connection remains reusable when rollback
succeeds.

#### Example: reusing a prepared statement after rollback

```lua
local insert = assert(db:prepare(
    "INSERT INTO log(id, value) VALUES(?, ?)"))

local ok, err = db:transaction(function()
    assert(insert:exec({ 1, "rolled back" }))
    error("intentional failure")
end)

assert(ok == nil and type(err) == "string")
assert(insert:exec({ 2, "kept" }))
insert:finalize()
```

Rollback resets SQLite's transactional state and the prepared statement can be
reused normally afterwards.

Intentional limitations:

- nested `db:transaction()` helpers are rejected;
- the helper is rejected while a manual SQL transaction is already active;
- `db:close()` is rejected during the callback;
- the callback must not issue its own `BEGIN`, `COMMIT`, or `ROLLBACK`.

Use `db:savepoint()` for managed nested scopes. Raw SQL savepoints remain
available when explicit SQL identifiers or manual control are required.

<!-- pdf-page-break -->

<a id="sqlite-savepoints"></a>
### Nested savepoints

Signature:

```lua
true, ...callback_results = db:savepoint(callback)
-- or
nil, err = db:savepoint(callback)
```

The callback receives the same open connection as its only argument. Babet
generates the SQL savepoint identifier internally; the API accepts no name and
therefore cannot inject caller-controlled text into `SAVEPOINT`, `ROLLBACK TO`,
or `RELEASE`.

On a normal callback return, Babet executes `RELEASE` and returns `true`
followed by every callback value. Explicit `nil` and `false` values are normal
results and do not request rollback. On a Lua error, Babet executes
`ROLLBACK TO` and then `RELEASE`, catches the error, and returns
`(nil, "sqlite: savepoint callback failed: ...")`.

#### Example: standalone savepoint

Outside a transaction, the outermost savepoint starts a transaction. Releasing
it commits the isolated work and restores autocommit:

```lua
local ok, id = db:savepoint(function(tx)
    assert(tx:exec(
        "INSERT INTO jobs(name) VALUES(?)",
        { "index" }))
    return assert(tx:last_insert_rowid())
end)

assert(ok, id)
assert(db:in_transaction() == false)
```

#### Example: rollback on callback error

Use `assert` on SQLite operations whose failure must cancel the scope:

```lua
local ok, err = db:savepoint(function(tx)
    assert(tx:exec(
        "INSERT INTO unique_names(name) VALUES(?)",
        { "alice" }))
    assert(tx:exec(
        "INSERT INTO unique_names(name) VALUES(?)",
        { "alice" }))
end)

assert(ok == nil)
assert(type(err) == "string")
-- Neither INSERT remains, and the connection is reusable.
```

<!-- pdf-page-break -->

#### Example: recover from a failed inner scope

Savepoint helpers may be nested. A failed inner scope rolls back only to its
own marker; the outer callback can inspect the error and continue:

```lua
local ok, inner_err = db:savepoint(function(tx)
    assert(tx:exec("INSERT INTO audit(message) VALUES('before')"))

    local inner_ok, err = tx:savepoint(function(inner)
        assert(inner:exec("INSERT INTO audit(message) VALUES('optional')"))
        error("discard optional work")
    end)
    assert(inner_ok == nil)

    assert(tx:exec("INSERT INTO audit(message) VALUES('after')"))
    return err
end)

assert(ok, inner_err)
-- "before" and "after" remain; "optional" was rolled back.
```

A later error in the outer callback also rolls back any inner savepoint that
was already released. `RELEASE` merges inner work into the surrounding scope;
it never makes that work independent of the outer transaction.

#### Example: inside a managed transaction

`db:savepoint()` is allowed inside `db:transaction()` even though a second
transaction helper is not:

```lua
local ok, err = db:transaction(function(tx)
    assert(tx:exec("INSERT INTO audit(message) VALUES('required')"))

    local optional_ok = tx:savepoint(function(inner)
        assert(inner:exec("INSERT INTO audit(message) VALUES('optional')"))
    end)
    if not optional_ok then
        assert(tx:exec("INSERT INTO audit(message) VALUES('optional failed')"))
    end

    assert(tx:in_transaction() == true)
end, "immediate")

assert(ok, err)
```

Releasing the inner savepoint does **not** commit the managed transaction. If
the outer callback subsequently fails, `db:transaction()` rolls back both the
required write and every released inner write.

#### Example: inside a manual transaction

```lua
assert(db:exec("BEGIN"))

local ok, err = db:savepoint(function(tx)
    assert(tx:exec("UPDATE accounts SET balance = balance - 10 WHERE id = 1"))
end)
assert(ok, err)
assert(db:in_transaction() == true)

assert(db:exec("ROLLBACK")) -- also undoes the released savepoint work
```

<!-- pdf-page-break -->

#### Example: failure while releasing the outermost savepoint

A deferred constraint may be checked only when the outermost `RELEASE` tries
to commit. Callback results are discarded, Babet rolls back to the savepoint,
removes it, and returns the release error:

```lua
local db = assert(babet.sqlite.open(
    ":memory:", { foreign_keys = true }))
assert(db:exec([[
    CREATE TABLE parent(id INTEGER PRIMARY KEY);
    CREATE TABLE child(
        id INTEGER PRIMARY KEY,
        parent_id INTEGER REFERENCES parent(id)
            DEFERRABLE INITIALLY DEFERRED
    )
]]))

local ok, err, leaked = db:savepoint(function(tx)
    assert(tx:exec("INSERT INTO child VALUES(1, 999)"))
    return "must not be forwarded"
end)

assert(ok == nil and type(err) == "string")
assert(leaked == nil)
assert(db:in_transaction() == false)
```

Inside an existing transaction, releasing an inner savepoint does not perform
the outer commit, so the deferred error remains the responsibility of that
transaction's later `COMMIT`.

The helper tracks nesting depth per connection and is available inside
workers. `db:close()` is rejected while any savepoint callback is active. The
Lua stack is reserved before opening the savepoint, and an allocation-free C++
guard attempts emergency `ROLLBACK TO` plus `RELEASE` if an internal exception
occurs.

Do not mix manual transaction or savepoint-control statements inside the
callback. In particular, a full `ROLLBACK` or `COMMIT` destroys the managed
savepoint. Babet detects the restored autocommit state, discards callback
results, skips redundant cleanup statements, and returns one stable error
without exposing the generated identifier. A `ROLLBACK` leaves the connection
reusable with the callback writes undone; a `COMMIT` may already have persisted
them before Babet can diagnose the contract violation. Use nested
`db:savepoint()` calls for recoverable inner scopes.

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
numeric indices, non-integer numeric indices, unsupported key types, and
unsupported value types raise a Lua error. Explicit `nil` as the params
argument is the same as omitting it; it is not a bind value.

Named values are read from raw table entries. A metatable `__index` result does
not count as a supplied value, and an `__index` error is never executed during
binding. Numbered `?NNN` placeholders are explicitly rejected; use anonymous
`?` placeholders in their natural order instead.

Accepted bind values:

| Lua type | SQLite value |
| --- | --- |
| boolean | INTEGER `0` or `1` |
| integer | INTEGER, including the full signed 64-bit range |
| finite non-integer number | REAL |
| string | TEXT, including embedded NUL bytes |
| `babet.sqlite.blob(data)` | binary-safe BLOB |
| `babet.sqlite.NULL` | SQL `NULL` |

NaN and positive or negative infinity are rejected instead of being handed to
SQLite with platform-dependent results.

<a id="sqlite-nulls"></a>
### Explicit NULL values

Lua cannot store `nil` inside a parameter table: assigning `nil` removes the
key. Use the exact singleton `babet.sqlite.NULL` when a placeholder must be
bound to SQL `NULL`.

Named optional value:

```lua
local NULL = babet.sqlite.NULL

assert(db:exec([[
    INSERT INTO users(name, nickname)
    VALUES(:name, :nickname)
]], {
    name = "Ada",
    nickname = NULL,
}))
```

Positional `NULL` in the middle of a parameter list:

```lua
assert(db:exec(
    "INSERT INTO events(id, payload, created_at) VALUES(?, ?, ?)",
    { 17, babet.sqlite.NULL, 1700000000 }
))
```

The sentinel works the same way with reusable statements and may alternate
between ordinary values and `NULL` on successive runs:

```lua
local update = assert(db:prepare(
    "UPDATE users SET nickname = ? WHERE name = ?"
))

assert(update:exec({ "Countess", "Ada" }))
assert(update:exec({ babet.sqlite.NULL, "Ada" }))
assert(update:finalize())
```

Binding and reading are deliberately asymmetric:

| Lua bind value | SQLite storage | Lua row value |
| --- | --- | --- |
| `true` | INTEGER `1` | integer `1` |
| `false` | INTEGER `0` | integer `0` |
| `babet.sqlite.NULL` | `NULL` | `nil` / absent key |

SQLite has no boolean storage class, so integers read back as integers; Babet
does not infer booleans from `0` or `1`. A `NULL` result produces no key in the
row table, which means both `row.column == nil` and absence from `pairs(row)`.

`babet.sqlite.NULL` is accepted only as a SQLite bind value. Other
lightuserdata values are rejected. JSON encoding and values transferred to
workers or channels also reject this sentinel with an explicit diagnostic,
preventing an opaque pointer-shaped value from silently crossing subsystem
boundaries.

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

`db:close()` is idempotent. After closing, new connection operations such as
`exec`, `query`, `prepare`, `transaction`, `savepoint`, and `in_transaction` return
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

Statements deliberately hold no Lua reference and no raw `Db*` pointer to
their parent userdata. SQLite itself keeps the native zombie connection alive,
which avoids a dangling C++ owner pointer and lets the Lua `db` userdata be
collected independently.

<a id="sqlite-errors"></a>
## Error contract

Errors fall into two groups:

- operational failures (open, preparation, step, transaction, closed handle)
  generally return `(nil, "sqlite: <description>")`;
- wrong types, invalid arity, and invalid parameter tables raise a Lua error.

All public functions validate their exact arity. Parameter-contract errors
also include numbered `?NNN`, non-finite REAL values, foreign lightuserdata,
and option/parameter tables with unsupported keys.

`opts.readonly`, `opts.foreign_keys`, and `opts.wal` require strict Lua
booleans. Combining `readonly = true` with `wal = true` raises a contract
error. Opening a missing database read-only, writing through a read-only
connection, or violating a foreign key are operational failures that return
`(nil, err)`.

Errors raised while calling a query iterator (`db:query` or
`prepared:query`) are Lua errors because the iterator protocol cannot also
return a separate `(nil, err)` result.

When no params table is provided, placeholders are detected before execution.
Babet never lets SQLite silently bind them as `NULL`.

`db:transaction()` and `db:savepoint()` are controlled exceptions: they catch
callback Lua errors, roll back their owned scope, and convert the error to
`(nil, err)`.

<a id="sqlite-examples"></a>
## Complete examples

### Prepared inserts, optional NULL, and BLOB values

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
}))

assert(db:exec([[
    CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        digest BLOB NOT NULL,
        media_type TEXT
    )
]]))

local insert = assert(db:prepare([[
    INSERT INTO files(path, digest, media_type)
    VALUES(?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
        digest = excluded.digest,
        media_type = excluded.media_type
]]))

for _, file in ipairs(files) do
    assert(insert:exec({
        file.path,
        babet.sqlite.blob(file.digest),
        file.media_type or babet.sqlite.NULL,
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

The following are intentionally not implemented:

- URI mode and other advanced `sqlite3_open_v2` flags;
- progress-handler and interrupt APIs;
- the `sqlite3_blob_open` streaming BLOB API;
- the `sqlite3_backup_init` backup API.

Raw SQL savepoints and `VACUUM INTO` remain available. FTS5 and R-Tree are not
enabled in the current embedded build.
