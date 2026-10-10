# Babet invariants and development guardrails

This document is the reference for the constraints that must survive future
Babet work. It deliberately separates product contracts from development
methodology and from design decisions that are specific to current roadmap
items.

Babet's core goal is simple:

> **One file to copy, one file to run.**

The convenience of Lua scripting and autonomous deployment takes precedence
over micro-optimisation and unnecessary architectural complexity. Linux is the
reference platform for the current roadmap.

## 1. Product contracts

### 1.1 `--create-exe` requires no external toolchain at use time

Normal use of:

```sh
babet --create-exe <project> <output>
```

must not require GCC, Clang, `ld`, CMake, static development archives, a SDK, or
any additional compilation environment on the machine where the command is
run.

`--create-exe` is a packaging operation, not a compile/link pipeline.

### 1.2 The official Babet binary remains autonomous

The official Linux Babet binary is intentionally built largely statically. A
normal deployment must not require carrying a collection of Babet-specific
shared libraries next to the executable.

The exact set of unavoidable platform dependencies may be measured during
release validation, but adding a required `libbabet.so` dependency to the
normal Babet executable would violate this contract.

### 1.3 `--create-exe` produces one autonomous application file

A generated application must not require:

- a Babet `.so` next to it;
- a runtime directory;
- mandatory external resources;
- Babet to be installed on the target machine.

The intended workflow remains:

```sh
babet --create-exe ./project application
scp application server:
./application
```

and nothing else must be required for Babet-specific runtime support.

### 1.4 A generated application is not a builder

An executable produced by `--create-exe` is a final application. It must refuse
an attempt to invoke Babet's `--create-exe` builder mode.

The refusal and the execution mode must use one source of truth. Since audit
batch 15, this is the descriptor in the loaded executable image, patched by
the builder before publication. ZIP contents validate the application payload;
they do not determine its identity. A marked application with a damaged or
missing ZIP/main.lua must fail before interpreting any CLI arguments.

Renaming or copying the original Babet executable must not remove its builder
capability:

```sh
cp babet toto
./toto --create-exe ./project application
```

must remain valid.

**Current development status after audit batch 15:** the loaded descriptor
replaces the historical `main.lua`-presence identity test, which could turn a
truncated application into a builder. The runtime reserves `--create-exe` / `-c`
in valid generated applications and refuses damaged applications at startup.
The original runtime remains a builder when copied, renamed or stripped before
packaging. Existing generated executables retain their bundled older runtime;
rebuild them to obtain the new format and protection.

The version-1 descriptor occupies 64 bytes in the loaded `.babet_image`
section: a 32-byte magic, little-endian 32-bit version and flag, little-endian
64-bit ZIP offset and size, then an FNV-1a-64 checksum over the first 56 bytes.
It uses volatile reads and a live code reference so optimization and section
garbage collection retain the actual patched data; `used` alone is insufficient
for linker garbage collection. The builder requires exactly one occurrence
in the copied runtime prefix, validates it as bare, patches the private output,
then publishes atomically. The checksum detects accidental descriptor damage;
it is not cryptographic authentication. ZIP bounds must exactly match EOF.
The image itself is still opened through `/proc/self/exe`: reading the identity
from memory does not add support for launching without procfs. Strip the bare
runtime before packaging; rewriting a generated image can invalidate its bounds.
UPX compression of a bare runtime is unsupported for `--create-exe`: the loaded
identity survives decompression, but the builder cannot patch a descriptor
hidden in the compressed file. `build_and_deploy.sh` must preserve the built
runtime and check packaging/execution before installing it. Its regression
uses an UPX command trap and redirects privileged installation into a private
fixture; optional runtime coverage exercises actual UPX when available.
The deployment smoke application runs under the build tree, so a noexec
`TMPDIR` does not prevent installation. Prepare mode `0755` in a temporary file
in the installation directory, then atomically rename it onto the final path.
Never overwrite the installed inode in place: running processes must retain
their original image and a failed copy must preserve the previous installation.
If `/usr/local/bin/babet` is a symbolic link, installation replaces the link
itself with the new executable and leaves the link's target unchanged.
This is atomic visibility, not an fsync-based power-loss durability guarantee.

### 1.5 A generated application contains the complete Babet runtime

`--create-exe` is not expected to build a reduced runtime containing only the
functions detected as used by a script. A small script may therefore produce
an application close to the size of the complete Babet runtime.

Babet must not be recompiled or relinked on every `--create-exe` invocation
merely to save a few megabytes.

## Product-contract protection

The table below records the protection that actually exists. It must not claim
coverage that the test suite does not provide.

| Product contract | Current protection | Roadmap action |
| --- | --- | --- |
| `--create-exe` needs no external toolchain at use time | `tests/test_packaging.sh` invokes the real builder with an empty `PATH` and requires executable creation to succeed, protecting against accidental PATH-resolved compiler/linker/tool dependencies. | Keep this focused packaging regression in the normal/release harness. |
| Official Babet remains autonomous | Lot 1 records the published binary `ldd` baseline; Lot 6 `tools/test_embedding_runtime.sh` additionally rejects any dynamic `libbabet.so` dependency on the freshly built official binary while the CLI links the reusable runtime statically at build time. | Keep the release baseline and the focused embedding autonomy check. |
| `--create-exe` produces one autonomous application file | `tests/test_packaging.sh` requires exactly one published application file, deletes the source project, and runs that file from an unrelated empty directory. `run_tests.sh` also retains its broader embedded-mode/PATH integration coverage. | Keep both focused and broad integration coverage. |
| Generated application is not a builder | `tests/test_packaging.sh` checks refusal of both builder flags and preserves the copied/renamed runtime's builder capability. `tools/test_image_identity.py` exercises false ZIP signatures, truncation, trailing data, corrupt metadata, missing main.lua, duplicate descriptors and stripped runtimes. | Keep the loaded descriptor as the single identity source and validate its archive before executing Lua. |
| Generated application contains the complete runtime | Broadly exercised indirectly by the embedded-mode self-test suite, which runs the packaged executable against the Babet APIs. There is **no focused contract test** asserting a particular binary composition. | Keep the contract architectural; add a focused test only if a simple stable assertion becomes useful. |
| Embedding public boundary is controlled and C-only | `tools/test_embedding_contracts.sh` requires an opaque context, no public Lua/STL/C++ implementation types, explicit status codes, one-context/same-thread first semantics, static-first `libbabet.a`, and no shared-library build claim. The runtime smoke host is written in C. | Keep the ABI experimental until real host use justifies freezing/expanding it. |

When a contract becomes explicitly covered by a new test, this table must be
updated in the same lot.

## 2. Development principles

These rules guide development. They are intentionally weaker than the product
contracts above and may evolve when evidence justifies a change.

- Prefer the simplest design that preserves autonomy, robustness, and Lua
  scripting comfort.
- Do not optimise binary size for its own sake. Track it to detect unexplained
  growth, not to chase a few hundred kilobytes.
- A roughly 13 MiB largely static binary is not inherently a problem; an
  unexplained drift toward 20-30 MiB should be investigated.
- Do not add a package manager in the style of `pip`, npm, or similar systems.
- Keep current modules/features in the core unless a concrete, measured reason
  justifies moving them.
- Do not modularise purely for aesthetics.
- Do not advertise a supported configuration that is not tested.
- Protect verifiable invariants with tests whenever this can be done simply and
  robustly.
- Work in small, independently green, testable, committable lots.
- Do not accumulate a large broken refactor across multiple releases.
- Linux remains the reference platform for this roadmap.
- Windows work is deferred until the Linux implementation is mature enough to
  make the portability boundary worth stabilising.

## 3. Current-work design decisions

The decisions in this section are specific to the current roadmap. They are not
fundamental Babet product contracts and should be revised or removed when their
corresponding work is completed or superseded.

### 3.1 Binary-size measurement

Lot 1 is a measurement pass, not an optimisation campaign. Record the stripped
x86_64 release binary size and inspect `file`, `ldd`, `size -A`, and unexpected
large debug sections. Historical release measurements are kept in
[BINARY_SIZE.md](BINARY_SIZE.md). Only investigate further if the result is
anomalous.

Do not introduce aggressive OpenSSL trimming, LTO, section-garbage collection,
or similar work merely to make the number smaller.

### 3.2 Explicit self-test accounting

Lot 2 replaced the former opaque folder/embedded total delta with explicit
`common`, `folder`, `embedded`, and `single-run` categories. New packaging
regressions must preserve this model rather than reintroducing a fixed numeric
difference between execution modes.

### 3.3 `ncursesw` terminal ownership

The reviewed Lot 4 implementation contract is kept in
[NCURSES_DESIGN.md](NCURSES_DESIGN.md). Lot 5 implements that contract; the
document remains the detailed source of truth for terminal lifecycle, signal,
terminfo, UTF-8 and test decisions. Structural implementation contracts are
protected by `tools/test_ncurses_runtime_contracts.sh`; live terminal behavior
is exercised by `tools/test_curses_pty.sh`.

The curses implementation targets `ncursesw`, not narrow-character ncurses, to
match Babet's UTF-8 orientation.

The terminal ownership invariant for that work is:

> **At any instant, exactly one subsystem owns the interactive terminal.**

The conceptual states are:

```text
normal
curses
child_process
terminal_reclaimed_curses_pending
```

The existing process/spawn terminal lifecycle must be reused or unified; a
second independent terminal manager must not be introduced.

All ncurses calls belong on the main thread. A monitor thread may reclaim the
terminal at the POSIX level after a child exits (`tcsetpgrp`, termios, internal
state), but it must only mark curses restoration as pending. A central helper on
the main thread performs `reset_prog_mode()`, `doupdate()`, redraw, or equivalent
curses restoration at a safe API entry point.

Interactive spawn during a curses session follows one-owner transitions:

```text
curses -> suspended curses -> child_process -> reclaimed terminal
       -> pending curses restore -> curses
```

A worker attempting an interactive spawn while curses is active should receive
a clear Lua error rather than forcing complex cross-thread terminal ownership.

Signal policy (`SIGWINCH`, `SIGTSTP`, `SIGCONT`, `SIGINT`, `SIGTERM`, `SIGHUP`)
remains Babet-owned and must integrate with the same terminal state machine.
Fatal-signal handlers such as `SIGSEGV`/`SIGABRT` must not call ncurses.

`TERM` missing/unknown and missing terminfo must become controlled Lua errors,
not uncontrolled library `exit()` calls.

### 3.4 `libbabet` / embedding

Embedding work comes after the packaging and ncurses lots are stable. The goal
is a C/C++ host using a Babet runtime library without making the official
`babet` executable depend obligatorily on `libbabet.so`.

Lot 6 starts with an **experimental C ABI over static `libbabet.a`**. The public
header exposes an opaque context and status-based lifecycle only; it does not
expose `lua_State`, STL types, C++ classes or exceptions. This first surface is
explicitly not frozen until a real host has exercised it.

The first implementation supports one live embedding context per process and
requires create/use/destroy on the same host thread. That reflects existing
process-wide signal, terminal and main-thread ownership rather than pretending
that independent concurrent runtimes are already safe.

The official CLI may reuse `libbabet.a` at **link time**, but the distributed
`babet` executable remains autonomous and must not acquire a dynamic
`libbabet.so` dependency. A shared-library artifact is reconsidered only after
the API has been exercised and the PIC/dependency cost of Babet's pinned static
third-party stack is understood.

If a later internal split into runtime/CLI/builder is useful, it should be
introduced because embedding needs it, not for aesthetic layering. Lot 6's
initial split is limited to sharing `register_babet()` and terminal-aware Lua
teardown between CLI, workers and embedding.

### 3.5 Optional GUI

The active GUI contract is [GUI_DESIGN.md](GUI_DESIGN.md). `babet.gui` is an
optional system-dependent feature, not a statically linked toolkit and not a
native-plugin companion. The normal Babet build must not link, download or
require GTK development files. The first implementation target is GTK 4, loaded
lazily from the system with `dlopen()` / `dlsym()` only when GUI use is
explicitly requested.

A script that never initializes `babet.gui` must keep the same runtime behaviour
and autonomy on a machine without GTK. A generated GUI application still
consists of exactly one file, but GTK 4 becomes an explicit target-system
runtime dependency; this is the only accepted autonomy exception for that GUI
feature. Missing GTK or display initialization must fail through a controlled
Babet/Lua diagnostic rather than an abort.

GUI work is main-thread only. An active GUI session and an active ncurses
session are mutually exclusive, Lua callbacks from the toolkit must remain
inside a protected Lua-call boundary, and Lua widget handles must be invalidated
when their native widget dies. GTK initialization must use
`gtk_disable_setlocale()` followed by `gtk_init_check()`, never uncontrolled
`gtk_init()`.

DrawingArea's Cairo context is borrowed only during its `onDraw` call. Protect
argument allocation and callback execution against Lua errors, then invalidate
the context before returning to GTK. Reject widget changes during drawing and
defer native widget finalization until GTK returns. Cairo is resolved through
the GTK runtime's dependencies; no Cairo development headers or direct runtime
link dependency are introduced. See the active DrawingArea contract in GUI_DESIGN.

The 2.23.0 FLTK companion prototype is retired from the active source after
having served its embedding/API experiment. `libbabet`, the host-function API
and their non-GUI embedding examples remain independent supported experimental
work. No FLTK, wxWidgets or other second GUI backend is promised until a real
need justifies it.

### 3.6 Native plugins

Lot 11 reopens native plugins only as a deliberately small Linux experiment. A
normal, non-generated Babet CLI may explicitly load one trusted `.so` through
`babet.plugin.load(path)`. The versioned plugin ABI is pure C, exposes no
`lua_State *` or C++ ownership across the boundary, and reuses the scalar
`babet_host_call_*` mechanism from Lot 10. A successfully loaded plugin remains
resident for the process lifetime; there is no unload protocol.

Native plugins are fully trusted in-process code, not a sandbox boundary. They
are motivated by specialised/vendor libraries and third-party or private
extensions, not by reducing Babet's binary size. Generated `--create-exe`
applications, worker Lua states and external embedding contexts refuse native
plugin loading in this first contract. There is no plugin package manager,
dependency resolver, Internet downloader, automatic `require()` discovery,
temporary extraction, or generated-application plugin packaging.

### 3.7 Windows

Do not combine a major Linux refactor with a Windows port. Windows work is
revisited only after `--create-exe`, ncurses, embedding, optional GUI decisions,
and Linux tests/documentation are mature.

## Roadmap governance

The root [`todo`](todo) file is the live roadmap. Every lot must update its
status there. When tests or measurements change a design decision, update the
roadmap instead of continuing mechanically with an obsolete plan.
