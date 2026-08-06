# Babet 2.19.0 — modular test harness and coherent SQLite backups

Babet 2.19.0 first turns the historical Lua regression script into a modular,
maintainable harness, then adds a bounded and atomically published SQLite backup
API based on `sqlite3_backup`.

## Modular regression harness

`examples/main.lua` is now a 15-line orchestrator instead of a 21,567-line
chunk. The existing coverage is distributed across 43 thematic suites for
runtime utilities, files, processes, networking, SQLite, workers, compression,
archives, packaging, and security regressions.

The modularization preserves the historical test order and diagnostics in all
three execution forms:

- folder mode;
- embedded executable mode;
- embedded executable launched through `PATH`.

A dedicated preflight checks that every suite remains reachable, enforces
anti-monolith limits, and rejects ambiguous parenthesized Lua statements that
could attach to the previous line.

## SQLite backup

An open SQLite connection now provides:

```lua
local ok, err = db:backup("state-backup.db", {
    timeout = 10,
    pages_per_step = 64,
    sleep = 0.005,
})
assert(ok, err)
```

`db:backup(path, opts?)` uses SQLite's online backup API rather than copying the
database file. It supports in-memory and file-backed sources, WAL databases,
and committed writes made by another connection while the copy is running.

Options are strict:

- `timeout`: one global monotonic deadline, from `0` to `86400` seconds;
- `pages_per_step`: pages copied per SQLite step, from `1` to `INT_MAX`;
- `sleep`: bounded pause between steps or retries, from `0` to `60` seconds;
- `overwrite`: explicitly replace a closed regular destination, default
  `false`.

`timeout = 0` performs exactly one non-blocking backup step. `SQLITE_BUSY` and
`SQLITE_LOCKED` are retried only while the original deadline remains. The
source connection's configured busy timeout is disabled during the loop and
restored afterwards so it cannot silently extend the global deadline.

## Atomic destination lifecycle

Babet writes the backup into a private same-directory temporary file, always
calls `sqlite3_backup_finish()`, closes the private SQLite connection,
synchronizes the file, and only then publishes it atomically with private
`0600` permissions.

Failures and timeouts:

- never publish a partial database;
- preserve an existing destination;
- remove the temporary database and any temporary `-journal`, `-wal`, or
  `-shm` files;
- restore the source busy timeout;
- close every temporary SQLite handle.

Existing destinations are refused unless `overwrite = true`. Symbolic links,
symlinked parent components, directories, FIFOs, other special files, hard
links to the source database, and destinations with existing SQLite sidecars
are rejected.

## Validation scope

The new regression coverage includes empty databases, data and schema, indexes,
triggers, reopening, restoration, large databases, zero and expired deadlines,
`SQLITE_BUSY`, source write transactions, busy-timeout restoration, WAL with a
concurrent committed writer, invalid and non-writable destinations, atomic
replacement, and cleanup after every failure path.

French and English documentation and both PDF manuals are updated with the
exact API contract, timeout behavior, WAL semantics, destination policy,
errors, limits, and multiple examples.

The release-validation pipeline now assigns compilation failures a dedicated
exit status and stops immediately instead of attempting the same broken source
in the normal build. Sanitizer-only test failures still allow the normal build
to run so that the final binary is restored and the diagnostic remains useful.

Babet remains focused exclusively on Linux, C++23, and embedded Lua 5.5.1.
