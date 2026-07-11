> **English** | [Français](../../fr/modules/http.md)

# `babet.http` — HTTP client

A simple HTTP/HTTPS client built on
[cpp-httplib](https://github.com/yhirose/cpp-httplib), reusing the
vendored OpenSSL. Synchronous, blocking, with timeouts.

## Why

Almost every non-trivial script needs to talk to some HTTP API.
Without a built-in client, you reach for `curl` via `exec`, with
all the quoting and process-spawning overhead. `babet.http`
makes a request a one-liner, with proper TLS verification by
default.

## API

| Function                      | Returns                                                                                     |
| ----------------------------- | ------------------------------------------------------------------------------------------- |
| `babet.http.request(opts)`    | `response` (table) \| `(nil, err)` — methods : GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE |
| `babet.http.get(url, opts?)`  | shortcut for `request{ method="GET", url=url, ... }`                                        |
| `babet.http.post(url, opts?)` | shortcut for `request{ method="POST", url=url, ... }`                                       |

> No `put`/`delete`/`patch` shortcuts in v1 (an earlier version of
> this page wrongly advertised them) : use
> `request{ method = "PUT", ... }`. See "Not in v1".

### `opts` table

| Field              | Type                                                                                                              | Default                                                                        |
| ------------------ | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `url`              | string (required for `request`)                                                                                   | —                                                                              |
| `method`           | string — GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE                                                             | `"GET"`                                                                        |
| `headers`          | table of `name = value`                                                                                           | `{}`                                                                           |
| `body`             | string (forbidden for GET/HEAD/OPTIONS)                                                                           | `""`                                                                           |
| `query`            | table `{ key = value }` — URL-encoded and appended to the URL (`?a=b&c=d`), merges cleanly with an existing query | —                                                                              |
| `timeout`          | number (seconds)                                                                                                  | **none** — without it, cpp-httplib's internal defaults apply ; always pass one |
| `verify`           | boolean (TLS cert verification)                                                                                   | `true`                                                                         |
| `ca_cert`          | string (path to CA bundle file)                                                                                   | system default                                                                 |
| `follow_redirects` | boolean                                                                                                           | **`false`** — following is opt-in ; hop limit internal to cpp-httplib          |

### `response` table

```lua
{
    status = 200,
    body = "...",
    headers = {                 -- normalised lowercase keys
        ["content-type"] = "application/json",
        ["content-length"] = "42",
    },
}
```

> **Duplicate** response headers : the last value wins (one key =
> one string). Known consequence : if a server sends several
> `Set-Cookie` headers, only the last one is visible. If that need
> becomes real, `headers` could carry a table of strings for
> repeated keys — see "Not in v1".

## Quick examples

```lua
-- Simple GET
local r, err = babet.http.get("https://api.example.com/health")
if r then
    print(r.status, r.body)
end

-- JSON POST with auth header
local r, err = babet.http.post("https://api.example.com/v1/things", {
    headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. token,
    },
    body = babet.json.encode({ name = "widget", count = 7 }),
    timeout = 10,
})

-- Self-signed cert (dev / private CA)
local r = babet.http.get("https://internal.svc/", {
    ca_cert = "/etc/myapp/internal-ca.crt",
})

-- Disable verification (TESTING ONLY)
local r = babet.http.get("https://expired.badssl.com/",
                            { verify = false })
```

## Error contract

- **Wrong argument types** → raises via `luaL_error`.
- **Network errors** (DNS, connect, timeout, TLS) →
  `(nil, "http: <description>")`.
- **`body` on GET/HEAD/OPTIONS** → `(nil, "http: body not allowed
  for <method>")` — reported, never silently dropped.
- **Unknown method** → `(nil, "http: unsupported method '...'")`.
- **HTTP status errors** are **not** errors — a `404` returns a
  normal `response` table with `status = 404`. Status semantics
  are the caller's responsibility.

## TLS / trust store

Babet ships its own static OpenSSL, so it doesn't automatically
inherit the distro's `ca-certificates` configuration. Two
mechanisms ensure `verify=true` works out of the box :

1. The vendored OpenSSL is built with `--openssldir=/etc/ssl`,
   covering Arch, Debian, Ubuntu, Alpine, Gentoo.
2. `babet.socket.connect_tls` additionally probes the known CA
   bundle paths (Fedora/RHEL, OpenSUSE, FreeBSD, NetBSD).
   **`babet.http` relies on the OpenSSL defaults alone**
   (mechanism 1) : on an exotic layout where point 1 is not
   enough, `http` may need `ca_cert` where `connect_tls` works.
   `tools/verif_ca.lua` diagnoses both paths.

You can override per-call with `ca_cert`, or globally via the
`SSL_CERT_FILE` / `SSL_CERT_DIR` environment variables.
[`security`](../security.md) and [`tls`](tls.md) for details.

## Design decisions

- **Synchronous, blocking**. Scripts are usually one-shot
  request-response affairs ; sync is simpler and sufficient. For
  many parallel calls, use [`workers`](workers.md).
- **`verify=true` by default**. Disabling TLS verification must
  be explicit (`verify=false`). No silent downgrade.
- **HTTP status is not an error**. The caller decides whether
  `404` or `500` is failure ; the network call itself succeeded.
- **Headers are normalised to lowercase keys** in the response,
  to make case-insensitive lookups work directly
  (`r.headers["content-type"]`).
- **Redirects are opt-in**. An unfollowed redirect is visible
  (`status = 301/302` + `location` header) ; following it is the
  caller's decision (`follow_redirects = true`). The hop limit is
  cpp-httplib's, not ours.

## Not in v1

- `put` / `delete` / `patch` shortcuts — covered by
  `request{ method = ... }` ; trivial sugar to add if the need is
  confirmed.
- `opts.ca_path` (per-call CA directory) and `opts.max_redirects`
  — an earlier version of this page wrongly documented them.
- Repeated response headers as a table of strings (multiple
  `Set-Cookie` case).
- Streaming response body (e.g. for downloading large files).
  Currently `body` is read fully into memory.
- HTTP/2 / HTTP/3.
- WebSockets (use [`socket`](socket.md) + TLS + a Lua framing
  library if needed).
- Server side. cpp-httplib supports it, but exposing a robust HTTP
  server to Lua is its own design effort.
