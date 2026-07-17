# Archive — secure ZIP and TAR operations with gzip, xz, bzip2, or zstd

## Scope

The `babet.archive` submodule creates, inspects, and extracts **ZIP**, **TAR**,
and **gzip-, xz-, bzip2-, or zstd-compressed TAR** archives without calling an external command:

```lua
babet.archive.create(source_or_sources, archive [, opts])
babet.archive.list(archive [, opts])
babet.archive.test(archive [, opts])
babet.archive.extract(archive, destination [, opts])
babet.archive.extractFile(archive, entry, destination [, opts])
```

ZIP creation, inspection, and extraction continue to use miniz. TAR creation,
inspection, and extraction use the statically linked libarchive backend;
gzip filtering is provided by the statically linked zlib backend, xz filtering
uses the statically linked XZ Utils/liblzma backend, bzip2 filtering uses the
statically linked bzip2/libbz2 backend, and zstd filtering uses the statically
linked Zstandard/libzstd backend. Readers detect both the container
and compression from the contents. For `create()`, `.tar` selects plain TAR,
`.tar.gz` and `.tgz` select gzip-compressed TAR, `.tar.xz` or `.txz` select
xz-compressed TAR, `.tar.bz2`, `.tbz2`, or `.tbz` select bzip2-compressed
TAR, and `.tar.zst`, `.tar.zstd`, or `.tzst` select zstd-compressed TAR.
`opts.format` can override the extension. Standalone compressed streams are
handled separately by [`babet.compression`](compression.md).

All five functions use the usual result contract:

```lua
local result, err = babet.archive.list("backup.zip")
if not result then
    io.stderr:write(err, "\n")
end
```

They return `(result, nil)` on success and `(nil, message)` on failure. Wrong
arity, a destination that is not a string, or a source that is neither a string
nor a table raises a Lua error. Invalid source lists and option tables return
`(nil, message)`.

## Contents

- [`babet.archive.create`](#babetarchivecreate)
- [Inspection/extraction options and anti-bomb limits](#inspectionextraction-options-and-anti-bomb-limits)
- [`babet.archive.list`](#babetarchivelist)
- [`babet.archive.test`](#babetarchivetest)
- [`babet.archive.extract`](#babetarchiveextract)
- [`babet.archive.extractFile`](#babetarchiveextractfile)
- [Path rules](#path-rules)
- [Destination protection](#destination-protection)
- [Atomic publication and cleanup](#atomic-publication-and-cleanup)
- [Permissions](#permissions)
- [Supported entry types](#supported-entry-types)
- [Errors and known limitations](#errors-and-known-limitations)

<a id="babetarchivecreate"></a>

## `babet.archive.create`

```lua
local result, err = babet.archive.create(
    source_or_sources,
    archive
    [, opts]
)
```

The first argument supports two distinct contracts:

- a **string** preserves the historical behavior: it must name an existing
  directory, and Babet archives its contents without including the source
  directory name itself;
- a **non-empty dense array** (`1..n`, no holes or extra keys) explicitly
  selects regular files and/or directories, possibly from unrelated locations.
  Each source is rooted at its final component: `/tmp/report.txt` becomes
  `report.txt`, while `/opt/project/docs` becomes `docs/` with all descendants.
  Absolute sources are accepted, but host path prefixes are never exposed in
  the archive.

In list mode, the final component must be stable: `.` and the filesystem root
are rejected, as is every `..` component. Two sources with the same final
component collide and fail, even when their descendants would differ. Repeating
the same source therefore fails as well. Input list order does not affect the
result: entries are always sorted by archive name.

In both modes traversal is descriptor-based and follows no symlink. A symlink
in a top-level source path always fails. Within a traversed tree, a selected
symlink, FIFO, socket, device, or other unsupported object fails the operation
before the archive is published; an object removed by the filters is not
opened. Entry names
produced by `create()` must be valid UTF-8. Linux permits arbitrary bytes in
filenames, but Babet refuses names that cannot be represented safely and
consistently in both output formats.

### Output format

Without `opts.format`, `create()` uses these rules:

- a destination ending in `.tar` (case-insensitive) creates an uncompressed
  POSIX pax TAR archive;
- `.tar.gz` and `.tgz` (case-insensitive) create a gzip-compressed POSIX pax
  TAR archive;
- `.tar.xz` and `.txz` (case-insensitive) create an xz-compressed
  POSIX pax TAR archive;
- `.tar.bz2`, `.tbz2`, and `.tbz` (case-insensitive) create a
  bzip2-compressed POSIX pax TAR archive;
- `.tar.zst`, `.tar.zstd`, and `.tzst` (case-insensitive) create a
  zstd-compressed POSIX pax TAR archive;
- every other destination keeps the pre-2.6 historical behaviour and creates a
  ZIP archive, regardless of its extension.

`opts.format = "zip"`, `"tar"`, `"tar.gz"`, `"tar.xz"`, `"tar.bz2"`, or
`"tar.zst"` explicitly selects a backend. An explicit format always overrides the destination suffix. This means, for
example, that `format = "zip"` may create a ZIP named `backup.tar.gz`, while
`format = "tar"` may create an uncompressed TAR named `backup.tgz` or
`backup.txz`, `backup.tbz2`, or `backup.tzst`. Format selection is based on the explicit
option or content, not trust in the suffix.

Creation options:

| Option | Default | Behaviour |
| --- | ---: | --- |
| `format` | inferred | strict string: `"zip"`, `"tar"`, `"tar.gz"`, `"tar.xz"`, `"tar.bz2"`, or `"tar.zst"` |
| `compression_level` | `6` | ZIP/gzip/xz: `0` through `9`; bzip2: `1` through `9`; zstd: `0` through `19` |
| `overwrite` | `false` | atomically replaces an existing regular archive |
| `deterministic` | `true` | stable entry order and fixed format-specific timestamps |
| `include_directories` | `true` | emits explicit directory entries, including empty directories |
| `include` | none | dense array of case-sensitive safe-glob patterns selecting archive entry paths |
| `exclude` | none | dense array of case-sensitive safe-glob patterns removed after inclusion; exclusion always wins |
| `max_entries` | `10000` | maximum output entries; hard ceiling `100000` |
| `max_file_size` | `256 * 1024 * 1024` | maximum source-file size; hard ceiling 8 GiB |
| `max_total_size` | `1024 * 1024 * 1024` | maximum source bytes; hard ceiling 64 GiB |

For plain TAR, an explicitly supplied `compression_level` is rejected. For
ZIP, gzip-compressed TAR, and xz-compressed TAR, level `0` is valid and level
`9` is the maximum. bzip2 accepts levels `1` through `9`; level `0` is
rejected because libbz2 block sizes start at 100 KiB. zstd accepts levels `0`
through `19`; Babet deliberately excludes the ultra levels `20` through `22`.

All integer options require strict Lua integers. Boolean options require real
Lua booleans. Unknown keys are rejected. `format` is case-sensitive and does
not accept aliases.

### Include and exclude filters

`include` and `exclude` are optional dense arrays of non-empty Lua strings. An
absent or empty `include` list keeps the historical behaviour and initially
selects every supported entry. A non-empty `include` list selects an entry when
at least one pattern matches. `exclude` is then applied and always wins, even
when the same path also matches `include`.

Patterns are matched against the complete path that will be stored in the
archive, using `/` as the separator. The historical string form therefore
matches paths relative to the source directory, while explicit-list sources
include their final basename (`docs/readme.md`, `report.txt`, and so on).
Matching is anchored, byte-oriented, and case-sensitive:

- `*` matches zero or more bytes except `/`;
- `**` matches zero or more bytes including `/`;
- `?` matches exactly one byte except `/`;
- `\x` quotes the following byte `x`.

Directories are tested both as `path` and `path/`. Consequently `build/**`
selects or excludes the `build/` directory itself as well as its descendants.
A directly excluded directory is pruned before it is opened, so nothing below
it is inspected or archived. When a deep file is included,
`include_directories = true` still emits every required parent directory even
if those parents do not directly match `include`. A matched empty directory is
preserved only when directory entries are enabled. With
`include_directories = false`, only selected regular files are emitted and
parents remain implicit.

Filtering defines the selected archive plan. A symlink, FIFO, socket, device,
or invalid UTF-8 filename that is excluded or does not match a non-empty
`include` list is ignored; the same object still fails creation when selected.
The explicit paths supplied as top-level sources are always validated first and
must themselves remain regular files or real directories reached without
symlinks. It is valid for all filters to select nothing: Babet then creates a
valid empty ZIP or TAR.

The safe-glob engine has no recursive backtracking. Each pattern is limited to
4096 bytes. `include` and `exclude` together are limited to 256 patterns and
256 KiB of pattern text, one million pattern evaluations, and a fixed
100,000,000-cell matching-work budget per creation call. Exceeding any limit fails before publication. Pattern
order does not affect selection or deterministic archive bytes.

All source paths are validated and each non-pruned directory tree is scanned
before the temporary output file is created. `max_entries`, `max_file_size`,
and `max_total_size` apply only to entries selected by the filters. Each
selected archive name is limited to 4096 bytes and their sum to 64 MiB.
Traversal still has fixed ceilings of 100000 sources/filesystem objects and 256
directory levels, independent of `include_directories`; descendants of a
pruned directory are not visited. Files are then reopened from
their pinned source descriptor with `O_NOFOLLOW`. Device, inode, size,
modification time, and change time are checked before and after streaming; a
file modified during creation fails the operation and removes the temporary
output.

The destination parent must already exist and may not contain symlink or `..`
components. The destination itself must be absent unless `overwrite = true`,
and it may never be a symlink or directory. The archive cannot be created
inside the historical source directory or any explicitly selected directory,
and cannot directly replace a selected regular file.

The result includes the selected format:

```lua
{
    files = 12,
    directories = 3,
    bytes = 987654,
    sources = 1,
    path = "backup.tar",
    format = "tar",
    compression = "none",
    compression_level = nil,
    deterministic = true,
    include_patterns = 0,
    exclude_patterns = 0,
}
```

`sources` is the number of supplied paths: `1` for the historical single
source-directory contract, or the explicit list length. `include_patterns`
and `exclude_patterns` report the number of compiled patterns supplied for
that call. For ZIP and gzip-, xz-, bzip2-, or zstd-compressed TAR,
`compression_level` is the effective
integer level. For plain TAR it is `nil`. Archive-level `compression`
is `"gzip"`, `"xz"`, `"bzip2"`, or `"zstd"` for compressed TAR and `"none"` otherwise. ZIP entry compression remains reported through the ZIP-specific
per-entry metadata returned by `list()`.

With the default deterministic mode, identical directory contents, format, pinned
dependency versions, and options produce byte-for-byte identical archives:

- ZIP entries use the fixed DOS timestamp 1980-01-01 00:00:00;
- TAR entries use Unix epoch zero, UID/GID `0`, empty owner/group names, mode
  `0644` for files, and mode `0755` for directories;
- gzip-compressed TAR additionally writes a gzip header timestamp of zero, so
  the outer stream does not inject wall-clock time;
- xz streams contain no wall-clock timestamp, and the selected LZMA2 preset is
  fixed by `compression_level`;
- bzip2 streams contain no wall-clock timestamp, and their block size is fixed
  by `compression_level`;
- zstd frames contain no wall-clock timestamp, enable their frame checksum, and
  use the compression level fixed by `compression_level`.

With `deterministic = false`, sorted entry order remains stable. ZIP uses each
source modification time, which must fit the DOS range 1980 through 2107 in the
local timezone. TAR preserves the source modification time with nanosecond
precision when representable by the platform and is not limited to the ZIP DOS
range.

Ownership, ACLs, extended attributes, and source permission bits are not copied.
TAR uses libarchive's restricted POSIX pax writer: ordinary names use portable
ustar headers where possible, while long paths or metadata that need extension
records are represented with pax headers. ZIP64 output is enabled automatically
when the preflight indicates that classic ZIP fields may be exceeded. Small ZIP
archives remain classic ZIP files.

The preflight and file checks prevent symlink substitution and detect changes
to every file that is actually archived. Creation is not a filesystem snapshot:
a file added after its directory was scanned may be absent from the result; a
previously enumerated file that is then removed or renamed normally makes its
secure reopen fail. Concurrent directory renames are not reported as a
transactional conflict.

When `include_directories = false`, empty directories cannot be represented and
are therefore omitted. In an explicit list, regular files still retain the
selected directory basename as their prefix. Required parents are recreated
implicitly during extraction.

Examples:

```lua
local zip, err = babet.archive.create("project", "project.zip", {
    compression_level = 9,
    overwrite = true,
})
assert(zip, err)

local selected, list_err = babet.archive.create({
    "bin/babet",
    "README.md",
    "docs",
}, "release.tar.zst", {
    compression_level = 19,
})
assert(selected, list_err)
-- Entries: babet, README.md, docs/, docs/...

local filtered, filter_err = babet.archive.create("project", "source-only.tar.zst", {
    include = { "src/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
})
assert(filtered, filter_err)

local tar
tar, err = babet.archive.create("project", "project.tar", {
    deterministic = true,
})
assert(tar, err)

local compressed
compressed, err = babet.archive.create("project", "project.tar.gz", {
    compression_level = 9,
})
assert(compressed, err)

local xz
xz, err = babet.archive.create("project", "project.tar.xz", {
    compression_level = 9,
})
assert(xz, err)

local bzip2
bzip2, err = babet.archive.create("project", "project.tar.bz2", {
    compression_level = 9,
})
assert(bzip2, err)

local zstd
zstd, err = babet.archive.create("project", "project.tar.zst", {
    compression_level = 19,
})
assert(zstd, err)

local named
named, err = babet.archive.create("project", "snapshot.data", {
    format = "tar.zst",
})
assert(named, err)
```

## Inspection/extraction options and anti-bomb limits

The following options are shared by `list()`, `test()`, `extract()`, and
`extractFile()`. They apply to the **whole archive**, even when `extractFile()` requests only one
entry: selecting a small file can never bypass global limits.

| Option | Default | Accepted maximum | Effect |
| --- | ---: | ---: | --- |
| `max_entries` | `10000` | `100000` | maximum number of entries exposed by the archive |
| `max_entry_size` | `256 * 1024 * 1024` | `8 * 1024^3` | maximum expanded size of one non-directory entry |
| `max_total_size` | `1024 * 1024 * 1024` | `64 * 1024^3` | maximum sum of expanded non-directory entry sizes |
| `max_path_length` | `64 * 1024` | `1024 * 1024` | maximum raw entry-name length, in bytes, accepted for inspection |
| `max_total_name_bytes` | `64 * 1024 * 1024` | `64 * 1024 * 1024` | maximum byte sum of all entry names; this option can tighten the fixed ceiling |
| `max_compression_ratio` | `1000` | `1000000000` | per-entry ratio for ZIP; global expanded-file-bytes/archive-bytes ratio for gzip-, xz-, bzip2-, or zstd-compressed TAR; irrelevant for plain TAR |

The five integer limits must be **real, strictly positive Lua integers**.
Floating-point values, even `10.0`, booleans, numeric strings, zero, and values
above the ceiling are rejected. `max_compression_ratio` must be finite and at
least `1`; `NaN` and infinity are rejected. An unknown key is always an error.

`max_path_length` bounds metadata accepted by Babet; it does not make a long
path extractable. Extraction path policy remains stricter: a name longer than
**4096 bytes** is reported by `list()` with `safe_path = false`, even when its
length remains below `max_path_length`. With the default value, a 4097-byte
name can therefore be inspected and diagnosed without ever being eligible for
extraction. Callers may lower `max_path_length` to reject the archive before the
Lua result table is built.

`max_total_name_bytes` already equals its fixed hard ceiling by default. It can
be lowered for an untrusted archive, but not increased. `list()` reports actual
usage as `total_name_bytes`. Allocations made by the miniz ZIP reader are also
capped at 128 MiB per archive, so an excessive central directory or ZIP comment
cannot trigger arbitrary allocation before per-entry checks.

TAR inspection is streaming: Babet reads every entry data stream without
keeping it in memory, both to reach the following header and to detect
truncation. For gzip TAR, bounded streaming validation with zlib also checks
each member's CRC and ISIZE; standard zero padding is accepted, while corrupt
trailers or foreign trailing bytes are rejected. For zstd TAR, an independent
bounded libzstd pass requires complete frames, accepts valid concatenated
frames, and rejects corruption, truncation, or foreign trailing bytes. xz and
bzip2 filters remain fully consumed by libarchive.

For complete extraction, the output tree is additionally capped internally at
100000 unique directories, including implicit parents, and 64 MiB of cumulative
normalised directory paths. These fixed ceilings are not configurable.

A non-empty entry announcing a zero compressed size is rejected. Directories
do not count towards `max_entry_size`, `max_total_size`, or the compression
ratio, but they do count towards `max_entries` and name budgets.

### One example per limit

Limit only the entry count:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 2000,
})
assert(result, err)
```

Limit only one entry's expanded size:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entry_size = 64 * 1024 * 1024,
})
assert(result, err)
```

Limit only the announced total size:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_size = 512 * 1024 * 1024,
})
assert(result, err)
```

Limit only raw name length:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_path_length = 8192,
})
assert(result, err)
```

Limit only cumulative name bytes:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_name_bytes = 2 * 1024 * 1024,
})
assert(result, err)
```

Limit only the compression ratio:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_compression_ratio = 200,
})
assert(result, err)
```

Combine every protection for a third-party archive:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 2000,
    max_entry_size = 64 * 1024 * 1024,
    max_total_size = 512 * 1024 * 1024,
    max_path_length = 8192,
    max_total_name_bytes = 2 * 1024 * 1024,
    max_compression_ratio = 200,
})
assert(result, err)
```

Creation or write-specific options such as `overwrite`,
`preserve_permissions`, `format`, `dry_run`, `include`, or `exclude` are not
accepted by `list()` or `test()`.

<a id="babetarchivelist"></a>

## `babet.archive.list`

```lua
local info, err = babet.archive.list(archive [, opts])
```

`archive` is the path to a ZIP, plain TAR, gzip-compressed TAR, xz-compressed
TAR, bzip2-compressed TAR, or zstd-compressed TAR file. Format and compression
are detected from **content**, never from the extension: a zstd TAR named
`snapshot.bin` is recognised, while a file named `snapshot.tar.zst` containing
something else is rejected. The usual `.tar`, `.tar.gz`, `.tgz`, `.tar.xz`,
`.txz`, `.tar.bz2`, `.tbz`, `.tbz2`, `.tar.zst`, `.tar.zstd`, and `.tzst`
suffixes are naming conventions only.

The source path may be a symlink to a regular file. Babet opens its target once
and keeps that same descriptor for the whole scan. Directories, FIFOs, sockets,
and devices are rejected before format parsing; non-blocking open notably
prevents a FIFO with no writer from hanging the call.

Babet first tries the miniz ZIP reader. If the pinned file is not ZIP, the same
descriptor is rewound and passed to libarchive's TAR reader, with only the
built-in `none`, `gzip`, `xz`, `bzip2`, and `zstd` filters enabled. No external
decompressor is executed. Split ZIP files and multi-volume archives are not
supported. A standard empty archive is valid and returns `count = 0`.

`list()` creates **no file, directory, or temporary file**. It preserves the
physical/logical entry order found in the archive: entries are not sorted,
deduplicated, or rearranged. `entries[1]` is always the first encountered entry,
`entries[2]` the second, and so on. This stable order lets `index`,
`duplicate_of`, and `conflict_with` directly reference the returned array.

The function returns exactly two values: `(info, nil)` on success and
`(nil, message)` on failure.

### Returned structure

```lua
{
    format = "zip",           -- "zip" or "tar"
    compression = "none",    -- "none", "gzip", "xz", "bzip2", or "zstd"
    entries = {
        {
            index = 1,
            name = "docs/readme.txt", -- raw name, binary Lua string
            path = "docs/readme.txt", -- normalised path when safe_path == true
            valid_utf8 = true,
            type = "file",
            size = 1234,

            compressed_size = 530,     -- ZIP only, otherwise nil
            crc32 = 305419896,          -- ZIP only, otherwise nil
            compression_method = 8,    -- ZIP only, otherwise nil
            encrypted = false,
            supported = true,

            safe_path = true,
            extractable = true,
            reason = nil,

            unix_mode = 420,            -- 0644, or nil
            mtime = 1750000000,         -- Unix seconds, or nil
            mtime_nsec = nil,           -- TAR only, or nil
            uid = nil,                  -- TAR only, or nil
            gid = nil,                  -- TAR only, or nil
            sparse = false,
            link_target = nil,

            duplicate = false,
            duplicate_of = nil,
            conflict = false,
            conflict_with = nil,
            conflict_reason = nil,
        },
    },
    count = 1,
    total_size = 1234,
    archive_size = 666,
    total_name_bytes = 19,
    duplicates = 0,
    conflicts = 0,
    zip64 = false,             -- nil for TAR
}
```

`format` describes the container. For ZIP, `compression` is always `"none"`
because compression is chosen per entry and reported by `compression_method`.
For TAR, `compression` is `"none"`, `"gzip"`, `"xz"`, `"bzip2"`, or `"zstd"`
according to the detected filter.

`count` is the number of elements in `entries`. `total_size` is the sum of
announced non-directory entry sizes. `archive_size` is the size of the pinned
archive file. `total_name_bytes` is the exact byte sum of all `name` fields.
`zip64` is a boolean for ZIP and `nil` for TAR.

### Fields shared by every entry

- `index` is the 1-based Lua index in archive order;
- `name` preserves the raw name as a binary Lua string;
- `path` is the normalised extraction form. A directory's trailing `/` is
  removed. It is usable as a path only when `safe_path == true`, and may be
  empty for an unsafe entry;
- `valid_utf8` says whether `name` is strict valid UTF-8. Babet never converts,
  replaces, or normalises the bytes;
- `type` is `file`, `directory`, `symlink`, `hardlink`, `fifo`,
  `character_device`, `block_device`, `socket`, or `unsupported`;
- `size` is the announced expanded size. It is normally `0` for directories or
  special objects, according to the actual metadata read;
- `safe_path` judges the name only: relative path, `/` separator, non-empty
  components, no `.` or `..`, no Windows drive prefix, no NUL byte, a trailing
  `/` consistent with the type, and the fixed 4096-byte extractable-name limit;
- `extractable` judges the entry in isolation: safe path, allowed type, no
  encryption, and a supported method. It deliberately does not include a
  duplicate or collision with another entry; also inspect `duplicate` and
  `conflict`;
- `reason` is `nil` for an individually extractable entry, otherwise a stable
  reason such as `symlink entries are refused` or
  `entry path contains '.' or '..'`;
- `unix_mode` contains bits `0000` through `7777` when available, otherwise
  `nil`. Decimal `420` is octal `0644`;
- `mtime` is modification time in seconds since the Unix epoch when available,
  otherwise `nil`;
- `mtime_nsec` is the nanosecond component of an available TAR timestamp. It is
  `nil` for ZIP;
- `uid` and `gid` are numeric TAR identifiers when explicitly present,
  otherwise `nil`. They are always `nil` for ZIP;
- `sparse` reports a sparse TAR file;
- `link_target` contains the raw target of a TAR symlink or hard link when
  exposed by libarchive, otherwise `nil`.

For ZIP, `mtime` comes from the entry's DOS timestamp converted by miniz to
`time_t`. ZIP stores neither a time zone nor nanoseconds, so this is local
calendar metadata and must be interpreted cautiously. For TAR, `mtime` may be
negative or outside the DOS range, and `mtime_nsec` preserves available
precision. Missing metadata is always represented by `nil`, never by an
invented value.

### ZIP-specific fields

`compressed_size`, `crc32`, and `compression_method` mirror ZIP central
directory metadata. `encrypted` reports the encryption flag and `supported`
says whether miniz understands the compression method. These fields are useful
for inspection, but `crc32` is not proof of integrity: `list()` does not
inflate every ZIP payload. A readable central directory may therefore coexist
with compressed data whose CRC failure is only found during reading or
extraction. For complete validation of local headers, payloads, and CRCs, use
[`archive.test()`](#babetarchivetest).

For TAR, `compressed_size`, `crc32`, and `compression_method` are `nil`,
`encrypted` is `false`, and `supported` means the header was parsed. Any outer
compression applies to the whole TAR stream and is reported by the global
`compression` field.

### Binary names, unsafe paths, and normalisation

ZIP names are byte strings from the central directory. TAR names are native
strings returned by libarchive after ustar prefix, GNU long-name, and pax
`path` processing. Comparisons are exact, byte-oriented, and case-sensitive.
No Unicode normalisation is applied: visually identical Unicode spellings
remain distinct names. Invalid UTF-8 is preserved and reported by
`valid_utf8 = false`; it is not automatically unsafe when all path rules pass.

Absolute paths, `.` or `..` components, doubled `/`, backslashes, `C:` drive
prefixes, empty names, NUL bytes, and names longer than 4096 bytes are reported
with `safe_path = false` and an explicit `reason`. `list()` continues with other
entries while metadata limits remain satisfied. It never silently repairs an
unsafe path.

### Duplicates and collisions

Diagnostics are attached to the **second and subsequent occurrences**:

- `duplicate = true` means an identical byte-for-byte `name` was already seen.
  `duplicate_of` is the first occurrence's index;
- `conflict = true` means this safe normalised output path cannot coexist with
  an earlier entry. `conflict_with` is the selected earlier index and
  `conflict_reason` is currently `duplicate output path` or
  `file/directory path conflict`;
- `duplicates` counts additional exact occurrences;
- `conflicts` counts additional occurrences that would make an extraction plan
  ambiguous or impossible.

An exact duplicate with a safe path is therefore both a `duplicate` and a
`conflict`. Different raw names such as `docs/` and `docs` are not duplicates,
but collide after normalisation and the latter receives `conflict = true`. An
unsafe entry may be reported as a raw duplicate, but does not participate in
output-path collision analysis because it has no safe extraction path.

`list()` does not turn these diagnostics into an error: inspecting a suspicious
archive is its purpose. `extract()` still rejects duplicates and collisions
before any write.

Diagnostic example:

```lua
local info, err = babet.archive.list("upload.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if not entry.safe_path then
        print(entry.index, entry.name, entry.reason)
    elseif entry.duplicate then
        print(entry.index, "duplicates entry", entry.duplicate_of)
    elseif entry.conflict then
        print(entry.index, entry.conflict_reason,
            "with entry", entry.conflict_with)
    end
end
```

### Usage examples

Print archive contents in stored order:

```lua
local info, err = babet.archive.list("backup.tar.zst")
assert(info, err)

print(info.format, info.compression, info.count)
for _, entry in ipairs(info.entries) do
    print(entry.index, entry.type, entry.path, entry.size)
end
```

Use optional metadata without assuming it exists:

```lua
local info, err = babet.archive.list("package.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if entry.mtime ~= nil then
        print(entry.name, os.date("%Y-%m-%d %H:%M:%S", entry.mtime))
    end
    if entry.unix_mode ~= nil then
        print(string.format("mode=%04o", entry.unix_mode))
    end
    if entry.uid ~= nil then
        print("uid/gid", entry.uid, entry.gid)
    end
end
```

Reject any ambiguous archive before further processing:

```lua
local info, err = babet.archive.list("upload.zip")
assert(info, err)

if info.duplicates ~= 0 or info.conflicts ~= 0 then
    error("ambiguous archive")
end

for _, entry in ipairs(info.entries) do
    if not entry.safe_path or not entry.extractable then
        error((entry.reason or "rejected entry") .. ": " .. entry.name)
    end
end
```

Handle an invalid UTF-8 name correctly:

```lua
local info, err = babet.archive.list("legacy.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if not entry.valid_utf8 then
        -- The string remains binary: display bytes instead of passing it to
        -- an interface that requires UTF-8 text.
        local bytes = {}
        for i = 1, #entry.name do
            bytes[#bytes + 1] = string.format("%02x", entry.name:byte(i))
        end
        print(entry.index, table.concat(bytes))
    end
end
```

Use `list()` in a worker:

```lua
local worker, err = babet.workers.spawn([[
local info, list_err = babet.archive.list(worker.args.archive, {
    max_entries = 5000,
})
if not info then error(list_err) end
return {
    format = info.format,
    compression = info.compression,
    count = info.count,
    duplicates = info.duplicates,
    conflicts = info.conflicts,
}
]], { archive = "backup.tar.zst" })
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.format, result.count)
```

The function and all fields behave identically in the main Lua state, folder
mode, embedded mode, and workers.

### What `list()` validates — and what it does not guarantee

For ZIP, Babet validates the structure required to open and read the central
directory, announced counts and sizes, paths, and limits. It does not read every
compressed file payload, so a payload CRC failure may remain invisible here.

For TAR and compressed TAR, reaching the next header requires consuming each
entry's data; Babet therefore detects many truncations, invalid headers, and
outer-stream errors. This complete read does not change the API's role:
`list()` returns an inventory, whereas [`archive.test()`](#babetarchivetest)
turns full consumption and aggregate safety rules into a strict verdict.

A technically readable archive containing unsafe paths, links, or special
objects is deliberately returned with diagnostics. An unknown format, an
unreadable structure, an exceeded limit, or a truncated TAR stream returns
`(nil, message)`.


<a id="babetarchivetest"></a>

## `babet.archive.test`

```lua
local result, err = babet.archive.test(archive [, opts])
```

`test()` fully verifies an archive **without extracting, creating, or writing
anything**. It accepts the same content-detected formats as `list()`: ZIP,
plain TAR, gzip TAR, xz TAR, bzip2 TAR, and zstd TAR. It accepts exactly the same
six anti-bomb limits documented above and rejects every other option.

The contract is deliberately strict: success means that the archive is both
**technically valid** and **entirely safe under Babet's extraction rules**. A
readable archive containing an unsafe path, duplicate, collision, symlink,
hard link, sparse file, special object, encrypted entry, or unsupported ZIP
method therefore returns `(nil, message)`. `test()` does not return a warnings
table or `safe = false`; use `list()` when a suspicious archive must be
inventoried and diagnosed without being accepted.

The source path follows the same contract as `list()`: a symlink to a regular
file is accepted, while directories, FIFOs, sockets, and devices are rejected
without blocking. The opened file is pinned by descriptor for the whole test.
The filename extension never chooses the backend.

### Technical verification

For ZIP, Babet checks, among other things:

- EOCD and ZIP64 metadata, rejecting split and multi-volume archives;
- the central directory and declared limits;
- the local header of **every** entry, including empty files and directories;
- local/central filename identity, flags, method, sizes, CRC, local ZIP64 fields,
  and signed or unsigned data descriptors;
- every local range, overlap between local entries, and overlap with the central
  directory;
- complete decompression of every non-directory entry, the actual output size,
  and its CRC.

For TAR, the reader consumes all entry data and checks headers, available TAR
checksums, sizes, truncation, padding, and trailing data. For gzip-, xz-,
bzip2-, or zstd-compressed TAR, the compression stream is also consumed to its
end; integrity errors, truncated members or frames, and foreign trailing bytes
are rejected according to the codec and backend guarantees.

A correctly formed empty archive is valid. A read error, unknown format,
ambiguous structure, exceeded limit, or disagreement between metadata and data
returns `(nil, message)`.

### Safety verification

After technical validation, Babet applies the same rules as real extraction to
entries in archive order:

- a non-empty relative path using only `/`, with no `.` or `..`, duplicate
  separators, backslash, drive prefix, or NUL byte;
- a maximum extractable path length of 4096 bytes;
- ordinary regular files and directories only;
- no symlink, hard link, FIFO, socket, device, unsupported object, or sparse
  file;
- no exact duplicate, output-path duplicate, or file/directory conflict;
- no encrypted ZIP entry or unsupported ZIP method.

The first diagnostic is deterministic: Babet keeps archive order and stops at
the first failing check in the phases above. Success therefore guarantees that
`files + directories == entries`.

### Returned structure

```lua
{
    format = "tar",
    compression = "zstd",
    entries = 42,
    files = 35,
    directories = 7,
    total_size = 12345678,
    archive_size = 3456789,
    total_name_bytes = 812,
    zip64 = nil,
}
```

- `format` is `"zip"` or `"tar"`;
- `compression` is `"none"`, `"gzip"`, `"xz"`, `"bzip2"`, or `"zstd"`;
- `entries`, `files`, and `directories` count verified entries;
- `total_size` is the sum of expanded regular-file sizes;
- `archive_size` is the byte size of the pinned archive file;
- `total_name_bytes` is the sum of raw entry-name lengths;
- `zip64` is a boolean for ZIP and `nil` for TAR.

The function returns exactly `(result, nil)` on success and `(nil, message)` on
failure.

### Usage examples

Simply verify an archive before keeping it:

```lua
local result, err = babet.archive.test("upload.zip")
if not result then
    io.stderr:write("archive rejected: ", err, "\n")
    return 1
end

print(result.format, result.entries, result.total_size)
```

Verify a compressed TAR even when its extension is misleading:

```lua
local result, err = babet.archive.test("snapshot.bin")
assert(result, err)
assert(result.format == "tar")
assert(result.compression == "zstd")
```

Tighten only the entry count:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 500,
})
assert(result, err)
```

Tighten only the per-file size:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entry_size = 16 * 1024 * 1024,
})
assert(result, err)
```

Tighten only the total size:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_size = 128 * 1024 * 1024,
})
assert(result, err)
```

Tighten only entry-name length:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_path_length = 4096,
})
assert(result, err)
```

Tighten only the cumulative name budget:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_name_bytes = 1024 * 1024,
})
assert(result, err)
```

Tighten only the compression ratio:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_compression_ratio = 100,
})
assert(result, err)
```

Combine all limits for an untrusted archive:

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 500,
    max_entry_size = 16 * 1024 * 1024,
    max_total_size = 128 * 1024 * 1024,
    max_path_length = 4096,
    max_total_name_bytes = 1024 * 1024,
    max_compression_ratio = 100,
})
assert(result, err)
```

Distinguish diagnostic inspection from a strict verdict:

```lua
local info, list_err = babet.archive.list("upload.zip")
assert(info, list_err)

local verified, test_err = babet.archive.test("upload.zip")
if not verified then
    print("contents visible but archive rejected:", test_err)
end
```

Use `test()` in a worker:

```lua
local worker, err = babet.workers.spawn([[
local result, test_err = babet.archive.test(worker.args.archive, {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
if not result then error(test_err) end
return result
]], { archive = "backup.tar.zst" })
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.format, result.compression, result.entries)
```

The return contract and behaviour are identical in folder mode, embedded mode,
embedded-via-`PATH` mode, and workers.

<a id="babetarchiveextract"></a>

## `babet.archive.extract`

```lua
local result, err = babet.archive.extract(
    archive,
    destination
    [, opts]
)
```

`archive` may be a ZIP, plain TAR, gzip-compressed TAR, xz-compressed TAR,
bzip2-compressed TAR, or zstd-compressed TAR. Format and compression are
detected from contents rather than the filename extension.

Accepted options:

| Option | Default | Behaviour |
| --- | ---: | --- |
| `overwrite` | `false` | allows atomic replacement of an existing regular file |
| `dry_run` | `false` | previews extraction and verifies selected data without modifying the filesystem |
| `preserve_permissions` | `false` | preserves ordinary Unix `rwx` bits when available |
| `include` | none | dense array of safe globs selecting normalised internal paths |
| `exclude` | none | dense array of safe globs removed after inclusion; exclusion always wins |
| `max_entries` | `10000` | maximum entries scanned; hard ceiling `100000` |
| `max_entry_size` | `256 * 1024 * 1024` | maximum expanded size of one entry; hard ceiling 8 GiB |
| `max_total_size` | `1024 * 1024 * 1024` | maximum sum of announced sizes; hard ceiling 64 GiB |
| `max_path_length` | `64 * 1024` | maximum raw-name length; hard ceiling 1 MiB |
| `max_total_name_bytes` | `64 * 1024 * 1024` | maximum sum of name lengths; hard ceiling 64 MiB |
| `max_compression_ratio` | `1000` | maximum expanded/compressed ratio, from `1` through `1000000000` |

Booleans must be real Lua booleans, integer limits must be strict positive Lua
integers, and `max_compression_ratio` must be finite. Unknown keys, excess
arguments, and creation-only options are rejected. `dry_run`, `include`, and
`exclude` are accepted by `extract()` only, not by `list()`, `test()`, or
`extractFile()`.

### Safe-glob selection

`include` and `exclude` reuse exactly the same bounded engine as
[`archive.create()`](#babetarchivecreate). There is no second matcher and no
extraction-specific glob dialect.

An absent or empty `include` list preserves historical behaviour and initially
selects every entry. A non-empty `include` list retains an entry when at least
one pattern matches. `exclude` is applied afterwards and always wins, even when
the same path also matches `include`.

Patterns are anchored against the entry's complete **normalised internal
path**, with `/` as the separator. Matching is byte-oriented and
case-sensitive:

- `*` matches zero or more bytes except `/`;
- `**` matches zero or more bytes including `/`;
- `?` matches exactly one byte except `/`;
- `\x` quotes the following byte `x`.

A directory is tested both as `path` and `path/`. Excluding `src/generated` or
`src/generated/**` therefore excludes that directory and prunes its complete
subtree, even when the archive has no explicit directory entry. Only parents
needed by retained files are created; an unselected explicit directory is not
created. An empty directory is restored only when its explicit entry is
selected.

The same bounds as creation apply: each pattern is limited to 4096 bytes;
`include` and `exclude` together are capped at 256 patterns and 256 KiB of
pattern text, one million pattern evaluations, and a fixed 100,000,000-cell
matching-work budget per call. The normalised graph used to propagate directory
exclusions is additionally capped at 100000 unique directory paths and 64 MiB
of cumulative path text. Exceeding a limit fails before publication. Pattern
order does not change selection.

### Read-only simulation with `dry_run`

With `dry_run = true`, Babet builds the same plan as a real extraction but does
not call any creation, write, chmod, rename, unlink, or publication operation.
The archive is pinned and scanned, the same limits and filters are applied,
selected entries are validated, and the destination is traversed read-only with
`openat`/`fstatat` and `O_NOFOLLOW`. No destination root, implicit parent,
temporary file, or final entry is created.

Destination checks retain the real extraction policy:

- a missing root is accepted and reported by
  `would_create_destination = true`;
- an existing root or parent that is a symlink or a non-directory object is
  rejected;
- a missing selected entry counts in `would_create`;
- an existing regular file counts in `would_overwrite` only with
  `overwrite = true`; with `overwrite = false`, the call fails exactly like real
  extraction;
- an explicitly selected directory that already exists counts in `would_skip`,
  because real extraction preserves it and does not chmod it;
- a file/directory conflict or a symlink final target remains an error.

`would_create`, `would_overwrite`, and `would_skip` count only **explicit selected
archive entries**. Their sum therefore equals `entries`. The destination root
and required implicit parents are not included; the root has its own boolean.
When active filters select nothing, behaviour remains identical to real
extraction: the destination is not inspected and `would_create_destination` is
`false`. Conversely, an unfiltered empty archive previews creation of its root
when that root is missing.

The simulation genuinely verifies the data that would be extracted. For ZIP,
each selected regular file is inflated to a null consumer and its CRC is
checked; unselected ZIP payloads remain untouched, as in real selective
extraction. For TAR, the second pass consumes the complete plain or compressed
stream and compares every header with the initial plan without forwarding bytes
to the filesystem. `archive.test()` remains the API for checking every ZIP
payload, including ones that extraction would skip.

The result is a **snapshot**. Another process may change the destination after
`dry_run` returns, so the preview is never a guarantee that a later extraction
will succeed or produce the same counters. Real extraction repeats all checks
and pins the required descriptors before publication.

### Validation, skipped entries, and integrity

Babet first pins the archive file and scans **every entry and the metadata needed for the extraction plan**, applying global
limits before opening the destination. Selection is then computed on normalised
names. Only retained entries participate in the output plan:

- a duplicate, file/directory collision, link, or special object found only
  outside the selection does not block extraction;
- a selected unsafe entry is still rejected before any write;
- with a non-empty `include` list, an unsafe path has no normalised form and
  cannot match, so it remains unselected;
- with `exclude` only, historical "select everything" behaviour remains active:
  an unsafe path cannot be sanitised by an exclusion pattern and still fails
  the call;
- existing destination collisions outside the selection are neither replaced
  nor modified.

This policy permits extraction of a safe part of a mixed archive without
presenting `exclude` as a path-repair mechanism. Entry, size, name, and
compression-ratio limits still apply to the complete scanned archive, not just
the retained files.

For ZIP, skipped payloads are not inflated, so their CRC is not checked by
selective extraction. For TAR, the reader must advance through the stream to
reach later headers, including through an outer compressed stream, but
`extract()` is not the complete verification API. Call
[`archive.test()`](#babetarchivetest) first when integrity of **every** entry,
including skipped data, must be guaranteed.

Before publication, Babet rejects retained non-extractable entries, duplicate
retained outputs, retained file/directory conflicts, and incompatible existing
destination objects. Selected files are staged in the secure destination and
then published atomically. For TAR, the same pinned file is reread from the
beginning and every header is compared with the first-pass plan.

When active filters select nothing, the call succeeds without creating the
destination. Without filters, an empty archive keeps historical behaviour and
creates the destination root directory.

### Return value

The function returns exactly `(result, nil)` or `(nil, message)`:

```lua
{
    entries = 28,     -- entries actually selected
    files = 24,       -- selected regular files
    directories = 4, -- selected explicit directory entries
    skipped = 15,     -- archive entries not selected
    bytes = 987654,   -- expanded bytes of selected files
    path = "restore",
}
```

With `dry_run = true`, the same table additionally contains:

```lua
{
    dry_run = true,
    would_create = 20,
    would_overwrite = 3,
    would_skip = 5,
    would_create_destination = false,
}
```

These additional fields are absent from a real extraction so its historical
contract remains unchanged. `directories` does not count implicit parents
created to reach a file. `entries == files + directories` after a successful
extraction because selected links and special objects are rejected. In a
successful simulation, `would_create + would_overwrite + would_skip == entries`.
`skipped` is `0` when no filter is active.

### Examples

Preview extraction to a missing destination:

```lua
local plan, err = babet.archive.extract("backup.zip", "restore", {
    dry_run = true,
})
assert(plan, err)
assert(plan.dry_run == true)
assert(plan.would_create_destination == true)
assert(not babet.fileExists("restore"))
```

Preview allowed replacements in an existing destination:

```lua
local plan, err = babet.archive.extract("backup.tar.zst", "restore", {
    dry_run = true,
    overwrite = true,
    preserve_permissions = true,
})
assert(plan, err)
print(plan.would_create, plan.would_overwrite, plan.would_skip)
```

Without `overwrite = true`, an existing final file remains an error:

```lua
local plan, err = babet.archive.extract("backup.zip", "restore", {
    dry_run = true,
})
assert(plan == nil and type(err) == "string")
```

Combine simulation, selection, and limits:

```lua
local plan, err = babet.archive.extract("project.tar.xz", "output", {
    dry_run = true,
    include = { "src/**", "docs/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
    overwrite = true,
    preserve_permissions = true,
    max_entries = 20000,
    max_total_size = 2 * 1024 * 1024 * 1024,
})
assert(plan, err)
assert(plan.would_create + plan.would_overwrite + plan.would_skip
    == plan.entries)
assert(not babet.fileExists("output"))
```

Extract only two precise areas:

```lua
local result, err = babet.archive.extract("project.tar.zst", "output", {
    include = {
        "src/**",
        "README.md",
    },
})
assert(result, err)
print(result.entries, result.skipped)
```

Exclude temporary files while retaining everything else:

```lua
local result, err = babet.archive.extract("backup.zip", "restore", {
    exclude = {
        "**/*.tmp",
        "cache/**",
    },
})
assert(result, err)
```

Combine inclusion and exclusion, with exclusion taking priority:

```lua
local result, err = babet.archive.extract("project.tar.xz", "output", {
    include = {
        "src/**",
        "docs/**",
        "README.md",
    },
    exclude = {
        "src/generated/**",
        "**/*.tmp",
    },
    overwrite = false,
    preserve_permissions = true,
    max_total_size = 2 * 1024 * 1024 * 1024,
})
assert(result, err)
```

Use `?` and quote a literal `*` byte:

```lua
local result, err = babet.archive.extract("assets.zip", "assets", {
    include = {
        "icons/icon-?.png", -- icon-a.png, but not icon-large.png
        "docs/file\\*.txt", -- a name that literally contains an asterisk
    },
})
assert(result, err)
```

Handle an empty selection without creating a directory:

```lua
local result, err = babet.archive.extract("package.zip", "unused", {
    include = { "does-not-exist/**" },
})
assert(result, err)
assert(result.entries == 0 and result.skipped > 0)
assert(not babet.fileExists("unused"))
```

Use filters inside a worker:

```lua
local worker, err = babet.workers.spawn([[
local result, extract_err = babet.archive.extract(
    worker.args.archive,
    worker.args.destination,
    {
        include = { "docs/**", "README.md" },
        exclude = { "docs/drafts/**" },
    }
)
if not result then error(extract_err) end
return result
]], {
    archive = "package.tar.gz",
    destination = "documentation",
})
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.files, result.skipped)
```

Preview inside a worker without creating the destination:

```lua
local worker, err = babet.workers.spawn([[
local plan, extract_err = babet.archive.extract(
    worker.args.archive, worker.args.destination, {
        dry_run = true,
        include = { "manifest.json", "docs/**" },
    })
if not plan then error(extract_err) end
return plan
]], {
    archive = "package.tar.gz",
    destination = "preview-only",
})
assert(worker, err)

local joined, plan = worker:join()
assert(joined, plan)
assert(plan.dry_run == true)
assert(not babet.fileExists("preview-only"))
```

The contract, limits, and selection are identical in folder mode, embedded
mode, embedded-via-`PATH` mode, and workers.

<a id="babetarchiveextractfile"></a>

## `babet.archive.extractFile`

```lua
local result, err = babet.archive.extractFile(
    archive,
    entry,
    destination
    [, opts]
)
```

`archive` may be a ZIP, plain TAR, gzip-compressed TAR,
xz-compressed TAR, bzip2-compressed TAR, or zstd-compressed TAR; detection uses the file contents, not the extension. ZIP
stays on miniz. TAR uses the same pinned-source and two-pass libarchive reader
as complete extraction.

`entry` is the exact **raw name** exposed by `list()`. Lookup is case-sensitive
and fails when the name is absent or occurs more than once. For TAR, GNU long
names and pax `path` records are matched after libarchive has decoded the TAR
headers, exactly as they appear in `list().entries[i].name`.

Only a regular-file entry can be selected. Sparse TAR files, symlinks, hard
links, directories, and special types are refused when selected. The entry path
is not reproduced: the content is written exactly to the caller-supplied
`destination` path.

```lua
local result, err = babet.archive.extractFile(
    "package.tar",
    "assets/logo.bin",
    "cache/current-logo.bin",
    { overwrite = true }
)
```

Result:

```lua
{
    bytes = 4096,
    path = "cache/current-logo.bin",
    entry = "assets/logo.bin",
}
```

Anti-bomb limits are still computed over the whole archive. For TAR, the first
pass consumes and validates every data stream. The second pass compares every
header with the inspected plan and consumes the archive to its end before the
selected temporary file is published. Unselected regular-file data is
discarded, and an unrelated unsafe path, special type, or sparse file does not
prevent selecting a safe regular file. Malformed or truncated data anywhere in
the archive still makes the operation fail without publishing the destination.

## Path rules

For complete extraction, every entry name must satisfy all of these rules:

- between 1 and 4096 bytes;
- no NUL byte;
- no `\`;
- no leading `/`;
- no drive prefix such as `C:` in the first component;
- no empty component (`a//b`);
- no `.` or `..` component;
- a trailing `/` only for an actual directory entry.

Paths remain relative to the destination. Babet never converts a Windows name
into a Linux path and never silently “cleans” traversal: the archive is
rejected. With `extractFile()`, the same rules apply to the selected entry name;
unselected unsafe names do not become destination paths.

Duplicates are detected after removing the trailing `/` from directory names.
An archive containing two identical outputs, or `node` as a file followed by
`node/child`, is rejected before extraction.

## Destination protection

Security does not rely only on string comparison. Babet walks the destination
component by component through directory descriptors and refuses to follow
symlinks:

- a symlink in the destination root path is rejected;
- a symlinked parent below the destination is rejected;
- a symlink final target is rejected, even with `overwrite = true`;
- a file may only replace a regular file;
- a directory entry may only use an existing or newly created directory.

Existing directories are accepted when they are real directories and remain
unchanged. Babet does not alter their permissions.

The destination path itself is trusted script input and may be absolute or
relative. The `..` rules above apply to untrusted names stored inside the
archive.

## Atomic publication and cleanup

`create()` writes the complete ZIP, plain TAR, gzip-compressed TAR, or
xz-compressed TAR to a unique mode-`0600` temporary file in the destination
directory. Its short internal name does not repeat the
output basename, so a valid destination close to the `NAME_MAX` limit remains
creatable. After the miniz ZIP central directory or libarchive TAR stream is
finalized, Babet flushes and `fsync`s the file, changes it to `0644`, publishes
it atomically,
and `fsync`s the parent directory. Without overwrite it uses a no-clobber hard
link publication; with overwrite it uses same-directory `rename`. Every error
before publication removes the temporary and leaves the previous destination
unchanged. If the final parent-directory `fsync` itself fails, the new archive
has already been atomically published but the call returns an error because
crash durability could not be confirmed.

Each extracted file is progressively written to a unique temporary file in
its final directory with mode `0600`. Temporary names are selected so they can
never collide with an output declared by the archive. Writes are bounded by
the announced size. For ZIP, miniz validates decompression and CRC. For TAR,
libarchive provides streaming blocks and Babet validates their order, bounds,
and final announced size. For gzip-wrapped TAR, Babet additionally validates
every gzip member’s CRC and ISIZE with zlib before publication. The temporary
file then receives its final permissions.

All files of a complete extraction are prepared before publication starts. A
read, decompression, or CRC error therefore publishes no file. `extractFile()`
likewise keeps its selected file temporary until the complete archive has
passed the verified read. Temporary files are removed, as are newly created
empty directories **below** the destination. Destination-root path components
that had to be created may remain present.

Publication is atomic **per file**:

- without overwrite, Babet uses creation that fails if the target exists;
- with overwrite, the same-directory temporary atomically replaces the target
  regular file.

The complete operation is not a multi-file transaction. A very late system
error during publication or final directory permission changes may happen
after previous files have been published. Those files may remain, and an old
file already replaced is not restored.

For extraction, atomic publication prevents a partially visible file but does
not promise crash durability: extracted files and directories are not fully
`fsync`ed. `create()` follows the stronger file-and-parent synchronization
sequence described above.

## Permissions

Defaults:

```text
files                                      0644
final directories                          0755
temporary files                            0600
archive directories during preparation    0700
created destination-path components        0755 (subject to umask)
```

With `preserve_permissions = true`, Babet preserves only the nine ordinary
owner/group/other bits (`0777`) from Unix modes announced by the ZIP or TAR.
setuid, setgid, and sticky bits are always stripped.

Permissions of a newly created directory are applied only after its contents
have been extracted, so a restrictive final mode such as `0000` cannot block
the current operation. Existing directories are never chmodded.

UIDs, GIDs, ACLs, extended attributes, and timestamps are not restored.

## Supported entry types

| Type | `create()` | `list()` | `extract()` | `extractFile()` |
| --- | --- | --- | --- | --- |
| regular file | supported | inspected | supported, except sparse TAR | supported, except sparse TAR |
| directory | supported when enabled | inspected | supported | not selectable |
| sparse TAR file | never created | identified in TAR | rejected | rejected if selected |
| symlink | rejected if selected | identified | rejected | rejected |
| hard link | never created | identified in TAR | rejected | rejected if selected |
| FIFO, socket, device, unknown type | rejected if selected | identified when exposed | rejected | rejected |
| encrypted entry | never created | identified in ZIP | rejected | rejected |
| unknown ZIP compression method | never created | identified | rejected | rejected |

During creation, a symlink or special filesystem object that is removed by the
filters is ignored rather than opened. Directory entries are emitted only when
`include_directories = true`.

For regular-file creation, ZIP, gzip, and xz accept compression levels `0`
through `9`; bzip2 accepts `1` through `9`; zstd accepts `0` through `19`;
plain TAR stores the source bytes without compression.

A ZIP entry that resembles a hard link but is encoded as a regular file is
treated as an independent regular file; no link is created.

## Errors and known limitations

Common failures include:

- missing or unsafe source directory, source symlink, non-UTF-8 source name,
  unsupported source object, invalid creation format, ZIP-only option used for
  TAR, or out-of-range ZIP timestamp;
- output archive inside the source, unsafe destination parent, or destination symlink;
- missing, unreadable, non-regular, unsupported, or malformed archive file;
- truncated TAR data, non-TAR trailing data, a non-regular TAR entry carrying
  a payload, or a change detected between inspection and extraction;
- inconsistent metadata or invalid CRC;
- exceeded anti-bomb limit;
- absolute path, traversal, duplicate, or path conflict;
- encrypted entry, symlink, or unsupported type;
- existing destination without `overwrite = true`;
- symlink or unsafe type in the destination;
- insufficient disk space, permissions, or another I/O error.

The module is synchronous: a call returns only after creation, inspection, or
extraction has completed. It does not expose progress, cancellation, or a timeout yet.

The archive file must not be modified concurrently. ZIP truncation or
modification will normally cause a read, decompression, or CRC error. TAR is
streamed through libarchive; concatenated TAR streams are scanned to their end,
and truncated or non-TAR trailing data is rejected. Neither backend provides a
concurrent snapshot.
The destination must not be actively reorganised by another process either.
Traversal rejects symlinks and rechecks types before publication, but an actor
that continuously renames directories can make the operation fail and turn
temporary-file cleanup into a best-effort action.

Plain, gzip-, xz-, bzip2-, and zstd-compressed TAR creation is supported.
Standalone compression streams remain intentionally outside this archive API
and are handled by [`babet.compression`](compression.md).

Multi-disk archives are not a supported target. ZIP64 is accepted when miniz
can read it, while still being subject to the configured limits.
