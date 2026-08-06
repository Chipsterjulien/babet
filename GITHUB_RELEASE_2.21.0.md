# Babet 2.21.0 — filesystem-boundary confinement for `find`

Babet 2.21.0 adds the strict `xdev` option to `babet.find()` so a recursive
search can stay on the filesystem of its root without invoking an external
`find` process.

## Highlights

- `babet.find(path, { xdev = true })` records the root `st_dev` and does not
  descend into directories on another device.
- Foreign mount points remain visible and can still match type, regex, glob,
  path, and depth filters; only their descendants are pruned.
- The historical behavior is unchanged when `xdev` is omitted or false.
- `xdev` is a strict boolean and reports invalid values through the ordinary
  `(nil, err)` contract.
- A valid root-directory symlink uses the target filesystem, while directory
  symlinks encountered during traversal remain non-followed.
- An entry that vanishes during the xdev-specific inspection is skipped only
  for `ENOENT`, after pending recursion is cancelled so iterator advancement
  cannot reopen the vanished path; every other inspection error remains fatal.
- Main-state and worker-state behavior is identical.
- A real `/dev` → `/dev/pts` regression proves that the implementation crosses
  the boundary without `xdev`, prunes it with `xdev`, and still returns the
  mount point itself.
- A dedicated 15-contract preflight protects the implementation, integration
  tests, worker coverage, disappearance-race handling, and French/English
  documentation.

## Example

```lua
local logs = assert(babet.find("/srv/application", {
    xdev = true,
    type = "f",
    path_iglob = "**/*.log",
    maxdepth = 8,
}))
```

Linux device boundaries are identified through `st_dev`. The option prevents
recursion into another mounted filesystem; it does not hide the mount point
entry itself. As with `find -xdev`, a Btrfs subvolume may be pruned while a bind
mount of the same filesystem is not.

The disappearance tolerance belongs specifically to the extra `xdev`
inspection. The historical traversal without `xdev` may still fail if a
directory vanishes immediately before iterator descent; broadening that legacy
behavior is intentionally outside this release.
