# Babet 2.22.0 - native WebSocket client

Babet 2.22.0 adds a native RFC 6455 WebSocket client designed as a generic
transport layer for bidirectional protocols such as WebDriver BiDi.

## Highlights

- `babet.websocket.connect(url, opts?)` for `ws://` and verified `wss://`;
- strict HTTP Upgrade and `Sec-WebSocket-Accept` validation;
- cryptographically random client masking on every frame;
- text and binary messages with automatic outgoing fragmentation;
- fragmented-message reassembly with interleaved control frames;
- automatic Ping/Pong handling;
- complete Close handshake and close-code/UTF-8 validation;
- strict `max_frame_bytes` and `max_message_bytes` resource ceilings without
  interfering with the RFC 125-byte control-frame ceiling;
- TLS 1.2 minimum, system trust, explicit CA files/directories, hostname/IP
  verification, and optional verification disable for controlled test cases;
- synchronous absolute deadlines and handled-signal interruption;
- identical API registration in worker Lua states.

## WebDriver BiDi

Babet remains protocol-agnostic. A Selenium binding can request the WebDriver
`webSocketUrl` capability and use that URL directly:

```lua
local ws = assert(babet.websocket.connect(webSocketUrl, { timeout = 10 }))

assert(ws:send_text(assert(babet.json.encode({
    id = 1,
    method = "session.status",
    params = {},
}))))

local message = assert(ws:recv())
local reply = assert(babet.json.decode(message.data))
```

Command IDs, pending replies, subscriptions and browser-event callbacks stay in
the Selenium Lua layer; Babet only provides the RFC 6455 transport.

## Protocol hardening

The client rejects masked server frames, reserved RSV bits/opcodes, non-minimal
length encodings, fragmented/oversized control frames, malformed close
payloads, invalid UTF-8 text, and unsolicited extensions/subprotocols.

When possible, Babet closes with:

- `1002` for protocol errors;
- `1007` for invalid UTF-8;
- `1009` for configured size-limit violations.

Peer-advertised frame lengths are checked before allocating or reading the
payload.

## Validation

The release adds:

- a 45th self-test suite;
- a 25-contract structural preflight;
- a deterministic local RFC 6455 server regression covering masking,
  fragmentation, Ping/Pong, binary frames, Close, invalid handshake responses,
  protocol-error closure, size ceilings, invalid UTF-8 Close handling, and
  verified local `wss://`.

French and English reference documentation and PDF manuals are updated.
