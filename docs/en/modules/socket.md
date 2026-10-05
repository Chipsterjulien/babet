> **English** | [Français](../../fr/modules/socket.md)

# SOCKET — TCP and Unix sockets, binary streams, lines, and timeouts

`babet.socket` provides synchronous stream sockets over TCP or the Unix
domain (`AF_UNIX`) for custom protocols: IRC, plain SMTP before STARTTLS,
line-oriented services, binary streams, and small local daemons.

It covers:

- connecting to a hostname or IP address;
- connecting locally through a Unix socket pathname;
- listening on a network interface or Unix pathname;
- accepting clients;
- sending a complete binary Lua string;
- receiving chunks, lines, or everything until remote EOF;
- per-socket and per-call deadlines;
- local and peer addresses;
- explicit close and garbage-collector cleanup;
- interruption by signals handled through Babet.

It does not expose UDP, the Linux abstract Unix namespace, asynchronous I/O,
`select`/`poll` loops, or an application protocol. Use [`HTTP`](http.md) for web requests and
[`TLS`](tls.md) for direct TLS or STARTTLS.

## Module contents

- [Core conventions](#socket-conventions)
- [API overview](#socket-api-summary)
- [Connecting a client](#socket-connect)
- [Creating a TCP server](#socket-listen)
- [Connecting to a Unix socket](#socket-connect-unix)
- [Creating a Unix server](#socket-listen-unix)
- [Accepting a client](#socket-accept)
- [Default timeout](#socket-set-timeout)
- [Sending data](#socket-send)
- [Receiving at most N bytes](#socket-recv)
- [Receiving one line](#socket-recv-line)
- [Receiving until EOF](#socket-recv-all)
- [Mixing receive methods](#socket-pending)
- [Local and peer addresses](#socket-addresses)
- [Closing and GC](#socket-close)
- [Signals and interruption](#socket-signals)
- [Complete examples](#socket-examples)
- [Error contract](#socket-errors)
- [Security and limitations](#socket-design)

<a id="socket-conventions"></a>
## Core conventions

### Synchronous streams

Every call runs in the current thread. Without a timeout, `connect`,
`connect_unix`, `accept`, `send`, and receive methods can wait indefinitely. Use
[`workers`](workers.md) for independent concurrent connections; Babet does not
expose a Lua event loop.

### Binary-safe data

Payload strings may contain NUL bytes:

```lua
assert(sock:send("AB\0CD") == 5)
local data = assert(sock:recv(5, 2))
assert(#data == 5 and data:byte(3) == 0)
```

Hostnames and Unix pathnames are passed to C/POSIX APIs and may not contain
NUL.

### Timeout rules

Timeouts are seconds and may be fractional:

- omitted or `nil`: use the socket default;
- `0`: wait forever;
- positive finite number: one deadline for the whole call;
- positive values below 1 ms: rounded up to 1 ms;
- negative, NaN, infinity, or excessively large: error.

The deadline is not restarted for every byte or internal retry.

### Return values

Constructors and reads return a value or `(nil, err)`. `set_timeout`,
`starttls`, and `close` return exactly `(true, nil)` on success.

Wrong positional types raise a Lua error. Invalid values and runtime failures
normally return `(nil, err)`.

<a id="socket-api-summary"></a>
## API overview

```lua
local sock, err = babet.socket.connect(host, port, timeout?)
local server, err = babet.socket.listen(host, port, backlog?)
local local_sock, err = babet.socket.connect_unix(path, timeout?)
local local_server, err = babet.socket.listen_unix(path, opts?)

local count, err = sock:send(data)
local data, err = sock:recv(count, timeout?)
local line, err, partial = sock:recv_line(timeout?)
local data, err = sock:recv_all(timeout?, max_bytes?)
local ok, err = sock:set_timeout(seconds)
local addr, err = sock:peer()
local addr, err = sock:sockname()
local ok, err = sock:close()

local client, err = server:accept(timeout?)
```

| Argument | Type | Default | Meaning |
| --- | --- | --- | --- |
| client `host` | strict non-empty string | required | DNS name or IP address |
| listen `host` | strict string | required | interface; `""` means all interfaces |
| `port` | strict Lua integer `0..65535` | required | TCP port |
| connect `timeout` | finite number `>= 0` | `0` | connection deadline in seconds |
| `backlog` | strict Lua integer `1..INT_MAX` | `16` | requested listen queue size |

Numeric strings such as `"443"` and floats such as `443.0` are rejected for
integer fields.

`listen_unix` accepts these strict options:

| Option | Default | Contract |
| --- | ---: | --- |
| `backlog` | `16` | integer `1..INT_MAX` |
| `permissions` | `0600` | exact final Unix mode `0000..0777`, applied after `bind()` |
| `unlink_on_close` | `true` | remove the created pathname on close/GC |

A listening socket rejects stream operations and `peer`; a connected socket
rejects `accept`.

<a id="socket-connect"></a>
## `babet.socket.connect(host, port, timeout?)`

```lua
local sock, err = babet.socket.connect("example.net", 9000, 5)
assert(sock, err)
```

Babet calls `getaddrinfo()` and tries returned IPv4/IPv6 addresses in order.
All connection attempts share the same deadline. Synchronous DNS resolution
itself is outside that deadline and may add delay.

Use a numeric address to avoid DNS:

```lua
local sock = assert(babet.socket.connect("127.0.0.1", 9000, 2))
```

The constructor timeout only covers connection establishment. The new socket's
default I/O timeout is still zero:

```lua
local sock = assert(babet.socket.connect(host, port, 3))
assert(sock:set_timeout(10))
```

Typical results:

- timeout: `(nil, "timeout")`;
- handled signal: `(nil, "interrupted")` after callback dispatch;
- DNS/TCP failure: `(nil, "socket: …")`;
- empty host or out-of-range port: `(nil, err)`;
- wrong positional type: Lua error.

<a id="socket-listen"></a>
## `babet.socket.listen(host, port, backlog?)`

Creates a TCP listening socket with `SO_REUSEADDR`.

Loopback only:

```lua
local server = assert(babet.socket.listen("127.0.0.1", 9000))
```

All interfaces:

```lua
local server = assert(babet.socket.listen("", 9000))
```

An empty host uses `AI_PASSIVE`. Use `"0.0.0.0"` or `"::"` to request a
specific address family. Listening on all interfaces exposes the service to the
network; add authentication and firewall rules.

Ask the kernel for a free test port:

```lua
local server = assert(babet.socket.listen("127.0.0.1", 0))
local addr = assert(server:sockname())
print(addr.host, addr.port)
```

Backlog is a kernel request, not a maximum number of active clients:

```lua
local server = assert(babet.socket.listen("127.0.0.1", 9000, 128))
```

<a id="socket-connect-unix"></a>
## `babet.socket.connect_unix(path, timeout?)`

Connects to a pathname-based Unix stream socket:

```lua
local sock, err = babet.socket.connect_unix("/run/my-service.sock", 2)
assert(sock, err)
```

The pathname must be a strict non-empty string without NUL and must fit in
`sockaddr_un.sun_path` (107 useful bytes on Linux). The timeout uses the same
global monotonic contract as TCP connect; zero means infinite. It is not kept
as the socket's later I/O timeout.

Linux abstract sockets are deliberately not exposed. `peer()` returns
`{ path = ... }`; `sockname()` on an unbound Unix client normally returns
`{ path = "" }`.

<a id="socket-listen-unix"></a>
## `babet.socket.listen_unix(path, opts?)`

Creates an `AF_UNIX`/`SOCK_STREAM` listener:

```lua
local server = assert(babet.socket.listen_unix("/run/my-service.sock", {
    backlog = 32,
    permissions = tonumber("660", 8),
    unlink_on_close = true,
}))
```

Babet refuses **every pre-existing pathname**, including stale sockets,
regular files, symlinks, FIFOs, and directories. It never silently removes an
existing entry; stale sockets must be explicitly removed by the application
after validation.

After `bind()`, the final permissions are applied exactly without following a
symlink. The final secure default is `0600`. Between `bind()` and that mode
change, the pathname briefly has the kernel-created mode filtered by the
process `umask`. Babet does not change that `umask` because it is process-global
and the runtime is multithreaded. Sensitive services should therefore place
the socket in a private parent directory, for example mode `0700`. The parent
directory must already exist.

With `unlink_on_close = true`, close and GC remove the pathname only when it is
still the same socket inode created by this listener. A replacement file is
never deleted. With `false`, the stale pathname remains for explicit cleanup.

<a id="socket-accept"></a>
## `server:accept(timeout?)`

```lua
local client, err = server:accept(10)
```

The positional timeout overrides `server:set_timeout()` for this call only.
The accepted socket has a default I/O timeout of zero; it does not inherit the
server timeout:

```lua
local client = assert(server:accept(10))
assert(client:set_timeout(30))
```

Accepted descriptors are close-on-exec.

<a id="socket-set-timeout"></a>
## `sock:set_timeout(seconds)`

Sets the default for `send`, `recv`, `recv_line`, `recv_all`, and `accept`:

```lua
assert(sock:set_timeout(3.5))
assert(sock:set_timeout(0)) -- infinite again
```

It does not apply to a completed constructor and does not control STARTTLS;
`starttls` uses `opts.timeout`.

Per-call overrides:

```lua
assert(sock:set_timeout(10))
local a, err = sock:recv(4096, 0.2) -- 200 ms
local b, err = sock:recv(4096)      -- 10 s
local c, err = sock:recv(4096, 0)   -- infinite
```

<a id="socket-send"></a>
## `sock:send(data)`

Sends the whole string or fails:

```lua
local count, err = sock:send("PING\r\n")
assert(count, err)
assert(count == 6)
```

Babet loops over partial OS/OpenSSL writes, so a successful count equals
`#data`. Empty and binary strings are accepted. `send` has no positional
timeout and uses the socket default.

If a transport error happens after some bytes were written, no partial count is
returned. Protocols needing safe retries must use application-level IDs or
acknowledgements.

On a TLS socket, a failure after the first `SSL_write` attempt closes the
connection, even if OpenSSL has not yet reported any application bytes written.
The original call keeps its diagnostic (`timeout`, `interrupted` or TLS error),
then subsequent I/O reports a closed socket. A timeout before any TLS write
attempt leaves the connection usable.

<a id="socket-recv"></a>
## `sock:recv(count, timeout?)`

Reads **at most** `count` bytes and may return fewer bytes while the connection
remains open:

```lua
local chunk, err = sock:recv(4096, 5)
```

`count` must be a strict Lua integer from 1 through 16 MiB. This is not
"read exactly N". A helper can accumulate:

```lua
local function recv_exact(sock, wanted, timeout)
    local chunks, total = {}, 0
    while total < wanted do
        local chunk, err = sock:recv(wanted - total, timeout)
        if not chunk then return nil, err end
        chunks[#chunks + 1] = chunk
        total = total + #chunk
    end
    return table.concat(chunks)
end
```

Here the timeout is per `recv` call. Compute a monotonic application deadline
when one budget must cover the whole helper.

EOF before data returns `(nil, "closed")`; expiration returns
`(nil, "timeout")`; a handled signal returns `(nil, "interrupted")`.

<a id="socket-recv-line"></a>
## `sock:recv_line(timeout?)`

Reads through LF and returns the line without LF. A CR immediately before LF is
also stripped:

```text
hello\n   -> "hello"
hello\r\n -> "hello"
```

Complete lines already buffered by `recv_all` are handled before polling the
network. Each call extracts one line and keeps all following bytes for
`recv_line`, `recv` or `recv_all`.

The line limit is 8 MiB before removing an optional CR, excluding LF. It applies
to buffered lines too. Oversized lines return a `line too long` error and the
protocol should generally be considered desynchronised. If the complete
oversized line was already buffered, it is discarded through LF and following
data is preserved.

EOF before LF returns three values:

```lua
local line, err, partial = sock:recv_line(5)
if not line and err == "closed" then
    print(partial) -- always a string, possibly empty
end
```

On timeout/interruption, bytes already consumed are retained internally and
are delivered first by the next `recv`, `recv_line`, or `recv_all`.

<a id="socket-recv-all"></a>
## `sock:recv_all(timeout?, max_bytes?)`

Reads until remote EOF; EOF is the successful terminator:

```lua
local body, err = sock:recv_all(10)
```

Use this only when connection close frames the message. A persistent peer that
keeps the connection open makes this call wait until timeout.

Memory limit:

- default: 64 MiB;
- strict positive integer;
- maximum: 2 GiB.

```lua
local body, err = sock:recv_all(10, 4 * 1024 * 1024)
```

Limit, timeout, and interruption failures expose no partial result, but already
consumed bytes remain buffered. A later call can resume with a larger limit or
new deadline:

```lua
local body, err = sock:recv_all(2, 1024)
if not body and err:find("max_bytes", 1, true) then
    body = assert(sock:recv_all(2, 4096))
end
```

<a id="socket-pending"></a>
## Mixing `recv`, `recv_line`, and `recv_all`

All three methods share one pending-byte buffer. Switching methods after a
timeout does not lose or reorder the TCP stream:

```lua
-- Peer sent "abc" without LF.
local line, err = sock:recv_line(0.1)
assert(line == nil and err == "timeout")
local prefix = assert(sock:recv(3, 1))
assert(prefix == "abc")
```

Still prefer one framing strategy per protocol phase. Mixing helpers is useful
for a line header followed by a fixed-size body, but the application must know
the exact boundary.

Pending plaintext must be consumed before `starttls`; Babet rejects the upgrade
otherwise.

<a id="socket-addresses"></a>
## `sock:peer()` and `sock:sockname()`

Both return numeric address tables:

```lua
{ host = "127.0.0.1", port = 9000 }
```

- `peer()` returns the remote endpoint of a connected socket;
- `sockname()` returns the local endpoint and also works on listeners.

No reverse DNS is performed. `peer()` is invalid on a listening socket.

<a id="socket-close"></a>
## `sock:close()` and garbage collection

`close()` is idempotent and returns `(true, nil)`:

```lua
assert(sock:close())
assert(sock:close())
```

Other methods then report a closed socket. The userdata owns its FD and SSL
object, so GC eventually cleans forgotten sockets, but GC timing is not a
lifecycle guarantee. Close explicitly.

Created and accepted sockets are close-on-exec, so
[`babet.exec`](exec.md) children do not silently inherit them.

<a id="socket-signals"></a>
## Signals and interruption

A wait interrupted by a signal registered through
[`babet.signal`](signal.md) may return `(nil, "interrupted")` after the Lua
callback is dispatched. Pending bytes from line/all reads are retained.

```lua
local stopping = false
babet.signal.handle("TERM", function() stopping = true end)
while not stopping do
    local client, err = server:accept(1)
    if client then
        client:close()
    elseif err ~= "timeout" and err ~= "interrupted" then
        error(err)
    end
end
```

<a id="socket-examples"></a>
## Complete examples

### Line-oriented echo server

```lua
local S = babet.socket
local server = assert(S.listen("127.0.0.1", 9000, 64))
assert(server:set_timeout(1))

while true do
    local client, err = server:accept()
    if client then
        assert(client:set_timeout(30))
        local line, read_err = client:recv_line()
        if line then
            assert(client:send("echo: " .. line .. "\n"))
        elseif read_err ~= "closed" then
            io.stderr:write(read_err, "\n")
        end
        client:close()
    elseif err ~= "timeout" then
        error(err)
    end
end
```

### Length-prefixed binary client

```lua
local sock = assert(babet.socket.connect("127.0.0.1", 9000, 3))
assert(sock:set_timeout(5))
assert(sock:send(string.pack(">I4", 5) .. "hello"))
local raw_len = assert(recv_exact(sock, 4, 5))
local len = string.unpack(">I4", raw_len)
local payload = assert(recv_exact(sock, len, 5))
print(payload)
sock:close()
```

### Response framed by EOF

```lua
local sock = assert(babet.socket.connect("127.0.0.1", 9001, 3))
assert(sock:send("request\n"))
local response = assert(sock:recv_all(10, 8 * 1024 * 1024))
print(#response)
```

<a id="socket-errors"></a>
## Error contract

Wrong positional types raise:

```lua
babet.socket.connect("localhost", "9000")
sock:send(42)
sock:recv(4096.0)
sock:set_timeout("5")
```

Invalid ranges and runtime failures return `(nil, err)`: invalid ports,
backlog, timeouts, receive sizes, incompatible methods, closed sockets,
DNS/TCP errors, and the stable typed states `"timeout"`, `"closed"`, and
`"interrupted"`.

Only compare complete strings for stable typed errors. System messages may vary
across libc and kernel versions.

Internal C++ exceptions never cross into Lua. Allocation failure is converted
to `(nil, "socket: out of memory")`; other internal exceptions receive a fixed
literal diagnostic. This boundary covers every public `babet.socket` function
and method.

<a id="socket-design"></a>
## Security and limitations

- Raw TCP has no encryption or peer authentication.
- Set deadlines for peer-controlled input.
- Bind loopback unless remote access is required.
- TCP is a byte stream; `send` boundaries are not preserved.
- DNS is synchronous and outside the controlled connection deadline.
- No half-close, configurable keepalive, UDP, or Lua event loop.
- Unix support is pathname stream sockets only: no abstract namespace,
  datagrams, `SCM_RIGHTS`, or credentials.
- The requested final mode is applied after `bind()`. Before that mode change,
  the pathname briefly inherits the process-`umask`-filtered mode. Babet does
  not modify this process-global state in a multithreaded runtime; put sensitive
  sockets in a private parent directory, ideally mode `0700`. Socket mode alone
  does not secure a writable directory.
- STARTTLS is TCP-only and is rejected on Unix streams without closing them.
- One userdata should not be used concurrently; socket userdata cannot cross a
  WORKERS message boundary.
- `connect`, `listen`, `accept`, and `connect_tls` create the Lua userdata owner
  before acquiring an FD or OpenSSL object, so a Lua memory-error longjmp cannot
  abandon an unowned resource. `starttls` uses a separate guard and closes the
  stream if an exception occurs after the handshake has started.
- OOM exception safety is established by structural review, strict compilation,
  and static analysis rather than deterministic `bad_alloc` injection; the
  integration suite covers observable lifecycle and failure paths.
