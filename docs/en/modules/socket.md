> **English** | [Français](../../fr/modules/socket.md)

# `babet.socket` — TCP client and server

Low-level TCP sockets with timeouts, signal awareness, and a
small set of higher-level helpers (`recv_line`, `recv_all`).
Foundation for any custom protocol — the IRC bot, a JSON-over-TCP
daemon, etc. See [`tls`](tls.md) for the encrypted variant.

## Why

For everyday HTTP needs there's [`http`](http.md). But many
scripts need to speak a custom line-oriented protocol (IRC,
Redis, plain telnet-style daemons), where a real TCP socket with
timeouts is the right tool. Lua has no built-in TCP, and `LuaSocket`
is a separate dep ; `babet.socket` makes the common patterns
one-liners.

## API

### Constructors

| Function | Returns |
| --- | --- |
| `babet.socket.connect(host, port, timeout?)` | `socket` \| `(nil, err)` |
| `babet.socket.listen(host, port, backlog?)` | `server_socket` \| `(nil, err)` |

- `timeout` : seconds (float), optional — default infinite (blocking).
  This is the budget for the TCP attempts **after DNS resolution**: a
  **global** deadline across all A/AAAA addresses. If DNS returns
  several addresses (typical dual-stack), successive attempts share
  the same budget — never `timeout` per address. On expiry:
  `(nil, "timeout")`. Known limit: DNS resolution itself
  (`getaddrinfo`, synchronous) is not covered by this deadline nor
  interruptible by signal — a slow resolver can add its own delay
  upfront.
- `backlog` : integer > 0, optional — default 16. `listen(2)` queue
  size.

> **TLS** : `babet.socket.connect_tls(host, port, opts?)` and
> `s:starttls(opts?)` also exist — they have their own page, see
> [`tls`](tls.md).

A `connect` — with or without a timeout — interrupted by a signal
handled via [`signal`](signal.md) returns `(nil, "interrupted")`
after dispatching the callback, like `recv`/`accept`.

### Methods (client socket)

| Method | Returns |
| --- | --- |
| `s:send(data)` | `integer` bytes sent \| `(nil, err)` — sends **everything** (internal loop over partial writes) |
| `s:recv(n, timeout?)` | `string` \| `(nil, "timeout")` \| `(nil, "interrupted")` \| `(nil, err)` |
| `s:recv_line(timeout?)` | `string` (without `\n`) \| `(nil, …)` |
| `s:recv_all(timeout?)` | `string` (read until EOF) \| `(nil, …)` |
| `s:set_timeout(seconds)` | sets default timeout (`0` = infinite). NaN/Inf/negative → `(nil, err)` ; internal 1 ms floor for tiny positive values |
| `s:close()` | idempotent |
| `s:peer()` | table `{host, port}` \| `(nil, err)` — remote endpoint |
| `s:sockname()` | table `{host, port}` \| `(nil, err)` — local endpoint |

`recv_line` reads bytes until `\n` (LF) is found. CR is stripped
if present (`\r\n` → returned without the trailing `\r`). Has a
hard 8 MiB cap to prevent DoS via an endless single line.

### Methods (server socket)

| Method | Returns |
| --- | --- |
| `srv:accept(timeout?)` | `socket` \| `(nil, …)` |
| `srv:close()` | idempotent |

## Quick examples

### TCP echo client

```lua
-- 5 s timeout for the WHOLE connect (all DNS addresses combined);
-- omit it for a blocking connect.
local s = assert(babet.socket.connect("localhost", 4000, 5))

s:send("hello\n")
local reply, err = s:recv_line()
print("got:", reply)
s:close()
```

### Simple line-protocol server with graceful shutdown

```lua
local sig = babet.signal
local srv = assert(babet.socket.listen("0.0.0.0", 4000))
local running = true
sig.handle("TERM", function() running = false end)
sig.handle("INT", function() running = false end)

while running do
    local client, err = srv:accept(1.0)        -- 1 s timeout
    if not client then
        if err == "timeout" or err == "interrupted" then
            -- loop and re-check `running`
        else
            io.stderr:write("accept: ", err, "\n"); break
        end
    else
        repeat
            local line = client:recv_line(30)
            if line then client:send("you said: " .. line .. "\n") end
        until not line
        client:close()
    end
end
srv:close()
```

## Error contract

- **Connect errors** (DNS, refused, network) → `(nil, "socket: ...")`.
  Timeout expiry → bare `(nil, "timeout")`. Handled signal during
  connect → `(nil, "interrupted")`.
- **Bind errors** (port in use, permission) → `(nil, "socket: ...")`.
- **`recv`** :
  - `string` (any length up to `n` requested).
  - Empty string `""` when the peer closed cleanly. Not an error.
  - `(nil, "timeout")` if no data within timeout.
  - `(nil, "interrupted")` if a handled signal arrived.
  - `(nil, "line too long")` for `recv_line` past the 8 MiB cap.
  - `(nil, err)` on other errors.
- **`send`** : may return fewer bytes than requested. Wrap in a
  loop if you need to send a fixed amount (or use `recv_all`-
  symmetric semantics in your protocol).
- **Methods after `close`** → `(nil, "socket: closed")`.
- **NaN/Inf timeouts**, negative timeouts → raises via
  `luaL_error`.

## Design decisions

- **Single-threaded, blocking I/O**. No `select`/`poll` exposed —
  use [`workers`](workers.md) for concurrent connections, or
  short timeouts in a polling loop for simple cases.
- **`recv_line` has an 8 MiB cap**. Protects against a peer that
  sends megabytes without ever sending `\n`. Configurable later
  if a use case needs more.
- **Signal-aware blocking**. All `recv*`, `accept` — and `connect`,
  including without a timeout — return `"interrupted"` on a handled
  signal, so scripts can exit cleanly.
- **`connect` timeout is global, not per-address** (v21 audit). The
  deadline is created once for the whole call; a dual-stack host
  whose first address stalls doesn't multiply the delay. Accepted
  trade-off: a fallback address only gets the remaining budget.
- **`recv` returns `""` on clean close, not `nil`**. Lets scripts
  distinguish "remote went away" (`""`) from "no data yet"
  (`"timeout"`) without inventing yet another sentinel.

## Not in v1

- UDP sockets. Easy to add additively (`babet.socket.udp.*`).
- Unix-domain sockets. Same reasoning.
- Native multiplexing (`select`/`poll`/`epoll` exposed to Lua).
  Use workers or short-timeout polling instead.
