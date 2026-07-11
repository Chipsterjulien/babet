> **English** | [Français](../../fr/modules/inotify.md)

# `babet.inotify` — filesystem event watching

Wraps Linux `inotify(7)` for instant filesystem event delivery —
no polling. Used for hot-reloading configuration, watching drop
directories, log tailing, file synchronisation triggers, etc.

## Why

Polling a directory with `listDir` every second is wasteful (CPU
+ inode lookups) and laggy. `inotify` is the kernel's
purpose-built mechanism : the kernel wakes your script only when
something actually changes, with sub-millisecond latency.

The Lua API exposes a minimal contract over a notoriously tricky
syscall. Queue overflow is surfaced explicitly (the only thing
worse than dropping events silently is not telling you about it).

## API

| Function | Returns |
| --- | --- |
| `babet.inotify.new()` | `watcher` (userdata) \| `(nil, err)` |
| `w:add(path, events)` | `integer` wd (watch descriptor) \| `(nil, err)` |
| `w:remove(wd)` | `(true, nil)` \| `(nil, err)` |
| `w:read(timeout?)` | `table` of events \| `(nil, "timeout")` \| `(nil, "interrupted")` \| `(nil, err)` |
| `w:close()` | `(true, nil)` — idempotent |

`read(timeout?)` : omitted = **blocks** until the next event ;
`0` = **non-blocking** (returns the already-pending events,
otherwise `(nil, "timeout")`) ; `t > 0` = waits at most `t`
seconds. Note : this convention diverges from `socket` where
`set_timeout(0)` means infinite — here, "give me what's there
right now" is the dominant use case.

### `events` argument

A strict 1..N array of event name strings. Acceptable names :

| Name | Triggered when |
| --- | --- |
| `"access"` | file accessed |
| `"modify"` | file content modified |
| `"attrib"` | metadata changed (perms, mtime, …) |
| `"close_write"` | file opened for writing is closed |
| `"close_nowrite"` | read-only fd closed |
| `"close"` | combined alias : `close_write` **or** `close_nowrite` |
| `"open"` | file opened |
| `"moved_from"` | file moved out of watched dir |
| `"moved_to"` | file moved into watched dir |
| `"move"` | combined alias : `moved_from` **or** `moved_to` |
| `"create"` | file/dir created in watched dir |
| `"delete"` | file/dir deleted from watched dir |
| `"delete_self"` | the watched path itself is deleted |
| `"move_self"` | the watched path is moved |

### Event returned by `read`

```lua
{
    wd     = 1,                  -- watch descriptor
    name   = "newfile.txt",      -- "" if the watched path itself is the target
    events = { create = true, close_write = true },
    is_dir = false,
    cookie = 0,                  -- non-zero pairs moved_from / moved_to
}
```

Special synthetic event for **queue overflow** :

```lua
{ wd = -1, events = { overflow = true } }
```

When you see this, the kernel queue ran out of space and some
events were lost. Re-scan the watched paths to recover state.

## Quick example

```lua
local w = assert(babet.inotify.new())
assert(w:add("/srv/incoming", { "close_write", "moved_to" }))

babet.signal.handle("TERM", function() w:close(); os.exit(0) end)

while true do
    local events, err = w:read()      -- blocks until something happens
    if not events then
        if err == "interrupted" then break end
        io.stderr:write("inotify: ", err, "\n"); break
    end
    for _, ev in ipairs(events) do
        if ev.events.overflow then
            rescan()                    -- queue overflowed, recover
        else
            handle_new_file("/srv/incoming/" .. ev.name)
        end
    end
end
```

## Error contract

- **`read(t)`** where `t` is NaN/Inf/negative → raises via
  `luaL_error`.
- **`add(path, events)`** with a non-list `events` table (sparse,
  extra keys, non-string elements) → `(nil, err)`.
- **`add` on a non-existent path** → `(nil, "no such file or
  directory")`.
- **`read`** :
  - `events` table on success.
  - `(nil, "timeout")` if timeout elapsed.
  - `(nil, "interrupted")` if a handled signal arrived.
  - `(nil, err)` on other errors.
- **Methods after `close`** → `(nil, "inotify: closed")`.

## Design decisions

- **Non-recursive in v1**. `inotify(7)` itself isn't recursive ;
  watching a tree means walking it and calling `add` on each
  sub-directory, then handling `create` events to extend the
  watch. That's a real design effort with subtleties (races
  between walking and event delivery, overflow handling) and
  worth a dedicated module if/when needed. Buildable in pure
  Lua on top.
- **Events list mandatory, no implicit "all"**. Watching
  everything floods the queue and forces every event to traverse
  Lua. Forcing the caller to pick events makes the cost visible.
- **Overflow surfaced explicitly**, never swallowed. The kernel
  has a finite queue (`/proc/sys/fs/inotify/max_queued_events`,
  default 16384). When it overflows, events are lost. The only
  appropriate action is to re-scan ; silently dropping the signal
  would defeat the entire reliability story.
- **`read()` is interruptible by signal**. A `read()` blocking
  forever ignoring `SIGTERM` is the classic graceful-shutdown
  bug. See [`signal`](signal.md).
- **`IN_CLOEXEC`** on the fd : not inherited by `exec`'d
  subprocesses, consistent with sockets.

## Not in v1

- Recursive watching. Add at the script level (walk + add) or
  wait for a `recursive = true` option.
- Multiple watchers per process. Doable today by creating
  multiple `inotify.new()` instances ; not a built-in registry.
- `IN_MASK_ADD` semantics (adding events to an existing watch).
  Currently `add(path, events)` replaces the mask. Rare need.
