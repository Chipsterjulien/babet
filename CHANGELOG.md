# Changelog

All notable changes to Babet are documented in this file.

The project follows semantic versioning for public releases. Migration and
usage notes are kept with each release when a new contract or operational rule
may affect existing scripts.

## [2.14.0] - 2026-08-03

### Summary

Babet 2.14.0 completes the audited C++ exception boundary work for the four
remaining public binding modules and fixes terminal ownership for interactive
`babet.spawn` children. No Lua function, option, or ordinary return contract is
added or removed.

### Lua/C++ exception boundaries

- added one shared exception-classification core that distinguishes
  `std::bad_alloc`, another `std::exception`, and an unknown C++ exception
  without allowing any of them to cross Lua's C frames, and destroys the
  caught exception before asking Lua to push the diagnostic;
- protected the two `babet.compression` functions, preserving the existing
  RAII cleanup of source descriptors and unpublished temporary outputs;
- protected all six flat SYS functions: `which`, `env`, `setenv`, `hostname`,
  `uname`, and `pid`;
- protected `babet.user.get` and `babet.user.exists` around their dynamic NSS
  buffers and diagnostic strings;
- protected the inotify factory plus `add`, `read`, `remove`, `close`, and
  `__tostring`, while giving `__gc` a dedicated catch-all boundary that never
  attempts to allocate or return an error;
- translated an unexpected allocation failure to `(nil, "<module>: out of
  memory")`, other standard exceptions to `(nil, "<module>: internal
  failure")`, and non-standard exceptions to `(nil, "<module>: unknown
  internal failure")`;
- kept programmer errors on their established Lua-error path and preserved all
  ordinary success, runtime-error, timeout, interruption, and NSS results.

### Interactive `babet.spawn` processes

- kept every child in its separate process group, so `terminate()`, `kill()`,
  and `close()` continue to target its descendants as well;
- when `stdin = "inherit"` refers to Babet's controlling terminal and Babet owns
  the foreground, synchronously transferred that terminal to the child group
  only after the group was established;
- added a `CLOEXEC` synchronization pipe that prevents the child from reading
  before the parent's `tcsetpgrp()`, avoiding a background-group `SIGTTIN` stop;
- restored the original foreground group and `termios` attributes after
  `wait()`, `terminate()`, `kill()`, `close()`, garbage collection, or a launch
  failure;
- locally blocked `SIGTTOU` around foreground-group changes without changing
  the process's lasting signal mask;
- left captured streams, file and `/dev/null` redirections, and inherited
  non-terminal stdin unchanged;
- terminal-generated signals such as `Ctrl+C` now reach the foreground child
  group while preserving the `128 + signal` result convention.

### Tests and documentation

- added a real pseudo-terminal regression test: one parent-side Lua read, a
  second read by a child with all three streams inherited, a `wait(timeout)`
  followed by normal continuation, `Ctrl+C` delivery, code-130 validation, a
  real `Ctrl+Z` stop followed by bounded `kill()` recovery, restoration after
  an `is_running()` status refresh, deliberate terminal-mode modification and
  restoration, plus a hard anti-hang deadline;
- explicitly documented the lack of full job control, the requirement to
  observe or close an exited child before the parent reads again, and the
  non-interactive scope of `pipeline()` / `spawnPipeline()`;
- integrated the PTY test into both normal and ASan/UBSan validation paths;
- added a compiled standalone self-test covering normal completion,
  `std::bad_alloc`, `std::exception`, and an unknown exception, while verifying
  that every diagnostic reporter runs after the active C++ catch is cleared;
- added a release preflight that requires every one of the 17 audited
  registrations to use its boundary and rejects the old direct registrations;
- kept fault injection out of the production binary: the self-test exercises
  the shared classification core in its own temporary executable;
- updated the English and French README files, module references, release
  procedure, `todo`, third-party notice header, and release notes for 2.14.0.

## [2.13.0] - 2026-08-03

### Release summary

Babet 2.13.0 adds a managed, nestable SQLite savepoint helper. Scripts can now
isolate a recoverable unit of work without inventing SQL identifiers or
manually pairing `ROLLBACK TO` with `RELEASE`, including inside an existing
managed or manual transaction.

### Nested savepoint helper

- added `db:savepoint(callback)`, returning `true` followed by every normal
  callback result, including explicit `nil` and `false` values;
- generated savepoint identifiers entirely inside Babet, with a monotonic
  per-connection sequence and no user-controlled SQL identifier;
- supported standalone savepoints, savepoints inside `db:transaction()`,
  savepoints inside a manual SQL transaction, and recursively nested helpers;
- kept `db:in_transaction()` true while a standalone savepoint is active and
  preserved the outer transaction after an inner `RELEASE`;
- converted callback Lua errors to `(nil, err)` after `ROLLBACK TO` followed by
  `RELEASE`, so a failed inner helper rolls back only its own work;
- discarded callback results when an outermost `RELEASE` fails, then attempted
  the same rollback-and-release cleanup before returning the SQLite error;
- rejected `db:close()` while any savepoint callback is active, while leaving
  the 2.12.0 transaction-helper rules unchanged.

### Exception safety and state recovery

- tracked active savepoint depth and generated-name sequence on each native
  connection without global state;
- added an allocation-free RAII emergency guard that performs a best-effort
  `ROLLBACK TO` and `RELEASE` if a C++ exception escapes after `SAVEPOINT`;
- detected callbacks that explicitly end the transaction before attempting
  cleanup, returning one stable diagnostic without a generated identifier or
  repeated `no such savepoint` errors;
- shortened generated names to a connection-local `babet_sp_<sequence>` form,
  removed the native address, and checked every formatting result explicitly;
- reserved Lua stack capacity before taking ownership of the savepoint and ran
  the callback through `lua_pcall`, preventing a Lua longjmp from bypassing the
  native cleanup path;
- kept all public entry points under the common SQLite C++ exception boundary
  and verified that connections remain reusable after callback, release, and
  deferred-constraint failures.

### Tests and documentation

- added 37 assertions covering normal values, explicit `nil`/`false`, callback
  rollback, connection reuse, three nested levels, inner and outer failure,
  managed and manual transactions, failed deferred checks at `RELEASE` and
  outer `COMMIT`, explicit callback `ROLLBACK` on both normal-return and Lua-
  error paths, strict arity, closed handles, close refusal, and workers;
- recorded a red probe before implementation, then compiled the final
  `sqlite.cpp` in C++23 with `-Wall -Wextra -Werror` and exercised the complete
  Lua campaign against a fully linked binary;
- expanded the French and English SQLite chapters in lockstep with separate
  standalone, rollback, nested, transaction, and deferred-constraint examples;
- updated version metadata, README files, release procedure, GitHub notes, and
  PDF manuals for 2.13.0.

## [2.12.0] - 2026-08-03

### Release summary

Babet 2.12.0 extends the audited SQLite surface with three connection-local
counters and two strict opening options. Existing read/write opening remains
the default; scripts may now request a genuinely read-only handle and enable
foreign-key enforcement before the first statement without issuing setup SQL.

### SQLite connection options

- added strict boolean `opts.readonly`, backed by
  `sqlite3_open_v2(..., SQLITE_OPEN_READONLY, ...)`; it never creates a missing
  database and SQLite rejects writes through the returned handle;
- preserved the historical `READWRITE | CREATE` flags when `readonly` is
  absent or false;
- added strict boolean `opts.foreign_keys`, configured directly on each native
  connection before WAL setup or user SQL; the false default is explicit and
  preserves previous behaviour;
- allowed `readonly` to combine with `busy_timeout` and `foreign_keys`, while
  rejecting the contradictory `readonly = true, wal = true` combination before
  opening a native handle; clarified that this only rejects a mode-change
  request and does not prevent read-only access to an existing WAL database;
- kept option lookup raw and strict: unknown fields, non-string keys,
  metatable-supplied values, and non-boolean values remain rejected.

### Connection counters

- added `db:last_insert_rowid()` using SQLite's signed 64-bit connection-local
  ROWID value;
- added `db:changes()` and `db:total_changes()` through their 64-bit SQLite
  APIs, returned as Lua integers;
- documented and tested that a successful `INSERT OR IGNORE` may report zero
  changes while `last_insert_rowid()` retains the previous insertion's ROWID;
- applied exact arity and closed-connection contracts to all three methods;
- exposed the same methods and opening options in worker Lua states.

### Inherited archive hardening

- extended the archive C++ exception boundary from `read()` to all six public
  archive entry points, preventing allocation and other C++ exceptions from
  crossing into Lua;
- added an explicit selected-entry completion state to the TAR in-memory sink
  and required `read()` to verify it after extraction, matching the final ZIP
  byte-count check;
- rechecked that the fixed `babet-tests.txt` journal is ignored by Git and
  excluded from both release archives.

### Tests and documentation

- added 36 focused assertions for option types and combinations, read-only
  query/write/create behaviour, enabled and disabled foreign keys, initial and
  cumulative and above-32-bit counter values, multi-row statements, closed
  handles, strict arity, ignored inserts, deferred foreign-key failure at
  `COMMIT`, and worker availability;
- recorded the red-to-green transition as 0 PASS / 5 FAIL before the public
  surface existed, then 5 PASS / 0 FAIL with the implementation;
- expanded the French and English SQLite chapters in lockstep with a separate
  example for each option and counter plus combined writer, reader, and counter
  examples;
- updated version metadata, README files, release procedure, GitHub notes, and
  PDF manuals for 2.12.0.

## [2.11.0] - 2026-08-02

### Release summary

Babet 2.11.0 adds bounded in-memory archive-entry reads through
`babet.archive.read()`. The API preserves raw names, makes duplicates
explicitly selectable by index, bounds bytes actually produced, and performs
no write. The richer `archive.list()` contract introduced in 2.8.0 remains
unchanged and directly serves as the catalogue for this new read operation.

### Bounded binary reads

- added `babet.archive.read(archive, name_or_index [, opts])`, with the strict
  `(binary_string, nil)` or `(nil, message)` result contract and support for
  empty files, NUL bytes, and non-UTF-8 data;
- added case-sensitive selection by exact raw name or by the one-based index
  exposed by `archive.list()`; a repeated raw name is rejected while an
  explicit index can deliberately select each occurrence;
- performs no sorting, deduplication, Unicode normalisation, or path
  sanitisation: a regular entry with an unsafe name can be read as data without
  ever becoming a destination path, while `list()` continues to expose
  `valid_utf8` and `safe_path`;
- rejects directories, symbolic and hard links, FIFOs, sockets, devices,
  unknown types, encrypted ZIP entries, unsupported ZIP methods, and sparse
  TAR files;
- added the strict integer `max_size` option, defaulting to 8 MiB with a
  256 MiB hard ceiling, independently of the six whole-archive limits already
  shared by the existing readers;
- checks announced size early and then checks bytes actually delivered by the
  decompression callback, including a dishonest ZIP whose metadata understates
  real output;
- copies directly into a bounded preallocated buffer, with no growth and no
  allocation on the successful data-copy path of the miniz C callback or TAR
  sink.

### Formats, integrity, and workers

- provides parity across ZIP, plain TAR, gzip TAR, xz TAR, bzip2 TAR, and zstd
  TAR with content detection and identical availability in worker Lua states;
- fully inflates and CRC-checks the selected ZIP payload;
- preserves the two-pass TAR model: full inspection and consumption, header
  comparison during the second pass, in-memory forwarding only for the chosen
  member, and gzip/zstd validation through stream end;
- documents the distinction from `archive.test()`, which remains responsible
  for validating every ZIP payload and the aggregate safety verdict;
- gives the new Lua entry point a dedicated C++ exception boundary that
  distinguishes allocation failure, standard exceptions, and unknown
  exceptions.

### Tests and documentation

- added 61 focused functional assertions covering raw-name and index
  selection, ZIP/TAR duplicates, unsafe and non-UTF-8 names, binary and empty
  data, rejected links, exact and invalid limits, dishonest expanded output,
  damaged CRC, strict options/arity, all six formats, workers, and zero
  temporary files;
- validated the focused lot at 64 PASS / 0 FAIL including the three archive
  submodule registration checks;
- expanded the French and English manuals in lockstep with separate examples
  for each selection mode, `max_size`, duplicates, unsafe names, workers, and a
  combined whole-limit example;
- updated README files, version metadata, release procedure, GitHub notes, and
  PDF manuals for 2.11.0.

## [2.10.0] - 2026-08-02

### Release summary

Babet 2.10.0 completes a source-to-test audit of `babet.sqlite`. The only new
public API is `babet.sqlite.NULL`; the remainder of the release makes existing
connection, statement, parameter, lifetime, diagnostic, and exception-safety
contracts explicit and mechanically enforced.

### Explicit SQL NULL and binding contracts

- added the singleton lightuserdata `babet.sqlite.NULL` for named, positional,
  direct, and prepared binds without weakening the exact-parameter-table rule;
- kept row conversion intentionally asymmetric: SQL `NULL` still produces an
  absent Lua table key, while SQLite INTEGER values produced from booleans read
  back as integers;
- preserved exact signed 64-bit integer binding and rejected NaN and both
  infinities before they reach SQLite;
- made named parameter lookup raw, so `__index` cannot supply or interfere with
  a bind, and rejected unsupported table key types, sparse/non-integer numeric
  keys, missing or extra values, and numbered `?NNN` placeholders;
- distinguished the exact NULL sentinel from every other lightuserdata, which
  remains an unsupported bind type;
- rejected `babet.sqlite.NULL` explicitly in JSON, worker arguments/messages,
  and channels, including atomic channel-send coverage.

### Lifetime, diagnostics, and exception safety

- preserved the SQLite step diagnostic before `reset` or `finalize` and used
  the step return code when `sqlite3_errcode()` has already become
  `SQLITE_MISUSE`, fixing constraint diagnostics after the parent `Db` userdata
  is collected;
- routed all 19 normal SQLite Lua entry points through a common C++ exception
  boundary and all four finalizers through a silent `noexcept` boundary, so an
  allocation failure cannot cross a `lua_CFunction` compiled as C;
- made every native handle finalizable before acquisition or transfer in
  `open`, direct `query`, `prepare`, and parameterized `exec` error paths;
- documented why temporary and prepared statements intentionally keep neither
  a raw `Db*` nor a Lua anchor: `sqlite3_close_v2` owns the zombie-connection
  lifetime until the last statement is finalized;
- retained a connection handle when `sqlite3_close_v2` reports failure instead
  of marking a still-owned handle as closed;
- made public arity checks exact and made `open` reject unknown options,
  non-string option keys, wrong option types, and out-of-range timeouts.

### Tests and documentation

- added five parent-collection regressions: two successful zombie-connection
  uses and three constraint diagnostics, each proving through a weak table that
  the parent userdata was actually collected;
- added 32 assertions per functional test mode for NULL, strict options and
  arity, parameter-table shape, non-finite numbers, 64-bit limits, raw named
  lookup, `?NNN`, closed handles, and cross-subsystem rejection;
- expanded the English and French SQLite manuals with separate option examples,
  explicit NULL patterns, readback rules, lifetime guarantees, diagnostics,
  intentional exclusions, and complete combined examples;
- regenerated both PDF manuals and updated release metadata and release notes
  for 2.10.0.

## [2.9.2] - 2026-08-01

### Release summary

Babet 2.9.2 is a hardening and regression-coverage release for Babet 2.9.1.
It does not change the Lua API. It strengthens worker serialization, process
and pipeline cleanup, SQLite transaction recovery, HTTP/socket exception
boundaries, inotify decoding, and the release-validation harness.

### Build and regression-test hardening

- extended the existing network-free Zstandard bootstrap preflight to ordinary
  test runs and to both release-validation builds;
- fixed an empty diagnostic when a gzip TAR was followed by a single non-zero
  byte, with regression coverage for one- and two-byte trailing data;
- hardened inotify buffer decoding with aligned fixed-header copies, explicit
  truncated-header and truncated-name checks, bounded progress, and an
  integration assertion for multiple events returned by the same read;
- hardened the `ok_fail()` test helper so an empty error string no longer counts
  as a valid failure diagnostic;
- audited all 132 `ok_raises()` assertions: the 36 calls that previously checked
  only that some Lua error was raised now require a stable diagnostic fragment,
  and the helper rejects any future call without a non-empty fragment;
- added an eight-case hermetic inotify decoder preflight and a TLS smoke test
  for an IP SAN through the statically linked OpenSSL actually used by Babet;
- realigned the French and English worker documentation with the actual `__gc`
  sequence, including the initial cancellation request, and clarified that a
  `join()` timeout does not bound a later garbage-collector `pthread_join()`.

### Worker serialization hardening

- caught allocation and JSON-construction exceptions without further C++
  allocation around `spawn` arguments, `job:send`, and `worker.send`, preventing
  exceptions from crossing a `lua_CFunction` boundary;
- added a symmetric per-operation budget of 1,000,000 expanded values and an
  estimated 64 MiB, charged before string copies and before queue publication;
- prevented exponential amplification through repeatedly shared subtables or
  strings, while guaranteeing that a rejected message is never published;
- fixed signed/unsigned JSON integer dispatch order;
- added integration coverage for exact 64-bit integer fidelity, rejection of
  `NaN` and infinities on all five transfer paths, the byte budget, and atomic
  rejected sends;
- added a network-free preflight for node and byte budget boundaries, plus one
  public-Lua-path test above one million nodes, enabled only for the normal
  folder-mode run;
- clarified pipeline grace-period semantics: all group members receive
  `SIGTERM` immediately, while zombie leaders preserve the PGID until the
  optional final signal.

### Process and pipeline exception safety

- protected the `spawn`, `exec`, `pipeline`, and `spawnPipeline` Lua boundaries
  from C++ exceptions raised during launch or synchronous processing, using
  fixed diagnostics that require no additional C++ allocation;
- added allocation-free post-`fork()` emergency cleanup: descriptor closure,
  immediate process-group `SIGKILL`, and a bounded reap attempt without the
  grace period reserved for `terminate()`;
- added RAII ownership around nominal `exec()` and `pipeline()` allocations,
  including output growth, rebuilt `poll()` vectors, and status buffers, so an
  allocation failure cannot abandon children or pipes;
- stopped cleanup signalling from ever targeting an already-reaped PID that may
  have been recycled;
- moved the 32-stage ceiling into the common launcher and validated it locally
  before any pipe creation or `fork()`;
- documented the invariant that Lua API calls are forbidden while these RAII
  guards are armed, because a Lua `longjmp` would bypass C++ destructors;
- documented that post-`fork()` OOM safety is established by structural review,
  strict compilation, and allocation-free cleanup rather than deterministic
  allocation-failure injection.

### SQLite transaction state hardening

- added explicit RAII ownership after a successful `BEGIN`, with immediate
  best-effort rollback on C++ exceptions and guaranteed reset of the
  transaction-helper-active flag;
- reserved the two callback stack slots before `BEGIN` and the final success
  slot before `COMMIT`, avoiding an unprotected Lua `longjmp` while the
  transaction guard is armed;
- delayed callback-error formatting until after rollback, so unusual Lua error
  objects cannot leave an open transaction behind;
- preserved both `COMMIT` and `ROLLBACK` diagnostics when cleanup fails, added
  one final allocation-free rollback attempt, and explicitly reports if the
  connection still remains inside a transaction;
- added integration coverage for deferred-constraint commit failure, rollback
  failure diagnostics, autocommit restoration, connection reuse, prepared
  statement reuse after rollback, and a read iterator that remains active
  across a successful commit;
- documented that `TransactionGuard` exception safety is established by
  structural review and strict compilation rather than deterministic
  `bad_alloc` injection; integration tests validate the resulting transaction
  states, cleanup, and connection reuse.

### HTTP and socket exception safety

- fixed the HTTP exception handler that still concatenated a `std::string`
  after catching `std::bad_alloc`, replacing it with a literal OOM diagnostic
  that requires no further C++ allocation;
- converted other HTTP exceptions to Lua diagnostics without C++ concatenation
  inside the handler;
- added a shared exception boundary to every public `babet.socket` function and
  method, preventing C++ exceptions from crossing a `lua_CFunction` while Lua
  is compiled as C;
- created the owning Lua userdata before acquiring an FD or OpenSSL object in
  `connect`, `listen`, `accept`, and `connect_tls`, so a Lua memory-error
  `longjmp` cannot abandon an unowned resource;
- added a dedicated `starttls` guard that restores flags before the handshake
  starts and closes the stream if an exception occurs after TLS exchange begins;
- added a local regression proving that an HTTP redirect to another origin does
  not forward the `Authorization` header;
- documented that socket OOM safety is established through structural review,
  strict compilation, and static analysis rather than deterministic
  `bad_alloc` injection.

### Release validation

The exact Babet 2.9.2 release tree passed:

- 3370 PASS / 0 FAIL in folder mode under ASan + UBSan;
- 3357 PASS / 0 FAIL in embedded mode under ASan + UBSan;
- 3357 PASS / 0 FAIL in embedded mode through `PATH` under ASan + UBSan;
- 3371 PASS / 0 FAIL in folder mode with the final normal build;
- 3357 PASS / 0 FAIL in embedded mode with the final normal build;
- 3357 PASS / 0 FAIL in embedded mode through `PATH` with the final normal build;
- 5/5 Zstandard bootstrap preflight checks;
- 8/8 inotify buffer preflight checks;
- 9/9 worker serialization budget preflight checks;
- 11 PASS / 0 FAIL / 0 WARN in the final network smoke suite.

The one-test difference between normal and sanitizer folder modes is expected:
the one-million-node worker serialization test is deliberately enabled only
once, in the normal folder-mode run.

## [2.9.1] - 2026-07-24

### HTTP fix for chunked and no-`Content-Length` responses

- fixed a regression introduced in Babet 2.9.0 while disabling
  cpp-httplib 0.45.0's internal payload cap: `0` was interpreted as a zero-byte
  limit on `Transfer-Encoding: chunked` and no-`Content-Length` read paths,
  producing `http: Failed to read connection` on the first received byte;
- replaced that value with the largest representable `std::size_t`, leaving
  Babet's own receivers as the sole authority for `max_body_size` and
  `max_file_size`;
- preserved the existing guarantees: no partial in-memory response, existing
  destination preserved on failure, download staging file removed, and an
  explicit diagnostic when the configured limit is exceeded;
- added deterministic local tests for 128 KiB chunked responses, exact and
  one-byte-below limits, downloads, fragmented chunks with extensions and
  trailers, connection-close-delimited responses, and truncated chunked
  streams;
- added independent required guards to `smoke_test_network.sh`, run by
  `run_tests.sh --release`, covering both memory and file receivers over local
  HTTPS for chunked framing and local HTTP for connection-close framing;
- validated the fix against the real AUR API use case from yaourt without
  making that external service a blocking test dependency;
- hardened the Zstandard bootstrap: an installation is now complete only when
  `libzstd.a`, `zstd.h`, and `zstd_errors.h` are all present, while an
  interrupted or incomplete source extraction is replaced automatically by a
  clean extraction through a temporary directory;
- added a network-free preflight to `run_tests.sh --release`, covering partial
  installations, partial source trees, reuse of complete sources, and rejection
  of malformed source archives.

## [2.9.0] - 2026-07-17

### Release summary

Babet 2.9.0 strengthens process supervision, binary-data handling, atomic file
publication, and concurrent worker orchestration. Existing `spawn()` and worker
calls remain compatible by default, while the new opt-in APIs remove external
Base64 commands, prevent undrained WebDriver log pipes, support bounded waits and cooperative worker
shutdown, and allow direct MPMC communication without relaying messages through
the parent Lua state.

### Lot A — configurable `babet.spawn()` redirections

- bumped the source version to 2.9.0;
- strictly preserved three non-blocking pipes as the default, leaving all
  historical calls unchanged;
- added `"pipe"`, `"inherit"`, and `"null"` modes for stdin, stdout, and
  stderr;
- added `stderr = "stdout"`, applied after stdout configuration;
- added direct stdout/stderr redirection to regular files with truncate or
  append mode, creation permissions bounded to `0777`, `O_CLOEXEC`, final
  symlink refusal, and `fstat()` verification;
- opens every redirection destination before `fork()`, so an open failure
  prevents child creation;
- added the stable `"not_piped"` reason when streaming methods target an
  inherited, null, merged, or file-redirected stream;
- added validation, special-path, truncate, append, permission, merge,
  `/dev/null`, inheritance, symlink-refusal, and compatibility tests;
- synchronised rich French and English documentation with one example per mode
  and a combined WebDriver/daemon example.

### Lot B — native binary Base64 module

- added `babet.base64.encode(data [, opts])` and
  `babet.base64.decode(text [, opts])` to the main Lua state and every worker;
- implemented the module internally with no external process and no additional
  dependency, preserving NUL bytes and non-UTF-8 data in binary Lua strings;
- added standard and URL-safe RFC 4648 alphabets through `url_safe`;
- added encoding padding control and explicit unpadded decoding through
  `padding` and `allow_unpadded`;
- applies strict canonical decoding: exact alphabet, final padding only,
  coherent length, at most two `=` characters, and rejection of truncated
  groups or non-zero unused trailing bits;
- added `ignore_whitespace` for the six ASCII whitespace bytes without making
  any other input permissive;
- added inclusive `max_output`, checked after full validation and before
  allocating decoded output;
- analyses text in two passes without an input-sized copy or position table,
  retaining exact error offsets without multiplying memory use;
- strictly validates arity, types, option keys, and unknown options, while
  separating raised call errors from invalid-data `(nil, err)` results;
- added RFC 4648 vectors, all 256 byte values, a large binary buffer,
  alphabet, padding, whitespace, limit, canonical-error, and worker tests;
- added rich French and English pages, separate examples for every option, a
  combined unpadded URL-safe example, and PDF manual integration.


### Lot C — generic atomic file writing

- added `babet.writeFileAtomic(path, data [, opts])` to the main Lua state and every worker;
- accepts binary Lua strings including NUL bytes and non-UTF-8 data, with no proportional intermediate copy in the binding;
- added strict `overwrite` (`false`), `permissions` (`0644`), and `durable` (`true`) options;
- creates a private mode-`0600` temporary file in the final directory, writes fully while handling `EINTR` and partial writes, applies `fchmod()` before synchronization, then publishes atomically;
- rejects overwrite by default through no-replace `linkat()` publication, while explicit replacement of a regular file uses `renameat()`;
- walks parents component by component with `openat()`/`O_NOFOLLOW`, rejecting `..`, symlink parents, a final symlink, and directory, FIFO, socket, or device destinations;
- never creates parents implicitly and best-effort removes every temporary file after a pre-publication failure;
- synchronizes the temporary file and parent directory by default, with an explicit diagnostic if publication already succeeded but rename persistence could not be confirmed;
- added binary, empty-file, overwrite, permissions, non-durable, special-path, symlink, special-type, validation, cleanup, and worker tests;
- added detailed French and English chapters, one example per option, a combined Base64/Selenium example, and PDF-manual integration.


### Lot D — robust worker lifecycle

- strictly rejects every unknown option and every non-string option key in `babet.workers.spawn()`, including names with a hidden NUL suffix;
- added non-blocking, non-consuming `job:status()` with stable `"running"`, `"done"`, and `"error"` states;
- extended `job:join(timeout?)` with monotonic second-based deadlines, non-blocking `0`, and `(nil, "timeout")` without closing queues, joining the pthread, or consuming the result;
- added a pthread completion signal separate from message queues, protected against lost wakeups and used by all success, Lua-error, and C++-exception paths;
- added idempotent cooperative `job:cancel()` and worker-side `worker.cancelled()`;
- cancellation closes only the inbox, wakes `worker.recv()` with `"cancelled"`, rejects future `job:send()` calls with the same reason, and leaves the outbox drainable for a final message;
- documented the distinction between `close()` — normal command completion with draining — and `cancel()` — cooperative abandonment of queued commands;
- garbage collection now requests cancellation before closing both queues and joining the thread, without adding unsafe forced termination;
- added non-consuming status, immediate and bounded join timeouts, messaging after a join timeout, final-error and validation coverage, idempotent cancellation, blocked-`worker.recv()` wakeup, queued-inbox abandonment, final-outbox-message, and direct cancellation-flag tests;
- synchronized rich French and English documentation with separate and combined `status`/`join(timeout)`/`cancel` examples.


### Lot E — direct shared worker channels

- added `babet.workers.channel({ capacity = 64 })`, a thread-safe bounded FIFO
  queue supporting 1 to 1,000,000 messages and multiple producers/consumers;
- added explicit handle passing through
  `workers.spawn(..., { channels = ... })` and an always-present
  `worker.channels` table without changing the JSON contract of `worker.args`;
- added `channel:send(value, timeout?)`, `channel:recv(timeout?)`,
  `channel:close()`, and `channel:is_closed()` with stable `full`, `empty`,
  `timeout`, and `closed` reasons;
- made global close idempotent, wake blocked producers/consumers, reject new
  sends, and drain already queued messages before `recv()` reports `closed`;
- integrated cooperative cancellation: `job:cancel()` wakes the affected
  worker's blocked `channel:send()` or `channel:recv()` with `cancelled`
  without closing the shared channel for other participants;
- shared the C++ resource through reference-counted handles, so collecting one
  local handle does not close the channel for other Lua states while the last
  reference safely closes and destroys the queue;
- refactored worker serialization error contexts so channel diagnostics name
  `workers.channel.send` or `workers.channel.recv` precisely;
- added strict validation for options, capacities, channel names,
  `opts.channels` values, arity, and transferred values; channels deliberately
  remain non-serializable as messages;
- added parent-to-worker, worker-to-parent, worker-to-worker, FIFO, `nil`,
  close/drain, blocked-wakeup, handle-lifetime, two-producer/two-consumer, and
  MPMC stress tests;
- validated 100,000 messages, 2,000 cancellation races, and 1,000 close races
  in native tests under normal compilation, ASan+UBSan, and ThreadSanitizer;
- synchronized README, French/English documentation, detailed examples, and
  both PDF manuals.

### Release validation

The final release candidate passed:

- 3319 PASS / 0 FAIL in folder mode;
- 3306 PASS / 0 FAIL in embedded mode;
- 3306 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes under ASan + UBSan;
- 9/9 runtime modes again with the final normal build.

The complete release gate, including local TLS and network smoke tests, remains:

```sh
./run_tests.sh --release
```

## [2.8.0] - 2026-07-17

### Release summary

Babet 2.8.0 completes the archive lifecycle with bounded inspection, full
integrity and safety testing, selective extraction, and read-only extraction
previews. ZIP and plain/gzip/xz/bzip2/zstd TAR readers share strict limits,
deterministic diagnostics, worker support, and the existing confined
destination policy.

The optional in-memory `archive.read()` proposal was reviewed and deliberately
deferred: `extractFile()` already covers targeted extraction, while a new Lua
string-returning API would add another allocation and size contract without
being required by the 2.8.0 theme.

### Lot 1 — advanced archive inspection

- bumped the source version to 2.8.0;
- preserved the bounded historical `babet.archive.list(archive [, opts])` API
  and its `format`/`compression`/`entries` wrapper instead of adding a
  redundant iterator;
- strictly preserves internal entry order without sorting or deduplication;
- added per-entry `index` and `valid_utf8`, preserving names exactly as binary
  Lua strings without Unicode normalisation;
- added `mtime`, `mtime_nsec`, `uid`, and `gid` when genuinely supplied by the
  backend, with explicit `nil` when unavailable;
- added deterministic `duplicate`/`duplicate_of` diagnostics for repeated raw
  names and `conflict`/`conflict_with`/`conflict_reason` for normalised output
  path or file/directory collisions;
- added global `total_name_bytes`, `duplicates`, and `conflicts` aggregates;
- added strict `max_path_length` (64 KiB default, 1 MiB hard cap) and
  `max_total_name_bytes` (64 MiB default and hard cap), shared with `extract()`
  and `extractFile()`;
- kept the independent 4096-byte extractable-path rule: longer names may be
  inspected within the metadata budget but remain `safe_path = false`;
- bounded the prefix graph used for collision diagnostics to 100000 directories
  and 64 MiB of cumulative paths;
- clarified integrity scope: `list()` inventories and diagnoses ZIP metadata
  without inflating every payload, while TAR must be consumed to its end to
  reach every header;
- added ZIP/TAR tests for metadata, order, invalid UTF-8, duplicates, normalised
  collisions, split/truncated archives, exact and tightened limits, workers,
  and no writes before extraction;
- systematically expanded French and English documentation with one example
  per option, combined examples, security diagnostics, ZIP/TAR differences,
  and worker usage.

### Lot 2 — complete integrity and safety verification

- added `babet.archive.test(archive [, opts])` to the main Lua state and
  workers, with the strict `(result, nil)` or `(nil, message)` contract;
- detects ZIP, TAR, gzip TAR, xz TAR, bzip2 TAR, and zstd TAR from content
  without writing or creating any temporary directory;
- strictly reuses the existing shared `max_entries`, `max_entry_size`,
  `max_total_size`, `max_path_length`, `max_total_name_bytes`, and
  `max_compression_ratio` limits;
- fully validates ZIP EOCD/ZIP64 metadata, local headers, names, flags, methods,
  sizes, CRCs, ZIP64 fields, data descriptors, bounds, and overlap, then fully
  decompresses every non-directory entry;
- fully consumes plain and compressed TAR streams, checking headers, available
  checksums, truncation, padding, corruption, and trailing data according to
  libarchive, zlib, liblzma, libbz2, and libzstd guarantees;
- applies a strict safety verdict, rejecting unsafe paths, duplicates,
  file/directory collisions, links, sparse files, special objects, encrypted
  entries, and unsupported ZIP methods;
- returns a deterministic `format`, `compression`, `entries`, `files`,
  `directories`, `total_size`, `archive_size`, `total_name_bytes`, and `zip64`
  summary;
- added ZIP/TAR, empty archive, damaged local header, data descriptor, CRC,
  per-compression corruption, limit, worker, and zero-side-effect tests;
- synchronised rich French and English documentation with one example per
  limit, combined examples, the `list()`/`test()` distinction, and worker use.

### Lot 3 — selective extraction through safe globs

- added strict `include` and `exclude` options to
  `babet.archive.extract()` without changing `extractFile()` or historical
  unfiltered calls;
- shared parsing, compilation, limits, and work accounting with the existing
  `safe_glob` engine already used by `archive.create()`;
- anchored, byte-oriented, case-sensitive matching on normalised internal
  paths with identical `*`, `**`, `?`, and `\` rules;
- made `exclude` always win, including pruning an entire directory subtree even
  when parent directories are implicit;
- limited type, duplicate, and output-collision validation to selected entries
  while retaining whole-archive header scanning and global limits;
- creates no destination when active filters select nothing and creates only
  the parents required by retained files;
- added `entries` and `skipped` result fields while preserving `files`,
  `directories`, `bytes`, and `path`;
- applies identically to ZIP, plain TAR, gzip TAR, xz TAR, bzip2 TAR, zstd TAR,
  and worker Lua states;
- added extensive ZIP/TAR tests for include-only, exclude-only, precedence,
  subtree pruning, escaping, limits, empty selection, unselected duplicates and
  collisions, skipped unsafe or special entries, compressed formats, and
  workers;
- synchronised rich French and English documentation with separate and combined
  examples, side effects, limits, and the selective-extraction versus
  `archive.test()` integrity distinction.

### Lot 4 — extraction preview without filesystem mutation

- added strict boolean `dry_run` to `babet.archive.extract()` without exposing
  it to `list()`, `test()`, or `extractFile()`;
- reused the exact same archive scan, anti-bomb limits, `include`/`exclude`
  filters, normalisation, and destination plan as real extraction;
- traversed the destination read-only through directory descriptors,
  `openat`/`fstatat`, and `O_NOFOLLOW`, with no mkdir, temporary file, write,
  chmod, rename, unlink, or publication operation;
- added `would_create`, `would_overwrite`, `would_skip`, and
  `would_create_destination`, counting explicit selected entries only and
  remaining absent from the historical real-extraction result;
- preserved strict overwrite policy: an existing file remains an error without
  permission, while an explicitly selected existing directory is reported as
  retained;
- genuinely verified selected ZIP payloads through a null consumer, including
  decompression and CRC, and performed the complete second TAR pass without
  forwarding data to the filesystem;
- kept an empty active selection inert without inspecting or creating the
  destination, while an unfiltered empty archive previews possible root
  creation;
- added ZIP, TAR, and compressed-TAR tests for missing and existing destinations,
  overwrite on and off, filters, limits, duplicates, corruption, symlinks,
  file/directory conflicts, workers, and complete absence of mutation;
- documented that the preview is a snapshot rather than a guarantee against
  concurrent destination changes before a later extraction.

### Final release audit

- audited the C++ implementation, Lua registration, strict option validation,
  worker registration, test coverage, README files, online help, build/test/
  release scripts, licences, and French/English documentation against the
  actual code and tests;
- confirmed that `archive.list()`, `archive.test()`, `archive.extract()`, and
  `archive.extractFile()` expose only their documented options and return
  fields, with `dry_run`, `include`, and `exclude` limited to full extraction;
- added the dedicated `GITHUB_RELEASE_2.8.0.md` publication notes and finalised
  the release checklist;
- regenerated both PDF manuals from the final Markdown sources and performed a
  rendered visual review;
- retained the last validated runtime results: 3067 PASS / 0 FAIL in folder
  mode, 3054 PASS / 0 FAIL in embedded mode, 3054 PASS / 0 FAIL through
  `PATH`, and 9/9 modes under both ASan/UBSan and the normal build.

## [2.7.0] - 2026-07-16

### Release summary

Babet 2.7.0 adds a dedicated secure API for standalone compressed streams and
extends archive creation with explicit multi-root sources plus bounded
include/exclude filtering, while preserving the audited ZIP and TAR contracts
from the 2.6 series.

- bumped the source version to 2.7.0;
- added `babet.compression.compress(source, destination, format [, opts])`;
- added `babet.compression.decompress(source, destination [, opts])`;
- supports standalone gzip, xz, bzip2, and zstd streams;
- detects decompression format from magic bytes rather than filename
  extensions;
- accepts valid concatenated members/streams/frames and rejects arbitrary
  trailing bytes;
- verifies codec integrity data and rejects corrupted or truncated streams;
- streams through bounded 64 KiB buffers without loading whole files into Lua;
- added `max_output_size` for decompression (1 GiB default, 64 GiB hard cap);
- pins source descriptors, rejects source/destination symlinks and parent
  symlink components, detects same-inode destinations, and revalidates source
  size/timestamps before publication;
- stages output in the destination directory and publishes atomically, with
  `overwrite = false` by default;
- registered the module in main and worker Lua states;
- added strict argument/option validation and binary, empty-file, limit,
  corruption, trailing-data, symlink, hard-link, worker, and cleanup tests;
- added complete English and French module documentation;
- added strict `level` selection for compression with stable per-format
  defaults and ranges: gzip 0-9 (default 6), xz 0-9 (default 6), bzip2 1-9
  (default 9), and zstd 1-22 (default 3);
- rejects floats, numeric strings, and out-of-range levels before opening the
  source, with format-specific diagnostics and regression coverage;
- extended `babet.archive.create()` so its first argument may be a non-empty
  dense array of explicit regular-file and directory paths while preserving
  the historical single-directory string contract;
- roots every explicit source at its final basename, accepts absolute sources
  without leaking host path prefixes, preserves directory prefixes when
  directory entries are omitted, and reports the selected path count through
  `result.sources`;
- rejects empty/sparse/mixed source tables, `..`, unstable root names, source
  symlinks and symlinked parents, unsupported filesystem objects, duplicate or
  colliding top-level basenames, and destinations inside any selected source;
- pins one descriptor root per explicit source, applies entry/size/node/depth
  limits across the complete list, sorts final archive names independently of
  input order, and supports the same ZIP and compressed/uncompressed TAR
  backends, workers, atomic publication, and deterministic output;
- added strict `include` and `exclude` dense arrays to `archive.create()`,
  matched case-sensitively against final archive paths through the existing
  bounded safe-glob engine; exclusions always win and excluded directories are
  pruned before opening;
- retains required parent directory entries for deep matches, supports matched
  empty directories and valid empty archives, applies filters consistently to
  historical and explicit-list sources, and ignores unselected special objects
  while continuing to reject them when selected;
- bounds filtering to 4096 bytes per pattern, 256 combined patterns, 256 KiB of
  total pattern text, one million pattern evaluations, and a fixed
  100,000,000-cell matching-work budget, with
  strict table/string/NUL/escape validation, worker coverage, ZIP/TAR parity,
  deterministic-order tests, and synchronized English/French documentation;
- completed the final function-by-function audit of the changed C++ bindings,
  Lua tests, examples, English/French documentation, security notes, release
  checklist, and generated PDF manuals.

Final core validation for this release:

- 2844 PASS / 0 FAIL in folder mode;
- 2831 PASS / 0 FAIL in embedded mode;
- 2831 PASS / 0 FAIL in embedded mode through `PATH`;
- 9/9 runtime modes passed under ASan + UBSan;
- 9/9 runtime modes passed again with the final normal build.

The release gate additionally runs the local TLS and network smoke tests through
`./run_tests.sh --release` before the commit is tagged.

## [2.6.1] - 2026-07-16

### Maintenance release

- bumped the patch version to 2.6.1;
- regenerated and republished the English and French PDF manuals so the
  generated documentation matches the 2.6.0 source documentation;
- made no runtime or public API change.

## [2.6.0] - 2026-07-16

### Release summary

Babet 2.6.0 adds secure multi-format TAR support, bounded filename matching,
and consistent strict validation across the public Lua bindings while
preserving the audited 2.5.0 contracts for ZIP and existing APIs.

- bumped the source version to 2.6.0;
- added a reproducible static integration of libarchive 3.8.8 from the
  official distribution verified with SHA-256;
- initially limited libarchive to its core and uncompressed TAR, then enabled
  gzip through a separately pinned static zlib, xz through a separately
  pinned static XZ Utils/liblzma, bzip2 through a separately pinned static
  libbz2, and zstd through a separately pinned static libzstd;
- added an early runtime check that the linked libarchive headers and library
  match;
- added the libarchive licence notice to binary distributions;
- extended `babet.archive.list()` with content-based detection of uncompressed
  TAR archives while keeping miniz as the unchanged ZIP backend;
- added progressive TAR metadata and data scanning through libarchive, with
  entry-count, per-entry-size, total-size, pathname-memory, and truncation
  checks;
- exposed canonical archive-level `format` and `compression` fields, plus TAR
  entry types, link targets, sparse metadata, and explicit `nil` values for
  ZIP-only CRC/compression fields;
- added secure complete extraction of uncompressed TAR archives while keeping
  miniz as the unchanged ZIP extraction backend;
- added a two-pass TAR extraction plan: Babet scans the whole pinned archive,
  validates paths, limits, duplicates, conflicts, and destination types, then
  rereads the same descriptor and compares every header before staging data;
- reused the descriptor-confined destination layer, mode-`0600` same-directory
  temporaries, bounded writes, atomic per-file publication, cleanup, workers,
  and safe permission policy for TAR;
- deliberately refuses TAR sparse files, symlinks, hard links, FIFOs, sockets,
  devices, and unsupported types before any file is published;
- extended `babet.archive.extractFile()` to uncompressed TAR with exact raw-name
  selection, whole-archive limits, a verified second pass, streamed discard of
  unselected data, and the existing confined atomic destination layer;
- allows a safe TAR regular file to be selected even when unrelated entries
  have unsafe paths, special types, or sparse maps, while still rejecting a
  selected sparse file and malformed data anywhere in the archive;
- extended `babet.archive.create()` to deterministic uncompressed TAR output
  through libarchive's restricted POSIX pax writer, while keeping miniz as the
  unchanged ZIP writer;
- added `.tar` format inference plus strict `format = "zip" | "tar"`, preserved
  ZIP as the backward-compatible fallback for other extensions, and at that
  stage kept compressed TAR suffixes explicitly disabled;
- streams source files through pinned descriptors into TAR, checks the source
  inode, size, mtime, and ctime before and after reading, supports pax long
  paths, empty directories, workers, atomic whole-archive publication, and
  deterministic UID/GID/mode/timestamp metadata;
- hardened `build_local.sh` with a content fingerprint for `src/` and
  `CMakeLists.txt`; when sources copied from a ZIP have misleading old
  timestamps, Babet now cleans only its own CMake objects instead of silently
  reusing stale code;
- added a reproducible static integration of zlib 1.3.2, verified by
  SHA-256, and enabled only libarchive's internal gzip filter;
- extended `list()`, `extract()`, and `extractFile()` to gzip-compressed TAR,
  detected by content, with full-stream CRC/truncation checks and the same
  pinned-source, two-pass, atomic-publication, worker, and special-type policy;
- extended `create()` with `.tar.gz` and `.tgz` inference plus strict
  `format = "tar.gz"`, levels `0` through `9`, deterministic zero gzip mtime,
  and byte-for-byte reproducible output;
- applied `max_compression_ratio` to gzip TAR as a bounded global ratio between
  announced regular-file bytes and the complete compressed archive size;
- added a libarchive build profile so a cached library compiled without the
  requested gzip, xz, bzip2, or zstd filters is rebuilt automatically when the dependency
  configuration changes;
- added a reproducible static integration of XZ Utils/liblzma 5.8.3, verified
  by SHA-256, and forced both its headers and `liblzma.a` to come from the local
  project build rather than the host distribution;
- extended `list()`, `extract()`, and `extractFile()` to xz-compressed TAR,
  detected by content, with the same full-stream validation, pinned-source,
  two-pass, atomic-publication, worker, and special-type policy;
- extended `create()` with `.tar.xz` and `.txz` inference plus strict
  `format = "tar.xz"`, levels `0` through `9`, deterministic output, and
  explicit `format = "tar"` / `compression = "xz"` result metadata;
- generalized `max_compression_ratio` to gzip-, xz-, bzip2-, and zstd-compressed TAR;
- added an early runtime check that the compile-time and linked liblzma
  versions match, mirroring the existing zlib consistency check;
- added a reproducible static integration of bzip2/libbz2 1.0.8 from the
  official Sourceware distribution, verified by SHA-256, with both `bzlib.h`
  and `libbz2.a` forced to come from the local project build;
- enabled only libarchive's internal bzip2 filter and extended `list()`,
  `extract()`, and `extractFile()` to bzip2-compressed TAR detected by content,
  with the same pinned-source, two-pass, atomic-publication, worker, corruption,
  ratio-limit, and special-type policy as gzip and xz;
- extended `create()` with `.tar.bz2`, `.tbz2`, and `.tbz` inference plus strict
  `format = "tar.bz2"`, levels `1` through `9`, deterministic output, and
  explicit `format = "tar"` / `compression = "bzip2"` result metadata;
- added an early runtime check that the linked libbz2 version starts with the
  pinned 1.0.8 version injected by CMake;
- added reproducible static integration of Zstandard/libzstd 1.5.7, verified by
  SHA-256, with locally built headers and `libzstd.a` forced into libarchive and
  Babet instead of any host-distribution copy;
- enabled only libarchive's internal zstd filter and extended `list()`,
  `extract()`, and `extractFile()` to content-detected zstd-compressed TAR, with
  complete-frame validation through libzstd, concatenated-frame support,
  trailing-data and corruption rejection, global ratio limits, pinned-source
  two-pass extraction, atomic publication, and workers;
- extended `create()` with `.tar.zst`, `.tar.zstd`, and `.tzst` inference plus
  strict `format = "tar.zst"`, levels `0` through `19`, deterministic output,
  and explicit `format = "tar"` / `compression = "zstd"` result metadata;
- worked around libarchive 3.8.8's custom-write-callback issue for zstd by using
  its built-in `archive_write_open_fd()` path for that filter while retaining
  Babet's pinned temporary descriptor and atomic whole-archive publication;
- added an early runtime check that the libzstd header and linked-library
  versions match exactly;
- audited every `std::regex` use and confirmed that only `babet.find()` used
  it;
- added bounded `glob`, `iglob`, `path_glob`, and `path_iglob` filters to
  `babet.find()`;
- implemented the safe glob matcher as a non-recursive dynamic-programming
  automaton with `*`, `**`, `?`, and backslash escaping, a 4096-byte pattern
  ceiling, anchored whole-string matching, ASCII-only case folding for the
  insensitive forms, and no catastrophic backtracking;
- replaced the remaining `std::regex` implementation behind `name`, `iname`,
  and `path` with statically linked RE2 2025-11-05 and Abseil 20250814.2,
  downloaded and SHA-256 verified by `build_local.sh` instead of using host
  packages;
- preserved `name`/`iname` full-match and `path` partial-search semantics,
  while documenting the intentional RE2 syntax differences such as rejection
  of backreferences and look-around assertions;
- bounded each RE2 pattern to 4096 bytes and each compiled expression to a
  1 MiB memory budget, using Latin-1 byte mode so Linux filenames containing
  non-UTF-8 bytes remain matchable;
- added shared, allocation-free Lua validation predicates for exact or bounded
  arity, strict strings, numbers, integers, booleans, optional `nil`, and
  embedded-NUL-safe strings;
- harmonized public bindings around those validators, removing accidental
  number-to-string coercions, rejecting surplus arguments where the documented
  signature is fixed, and preserving non-`longjmp` error paths while C++
  objects are alive;
- strengthened validation tests for `find`, filesystem listings and iterators,
  tree copies, `exec`, signals, workers, and archive options;
- fixed release packaging so the existing French README (`README.fr.md`) is
  included under its actual filename;
- completed the final code/tests/documentation audit, synchronized the French
  and English references, corrected the RE2 escaping example, and regenerated
  both PDF manuals for the 2.6.0 release;
- added deterministic pure-Lua TAR fixtures for ustar prefixes, GNU long
  names, pax paths, links, sparse files, special types, unsafe paths, limits,
  corruption,
  truncation, concatenated archives, trailing foreign data, symlinked inputs,
  extraction contents, permissions, overwrite, destination symlink attacks,
  cleanup, single-file selection, mixed and concatenated archives, sparse
  selection policy, and worker states.

ZIP creation, listing, and extraction continue to use miniz with their 2.5.0
contracts. Plain, gzip-, xz-, bzip2-, and zstd-compressed TAR creation, listing,
complete extraction, and single-file extraction use libarchive with static
zlib, XZ Utils/liblzma, libbz2, and libzstd. Standalone compressed streams
remain a separate later decision.

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
