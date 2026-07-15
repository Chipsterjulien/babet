# Changelog

All notable changes to Babet are documented in this file.

The project follows semantic versioning for public releases. Migration and
usage notes are kept with each release when a new contract or operational rule
may affect existing scripts.

## [2.5.0] - 2026-07-15

### Release summary

Babet 2.5.0 adds two major audited capabilities while continuing the local
security hardening started in the 2.3 and 2.4 series:

- shell-free synchronous and streaming process pipelines, with per-stage
  status, bounded I/O, process-group cleanup, launch rollback, and Lua
  `<close>` support;
- secure ZIP creation, inspection, and extraction, with deterministic output,
  progressive processing, anti-bomb limits, strict path confinement, source
  mutation detection, and atomic publication;
- descriptor-pinned filesystem operations for `setAttributes()`, `touch()`,
  and `--create-exe`, closing the remaining destructive pathname races found
  during the final review.

Final core validation for this release:

- 2235 PASS / 0 FAIL in folder mode;
- 2222 PASS / 0 FAIL in embedded mode;
- 2222 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes passed under ASan + UBSan;
- 9/9 runtime modes passed again with the final normal build.

The release gate additionally runs the local TLS and network smoke tests through
`./run_tests.sh --release` before the commit is tagged.

### Upgrade and usage notes

- `babet.pipeline()` and `babet.spawnPipeline()` never invoke a shell. Commands
  and arguments must be passed as separate strings.
- The pipeline result code is the last stage's code. Inspect `all_succeeded`,
  `failed_index`, and `stages` when an intermediate failure matters.
- Streaming process and pipeline users must drain stdout and stderr while the
  child is active when large output is possible.
- `babet.archive.create()` is deterministic by default and refuses symlinked or
  special source entries. Existing archives are inspected as byte-oriented ZIP
  names; newly created names must be valid UTF-8.
- `touch()` now refuses a dangling final symlink instead of creating its target.
- `setAttributes()` requires strict Lua integers for UID, GID, and mode;
  numeric strings are no longer coerced.
- ECMAScript regular expressions supplied to `babet.find()` must not come
  directly from untrusted users because `std::regex` has no execution timeout.


### Filesystem race hardening

- `setAttributes()` now pins the resolved target once and applies `fstat`,
  `chown`, optional `chmod`, and rollback to the same inode, preventing a
  pathname replacement from redirecting a privileged later phase.
- Fixed a Lua/C++ `longjmp` leak path by validating the path, UID, GID, and
  mode before constructing the owned pathname string; these arguments now keep
  their documented strict Lua types, so numeric strings are not coerced.
- Reworked `touch()` around a pinned parent, `O_PATH`, and atomic
  `O_CREAT|O_EXCL`; it no longer has an existence-check/truncating-open race,
  never truncates a file that appears concurrently, and refuses dangling final
  symlinks.
- Documented the catastrophic-backtracking risk of untrusted ECMAScript
  patterns passed to `babet.find`, and corrected the `setAttributes()` mode
  examples in the user documentation.
- `--create-exe` now unlinks its `mkstemp` ZIP immediately and passes the
  still-open inode to miniz and the merge step through `/proc/self/fd`; the
  temporary archive can no longer be replaced between creation and reopening.
  The final merge also pins the output directory, uses a short internal
  temporary name, and publishes with `renameat()`, so a replaced parent symlink
  cannot redirect the result and valid near-`NAME_MAX` outputs remain usable.

### Secure ZIP archives

- Added `babet.archive.create()` for progressive directory-to-ZIP creation with deterministic ordering and timestamps, compression levels 0-9, explicit directory entries, bounded source scanning, source-change detection, and atomic whole-archive publication.
- Creation rejects symlink components and entries, unsupported filesystem objects, outputs inside the source tree, unsafe destination parents, destination symlinks, and unexpected source mutations.
- Added `babet.archive.list()` to inspect ZIP metadata, entry types, sizes,
  methods, CRC values, Unix permissions, and paths without extracting.
- Added `babet.archive.extract()` and `babet.archive.extractFile()` with
  progressive decompression, configurable anti-bomb limits, CRC validation,
  same-directory staging files, and atomic per-file publication.
- Rejected absolute paths, `.`/`..` components, backslashes, drive prefixes,
  duplicates, file/directory conflicts, ZIP symlinks, encrypted entries, and
  special filesystem types.
- Added descriptor-based destination traversal with `openat`, `fstatat`,
  `O_NOFOLLOW`, and `AT_SYMLINK_NOFOLLOW`, including existing parents and
  final targets.
- Added limits for entry count, per-entry size, total expanded size,
  compression ratio, cumulative entry-name metadata memory, and a 128 MiB cap
  on internal miniz reader allocations, plus fixed bounds on the implicit
  directory tree produced by extraction.
- Updated miniz from 3.1.1 to 3.1.2 so upstream central-directory parsing and
  decompression fixes are included before exposing untrusted-archive analysis.
- Added deterministic pure-Lua ZIP fixtures covering binary data, DEFLATE,
  permissions, CRC corruption, overwrite, cleanup, traversal, symlinks,
  duplicates, limits, and strict arguments.
- Final P2-C audit: input archives are opened once through a regular-file
  descriptor so FIFO sources are rejected without blocking; `create()` now
  validates emitted UTF-8 names, explicitly enforces the ZIP 1980-2107 timestamp
  range in non-deterministic mode, and uses temporary names independent of the
  final basename so near-`NAME_MAX` destinations remain supported.

### Process pipelines

- Added `babet.pipeline()` for shell-free synchronous pipelines with direct
  stage-to-stage pipes, binary stdin, final stdout capture, separate stderr per
  stage, bounded capture, a global timeout, and per-stage exit statuses.
- Added `babet.spawnPipeline()` for progressive binary I/O through the first
  stdin, final stdout, and every separate stderr stream.
- Added `read_stdout`, indexed `read_stderr`, partial `write`, idempotent
  `close_stdin`, `is_running`, `pids`, `wait`, `terminate`, `kill`, and `close`
  methods, with `__gc` and Lua `<close>` cleanup.
- A pipeline's global code is the last stage's code, while `all_succeeded`,
  `failed_index`, and `stages` preserve intermediate failures and signals.
- Each stage runs in its own process group. Launch failure, timeout, explicit
  termination, close, and garbage collection clean up all already-created
  stages and descendants that remain in those groups. Normal completion also
  removes background descendants before the leader is reaped, without risking
  a signal being sent to a recycled PID.
- Refactored synchronous and streaming pipelines onto one shared multi-process
  launcher in `process_common`, including strict pre-fork validation and
  bounded partial-launch rollback.
- Added deterministic regression coverage for binary and partial I/O, large
  stdin/stdout/stderr volumes, SIGPIPE, intermediate failures, launch errors,
  timeouts, idempotence, process groups, GC, and Lua `<close>`.
- Final P1-C audit: strict validation of both APIs and every method, launch
  timeout coverage during `chdir`/`exec`, rollback of partial launches and their
  descendants, cleanup of a background child after normal completion,
  protection when standard descriptors 0/1/2 are closed, and cross-checking of
  code, tests, French/English documentation, examples, and PDF manuals.

## [2.4.0] - 2026-07-14

### Release summary

Babet 2.4.0 removes three practical limits of the 2.3 series without weakening
the safety guarantees established by the previous audit:

- external programs can now be driven progressively through `babet.spawn`,
  without buffering all stdin, stdout, or stderr in memory;
- HTTP and HTTPS responses can be downloaded directly to a file with bounded,
  atomic, symlink-aware destination handling;
- SQLite now supports reusable prepared statements, explicit BLOB values, and
  assisted transactions with automatic rollback on Lua errors.

The existing `babet.exec`, `babet.http.request`, `db:exec`, and `db:query`
contracts remain available. The new APIs are additive, while the shared process
engine and release smoke tests were refactored and revalidated.

Final validation for this release:

- 1810 PASS / 0 FAIL in folder mode;
- 1797 PASS / 0 FAIL in embedded mode;
- 1797 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes passed under ASan + UBSan;
- 9/9 runtime modes passed again with the final normal build;
- network smoke tests: 6 blocking checks passed, 0 failed, and 2 public probes
  reported advisory warnings.

### Upgrade and usage notes

Babet 2.4.0 is primarily additive, but the following operational rules are
important when adopting the new APIs:

- `process:wait()` does not drain stdout or stderr. A child that produces enough
  output can block until both streams are read; long-running scripts should
  drain them while the process is active.
- `process:write()` may write only part of the supplied string. Continue from
  the returned byte count or use the documented write-all pattern.
- `babet.http.download()` commits a destination only for a complete final 2xx
  response. Non-2xx responses return metadata with `saved=false`; transport,
  TLS, timeout, size, or disk failures return `(nil, err)` and preserve an
  existing destination.
- Download destinations reject `..` and symlinked parent-directory components.
  A symlink exactly at the final destination is replaced as an inode; its target
  is not modified.
- `db:transaction()` commits every normal callback return, including `nil` and
  `false`. Use `assert` or explicitly raise an error when an operation returning
  `(nil, err)` must trigger rollback.
- Only one prepared-query iteration can be active per prepared statement. A
  reset or a new execution invalidates the previous iteration.
- Plain Lua strings continue to bind as SQLite TEXT. Use
  `babet.sqlite.blob(data)` when the SQLite storage class must be BLOB.

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
