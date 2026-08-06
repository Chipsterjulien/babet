# Babet 2.21.1 - robust `find` traversal on live trees

Babet 2.21.1 closes the remaining directory-disappearance race in
`babet.find()`, including searches that do not enable `xdev`.

## Highlights

- Replaces `recursive_directory_iterator` with an explicit stack of
  `directory_iterator` frames.
- Advances the parent iterator before opening a child, preserving later
  siblings if that child disappears.
- Skips only `ENOENT` disappearance races; every other traversal error remains
  fatal and returns `(nil, err)`.
- Preserves pre-order output, depth limits, type/regex/glob filters, symlink
  policy, root-symlink behavior, `xdev`, and worker semantics.
- Adds a deterministic `LD_PRELOAD` regression that deletes the selected child
  at the exact libstdc++ `openat` descent point.
- Adds a dedicated structural preflight and updates the French and English
  manuals and PDFs.

## Validation target

```text
ASan + UBSan       : 9/9 modes
Normal build       : 9/9 modes
Network smoke tests: 11 PASS / 0 FAIL / 0 WARN
```

The ordinary Lua API is unchanged:

```lua
local files = assert(babet.find("/tmp/build-tree", {
    type = "f",
    path_iglob = "**/*.log",
}))
```

When a directory disappears immediately before descent, the search now skips
that vanished subtree and continues with surviving siblings. This tolerance is
limited to `ENOENT`; permission, I/O, loop, and other errors still fail the
complete call.
