> **English** | [Français](README.fr.md)

<p align="center">
  <img src="docs/assets/babet-closed.png" alt="Babet — pine cone" width="200">
</p>

# Babet

> *Babet*, n.m. — regional word from south-eastern France
> (Lyonnais, Forez, Dauphiné, Savoie, and adjacent Swiss
> Romandy) for a pine cone. Small, light, packed with seeds,
> and good for starting a fire — like this binary.

A standalone Lua 5.5 binary for Linux scripting and automation, written
in C++23. Embeds OpenSSL, SQLite, miniz, libarchive, zlib, liblzma, libbz2,
libzstd, RE2, Abseil, nlohmann/json, cpp-httplib, and tomlplusplus
statically — one binary, no system dependencies beyond glibc.

Current release candidate: **2.22.2**. See the
[English changelog](CHANGELOG.md) or the
[French changelog](CHANGELOG.fr.md).

Babet 2.22.2 adds a native RFC 6455 WebSocket client through
`babet.websocket`. It supports `ws://` and verified `wss://`, strict Upgrade
validation, cryptographically random client masking, fragmented text/binary
messages, automatic Ping/Pong, bounded frame/message sizes, and a complete
closing handshake. The transport is generic and can be used directly by a
WebDriver BiDi binding.

Babet 2.21.1 hardens `babet.find()` on live directory trees. The traversal
now keeps an explicit stack of directory iterators, advances each parent before
opening a child, and treats only `ENOENT` disappearance races as local. A child
that vanishes no longer aborts the whole search or hides surviving siblings;
all other inspection and traversal errors remain fatal.

Babet 2.21.0 adds `xdev = true` to `babet.find()`. The traversal records
the root filesystem device, keeps foreign mount points visible, and prunes
their descendants without changing historical behavior when the option is
absent or false. The contract is identical in workers.

Babet 2.20.0 added pathname-based Unix-domain stream sockets with strict
validation, an exact final mode, global connect deadlines, inode-sensitive
listener cleanup, worker support, and the same binary-safe stream methods as
TCP.

The release also adds `db:backup(path, opts?)`, a synchronous SQLite backup
based on `sqlite3_backup`. It supports WAL sources, concurrent writes, one
global monotonic deadline, genuinely non-blocking attempts, and atomic
publication of a complete destination. Failures preserve an existing
destination and clean temporary files. Babet remains Linux-only.

Can be used in three modes:

1. **As a Lua interpreter** : `babet script.lua` or `babet folder/`
   (looks for `main.lua` inside).
2. **As a packager** : `babet --create-exe ./myproject app` produces a
   self-contained executable with the script and its `require`d modules
   embedded as a ZIP appended to the binary. A generated application is final:
   it refuses `--create-exe` / `-c`; use the original Babet binary to package
   another application.
3. **As a library of bindings** : Lua scripts get
   `babet.base64`, `babet.json`, `babet.http`, `babet.sqlite`,
   `babet.socket`, `babet.websocket`, `babet.inotify`, `babet.curses`, `babet.workers`,
   `babet.user`, `babet.exec`, `babet.writeFileAtomic`, the streaming
   `babet.spawn`,
   `babet.pipeline` / `babet.spawnPipeline`, secure ZIP and TAR handling through
   `babet.archive`, standalone gzip/xz/bzip2/zstd streams through
   `babet.compression`, direct-to-file `babet.http.download`, and more.

## Quick start

```sh
git clone https://github.com/Chipsterjulien/babet.git
cd babet
./build_local.sh        # downloads deps and compiles (~5 min first time)
./run_tests.sh          # offline harness — should finish with 0 FAIL
./test/babet --help
```

Every top-level `run_tests.sh` invocation also writes the complete color-free
output to `babet-tests.txt`, replacing the previous log.

The build script vendors and compiles all its dependencies. The only
prerequisites on your system are a C++23 compiler, CMake 3.22 or newer, `wget`, `unzip`,
and `xz`.

### Keep a recursive search on one filesystem

```lua
local entries = assert(babet.find("/srv", {
    xdev = true,
    type = "f",
    path_iglob = "**/*.log",
}))
```

A mount point belonging to another filesystem may still appear in the result,
but Babet does not descend into it. This matches the useful traversal contract
of `find -xdev` without invoking an external shell command. The decision is
based on `st_dev`: a Btrfs subvolume may be pruned, while a bind mount of the
same filesystem is not.

### Open SQLite with explicit connection policy

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
    foreign_keys = true,
}))

assert(db:exec("INSERT INTO jobs(name) VALUES(?)", { "index" }))
print(assert(db:last_insert_rowid()))
print(assert(db:changes()), assert(db:total_changes()))
```

Use `{ readonly = true }` for an existing database that must not be created or
written. Read-only handles remain compatible with `busy_timeout` and
`foreign_keys`, but deliberately reject `wal = true`. This only prevents a
journal-mode change request; an existing WAL database can still be opened
read-only when SQLite can use its companion files.

### Isolate a recoverable SQLite step with a savepoint

```lua
local ok, err = db:transaction(function(tx)
    assert(tx:exec("INSERT INTO jobs(name) VALUES(?)", { "required" }))

    local optional_ok = tx:savepoint(function(inner)
        assert(inner:exec(
            "INSERT INTO jobs(name) VALUES(?)", { "optional" }))
    end)

    if not optional_ok then
        -- Only the optional work was rolled back. The transaction continues.
    end
end, "immediate")

assert(ok, err)
```

A successful inner `RELEASE` never commits an outer transaction. A Lua error
in the callback rolls back only to the generated savepoint, removes it, and
returns `(nil, err)`.

### Back up SQLite without an inconsistent file copy

```lua
assert(db:backup("state-backup.db", {
    timeout = 10,
    pages_per_step = 64,
    sleep = 0.005,
}))
```

`db:backup()` uses `sqlite3_backup`, supports WAL sources, and atomically
publishes the destination only after a complete copy. Timeouts use one global
monotonic deadline, and failures leave no partial database. Use
`overwrite = true` only to explicitly replace a closed older backup.

### Download a large HTTP response without buffering it

```lua
assert(babet.mkdir("downloads"))
local result, err = babet.http.download(
    "https://example.com/archive.tar.gz",
    "downloads/archive.tar.gz",
    {
        timeout = 120,
        follow_redirects = true,
        max_file_size = 512 * 1024 * 1024,
    }
)
assert(result, err)
assert(result.saved, "HTTP " .. result.status)
```

The response is written to a same-directory temporary file and atomically
committed only for a final 2xx status. Existing destinations are preserved on
network, TLS, size, disk, and non-2xx failures.


### Encode or decode binary data as Base64

```lua
local source = "\0\1\2screenshot\255"
local encoded, err = babet.base64.encode(source, {
    url_safe = true,
    padding = false,
})
assert(encoded, err)

local decoded
decoded, err = babet.base64.decode(encoded, {
    url_safe = true,
    allow_unpadded = true,
    max_output = 32 * 1024 * 1024,
})
assert(decoded, err)
assert(decoded == source)
```

The module is binary-safe, imposes no UTF-8 requirement, and rejects mixed
alphabets, whitespace, misplaced padding, and non-canonical trailing bits by
default. It is also available inside workers.

### Atomically publish a configuration file

```lua
local ok, err = babet.writeFileAtomic("runtime/state.json", json_data, {
    overwrite = true,
    permissions = tonumber("600", 8),
})
assert(ok, err)
```

Content is written to a private same-directory temporary file and then
published atomically. Overwrite is disabled by default, symlink parents and a
final symlink are rejected, and durability is enabled by default.

### Wait for or cooperatively cancel a worker

```lua
local job = assert(babet.workers.spawn([[
    while not worker.cancelled() do
        local ok, command = worker.recv(0.1)
        if ok then process(command) end
    end
    return "cancelled"
]]))

local ok, result = job:join(0.05)
if ok == nil then
    assert(result == "timeout")
    assert(job:cancel())
    ok, result = job:join(2)
end
assert(ok, result)
```

`status()` observes `running`, `done`, or `error` without consuming the result.
A `join()` timeout leaves the job unchanged. `cancel()` deliberately remains
cooperative: it wakes `worker.recv()`, sets the flag read by
`worker.cancelled()`, also wakes the current channel wait without closing the
shared channel, and leaves the outbox available for a final message.


### Connect workers directly with shared channels

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
local results = assert(babet.workers.channel({ capacity = 16 }))

local producer = assert(babet.workers.spawn([[
    for i = 1, 10 do
        assert(worker.channels.tasks:send({ id = i, value = i * 10 }, 2))
    end
    return true
]], nil, { channels = { tasks = tasks } }))

local consumer = assert(babet.workers.spawn([[
    for _ = 1, 10 do
        local ok, task = worker.channels.tasks:recv(2)
        assert(ok, task)
        assert(worker.channels.results:send({
            id = task.id,
            result = task.value * 2,
        }, 2))
    end
    return true
]], nil, { channels = { tasks = tasks, results = results } }))

for _ = 1, 10 do
    local ok, result = results:recv(2)
    assert(ok, result)
    print(result.id, result.result)
end

assert(producer:join(2))
assert(consumer:join(2))
```

Producer-to-consumer messages do not pass through the parent. Channels are
FIFO, multi-producer, multi-consumer, and close with drainage of queued
messages.

### Compress or decompress a standalone stream

```lua
local ok, err = babet.compression.compress(
    "database.dump", "database.dump.zst", "zstd",
    { overwrite = true }
)
assert(ok, err)

ok, err = babet.compression.decompress(
    "database.dump.zst", "database.dump",
    { overwrite = true, max_output_size = 4 * 1024 * 1024 * 1024 }
)
assert(ok, err)
```

The decompressor detects gzip, xz, bzip2, or zstd from the stream bytes.
Sources and destinations must be regular files reached without symlink parent
components; output is staged in the destination directory and published
atomically. The default decompression ceiling is 1 GiB.

### Create, inspect, verify, and extract ZIP or TAR securely

```lua
local created, err = babet.archive.create("project", "project.zip", {
    compression_level = 9,
    overwrite = true,
})
assert(created, err)

local tar_created
tar_created, err = babet.archive.create("project", "project.tar")
assert(tar_created, err)
assert(tar_created.format == "tar")

local selected
selected, err = babet.archive.create({
    "bin/babet",
    "README.md",
    "docs",
}, "release.tar.zst", {
    include = { "babet", "README.md", "docs/**" },
    exclude = { "docs/drafts/**", "**/*.tmp" },
})
assert(selected, err)

local info, err = babet.archive.list("upload.zip", {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
    max_path_length = 8192,
    max_total_name_bytes = 2 * 1024 * 1024,
})
assert(info, err)
assert(info.duplicates == 0 and info.conflicts == 0)

local manifest
manifest, err = babet.archive.read("upload.zip", "manifest.json", {
    max_size = 1024 * 1024,
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
assert(manifest, err)

local verified
verified, err = babet.archive.test("upload.zip", {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
assert(verified, err)
assert(verified.files + verified.directories == verified.entries)

local tar_info
tar_info, err = babet.archive.list("source.tar.xz")
assert(tar_info, err)
assert(tar_info.format == "tar")
assert(tar_info.compression == "xz")

local plan
plan, err = babet.archive.extract("source.tar", "restore", {
    dry_run = true,
    include = { "src/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
    overwrite = true,
})
assert(plan, err)
assert(plan.would_create + plan.would_overwrite + plan.would_skip
    == plan.entries)
assert(not babet.fileExists("restore"))

local result
result, err = babet.archive.extract("source.tar", "restore", {
    include = { "src/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
    overwrite = false,
})
assert(result, err)

local one
one, err = babet.archive.extractFile(
    "source.tar", "docs/readme.txt", "readme.txt")
assert(one, err)
```

ZIP creation, listing, verification, and extraction continue to use miniz. Plain, gzip-,
xz-, bzip2-, and zstd-compressed TAR operations use the statically linked
libarchive, zlib, XZ Utils/liblzma, libbz2, and libzstd backends. Readers detect
format and compression from the contents; `archive.create()` infers TAR from
`.tar`, gzip TAR from `.tar.gz` or `.tgz`, xz TAR from `.tar.xz` or `.txz`,
bzip2 TAR from `.tar.bz2`, `.tbz2`, or `.tbz`, and zstd TAR from `.tar.zst`,
`.tar.zstd`, or `.tzst`. It accepts `format = "tar"`, `format = "tar.gz"`,
`format = "tar.xz"`, `format = "tar.bz2"`, or `format = "tar.zst"`.
The first argument may also be a dense list of unrelated regular files and
directories: each source is rooted at its final basename, collisions are
rejected, and list order does not affect deterministic output. Creation also
accepts bounded, case-sensitive `include` and `exclude` safe-glob arrays matched
against final archive paths; exclusions win and excluded directories are
pruned. Creation rejects selected source symlinks, unsupported filesystem
objects, unsafe entry names, and an output inside any source tree.
`archive.test()` fully reads verifiable data and rejects technically corrupt,
ambiguous, or unsafe archives without creating any file. `archive.extract()`
now reuses the exact same bounded `include` and `exclude` safe globs as
creation, matched against normalised internal paths; exclusions win, excluded
subtrees are pruned, and only required parents are created. Unselected entries
do not participate in output collisions, while global limits still apply to
the whole archive. Extraction still rejects selected absolute paths, `..`
components, archive links and special types, sparse TAR files, and symlinked
destination parents. Created archives are published atomically as a whole; retained extraction
files are staged before publication and published atomically per file. With
`dry_run = true`, the same plan, filters, limits, and destination checks run
without creation, writes, chmod, renames, or removals; the result reports
`would_create`, `would_overwrite`, `would_skip`, and whether the destination
root would be created. This preview is a snapshot and does not replace the
checks repeated by real extraction. Run `archive.test()` first when skipped ZIP
payload integrity must also be verified.
`archive.read()` loads one regular file into a binary Lua string with an 8 MiB
default memory limit and a 256 MiB hard ceiling. Selection uses either an exact
raw name or the one-based index exposed by `archive.list()`; a duplicated name
is rejected until an index explicitly disambiguates the occurrence. No name is
cleaned and no write occurs: an unsafe path may be read as data while remaining
reported as `list().entries[i].safe_path = false` and forbidden for extraction.

## Experimental C embedding / libbabet

Lot 6 introduces the first exercised host embedding boundary.  C and C++ hosts
can target the small C header [`include/babet/babet.h`](include/babet/babet.h)
and the in-tree static `libbabet.a` runtime produced by CMake. A normal build
also creates a relocatable static SDK under `build/embedding-sdk/` containing
only the public header, one flattened `libbabet.a` with Babet's pinned static
third-party libraries folded in, and a short linking note. An external C host
can therefore compile against that moved SDK without knowing the dependency
build tree; the final executable is linked with a C++ linker driver plus the
normal Linux system libraries (`-ldl -pthread -lm`, and `-latomic` on 32-bit).
The public surface is deliberately narrow and experimental: an opaque context,
create/search-root/run/error/destroy
lifecycle, version/status helpers, one active context per process, and
same-thread use. An explicit on-disk Lua search root can be configured once
before the first run; it feeds both the parent `package.path` and workers. A
small `babet_value` API also exchanges scalar globals (`nil`, boolean, signed
64-bit integer, double and binary string) without exposing `lua_State`, and can
call one Lua global function with scalar arguments and one scalar result.
Structured tables, host callbacks, dotted method lookup and multi-result calls
remain deferred. Lua/C++ internals are not public ABI.

The official `babet` executable still contains the runtime in its own binary;
it does **not** require a `libbabet.so` at runtime. Shared-library packaging and
multiple concurrent contexts remain deferred; Lot 6 intentionally validates the
static SDK path first. Process-wide Babet APIs
(`chdir`, environment, signals, children, terminal) remain real host-process
side effects rather than sandboxed state. The practical developer guide is [`EMBEDDING.md`](EMBEDDING.md), with small executable C examples under [`examples/embedding/`](examples/embedding/). The detailed architectural contract and rationale remain in [`EMBEDDING_DESIGN.md`](EMBEDDING_DESIGN.md).

Lot 7 deliberately keeps optional GUI support outside the CLI. Lot 9 now adds
a deliberately tiny **separate** FLTK 1.4.5 companion prototype consuming the
standalone libbabet SDK; it is not part of the normal Babet build and does not
change `--create-exe`. The prototype uses only the existing host -> Lua call
path and records the missing Lua -> host capabilities that will define Lot 10.
wxWidgets 3.2.x remains the first fallback if the real prototype shows FLTK is
not suitable. See [`GUI_STUDY.md`](GUI_STUDY.md) and
[`FLTK_PROTOTYPE.md`](FLTK_PROTOTYPE.md).

## Pre-release validation

Before tagging a release, run the complete validation with one command:

```sh
./run_tests.sh --release
```

Like the normal and `--sanitizers` modes, `--release` saves the complete
color-free output to `babet-tests.txt`. The filename is stable and each
top-level run replaces the previous log. This is the file to provide when a
validation result must be reviewed.

Babet's blocking HTTP-framing and TLS checks use local HTTP/HTTPS fixtures
generated at runtime. Public HTTPS probes are advisory by default, so a
third-party outage, proxy, DNS filter, or TLS interception does not invalidate
a release. To make those probes blocking too:

```sh
BABET_SMOKE_STRICT_EXTERNAL=1 ./run_tests.sh --release
```

It automatically runs the ASan/UBSan suite, restores and revalidates the
normal build, then runs the network smoke tests against that final binary.
The normal build step is still attempted when the sanitizer stage fails, so
`test/babet` is not deliberately left instrumented. Internet access is
optional: without it, only the advisory public probes warn. The blocking HTTP
and TLS checks use local fixtures; the bounded TCP check uses a reserved
TEST-NET address. The network stage requires the `python3` and `openssl`
commands.

The individual commands remain available for diagnosis:

```sh
./run_tests.sh --sanitizers
./run_tests.sh
./smoke_test_network.sh ./test/babet
```

Valgrind is optional; ASan and UBSan are the primary memory and undefined
behaviour checks used by the project.

## Documentation

- Project invariants and architectural guardrails: [`INVARIANTS.md`](INVARIANTS.md)
- Optional GUI architecture study: [`GUI_STUDY.md`](GUI_STUDY.md)
- Separate FLTK companion prototype (Lot 9): [`FLTK_PROTOTYPE.md`](FLTK_PROTOTYPE.md)
- Current development roadmap: [`todo`](todo)

- **English** : [`docs/en/README.md`](docs/en/README.md)
- **Français** : [`docs/fr/README.md`](docs/fr/README.md)

The docs are split per module under `docs/en/modules/` (and `docs/fr/`).
You can generate a single PDF manual with:

```sh
cd docs && ./build_doc.sh en   # or: ./build_doc.sh fr
```

Requires `pandoc` and a LaTeX engine (`texlive-xetex` is fine).

## Releases

The maintainer release checklist is documented in
[`RELEASING.md`](RELEASING.md).

Download prebuilt binaries from the
[releases page](https://github.com/Chipsterjulien/babet/releases).

## Development methodology

Babet was developed by a single human author with substantial AI
assistance, primarily Claude (Anthropic) for design discussions,
code generation, and documentation drafting. Cross-audits were
performed regularly with ChatGPT (OpenAI), Gemini (Google), and
Mistral, and the suggestions from these audits were applied only
after verification against the actual source code — AI tools
occasionally hallucinate bugs that aren't there, or invent APIs
that don't exist, so every suggestion was treated as a hypothesis
to test, not a fix to apply blindly.

The pine cone illustrations in `docs/assets/` were generated with
ChatGPT (image model gpt-image-1).

All architectural decisions, the comprehensive test harness across folder
and embedded modes, and the validation of every change before tagging are
the author's responsibility. The AI tools accelerated drafting
and exploration; they did not replace human judgement.

## License

See [LICENSE](LICENSE).
