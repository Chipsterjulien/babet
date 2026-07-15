# Archive — secure ZIP creation, inspection, and extraction

## Scope

The `babet.archive` submodule creates, inspects, and extracts **ZIP** archives
without calling an external command:

```lua
babet.archive.create(source, archive [, opts])
babet.archive.list(archive [, opts])
babet.archive.extract(archive, destination [, opts])
babet.archive.extractFile(archive, entry, destination [, opts])
```

The module is deliberately limited to ZIP and does not support TAR, GZIP, XZ,
BZIP2, or Zstandard.

All four functions use the usual result contract:

```lua
local result, err = babet.archive.list("backup.zip")
if not result then
    io.stderr:write(err, "\n")
end
```

They return `(result, nil)` on success and `(nil, message)` on failure. Wrong
arity or a mandatory argument that is not a string raises a Lua error. An
invalid option table returns `(nil, message)`.

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
    source,
    archive
    [, opts]
)
```

`source` must be an existing directory. Babet archives its contents, not the
source directory name itself. Traversal is descriptor-based and does not follow
symlinks. A symlink anywhere in the source path or tree, or a FIFO, socket,
device, or other unsupported object, makes the operation fail before the
archive is published. Entry names produced by `create()` must be valid UTF-8:
Linux permits arbitrary bytes in filenames, but Babet rejects names that would
produce a ZIP falsely declaring invalid bytes as UTF-8.

Creation options:

| Option | Default | Behaviour |
| --- | ---: | --- |
| `compression_level` | `6` | integer from `0` (stored) through `9` |
| `overwrite` | `false` | atomically replaces an existing regular archive |
| `deterministic` | `true` | sorts names and writes the timezone-independent fixed timestamp 1980-01-01 00:00:00 |
| `include_directories` | `true` | emits explicit directory entries, including empty directories |
| `max_entries` | `10000` | maximum output entries; hard ceiling `100000` |
| `max_file_size` | `256 * 1024 * 1024` | maximum source-file size; hard ceiling 8 GiB |
| `max_total_size` | `1024 * 1024 * 1024` | maximum source bytes; hard ceiling 64 GiB |

All integer options require strict Lua integers. Boolean options require real
Lua booleans. Unknown keys are rejected.

The complete source tree is scanned before the output temporary file is
created. Entry names are limited to 4096 bytes each and 64 MiB cumulatively.
The scan also has fixed ceilings of 100000 filesystem nodes and 256 directory
levels, independently of `include_directories`. Files are then reopened through
the source directory descriptor with
`O_NOFOLLOW`. Device, inode, size, modification time, and change time are
checked before and after compression; a file changed during creation causes a
failure and the temporary archive is removed.

The destination parent must already exist and may not contain symlink or `..`
components. The destination itself must be absent unless `overwrite = true`,
and it may never be a symlink or directory. An archive cannot be written inside
the source tree, avoiding accidental self-inclusion.

The result is:

```lua
{
    files = 12,
    directories = 3,
    bytes = 987654,
    path = "backup.zip",
    compression_level = 6,
    deterministic = true,
}
```

With the default deterministic mode, identical directory contents and options
produce byte-for-byte identical archives, including across local time zones.
With `deterministic = false`, sorted entry order remains stable but each entry
uses the source modification time, which must fit the ZIP DOS timestamp range
1980 through 2107 in the local timezone. Ownership, ACLs, extended attributes, and
permission bits are not copied. The archive file itself is published with mode
`0644`; extracted files continue to use the safe extraction defaults described
below.

ZIP64 output is enabled automatically when the preflight indicates that the
classic ZIP entry-count or 4 GiB size fields may be exceeded. Small archives
remain classic ZIP files.

The preflight and file checks prevent symlink substitution and detect changes
to every file that is actually archived. Creation is not a filesystem snapshot:
a file added after its directory was scanned may be absent from the result; a
previously enumerated file that is then removed or renamed normally makes its
secure reopen fail. Concurrent directory renames are not reported as a
transactional conflict.

When `include_directories = false`, empty directories cannot be represented and
are therefore omitted.

Example:

```lua
local result, err = babet.archive.create("project", "project.zip", {
    compression_level = 9,
    overwrite = true,
    max_total_size = 2 * 1024 * 1024 * 1024,
})
if not result then
    error(err)
end
```

## Inspection/extraction options and anti-bomb limits

The options shared by `list()`, `extract()`, and `extractFile()` are:

| Option | Default | Accepted maximum | Effect |
| --- | ---: | ---: | --- |
| `max_entries` | `10000` | `100000` | maximum number of entries in the archive |
| `max_entry_size` | `256 * 1024 * 1024` | `8 * 1024^3` | maximum expanded size of one non-directory entry |
| `max_total_size` | `1024 * 1024 * 1024` | `64 * 1024^3` | maximum sum of expanded non-directory entry sizes |
| `max_compression_ratio` | `1000` | `1000000000` | maximum per-entry `expanded size / compressed size` ratio |

The three integer limits must be **strictly positive Lua integers**.
`max_compression_ratio` must be finite and at least `1`. `NaN`, infinity,
booleans, and numeric strings are rejected.

Independently of the options, the cumulative size of all entry names is
internally limited to 64 MiB. This fixed ceiling bounds metadata memory even
when `max_entries` is explicitly raised.
Allocations made by the miniz ZIP reader are additionally capped at 128 MiB per
archive. The central directory and its comments therefore cannot trigger an
arbitrary allocation before per-entry limits are applied.

For complete extraction, the output tree is also internally capped at 100000
unique directories, including implicit parents, and 64 MiB of cumulative
normalized directory paths. A few extremely deep entries therefore cannot
cause an unbounded explosion in `mkdir` operations or prefix-memory use.

These limits are applied while inspecting the **whole archive**, including
with `list()` and `extractFile()`. Therefore `extractFile()` cannot bypass the
global policy by selecting a small entry from an archive whose metadata
announces excessive expansion.

A non-empty entry that announces a zero compressed size is always rejected.
Directories do not count towards `max_entry_size`, `max_total_size`, or the
compression ratio, but they do count towards `max_entries`.

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

`archive` is the path to a ZIP file. The path may be a symlink to a regular file: Babet opens its target once and keeps that same descriptor for the
whole scan. Directories, FIFOs, sockets, and devices are rejected before ZIP
parsing; non-blocking open notably prevents a FIFO with no writer from hanging
`list()`, `extract()`, or `extractFile()`. The function then opens the central
directory, applies the limits above, and returns:

```lua
{
    entries = {
        {
            name = "docs/readme.txt", -- raw entry name
            path = "docs/readme.txt", -- normalised extraction path
            type = "file",            -- file, directory, symlink, unsupported
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
        },
    },
    count = 1,
    total_size = 1234,
    archive_size = 666,
    zip64 = false,
}
```

`path` removes the trailing `/` from a directory entry. It is only meaningful
as an extraction path when `safe_path == true`.

`extractable` means that the entry has an acceptable path and type, uses a
compression method understood by miniz, and is not encrypted. It does not
predict destination conflicts or duplicates between entries. When it is
`false`, `reason` describes the first rejection reason.

`unix_mode` contains only bits `0000` through `7777` announced by an archive
created on a Unix host. It is `nil` when that information is unavailable. A
mode being present does not mean it will be preserved: see
[`preserve_permissions`](#permissions).

Names read from an existing archive are byte strings. Comparisons are exact and
case-sensitive; no Unicode normalisation is performed. This inspection
tolerance does not weaken `create()`, which emits valid UTF-8 names only.

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

Before writing any file, Babet:

1. inspects all metadata and applies the limits;
2. rejects every non-extractable entry;
3. rejects duplicate output paths;
4. rejects conflicts where one path would need to be both a file and a
   directory;
5. checks existing destination objects.

The result is:

```lua
{
    files = 12,
    directories = 3, -- explicit directory entries in the ZIP
    bytes = 987654,  -- expanded file bytes
    path = "restore",
}
```

`directories` does not count implicit parents created to reach a file.

Example:

```lua
local result, err = babet.archive.extract("backup.zip", "restore", {
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

`entry` is the exact **raw name** stored in the archive. Lookup is
case-sensitive. It fails when the name is absent or occurs more than once.

Only a regular-file entry can be selected. The entry path is not reproduced:
the content is written exactly to the caller-supplied `destination` path.

```lua
local result, err = babet.archive.extractFile(
    "package.zip",
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

Anti-bomb limits are still computed over the whole archive. Other entries are
not extracted, however: an unselected entry with an unsafe path or a
non-extractable type does not prevent selecting a safe entry.

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
rejected.

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

`create()` writes the complete ZIP to a unique mode-`0600` temporary file in
the destination directory. Its short internal name does not repeat the output
basename, so a valid destination close to the `NAME_MAX` limit remains
creatable. After the central directory is finalized, Babet
flushes and `fsync`s the file, changes it to `0644`, publishes it atomically,
and `fsync`s the parent directory. Without overwrite it uses a no-clobber hard
link publication; with overwrite it uses same-directory `rename`. Every error
before publication removes the temporary and leaves the previous destination
unchanged. If the final parent-directory `fsync` itself fails, the new archive
has already been atomically published but the call returns an error because
crash durability could not be confirmed.

Each extracted file is progressively extracted into a unique temporary file created in
its final directory with mode `0600`. Temporary names are selected so they can
never collide with an output declared by the archive. Writes are bounded by
the announced size. miniz validates decompression and CRC before the file is
published. The temporary file then receives its final permissions.

All files of a complete extraction are prepared before publication starts. A
read, decompression, or CRC error therefore publishes no file. Temporary files
are removed, as are newly created empty directories **below** the destination.
Destination-root path components that had to be created may remain present.

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
owner/group/other bits (`0777`) from Unix modes announced by the ZIP. setuid,
setgid, and sticky bits are always stripped.

Permissions of a newly created directory are applied only after its contents
have been extracted, so a restrictive final mode such as `0000` cannot block
the current operation. Existing directories are never chmodded.

UIDs, GIDs, ACLs, extended attributes, and timestamps are not restored.

## Supported entry types

| Type | `create()` | `list()` | `extract()` / `extractFile()` |
| --- | --- | --- | --- |
| regular file | supported, stored at level `0` or DEFLATE otherwise | inspected | supported |
| directory | supported when `include_directories = true` | inspected | supported by `extract()` |
| symlink | always rejected | identified | always rejected |
| FIFO, socket, device, or unknown filesystem type | always rejected | identified | rejected |
| encrypted entry | not created | identified | rejected |
| unknown compression method | not created | identified | rejected |

A ZIP entry that resembles a hard link but is encoded as a regular file is
treated as an independent regular file; no link is created.

## Errors and known limitations

Common failures include:

- missing or unsafe source directory, source symlink, non-UTF-8 source name,
  out-of-range ZIP timestamp, or unsupported source object;
- output archive inside the source, unsafe destination parent, or destination symlink;
- missing, unreadable, non-regular, or malformed ZIP file;
- inconsistent metadata or invalid CRC;
- exceeded anti-bomb limit;
- absolute path, traversal, duplicate, or path conflict;
- encrypted entry, symlink, or unsupported type;
- existing destination without `overwrite = true`;
- symlink or unsafe type in the destination;
- insufficient disk space, permissions, or another I/O error.

The module is synchronous: a call returns only after creation, inspection, or
extraction has completed. It does not expose progress, cancellation, or a timeout yet.

The ZIP file must not be modified concurrently. Truncation or modification
during an operation will normally cause a read, decompression, or CRC error,
but no concurrent snapshot is guaranteed.
The destination must not be actively reorganised by another process either.
Traversal rejects symlinks and rechecks types before publication, but an actor
that continuously renames directories can make the operation fail and turn
temporary-file cleanup into a best-effort action.

Multi-disk archives are not a supported target. ZIP64 is accepted when miniz
can read it, while still being subject to the configured limits.
