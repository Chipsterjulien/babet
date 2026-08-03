# Babet 2.12.0 — SQLite connection options and counters

Babet 2.12.0 extends the audited `babet.sqlite` API with read-only opening,
per-connection foreign-key enforcement, and three native 64-bit counters. The
default read/write behaviour and every documented 2.11.0 API remain compatible.

## Open with an explicit policy

Enable WAL, bounded lock waiting, and foreign keys on a writer:

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
    foreign_keys = true,
}))
```

Open an existing database without creating or writing it:

```lua
local db = assert(babet.sqlite.open("state.db", {
    readonly = true,
    busy_timeout = 2000,
    foreign_keys = true,
}))
```

`readonly = true` uses native `SQLITE_OPEN_READONLY`. A missing path returns
`(nil, err)` and leaves no file behind; writes return a SQLite error. Read-only
opening combines with `busy_timeout` and `foreign_keys`, but deliberately
rejects `wal = true` before a native handle is acquired. This rejects a request
to switch journal mode; it does not prevent `readonly = true` from opening a
database that already uses WAL when its companion files are usable.

`foreign_keys = true` enables referential-integrity checks before the first
statement. It is a connection-local policy. The explicit false default
preserves the historical Babet behaviour.

## Read connection counters

```lua
assert(db:exec("INSERT INTO jobs(name) VALUES(?)", { "index" }))

local id = assert(db:last_insert_rowid())
local changed = assert(db:changes())
local total = assert(db:total_changes())

print(id, changed, total)
```

- `last_insert_rowid()` reports the latest successful ROWID insertion on the
  current connection;
- `changes()` reports rows changed by the latest completed DML statement;
- `total_changes()` reports the cumulative count since the connection opened.

After a one-row `INSERT OR IGNORE`, check `changes() == 1` before trusting
`last_insert_rowid()`: an ignored insert succeeds with zero changes and leaves
the previous ROWID in place.

All three use SQLite's signed 64-bit APIs, return Lua integers, enforce exact
arity, and return `(nil, "sqlite: connection closed")` after `close()`.

## Strictness and workers

The new options require actual Lua booleans. Unknown options, non-string keys,
and values supplied only by `__index` remain rejected. The five additions are
registered identically in worker Lua states; each worker connection owns its
own policy and counters.

## Validation

The new contract has 36 focused assertions covering option validation,
read-only reads/writes/non-creation, enabled and disabled foreign keys, counter
semantics including ignored inserts, deferred foreign-key failure at `COMMIT`,
closed handles, arity, and workers. Its pre-implementation probe was 0 PASS / 5
FAIL and the implemented surface is 5 PASS / 0 FAIL.

The final audit also extends the archive exception boundary to all six public
archive functions and adds an explicit completion check to the TAR in-memory
`read()` sink.

Before publication, run:

```bash
./run_tests.sh --release
```

The final journal must report zero failures, no sanitizer diagnostics, 9/9
execution modes in both builds, and a fully green network smoke suite.
