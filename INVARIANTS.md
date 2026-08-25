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

The refusal must use the same internal source of truth that identifies an
embedded payload. Babet must not introduce a second independent marker such as
`generated_executable = true` beside the existing embedded-payload detection.

Renaming or copying the original Babet executable must not remove its builder
capability:

```sh
cp babet toto
./toto --create-exe ./project application
```

must remain valid.

**Current development status after Lot 3:** this contract is enforced. Once the
existing embedded `main.lua` detection identifies a packaged application, the
runtime reserves `--create-exe` / `-c` and refuses builder mode before executing
the embedded script. No second generated-executable identity marker is used.

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
| Generated application is not a builder | `tests/test_packaging.sh` structurally verifies that the refusal is inside the existing `if (fileData)` packaged-identity branch, rejects parallel identity markers, and checks at runtime that generated applications refuse both `--create-exe` and `-c` before `main.lua` runs. It also proves a copied/renamed original Babet remains a builder. | Keep this contract tied to the embedded-payload source of truth. |
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

Lot 7 records the reviewed comparison in [GUI_STUDY.md](GUI_STUDY.md). A future
GUI is a separate companion host consuming the standalone `libbabet` SDK; the
normal `babet` executable, its bootstrap and its `--create-exe` semantics do not
acquire any GUI toolkit dependency.

FLTK 1.4.x is the preferred **first prototype** because it best matches the
small/modular, cross-platform and static-friendly constraints. wxWidgets 3.2.x
is the first fallback when native widget integration matters more than the
smallest practical deployment surface. GTK 4 and Qt 6 remain capable toolkits
but are not selected as Babet's default GUI host under the current constraints.
The preference is not a permanent dependency decision: a real prototype must
measure its stripped binary and dynamic dependency closure first.

Lot 10 supplies the narrow host-function registration boundary required by the
FLTK prototype. It remains scalar and C-only, exposes no `lua_State *`, and does
not force GUI support into the CLI. Lot 11 native plugins are a separate
extension mechanism for specialised/vendor SDKs and private or third-party
integrations; they are not the GUI implementation path.

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
