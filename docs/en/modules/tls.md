> **English** | [Français](../../fr/modules/tls.md)

# TLS — direct encryption, STARTTLS, certificates, and SNI

Babet TLS uses the same userdata as [`babet.socket`](socket.md). After the
handshake, `send`, `recv`, `recv_line`, `recv_all`, `set_timeout`, `peer`,
`sockname`, and `close` behave like their plain-TCP versions.

Two modes are available:

- `babet.socket.connect_tls()` starts TLS on the first application byte;
- `sock:starttls()` upgrades an existing TCP connection after a plaintext
  protocol negotiation.

The implementation provides TLS 1.2 minimum, certificate verification by
default, hostname checks, SNI independent from verification, system and
per-call CA trust, shared TCP+handshake deadlines, and fail-closed STARTTLS.
It does not expose TLS servers, client certificates, ALPN, public-key pinning,
or peer-certificate inspection.

## Module contents

- [Core conventions](#tls-conventions)
- [API overview](#tls-api-summary)
- [TLS options](#tls-options)
- [Direct TLS connection](#tls-connect)
- [STARTTLS upgrade](#tls-starttls)
- [Verification, hostname, and SNI](#tls-hostname-sni)
- [Certificate authorities](#tls-ca)
- [TLS versions](#tls-versions)
- [Timeouts](#tls-timeouts)
- [Socket state after failure](#tls-failure-state)
- [Complete examples](#tls-examples)
- [Error contract](#tls-errors)
- [Security and limitations](#tls-design)

<a id="tls-conventions"></a>
## Core conventions

### Verification is on by default

```lua
local sock = assert(babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
}))
```

`verify = false` explicitly disables both chain and hostname verification. It
may be useful in controlled tests but encryption without authentication does
not prevent an active man-in-the-middle attack.

### Same stream API after handshake

```lua
local sock = assert(babet.socket.connect_tls("irc.example.net", 6697, {
    timeout = 10,
}))
assert(sock:set_timeout(120))
assert(sock:send("PING :hello\r\n"))
local line = assert(sock:recv_line())
```

Handshake timeout and later I/O timeout are separate.

### SNI is not certificate verification

SNI selects a TLS virtual host. Verification checks trust and reference
identity. Babet sends DNS SNI whenever a DNS hostname is available, including
when `verify = false`.

<a id="tls-api-summary"></a>
## API overview

```lua
local sock, err = babet.socket.connect_tls(host, port, opts?)
local ok, err = sock:starttls(opts?)
```

```lua
{
    verify = true,
    hostname = "example.com",
    ca_cert = "/path/ca-bundle.pem",
    ca_path = "/path/certs",
    min_version = "1.2",
    timeout = 10,
}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `verify` | strict boolean | `true` | chain and hostname verification |
| `hostname` | string | `connect_tls` host | reference name and DNS SNI |
| `ca_cert` | string | no custom file | extra PEM trust file |
| `ca_path` | string | no custom directory | OpenSSL hashed CA directory |
| `min_version` | `"1.2"` or `"1.3"` | `"1.2"` | minimum protocol version |
| `timeout` | finite number `>= 0` | `0` | handshake budget in seconds |

Unknown fields are currently ignored; misspellings do not fail.

<a id="tls-options"></a>
## TLS options

`verify` must be an actual boolean. `hostname`, `ca_cert`, `ca_path`, and
`min_version` must be strings without NUL. `timeout` must be finite and
non-negative; a positive value below 1 ms is rounded up.

`hostname` has two roles:

1. OpenSSL reference identity when verification is enabled;
2. SNI value when it is a DNS name.

Connect to an IP while validating a DNS certificate:

```lua
local sock = assert(babet.socket.connect_tls("203.0.113.10", 443, {
    hostname = "api.example.com",
    timeout = 10,
}))
```

An IP literal is not sent as SNI. `ca_cert` and `ca_path` augment trust for that
connection; they are not exclusive pinning.

`min_version = "1.3"` raises the minimum. It does not cap the maximum.

<a id="tls-connect"></a>
## `babet.socket.connect_tls(host, port, opts?)`

Establishes TCP then performs a client handshake:

```lua
local sock, err = babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
})
assert(sock, err)
```

Without `opts.hostname`, the `host` argument is used for verification and DNS
SNI. For an IP connection to a DNS certificate, supply the name explicitly.

After synchronous DNS resolution, one deadline covers every TCP address
attempt and the TLS handshake. The handshake does not receive a fresh budget.
DNS itself remains outside this controlled deadline.

`opts.timeout` is not retained as the socket I/O default:

```lua
local sock = assert(babet.socket.connect_tls(host, port, { timeout = 10 }))
assert(sock:set_timeout(30))
```

<a id="tls-starttls"></a>
## `sock:starttls(opts?)`

Upgrades an existing connected plain TCP socket in place:

```lua
local ok, err = sock:starttls({
    hostname = "mail.example.com",
    timeout = 10,
})
```

On success it returns exactly `(true, nil)`.

The socket must be open, connected, not already TLS, and have no pending
plaintext buffered by Babet. `starttls` does not remember the hostname passed
to the earlier TCP constructor, so `hostname` is mandatory when
`verify = true`.

Babet does not send a protocol `STARTTLS` command. The script must:

1. negotiate in plaintext;
2. request STARTTLS;
3. validate the positive protocol reply;
4. call `starttls`;
5. resume the protocol over TLS, often with a new greeting.

If a prior line/all read timed out after consuming plaintext, finish consuming
or otherwise resolve that plaintext before upgrading. Babet rejects STARTTLS
while the shared pending buffer is non-empty.

<a id="tls-hostname-sni"></a>
## Verification, hostname, and SNI

| Connection | `verify` | `hostname` | Identity check | SNI |
| --- | --- | --- | --- | --- |
| DNS `example.com` | `true` | absent | `example.com` | `example.com` |
| IP | `true` | `api.example.com` | DNS name | DNS name |
| IP | `true` | absent | IP identity | none |
| DNS | `false` | absent | none | DNS host |
| IP | `false` | DNS name | none | DNS name |
| IP | `false` | absent | none | none |

Providing `hostname` can therefore still be required by a virtual host even
when verification is disabled.

<a id="tls-ca"></a>
## Certificate authorities

The socket TLS context attempts OpenSSL defaults, OpenSSL environment
variables, and several known Linux/BSD CA locations. Per-call `ca_cert` and
`ca_path` are then added.

This applies to both `connect_tls` and `starttls`. An empty string adds no
custom trust. In contrast, a non-empty [`HTTP`](http.md#http-tls) `ca_cert`
replaces the default authorities for that request; the identically named
options therefore have different trust policies across these modules.

Custom trust is isolated per connection:

```lua
local a = assert(babet.socket.connect_tls("internal.example", 443, {
    ca_cert = "/tmp/test-root.pem",
    timeout = 5,
}))
a:close()
-- Later calls do not retain /tmp/test-root.pem.
```

`ca_path` must follow OpenSSL's hashed-directory conventions. A CA file trusts
certificates issued by that CA; it is not a leaf-certificate/public-key pin.
Babet does not expose the peer certificate for custom pinning.

<a id="tls-versions"></a>
## TLS versions

Protocols older than TLS 1.2 are always rejected.

- default minimum: TLS 1.2;
- optional minimum: TLS 1.3;
- TLS 1.3 is negotiated automatically with the default when supported.

No maximum-version option is exposed.

<a id="tls-timeouts"></a>
## Timeouts

For `connect_tls`, `opts.timeout` covers TCP plus handshake after DNS. For
`starttls`, it covers only the upgrade handshake and does not inherit
`sock:set_timeout()`.

After success, configure I/O separately:

```lua
assert(sock:set_timeout(30))
local line, err = sock:recv_line()
```

TLS sockets remain non-blocking internally and OpenSSL WANT_READ/WANT_WRITE is
coordinated with one poll deadline.

<a id="tls-failure-state"></a>
## Socket state after failure

`connect_tls` returns no socket and closes all intermediate resources.

Pre-handshake STARTTLS validation/configuration failures leave the plain TCP
socket usable: invalid options, missing hostname, pending plaintext, context
setup, or pre-handshake `fcntl` failure.

Once `SSL_connect` begins, any failure closes the socket: timeout,
interruption, certificate failure, alert, protocol, or I/O error. A ClientHello
may already have been sent and peer bytes consumed, so falling back to
plaintext would be unsafe. This is intentionally fail-closed.

After the first `SSL_write` attempt in `send`, abandoning that call because of
a timeout, interruption or error closes the transport. OpenSSL may have begun
a record without reporting application bytes written, so checking a positive
byte counter is insufficient. The original error is retained; subsequent I/O
reports a closed socket, and `close()` stays idempotent. Closure happens before
any signal callback is dispatched. A timeout before the first `SSL_write`
attempt leaves the socket usable.

<a id="tls-examples"></a>
## Complete examples

### Raw HTTPS request

For normal HTTP use [`babet.http`](http.md); this demonstrates stream use:

```lua
local sock = assert(babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
}))
assert(sock:set_timeout(10))
assert(sock:send(
    "GET / HTTP/1.1\r\n" ..
    "Host: example.com\r\n" ..
    "Connection: close\r\n\r\n"
))
local response = assert(sock:recv_all(nil, 8 * 1024 * 1024))
print(response)
sock:close()
```

### IP connection with DNS identity

```lua
local sock = assert(babet.socket.connect_tls("203.0.113.20", 443, {
    hostname = "api.example.com",
    ca_cert = "/etc/myapp/ca.pem",
    timeout = 5,
}))
```

### Simplified SMTP STARTTLS

```lua
local sock = assert(babet.socket.connect("mail.example.com", 587, 5))
assert(sock:set_timeout(10))
assert(sock:recv_line():match("^220"))
assert(sock:send("EHLO client.example\r\n"))
-- Parse the full multiline EHLO response and require STARTTLS.
assert(sock:send("STARTTLS\r\n"))
assert(sock:recv_line():match("^220"))
assert(sock:starttls({
    hostname = "mail.example.com",
    timeout = 10,
}))
assert(sock:send("EHLO client.example\r\n"))
```

A complete SMTP client must correctly parse every multiline reply and prevent
STARTTLS downgrade.

### Controlled self-signed test

```lua
local sock = assert(babet.socket.connect_tls("127.0.0.1", 8443, {
    verify = false,
    hostname = "dev.local", -- SNI is still sent
    timeout = 3,
}))
```

Do not use this trust policy in production.

<a id="tls-errors"></a>
## Error contract

Wrong positional types raise; invalid values and runtime failures return
`(nil, err)`: empty host, bad port/options, CA loading, DNS/TCP, timeout,
interruption, handshake, certificate/hostname verification, and STARTTLS
preconditions.

OpenSSL wording varies. Compare stable states such as `"timeout"` and
`"interrupted"`; log full messages for diagnosis.

OpenSSL writes are protected against `SIGPIPE`, including during handshake,
read and shutdown. Transport failures are reported through the API instead of
terminating the program; `close()` remains best-effort. The application’s
`babet.signal` handler is not replaced.

<a id="tls-design"></a>
## Security and limitations

- Keep `verify = true` in production.
- Validate against a trusted expected hostname, never one supplied by the peer.
- STARTTLS must be required by application policy to prevent stripping.
- No ALPN, client certificate, TLS server, peer-certificate access, custom
  cipher policy, or application OCSP/CRL policy.
- Protect and rotate private CA files.
