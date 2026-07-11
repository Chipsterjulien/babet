> **English** | [Français](../../fr/modules/tls.md)

# `babet.socket` TLS — `connect_tls` and `starttls`

The TLS half of [`socket`](socket.md) : encrypted TCP for IRC over
TLS, IMAPS, custom secure protocols. Two entry points :
`connect_tls` for protocols that go TLS from the start (port
6697 IRC, 993 IMAPS, etc.) and `starttls` for protocols that
upgrade an existing plain connection (SMTP, IMAP, IRC `STARTTLS`).

## Why

Talking encrypted TCP without [`http`](http.md) is a real need :
IRC bots over `+6697`, SMTP submission, custom internal services
behind TLS. Doing it manually with `openssl s_client` via `exec`
is unreliable ; `openssl` the C++ library + `cpp-httplib` chosen
abstractions give a clean Lua API that handles cert verification
correctly by default.

## API

| Function | Returns |
| --- | --- |
| `babet.socket.connect_tls(host, port, opts?)` | `tls_socket` \| `(nil, err)` |
| `s:starttls(opts?)` | `(true, nil)` \| `(nil, err)` — upgrade an existing plain socket |

`opts` :

| Field      | Type                               | Default                                                                                                                              |
| ---------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `verify`   | boolean — certificate verification | `true`                                                                                                                               |
| `ca_cert`  | string (path to a CA bundle file)  | system trust store                                                                                                                   |
| `ca_path`  | string (path to a CA directory)    | system trust store                                                                                                                   |
| `hostname` | string — SNI + name verification   | `connect_tls` : the `host` argument. `starttls` : **required** if `verify = true`                                                    |
| `timeout`  | number (seconds)                   | infinite — budget applied to **each phase** (TCP connect, then TLS handshake), not a single envelope ; DNS resolution is not covered |

> An earlier version of this page named the option `server_name`
> (the real name is `hostname`) and documented an `alpn` option
> that doesn't exist — see "Not in v1".

A `tls_socket` has the same methods as a plain socket
(`send`, `recv`, `recv_line`, `recv_all`, `set_timeout`,
`close`, `peer`). The encryption is transparent.

## Quick examples

### Connect to IRC over TLS

```lua
local s = assert(babet.socket.connect_tls("irc.libera.chat", 6697, {
    timeout = 30,
}))

s:send("NICK babet-bot\r\n")
s:send("USER babet 0 * :babet bot\r\n")

while true do
    local line, err = s:recv_line()
    if not line then break end
    print(line)
    if line:match("^PING (.+)$") then
        s:send("PONG " .. line:match("^PING (.+)$") .. "\r\n")
    end
end
```

### STARTTLS upgrade (SMTP submission)

```lua
local s = assert(babet.socket.connect("mail.example.com", 587))
print(s:recv_line())                              -- 220 banner
s:send("EHLO myhost\r\n")
repeat
    line = s:recv_line()
until not line:match("^250%-")                    -- last 250 line

s:send("STARTTLS\r\n")
print(s:recv_line())                              -- 220 ready to start TLS

assert(s:starttls({ hostname = "mail.example.com" }))
-- s is now encrypted ; continue with EHLO + AUTH + …
```

### Self-signed server (dev / private CA)

```lua
local s = assert(babet.socket.connect_tls("internal.svc", 5555, {
    ca_cert = "/etc/myapp/internal-ca.crt",
}))
```

### Skip verification (TESTING ONLY)

```lua
local s = assert(babet.socket.connect_tls("self-signed.local", 8443, {
    verify = false,
}))
```

## Error contract

- All errors prefixed `"tls: ..."` (handshake, cert verify, etc.)
  or `"socket: ..."` (DNS, connect, timeout).
- `(nil, err)` always — no exceptions for "expected" failures
  like cert mismatch.
- **`verify=true` + invalid cert** → `(nil, "tls: certificate
  verify failed: <reason>")`. Common reasons : expired,
  self-signed, hostname mismatch, unknown CA.
- **`starttls` with `verify = true` and no `opts.hostname`** →
  `(nil, "tls: starttls with verify=true requires opts.hostname;
  pass hostname or set verify=false")` — a certificate cannot be
  verified without knowing which name to verify ; the explicit
  refusal beats a silently incomplete verification.
- **After a failed `starttls`** : the socket is handed back **as
  it was** — plaintext, blocking, still open (you can close
  cleanly or retry). Edge case : if restoring blocking mode fails
  (nearly impossible), the socket is **closed** and the error
  carries the suffix
  `"(socket closed: could not restore blocking mode)"` — a safe,
  explicit state instead of a socket with altered behaviour.
- **NaN/Inf timeouts**, wrong types → raises via `luaL_error`.

## Trust store

Babet ships its own statically-linked OpenSSL. Out of the box,
`verify=true` works on :

- **Arch, Debian, Ubuntu, Alpine, Gentoo** : via `--openssldir=/etc/ssl`
  baked into the vendored OpenSSL.
- **Fedora, RHEL, CentOS, Rocky, Alma, OpenSUSE, FreeBSD, NetBSD**
  : via runtime probing of known CA bundle paths.

Overrides, in priority order :

1. `ca_cert` / `ca_path` per call.
2. `SSL_CERT_FILE` / `SSL_CERT_DIR` environment variables.
3. The two mechanisms above.

If none of these find a CA store and you use `verify=true`, the
handshake fails with a clear error. See
[`security`](../security.md) for the full picture.

## Design decisions

- **TLS 1.2 minimum**. SSL 3, TLS 1.0, TLS 1.1 are
  unconditionally rejected — they're broken, no modern server
  should rely on them. TLS 1.3 is negotiated automatically when
  available.
- **`verify=true` by default, `verify=false` requires explicit
  opt-in**. No way to accidentally turn off cert checking.
- **`hostname` defaults to the host argument** (for
  `connect_tls`), so SNI works out of the box. Pass it explicitly
  when connecting by IP to a TLS server that uses SNI — and it is
  required for `starttls` with verification, since the existing
  socket doesn't know which name to expect.
- **Same methods as plain socket**, so a function that takes a
  `socket` works for both transparently.

## Not in v1

- ALPN negotiation (an earlier version of this page documented an
  `alpn` option that never existed).
- Client certificate authentication. Possible to add as a
  `client_cert` / `client_key` opt later.
- TLS session resumption / session tickets. Not commonly needed
  at script level.
- OCSP stapling verification. Reliance on OpenSSL's defaults.
