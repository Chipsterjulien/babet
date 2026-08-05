> **English** | [Français](../fr/getting-started.md)

# Getting started

## Download

Prebuilt binaries for x86_64, aarch64 (RPi4), and armv6l (RPi0) are
available on the
[releases page](https://github.com/Chipsterjulien/babet/releases).

## Build from source

Babet vendors all its dependencies (Lua, OpenSSL, SQLite, miniz, libarchive, zlib,
XZ Utils/liblzma, bzip2/libbz2, Zstandard/libzstd, RE2, Abseil,
nlohmann/json, cpp-httplib, tomlplusplus), so the only prerequisites
on your system are :

- a C++23 compiler (recent GCC or Clang)
- CMake (≥ 3.22)
- `wget`, `unzip`, and `xz`

```sh
git clone https://github.com/Chipsterjulien/babet.git
cd babet
./build_local.sh        # downloads deps and compiles
                        # (~5 min on first run, faster afterwards)
./run_tests.sh          # offline harness — should finish with 0 FAIL
```

The build script downloads each dependency from a pinned upstream source,
verifies its SHA256, then compiles it statically. Several dependencies have an
explicit mirror or fallback URL. When a source has no mirror, the script prints
the exact archive name to place manually in `downloads/`; the same SHA256 check
still applies before extraction.

The resulting binary is at `test/babet`.

## Three ways to run a Lua script

Babet supports three launch modes :

### 1. Folder mode

Point the binary at a directory containing `main.lua` :

```sh
echo 'print("hello from Babet")' > main.lua
./test/babet .
```

`require("X")` in `main.lua` looks for `X.lua` in the same directory.

### 2. Embedded mode (single-file executable)

Package a script and its modules into a self-contained binary :

```sh
./test/babet --create-exe . myapp
./myapp        # runs main.lua from the embedded ZIP
```

Version-control metadata directories `.git`, `.svn`, and `.hg` are
automatically excluded at any depth.

Internally, Babet appends a ZIP to its own binary, and reads
`main.lua` (plus any `require`d module) from that ZIP at runtime.
The resulting `myapp` is fully self-contained — no Babet install
needed on the target machine, just glibc.

### 3. Embedded via PATH (folder + auto-detect)

If Babet is on `$PATH` and you `chmod +x main.lua` after adding
a shebang line :

```lua
#!/usr/bin/env babet
print("hello")
```

```sh
chmod +x main.lua
./main.lua
```

Babet uses the script's own directory as the folder, so
`require("helpers")` finds `helpers.lua` next to `main.lua`.

## Command-line invocation

In addition to the three launch modes above, Babet accepts a
few standard flags :

| Flag | Effect |
| --- | --- |
| `-h`, `--help` | Print the help text and exit `0`. |
| `-V`, `--version` | Print `babet <version>` and exit `0`. |
| `-c <dir> <out>`, `--create-exe <dir> <out>` | Create a self-contained executable named `<out>` by embedding `<dir>` (which must contain `main.lua`). |

Any other argument starting with `-` is treated as an **unknown
option** : Babet prints `Unknown option: ...` + a hint to use
`--help`, and exits `1` instead of trying to interpret it as a
directory name. Folders whose name legitimately starts with `-`
can still be passed via `./-dirname` (POSIX convention).

```sh
babet --version    # babet 2.16.0
babet --help       # full usage
babet --bogus      # Unknown option: --bogus
                      # Try 'babet --help' for more information.
```

The same version is also exposed to scripts as `babet.VERSION`
(plus `babet.VERSION_MAJOR` / `VERSION_MINOR` / `VERSION_PATCH`
as integers) — see [`sys`](modules/sys.md).

## First script

Once the binary is built, try this :

```lua
-- main.lua
print("Babet says hi")
print("PID:", babet.pid())
print("Host:", babet.hostname())

local r, err = babet.http.get("https://example.com/")
if r then
    print("Status:", r.status)
else
    print("HTTP failed:", err)
end
```

Run it with `./test/babet .` (or whichever mode you prefer).

## Where to look next

- Each module has its own page under [`modules/`](modules/).
- The [`user`](modules/user.md) module is a small, complete example
  of the documentation pattern used throughout — read it as the
  canonical reference.
- For date and duration utilities (ISO 8601 timestamps, human
  durations like `"5m"` or `"2h30m"`), see [`time`](modules/time.md)
  — the `babet.time.*` sub-table covers parsing and formatting.
- See [`security.md`](security.md) before exposing Babet scripts
  to anything that might receive untrusted input.
