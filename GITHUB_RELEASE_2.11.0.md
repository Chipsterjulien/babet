# Babet 2.11.0 — bounded in-memory archive reads

Babet 2.11.0 adds `babet.archive.read()` for reading one regular ZIP or TAR
entry into a binary Lua string without writing to disk. Existing archive APIs
and their extraction rules remain compatible.

## Highlights

- Read by exact raw entry name:

  ```lua
  local manifest, err = babet.archive.read(
      "package.tar.zst",
      "manifest.json",
      { max_size = 1024 * 1024 }
  )
  assert(manifest, err)
  ```

- Or select the one-based index exposed by `archive.list()`. Name lookup
  refuses duplicates as ambiguous; an explicit index can deliberately select
  a particular occurrence.
- Returned strings are binary-safe and may be empty or contain NUL and
  non-UTF-8 bytes.
- The dedicated `max_size` option defaults to 8 MiB and has a 256 MiB hard
  ceiling. It is enforced both against announced metadata and against bytes
  actually produced by decompression.
- ZIP, plain TAR, gzip TAR, xz TAR, bzip2 TAR, and zstd TAR behave identically,
  including in worker Lua states.
- Only regular entries are readable. Directories, links, sparse TAR files,
  special types, encryption, and unsupported ZIP methods remain refused.

## Raw names and safety

`archive.read()` never turns an entry name into a filesystem path. It can
therefore read a regular entry whose raw name is unsafe for extraction, while
preserving every byte and performing no silent sanitisation. Use
`archive.list()` to inspect `valid_utf8`, `safe_path`, `duplicate`, and
`conflict` before reusing a name elsewhere.

Extraction policy is unchanged: `archive.extract()` and
`archive.extractFile()` still reject unsafe selected paths and remain confined
to their destination.

## Integrity and limits

The six existing whole-archive limits still apply to `read()`. For ZIP, the
selected payload is completely inflated and CRC-checked. For TAR, Babet keeps
the established two-pass model: the first pass consumes the archive, and the
second compares every header and consumes every member while forwarding only
the selected file into bounded memory. gzip and zstd stream validation remains
active.

`archive.read()` is deliberately not a replacement for `archive.test()`:
`test()` continues to validate every ZIP payload and enforce a strict aggregate
safety verdict across the whole archive.

## Compatibility notes

Scripts using documented Babet 2.10.0 behavior remain source-compatible. The
new `max_size` option belongs only to `archive.read()` and is rejected by other
archive functions. The selector is strict: it must be a raw string without NUL
or a true Lua integer.

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
