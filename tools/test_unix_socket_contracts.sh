#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE="${PROJECT_DIR}/src/lua_bindings/socket.cpp"
HEADER="${PROJECT_DIR}/src/lua_bindings/socket.hpp"
SUITE="${PROJECT_DIR}/examples/selftest/suites/network/unix_socket.lua"
REGISTRY="${PROJECT_DIR}/examples/selftest/suites/network/init.lua"

python3 - "${SOURCE}" "${HEADER}" "${SUITE}" "${REGISTRY}" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
header = Path(sys.argv[2]).read_text(encoding="utf-8")
suite = Path(sys.argv[3]).read_text(encoding="utf-8")
registry = Path(sys.argv[4]).read_text(encoding="utf-8")

checks = []

def check(name, condition):
    checks.append((name, bool(condition)))

check("Unix constructors are declared and registered",
      "lua_socket_connect_unix" in header
      and "lua_socket_listen_unix" in header
      and 'lua_setfield(L, -2, "connect_unix")' in source
      and 'lua_setfield(L, -2, "listen_unix")' in source)
check("Unix sockets use pathname AF_UNIX stream descriptors",
      "AF_UNIX" in source and "SOCK_STREAM | SOCK_CLOEXEC" in source
      and "sockaddr_un" in source)
check("Unix connect shares the monotonic deadline machinery",
      "unix_connect_owned" in source
      and "Deadline deadline = make_deadline(timeout_ms);" in source
      and "wait_ready_deadline(fd, POLLOUT, deadline)" in source)
check("Unix listener refuses every pre-existing pathname",
      "path already exists; remove stale sockets explicitly" in source
      and re.search(r"lstat\(path\.c_str\(\), &existing\).*?ENOENT",
                    source, re.S))
check("Unix listener permissions are exact and nofollow",
      "permissions = 0600" in source
      and "AT_SYMLINK_NOFOLLOW" in source
      and "permissions were not applied exactly" in source)
check("Unix pathname cleanup is inode-sensitive",
      "same_unix_entry" in source
      and "st.st_dev == s->unix_dev" in source
      and "st.st_ino == s->unix_ino" in source
      and "release_owned_unix_path" in source)
check("Accepted sockets inherit the listener domain",
      "attach_plain_sock(owner, client_fd, false, s->domain)" in source)
check("Unix peer and sockname expose path tables",
      'sa->sa_family == AF_UNIX' in source
      and 'lua_setfield(L, -2, "path")' in source)
check("STARTTLS is explicitly restricted to TCP",
      "TLS is supported only on TCP sockets" in source)
check("Unix regression suite is reachable",
      'test:run("selftest.suites.network.unix_socket")' in registry)
check("Unix tests cover lifecycle, replacement safety and workers",
      "closing the Unix listener unlinks its owned pathname" in suite
      and "listener close never deletes a replacement entry" in suite
      and "worker completes the Unix socket round-trip" in suite)
check("Unix tests cover strict options and path boundaries",
      "listen_unix rejects unknown options" in suite
      and "exact sockaddr_un path boundary" in suite
      and "beyond sockaddr_un" in suite)
check("Unix tests distinguish socket path existence from regular files",
      "local function path_exists(path)" in suite
      and "babet.getMode(path)" in suite
      and "babet.fileExists(path)" not in suite)

failed = [name for name, passed in checks if not passed]
for name, passed in checks:
    print(f"[{'PASS' if passed else 'FAIL'}] {name}")

if failed:
    raise SystemExit(1)
print(f"Unix socket structural contracts: {len(checks)} PASS / 0 FAIL")
PY
