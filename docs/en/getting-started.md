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

Internally, Babet appends a ZIP to its own binary and reads `main.lua` and
packaged Lua modules from it. The target machine does not need a separate
Babet installation. Platform dependencies still apply; an application using
the [GUI](modules/gui.md) also requires GTK4 at runtime.
A generated application is a final artifact: invoking it with `--create-exe`
or `-c` is rejected before its
`main.lua` runs. Use the original Babet binary to create another executable.

**Module sources.** For a module that `require` has not already loaded,
`package.preload` is checked before the ZIP. The embedded loader searches
`name.lua`, then `name/init.lua`. If both entries are absent, the ordinary Lua
loaders remain active: `package.path` can supply a disk Lua module and
`package.cpath` a native module compatible with the Lua ABI. A read or compile
error in a module found in the ZIP stops loading; it does not trigger this disk
fallback. These rules also apply to workers in generated applications.

`package.loadlib` remains available to load a native library explicitly from
disk. This Lua API is distinct from the Babet plugin API, which remains
unavailable in generated applications. Packaging therefore does not guarantee
that all loading comes exclusively from the ZIP and does not create a
[sandbox](security.md). To distribute a self-contained application, include its
Lua modules in the packaged project and check its external resource or library
requirements.

Embedded `main.lua` and modules support the same initial UTF-8 BOM and `#`
comment/shebang line as disk-loaded Lua files, including in workers. Source
line numbers are preserved; Lua bytecode remains loadable with these prefixes.
Modules are read from the running executable's inode: replacing or deleting
its pathname does not mix the current application's modules with a new version.

Startup requires an accessible, readable `/proc/self/exe`. An image open or
read failure stops Babet with status 1 and a diagnostic; it does not turn a
generated application into the Babet CLI or builder.

The builder now writes a descriptor in its runtime copy identifying the output
as an application and recording the ZIP offset and size. Startup reads this
identity from the loaded image: incidental ZIP bytes in a bare runtime cannot
change its mode. An application with a truncated ZIP, extra trailing data,
unreadable payload or missing `main.lua` is rejected before processing arguments.

Rebuild applications with the new Babet binary to obtain this protection.
Existing executables retain their bundled runtime. Use `--create-exe`: manually
concatenating a ZIP to the new runtime no longer turns it into an application.
If desired, run `strip` on the bare runtime **before** packaging, then preserve
the generated application file.

Do not compress the runtime with UPX: this hides the descriptor in the file
and prevents `--create-exe` from working. `build_and_deploy.sh` now preserves
the built binary even when UPX is installed, and checks that it can create and
run a small application before replacing the installed Babet binary.
This check uses a temporary directory under `build/`, so it also works when
`TMPDIR` is mounted `noexec`. Installation prepares a file with mode `0755`
in the target directory, then replaces the target by atomic rename: an already
running Babet keeps its old binary and a failed copy leaves the previous
installation intact.

Each embedded Lua file (`*.lua`, including `main.lua` and `*/init.lua`) is
limited to **16 MiB uncompressed**, inclusive. Packaging rejects larger scripts
with their archive filename before publishing the executable and preserves any
previous output. The completed ZIP is checked too, covering source growth
during packaging. Non-Lua assets retain their existing size policy. The loader
also enforces the limit on altered archives carrying a valid descriptor.

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
babet --version    # babet 2.22.0
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
