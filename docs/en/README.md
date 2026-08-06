> **English** | [Français](../fr/README.md)

<p align="center">
  <img src="../assets/babet-closed.png" alt="Babet — pine cone" width="160">
</p>

# Babet — User manual

> *Babet*, n.m. — a regional word from south-eastern France
> (Lyonnais, Forez, Dauphiné, Savoie, and neighbouring Swiss Romandy)
> meaning a pine cone. Small, light, full of seeds, and able to start a
> fire—like this binary.

Babet is a standalone Lua binary for Linux scripting and automation. This
manual is organised by need and by module: the tables below describe both the
technical chapter name and the features it contains.

Documentation for the **Babet 2.20.0** release candidate.

Babet 2.20.0 modularizes the Lua test harness into 44 reachable suites and
adds `db:backup()`, a coherent, bounded, atomically published SQLite backup,
including WAL databases modified while the copy is running.

## Getting started

- [`Getting started`](getting-started.md) — installation, first script, running
  a file or directory, creating an embedded executable, and using Babet through
  `PATH`.
- [`Security`](security.md) — threat model, actual protections, limitations,
  and least-privilege rules.
- [`Cookbook`](cookbook.md) — complete recipes combining several modules.
- [`Changelog`](../../CHANGELOG.md) — complete 2.20.0 release notes and the history of earlier releases, migration, validation, and known limitations.

## Find a feature

| I need to… | Chapter | What it contains |
| --- | --- | --- |
| create, remove, list, search, copy, or move files | [`FS — filesystem`](modules/fs.md) | files, directories, paths, symlinks, `listFiles`, `find`, `copyTree`, permissions, and checksums |
| atomically publish configuration or binary data | [`writeFileAtomic — atomic writing`](modules/write-file-atomic.md) | default no-overwrite, permissions, durability, path confinement, concurrency, and workers |
| parse script arguments | [`Argparse — command line`](modules/argparse.md) | flags, options, positional arguments, defaults, choices, and conversion |
| run an external program | [`Exec — processes`](modules/exec.md) | shell-free arguments, complete capture with `exec`, streaming with `spawn`, environment, cwd, and process control |
| chain several commands | [`Process pipelines`](modules/pipeline.md) | complete capture or streaming, separate stderr streams, per-stage statuses, and process-group cleanup |
| create or inspect/extract ZIP or TAR archives | [`Archive — secure multi-format archives`](modules/archive.md) | deterministic ZIP and plain/gzip/xz/bzip2/zstd TAR creation, listing, full testing, selective extraction, `dry_run` preview, anti-bomb limits, and atomic file publication |
| encode or decode binary data as Base64 | [`Base64 — binary data`](modules/base64.md) | standard or URL-safe alphabets, optional padding, strict canonical decoding, controlled whitespace, and an output limit |
| compress or decompress one file | [`Compression — standalone streams`](modules/compression.md) | gzip, xz, bzip2, and zstd streams, content detection, output limits, concatenated members, integrity checks, and atomic publication |
| inspect the process, environment, machine, or Lua VM memory | [`SYS — process and machine`](modules/sys.md) | runtime version, PID, hostname, `uname`, `PATH`, `env`, `setenv`, and Lua-state memory |
| send an HTTP request | [`HTTP — web client`](modules/http.md) | GET/POST and other methods, query, validated headers, binary bodies, atomic downloads, redirects, TLS, timeout, and size limits |
| open a TCP connection or local Unix socket | [`Socket — TCP and Unix`](modules/socket.md) | TCP/Unix clients and servers, accept, local permissions, binary streams, lines, EOF, timeouts, and cleanup |
| encrypt TCP or perform STARTTLS | [`TLS — secure sockets`](modules/tls.md) | direct TLS, STARTTLS, verification, CA, hostname, SNI, versions, timeout, and fail-closed state |
| store SQL data locally | [`SQLite — embedded database`](modules/sqlite.md) | read/write or read-only opening, foreign-key enforcement, change counters, strict parameters, coherent atomic backups, explicit `NULL` and BLOB values, prepared statements, and assisted transactions |
| encode or decode JSON | [`JSON — structured data`](modules/json.md) | scalars, arrays, objects, `null`, empty arrays, pretty printing, and errors |
| read TOML configuration | [`TOML — configuration`](modules/toml.md) | decoding, TOML types, arrays, sections, dates, and parse errors |
| watch a directory | [`Inotify — file events`](modules/inotify.md) | watches, events, timeout reads, moves, cookies, and closing |
| handle Unix signals | [`SIGNAL — clean shutdown and reload`](modules/signal.md) | `TERM`/`INT`/`HUP`/`USR1`/`USR2`/`PIPE`, deferred callbacks, fixed order, coalescing, interruptible calls, and workers |
| parallelise Lua work | [`WORKERS — OS threads, messages, and channels`](modules/workers.md) | isolated Lua states, `spawn`, a persistent bounded pool, `cpu_count`, inbox/outbox, and direct MPMC channels |
| obtain or format time | [`Time — clocks and durations`](modules/time.md) | realtime and monotonic clocks, sleep, ISO-8601, parsing, and duration formatting |
| look up a system account by name or UID | [`USER — system accounts`](modules/user.md) | NSS, `get`, `exists`, UID, primary GID, GECOS, home, shell, and resolution errors |
| split or transform strings | [`Strings`](modules/strings.md) | `split`, separators, limits, character mode, and binary strings |
| copy, merge, or mark tables | [`Tables`](modules/tables.md) | `mergeTables`, `deepCopyTable`, cycles, and shared structures |
| produce logs | [`Logging`](modules/logging.md) | levels, threshold, destination, colours, and sink-error behaviour |

## Module reference

Each module has a standalone page under [`modules/`](modules/). The expanded
names below define each chapter's scope before you open it.

| Module | Detailed scope |
| --- | --- |
| [`Archive — secure ZIP, TAR, gzip, xz, bzip2, and zstd operations`](modules/archive.md) | Create deterministic ZIP, TAR, gzip TAR, xz TAR, bzip2 TAR, or zstd TAR archives, then inspect, test, and selectively extract them with `dry_run` previews, bounded resources, confined paths, and atomic per-file publication. |
| [`Base64 — binary encoding and decoding`](modules/base64.md) | Encode or decode binary Lua strings with standard or URL-safe alphabets, controlled padding, canonical validation, optional whitespace, and a `max_output` ceiling. |
| [`Compression — standalone gzip, xz, bzip2, and zstd streams`](modules/compression.md) | Compress or decompress one regular file with automatic content detection, bounded expansion, integrity verification, symlink refusal, and atomic output publication. |
| [`Argparse — command-line arguments`](modules/argparse.md) | Declare flags, options, and positional values; generate help; validate choices; convert values. |
| [`Exec — external programs and processes`](modules/exec.md) | Run without a shell using `exec`, or progressively drive stdin/stdout/stderr using `spawn`. |
| [`Process pipelines`](modules/pipeline.md) | Connect commands without a shell, using complete capture or streaming and per-stage statuses. |
| [`FS — files, directories, paths, and attributes`](modules/fs.md) | Existence and types, creation/removal, paths, listings, search, iterators, tree copy/move, symlinks, Unix modes, and checksums. |
| [`writeFileAtomic — atomic and durable file writing`](modules/write-file-atomic.md) | Publish a binary Lua string through a private temporary file and atomic rename, with explicit overwrite, exact permissions, `fsync`, path confinement, and worker support. |
| [`HTTP — web requests`](modules/http.md) | URLs, methods, query, validated headers, binary bodies, responses, atomic file downloads, redirects, TLS verification, timeout, and limits. |
| [`Inotify — filesystem monitoring`](modules/inotify.md) | Add/remove watches, read events, handle timeouts, moves, cookies, and closing. |
| [`JSON — encoding and decoding`](modules/json.md) | Lua/JSON types, `null`, empty arrays, array marking, indentation, UTF-8, cycles, and limits. |
| [`Logging`](modules/logging.md) | Levels, filtering, destination, colours, and variadic calls. |
| [`SIGNAL — POSIX signals and clean shutdown`](modules/signal.md) | Install, replace, or remove callbacks; ignore/restore; dispatch order, coalescing, interruptions, and multithread restrictions. |
| [`Socket — TCP and Unix sockets`](modules/socket.md) | TCP/Unix connect and listen, accept, permissions and inode-sensitive cleanup, binary streams, block/line/EOF reads, addresses, and timeouts. |
| [`SQLite — embedded database`](modules/sqlite.md) | Read/write and read-only connections, WAL/timeout, foreign keys, row/change counters, direct SQL, reusable prepared statements, explicit BLOBs, coherent WAL backups, iteration, and assisted transactions. |
| [`Strings`](modules/strings.md) | Splitting, character mode, separators, split limits, and binary content. |
| [`SYS — process, machine, environment, and Lua memory`](modules/sys.md) | Version constants, PID, hostname, `uname`, executable lookup, environment reads/writes, worker interaction, and Lua-state memory. |
| [`Tables`](modules/tables.md) | Deterministic merging, list/map keys, deep copy, cycles, and shared subtables. |
| [`Time — clocks, ISO, and durations`](modules/time.md) | Realtime and monotonic clocks, sleep, ISO-8601 formatting/parsing, and duration parsing/rendering. |
| [`TLS — encrypted connections`](modules/tls.md) | Direct TLS, STARTTLS, verification, CA, hostname, SNI, versions, deadlines, and fail-closed behaviour. |
| [`TOML — configuration files`](modules/toml.md) | TOML decoding, scalars, arrays, tables, arrays of tables, dates/times, and diagnostics. |
| [`USER — NSS system users`](modules/user.md) | Lookup by name or UID, existence, absence vs NSS errors, passwd fields, workers, and security limits. |
| [`WORKERS — OS threads, queues, and channels`](modules/workers.md) | Isolated Lua states, JSON transport, `status`, `done`, a persistent bounded pool, cooperative cancellation, inbox/outbox, direct MPMC channels, closing, GC, and deadlock traps. |

## Structure of a module page

Detailed pages are progressively aligned on this structure:

1. **Scope** — what the module covers and deliberately excludes;
2. **Internal contents** — direct access to each function group;
3. **API overview** — signatures and results;
4. **Detailed behaviour** — defaults, symlinks, recursion, limits, and side effects;
5. **Examples** — one example per important mode or option;
6. **Error contract** — raised errors and returned errors;
7. **Design decisions and limitations** — intentional choices and omissions.

The goal is to let a function be used without reading its source code or
having to guess default values.

## PDF generation

The whole manual can be exported as one PDF:

```sh
cd docs
./build_doc.sh
```

English chapter order is defined in [`manual_order_en.txt`](../manual_order_en.txt).
