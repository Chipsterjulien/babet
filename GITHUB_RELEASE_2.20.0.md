# Babet 2.20.0 — pathname-based Unix stream sockets

Babet 2.20.0 adds local `AF_UNIX`/`SOCK_STREAM` clients and servers to
`babet.socket` without creating a separate I/O model.

## Highlights

- `babet.socket.connect_unix(path, timeout?)` with one monotonic connection
  deadline and handled-signal interruption.
- `babet.socket.listen_unix(path, opts?)` with strict `backlog`, an exact
  final mode (private `0600` by default), and `unlink_on_close`.
- Conservative pathname handling: every existing entry is refused; Babet never
  silently removes a stale socket or unrelated file.
- Inode-sensitive cleanup: close and GC unlink only the socket pathname created
  by that listener and never a replacement entry.
- Existing stream methods work unchanged: `accept`, `send`, `recv`,
  `recv_line`, `recv_all`, `set_timeout`, `peer`, `sockname`, and `close`.
- Unix endpoints are reported as `{ path = ... }`; STARTTLS remains TCP-only.
- Full worker interoperability, a 44-suite modular harness, and a dedicated
  13-contract Unix-socket preflight.

The requested mode is applied immediately after `bind()`. Before that call to
`fchmodat()`, the kernel-created pathname briefly has the mode selected by the
process `umask`; sensitive services should therefore place the socket in a
private parent directory.

Linux pathname sockets only are supported. Abstract namespace sockets,
datagrams, descriptor passing, and peer credentials remain outside this
release.
