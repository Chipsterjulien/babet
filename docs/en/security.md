> **English** | [Français](../fr/security.md)

# Security model

**Babet runs trusted Lua scripts. It is not a sandbox.**

Scripts execute with the full Lua standard library (`luaL_openlibs`),
and Babet additionally exposes filesystem and process primitives
such as `exec`, `remove`, `rmdirAll` and `chdir`. A script therefore
has the same privileges as the process running it : it can read,
modify or delete files and run arbitrary commands. This is by
design — like `make`, a shell script, or any build tool, Babet is
meant to run code you control.

Only run `main.lua` and `require`d modules that you trust. Do **not**
use Babet to execute Lua from untrusted sources ; it provides no
isolation against hostile code, and none is intended. If you need to
run untrusted scripts, use a purpose-built Lua sandbox instead.

## What the hardening *does* protect against

The hardening work in Babet protects *legitimate* use against
accidents and supply-chain tampering :

- **`copyTree` / `moveTree` confinement** : the destination root is
  opened once, then every create, copy and move is performed relative to
  that descriptor with `openat`/`mkdirat`/`renameat` and
  `O_NOFOLLOW`/`AT_SYMLINK_NOFOLLOW`. A pre-existing symlink, or one swapped
  during the operation, cannot redirect a write to an outside target. The
  `is_within()` guards additionally reject a destination resolving inside
  the source.
- **Confined archive creation and extraction**: `babet.archive` refuses symlinked creation-source and
  output/extraction-destination paths, selected unsupported source objects, non-UTF-8 selected source names,
  outputs inside the source tree, absolute archive-entry paths, `.`/`..`
  components, backslashes, duplicates, ZIP symlinks, and special filesystem
  types. Input archives are opened once and must resolve to a regular file,
  excluding blocking FIFO sources. It walks the destination through descriptors with
  `O_NOFOLLOW`; each file is decompressed into a same-directory temporary,
  checked against anti-bomb limits, then published atomically. Creation-side
  `include`/`exclude` rules reuse the non-recursive safe-glob engine, prune
  excluded directories before opening, and enforce per-pattern, cumulative
  pattern-text, pattern-evaluation, matching-work, and pattern-count limits.
- **Standalone compression confinement**: `babet.compression` accepts only real
  regular source files, rejects symlink path components and same-inode
  destinations, pins and revalidates the source descriptor, bounds decompressed
  output, verifies codec integrity, rejects trailing junk, stages output beside
  the destination, and publishes atomically.
- **General atomic file writing**: `writeFileAtomic()` opens every parent without following symlinks, rejects `..`, a final symlink or non-regular destination, and implicit overwrite. Data is written to a private same-directory temporary file, permissions are applied, then the file and directory are synchronized around atomic publication.
- **Bounded process-group cleanup** in `babet.exec` also covers the
  `chdir`/`exec` launch phase, internal polling failures, and children that
  close all pipes while continuing to run. On timeout, TERM then KILL target
  the whole group; these error paths never end in an unbounded final
  `waitpid`.
- **Output limits** on `babet.exec` bound the amount of stdout
  and stderr captured into memory (default 10 MiB each, configurable),
  so a runaway subprocess can't OOM the Babet process.
- **Pinned local metadata updates**: `setAttributes` resolves its target once
  and keeps `chown`, `chmod`, and rollback attached to the same inode. `touch`
  creates with `O_EXCL`, never truncates an existing file, and pins an existing
  target before changing its timestamp.
- **Anonymous and pinned executable staging**: `--create-exe` unlinks its
  temporary ZIP immediately after `mkstemp` and lets miniz and the merge step
  reopen the still-live inode through `/proc/self/fd`, not through a replaceable
  temp path. The final merge pins the output directory and publishes with
  `renameat()`, so changing a parent symlink cannot redirect the executable.
- **Dependency checksums** : every vendored dependency is
  SHA256-pinned in `build_local.sh`. An empty hash refuses to build.
  A mismatch deletes the downloaded file and exits with an error.
  This protects against a compromised upstream or Wayback Machine
  archive (which is the fallback source).
- **TLS verification** is on by default (`verify=true`). Disabling
  it requires an explicit per-call `verify=false` — there is no silent
  fallback. TLS sockets accept extra trust through `ca_cert` or `ca_path`;
  HTTP exposes `ca_cert`. OpenSSL's `SSL_CERT_FILE` / `SSL_CERT_DIR` remain
  available. SNI is sent independently from verification when a DNS hostname
  is known.
- **HTTP line validation** rejects CR/LF in URLs and header values, and header
  names must follow the HTTP `token` grammar. User-controlled values cannot
  inject an extra header or request line through those fields.
- **Network memory limits** bound `socket:recv_line`, `socket:recv_all`, and
  `http.max_body_size`. After a socket-read timeout, already consumed bytes
  stay in one shared pending buffer so switching receive methods cannot lose or
  reorder the stream.
- **Bounded filename matching** provides a non-recursive safe glob engine for
  `babet.find` and archive creation, plus RE2-backed regular expressions for
  `babet.find`. Regex patterns are capped at 4096 bytes, compiled with a 1 MiB
  memory budget, and cannot trigger catastrophic backtracking. Archive filter
  lists add cumulative count, byte, and matching-work ceilings. RE2-unsupported
  constructs fail before traversal.

## What it does *not* protect against

- A malicious script. Babet has no sandbox. `babet.exec` does not invoke a
  shell, but allowing untrusted input to choose the executable or its arguments
  can still permit arbitrary program execution or option injection. Passing
  untrusted text to `load` gives arbitrary Lua code execution.
- A determined attacker who has obtained code execution on the
  machine running Babet. The hardening makes accidental
  mistakes loud, not adversarial attacks impossible.
- Long-tail OS-level issues (kernel exploits, container escapes,
  privilege escalation). Babet is an ordinary userland binary.

## Recommended pattern : least privilege

When running Babet as a service, treat it like any other
unprivileged process :

```sh
# As root, create a dedicated service user with no shell.
useradd --system \
        --home-dir /var/lib/myapp \
        --create-home \
        --shell /usr/sbin/nologin \
        --comment "myapp Babet service" \
        myapp

# Use babet.user.exists("myapp") in your install script to
# verify the user is provisioned before launching the daemon.
```

Combine with `systemd` unit file options like `User=myapp`,
`PrivateTmp=yes`, `ProtectSystem=strict`, `NoNewPrivileges=yes`,
and `CapabilityBoundingSet=` (empty unless you genuinely need a
capability). The kernel does much more than Babet can to
contain a misbehaving script ; let it.
