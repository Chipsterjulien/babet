> **English** | [Français](../../fr/modules/file-lock.md)

# lockFile — exclusive file locks

**Available since Babet 2.34.0.**
This API is not available in Babet 2.33.0 or earlier.

`babet.lockFile(path)` lets cooperating processes reserve a resource, such as
a data directory with one writer process. This Linux primitive requires no
GTK and is available in the runtime, workers and embedding. It uses
`flock(LOCK_EX | LOCK_NB)`, not POSIX `fcntl(F_SETLK)` locks.

## API

| Call | Result |
| --- | --- |
| `babet.lockFile(path)` | `handle, nil`, or `nil, "locked"` for contention, or `nil, message` for a system error |
| `handle:write(text)` | `true, nil` or `nil, message`; replaces the contents on the same inode |
| `handle:close()` | `true, nil` or `nil, message`; closing an already closed handle succeeds |

Every call returns exactly two values. Invalid arity/types, an empty path or
a path containing NUL raise a Lua error. `write` accepts binary strings,
including empty strings and NUL bytes. Writing to a closed handle fails.

The path must identify a regular file. If absent, Babet creates it with mode
`0600`, possibly reduced by umask. Acquiring an existing file preserves its
contents and permissions, including on contention. Symlinks to existing
files and hard links refer to the same lock. Dangling symlinks are rejected
without creating their target. Directories, FIFOs and devices are rejected
before opening them for I/O.

`lockFile` does not wait for a held lock to become available, though filesystem
operations may still block. A handle lasts until explicit close, `<close>`
scope exit, Lua garbage collection or Lua state destruction. Keep a reference,
preferably a `<close>` variable, throughout directory use. Leaving `gui.run()`
does not automatically close a file lock.

## One writer per directory

```lua
local directory = "/path/to/my-data"
local path = directory .. "/.basket.lock"
local lock, err = babet.lockFile(path)
if not lock then
    if err == "locked" then
        -- Reading a PID is optional: metadata may be empty, unreadable or
        -- being updated. The actual lock is authoritative.
        io.stderr:write("This directory is already open.\n")
    else
        io.stderr:write(tostring(err), "\n")
    end
    return
end
local guard <close> = lock
assert(lock:write(tostring(babet.pid()) .. "\n"))

-- Open the database and run the application only after acquisition.
-- Keep guard in scope during writes, backup/restore and database shutdown.
-- Multiple windows in this process may share this handle.
```

Babet writes no PID automatically. `write` lets the application set metadata
without reopening the file. Opening and closing a separate descriptor for
the same inode does not release this `flock` lock. A PID read from the file
is informational: it may be stale, absent, partial or reused. Never infer
lock availability from it or automatically kill that process.

**Keep the lock file permanently.** Never unlink, rename or replace it, even
after closing it. Exclude it from restore, cleanup and atomic replacement
operations. Otherwise two processes could lock distinct inodes under the
same filename. Different files have independent locks.

## Processes, workers and errors

- Descriptors use `O_CLOEXEC`, so an executed program cannot retain the lock.
  After libc `fork()`, a child handler closes inherited descriptors using
  `close()`, never `LOCK_UN`, and invalidates copied handles. The parent's
  lock remains active. The parent can resume before the handler, so temporary
  contention is possible until the handler runs. Raw fork syscalls and Lua
  execution after `vfork()` are outside this contract.
- Babet workers are threads with separate Lua states. Their independent lock
  attempts contend with the main thread. Closing a worker releases its own
  handles without releasing another state's handles.
- Process exit, including `kill -9`, releases its descriptors. The lock file
  and metadata remain on disk. Embedding releases handles on Lua state cleanup.
- A failed `write`, including a partial write, **keeps the lock held**.
  Interrupted calls and short writes are handled; truncation to the new size
  occurs after writing. Unlocked readers can see partial data. This is neither
  atomic publication nor durable storage (`fsync`): use it for lock metadata,
  not for saving application data.

`write` runs synchronously in its owning Lua state, without holding the
process-wide registry gate: other states can acquire locks and other threads
can fork during a slow write. Acquisition and close still take that gate to
synchronize descriptor registration with fork cleanup; slow filesystem calls
there can delay other acquisitions, closes and forks.

## Limits

This is an advisory lock: every writer must cooperate using the same file.
The contract targets local Linux filesystems; NFS/SMB semantics depend on the
server and mount. `locked` specifically means contention reported by `flock`;
permission failures and other errors have different diagnostics.

To validate an existing file without opening a device for I/O, Babet pins
the inode with `O_PATH`, then reopens it through `/proc/self/fd`. Accessible
procfs is therefore required, including in an embedding host. The application
must control the data directory and keep it from being replaced while in use.
