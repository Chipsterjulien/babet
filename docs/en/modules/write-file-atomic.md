> **English** | [Français](../../fr/modules/write-file-atomic.md)

# `writeFileAtomic` — atomic and durable file writing

`babet.writeFileAtomic()` publishes a binary Lua string to a regular file
without exposing partially written content under the final name. Data is first
written to a private same-directory temporary file, final permissions are
applied, then the temporary file is published atomically.

It is intended for configuration, tokens, JSON state, small binary files, and
screenshots already held in memory. It does not replace streaming APIs such as
`babet.http.download()` for very large payloads.

## Contents

- [API](#write-atomic-api)
- [Defaults](#write-atomic-defaults)
- [Basic write](#write-atomic-basic)
- [Explicit replacement](#write-atomic-overwrite)
- [Permissions](#write-atomic-permissions)
- [Durability](#write-atomic-durable)
- [Binary data](#write-atomic-binary)
- [Paths and symbolic links](#write-atomic-paths)
- [Atomicity and concurrency](#write-atomic-concurrency)
- [Using it in a worker](#write-atomic-worker)
- [Combined Selenium example](#write-atomic-selenium)
- [Error contract](#write-atomic-errors)
- [Limitations](#write-atomic-limits)

<a id="write-atomic-api"></a>
## API

```lua
local ok, err = babet.writeFileAtomic(path, data, opts?)
```

| Argument | Type | Purpose |
| --- | --- | --- |
| `path` | string | relative or absolute destination, with no NUL byte |
| `data` | string | complete binary content; embedded NUL bytes are allowed |
| `opts` | table or `nil` | strict options |

Results:

- success: `true, nil`;
- filesystem or publication failure: `nil, err`;
- bad arity, bad type, or unknown option: raised Lua error.

<a id="write-atomic-defaults"></a>
## Defaults

```lua
{
    overwrite = false,
    permissions = tonumber("644", 8),
    durable = true,
}
```

| Option | Default | Effect |
| --- | --- | --- |
| `overwrite` | `false` | rejects an existing destination |
| `permissions` | `0644` | exact permissions for the new final file |
| `durable` | `true` | synchronizes the temporary file and parent directory |

Unknown and non-string keys are rejected. Booleans are not coerced from `0`,
`1`, or strings. `permissions` must be an integer from `0` through `0777`.

<a id="write-atomic-basic"></a>
## Basic write

```lua
local ok, err = babet.writeFileAtomic("state.json", [[{"ready":true}]])
assert(ok, err)
```

The destination becomes visible only after the temporary file is complete. If
`state.json` already exists, the call fails and preserves its contents.

Parent directories are not created automatically:

```lua
assert(babet.mkdir("runtime"))
assert(babet.writeFileAtomic("runtime/state.json", "{}"))
```

<a id="write-atomic-overwrite"></a>
## Explicit replacement

```lua
local ok, err = babet.writeFileAtomic("state.json", new_state, {
    overwrite = true,
})
assert(ok, err)
```

With `overwrite = true`:

- an absent destination is created;
- an existing regular file is replaced by a same-directory rename;
- a symbolic link, directory, FIFO, socket, or device is rejected;
- the old file remains intact after any failure before publication.

Without overwrite, Babet uses a publication operation that atomically fails if
another task wins the race and creates the destination first.

<a id="write-atomic-permissions"></a>
## Permissions

```lua
local ok, err = babet.writeFileAtomic("token.bin", token, {
    permissions = tonumber("600", 8),
})
assert(ok, err)
```

The temporary file is always created with private mode `0600`, or more
restrictive because of the process umask. Before publication Babet applies the
requested permissions exactly using `fchmod()`. Setuid, setgid, and sticky bits
cannot be requested: the accepted range is `0000..0777`.

On replacement, the new file gets the requested permissions rather than those
of the previous file.

<a id="write-atomic-durable"></a>
## Durability

With default `durable = true`, the sequence is:

1. create a unique temporary file in the destination directory;
2. write all bytes while handling `EINTR` and partial writes;
3. apply final permissions;
4. `fsync()` the temporary file;
5. publish atomically;
6. `fsync()` the parent directory.

This aims to preserve the update after a crash, subject to filesystem and
hardware guarantees.

For a rebuildable cache where speed matters more:

```lua
local ok, err = babet.writeFileAtomic("cache/index.bin", cache, {
    overwrite = true,
    durable = false,
})
assert(ok, err)
```

`durable = false` retains atomic publication but does not confirm persistence
after a crash or power loss.

If publication succeeds and parent-directory synchronization then fails, the
call returns an explicit error stating that the destination has already been
published atomically but its persistence could not be confirmed.

<a id="write-atomic-binary"></a>
## Binary data

`data` is a binary Lua string. No UTF-8 validation is performed:

```lua
local payload = "\0\1\2PNG\255\254"
assert(babet.writeFileAtomic("capture.bin", payload))
```

An empty string creates a zero-length regular file.

All data must already be in memory. Prefer a streaming API for downloads or
transformations measured in gigabytes.

<a id="write-atomic-paths"></a>
## Paths and symbolic links

Paths may be relative or absolute. They are interpreted literally: there is no
`~`, `$HOME`, shell, or glob expansion.

To confine the write:

- every parent component is opened with `openat()` and `O_NOFOLLOW`;
- symlink parent components are rejected;
- `..` is rejected;
- a final symbolic link is rejected;
- missing parent directories are not created;
- the destination must be absent or a regular file when `overwrite = true`.

```lua
local ok, err = babet.writeFileAtomic("link/config.json", "{}", {
    overwrite = true,
})
assert(not ok)
print(err)
```

A process that can itself write the parent directory remains inside the same
trust boundary: POSIX has no portable conditional rename tied to one exact
inode. Babet never follows the final link and reinspects the destination
immediately before publication, but directory permissions remain the security
boundary against a hostile concurrent actor.

<a id="write-atomic-concurrency"></a>
## Atomicity and concurrency

Readers never observe a mixture of old and new data: they see one complete file
or the other.

With `overwrite = false`, several producers may attempt the same creation:

```lua
local ok, err = babet.writeFileAtomic("once.dat", value)
if not ok and err:find("already exists", 1, true) then
    -- Another producer won.
end
```

Exactly one call publishes the destination. Others fail without replacing it.

With `overwrite = true`, the last successful rename determines the final
contents. Ordering between concurrent writers is unspecified.

<a id="write-atomic-worker"></a>
## Using it in a worker

The function is available in every worker Lua state:

```lua
local job = assert(babet.workers.spawn([[
    local ok, err = babet.writeFileAtomic(worker.args.path, worker.args.data, {
        overwrite = true,
        permissions = tonumber("600", 8),
    })
    assert(ok, err)
    return true
]], {
    path = "runtime/result.bin",
    data = "worker-result",
}))

assert(job:join())
```

Values carried in `worker.args` remain subject to the workers JSON serializer.
A binary string containing NUL cannot therefore be passed directly through
`worker.args`; generate it in the worker, retain it as Base64, or read it from
another source.

<a id="write-atomic-selenium"></a>
## Combined Selenium example

Decode a WebDriver screenshot and publish it without a partial final file:

```lua
local png, err = babet.base64.decode(response.value, {
    max_output = 32 * 1024 * 1024,
})
assert(png, err)

assert(babet.mkdir("screenshots"))
local ok
ok, err = babet.writeFileAtomic("screenshots/latest.png", png, {
    overwrite = true,
    permissions = tonumber("640", 8),
    durable = true,
})
assert(ok, err)
```

Readers of `latest.png` see either the complete previous screenshot or the
complete new one, never a partially decoded or written image.

<a id="write-atomic-errors"></a>
## Error contract

Raised Lua errors:

```lua
babet.writeFileAtomic()                       -- arity
babet.writeFileAtomic(42, "data")             -- path is not a string
babet.writeFileAtomic("x", {})                -- data is not a string
babet.writeFileAtomic("x", "data", 42)        -- opts is not a table
babet.writeFileAtomic("x", "data", {
    permissions = "600",
})
babet.writeFileAtomic("x", "data", {
    unknown = true,
})
```

Failures returned as `nil, err` include:

- absent, inaccessible, symlink, or non-directory parent;
- existing destination without `overwrite`;
- final symlink or non-regular destination;
- temporary creation, write, `fchmod`, `fsync`, close, or publication failure;
- inability to allocate a unique temporary name.

After a failure before publication, the old destination remains intact and the
temporary file is removed on a best-effort basis.

<a id="write-atomic-limits"></a>
## Limitations

The first version does not provide:

- automatic parent-directory creation;
- append mode;
- input from an `io.file` object or numeric descriptor;
- a streaming API;
- application-level locking between writers;
- automatic rotation or size limits;
- atomic publication of several files as one transaction.

For multiple related files, publish a new version directory and switch an
application pointer, or use SQLite when a transaction is required.
