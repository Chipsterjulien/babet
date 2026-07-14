# Changelog

All notable changes to Babet are documented in this file.

The project follows semantic versioning for public releases. Because 2.3.0
hardens several API contracts that were previously permissive, users upgrading
from 2.2.x should read the migration notes below.

## [2.4.0] - Unreleased

### SQLite prepared statements, BLOB values, and transactions

- Added `db:prepare(sql)` for reusable single-statement handles with
  `exec`, callable `query`, `reset`, `close`, and `finalize` operations.
- Prepared statements automatically reset and clear bindings between runs; a
  partial row iteration can be explicitly reset or replaced by the next run.
- Added `babet.sqlite.blob(data)` to bind binary-safe Lua strings with SQLite
  BLOB storage while preserving the historical TEXT behavior of plain strings.
- Added `db:transaction(callback [, mode])` with deferred, immediate, and
  exclusive modes, automatic rollback on Lua callback errors, and forwarding
  of callback return values after a leading success boolean.
- Added `db:in_transaction()` and guards against nested helpers, helper use
  inside an existing manual transaction, and closing the connection from the
  transaction callback.
- Preserved `sqlite3_close_v2` lifetime semantics: prepared statements created
  before `db:close()` remain usable until they are finalized.
- Added 66 regression checks covering repeated binds, query reuse, early reset,
  step errors, BLOB storage classes, transaction modes, rollback, callback
  errors, nesting, manual transactions, and closed-handle behavior.

### HTTP file downloads

- Added `babet.http.download(url, destination [, opts])` for synchronous GET
  downloads streamed directly to disk without buffering the complete body.
- Added `max_file_size` with an 8 GiB default and strict positive-integer
  validation; the limit applies to bytes actually delivered by the HTTP client.
- Downloads use an exclusive same-directory temporary file and atomically
  replace the final path only for a complete final 2xx response.
- Existing destinations are preserved after DNS, TCP, TLS, timeout, size,
  disk-write, non-2xx, and redirect-not-followed outcomes; unfinished temporary
  files are removed.
- Hardened destination traversal: parent directories must exist, `..` and
  parent symlink components are rejected, while a final destination symlink is
  safely replaced without modifying its target.
- Added compact result metadata (`status`, `saved`, `bytes`, `path`, `headers`,
  `headers_multi`) with no in-memory `body` field.
- Added local deterministic regression coverage for binary files, empty files,
  replacement, redirects, HTTP errors, size limits, transport failures, and
  symlink protections, plus a blocking local HTTPS download smoke test.

### Process streaming

- Added `babet.spawn(command [, args] [, opts])`, returning a process userdata
  with non-blocking stdin, stdout, and stderr pipes.
- Added progressive `read_stdout`, `read_stderr`, and partial `write` methods
  with binary-safe strings and typed `timeout`, `closed`, and `interrupted`
  outcomes.
- Added bounded `wait`, process-group `terminate`/`kill`, idempotent `close`,
  automatic garbage-collection cleanup, PID access, and running-state checks.
- Added an optional `launch_timeout` covering the `chdir` and `exec` phase.
- Refactored `babet.exec` and `babet.spawn` to share the same hardened launch
  engine: CLOEXEC pipes, parent-side environment construction, process groups,
  launch-error reporting, and bounded cleanup.
- Added regression coverage for binary stdin, separate large stdout/stderr
  streams, timeouts, environment/cwd, lifecycle methods, and validation.

## [2.3.0] - 2026-07-14

### Release summary

Babet 2.3.0 is a full source/documentation audit rather than a narrow feature
release. Every public module was checked against the C++ or Lua implementation,
the folder and embedded test modes, and the French and English manuals.

The release notably adds or completes:

- exhaustive bilingual module documentation with local tables of contents;
- hardened filesystem and executable-packaging operations;
- stricter and more predictable Lua argument contracts;
- bounded process, socket, TLS, HTTP, inotify, and worker operations;
- major regression coverage across folder, embedded, and `PATH` execution;
- a one-command pre-release validation using ASan, UBSan, a normal rebuild,
  and network smoke tests.

Final validation for this release:

- 1637 PASS / 0 FAIL in folder mode;
- 1624 PASS / 0 FAIL in embedded mode;
- 1624 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes passed under ASan + UBSan;
- 9/9 runtime modes passed again with the final normal build;
- network smoke tests: 4 blocking checks passed, 0 failed, 2 external probes
  reported advisory warnings.

### Migration notes and stricter contracts

These changes may expose bugs in scripts that relied on implicit coercions or
ignored arguments:

- Public functions audited in this release now reject undocumented extra
  arguments instead of silently ignoring them.
- APIs documented as taking strings now generally require real Lua strings;
  numeric-to-string coercion is no longer accepted by `json.decode`,
  `split`, time parsers, process arguments, system-account lookups, socket/TLS
  hosts, and similar entry points.
- Numeric options now generally require real finite Lua numbers or integers;
  numeric strings, NaN, infinities, fractional integers, and out-of-range
  values are rejected where appropriate.
- `babet.sleep` still supports `s`, `ms`, `us`, and `ns`. Only implicit forms
  such as `babet.sleep("1", "ms")` or a numeric unit are rejected.
- Filesystem removal is explicit: `remove` removes regular files or symlinks,
  `rmdir` removes an empty real directory, and `rmdirAll` removes a real
  directory recursively.
- After the first `workers.spawn`, process-wide `chdir` and environment
  mutation are rejected to avoid cross-thread races.
- Argparse now rejects malformed or ambiguous declarations, including
  reserved `-h`/`--help`, duplicate names or destinations, sparse `choices`,
  invalid explicit token arrays, and required positionals after optional ones.
- `logging.set_output` now requires a callable `write` method and
  `logging.set_level` rejects non-finite numeric thresholds.
- `inotify.add(..., { onlydir = ... })` requires a strict boolean; a string
  such as `"false"` is no longer treated as true.
- JSON table keys outside the documented array/object shapes are rejected,
  including zero, fractional, boolean, and unsupported mixed keys.
- `toml.decode`, JSON encoding/decoding, time helpers, inotify methods,
  logging accessors, table helpers, and string helpers enforce their
  documented arity.
- `babet.time.iso` floors negative fractional timestamps to the preceding
  second, making pre-epoch formatting consistent.

### Runtime and executable packaging

- Made `babet --create-exe` publication atomic: an existing output remains
  intact when generation fails.
- Refused overwriting the currently running binary, including equivalent
  symlink paths.
- Excluded the output executable from its own embedded ZIP, making repeated
  builds stable.
- Recursively excluded `.git`, `.svn`, and `.hg` metadata from packages.
- Added a per-file embedded ZIP size limit with a clear diagnostic.
- Hardened appended-ZIP parsing, bounds checks, offsets, and malformed archive
  handling.
- Improved dynamic executable-path discovery to grow its buffer instead of
  truncating long `/proc/self/exe` results.
- Improved script-file mode: neighboring modules are available through
  `require`, `arg` is populated consistently, and `#!babet` scripts without a
  `.lua` extension are supported.
- Added clear errors for missing paths, directories without `main.lua`, and a
  `main.lua` path that is itself a directory.
- Improved diagnostics for non-string Lua errors in normal and embedded mode.

### Filesystem, paths, attributes, and checksums

- Added consistent embedded-NUL rejection for filesystem paths, modes,
  environment fields, regex options, and related string inputs.
- Hardened `copyTree` and `moveTree` against destination traversal through
  symlinks, destination-inside-source recursion, source-root symlinks, and
  collisions that could redirect writes outside the requested tree.
- Added secure destination helpers and rollback-oriented preparation for tree
  operations.
- Preserved and retargeted internal absolute symlinks when copying or moving a
  tree, while leaving external and dangling links meaningful.
- Improved cross-filesystem `moveTree` behavior and preserved the source on
  failed copies or collisions.
- Dropped setuid, setgid, and sticky bits on copied regular files while
  preserving ordinary permission bits.
- Made `copyTree` continuation mode return warnings instead of silently
  discarding unsupported or unreadable entries.
- Clarified and tested strict file/directory distinctions for `remove`,
  `rmdir`, and `rmdirAll`, including symlinks, FIFOs, and dangling links.
- Hardened `find` depth validation, type validation, regex lifetime, traversal
  errors, pruning, and concurrent calls.
- Hardened `FileIterator` cleanup and traversal-error reporting.
- Made checksums reject non-regular files and never return a digest after a
  read failure; symlinks to regular files remain supported.
- Added rollback when `setAttributes` partially changes a path and a later
  attribute operation fails.

### External processes (`exec`)

- Enforced strict command, argument, option, environment, cwd, stdin, timeout,
  and output-limit validation.
- Made stdin/stdout/stderr handling binary-safe and robust for large streams,
  early pipe closure, and `EPIPE`.
- Applied the timeout to the entire launch sequence, including child setup,
  `chdir`, and `exec`.
- Killed and reaped the complete process group on timeout so grandchildren do
  not keep pipes or the parent call alive.
- Preserved output produced before timeout and exposed truncation flags when
  `max_output` is used.
- Normalized signal termination to `128 + signal`.
- Hardened cleanup after polling errors and added deterministic regression
  injection in the normal build.
- Prepared child arguments and environment before `fork` to reduce unsafe work
  in the child of a multithreaded process.

### Signals and workers

- Documented and enforced the supported POSIX signal set, strict signal names,
  main-thread-only handler changes, fixed dispatch order, callback arity, and
  deferred delivery semantics.
- Preserved signal handlers across concurrent `exec` calls and prevented
  global `SIGPIPE` races.
- Hardened worker serialization/deserialization stack usage and depth limits.
- Improved diagnostics for non-string worker errors and internal exceptions.
- Enforced dense JSON-compatible spawn arguments and message payloads.
- Added bounded inbox/outbox capacities and strict timeout validation.
- Clarified `poll`, consumable `join` results, close/drain behavior, and
  `closed`/`full`/`timeout` outcomes.
- Allowed explicit `nil` messages while continuing to reject unsupported Lua
  values.
- Permanently locked process-wide cwd/environment mutation after the first
  worker is created.
- Expanded real-parallelism, independent-worker, queue, close, timeout, and
  error-path regression tests.

### TCP sockets

- Enforced strict host, port, backlog, timeout, count, and size types/ranges.
- Added bounded per-call timeouts for `accept`, `recv`, `recv_line`, and
  `recv_all`, overriding the socket default when supplied.
- Added a 16 MiB cap for `recv` and a configurable, bounded `recv_all` limit.
- Preserved buffered bytes across `recv_line` timeouts and across later
  `recv`/`recv_all` calls.
- Made `recv_all` timeout and size-limit failures recoverable without exposing
  a partial body.
- Standardized typed outcomes such as `timeout`, `closed`, and `interrupted`.
- Made blocking connect responsive to Babet signal dispatch and bounded
  saturated-backlog connection attempts.
- Hardened operations on closed or listening sockets and made `close`
  idempotent.

### TLS

- Added and documented direct TLS connections and STARTTLS on an existing TCP
  socket.
- Enabled certificate-chain and hostname verification by default, including
  system trust-store probing.
- Added SNI independently from certificate verification, including
  `verify=false` test connections.
- Isolated custom `ca_cert`/`ca_path` configuration in a private `SSL_CTX` per
  connection so custom authorities neither leak into later connections nor
  race between workers.
- Enforced TLS 1.2 as the default minimum and supported a TLS 1.3 minimum.
- Added global handshake deadlines and per-call TLS I/O deadlines.
- Refused STARTTLS when plaintext remains buffered, while preserving those
  bytes for the caller.
- Made failed STARTTLS fail closed after the handshake starts; pre-handshake
  validation errors leave the TCP socket usable.
- Added strict validation for host, port, verification flags, CA paths,
  hostname, version, timeout, and embedded NULs.

### HTTP

- Aligned URL, method, headers, query, body, TLS, redirect, timeout, and size
  handling with the implementation.
- Added strict URL authority and host validation, CR/LF rejection, header-name
  validation, and scalar query validation.
- Documented and tested query normalization, UTF-8 percent encoding, existing
  query merging, and fragment removal.
- Made request bodies and responses binary-safe.
- Added `headers_multi` for repeated response headers while retaining the
  simplified `headers` map.
- Added a bounded `max_body_size` and rejected oversized responses without
  returning partial data.
- Applied one global timeout to connect, TLS, send, and receive phases.
- Clarified redirect defaults, method normalization, HEAD behavior, and POST
  overload precedence.

### SQLite

- Replaced documentation of nonexistent `prepare`/`step`/`finalize` bindings
  with the actual `open`/`exec`/`query` iterator API.
- Documented the difference between multi-statement `exec(sql)` and the
  single-statement parameterized form.
- Fixed empty or comment-only parameterized SQL so a null SQLite statement is
  never dereferenced.
- Clarified that Lua strings are bound as SQLite TEXT, while BLOB values read
  from SQLite remain binary-safe Lua strings.
- Documented positional/named binding validation, placeholder detection,
  duplicate column behavior, `NULL`, empty TEXT/BLOB, lazy DML execution, and
  iterator lifetime after `db:close`.
- Added strict options, SQL NUL checks, bounded busy timeout, iterator cleanup,
  and step-error regression coverage.

### JSON

- Made `json.decode` require an actual Lua string and made `json.encode`
  enforce its documented arity.
- Fixed classification of tables containing only invalid keys; they now fail
  instead of being encoded as `{}`.
- Documented exact array/object shape rules, root `nil`, `json.null`, empty
  array tagging, duplicate keys, UTF-8, binary NULs, large integers, cycles,
  indentation, and depth limits.
- Clarified that `as_array` replaces the table metatable and that an emptied
  formerly non-empty decoded array needs to be marked again.

### TOML

- Made `toml.decode` enforce exactly one real Lua string argument.
- Preserved quoted TOML keys containing `\u0000` by using length-aware Lua
  table insertion instead of C-string field APIs.
- Documented signed 64-bit integers, bases, infinities, NaN, Unicode and quoted
  keys, dotted keys, heterogeneous arrays, dates/times, empty containers, and
  information lost during Lua conversion.

### Inotify

- Enforced strict arity for watcher construction and methods.
- Made `opts.onlydir` a strict boolean.
- Documented file-versus-directory watches, mask replacement, batched reads,
  `ignored`, `unmount`, overflow events, signal interruption, multiple watches,
  and multiple watcher instances.
- Fixed a LeakSanitizer-reported allocation leak caused by a Lua longjmp
  bypassing a live C++ `std::string` destructor in an argument-error path.

### Time and sleeping

- Removed implicit string/number coercions from sleep, ISO, and duration APIs.
- Kept `s`, `ms`, `us`, and `ns` sleep units unchanged.
- Made negative fractional timestamps floor consistently before ISO formatting.
- Documented realtime versus monotonic clocks, exact ISO grammar, timezone
  offsets, pre-epoch and extended years, duration grammar, non-normalized
  components, canonical formatting, and error contracts.

### Argparse

- Renamed module metadata from LuaPilot to Babet and bumped it to 1.1.0.
- Added strict constructor/method arity and complete option-field validation.
- Rejected reserved, malformed, duplicate, or ambiguous names and
  destinations.
- Made builder updates atomic so an error caught by `pcall` leaves no partial
  alias or option behind.
- Enforced ordered positional declarations and dense explicit token arrays.
- Kept useful behavior such as inline values, negative option values,
  repeated options (last value wins), option-looking values, and `--`.
- Clarified that defaults bypass `choices` and `convert`.

### Strings and tables

- Made `split` require real Lua strings while preserving binary strings,
  embedded NULs, literal one-byte separators, empty fields, and byte-oriented
  mode.
- Fully documented `mergeTables` ordering, compaction, last-writer-wins map
  keys, shallow references, raw traversal, and ignored metatables.
- Fully documented `deepCopyTable` cycles, shared values, raw entries,
  un-copied table keys, shared metatables, and the 75-level depth contract.
- Fixed a cycle closing exactly at the maximum depth so it reuses the existing
  copied table before rejecting genuinely deeper new tables.

### Logging

- Renamed module metadata from LuaPilot to Babet and bumped it to 1.1.0.
- Protected the complete logging pipeline, including `tostring`, timestamp
  creation, and sink writes, so log emission never escapes an error.
- Made `set_output` verify a callable `write` method, including methods supplied
  through `__index`.
- Added strict accessor/setter arity and rejected non-finite thresholds while
  preserving finite custom numeric levels.
- Documented local timestamps, multiline/binary messages, colors, shared state
  inside one Lua state, worker isolation, and the absence of a `fatal` level.

### Documentation and validation

- Rewrote the French and English manuals against source and tests for every
  public module: FS, SYS, USER, EXEC, SIGNAL, WORKERS, SOCKET, TLS, HTTP,
  SQLite, JSON, TOML, Inotify, Time, Argparse, Strings, Tables, and Logging.
- Added descriptive manual indexes and a stable local table of contents to
  every module page.
- Regenerated the complete PDF manuals with working internal links.
- Expanded the harness to 1637 folder-mode checks and 1624 checks in each
  embedded mode.
- Added `./run_tests.sh --release`, which runs ASan + UBSan, restores and tests
  the normal build, then runs network smoke tests against the final binary.
- Added blocking local/network-contract probes and advisory Google/AUR probes;
  set `BABET_SMOKE_STRICT_EXTERNAL=1` to make the latter blocking.

### Known limitations carried forward

- Babet remains a Linux/glibc project; macOS/BSD portability is not claimed.
- `exec` still uses glibc `execvpe`; resolving PATH entirely in the parent and
  using only `execve` in the child remains a possible extra hardening step.
- Worker-to-worker channels and forced thread termination are intentionally not
  provided; communication is parent-mediated and workers must cooperate when
  closing.
- ZIP/TAR convenience bindings are not yet part of the public Lua API.
- Valgrind is optional; ASan and UBSan are the primary release checks.
