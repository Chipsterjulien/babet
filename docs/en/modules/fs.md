> **English** | [Français](../../fr/modules/fs.md)

# FS — files, directories, paths, searching, copying, permissions, and checksums

The functions in this chapter are exposed directly on the global `babet`
table. There is no `babet.fs` subtable: this flat namespace is historical and
is now part of the stable API.

The FS module covers:

- checking whether a path exists and what type it has;
- creating and removing files and directories;
- changing the current working directory;
- lexical path manipulation;
- listing, iterating, and recursively searching a tree;
- copying and moving directory trees;
- symbolic links;
- Unix permissions, owners, and groups;
- CRC-32, MD5, SHA, and BLAKE2 checksums.

## Module contents

- [General conventions](#fs-conventions)
- [API overview](#fs-api-summary)
- [Existence, type, and size](#fs-predicates)
  - [`fileExists`](#fileexists)
  - [`isFile` / `isfile`](#isfile)
  - [`isDir` / `isdir`](#isdir)
  - [`fileSize`](#filesize)
- [Current working directory](#fs-cwd)
  - [`currentDir`](#currentdir)
  - [`chdir`](#chdir)
- [Lexical path manipulation](#fs-paths)
  - [`getBasename`](#getbasename)
  - [`getFilename`](#getfilename)
  - [`getExtension`](#getextension)
  - [`getPath`](#getpath)
  - [`joinPath`](#joinpath)
- [Create, remove, rename, and link](#fs-actions)
  - [`touch`](#touch)
  - [`mkdir`](#mkdir)
  - [`remove`](#remove)
  - [`rmdir`](#rmdir)
  - [`rmdirAll`](#rmdirall)
  - [`rename`](#rename)
  - [`link`](#link)
- [List, iterate, and search](#fs-list-search)
  - [`listFiles`](#listfiles)
  - [`createFileIterator`](#createfileiterator)
  - [`find`](#find)
- [Copy and move](#fs-copy-move)
  - [`copy`](#copy)
  - [`copyTree`](#copytree)
  - [`moveTree`](#movetree)
- [Unix permissions and attributes](#fs-attributes)
  - [`getMode` / `setMode`](#getmode-setmode)
  - [`getAttributes` / `setAttributes`](#getattributes-setattributes)
  - [`symlinkAttr` / `symlinkattr`](#symlinkattr)
- [File checksums](#fs-checksums)
- [In-memory CRC-32](#crc32-memory)
- [Error contract](#fs-errors)
- [Design decisions and limitations](#fs-design)

<a id="fs-conventions"></a>
## General conventions

### Paths

Paths are Lua strings and may be relative or absolute.

Babet does not automatically perform:

- `~` expansion;
- variable expansion such as `$HOME`;
- glob expansion such as `*.lua`;
- general `.` and `..` normalization in lexical path helpers.

For example:

```lua
local home = assert(babet.env("HOME"))
local config = babet.joinPath(home, ".config", "my-app")
```

A NUL byte in a path is always rejected. Depending on the function, a bad
signature raises a Lua error, while a filesystem failure is generally returned
as `(nil, err)`.

### Symbolic links

There is no single symlink rule that applies to every function:

- `isFile`, `isDir`, `fileSize`, `getMode`, `getAttributes`, and checksum
  functions follow a valid link to its target;
- `remove` removes the link itself, including a dangling link;
- `rmdir` and `rmdirAll` reject a symlink root;
- `symlinkAttr` changes the owner and group of the link itself;
- `listFiles`, `createFileIterator`, and `find` do not recurse into a symlink
  to a directory;
- `copyTree` and `moveTree` reject a symlink source or destination root, but
  handle links found inside the tree.

Each function documents its exact behavior below.

### Result order

`listFiles`, `createFileIterator`, and `find` preserve the order supplied by
the filesystem. That order is not sorted and must not be treated as stable.

Sort explicitly when order matters:

```lua
local files = assert(babet.listFiles("documents", true))
table.sort(files)
```

### Return values

The most common convention is:

```lua
local value, err = function_name(...)
if not value then
    print(err)
end
```

A successful action generally returns `(true, nil)`. A few pure functions and
iterator methods use a different shape; those exceptions are called out in
their sections.

<a id="fs-api-summary"></a>
## API overview

### Check and inspect

| Function | Successful result |
| --- | --- |
| `babet.fileExists(path)` | `(boolean, nil)` — true only for a regular file |
| `babet.isFile(path)` | `(boolean, nil)` — same functional predicate as `fileExists` |
| `babet.isDir(path)` | `(boolean, nil)` — true for a directory |
| `babet.fileSize(path)` | `(integer, nil)` — regular-file size in bytes |
| `babet.currentDir()` | `(string, nil)` — current working directory |
| `babet.getMode(path)` | `(integer, nil)` — Unix mode `0000..07777` |
| `babet.getAttributes(path)` | `(table, nil)` — `{mode, owner, group}` |

### Manipulate paths

| Function | Successful result |
| --- | --- |
| `babet.getBasename(path)` | `(string, nil)` |
| `babet.getFilename(path)` | `(string, nil)` |
| `babet.getExtension(path)` | `(string, nil)` |
| `babet.getPath(path)` | `(string, nil)` |
| `babet.joinPath(a, b, ...)` | `string` |
| `babet.joinPath({a, b, ...})` | `string` |

### Act on the filesystem

| Function | Successful result |
| --- | --- |
| `babet.touch(path)` | `(true, nil)` |
| `babet.mkdir(path)` | `(true, nil)` — recursive and idempotent |
| `babet.remove(path)` | `(true, nil)` — regular file or symlink |
| `babet.rmdir(path)` | `(true, nil)` — real, empty directory |
| `babet.rmdirAll(path)` | `(true, nil)` — real directory, recursive removal |
| `babet.rename(source, destination)` | `(true, nil)` |
| `babet.link(target, linkpath)` | `(true, nil)` — creates a symlink |
| `babet.chdir(path)` | `(true, nil)` |

### List and search

| Function | Successful result |
| --- | --- |
| `babet.listFiles(path, recursive?)` | `(table, nil)` |
| `babet.createFileIterator(path, recursive?)` | `(iterator, nil)` |
| `babet.find(path, opts?)` | `(table, nil)` |

### Copy and move

| Function | Successful result |
| --- | --- |
| `babet.copy(source, destination)` | `(true, nil)` — one file |
| `babet.copyTree(source, destination, continue_on_error?)` | `(true, nil)` — one tree |
| `babet.moveTree(source, destination)` | `(true, nil)` — one tree |

### Change attributes

| Function | Successful result |
| --- | --- |
| `babet.setMode(path, mode)` | `(true, nil)` |
| `babet.setAttributes(path, uid, gid, mode?)` | `(true, nil)` |
| `babet.symlinkAttr(path, uid, gid)` | `(true, nil)` |

<a id="fs-predicates"></a>
## Existence, type, and size

<a id="fileexists"></a>
### `babet.fileExists(path)`

Checks whether `path` designates a **regular file**.

```lua
local exists, err = babet.fileExists("report.txt")
```

Results:

- regular file: `(true, nil)`;
- directory, dangling link, or missing path: `(false, nil)`;
- valid link to a regular file: `(true, nil)`;
- genuine inspection error: `(nil, err)`.

Despite its historical name, `fileExists` is not true for every kind of path.
Use `isDir` for a directory.

```lua
local is_file = assert(babet.fileExists("archive.tar"))
local is_dir  = assert(babet.isDir("backups"))
```

<a id="isfile"></a>
### `babet.isFile(path)` and `babet.isfile(path)`

`isFile` is the canonical name. `isfile` is a deprecated compatibility alias.

It tests the same kind of path as `fileExists`: a regular file, following a
valid symlink if present.

```lua
local regular, err = babet.isFile("program.lua")
if err then
    print("Cannot inspect path:", err)
elseif regular then
    print("This is a regular file")
end
```

A missing path returns `(false, nil)`, not an error.

<a id="isdir"></a>
### `babet.isDir(path)` and `babet.isdir(path)`

`isDir` is the canonical name. `isdir` is a deprecated alias.

```lua
local directory, err = babet.isDir("assets")
```

Results:

- real directory: `(true, nil)`;
- valid link to a directory: `(true, nil)`;
- file, dangling link, or missing path: `(false, nil)`;
- access or inspection error: `(nil, err)`.

<a id="filesize"></a>
### `babet.fileSize(path)`

Returns the size of a regular file in bytes.

```lua
local size, err = babet.fileSize("video.mp4")
if not size then
    print("Cannot read size:", err)
else
    print(size, "bytes")
end
```

The function follows a valid symlink to a file. Directories and other file
types are rejected.

```lua
local size, err = babet.fileSize("documents")
-- size == nil; err says the path is not a regular file
```

<a id="fs-cwd"></a>
## Current working directory

<a id="currentdir"></a>
### `babet.currentDir()`

Returns the process current working directory.

```lua
local cwd, err = babet.currentDir()
assert(cwd, err)
print(cwd)
```

The result is the path supplied by the filesystem and is normally absolute.

<a id="chdir"></a>
### `babet.chdir(path)`

Changes the current working directory of the entire process.

```lua
local previous = assert(babet.currentDir())
assert(babet.chdir("/tmp"))
print(assert(babet.currentDir()))
assert(babet.chdir(previous))
```

The path is resolved to its canonical form: `.` and `..` components and
symlinks are resolved before changing directory.

The working directory is shared by all threads. Consequently, `chdir` is
permanently rejected after the first `babet.workers.spawn()`, even after that
worker has completed.

```lua
assert(babet.chdir("/srv/my-app")) -- do this before any spawn
local worker = assert(babet.workers.spawn("return true"))

local ok, err = babet.chdir("/tmp")
-- ok == nil; err explains that chdir is forbidden after workers.spawn
```

<a id="fs-paths"></a>
## Lexical path manipulation

These helpers only process strings. They do not check whether the path exists.

<a id="getbasename"></a>
### `babet.getBasename(path)`

Returns the last component, including its extension.

```lua
local name = assert(babet.getBasename("/var/log/app.log"))
print(name) -- app.log
```

A path with no usable last component, such as `/`, returns `(nil, err)`.

<a id="getfilename"></a>
### `babet.getFilename(path)`

Returns the last component without its final extension.

```lua
print(assert(babet.getFilename("report.tar.gz"))) -- report.tar
print(assert(babet.getFilename("README")))        -- README
```

<a id="getextension"></a>
### `babet.getExtension(path)`

Returns the final extension, including the dot.

```lua
print(assert(babet.getExtension("report.tar.gz"))) -- .gz
```

A name without an extension returns `(nil, err)`, not an empty string.

```lua
local ext, err = babet.getExtension("README")
-- ext == nil
```

<a id="getpath"></a>
### `babet.getPath(path)`

Returns the lexical parent directory.

```lua
print(assert(babet.getPath("/var/log/app.log"))) -- /var/log
```

A simple name with no parent component, such as `app.log`, returns `(nil, err)`
rather than `"."`.

<a id="joinpath"></a>
### `babet.joinPath(...)`

Two forms are accepted:

```lua
local path = babet.joinPath("var", "lib", "my-app", "data.db")
```

```lua
local path = babet.joinPath({ "var", "lib", "my-app", "data.db" })
```

At least two non-empty segments are required. On success, `joinPath` returns
**one value**, the joined string. On failure it returns `(nil, err)`.

The function only adjusts the `/` separator at segment boundaries:

```lua
print(babet.joinPath("/var/", "/log", "app.log"))
-- /var/log/app.log
```

It does not normalize `.` or `..`, and a later absolute-looking segment does
not reset the path:

```lua
print(babet.joinPath("base", "..", "other")) -- base/../other
print(babet.joinPath("base", "/other"))       -- base/other
```

Do not mix the table form with separate arguments. When the first argument is
a table, that table is the complete segment list.

<a id="fs-actions"></a>
## Create, remove, rename, and link

<a id="touch"></a>
### `babet.touch(path)`

Creates an empty file when the path does not exist, or updates the last-write
time of an existing path.

```lua
assert(babet.touch("cache/ready.flag"))
```

The parent directory must already exist; `touch` does not create it.

```lua
local ok, err = babet.touch("missing/nested/file.txt")
-- ok == nil if missing/nested does not exist
```

Create parents first when needed:

```lua
assert(babet.mkdir("cache/images"))
assert(babet.touch("cache/images/index.dat"))
```

For an existing path, the function updates its timestamp; like the Unix
`touch` command, it can therefore also touch a directory.

<a id="mkdir"></a>
### `babet.mkdir(path)`

Creates a directory with `mkdir -p` semantics:

- creation is **always recursive**;
- missing parents are created;
- calling it again on an existing directory succeeds;
- a file or another non-directory blocking the path returns `(nil, err)`.

```lua
assert(babet.mkdir("data/cache/images"))
-- creates data, data/cache, and data/cache/images as needed
```

```lua
assert(babet.mkdir("data/cache/images"))
-- also succeeds when the directory already exists
```

There is **no option to disable recursion**. To require an already-existing
parent, check it before calling `mkdir`:

```lua
local parent = "data/cache"
assert(babet.isDir(parent), "parent must already exist")
assert(babet.mkdir(babet.joinPath(parent, "images")))
```

New directories use mode `0777` filtered through the process umask. No source
directory mode is involved.

<a id="remove"></a>
### `babet.remove(path)`

Removes only:

- a regular file;
- a symbolic link, valid or dangling.

```lua
assert(babet.remove("temp.txt"))
```

```lua
-- the link is removed, not its target
assert(babet.link("important-file.txt", "shortcut"))
assert(babet.remove("shortcut"))
```

Directories, FIFOs, sockets, devices, and other special types are rejected.

```lua
local ok, err = babet.remove("my-directory")
-- ok == nil; use rmdir or rmdirAll
```

<a id="rmdir"></a>
### `babet.rmdir(path)`

Removes a **real empty directory**.

```lua
assert(babet.mkdir("empty-cache"))
assert(babet.rmdir("empty-cache"))
```

It rejects:

- a non-empty directory;
- a file;
- a symlink, even when it points to a directory;
- a missing path.

```lua
local ok, err = babet.rmdir("non-empty-directory")
```

<a id="rmdirall"></a>
### `babet.rmdirAll(path)`

Recursively removes a **real directory root** and all of its contents.

```lua
assert(babet.rmdirAll("temporary-build"))
```

The root must exist and be a real directory. A file or a symlink to a
directory is rejected.

Symlinks *inside* the removed directory are deleted as directory entries;
their external targets are not traversed.

```lua
local is_dir = babet.isDir("temporary-build")
if is_dir then
    assert(babet.rmdirAll("temporary-build"))
end
```

<a id="rename"></a>
### `babet.rename(source, destination)`

Renames or moves an entry on the same filesystem.

```lua
assert(babet.rename("old.txt", "new.txt"))
```

Files, directories, and symlinks are accepted, including dangling links. The
destination parent directory is not created.

On Linux, the function follows `rename(2)` semantics: an existing destination
may be replaced when the entry types are compatible. Crossing filesystems
fails; `rename` does not perform a copy-and-delete fallback.

```lua
local ok, err = babet.rename("/tmp/a.txt", "/other-mount/a.txt")
-- may fail with cross-device link
```

Use `moveTree` to move a directory tree with a cross-filesystem fallback.

<a id="link"></a>
### `babet.link(target, linkpath)`

Always creates a **symbolic link**, never a hard link.

The target is stored exactly as supplied:

```lua
assert(babet.link("../shared/config.toml", "app/config.toml"))
```

A relative target stays relative, and a missing target is allowed:

```lua
assert(babet.link("future-file.txt", "dangling-link"))
```

Unlike `touch` and `copy`, `link` recursively creates explicit parent
directories of `linkpath`:

```lua
assert(babet.link("../../data.db", "a/b/c/database"))
-- creates a/, a/b/, and a/b/c/ as needed
```

The link path must not already be occupied.

<a id="fs-list-search"></a>
## List, iterate, and search

The three APIs do not return paths in the same form:

| Function | Returned path form |
| --- | --- |
| `listFiles(root, ...)` | relative to `root` |
| `createFileIterator(root, ...)` | as produced from `root`: prefixed by the supplied root path |
| `find(root, ...)` | as produced from `root`: prefixed by the supplied root path |

<a id="listfiles"></a>
### `babet.listFiles(path, recursive?)`

Returns an array containing regular files only. Directories are never included.

#### Non-recursive listing — the default

```lua
local files, err = babet.listFiles("assets")
assert(files, err)

for _, relative_path in ipairs(files) do
    print(relative_path)
end
```

Only files directly contained in `assets` are returned.

#### Recursive listing

```lua
local files, err = babet.listFiles("assets", true)
assert(files, err)

table.sort(files)
for _, relative_path in ipairs(files) do
    print(relative_path)
end
```

Paths are relative to the requested root:

```text
logo.png
icons/open.png
icons/close.png
```

not:

```text
assets/logo.png
assets/icons/open.png
```

#### Symlinks

- a valid symlink to a regular file is included under the link name;
- a dangling link is skipped;
- a symlink to a directory is neither included as a file nor traversed;
- directory-symlink loops therefore cannot cause infinite recursion.

```lua
local files = assert(babet.listFiles("collection", true))
-- collection/external -> /other/directory is not followed
```

The second argument is optional and defaults to `false`.

<a id="createfileiterator"></a>
### `babet.createFileIterator(path, recursive?)`

Creates a userdata with two methods:

- `iterator:next()` — next path, or `nil` at end;
- `iterator:close()` — explicitly releases the iterator.

#### Non-recursive

```lua
local iterator, err = babet.createFileIterator("assets")
assert(iterator, err)

while true do
    local path = iterator:next()
    if path == nil then
        break
    end
    print(path) -- assets/logo.png, etc.
end

iterator:close()
```

#### Recursive

```lua
local iterator = assert(babet.createFileIterator("assets", true))
while true do
    local path = iterator:next()
    if not path then break end
    print(path)
end
iterator:close()
```

Despite its name, the current implementation builds the complete list during
`createFileIterator`. Access and traversal failures are therefore returned at
creation time, before the first `next()` call.

Symlink behavior:

- valid link to a regular file: included under the link path;
- dangling link, loop, or inaccessible target: skipped;
- link to a directory: not traversed;
- genuine entry-inspection or traversal-increment error: creation fails with
  `(nil, err)`.

Calling `next()` after `close()` raises a Lua error. Omitting `close()` is not
fatal: the garbage collector eventually releases the object.

<a id="find"></a>
### `babet.find(path, opts?)`

Recursively searches the entries of a directory and returns an array of paths.

These calls are equivalent:

```lua
local entries = assert(babet.find("src"))
local entries = assert(babet.find("src", nil))
```

Without options, both files **and** directories are included. The root itself
is not included.

#### Options

| Option | Type | Default | Effect |
| --- | --- | --- | --- |
| `type` | string | no filter | `"f"` for files, `"d"` for directories |
| `name` | string | absent | ECMAScript regex on basename, case-sensitive |
| `iname` | string | absent | ECMAScript regex on basename, case-insensitive |
| `path` | string | absent | ECMAScript regex searched in the full path |
| `mindepth` | integer | `0` | minimum included depth |
| `maxdepth` | integer | practically unlimited | maximum included depth |

All supplied options are combined with logical **AND**.

#### Find files by extension

`name` matches the complete basename rather than searching for a substring:

```lua
local lua_files = assert(babet.find("src", {
    type = "f",
    name = ".*\\.lua$",
}))
```

#### Case-insensitive search

```lua
local images = assert(babet.find("assets", {
    type = "f",
    iname = ".*\\.(png|jpg|jpeg)$",
}))
```

#### Filter the full path

`path` searches within the complete path:

```lua
local tests = assert(babet.find(".", {
    type = "f",
    path = "/tests/",
}))
```

#### Limit depth

Depth `0` is the root’s immediate children:

```lua
local direct_children = assert(babet.find("src", {
    maxdepth = 0,
}))
```

Children of a subdirectory are at depth `1`:

```lua
local one_level_below = assert(babet.find("src", {
    mindepth = 1,
    maxdepth = 1,
}))
```

`mindepth` filters results only; shallower directories are still traversed to
reach requested depths.

#### Symlinks and errors

Traversal does not recurse into directory symlinks. Type checks do follow a
valid target, however: a symlink to a file may match `type = "f"`, and a
symlink to a directory may appear with `type = "d"` without its contents being
traversed.

An invalid regex or traversal error fails the entire call with `(nil, err)`.
There is no “continue after errors” mode for `find`.

<a id="fs-copy-move"></a>
## Copy and move

<a id="copy"></a>
### `babet.copy(source, destination)`

Copies one file using `std::filesystem::copy_file` and overwrites an existing
file destination.

```lua
assert(babet.copy("config/default.toml", "config/local.toml"))
```

The destination parent directory must already exist:

```lua
assert(babet.mkdir("backup/config"))
assert(babet.copy("config/app.toml", "backup/config/app.toml"))
```

Important behavior:

- a valid source symlink is followed and produces a new regular file;
- a valid destination symlink is followed: the link target is overwritten;
- source and destination directories are rejected;
- ordinary source permissions are copied according to filesystem semantics;
  owner, group, and timestamps are not guaranteed;
- this operation does not use `copyTree`’s hardened destination confinement.

Use `copyTree` for a tree or when destination symlink redirection must be
prevented.

<a id="copytree"></a>
### `babet.copyTree(source, destination, continue_on_error?)`

Recursively copies a source directory to a destination directory.

```lua
assert(babet.copyTree("site", "backup/site"))
```

#### Default value of `continue_on_error`

The optional third argument defaults to **`true`**.

For an error limited to one entry:

1. a warning is written to `stderr`;
2. copying continues with other entries when possible;
3. the final call returns `(nil, "completed with warnings ...")`.

A partial success is therefore never reported as a full success.

```lua
local ok, err = babet.copyTree("source", "destination")
if not ok then
    print(err) -- may report warnings after a partial copy
end
```

#### Strict mode

Pass `false` explicitly to stop at the first error:

```lua
local ok, err = babet.copyTree("source", "destination", false)
assert(ok, err)
```

Pass `true` explicitly when you want the continuation choice to be visible:

```lua
local ok, err = babet.copyTree("source", "destination", true)
```

#### Destination and merging

- the destination is recursively created when absent;
- existing destinations are merged;
- existing regular files are replaced;
- a pre-existing destination symlink, either as an intermediate component or
  final file, is rejected;
- the destination cannot be inside the source;
- source and destination roots must not be symlinks.

#### Metadata

When a new file is created:

- ordinary source `rwx` bits are preserved;
- setuid, setgid, and sticky bits are removed;
- the new inode’s owner and group are determined by the system for the caller;
- timestamps are not preserved.

Created directories use `0777` filtered through the umask. Source directory
mode, owner, group, and timestamps are not reproduced.

#### Internal symlinks

Links inside the source tree are recreated:

- relative targets stay unchanged;
- dangling links stay dangling;
- an absolute target inside the source is rewritten to its corresponding
  destination path;
- an absolute external target stays unchanged.

Directory symlinks are never traversed as directories.

<a id="movetree"></a>
### `babet.moveTree(source, destination)`

Recursively moves a directory tree.

```lua
assert(babet.moveTree("staging/site", "public/site"))
```

#### Fast path

When the destination does not exist, the move remains on one filesystem, and
no internal absolute link needs rewriting, Babet renames the whole tree. This
is fast and preserves inodes and their metadata.

#### Merge or cross-filesystem fallback

When the destination exists, the move crosses a filesystem, or an internal
link needs rewriting, Babet uses an entry-by-entry fallback:

- scan the complete source before the first modification;
- create destination directories;
- create destination symlinks;
- move other entries;
- remove the residual source tree.

In this fallback, a file copied to a new inode preserves ordinary `rwx` bits
but not special bits, owner, group, or timestamps. Created directories follow
the umask.

#### Safety checks

- source must be a real directory, not a symlink;
- destination root must not be a symlink;
- destination cannot be inside source;
- a pre-existing symlink in a merge destination is rejected;
- internal links use the same rewriting rules as `copyTree`.

`moveTree` reduces partial-state risk by scanning first and preparing symlinks
before moving files. It is not a general transaction, however: an error after
several file moves may leave some entries in the source and others in the
destination. Such an error requires checking both trees manually.

<a id="fs-attributes"></a>
## Unix permissions and attributes

Modes are integers. Lua has no `0o755` literal; use an octal string where the
API accepts it, or `tonumber("755", 8)`.

```lua
local mode_755 = tonumber("755", 8)
```

<a id="getmode-setmode"></a>
### `babet.getMode(path)` and `babet.setMode(path, mode)`

`getMode` returns ordinary permissions and special bits in the range
`0000..07777`.

```lua
local mode, err = babet.getMode("run.sh")
assert(mode, err)
print(string.format("%04o", mode))
```

`setMode` accepts two forms:

```lua
assert(babet.setMode("run.sh", "755"))
```

```lua
assert(babet.setMode("run.sh", tonumber("755", 8)))
```

A string is interpreted in base 8. A number is taken as the direct integer
value. Non-integers, negative values, and values above `07777` are rejected.

Special bits may be requested explicitly:

```lua
assert(babet.setMode("tool", "4755"))
local mode = assert(babet.getMode("tool"))
assert(mode == tonumber("4755", 8))
```

Both functions follow a symlink to its target.

<a id="getattributes-setattributes"></a>
### `babet.getAttributes(path)`

Returns exactly these three fields:

```lua
local attrs, err = babet.getAttributes("file.txt")
assert(attrs, err)

print(attrs.mode)  -- integer 0000..07777
print(attrs.owner) -- UID
print(attrs.group) -- GID
```

The table contains no size, mtime, or file type.

The function follows a symlink to its target.

### `babet.setAttributes(path, uid, gid, mode?)`

Changes owner and group, then optionally the mode.

Without a mode:

```lua
local attrs = assert(babet.getAttributes("file.txt"))
assert(babet.setAttributes(
    "file.txt",
    attrs.owner,
    attrs.group
))
```

With a mode:

```lua
assert(babet.setAttributes(
    "file.txt",
    1000,
    1000,
    tonumber("640", 8)
))
```

Unlike `setMode`, the fourth argument must be an **integer**; a string such as
`"640"` is not accepted.

Validation before mutation:

- UID and GID must be non-negative integers in the `uid_t` and `gid_t` range;
- mode must be between `0` and `07777`.

POSIX provides no atomic operation combining `chown` and `chmod`. If `chmod`
fails after a successful `chown`, Babet attempts to restore the original
owner, group, and mode. An incomplete rollback is reported in the error.

The call follows symlinks. Required privileges depend on the system and
process identity; changing owner normally requires root privileges.

<a id="symlinkattr"></a>
### `babet.symlinkAttr(path, uid, gid)` and `babet.symlinkattr(...)`

`symlinkAttr` is the canonical name. `symlinkattr` is a deprecated alias.

The function uses `lchown` and therefore does not follow a symbolic link:

```lua
assert(babet.symlinkAttr("shortcut", 1000, 1000))
```

It changes the UID and GID of the link itself, not of its target. It does not
change mode.

UID and GID are validated as in `setAttributes`.

<a id="fs-checksums"></a>
## File checksums

All functions below stream the file and return lowercase hexadecimal text:

| Function | Algorithm | Hex length | Recommended use |
| --- | --- | ---: | --- |
| `babet.crc32sum(path)` | CRC-32 IEEE | 8 | accidental-error detection only |
| `babet.md5sum(path)` | MD5 | 32 | legacy compatibility, not security |
| `babet.sha1sum(path)` | SHA-1 | 40 | legacy compatibility, not security |
| `babet.sha256sum(path)` | SHA-256 | 64 | common cryptographic integrity |
| `babet.sha384sum(path)` | SHA-384 | 96 | cryptographic integrity |
| `babet.sha512sum(path)` | SHA-512 | 128 | cryptographic integrity |
| `babet.sha3_256sum(path)` | SHA3-256 | 64 | cryptographic integrity |
| `babet.sha3_384sum(path)` | SHA3-384 | 96 | cryptographic integrity |
| `babet.sha3_512sum(path)` | SHA3-512 | 128 | cryptographic integrity |
| `babet.blake2b512sum(path)` | BLAKE2b-512 | 128 | cryptographic integrity |
| `babet.blake2s256sum(path)` | BLAKE2s-256 | 64 | cryptographic integrity |

Example:

```lua
local digest, err = babet.sha256sum("release.tar.gz")
assert(digest, err)
print(digest)
```

Check against an expected value:

```lua
local expected = "..."
local actual = assert(babet.sha256sum("release.tar.gz"))
assert(actual == expected, "checksum mismatch")
```

Common contract:

- regular files only;
- a valid symlink to a regular file is followed;
- directories, FIFOs, sockets, devices, and non-regular pseudo-files are
  rejected;
- a read error returns `(nil, err)` and never a misleading digest of partial
  data;
- the complete content is not loaded into memory.

CRC-32, MD5, and SHA-1 must not authenticate data against an attacker. Prefer
SHA-256, SHA-3, or BLAKE2 for new integrity checks.

<a id="crc32-memory"></a>
## In-memory CRC-32

### `babet.crc32(data)`

Computes CRC-32 for a Lua string already in memory. Lua strings are
binary-safe, so embedded NUL bytes are accepted.

```lua
print(babet.crc32("abc")) -- 352441c2
print(babet.crc32(""))    -- 00000000
```

```lua
local bytes = "a\0b\0c"
local digest = babet.crc32(bytes)
```

On success this function returns one string, without a second `nil` value. A
bad argument count or type raises a Lua error.

<a id="fs-errors"></a>
## Error contract

### Raised Lua errors

A bad signature or incompatible type generally raises a Lua error:

```lua
babet.fileSize({})       -- Lua error
babet.mkdir("a", true)  -- Lua error: mkdir accepts exactly one argument
```

Paths containing a NUL byte are rejected before any system call.

### Returned errors

Filesystem failures are normally returned:

```lua
local ok, err = babet.remove("missing.txt")
if not ok then
    print(err)
end
```

The `fileExists`, `isFile`, and `isDir` predicates treat a simply missing path
as the normal result `(false, nil)`. A genuine inspection failure remains
`(nil, err)`.

### Partial operations

- `copyTree` in continuation mode may copy some entries and then return a
  summary error reporting warnings;
- `moveTree` may leave state split between source and destination when a late
  error occurs in its entry-by-entry fallback;
- `setAttributes` attempts rollback if `chmod` fails after `chown`, and
  explicitly reports an incomplete rollback.

<a id="fs-design"></a>
## Design decisions and limitations

- **Historical flat namespace**: `babet.fileExists`, not
  `babet.fs.fileExists`.
- **Canonical names**: `isFile`, `isDir`, and `symlinkAttr`. The `isfile`,
  `isdir`, and `symlinkattr` forms are deprecated.
- **`mkdir` is always recursive**: no non-recursive API variant exists.
- **`copy` for one file, `copyTree` for a tree**: no implicit overload based
  on source type.
- **No standalone glob**: use `find` with an ECMAScript regex.
- **No automatic sorting**: call `table.sort` when stable ordering matters.
- **No complete metadata preservation during copy**: regular file permission
  bits are handled, but owners, groups, timestamps, and directory modes are
  not preserved.
- **No asynchronous I/O**: use [workers](workers.md) to parallelize independent
  work.
