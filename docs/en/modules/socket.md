> **English** | [Français](../../fr/modules/socket.md)

# SOCKET — TCP clients and servers, binary streams, lines, and timeouts

`babet.socket` provides synchronous TCP sockets for custom protocols: IRC,
plain SMTP before STARTTLS, line-oriented services, binary streams, and small
internal daemons.

It covers:

- connecting to a hostname or IP address;
- listening on one interface or all interfaces;
- accepting clients;
- sending a complete binary Lua string;
- receiving chunks, lines, or everything until remote EOF;
- per-socket and per-call deadlines;
- local and peer addresses;
- explicit close and garbage-collector cleanup;
- interruption by signals handled through Babet.

It does not expose UDP, Unix-domain sockets, asynchronous I/O, `select`/`poll`
loops, or an application protocol. Use [`HTTP`](http.md) for web requests and
[`TLS`](tls.md) for direct TLS or STARTTLS.

## Module contents

- [Core conventions](#socket-conventions)
- [API overview](#socket-api-summary)
- [Connecting a client](#socket-connect)
- [Creating a server](#socket-listen)
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

### Synchronous TCP

Every call runs in the current thread. Without a timeout, `connect`, `accept`,
`send`, and receive methods can wait indefinitely. Use
[`workers`](workers.md) for independent concurrent connections; Babet does not
expose a Lua event loop.

### Binary-safe data

Payload strings may contain NUL bytes:

```lua
assert(sock:send("AB\0CD") == 5)
local data = assert(sock:recv(5, 2))
assert(#data == 5 and data:byte(3) == 0)
```

Hostnames are passed to C/POSIX APIs and may not contain NUL.

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

The line limit is 8 MiB. Oversized lines return a `line too long` error and the
protocol should generally be considered desynchronised.

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

<a id="socket-design"></a>
## Security and limitations

- Raw TCP has no encryption or peer authentication.
- Set deadlines for peer-controlled input.
- Bind loopback unless remote access is required.
- TCP is a byte stream; `send` boundaries are not preserved.
- DNS is synchronous and outside the controlled connection deadline.
- No half-close, configurable keepalive, UDP, Unix sockets, or Lua event loop.
- One userdata should not be used concurrently; socket userdata cannot cross a
  WORKERS message boundary.
