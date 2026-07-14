> **English** | [Français](../../fr/modules/user.md)

# USER - look up system accounts by name or UID

The `babet.user` module queries the system user database through NSS. It can:

- look up an account by name;
- look up an account by UID;
- quickly test whether an account exists;
- retrieve the name, UID, primary GID, GECOS field, home directory, and shell.

It never parses `/etc/passwd` directly. It uses the same resolution mechanisms
as `id` or `getent passwd`, so it can see accounts supplied by LDAP, SSSD, NIS,
FreeIPA, or other sources configured in `/etc/nsswitch.conf`.

## Module contents

- [General conventions](#user-conventions)
- [API overview](#user-api-summary)
- [Returned user table](#user-result-table)
- [Look up an account with `get`](#user-get)
  - [By name](#user-get-name)
  - [By UID](#user-get-uid)
  - [Missing account](#user-get-missing)
- [Test existence with `exists`](#user-exists)
  - [By name](#user-exists-name)
  - [By UID](#user-exists-uid)
  - [When to prefer `get`](#user-exists-errors)
- [Argument validation](#user-validation)
- [NSS, workers, and security](#user-nss)
- [Error contract](#user-errors)
- [Design decisions and limits](#user-design)

<a id="user-conventions"></a>
## General conventions

### Dedicated subtable

Unlike the historical SYS or FS functions, user helpers live under
`babet.user`:

```lua
local user = babet.user.get("root")
local exists = babet.user.exists("root")
```

### Name or UID, without implicit conversion

The argument accepts exactly:

- a Lua string: lookup by **name**;
- a non-negative Lua integer in the `uid_t` range: lookup by **UID**.

A numeric string remains a name:

```lua
-- Looks for an account literally named "1000"
local by_name = babet.user.get("1000")

-- Looks up numeric UID 1000
local by_uid = babet.user.get(1000)
```

Floats, booleans, tables, `nil`, negative UIDs, and oversized UIDs raise a Lua
error. No silent conversion or truncation is performed.

### Fields are always present

When a user is found, the returned table always contains all six documented
fields. Text fields may be empty strings, but never `nil`.

<a id="user-api-summary"></a>
## API overview

| Function | Result |
| --- | --- |
| `babet.user.get(name_or_uid)` | table, `(nil, "user not found")`, or `(nil, "user: ...")` |
| `babet.user.exists(name_or_uid)` | strict boolean |

<a id="user-result-table"></a>
## Returned user table

Typical example:

```lua
{
    name  = "www-data",
    uid   = 33,
    gid   = 33,
    gecos = "www-data",
    home  = "/var/www",
    shell = "/usr/sbin/nologin",
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | canonical account name returned by NSS |
| `uid` | integer | numeric user identifier |
| `gid` | integer | account's **primary** GID |
| `gecos` | string | raw descriptive field, often the full name |
| `home` | string | configured home directory |
| `shell` | string | configured login shell |

`gid` is not a list of supplementary groups. The module does not perform group
lookups and does not expose additional memberships.

The `gecos` field is returned unchanged. Its historical format can contain
comma-separated values, but many systems simply store a free-form name.

```lua
local u = assert(babet.user.get("root"))
print("Name :", u.name)
print("UID  :", u.uid)
print("GID  :", u.gid)
print("GECOS:", u.gecos)
print("Home :", u.home)
print("Shell:", u.shell)
```

<a id="user-get"></a>
## Look up an account with `get`

Signature:

```lua
local info, err = babet.user.get(name_or_uid)
```

Use `get` when you need account details or must distinguish a missing account
from an NSS failure.

<a id="user-get-name"></a>
### By name

```lua
local root, err = babet.user.get("root")
assert(root, err)
assert(root.name == "root")
assert(root.uid == 0)
```

Preparing a directory for a service account:

```lua
local account, err = babet.user.get("my-service")
assert(account, err)

assert(babet.mkdir("/var/lib/my-service"))
assert(babet.setAttributes(
    "/var/lib/my-service",
    account.uid,
    account.gid,
    "750"
))
```

The name is passed to NSS unchanged. It must be a string without an embedded
NUL byte. An empty string is a valid API input, but normally matches no account
and returns `user not found`.

<a id="user-get-uid"></a>
### By UID

```lua
local root, err = babet.user.get(0)
assert(root, err)
assert(root.name == "root")
```

Displaying the account associated with a file owner:

```lua
local attrs, err = babet.getAttributes("report.txt")
assert(attrs, err)

local owner, user_err = babet.user.get(attrs.owner)
if owner then
    print("Owner:", owner.name)
else
    print("Unresolved owner UID:", attrs.owner, user_err)
end
```

The UID must be a non-negative integer compatible with the system `uid_t` type.
On Linux the limit is usually `2^32 - 1`, but the code uses the actual platform
limit at compile time.

<a id="user-get-missing"></a>
### Missing account

A missing account is not a Lua error. The function returns:

```lua
local info, err = babet.user.get("missing-account")
-- info == nil
-- err  == "user not found"
```

Typical handling:

```lua
local account, err = babet.user.get("my-service")
if not account then
    if err == "user not found" then
        print("The account must be created")
    else
        print("NSS lookup failed:", err)
    end
end
```

Avoid this when absence is expected:

```lua
-- Wrong for an optional account: assert raises immediately
-- local account = assert(babet.user.get("optional-account"))
```

<a id="user-exists"></a>
## Test existence with `exists`

Signature:

```lua
local present = babet.user.exists(name_or_uid)
```

The function always returns a boolean for a valid argument.

<a id="user-exists-name"></a>
### By name

```lua
if babet.user.exists("www-data") then
    print("The www-data account exists")
end
```

Simple precondition:

```lua
if not babet.user.exists("my-service") then
    error("The my-service account must exist before startup")
end
```

<a id="user-exists-uid"></a>
### By UID

```lua
assert(babet.user.exists(0)) -- root on a normal Unix system
```

A missing UID returns `false`:

```lua
local present = babet.user.exists(2000000000)
print(present)
```

<a id="user-exists-errors"></a>
### When to prefer `get`

`exists` deliberately converts an NSS error to `false`.

This makes it convenient for a simple branch, but it cannot distinguish:

- an account that truly does not exist;
- a temporarily unavailable LDAP directory;
- an I/O error;
- an out-of-memory condition in the resolver.

For an important administrative or security decision, use `get`:

```lua
local account, err = babet.user.get("my-service")
if account then
    print("Account available")
elseif err == "user not found" then
    print("Account missing")
else
    error("Unable to query NSS: " .. err)
end
```

<a id="user-validation"></a>
## Argument validation

The following cases raise a Lua error, recoverable with `pcall`:

```lua
local invalid_calls = {
    function() return babet.user.get() end,
    function() return babet.user.get(nil) end,
    function() return babet.user.get(true) end,
    function() return babet.user.get({}) end,
    function() return babet.user.get(1.5) end,
    function() return babet.user.get(-1) end,
    function() return babet.user.get(8589934592) end,
    function() return babet.user.get("root\0other") end,
}

for _, call in ipairs(invalid_calls) do
    local ok, err = pcall(call)
    assert(not ok)
    print(err)
end
```

`exists` applies exactly the same validation:

```lua
local ok = pcall(function()
    return babet.user.exists(-1)
end)
assert(not ok)
```

Rejecting NUL bytes prevents `"root\0other"` from being interpreted as
`"root"` by `getpwnam_r`.

<a id="user-nss"></a>
## NSS, workers, and security

### Account sources

The result depends on the machine's NSS configuration. According to
`/etc/nsswitch.conf`, an account may come from:

- `/etc/passwd`;
- LDAP;
- SSSD;
- NIS;
- FreeIPA;
- systemd-userdb;
- another NSS module.

The same script may therefore see different accounts on different machines
without any Babet change.

### Calls from workers

The module uses the reentrant `getpwnam_r` and `getpwuid_r` functions. It can be
used inside workers:

```lua
local worker = assert(babet.workers.spawn([[
    local root, err = babet.user.get("root")
    if not root then
        error(err)
    end
    return root.uid
]]))

local joined, uid = worker:join()
assert(joined and uid == 0)
```

Each call queries NSS. Babet does not maintain an application-level user cache.

### Security-sensitive decisions

The `home` and `shell` fields are configuration data, not proof that a path
exists or that a program is executable.

```lua
local u = assert(babet.user.get("my-service"))
local home_is_dir = assert(babet.isDir(u.home))
local shell_path = babet.which(u.shell)
```

Likewise, the presence of an account does not prove that it can log in, that a
password is valid, or that it belongs to a particular supplementary group.

<a id="user-errors"></a>
## Error contract

| Situation | `get` | `exists` |
| --- | --- | --- |
| account found | user table | `true` |
| account missing | `(nil, "user not found")` | `false` |
| NSS error | `(nil, "user: ...")` | `false` |
| invalid argument | Lua error | Lua error |

Generic handling:

```lua
local ok, info, err = pcall(function()
    return babet.user.get("my-service")
end)

if not ok then
    print("Invalid call:", info)
elseif not info then
    print("Lookup failed:", err)
else
    print("UID:", info.uid)
end
```

<a id="user-design"></a>
## Design decisions and limits

- NSS is used instead of parsing `/etc/passwd`.
- Reentrant `_r` variants are used for worker compatibility.
- Text fields are always present and replaced with `""` if NSS supplies a null
  pointer.
- The NSS buffer grows dynamically up to an internal 64 KiB limit; beyond that,
  `get` returns an NSS error.
- `exists` favors a simple boolean API and hides NSS errors; use `get` when a
  diagnosis is required.
- The module does not expose supplementary groups.
- It exposes neither `/etc/shadow`, passwords, nor account expiration data.
- It does not create, remove, or modify users.
- To create an account, a script can invoke a system utility through
  [`babet.exec`](exec.md), with appropriate privileges.
