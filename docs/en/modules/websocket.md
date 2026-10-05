> **English** | [Français](../../fr/modules/websocket.md)

# WEBSOCKET — RFC 6455 client for `ws://` and `wss://`

`babet.websocket` is a synchronous WebSocket **client**. It implements the
RFC 6455 opening handshake and framing directly in Babet and is designed for
protocols that need full-duplex message transport, including WebDriver BiDi.

Babet deliberately keeps the layer generic: it knows WebSocket frames, TLS,
timeouts and close semantics, but it does not know Selenium, WebDriver BiDi,
JSON-RPC, browser events, or application-level command identifiers.

## API overview

```lua
local ws, err = babet.websocket.connect(url, opts?)

local n, err = ws:send_text(data, timeout?)
local n, err = ws:send_binary(data, timeout?)
local message, err = ws:recv(timeout?)
local ok, err = ws:ping(data?, timeout?)
local ok, err = ws:set_timeout(seconds)
local ok, err = ws:close(code?, reason?, timeout?)
```

`recv()` returns one complete application message:

```lua
{ type = "text",   data = "..." }
{ type = "binary", data = "..." }
{ type = "close",  code = 1000, reason = "..." }
```

Ping frames are answered automatically with Pong and are not returned as
application messages. Pong frames are consumed internally.

## `babet.websocket.connect(url, opts?)`

Accepted URL schemes are `ws://` and `wss://`; URI scheme matching is ASCII case-insensitive.

```lua
local ws = assert(babet.websocket.connect(
    "ws://127.0.0.1:9222/session/abc",
    { timeout = 5 }
))
```

Secure connection:

```lua
local ws = assert(babet.websocket.connect(
    "wss://example.net/events",
    { timeout = 5 }
))
```

The URL parser accepts DNS names, IPv4, bracketed IPv6, explicit ports, paths,
and query strings. Userinfo and fragments are rejected. Spaces and control
bytes in the HTTP target must be percent-encoded by the caller.

### Options

`opts` is a raw strict table: metamethods are not consulted, option names must
be strings, and unknown fields are rejected.

| Option | Default | Contract |
| --- | ---: | --- |
| `timeout` | `0` | finite seconds `>= 0`; one deadline for TCP, TLS and HTTP Upgrade |
| `verify` | `true` | verify the certificate chain and reference identity for `wss://` |
| `ca_cert` | none | PEM CA file added to default authorities for this connection |
| `ca_path` | none | OpenSSL CA directory added to default authorities for this connection |
| `hostname` | URL host | TLS identity/SNI override |
| `min_version` | `"1.2"` | `"1.2"` or `"1.3"` |
| `max_message_bytes` | 16 MiB | complete reassembled message ceiling |
| `max_frame_bytes` | 16 MiB | application data-frame ceiling; must not exceed message limit; RFC control frames retain their independent 125-byte ceiling |

Both size limits are strict integers in `1..2147483648`.

The constructor timeout is also stored as the WebSocket's default I/O timeout.
Use `set_timeout()` to change it after connection.

### Option examples

Bound the complete TCP/TLS/Upgrade connection sequence after DNS resolution:

```lua
local ws = assert(babet.websocket.connect("ws://127.0.0.1:9222/events", {
    timeout = 2,
}))
```

Use a private CA file for a local or internal `wss://` service:

```lua
local ws = assert(babet.websocket.connect("wss://automation.internal/events", {
    ca_cert = "/etc/myapp/automation-ca.pem",
}))
```

For WSS, `ca_cert` and `ca_path` **add** authorities to those already loaded
from OpenSSL defaults, its environment variables, and recognized distribution
locations. They do not restrict trust to the supplied file or directory. An
empty string adds nothing; a call's custom authorities are not retained by
subsequent connections.

This matches [`socket TLS`](tls.md#tls-ca) and differs from
[`HTTP`](http.md#http-tls), where a non-empty `ca_cert` file replaces the default
authorities. This is not leaf-certificate or public-key pinning: several
certificates issued by one CA can be accepted. With `verify = true`, the
server's identity is still checked.

Use a directory of OpenSSL-compatible CA certificates:

```lua
local ws = assert(babet.websocket.connect("wss://automation.internal/events", {
    ca_path = "/etc/myapp/certs",
}))
```

Override the TLS reference identity and SNI while connecting to a different
address. This is useful for controlled local routing or tests; the certificate
is still checked against `automation.internal`:

```lua
local ws = assert(babet.websocket.connect("wss://127.0.0.1:9443/events", {
    hostname = "automation.internal",
    ca_cert = "/etc/myapp/automation-ca.pem",
}))
```

Require TLS 1.3 instead of the default TLS 1.2 minimum:

```lua
local ws = assert(babet.websocket.connect("wss://example.net/events", {
    min_version = "1.3",
}))
```

Disable certificate verification only for a deliberately controlled test
environment:

```lua
local ws = assert(babet.websocket.connect("wss://127.0.0.1:9443/events", {
    verify = false,
}))
```

`verify = false` disables both chain and reference-identity verification. Do
not use it for untrusted networks or production endpoints.

Bound complete messages and individual application data frames independently:

```lua
local ws = assert(babet.websocket.connect("ws://127.0.0.1:9222/events", {
    max_message_bytes = 8 * 1024 * 1024,
    max_frame_bytes = 1 * 1024 * 1024,
}))
```

A deliberately small `max_frame_bytes` does not reduce the RFC control-frame
ceiling: Ping, Pong and Close can still use payloads up to 125 bytes.

Combined secure configuration:

```lua
local ws = assert(babet.websocket.connect("wss://127.0.0.1:9443/bidi", {
    timeout = 5,
    ca_cert = "/etc/myapp/automation-ca.pem",
    hostname = "automation.internal",
    min_version = "1.3",
    max_message_bytes = 8 * 1024 * 1024,
    max_frame_bytes = 512 * 1024,
}))
```

## Opening handshake

The client sends an HTTP/1.1 Upgrade request with WebSocket version 13 and a
fresh random `Sec-WebSocket-Key`. The response is accepted only when:

- the status is `101 Switching Protocols`;
- `Upgrade` is exactly `websocket` case-insensitively;
- `Connection` contains the `Upgrade` token;
- `Sec-WebSocket-Accept` exactly matches SHA-1 + Base64 of the RFC 6455 GUID;
- the server did not negotiate an extension Babet did not request;
- the server did not select an unsolicited subprotocol.

The handshake header block is capped at 64 KiB.

Babet 2.22.0 does not yet expose custom handshake headers, cookies,
subprotocol negotiation, HTTP proxies, or WebSocket extensions such as
`permessage-deflate`.

## Sending text

```lua
local n, err = ws:send_text('{"id":1,"method":"session.status","params":{}}')
assert(n, err)
```

Text must be valid UTF-8. The return value is the number of application bytes,
not the number of bytes placed on the wire.

Large messages are automatically fragmented into continuation frames. Every
client frame is masked with a fresh unpredictable 32-bit key obtained from
OpenSSL's cryptographic RNG, including frames sent over TLS.

Once sending a frame has been attempted, abandoning it because of a timeout,
interruption or transport error closes the connection. This also covers
fragmented messages, Ping and automatic Pong replies during `recv`. The first
call keeps its error; subsequent operations return `closed` and `close()` stays
idempotent. Closure happens before any signal callback is dispatched.

Validation errors before transmission (UTF-8, message size, arguments) leave
the connection usable. A receive timeout that does not abandon a write keeps
the receive state and remains resumable.

## Sending binary data

```lua
local n = assert(ws:send_binary("A\0B\255"))
assert(n == 4)
```

Binary messages are arbitrary Lua strings and may contain NUL or invalid UTF-8.

## Receiving messages

```lua
local message, err = ws:recv(2)
assert(message, err)

if message.type == "text" then
    print(message.data)
elseif message.type == "binary" then
    -- binary-safe string
elseif message.type == "close" then
    print(message.code, message.reason)
end
```

`recv()` reassembles fragmented text/binary messages and permits control frames
between fragments. Text is validated as UTF-8 only after the complete message
has been reassembled.

Incoming server frames must be unmasked. Reserved RSV bits, reserved opcodes,
non-minimal length encodings, fragmented control frames, and malformed close
payloads are protocol errors.

The advertised payload length of application data frames is checked against
`max_frame_bytes` **before** the payload string is allocated or read. RFC
control frames instead retain their fixed 125-byte ceiling, so a deliberately
small data-frame cap cannot prevent Ping/Pong or Close handling. Reassembled
data is independently bounded by `max_message_bytes`.

## Ping and Pong

```lua
assert(ws:ping("health"))
```

Ping payloads are limited to 125 bytes as required for control frames.
Received Ping frames are immediately echoed as Pong by `recv()` before it
continues waiting for the next application message.

## Closing handshake

```lua
assert(ws:close(1000, "done", 2))
```

`close()` validates the status code and UTF-8 reason, sends a masked Close
frame, then waits for the peer Close using the same absolute deadline. The
reason is limited to 123 bytes so code + reason fit in the RFC 6455 125-byte
control-frame ceiling.

If the peer sends Close first, `recv()` validates it, automatically echoes it
when necessary, closes the transport, and returns a `type = "close"` message.

The GC is intentionally best-effort: forgotten userdata closes the underlying
TCP/TLS resources but does not perform a potentially blocking WebSocket close
handshake.

## Protocol failures

Babet fails closed:

- framing/protocol error -> Close `1002` when possible;
- invalid UTF-8 -> Close `1007`;
- configured frame/message limit exceeded -> Close `1009`.

Transport failures and timeouts remain `(nil, err)` results. A handled POSIX
signal interrupts the current wait, dispatches the pending callback, then
returns `(nil, "interrupted")`.

For `wss://`, internal TLS writes during handshake, send and receive are
protected against `SIGPIPE`. A transport failure does not terminate the
program or replace the application’s signal handler.

## WebDriver BiDi example

WebDriver BiDi uses WebSocket as its transport. The WebDriver session returns a
`webSocketUrl`; Babet only needs that URL:

```lua
local ws = assert(babet.websocket.connect(webSocketUrl, {
    timeout = 10,
    max_message_bytes = 8 * 1024 * 1024,
}))

local command = assert(babet.json.encode({
    id = 1,
    method = "session.status",
    params = {},
}))
assert(ws:send_text(command))

local message = assert(ws:recv())
assert(message.type == "text")
local decoded = assert(babet.json.decode(message.data))
print(decoded.id)
```

A Selenium binding should keep command IDs, pending replies, subscriptions,
and event callbacks in Lua. `babet.websocket` remains transport only.

## Concurrency and event loops

The API is synchronous. Calling `recv()` without a timeout on the main thread
of a GUI/game loop will block that loop. Use a Babet worker, a dedicated
threading strategy in the host application, or short bounded polls when
appropriate.

Each worker has its own Lua state and can create its own WebSocket connection.
A WebSocket userdata itself is not serialized between workers.

## Security and limits

- `wss://` verifies certificates by default and requires TLS 1.2 or newer.
- Client masking uses cryptographically strong random keys for every frame.
- No compression extension is negotiated, avoiding decompression amplification
  and extension-specific state complexity.
- Frame and message limits prevent peer-controlled length fields from causing
  unbounded allocations.
- Server frames that violate RFC 6455 are rejected rather than normalized.
- DNS resolution is synchronous and is not itself bounded by the socket
  deadline; use a numeric address where this matters.
