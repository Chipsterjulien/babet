# ncursesw integration design contract

Status: **Lot 4 design contract**. This document freezes the terminal and
lifecycle rules that Lot 5 must implement before the public binding is expanded.
It is deliberately an implementation contract, not a fundamental Babet product
invariant.

## 1. Goals and non-goals

Babet will add a terminal UI binding based on **ncursesw** (wide-character
ncurses), with Linux as the reference platform.

The binding must preserve Babet's deployment philosophy:

> one file to copy, one file to run.

The first implementation therefore targets a statically linked ncursesw core
with a small set of embedded terminfo fallbacks. It must not introduce a
runtime dependency on `libncursesw.so`, a separately shipped terminfo tree, or
an external tool invoked by `--create-exe`.

Lot 4 does **not** implement the binding, add ncurses to CMake, or freeze a large
Lua API. Lot 5 may choose the exact names of drawing/window helpers, but it must
respect the lifecycle and event contracts below.

Not in scope for the first binding:

- forms/menu/panel libraries unless a concrete API need appears;
- multiple simultaneously active curses screens;
- curses calls from workers;
- a second terminal ownership subsystem beside Babet's current process/spawn
  terminal handoff code;
- a CMake `NCURSES=ON/OFF` support matrix;
- fatal-signal recovery that calls ncurses.

## 2. Existing Babet terminal machinery is the owner

The current process implementation already centralizes interactive terminal
handoff in `src/lua_bindings/process_terminal_internal.cpp` and
`process_common.hpp`. It tracks:

- the actual terminal identity (`st_dev` + `st_ino`);
- a bounded handoff reservation;
- the foreground child process group;
- the Babet process group to restore;
- the shell-side `termios` snapshot;
- the child-side `termios` snapshot across stop/resume;
- asynchronous child-exit restoration through a detached monitor;
- stale-monitor protection so an old child cannot steal a terminal transferred
  to a newer child.

Lot 5 must **extend or rename this existing registry**, not create an independent
`curses_terminal_manager` with its own foreground-owner truth.

A curses-specific source file may own `SCREEN *`, windows, drawing and input,
but foreground PGID, terminal identity and terminal handoff state remain under
the existing terminal-control registry.

## 3. One-owner state machine

The externally meaningful terminal states are:

```text
normal
curses
child_process
terminal_reclaimed_curses_pending
```

`reservation_active` remains an internal transient coordination mechanism. It
is not a fifth terminal owner.

The valid transitions are:

```text
normal -> curses
normal -> child_process

curses -> normal
curses -> child_process

child_process -> normal
child_process -> terminal_reclaimed_curses_pending

terminal_reclaimed_curses_pending -> curses
```

### `normal`

Babet owns no curses program mode and no interactive child owns the terminal.
The parent process group is the foreground group and shell-compatible termios
are active.

### `curses`

A single Babet curses session is active and Babet owns the foreground terminal
in ncurses program mode.

### `child_process`

An interactive child process group owns the terminal. Curses, if logically
active, has already been suspended with `endwin()` on the main thread.

### `terminal_reclaimed_curses_pending`

The child no longer owns the terminal. The existing POSIX handoff machinery has
restored the Babet process group and shell-side termios, but a curses session
was suspended for that child and has not yet been restored by the main thread.

At no point may curses and a child process both believe they own the interactive
terminal.

## 4. Starting and stopping curses

The first binding has one process-wide curses session.

- Starting a second session while one is active is an error.
- Starting while another interactive child owns the terminal is an error.
- Starting from a worker is an error.
- Stopping an inactive session is safe/idempotent.
- Stopping a curses session that is currently suspended behind an interactive
  child cancels the pending curses restoration; it must not steal the terminal
  from that child.

The v1 implementation uses the process standard terminal streams. `stdin` and
`stdout` must both be TTYs referring to the same terminal identity. There is no
implicit `/dev/tty` fallback in the first binding; this keeps curses and the
existing inherited-stdin process handoff on the same terminal source of truth.

## 5. Initialization: `setupterm` + `newterm`, never `initscr`

The implementation must **not call `initscr()`**. ncurses documents that
`initscr()` can print a diagnostic and terminate the application when
initialization fails.

Initialization is instead:

1. validate non-empty `TERM`;
2. verify `stdin`/`stdout` TTY identity;
3. call `setupterm(..., &errret)` to classify terminal/terminfo failures without
   allowing the library to call `exit()`;
4. dispose of the temporary low-level terminal state as required;
5. call `newterm()` and retain its `SCREEN *`;
6. establish Babet's signal dispositions again after `newterm()` because
   ncurses may install its own handlers during screen initialization;
7. enter the `curses` state only after all previous steps succeed.

Failures become normal Babet/Lua errors. Partial initialization must restore the
terminal before returning an error.

`setupterm` errors are reported distinctly enough to diagnose:

- missing/empty `TERM`;
- unknown or generic terminal description;
- missing terminfo database with no usable embedded fallback;
- allocation/system initialization failure.

Babet must never silently replace an unknown `TERM` with `xterm` or another
terminal type.

## 6. Terminfo and one-file autonomy

A normal system terminfo entry is preferred when present.

The ncurses library linked into Babet must also contain a small common fallback
set compiled with ncurses' `--with-fallbacks` mechanism. ncurses checks these
entries only after normal terminfo/termcap lookup has failed, so an embedded
fallback does not shadow a newer system description.

The initial fallback set should at least cover the common Linux/PTY families:

```text
linux
vt100
xterm
xterm-256color
screen
screen-256color
tmux
tmux-256color
```

A few additional common modern terminal names may be added in Lot 5 if they are
present in the pinned ncurses source and the focused fallback test justifies
them. This is not a package manager or a complete embedded terminfo database.

No `tic`, `infocmp`, compiler, linker or other external command may be required
at **runtime** or by `--create-exe`. Build-time generation while compiling Babet
itself is allowed.

## 7. UTF-8 and locale

The binding uses **ncursesw** wide-character input/output APIs. Public text is
UTF-8 and must not be implemented by passing arbitrary UTF-8 byte sequences to
narrow-character ncurses calls.

Babet must not change the process-global locale dynamically for curses. This is
important both for worker safety and for the later `libbabet` embedding work.

On Linux, the curses main thread should use a stable thread-local `LC_CTYPE`
locale for the lifetime of the curses session (for example with
`newlocale()`/`uselocale()`), preferring the environment locale when it is
UTF-8 and falling back to a known UTF-8 locale such as `C.UTF-8` when available.
If no usable UTF-8 locale exists, `curses.start()` fails cleanly.

The selected thread-local locale remains unchanged while curses is active and
is restored/released when the session ends. Workers are unaffected.

## 8. Main-thread-only rule

**Every ncurses function call runs on Babet's main thread.** This includes
initialization, drawing, input, resize, `endwin()`, `reset_prog_mode()`,
`doupdate()`, `delscreen()` and cleanup.

Lot 5 should extract the current main-thread identity from its signal-only
private location into a small shared internal helper used by:

- `babet.signal`;
- the curses binding;
- the interactive-terminal path when it must distinguish a main-thread handoff
  from a worker handoff.

This is a functional sharing requirement, not an invitation to refactor other
runtime code.

The ncurses threaded ABI (`libncursest`) is not a solution here. ncurses itself
describes its multi-thread support as rudimentary and does not make arbitrary
concurrent curses use safe.

## 9. Central main-thread service helper

Lot 5 must introduce one central helper, conceptually:

```text
service_terminal_events_on_main_thread()
```

The exact C++ name may differ. It is the **only** place that turns pending
terminal events back into ncurses operations after asynchronous activity.

It handles, as applicable:

- `terminal_reclaimed_curses_pending` -> curses restoration;
- pending resize;
- pending Babet suspension/resume;
- controlled default termination that must leave curses first.

It is called at safe main-thread points:

- before and after public curses API operations;
- immediately after a blocking curses input function returns, including
  `ERR/EINTR`;
- after main-thread process operations that may reclaim a stopped/exited
  interactive child, before returning control to Lua;
- from the existing main-thread signal dispatch/hook path when an internal
  terminal signal requires service.

It must never be invoked as an ncurses-calling operation from a POSIX signal
handler or child-monitor thread.

## 10. Interactive child processes while curses is active

Interactive process launch remains supported from the **main thread**.

The handoff is committed under the existing terminal reservation/registry so
there is no race between curses suspension and foreground transfer:

```text
curses
  -> main thread saves curses program state
  -> main thread endwin()
  -> existing terminal manager gives foreground to child PGID
  -> child_process
```

If the child launch/foreground transfer fails after curses was suspended, the
main thread restores curses before the error is returned to Lua.

While an interactive child still owns the terminal, ordinary curses drawing or
input calls must not steal it; they return a clear "interactive child owns the
terminal" error until the child has stopped/exited and ownership has been
reclaimed.

When the child exits asynchronously, the existing monitor may perform only the
POSIX-level work it already owns:

- inspect/reclaim foreground PGID;
- restore the saved parent/shell termios;
- update the shared terminal state.

If a curses session was suspended, the monitor sets:

```text
terminal_reclaimed_curses_pending
```

and stops there. It must **not** call any ncurses function.

At the next safe main-thread point the central helper performs the curses side,
conceptually:

```text
reset_prog_mode()
clear/touch screen as required
doupdate()
```

and returns to `curses`.

`process:wait()` observing a stopped child should reclaim the terminal and
restore curses before returning the stopped state to Lua. A later
`process:resume(true)` from the main thread repeats the curses -> child handoff.
A non-foreground resume does not take the terminal.

## 11. Worker process policy

Curses calls from workers always fail with a clear Lua error.

When curses is active:

- a worker `spawn` whose stdin does **not** request the inherited interactive
  terminal remains a normal non-interactive spawn;
- a worker operation that would take the interactive terminal (interactive
  spawn or foreground resume) fails immediately with a clear Lua error;
- it must not wait for curses ownership or introduce cross-thread curses
  synchronization.

When curses is not active, existing worker/process behavior is preserved.

## 12. Signal ownership

ncurses may install signal handlers when `newterm()` initializes a screen.
Babet must not rely on those handlers as its policy. After initialization,
Babet reapplies/installs the dispositions described below.

POSIX handlers do the strict minimum: set `sig_atomic_t` flags. No Lua call,
allocation, mutex-taking or ncurses call occurs in a signal handler.

### SIGWINCH

During a curses session Babet owns SIGWINCH handling.

- The handler sets a pending-resize flag only.
- The main-thread service helper obtains the current terminal size with the
  normal OS interface and calls `resize_term(rows, cols)` outside the handler.
  Babet deliberately uses the inner resize primitive rather than `resizeterm()`: the
  latter unconditionally queues `KEY_RESIZE` in ncurses, which would duplicate the
  logical `"resize"` event already owned and delivered by Babet.
- Resize notifications are coalesced.
- The curses input API exposes a symbolic Lua **resize event**; it does not leak
  ncurses' numeric `KEY_RESIZE` value as a stable Babet ABI.
- SIGWINCH is not added to `babet.signal` in the first curses binding, avoiding
  two public owners for the same resize event.

Outside curses, Babet keeps its pre-existing SIGWINCH behavior.

### SIGTSTP / SIGCONT

Ctrl-Z while Babet owns curses follows a controlled main-thread sequence:

```text
SIGTSTP handler -> pending flag
safe point -> save program mode -> endwin()
           -> save/block the main-thread SIGTSTP mask
           -> temporarily restore/default SIGTSTP disposition
           -> raise a pending SIGTSTP
           -> explicitly unblock SIGTSTP to suspend Babet
SIGCONT -> execution resumes
         -> briefly re-block SIGTSTP
         -> reinstall Babet terminal dispositions
         -> restore the exact previous thread signal mask
         -> mark curses restoration pending
safe point -> reset program mode -> redraw -> curses
```

This uses the same terminal state machine as interactive child handoff. No
ncurses function runs from either signal handler.

When a child is the foreground process group, terminal-generated job-control
signals belong to that child. Babet must not steal the terminal to process
Ctrl-Z on the child's behalf.

### SIGINT / SIGTERM / SIGHUP

These remain part of Babet's existing public signal policy.

The signal subsystem must distinguish the **logical** user disposition from the
kernel handler temporarily required to protect a curses terminal:

- `ignore`: keep ignore semantics;
- Lua handler: set the normal Babet pending flag, dispatch the Lua callback on
  the main thread, and keep curses active unless user code ends it/exits;
- default: while curses is active, use a minimal Babet handler to defer default
  termination to a safe point, call `endwin()` on the main thread, restore the
  default disposition, then re-raise the same signal so the process retains
  normal signal-exit semantics.

SIGUSR1, SIGUSR2 and SIGPIPE keep their current behavior and are not terminal
lifecycle signals.

## 13. Controlled cleanup and errors

The curses native state must have one process-level cleanup path that can be
called safely from the main thread and is idempotent.

It must restore the terminal for:

- normal script completion;
- explicit curses stop;
- an uncaught Lua error reaching Babet's top-level protected execution;
- errors crossing a Lua `pcall`/binding boundary without corrupting the active
  session;
- managed C++ exceptions caught by Babet's normal exception boundaries;
- default SIGINT/SIGTERM/SIGHUP handled through the controlled path above.

A Lua error **caught** by user code does not implicitly terminate the curses
session. A curses binding that fails must leave either a usable curses session
or a clean stopped state before returning the error.

Cleanup must respect terminal ownership: if a live interactive child currently
owns the terminal, stopping/canceling the curses session must not `tcsetpgrp`
the terminal away from that child. The existing child lifecycle remains
responsible for final parent restoration.

## 14. Fatal signals

No ncurses call is permitted from a `SIGSEGV`, `SIGABRT` or similar fatal-signal
handler.

The first implementation does not promise full terminal recovery from memory
corruption, `SIGKILL`, or an unrecoverable runtime crash. A future minimal
async-signal-safe best-effort escape sequence may be studied separately, but it
is not part of the Lot 5 correctness contract.

Documentation should mention `reset` (or opening a fresh terminal) as the manual
recovery path after a fatal crash leaves a terminal in an unusual mode.

## 15. Initial Lua-facing lifecycle contract

Lot 5 keeps the public model intentionally small:

```text
babet.curses.start(...)
babet.curses.stop()
```

plus focused drawing/input helpers. There is one active session, not a graph of
independent terminal objects.

The exact drawing/window method names are intentionally left to Lot 5, but the
following behavior is fixed now:

- all functions reject worker execution;
- calls requiring an active session reject the inactive state;
- input returns UTF-8 text / symbolic special-key events;
- resize is a symbolic event;
- timeouts/interruption are explicit, not hidden infinite retries;
- no public API exposes raw `WINDOW *`, `SCREEN *` or ncurses integer key codes
  as stable Babet ABI.

## 16. Lot 5 test matrix

Lot 5 is not complete until focused tests cover at least:

1. start/stop on a PTY and exact termios restoration;
2. missing `TERM`, unknown `TERM`, and a missing external terminfo database;
3. successful startup from an embedded fallback with external terminfo hidden;
4. UTF-8 wide output and input;
5. resize notification and updated dimensions;
6. SIGTSTP/SIGCONT suspension and redraw;
7. default SIGINT/SIGTERM/SIGHUP terminal cleanup;
8. preservation of a user-installed `babet.signal` handler through curses
   initialization;
9. uncaught Lua error and managed C++ error cleanup;
10. a caught Lua error that leaves the session usable;
11. main-thread interactive spawn while curses is active, including child input,
    child exit, reclaim and redraw;
12. stopped child reclaim followed by foreground resume;
13. worker interactive spawn/foreground-resume rejection while curses is active;
14. worker non-interactive spawn while curses is active;
15. no ncurses call from the existing terminal exit monitor;
16. static-link/runtime dependency inspection and the measured stripped-binary
    size delta.

PTY tests should extend the existing terminal regression machinery rather than
create a parallel pseudo-terminal test framework unless the existing one proves
insufficient.

## 17. References used for this design

- ncurses `initscr`/`newterm`/`endwin` manual:
  https://invisible-island.net/ncurses/man/curs_initscr.3x.html
- ncurses low-level program/shell mode manual:
  https://invisible-island.net/ncurses/man/curs_kernel.3x.html
- ncurses input and `KEY_RESIZE` behavior:
  https://invisible-island.net/ncurses/man/curs_getch.3x.html
- ncurses resize handling:
  https://invisible-island.net/ncurses/man/resizeterm.3x.html
- ncurses thread-safety notes:
  https://invisible-island.net/ncurses/man/curs_threads.3x.html
- ncurses terminfo/setupterm error contract:
  https://invisible-island.net/ncurses/man/curs_terminfo.3x.html
- ncurses compiled terminfo fallback configuration:
  https://invisible-island.net/ncurses/INSTALL.html
