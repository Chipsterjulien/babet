# Babet 2.10.0 — SQLite contracts and explicit NULL

Babet 2.10.0 completes a source-to-test audit of `babet.sqlite`. Its only new
public API is `babet.sqlite.NULL`; all other changes harden or document existing
behavior.

## Highlights

- Bind SQL `NULL` explicitly from named, positional, direct, or prepared
  parameter tables:

  ```lua
  assert(db:exec(
      "INSERT INTO users(name, nickname) VALUES(:name, :nickname)",
      { name = "Ada", nickname = babet.sqlite.NULL }
  ))
  ```

- Parameter tables are now enforced as exact data objects: no missing or extra
  values, sparse/non-integer indices, unsupported key types, `__index` lookup,
  numbered `?NNN`, foreign lightuserdata, NaN, or infinities.
- Constraint diagnostics remain correct even after the parent connection
  userdata has been collected while a statement keeps SQLite's native zombie
  connection alive.
- Every SQLite Lua entry point is protected against C++ exceptions, and every
  native handle becomes finalizable before acquisition or transfer.
- Open options and public arities are strict and documented.
- JSON, workers, and channels reject the SQLite-only NULL sentinel explicitly;
  rejected channel sends remain atomic.

## Reading NULL values

Binding and reading are deliberately asymmetric. `babet.sqlite.NULL` binds SQL
`NULL`, but a NULL result still appears as `nil` and as an absent key in the row
table. Booleans bind as SQLite INTEGER `0`/`1` and read back as integers.

## Compatibility notes

Scripts using only documented 2.9.2 behavior remain source-compatible. Code
that relied on ignored `open` options, excess arguments, parameter values from
`__index`, numbered `?NNN`, unsupported table keys, or non-finite REAL values
now receives an explicit Lua error. Replace `?NNN` with anonymous `?`
placeholders in natural order.

`babet.sqlite.NULL` is a bind-only sentinel. Do not put it in JSON, worker
arguments/messages, or channels; use a domain value such as a tagged table when
NULL must cross one of those boundaries.

## Validation

From the release tree, run:

```bash
./run_tests.sh --release
```

The command performs strict release builds, ASan/UBSan runs, folder and
embedded execution modes, hermetic preflights, and the local network smoke
suite. The complete result must contain zero failures and no sanitizer report
before publication.

See `CHANGELOG.md`, `CHANGELOG.fr.md`, and the English/French manuals for the
complete contracts and examples.
