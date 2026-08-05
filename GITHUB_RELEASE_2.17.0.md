# Babet 2.17.0 — process launch hardening and Lua 5.5.1

Babet 2.17.0 completes the planned Linux process-launch hardening without
changing the public process API signatures.

## Highlights

- embeds Lua 5.5.1 with its official checksum;
- expands executable names in the parent into an ordered candidate list from
  the final child environment;
- makes `opts.env.PATH` authoritative for `exec`, `spawn`, `pipeline`, and
  `spawnPipeline`;
- prepares candidate paths, `argv`, and `envp` before `fork()`; children only
  traverse the prepared list with `execve()`;
- handles empty and relative `PATH` entries from the effective child `cwd`;
- preserves `ENOENT`/`ENOTDIR`/`EACCES` lookup precedence and reports launch
  races directly;
- makes the prepared command object non-copyable/non-movable and uses raw Lua
  sequence access so hostile `__len`/`__index` metamethods are never run during
  process argument or worker serialization;
- bounds competing interactive terminal reservations and returns
  `terminal handoff is busy` before creating a child;
- moves launch preparation and the private terminal registry out of
  `process_common.cpp`;
- adds standalone launch preflights, Lua coverage for all four process APIs,
  and a deterministic PTY timeout/recovery regression;
- updates the bilingual documentation and regenerated PDF manuals.

The process state, Ctrl+Z/resume, asynchronous terminal reclamation, Yaourt →
Pacman interactive flow, process-group cleanup, and non-interactive pipeline
contracts from Babet 2.16 remain unchanged.

Babet remains Linux-only.

## Migration note

Babet no longer retries an executable file without a shebang through `/bin/sh`.
Such a file now fails with `ENOEXEC` (“Exec format error”). Add an explicit
interpreter line, for example:

```sh
#!/bin/sh
```

This is the only intentional launch-behavior change that may require an update
when moving from Babet 2.16.x.
