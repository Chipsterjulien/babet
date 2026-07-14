> **English** | [Français](../fr/README.md)

<p align="center">
  <img src="../assets/babet-closed.png" alt="Babet — pine cone" width="160">
</p>

# Babet — User manual

> *Babet*, n. — a regional word from south-eastern France
> (Lyonnais, Forez, Dauphiné, Savoie, and nearby French-speaking
> Switzerland) meaning a pine cone. Small, light, full of seeds,
> and able to start a fire — like this binary.

Babet is a standalone Lua binary for Linux scripting and automation. This
manual is organized by need and by module: the contents below describe not
only each technical module name, but also the features it contains.

## Getting started

- [`Getting started`](getting-started.md) — installation, first script,
  running a file or directory, creating an embedded executable, and using
  Babet through `PATH`.
- [`Security`](security.md) — threat model, actual protections, limitations,
  and least-privilege rules.
- [`Cookbook`](cookbook.md) — complete recipes combining several modules.

## Find a feature

| I need to… | Read | What it covers |
| --- | --- | --- |
| create, remove, list, search, copy, or move files | [`FS — filesystem`](modules/fs.md) | files, directories, paths, symlinks, `listFiles`, `find`, `copyTree`, permissions, and checksums |
| parse script arguments | [`Argparse — command line`](modules/argparse.md) | flags, options, positional arguments, defaults, choices, and conversions |
| run an external program | [`Exec — processes`](modules/exec.md) | shell-free argv, stdin, stdout/stderr, environment, cwd, timeout, and output limits |
| manage the environment, identify the process, or measure Lua memory | [`SYS - process and host`](modules/sys.md) | runtime version, PID, hostname, `uname`, `PATH`, `env`, `setenv`, and Lua-state memory |
| send a web request | [`HTTP — web client`](modules/http.md) | GET/POST and other methods, query, validated headers, binary bodies, redirects, TLS, timeout, and response-size limits |
| open a TCP connection | [`Socket — TCP`](modules/socket.md) | clients, servers, accept, binary streams, lines, reads through EOF, timeouts, buffering, and limits |
| secure TCP or perform STARTTLS | [`TLS — secure sockets`](modules/tls.md) | direct TLS, STARTTLS, verification, CA, hostname, SNI, versions, timeout, and failure state |
| store SQL data locally | [`SQLite — embedded database`](modules/sqlite.md) | open options, execution, parameters, queries, iterators, and transactions |
| encode or decode JSON | [`JSON — structured data`](modules/json.md) | scalars, arrays, objects, `null`, empty arrays, pretty printing, and errors |
| read TOML configuration | [`TOML — configuration`](modules/toml.md) | decoding, TOML types, arrays, sections, dates, and parse errors |
| watch a directory | [`Inotify — filesystem events`](modules/inotify.md) | watches, events, timeout reads, moves, cookies, and closing |
| handle Unix signals | [`SIGNAL — graceful shutdown and reloads`](modules/signal.md) | `TERM`/`INT`/`HUP`/`USR1`/`USR2`/`PIPE`, deferred callbacks, fixed order, coalescing, interruptible calls, and workers |
| run Lua in parallel | [`WORKERS — OS threads and messages`](modules/workers.md) | isolated Lua states, `spawn`, `join`, `poll`, inbox/outbox, timeouts, closing, serialization, and deadlocks |
| obtain or format time | [`Time — clocks and durations`](modules/time.md) | realtime, monotonic time, sleep, ISO-8601, duration parsing, and formatting |
| look up a system account by name or UID | [`USER - system accounts`](modules/user.md) | NSS, `get`, `exists`, UID, primary GID, GECOS, home, shell, and resolver errors |
| split or transform strings | [`Strings — string helpers`](modules/strings.md) | `split`, separators, limits, and binary strings |
| copy or merge tables | [`Tables — Lua tables`](modules/tables.md) | `mergeTables`, `deepCopyTable`, cycles, and shared structures |
| produce logs | [`Logging — logging`](modules/logging.md) | levels, threshold, output, colors, and sink failures |

## Reference modules

Each module has a standalone page under [`modules/`](modules/). The expanded
titles below let readers understand scope without opening every file.

| Module | Detailed scope |
| --- | --- |
| [`Argparse — command-line arguments`](modules/argparse.md) | Declare flags, options, and positionals; generate help; validate choices; convert values. |
| [`Exec — external programs and processes`](modules/exec.md) | Run without a shell, pass argv/stdin/env/cwd, capture stdout/stderr, limit time and output. |
| [`FS — files, directories, paths, and attributes`](modules/fs.md) | Existence and types, creation/removal, paths, listing, search, iteration, tree copy/move, symlinks, Unix modes, and checksums. |
| [`HTTP — web requests`](modules/http.md) | URLs, methods, query, validated headers, binary bodies/responses, redirects, TLS verification, timeout, and maximum size. |
| [`Inotify — filesystem monitoring`](modules/inotify.md) | Add/remove watches, read events, handle timeouts, moves, cookies, and closing. |
| [`JSON — encoding and decoding`](modules/json.md) | Lua/JSON types, `null`, empty arrays, array marking, indentation, UTF-8, cycles, and limits. |
| [`Logging — application logs`](modules/logging.md) | Levels, filtering, destination, colors, and variadic calls. |
| [`SIGNAL — POSIX signals and graceful shutdown`](modules/signal.md) | Install, replace, or remove callbacks; ignore/restore; dispatch order, coalescing, interruptions, and multithread restrictions. |
| [`Socket — TCP client and server`](modules/socket.md) | Connect, listen, accept, binary streams, chunk/line/EOF reads, shared buffering, addresses, closing, and timeouts. |
| [`SQLite — embedded database`](modules/sqlite.md) | Connections, WAL/timeout options, SQL, positional/named parameters, row iteration, types, and transactions. |
| [`Strings — string manipulation`](modules/strings.md) | Splitting, character mode, separators, split limits, and binary content. |
| [`SYS - process, host, environment, and Lua memory`](modules/sys.md) | Version constants, PID, hostname, `uname`, executable lookup, environment access/mutation, worker interaction, and current Lua-state memory. |
| [`Tables — Lua table manipulation`](modules/tables.md) | Deterministic merge, list/map keys, deep copy, cycles, and shared subtables. |
| [`Time — clocks, ISO, and durations`](modules/time.md) | Realtime and monotonic clocks, sleep, ISO-8601 parse/format, duration parse/format. |
| [`TLS — encrypted connections`](modules/tls.md) | Direct TLS, STARTTLS, verification, CA, hostname, SNI, versions, deadlines, and fail-closed behavior. |
| [`TOML — configuration files`](modules/toml.md) | TOML decoding, scalars, arrays, tables, arrays of tables, dates/times, and diagnostics. |
| [`USER - system users through NSS`](modules/user.md) | Name/UID lookup, existence checks, missing-vs-NSS-error handling, passwd fields, workers, and security limits. |
| [`WORKERS — OS threads and message queues`](modules/workers.md) | Isolated Lua states, JSON transport, consumable results, `poll`/`join`, inbox/outbox, timeouts, closing, GC, and deadlock traps. |

## Module page structure

Detailed pages are progressively aligned to this structure:

1. **Scope** — what the module does and does not cover;
2. **Internal contents** — direct links to each function group;
3. **API overview** — signatures and results;
4. **Detailed behavior** — defaults, symlinks, recursion, limits, and side
   effects;
5. **Examples** — one example for each important mode or option;
6. **Error contract** — raised and returned errors;
7. **Design and limitations** — API choices and intentionally absent features.

The goal is to make every function usable without reading its source code and
without guessing its defaults.

## Building the PDF

The manual can be exported as one PDF:

```sh
cd docs
./build_doc.sh
```

English chapter order is defined in
[`manual_order_en.txt`](../manual_order_en.txt). The build script then creates
the PDF table of contents from headings and subheadings.

## Verification methodology

Documentation is checked module by module against three sources:

- the C/C++ implementation actually registered in `babet`;
- regression tests in `examples/main.lua` and `run_tests.sh`;
- French and English pages, which must describe the same contract.

A mismatch found during this work is treated as something to fix, not a
wording detail to hide.
