> **English** | [Français](../../fr/modules/http.md)

# HTTP — synchronous web requests, headers, bodies, TLS, and limits

`babet.http` is a synchronous HTTP/HTTPS client built on cpp-httplib and
OpenSSL. It is intended for APIs, webhooks, bounded downloads, and simple REST
calls.

It supports:

- HTTP and HTTPS;
- GET, HEAD, OPTIONS, POST, PUT, PATCH, and DELETE;
- encoded and normalised query parameters;
- request headers;
- text or binary request bodies;
- binary responses;
- repeated response headers;
- optional redirects;
- TLS verification by default;
- connection and global request timeouts;
- a maximum in-memory response size.

It does not expose streaming, persistent sessions, a cookie jar,
multipart/form-data, form helpers, proxies, an HTTP server, WebSockets, HTTP/2,
or HTTP/3.

## Module contents

- [Core conventions](#http-conventions)
- [API overview](#http-api-summary)
- [`request(opts)`](#http-request)
- [`get(url, opts?)`](#http-get)
- [`post` call forms](#http-post)
- [URLs, fragments, and query](#http-url-query)
- [HTTP methods](#http-methods)
- [Request headers](#http-request-headers)
- [Request body and Content-Type](#http-body)
- [Timeouts](#http-timeout)
- [TLS and CA](#http-tls)
- [Redirects](#http-redirects)
- [Maximum response size](#http-max-body)
- [Response table](#http-response)
- [Complete examples](#http-examples)
- [Error contract](#http-errors)
- [Security and limitations](#http-design)

<a id="http-conventions"></a>
## Core conventions

### Synchronous client

The call blocks the current thread until response or error. Use independent
[`workers`](workers.md) for parallel requests.

### HTTP status is not a transport error

A received 404 or 500 is a normal response table:

```lua
local response, err = babet.http.get(url, { timeout = 10 })
assert(response, err)

if response.status >= 200 and response.status < 300 then
    print(response.body)
else
    io.stderr:write("HTTP ", response.status, "\n", response.body)
end
```

DNS, TCP, TLS, timeout, and body-limit failures return `(nil, err)`.

### Binary bodies

Request bodies and `response.body` may contain NUL bytes:

```lua
local response = assert(babet.http.post(url, "AB\0CD", {
    timeout = 10,
}))
```

URLs, methods, header names, CA paths, and other C-facing strings reject NUL.
URLs and headers also reject CR/LF to prevent HTTP-line injection.

### Unknown option fields

Unknown fields are currently ignored. A typo such as `timeot = 5` does not
activate a timeout and does not fail. Use the documented names exactly.

<a id="http-api-summary"></a>
## API overview

```lua
local response, err = babet.http.request(opts)
local response, err = babet.http.get(url, opts?)
local response, err = babet.http.post(url)
local response, err = babet.http.post(url, body)
local response, err = babet.http.post(url, opts)
local response, err = babet.http.post(url, body, opts)
local response, err = babet.http.post(url, nil, opts)
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `url` | string | required by `request` | absolute `http://` or `https://` URL |
| `method` | string | `"GET"` | supported method, case-insensitive |
| `headers` | table | `{}` | string names; string/number values |
| `body` | binary string | absent | body for body-capable methods |
| `query` | table | absent | string keys; string/number values |
| `timeout` | finite number `> 0` | library defaults | seconds, connect plus global budget |
| `verify` | strict boolean | `true` | HTTPS certificate verification |
| `ca_cert` | string | OpenSSL trust store | CA file path |
| `follow_redirects` | strict boolean | `false` | follow redirects automatically |
| `max_body_size` | integer `1..2 GiB` | `64 MiB` | in-memory response cap |

`get` and `post` always overwrite `url` and `method` after shallow-copying
options.

<a id="http-request"></a>
## `babet.http.request(opts)`

General form for every method:

```lua
local response, err = babet.http.request({
    url = "https://api.example.com/items/42",
    method = "DELETE",
    headers = {
        ["Authorization"] = "Bearer " .. token,
    },
    timeout = 10,
})
```

The first argument must be a table. `opts.url` must be a strict string.
Invalid option fields return `(nil, err)`; a wrong first-argument type raises.

<a id="http-get"></a>
## `babet.http.get(url, opts?)`

The wrapper shallow-copies `opts`, then forces:

```lua
opts.url = url
opts.method = "GET"
```

```lua
local response, err = babet.http.get(
    "https://api.example.com/health",
    { timeout = 5 }
)
```

The second argument must be absent, `nil`, or a table. GET rejects `opts.body`
instead of silently dropping it.

<a id="http-post"></a>
## `babet.http.post` call forms

No explicit body:

```lua
babet.http.post(url)
babet.http.post(url, { timeout = 5 })
babet.http.post(url, nil, { timeout = 5 })
```

Positional body:

```lua
babet.http.post(url, "payload", { timeout = 5 })
```

Body in options:

```lua
babet.http.post(url, {
    body = "payload",
    timeout = 5,
})
```

A table in the second position is interpreted as `opts`. Any other non-string,
non-nil second value raises. When both a positional body and `opts.body` exist,
the positional body wins.

<a id="http-url-query"></a>
## URLs, fragments, and query

Only absolute HTTP/HTTPS URLs are accepted. A non-empty host is required;
bracketed IPv6 literals are supported:

```lua
local r, err = babet.http.get("http://[::1]:8080/", { timeout = 2 })
```

Fragments are removed and never sent.

Add query parameters with a table:

```lua
local response = assert(babet.http.get("https://example.com/search", {
    query = {
        q = "lua socket",
        page = 2,
    },
    timeout = 10,
}))
```

Keys must be strings; values may be strings or numbers. Babet protects query
delimiters and non-ASCII bytes first, then cpp-httplib 0.45.0 normalises the
query before it is sent. The effective wire format therefore follows these
conventions:

- spaces become `+`;
- `+` becomes `%2B`;
- `/` and `?` remain literal inside a value;
- non-ASCII UTF-8 bytes are percent-encoded as `%HH`;
- `&`, `=`, and `%` are percent-encoded when they belong to a key or value.

For example, `q = "lua socket"` becomes `q=lua+socket`, while
`path = "a/b"` remains `path=a/b`.

When the URL already contains `?a=b`, new parameters are appended with `&`.
The existing query is normalised as well: `%20` may become `+` and `%2F` may
become `/`. The `#...` fragment is removed before transmission.

Lua table iteration order is not stable, so do not build canonical signatures
by assuming the order produced from `query`. For canonical signing, construct
an already ordered URL yourself and account for the normalisation described
above.

NUL bytes in query keys/values are sent as `%00`; make sure the server accepts
that semantic.

<a id="http-methods"></a>
## HTTP methods

Supported methods:

- GET;
- HEAD;
- OPTIONS;
- POST;
- PUT;
- PATCH;
- DELETE.

Method names are uppercased internally:

```lua
local response = assert(babet.http.request({
    url = "https://api.example.com/items/42",
    method = "patch",
    body = '{"enabled":true}',
    headers = { ["Content-Type"] = "application/json" },
    timeout = 10,
}))
```

GET, HEAD, and OPTIONS reject a body. POST, PUT, PATCH, and DELETE accept an
absent, empty, or non-empty body.

There are no `put`, `patch`, or `delete` shortcuts; use `request`.

<a id="http-request-headers"></a>
## Request headers

```lua
headers = {
    ["Accept"] = "application/json",
    ["Authorization"] = "Bearer " .. token,
    ["X-Retry"] = 3,
}
```

Header names must be non-empty HTTP `token` strings: alphanumeric plus
``!#$%&'*+-.^_`|~``. Spaces, tabs, colon, CR/LF, NUL, and non-string keys are
rejected.

Values may be strings or numbers. Numbers are converted using Lua's textual
conversion. NUL, CR/LF, booleans, tables, and other types are rejected.

A Lua table cannot represent repeated exact request-header names. The binding
does not expose a multi-value request-header form. Combine values only when the
specific header grammar permits it.

Names are sent with the provided case; HTTP matching is case-insensitive.
`Content-Type` detection is case-insensitive.

<a id="http-body"></a>
## Request body and `Content-Type`

Absent and explicitly empty bodies differ:

```lua
babet.http.post(url, { timeout = 5 }) -- no body field
babet.http.post(url, "", { timeout = 5 }) -- present empty body
```

When a body exists on POST/PUT/PATCH/DELETE and no Content-Type is supplied,
Babet uses `application/octet-stream`. No default Content-Type is added when the
body is absent.

JSON example:

```lua
local payload = assert(babet.json.encode({ name = "babet" }))
local response = assert(babet.http.post(url, payload, {
    headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    },
    timeout = 10,
}))
```

There is no `form` helper. Encode URL-encoded form data yourself and set
`application/x-www-form-urlencoded`. The `query` table changes the URL only;
it does not build a form body.

No multipart builder or streaming upload is exposed. For large/complex uploads,
use a specialised tool through `babet.exec` without unsafe shell concatenation.

<a id="http-timeout"></a>
## `opts.timeout`

```lua
local response, err = babet.http.get(url, { timeout = 10 })
```

The value must be finite and strictly positive. Positive values below 1 ms are
rounded up. Babet configures both a connection timeout and cpp-httplib's global
maximum request timeout; the first limit reached wins.

Synchronous DNS may still happen outside the controllable library budget and
can make wall-clock duration exceed the requested timeout.

Without an explicit timeout, cpp-httplib/system defaults apply. Always set one
for remote services.

<a id="http-tls"></a>
## HTTPS, verification, and CA

Verification defaults to true:

```lua
local response = assert(babet.http.get("https://example.com/", {
    timeout = 10,
}))
```

Use a private CA file:

```lua
local response = assert(babet.http.get("https://internal.example/", {
    ca_cert = "/etc/myapp/internal-ca.pem",
    timeout = 10,
}))
```

HTTP exposes `ca_cert`, not `ca_path`, and does not run the socket TLS module's
manual distro-path probing. It relies on the embedded OpenSSL defaults,
environment, and the supplied CA file.

```lua
local response = assert(babet.http.get("https://127.0.0.1:8443/", {
    verify = false,
    timeout = 3,
}))
```

Use `verify = false` only in controlled tests. HTTP has no separate hostname
override; the URL host is used.

<a id="http-redirects"></a>
## `follow_redirects`

Redirects are visible by default:

```lua
local r = assert(babet.http.get(url, { timeout = 10 }))
if r.status == 302 then
    print(r.headers.location)
end
```

Enable automatic following:

```lua
local r = assert(babet.http.get(url, {
    follow_redirects = true,
    timeout = 10,
}))
```

The result describes the final response. Redirect history and `max_redirects`
are not exposed; cpp-httplib's internal limit applies.

For untrusted URLs, consider redirects to another domain, HTTPS-to-HTTP
downgrade, internal/metadata addresses, and sensitive-header handling.

<a id="http-max-body"></a>
## `max_body_size`

The entire response is buffered in memory:

```lua
local response, err = babet.http.get(url, {
    timeout = 30,
    max_body_size = 8 * 1024 * 1024,
})
```

- default: 64 MiB;
- minimum: 1 byte;
- maximum: 2 GiB;
- strict positive Lua integer.

When actual received chunks would exceed the cap, Babet aborts and returns:

```lua
nil, "http: response body exceeds max_body_size"
```

No partial body is exposed. The guard applies to actual received bytes, not
only Content-Length, including chunked or misleading responses.

Use an external streaming tool for large downloads; a 2 GiB cap can imply a
multi-gigabyte allocation.

<a id="http-response"></a>
## Response table

```lua
{
    status = 200,
    body = "...",
    headers = {
        ["content-type"] = "application/json",
        ["set-cookie"] = "b=2",
    },
    headers_multi = {
        ["content-type"] = { "application/json" },
        ["set-cookie"] = { "a=1", "b=2" },
    },
}
```

- `status`: integer HTTP status;
- `body`: complete binary string, possibly empty; HEAD returns an empty body;
- `headers`: lowercase names, last occurrence wins;
- `headers_multi`: lowercase names, every occurrence in an array, even one.

Use `headers_multi` for repeated fields such as Set-Cookie:

```lua
for _, cookie in ipairs(response.headers_multi["set-cookie"] or {}) do
    print(cookie)
end
```

<a id="http-examples"></a>
## Complete examples

### GET JSON

```lua
local response, err = babet.http.get("https://api.example.com/v1/status", {
    headers = { ["Accept"] = "application/json" },
    query = { verbose = 1 },
    timeout = 10,
    max_body_size = 1024 * 1024,
})
assert(response, err)
assert(response.status == 200, response.body)
local data = assert(babet.json.decode(response.body))
```

### Authenticated JSON POST

```lua
local body = assert(babet.json.encode({ title = "hello" }))
local response, err = babet.http.post(
    "https://api.example.com/v1/items",
    body,
    {
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
        },
        timeout = 15,
        max_body_size = 2 * 1024 * 1024,
    }
)
assert(response, err)
```

### Binary PUT

```lua
local file = assert(io.open("image.bin", "rb"))
local payload = file:read("a")
file:close()

local response = assert(babet.http.request({
    url = "https://upload.example.com/blob/42",
    method = "PUT",
    body = payload,
    headers = { ["Content-Type"] = "application/octet-stream" },
    timeout = 30,
    max_body_size = 1024 * 1024,
}))
```

This loads the file into memory and is not suitable for very large uploads.

### Separate network and HTTP failures

```lua
local response, err = babet.http.get(url, { timeout = 5 })
if not response then
    io.stderr:write("transport failure: ", err, "\n")
elseif response.status == 404 then
    print("not found")
elseif response.status >= 400 then
    io.stderr:write("HTTP ", response.status, "\n")
else
    print(response.body)
end
```

### Parallel requests with WORKERS

```lua
local jobs = {}
for i, url in ipairs(urls) do
    jobs[i] = assert(babet.workers.spawn([[
        local r, err = babet.http.get(worker.args.url, {
            timeout = 10,
            max_body_size = 1024 * 1024,
        })
        if not r then error(err) end
        return { status = r.status, size = #r.body }
    ]], { url = url }))
end

for i, job in ipairs(jobs) do
    local ok_result, value = job:join()
    if ok_result then
        print(urls[i], value.status, value.size)
    else
        io.stderr:write(urls[i], ": ", value, "\n")
    end
end
```

<a id="http-errors"></a>
## Error contract

Wrong positional types raise:

```lua
babet.http.request("not a table")
babet.http.get(42)
babet.http.get(url, "not a table")
babet.http.post(url, 42)
```

Invalid values and runtime failures return `(nil, err)`: missing/bad URL,
unsupported method, forbidden body, invalid options/query/headers, DNS/TCP/TLS,
timeout, response limit, and converted internal exceptions.

Any received HTTP status, including 3xx/4xx/5xx, returns a normal response.

<a id="http-design"></a>
## Security and limitations

- Validate untrusted URLs against SSRF to loopback, LAN, cloud metadata, and
  administrative services.
- Treat redirects as new destinations and protect sensitive headers.
- Keep TLS verification enabled; use private CA trust instead of disabling it.
- Set the smallest practical `max_body_size`.
- Request and response bodies are in memory; no streaming.
- Every call constructs a client; no exposed cookie jar or connection pool.
- No form/multipart helper, proxy configuration, HTTP/2/3, WebSocket, or server.
- DNS is synchronous and may exceed the requested timeout.
