> **English** | [Français](../fr/runtime-exit.md)

# Program exit

In the Babet CLI and generated executables, `os.exit([code [, close]])`
terminates the process, including from a coroutine or inside `pcall`.
Status arguments follow Lua: absent, `nil` or `true` means success; `false`
means failure; an integer supplies the exit status. Invalid arguments raise
a Lua error before cleanup begins.

Babet disables its GUI callbacks and restores its curses session before exit.
If an interactive child still owns the terminal, Babet respects that ownership
and does not take the TTY away from it. Wait for or explicitly terminate that
child before exiting when an orderly terminal handback is required.

- Missing or false `close`: no Lua state closure, no Lua finalizers and no
  implicit worker join. Other threads terminate with the process.
- Lua-truthy `close`: the common Babet cleanup closes the Lua state, running
  its finalizers and the usual worker joins. This can wait for a worker stuck
  in a non-cooperative native call; it is neither forced cancellation nor a
  deadline guarantee.

Open C/Lua file buffers are flushed before exit. Flushing can itself wait for
I/O; it does not provide an `fsync` durability guarantee. Automatic C++ objects
on abandoned stacks are not destroyed.

**Difference from stock Lua `os.exit`:** following this explicit cleanup,
Babet stops the process without running native `atexit` callbacks or C++
static destructors. This avoids tearing down global libraries while workers
or native threads may still use them. Plugins must perform application cleanup
explicitly before `os.exit`. Returning normally from the script retains the
ordinary shutdown path and native process-exit callbacks.

An `os.exit` called by a finalizer during Babet state closure does not start a
second close of the same VM; it exits with the new status. Remaining finalizers
are then not guaranteed to run.

Workers still reject `os.exit` with a Lua error; use `return`. The embedding
API does not replace stock `os.exit` in the host's main Lua state; this CLI
policy is not installed there.
