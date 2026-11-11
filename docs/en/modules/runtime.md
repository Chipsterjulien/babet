# Launch context and resources

Available since Babet 2.35.0.

`babet.runtimeInfo()` returns `table, nil`. The table is an independent copy.

| Field | Script | Directory | Generated application |
| --- | --- | --- | --- |
| `mode` | `"file"` | `"directory"` | `"embedded"` |
| `projectDir` | absolute script directory | absolute project directory | `nil` |
| `scriptPath` | absolute script path | absolute `main.lua` path | `"main.lua"` |
| `executablePath` | runtime path | runtime path | application path |

Paths are captured at launch and do not follow working-directory changes. They
are location information, not proof of identity after renaming. Workers inherit
the context. C embedding hosts use `mode="host"` with unknown fields absent;
their workers may know the directory configured by the host.

## Embedded resources

- `babet.embedded.read(name)` → `bytes, nil` or `nil, error`.
- `babet.embedded.list()` → sorted names table and `nil`, or `nil, error`.

These APIs require an application created using `-c` / `--create-exe`; there is
no filesystem fallback. Names are case-sensitive, relative to the ZIP root,
and use `/`. Lists contain files, including `main.lua`, without directory
entries. Missing resources return `nil, error`. Reads preserve all bytes:
NUL, BOM, line endings and empty files. They use the actual running image via
`/proc/self/exe`, even after its path is replaced.

Limits: 16 MiB uncompressed per file; 16 MiB for all listed names, including
terminators. Packaging a large resource does not guarantee this API can read it.

```lua
local info = assert(babet.runtimeInfo())
local css
if info.mode == 'embedded' then
    css = assert(babet.embedded.read('assets/style.css'))
else
    local f = assert(io.open(info.projectDir .. '/assets/style.css', 'rb'))
    css = f:read('a')
    f:close()
end
```

## Strict globals

`babet.strict()` or `babet.strict(true)` raises an error when reading an absent
global. `babet.strict(false)` disables it. Returns `true, nil`, or `nil, error`
if `_G` has a foreign metatable, which is never overwritten. Global assignments
remain allowed; `nil` means absence. Use `rawget(_G, 'name')` for optional
lookups. Each Lua state must opt in, including workers. This does not check
other tables, analyze code statically or provide a security boundary. No new
CLI switch is introduced.

## Multiple returns and arity

Existing APIs retain strict arity. Lua forwards all results of a call used as
the last argument, so `f(babet.getPath(x))` may pass two arguments. Use
`f((babet.getPath(x)))` to pass only the first result. To handle errors, prefer
`local path, err = babet.getPath(x)`, check `path`, then call `f(path)`.
Extra `nil` arguments are not silently discarded.
