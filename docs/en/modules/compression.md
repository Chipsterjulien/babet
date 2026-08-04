# Compression - standalone gzip, xz, bzip2, and zstd streams

## Scope

`babet.compression` compresses or decompresses the bytes of one regular file.
It handles **standalone streams**, not archives:

- gzip (`.gz` by convention);
- xz (`.xz`);
- bzip2 (`.bz2`);
- Zstandard (`.zst`).

A standalone stream has no portable entry name, directory tree, permissions,
or archive metadata. Use [`babet.archive`](archive.md) for ZIP files or TAR
archives, including `.tar.gz`, `.tar.xz`, `.tar.bz2`, and `.tar.zst`.

## API overview

```lua
local ok, err = babet.compression.compress(
    source, destination, format [, opts]
)

local ok, err = babet.compression.decompress(
    source, destination [, opts]
)
```

Both functions return:

- `true, nil` on success;
- `nil, "message"` on an operational or option error.

Wrong required argument types, embedded NUL bytes, and incorrect arity raise a
Lua error. Unknown option names are rejected.

## `compress(source, destination, format [, opts])`

`source`, `destination`, and `format` are strict Lua strings. Paths must not be
empty or contain an embedded NUL byte.

`format` must be exactly one of:

```text
"gzip"  "xz"  "bzip2"  "zstd"
```

The filename extension is not inspected or added automatically. This is valid:

```lua
local ok, err = babet.compression.compress(
    "payload.bin",
    "payload.data",
    "zstd"
)
```

The optional table accepts:

| Field | Type | Default | Meaning |
| --- | --- | ---: | --- |
| `overwrite` | boolean | `false` | Atomically replace an existing regular destination file. |
| `level` | Lua integer | format-specific | Explicitly select the compression level. |

`level` is a strict Lua integer. Floats, numeric strings, and out-of-range
values are rejected before the source file is opened. Accepted ranges and the
values used when the field is absent are:

| Format | Minimum | Maximum | Default |
| --- | ---: | ---: | ---: |
| gzip | `0` | `9` | `6` |
| xz | `0` | `9` | `6` |
| bzip2 | `1` | `9` | `9` |
| zstd | `1` | `22` | `3` |

A higher level generally favours compression ratio at the cost of CPU time and
sometimes additional memory. For gzip, level `0` creates a valid stream without
DEFLATE compression. The highest xz presets can consume substantial memory and
therefore must always be selected explicitly.

### Example

```lua
local ok, err = babet.compression.compress(
    "database.dump",
    "database.dump.zst",
    "zstd",
    { overwrite = true, level = 10 }
)

if not ok then
    io.stderr:write(err, "\n")
    return 1
end
```

## `decompress(source, destination [, opts])`

The compression format is detected from the input bytes, not from the
extension. Renaming `file.gz` to `file.bin` therefore does not change how it is
decoded. Uncompressed data and unsupported formats are rejected.

The optional table accepts:

| Field | Type | Default | Meaning |
| --- | --- | ---: | --- |
| `overwrite` | boolean | `false` | Atomically replace an existing regular destination file. |
| `max_output_size` | Lua integer | 1 GiB | Maximum number of decompressed bytes accepted. |

`max_output_size` must be between `1` and `68719476736` bytes (64 GiB).
The limit is checked before each write. If it is exceeded, the temporary file
is removed and the destination is not published.

### Example

```lua
local ok, err = babet.compression.decompress(
    "database.dump.zst",
    "database.dump",
    {
        overwrite = true,
        max_output_size = 4 * 1024 * 1024 * 1024,
    }
)

if not ok then
    io.stderr:write(err, "\n")
    return 1
end
```

## Concatenated streams and integrity

Valid concatenated gzip members, xz streams, bzip2 members, and zstd frames are
decoded in order into the same destination file.

The decoders verify the mandatory integrity fields and any optional checksum
present in the stream. Babet-generated zstd frames enable the optional content
checksum. An external zstd frame without that field remains readable, but the
format itself then cannot detect every possible payload bit flip. Babet rejects:

- truncated streams;
- corrupted checksums or frames;
- arbitrary trailing bytes after the final valid member/frame;
- inputs whose magic bytes do not identify a supported format.

## Filesystem and publication guarantees

The module follows a fail-closed file policy:

- the source must be a real regular file;
- a symlink source is rejected;
- source and destination parent paths must already exist and are opened
  component by component with `O_NOFOLLOW`;
- `..` components in those parent paths are rejected;
- a destination symlink or non-regular destination is rejected;
- source and destination must not refer to the same inode, including through a
  hard link;
- the source descriptor is pinned and its size and timestamps are checked again
  before publication;
- output is streamed into a mode-`0600` temporary file in the destination
  directory;
- the completed file is synced, changed to mode `0644`, and atomically
  published;
- with `overwrite = false`, publication cannot replace a destination that
  appeared concurrently;
- temporary files are removed on failures before publication.

The module never uses a shell and never derives the destination filename from
compressed metadata.

## Binary data and memory use

Input and output are byte streams. NUL bytes and arbitrary binary content are
preserved.

Compression and decompression use bounded 64 KiB working buffers. The full
input or output is not loaded into the Lua state or into one C++ string.
`max_output_size` additionally bounds decompression expansion. The xz decoder
has a 256 MiB internal memory ceiling and the zstd decoder refuses windows
above 128 MiB.

## C++ exception boundary

Both public functions enter through the common Lua/C++ exception boundary.
This does not change any ordinary result. It prevents an unexpected C++
exception from crossing Lua's C frames:

- allocation failure: `(nil, "compression: out of memory")`;
- another standard exception: `(nil, "compression: internal failure")`;
- unknown exception: `(nil, "compression: unknown internal failure")`.

The source descriptor and unpublished output remain owned by RAII guards while
the operation runs. If such an exception occurs, those descriptors are closed
and the same-directory temporary output is removed before the diagnostic is
returned.

## Workers

`babet.compression` is registered in every worker Lua state. Different workers
may process different files concurrently. Normal filesystem collision rules
still apply if several workers target the same destination.

## Error examples

```lua
local ok, err = babet.compression.compress(
    "input.bin", "input.bin.gz", "zip"
)
-- nil, "compression: format must be 'gzip', 'xz', 'bzip2', or 'zstd'"

ok, err = babet.compression.decompress(
    "large.gz", "large.bin", { max_output_size = 1024 }
)
-- nil, "compression: decompressed output exceeds opts.max_output_size"
```

A failed operation should always be handled before using the destination.
