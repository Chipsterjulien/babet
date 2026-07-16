# Babet 2.6.0

Babet 2.6.0 completes the multi-format archive and bounded-search roadmap while
keeping the audited ZIP and existing API contracts from 2.5.0.

## Highlights

- Secure creation, inspection, complete extraction, and single-file extraction
  for plain TAR and TAR compressed with gzip, xz, bzip2, or zstd.
- Content-based archive detection, deterministic output, pinned source
  descriptors, two-pass TAR verification, anti-bomb limits, confined
  destinations, and atomic publication.
- Statically built and SHA-256-verified libarchive 3.8.8, zlib 1.3.2,
  XZ Utils/liblzma 5.8.3, bzip2 1.0.8, and Zstandard 1.5.7.
- New bounded `glob`, `iglob`, `path_glob`, and `path_iglob` filters for
  `babet.find()`.
- Migration of `name`, `iname`, and `path` from `std::regex` to statically
  linked RE2 2025-11-05 and Abseil 20250814.2, with 4096-byte patterns and a
  1 MiB compilation budget per expression.
- Shared strict Lua validators for arity, strings, numbers, integers, booleans,
  optional `nil`, and embedded-NUL-safe native strings.
- Synchronized French and English documentation, regenerated PDF manuals, and
  expanded deterministic regression fixtures.

## Compatibility notes

- ZIP operations still use miniz and retain their 2.5.0 behavior.
- `name` and `iname` remain full matches; `path` remains a partial search.
- RE2 deliberately rejects backreferences and look-around assertions. Use the
  glob fields when wildcard matching is sufficient.
- Standalone `.gz`, `.xz`, `.bz2`, and `.zst` streams are not treated as
  archives; only compressed TAR streams are supported by `babet.archive`.
- Archive creation still takes one source directory. Explicit unrelated file
  lists and exclusion rules remain outside this release until their root,
  collision, and symlink semantics are specified.

## Validation

The exact release tree must pass:

```sh
./run_tests.sh --release
```

This runs ASan/UBSan, a clean normal rebuild with the complete folder and
embedded suites, and network smoke tests against the final normal binary.
