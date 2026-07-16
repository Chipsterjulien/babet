# Babet 2.7.0

Babet 2.7.0 adds secure standalone compression streams and expands archive
creation with explicit multi-root sources plus bounded include/exclude filters.
It preserves the audited ZIP and TAR contracts introduced in the 2.5 and 2.6
series.

## Standalone compression

The new `babet.compression` module provides:

- `compress(source, destination, format [, opts])`;
- `decompress(source, destination [, opts])`;
- gzip, xz, bzip2, and zstd streams;
- automatic decompression-format detection from stream bytes;
- concatenated-member/frame support;
- integrity and truncation checks, including checksummed Babet-generated zstd
  frames;
- bounded 64 KiB streaming buffers;
- a 1 GiB default decompressed-output limit and a 64 GiB hard ceiling;
- strict format-specific compression levels;
- pinned regular-file sources, symlink refusal, same-inode protection,
  same-directory staging, and atomic publication;
- availability in worker Lua states.

Default compression levels are gzip 6, xz 6, bzip2 9, and zstd 3. Explicit
accepted ranges are gzip 0-9, xz 0-9, bzip2 1-9, and zstd 1-22.

## Archive creation

`babet.archive.create()` now accepts either its historical source-directory
string or a non-empty dense array of explicit regular files and directories.
Explicit sources may come from unrelated locations and are rooted at their
final basename without exposing host path prefixes.

Creation also accepts bounded `include` and `exclude` safe-glob arrays matched
against final archive paths. Exclusions always win, excluded directories are
pruned before opening, required parent directories are retained for selected
deep files, and selecting nothing produces a valid empty archive.

The filter engine is non-recursive and bounded by per-pattern, cumulative text,
evaluation-count, and matching-work limits. ZIP, plain TAR, and gzip/xz/bzip2/
zstd TAR backends share the same selection contract, deterministic ordering,
worker support, source mutation checks, and atomic publication.

## Compatibility and documentation

- The historical single-directory `archive.create()` contract remains valid.
- Existing archive listing and extraction contracts are unchanged.
- Unknown options and malformed source/filter tables are rejected strictly.
- English and French documentation, examples, security notes, changelogs, and
  PDF manuals have been audited and synchronized with the implementation.

## Validation

The final release candidate passed:

- 2844 PASS / 0 FAIL in folder mode;
- 2831 PASS / 0 FAIL in embedded mode;
- 2831 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes under ASan + UBSan;
- 9/9 runtime modes again with the final normal build.

The release gate additionally runs the local TLS and network smoke tests through
`./run_tests.sh --release`.
