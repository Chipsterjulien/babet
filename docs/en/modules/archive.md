# Archive — secure ZIP and TAR operations with gzip, xz, bzip2, or zstd

## Scope

The `babet.archive` submodule creates, inspects, and extracts **ZIP**, **TAR**,
and **gzip-, xz-, bzip2-, or zstd-compressed TAR** archives without calling an external command:

```lua
babet.archive.create(source_or_sources, archive [, opts])
babet.archive.list(archive [, opts])
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

All four functions use the usual result contract:

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

The options shared by `list()`, `extract()`, and `extractFile()` are:

| Option | Default | Accepted maximum | Effect |
| --- | ---: | ---: | --- |
| `max_entries` | `10000` | `100000` | maximum number of entries in the archive |
| `max_entry_size` | `256 * 1024 * 1024` | `8 * 1024^3` | maximum expanded size of one non-directory entry |
| `max_total_size` | `1024 * 1024 * 1024` | `64 * 1024^3` | maximum sum of expanded non-directory entry sizes |
| `max_compression_ratio` | `1000` | `1000000000` | maximum per-entry ratio for ZIP; maximum global expanded-file-bytes/archive-bytes ratio for gzip-, xz-, bzip2-, or zstd-compressed TAR; irrelevant for plain TAR |

The three integer limits must be **strictly positive Lua integers**.
`max_compression_ratio` must be finite and at least `1`. `NaN`, infinity,
booleans, and numeric strings are rejected.

Independently of the options, the cumulative size of all entry names is
internally limited to 64 MiB. This fixed ceiling bounds metadata memory even
when `max_entries` is explicitly raised.
Allocations made by the miniz ZIP reader are additionally capped at 128 MiB per
archive. The central directory and its comments therefore cannot trigger an
arbitrary allocation before per-entry limits are applied. TAR inspection is
streaming: Babet reads every entry data stream without storing it in memory,
both to reach the following header and to detect truncated data. For gzip TAR, Babet additionally performs a bounded streaming validation with
zlib because libarchive itself does not verify the gzip trailer CRC/ISIZE;
corrupt trailers and non-gzip trailing bytes are therefore rejected. Standard
zero padding after a gzip member is accepted. For zstd TAR, Babet performs an
independent bounded streaming validation with libzstd, requiring complete
frames, accepting valid concatenated frames, and rejecting corruption,
truncation, or foreign trailing bytes before publication.

For complete extraction, the output tree is also internally capped at 100000
unique directories, including implicit parents, and 64 MiB of cumulative
normalized directory paths. A few extremely deep entries therefore cannot
cause an unbounded explosion in `mkdir` operations or prefix-memory use.

These limits are applied while inspecting the **whole archive**, including
with `list()` and `extractFile()`. Therefore `extractFile()` cannot bypass the
global policy by selecting a small entry from an archive whose metadata
announces excessive expansion.

For ZIP, a non-empty entry that announces a zero compressed size is always
rejected and the ratio is checked per entry. For gzip-, xz-, bzip2-, or zstd-compressed TAR, Babet checks the sum of announced regular-file sizes against the complete
compressed archive size after the stream has been consumed. Plain TAR has no
compression ratio. Directories do not count towards `max_entry_size` or
`max_total_size`,
but they do count towards `max_entries`.

Example:

```lua
local info, err = babet.archive.list("upload.zip", {
    max_entries = 2000,
    max_entry_size = 64 * 1024 * 1024,
    max_total_size = 512 * 1024 * 1024,
    max_compression_ratio = 200,
})
```

Unknown keys are rejected. Creation and extraction-only options are not
accepted by `list()`.

<a id="babetarchivelist"></a>

## `babet.archive.list`

```lua
local info, err = babet.archive.list(archive [, opts])
```

`archive` is the path to a ZIP, plain TAR, gzip-compressed TAR,
xz-compressed TAR, bzip2-compressed TAR, or zstd-compressed TAR file. The extension is not used for detection. The path may
be a symlink to a regular file: Babet opens its target once and keeps that same
descriptor for the whole scan. Directories,
FIFOs, sockets, and devices are rejected before format parsing; non-blocking
open notably prevents a FIFO with no writer from hanging `list()`.

For ZIP, Babet first uses the existing miniz reader. If the same pinned file is
not a ZIP, Babet rewinds that descriptor and enables only libarchive's TAR
reader plus the built-in `none`, `gzip`, `xz`, `bzip2`, and `zstd` filters. No external
decompressor can be invoked by this path. Concatenated TAR archives are traversed completely;
non-TAR trailing data, truncated payloads, and data attached to non-regular
entries are rejected. The function applies the limits above and returns:

```lua
{
    format = "zip",           -- "zip" or "tar"
    compression = "none",    -- "none", "gzip", "xz", "bzip2", or "zstd" for TAR
    entries = {
        {
            name = "docs/readme.txt", -- raw entry name
            path = "docs/readme.txt", -- normalised extraction path
            type = "file",            -- see the supported entry types below
            size = 1234,
            compressed_size = 530,
            crc32 = 305419896,         -- unsigned 32-bit integer
            compression_method = 8,
            encrypted = false,
            supported = true,
            safe_path = true,
            extractable = true,
            reason = nil,
            unix_mode = 420,           -- 0644, or nil without a Unix mode
            sparse = false,
            link_target = nil,         -- TAR symlink/hard-link target
        },
    },
    count = 1,
    total_size = 1234,
    archive_size = 666,
    zip64 = false,             -- nil for TAR
}
```

`path` removes the trailing `/` from a directory entry. It is only meaningful
as an extraction path when `safe_path == true`.

For ZIP, `compression` remains `"none"`: ZIP compression is per entry rather
than an outer stream. For TAR, `compression` is `"none"`, `"gzip"`, or `"xz"` according to the
detected filter.

For ZIP, `extractable` means that the entry has an acceptable path and type,
uses a compression method understood by miniz, and is not encrypted. For TAR,
safe regular files and directories are extractable. Sparse files, symlinks,
hard links, FIFOs, devices, and other special TAR types are inspected but
rejected with an explicit reason. `extractable` never predicts destination
conflicts or duplicates between entries.

ZIP-specific fields keep their previous exact values. For TAR,
`compressed_size`, `crc32`, and `compression_method` are `nil`, because TAR has
no per-entry compression or CRC metadata. `encrypted` is `false`, `supported`
means that libarchive could parse the entry, and `sparse` reports sparse-file
metadata. `link_target` contains the raw target announced for a TAR symlink or
hard link when libarchive exposes one, and is `nil` otherwise. The TAR types
reported by this lot are
`file`, `directory`, `symlink`, `hardlink`, `fifo`, `character_device`,
`block_device`, `socket`, and `unsupported`.

`unix_mode` contains only bits `0000` through `7777` announced by an archive
created on a Unix host. It is `nil` when that information is unavailable. A
mode being present does not mean it will be preserved: see
[`preserve_permissions`](#permissions).

ZIP names read from an existing archive are byte strings. TAR pathnames are the
native strings returned by libarchive after its TAR header handling (including
ustar prefixes, GNU long names, and pax path headers). Comparisons are exact
and case-sensitive, and Babet performs no additional Unicode normalisation.
This inspection tolerance does not weaken `create()`, which emits valid UTF-8
names for both ZIP and TAR.

<a id="babetarchiveextract"></a>

## `babet.archive.extract`

```lua
local result, err = babet.archive.extract(
    archive,
    destination
    [, opts]
)
```

Additional options:

| Option | Default | Behaviour |
| --- | --- | --- |
| `overwrite` | `false` | allows atomic replacement of an existing regular file |
| `preserve_permissions` | `false` | preserves ordinary Unix `rwx` bits when available |

Both values must be real Lua booleans.

`archive` may be a ZIP, plain TAR, gzip-compressed TAR,
xz-compressed TAR, bzip2-compressed TAR, or zstd-compressed TAR; the format and compression are detected from its contents,
not its extension. Before writing any file, Babet:

1. inspects the whole archive and applies the limits;
2. rejects every non-extractable entry;
3. rejects duplicate output paths;
4. rejects conflicts where one path would need to be both a file and a
   directory;
5. checks existing destination objects.

For TAR, Babet then rereads the **same pinned file** from the beginning,
compares every header with the plan produced by inspection, and forwards
regular-file blocks to the secure destination layer. An entry added, removed,
or changed in metadata between the two passes makes the operation fail. This
check is not a snapshot: concurrent same-size data modification can still
trigger a read error, but is not guaranteed to be distinguished when the
headers remain identical.

The result is:

```lua
{
    files = 12,
    directories = 3, -- explicit directory entries in the archive
    bytes = 987654,  -- expanded file bytes
    path = "restore",
}
```

`directories` does not count implicit parents created to reach a file.

Example:

```lua
local result, err = babet.archive.extract("backup.tar", "restore", {
    overwrite = false,
    preserve_permissions = true,
    max_total_size = 2 * 1024 * 1024 * 1024,
})

if not result then
    error(err)
end

print(result.files, result.bytes)
```

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
