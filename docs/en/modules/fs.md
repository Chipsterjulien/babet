> **English** | [Français](../../fr/modules/fs.md)

# `babet` fs — file system

A flat set of file system operations exposed directly on `babet`
(no sub-namespace, predates the convention). Covers the everyday
needs that Lua's `os.*` and `io.*` don't : recursive listing, copy
with attributes, hashing, path manipulation, attributes, links.

## Why

Lua's standard `io` and `os` give you `open`, `rename`, `remove`,
and that's about it. Everything beyond that — listing a directory,
recursive copy, computing a hash, querying mtime — requires
external programs or low-level FFI. `babet` collects these in a
single set of functions that behave consistently (paths are
strings, errors come back as `(nil, "...")`).

All paths are accepted as plain strings. Tilde expansion (`~/x`)
is **not** automatic — the caller must resolve `$HOME` itself if
needed. Functions never expand globs ; for glob support, use
`babet.find` with an explicit pattern.

## API — Existence, type, attributes

| Function | Returns |
| --- | --- |
| `babet.fileExists(path)` | `boolean` |
| `babet.isfile(path)` | `boolean` (true only for regular files) |
| `babet.isdir(path)` | `boolean` |
| `babet.fileSize(path)` | `integer` bytes \| `(nil, err)` |
| `babet.getAttributes(path)` | `table` with `mtime`, `mode`, `size`, `uid`, `gid`, `inode`, etc. \| `(nil, err)` |
| `babet.setAttributes(path, uid, gid, mode?)` | `(true, nil)` \| `(nil, err)` — set owner/group, optionally mode |
| `babet.symlinkattr(path)` | same shape as `getAttributes`, but `lstat` (does not follow symlinks) \| `(nil, err)` |
| `babet.getMode(path)` | octal `integer` \| `(nil, err)` |
| `babet.setMode(path, mode)` | `(true, nil)` \| `(nil, err)` — `mode` is an integer (use `0x1ed` for `0755`, or build it with `tonumber("755", 8)`) |

## API — Creating, removing, moving

| Function | Returns |
| --- | --- |
| `babet.touch(path)` | `(true, nil)` \| `(nil, err)` — create file or update mtime |
| `babet.mkdir(path, opts?)` | `(true, nil)` \| `(nil, err)` — `opts.parents = true` for `mkdir -p` |
| `babet.rmdir(path)` | `(true, nil)` \| `(nil, err)` — only empty dirs |
| `babet.rmdirAll(path)` | `(true, nil)` \| `(nil, err)` — recursive |
| `babet.remove(path)` | `(true, nil)` \| `(nil, err)` — file or symlink |
| `babet.rename(old, new)` | `(true, nil)` \| `(nil, err)` |
| `babet.chdir(path)` | `(true, nil)` \| `(nil, err)` |

> `chdir` mutates the working directory of the WHOLE process : it is
> forbidden once a `workers.spawn` has happened (`(nil, err)`,
> permanent). See the note in [sys](sys.md).
| `babet.currentDir()` | `string` (absolute) |
| `babet.joinPath(a, b, ...)` | `string` — like `path/a/b/c` ; also accepts a single table of segments |
| `babet.link(target, link, opts?)` | `(true, nil)` \| `(nil, err)` — `opts.symbolic = true` for symlinks |

## API — Path manipulation

These operate on path *strings* — they don't touch the filesystem.

| Function | Returns | Example |
| --- | --- | --- |
| `babet.getBasename(path)` | `string` \| `(nil, err)` — last component | `"/etc/hostname"` → `"hostname"` |
| `babet.getPath(path)` | `string` \| `(nil, err)` — parent dir (dirname) | `"/etc/hostname"` → `"/etc"` |
| `babet.getFilename(path)` | `string` \| `(nil, err)` — basename without extension | `"report.tar.gz"` → `"report.tar"` |
| `babet.getExtension(path)` | `string` \| `(nil, err)` — final extension | `"report.tar.gz"` → `".gz"` |

## API — Listing and finding

| Function | Returns |
| --- | --- |
| `babet.listFiles(path)` | `table` (regular files in `path`) \| `(nil, err)` |
| `babet.find(path, opts)` | iterator function, see below |
| `babet.createFileIterator(path)` | iterator function over directory entries |

`find` accepts `opts` :

- `pattern = "*.lua"` — shell glob applied to file name only.
- `recursive = true` — descend into sub-directories.
- `type = "f"` / `"d"` — restrict to files or dirs.
- `max_depth = N` — limit recursion depth.

## API — Copy

| Function | Returns |
| --- | --- |
| `babet.copy(src, dst, opts?)` | `(true, nil)` \| `(nil, err)` |
| `babet.copyTree(src, dst, opts?)` | `(true, nil)` \| `(nil, err)` — recursive |
| `babet.moveTree(src, dst)` | `(true, nil)` \| `(nil, err)` |

`copy` options :

- `preserve = true` — keep mtime, mode, owner where possible.
- `overwrite = true` — replace destination if it exists.

## API — Hashes and checksums

Hash digests of file contents. Result is **lowercase hex string**
unless noted. Note the `sum` suffix — these are the registered
names in `babet.*`.

| Function | Algorithm | Notes |
| --- | --- | --- |
| `babet.crc32sum(path)` | CRC-32 (IEEE 802.3) | **Not cryptographic**. For integrity / accidental-error detection only. |
| `babet.md5sum(path)` | MD5 | Legacy. Don't use for security. |
| `babet.sha1sum(path)` | SHA-1 | Legacy. Don't use for security. |
| `babet.sha256sum(path)` | SHA-256 | |
| `babet.sha384sum(path)` | SHA-384 | |
| `babet.sha512sum(path)` | SHA-512 | |
| `babet.sha3_256sum(path)` | SHA3-256 | |
| `babet.sha3_384sum(path)` | SHA3-384 | |
| `babet.sha3_512sum(path)` | SHA3-512 | |
| `babet.blake2b512sum(path)` | BLAKE2b-512 | |

Each returns `string` (hex) or `(nil, err)`. The file is streamed,
not loaded entirely into RAM. Non-regular files (directories,
sockets, …) are rejected with `(nil, "<algo>: not a regular file")`.

MD5 and SHA-1 are exposed for compatibility (Git, legacy systems)
— don't use them for new cryptographic uses. **CRC-32 is even
further from cryptographic**: an attacker can produce collisions
trivially. Use it for integrity / change detection, never for
authentication.

## API — In-memory checksums

Compute a hash of bytes already in memory, without round-tripping
through a temporary file. Binary-safe (embedded NULs are allowed).

| Function | Returns |
| --- | --- |
| `babet.crc32(data)` | `string` — 8-char lowercase hex |

Cannot fail at runtime (pure computation). Wrong argument types
raise via `luaL_error`. As with `crc32sum`, **not cryptographic**.

## Quick examples

```lua
-- Predicates
if babet.isdir("/etc") and babet.fileExists("/etc/hostname") then
    print("size:", babet.fileSize("/etc/hostname"))
end

-- Path manipulation (pure string ops)
local base = babet.getBasename("/var/log/syslog.1")  -- "syslog.1"
local dir  = babet.getPath("/var/log/syslog.1")      -- "/var/log"
local ext  = babet.getExtension("/var/log/syslog.1") -- ".1"

-- Recursive listing
for entry in babet.find("/var/log",
        { pattern = "*.log", type = "f", recursive = true }) do
    print(entry)
end

-- Copy with attributes
babet.copyTree("./src", "/tmp/backup",
                  { preserve = true, overwrite = true })

-- Hash a release tarball
local sha, err = babet.sha256sum("/tmp/babet-1.7.0.tar.gz")
if sha then print("SHA256:", sha) end

-- Quick integrity check (NOT cryptographic, but fast)
local crc = babet.crc32sum("/tmp/babet-1.7.0.tar.gz")
print("CRC32:", crc)                 -- e.g. "a1b2c3d4"

-- In-memory CRC32 of arbitrary bytes (binary-safe, NULs OK)
print(babet.crc32("abc"))         -- "352441c2"
print(babet.crc32(""))            -- "00000000"

-- Set ownership and permissions
local mode_755 = tonumber("755", 8)  -- octal -> integer
assert(babet.setMode("/srv/myapp/run.sh", mode_755))
-- root only:
-- assert(babet.setAttributes("/srv/myapp", 1000, 1000))
```

## Error contract

- All functions follow the `(nil, err)` convention on runtime
  failure (no such file, permission denied, etc.).
- Wrong argument **types** raise via `luaL_error`.
- **`setAttributes(path, uid, gid)`** rejects negative UIDs/GIDs
  and values above `uid_t`/`gid_t` max (typically `2^32 - 1`).
  Without that upper-bound check, a value above the limit would
  truncate silently — worst case to UID 0 (root). Same logic as
  the [`user`](user.md) module.
- Path safety : `copy`, `copyTree`, `moveTree` use
  `lexically_relative()` and component-wise `is_within()` guards
  to prevent symlink-based escapes out of the destination tree.
  See [`security`](../security.md).

## Design decisions

- **Flat namespace** : `fileExists` instead of `fs.exists`,
  `getAttributes` instead of `fs.attr.get`. Pure historical
  reason — these functions predate the per-module convention.
  Stable now ; renaming would break every script.
- **`get*` / `set*` for path attributes** (`getMode`/`setMode`,
  `getAttributes`/`setAttributes`) but plain verbs for FS
  actions (`remove`, `touch`, `mkdir`). The "get/set" pairs
  exist because both directions are needed ; the others are
  single-direction operations.
- **Path manipulation is separate from FS access**.
  `getBasename`, `getPath`, etc. operate on strings only — they
  don't stat the path. Use `fileExists` if you need to know
  whether the path actually exists.
- **Hashes have a `sum` suffix** to match the standard Unix
  tools (`md5sum`, `sha256sum`, etc.). Discoverable for anyone
  familiar with the command line.
- **`copy` is single-file, `copyTree` is recursive**. Lua doesn't
  have function overloading by type, so splitting them avoids the
  ambiguity "did `copy('dir', 'dir')` mean recursive or not ?".

## Not in v1

- Glob matching as a standalone function (`babet.glob`). Use
  `find` with `pattern = "*.lua"` for the common case.
- Async I/O. Use [`workers`](workers.md) for parallel file
  processing instead.
- BLAKE2s (only BLAKE2b-512 is exposed via OpenSSL EVP).
