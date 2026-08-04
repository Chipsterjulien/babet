# Babet 2.13.0 — Nested SQLite savepoints

Babet 2.13.0 adds a managed, nestable savepoint helper to the audited
`babet.sqlite` API.

```lua
local ok, result = db:savepoint(function(tx)
    assert(tx:exec(
        "INSERT INTO jobs(name) VALUES(?)",
        { "index" }))
    return tx:last_insert_rowid()
end)
```

## Managed savepoint scopes

The new method is:

```lua
true, ...callback_results = db:savepoint(callback)
-- or
nil, err = db:savepoint(callback)
```

- Babet generates every savepoint identifier internally;
- normal callback returns execute `RELEASE` and preserve all returned values,
  including explicit `nil` and `false`;
- callback Lua errors execute `ROLLBACK TO` followed by `RELEASE` and become
  `(nil, err)`;
- the helper works outside a transaction, inside `db:transaction()`, inside a
  manual SQL transaction, and recursively inside another `db:savepoint()`;
- a failed inner scope rolls back only its own work, so the surrounding
  callback can recover and continue;
- a later outer failure still rolls back inner work that was already released;
- releasing an inner savepoint never commits the outer transaction.

## Release-failure recovery

An outermost `RELEASE` can fail when SQLite checks a deferred constraint. In
that case Babet:

- discards every callback result;
- attempts `ROLLBACK TO` and `RELEASE` cleanup;
- returns the SQLite release error;
- restores a reusable connection when cleanup succeeds.

Inside an existing transaction, the inner `RELEASE` does not perform the outer
commit. Deferred checks therefore remain the responsibility of the later
`COMMIT`.

## Native hardening

- active savepoint depth and generated-name sequence are tracked per
  connection with no global state;
- `db:close()` is rejected while any savepoint callback is active;
- Lua stack capacity is reserved before `SAVEPOINT`;
- callbacks run through `lua_pcall`;
- an allocation-free RAII guard performs a best-effort emergency
  `ROLLBACK TO` plus `RELEASE` if an internal C++ exception occurs;
- a callback that explicitly ends the transaction is detected before cleanup,
  producing one stable diagnostic without an address or repeated SQLite cause;
- generated names use a checked connection-local `babet_sp_<sequence>` form;
- the method remains protected by the common SQLite C++ exception boundary;
- the same API is available inside workers.

## Tests and documentation

The release adds 37 assertions covering:

- normal results and explicit `nil` / `false` values;
- callback rollback and connection reuse;
- three nested savepoint levels;
- recoverable inner failure and fatal outer failure;
- managed and manual outer transactions;
- deferred failures at outermost `RELEASE` and outer `COMMIT`;
- explicit callback `ROLLBACK` on both normal-return and Lua-error paths,
  clean diagnostics, and connection reuse;
- strict arity, callback type, closed handles, and close refusal;
- worker availability.

The French and English Markdown documentation and PDF manuals include separate
standalone, rollback, nested, transaction, manual-transaction, and deferred-
constraint examples.

Existing `db:transaction()`, direct SQL, prepared statements, opening options,
connection counters, and all non-SQLite APIs remain compatible.
