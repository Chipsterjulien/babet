# Babet 2.8.0

Babet 2.8.0 completes secure archive inspection and advanced extraction for
ZIP and plain/gzip/xz/bzip2/zstd TAR files. The new APIs remain available in
both the main Lua state and workers, reuse the existing bounded archive policy,
and do not weaken historical extraction or destination protections.

## Inspect archives without extraction

`babet.archive.list(archive [, opts])` now exposes a bounded, deterministic
inventory while preserving raw entry order and binary Lua names. It reports
format/compression information, reliable metadata, invalid UTF-8 status,
unsafe-path reasons, exact duplicates, and normalized output conflicts without
creating files or directories.

The inspection contract adds shared limits for raw path length and cumulative
name bytes. ZIP listing remains metadata-oriented and does not inflate every
payload; TAR listing streams through the archive to reach and validate every
header.

## Verify integrity and safety completely

The new `babet.archive.test(archive [, opts])` reads the complete archive and
returns a compact summary only when both technical integrity and Babet's safety
rules pass.

It verifies ZIP/ZIP64 structures, local headers, data descriptors, compression,
CRC, sizes, bounds, and overlap. TAR readers consume complete raw or compressed
streams and detect invalid headers, truncation, corruption, and foreign trailing
data according to the available backend guarantees.

Technically valid but unsafe archives are rejected: traversal or absolute
paths, duplicates, file/directory collisions, links, sparse files, special
objects, encrypted ZIP entries, and unsupported compression methods do not
produce a successful result.

## Extract only what is needed

`babet.archive.extract()` now accepts the same bounded safe-glob `include` and
`exclude` arrays as archive creation. Matching is anchored, byte-oriented,
case-sensitive, and shares the existing `*`, `**`, `?`, and backslash-escape
rules. Exclusion always wins and can prune an entire subtree.

Only selected entries participate in output collisions and type checks, while
whole-archive anti-bomb and metadata limits remain enforced. A selection that
matches nothing creates no destination. Required implicit parent directories
are created only for retained entries.

## Preview extraction without changing the disk

With `dry_run = true`, `archive.extract()` performs the same archive scan,
filters, limits, path normalization, selected payload verification, overwrite
policy, and read-only destination traversal without mkdir, temporary files,
writes, chmod, rename, unlink, or publication.

The result reports `would_create`, `would_overwrite`, `would_skip`, and
`would_create_destination`. This is an accurate preview of the observed state,
not a promise that the filesystem cannot change before a later real extraction.

## Compatibility and deliberate scope

- Historical unfiltered extraction calls remain valid.
- `archive.extractFile()` is unchanged.
- `dry_run`, `include`, and `exclude` are accepted only by full extraction.
- ZIP, TAR, TAR.GZ/TGZ, TAR.XZ/TXZ, TAR.BZ2/TBZ/TBZ2, and TAR.ZST/TZST are
  detected by content for reading.
- The optional in-memory `archive.read()` proposal was reviewed and deferred;
  it is not necessary for the completed 2.8.0 archive lifecycle.
- English and French README files, module documentation, changelogs, examples,
  release procedures, and PDF manuals were audited and synchronized.

## Validation

The validated release candidate passed:

- 3067 PASS / 0 FAIL in folder mode;
- 3054 PASS / 0 FAIL in embedded mode;
- 3054 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes under ASan + UBSan;
- 9/9 runtime modes again with the final normal build.

The complete release gate, including the local TLS and network smoke tests, is:

```sh
./run_tests.sh --release
```
