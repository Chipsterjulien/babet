> **English** | [Français](../../fr/modules/inotify.md)

# `babet.inotify` — filesystem watching

`babet.inotify` provides a small interface to Linux `inotify(7)`.
Notifications come from the kernel, so watched directories do not need to
be scanned periodically.

The module is **Linux-specific** and watching is not recursive.

## Module contents

- [API](#inotify-api)
- [Creating a watcher](#inotify-new)
- [Adding a watch](#inotify-add)
  - [`onlydir` option](#inotify-onlydir)
- [Reading events](#inotify-read)
  - [Queue overflow](#inotify-overflow)
  - [Signal interruption](#inotify-signal)
- [Removing and closing](#inotify-remove-close)
- [Example](#inotify-example)
- [Error contract](#inotify-errors)
- [Limits](#inotify-limits)

<a id="inotify-api"></a>
## API

| Function | Result |
| --- | --- |
| `babet.inotify.new()` | `watcher` \| `(nil, err)` |
| `w:add(path, events [, opts])` | integer `wd` \| `(nil, err)` |
| `w:read([timeout])` | event array \| `(nil, "timeout")` \| `(nil, "interrupted")` \| `(nil, err)` |
| `w:remove(wd)` | `(true, nil)` \| `(nil, err)` |
| `w:close()` | `(true, nil)` |

Signatures are strict: extra arguments raise a Lua error. `close()` is
idempotent, and garbage collection also closes a forgotten watcher.

<a id="inotify-new"></a>
## Creating a watcher

```lua
local watcher, err = babet.inotify.new()
if not watcher then
    error(err)
end
```

Each call creates an independent instance. The inotify descriptor uses
`IN_NONBLOCK` and `IN_CLOEXEC`: `read()` controls waiting itself, and the
descriptor is not inherited by programs launched through `exec`.

<a id="inotify-add"></a>
## Adding a watch

```lua
local wd, err = watcher:add(path, events [, opts])
```

`path` must be a string without an embedded NUL byte. It may refer to an
existing directory or file.

`events` is a strict, non-empty `1..N` array with no holes or extra keys.
Every element must be one of these names:

| Name | Requested event |
| --- | --- |
| `"access"` | file read or accessed |
| `"modify"` | content modified |
| `"attrib"` | attributes or metadata modified |
| `"close_write"` | write-open descriptor closed |
| `"close_nowrite"` | non-write descriptor closed |
| `"close"` | combination of `close_write` and `close_nowrite` |
| `"open"` | file opened |
| `"moved_from"` | entry moved out of the watched directory |
| `"moved_to"` | entry moved into the watched directory |
| `"move"` | combination of `moved_from` and `moved_to` |
| `"create"` | entry created in the watched directory |
| `"delete"` | entry deleted from the watched directory |
| `"delete_self"` | watched target deleted |
| `"move_self"` | watched target moved |

<a id="inotify-onlydir"></a>
### `onlydir` option

```lua
local wd = assert(watcher:add(path, { "create" }, {
    onlydir = true,
}))
```

When present, `onlydir` must be a boolean:

- `true` adds Linux's `IN_ONLYDIR` mask and therefore rejects a target
  that is not a directory;
- `false` keeps the normal behavior;
- other fields in `opts` are currently ignored.

Adding a watch again for the same target follows native inotify semantics:
the existing mask is replaced because `IN_MASK_ADD` is not used.

<a id="inotify-read"></a>
## Reading events

```lua
local events, err = watcher:read([timeout])
```

The timeout is in seconds and may be fractional:

- omitted or `nil`: wait indefinitely;
- `0`: non-blocking read of events already available;
- positive value: bounded wait.

A negative, NaN, infinite, or excessively large timeout returns
`(nil, err)`. A value of the wrong type raises a Lua error.

A successful read returns an array of tables:

```lua
{
    {
        wd = 1,
        name = "photo.jpg",
        events = { create = true, close_write = true },
        is_dir = false,
        cookie = 0,
    },
}
```

- `wd` is the watch descriptor returned by `add`;
- `name` is the affected entry name, or `""` for an event on the watched
  target itself;
- `events` contains a true boolean for every received bit;
- `is_dir` reflects `IN_ISDIR`;
- `cookie` pairs `moved_from` with `moved_to`; outside moves it is usually
  `0`.

Besides events requestable through `add`, the kernel may produce:

- `events.ignored` when a watch is removed, automatically or through
  `remove`;
- `events.unmount` when the watched filesystem is unmounted.

One call may return several events because the module reads and decodes a
whole batch from the kernel queue.

<a id="inotify-overflow"></a>
### Queue overflow

If the inotify queue overflows, events have been lost. The module surfaces
this explicitly:

```lua
{
    wd = -1,
    name = "",
    events = { overflow = true },
    is_dir = false,
    cookie = 0,
}
```

The program must then rescan watched paths to rebuild reliable state.

<a id="inotify-signal"></a>
### Signal interruption

If a signal handled by `babet.signal` arrives while waiting, its Lua
callback runs and `read()` then returns `(nil, "interrupted")`.

<a id="inotify-remove-close"></a>
## Removing and closing

```lua
assert(watcher:remove(wd))
assert(watcher:close())
```

After `remove(wd)`, the kernel normally queues an `ignored` event.
Removing an invalid descriptor returns `(nil, err)`.

After `close`, `add`, `read`, and `remove` return an error saying the
watcher is closed. `close` may be called more than once.

<a id="inotify-example"></a>
## Example

```lua
local watcher = assert(babet.inotify.new())
local wd = assert(watcher:add("/srv/incoming", {
    "close_write",
    "moved_to",
}, {
    onlydir = true,
}))

while true do
    local events, err = watcher:read()
    if not events then
        if err == "interrupted" then
            break
        end
        error(err)
    end

    for _, event in ipairs(events) do
        if event.events.overflow then
            rescan_directory()
        elseif event.wd == wd then
            process_entry(event.name)
        end
    end
end

watcher:close()
```

<a id="inotify-errors"></a>
## Error contract

- wrong argument count or type: Lua error;
- invalid value, system error, or closed watcher: `(nil, err)`;
- no event before the deadline: `(nil, "timeout")`;
- handled signal during `read`: `(nil, "interrupted")`;
- successful `remove` and `close`: `(true, nil)`.

System errors are prefixed with `"inotify: "` and retain the description
provided by the operating system.

<a id="inotify-limits"></a>
## Limits

- Linux only;
- no recursive watching;
- no `IN_DONT_FOLLOW`, `IN_ONESHOT`, or `IN_MASK_ADD`;
- one instance may hold several watches, and several independent instances
  may coexist in one process.
