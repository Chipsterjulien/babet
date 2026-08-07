#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /chemin/vers/babet" >&2
    exit 2
fi
BINARY="$1"
if [ ! -x "$BINARY" ]; then
    echo "websocket runtime: binaire introuvable: $BINARY" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="${SCRIPT_DIR}/websocket_test_server.py"
TMP_ROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
    if [ -n "${SERVER_PID}" ]; then
        kill "${SERVER_PID}" 2>/dev/null || true
        wait "${SERVER_PID}" 2>/dev/null || true
    fi
    rm -rf "${TMP_ROOT}"
}
trap cleanup EXIT

pass=0
fail=0
record_pass() { echo "[PASS] $1"; pass=$((pass + 1)); }
record_fail() { echo "[FAIL] $1"; fail=$((fail + 1)); }

start_server() {
    local mode="$1"
    shift
    local port_file="${TMP_ROOT}/port"
    local log_file="${TMP_ROOT}/server.log"
    rm -f "${port_file}" "${log_file}"
    python3 "${SERVER}" --mode "${mode}" --port-file "${port_file}" "$@" >"${log_file}" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 250); do
        [ -s "${port_file}" ] && break
        if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
            cat "${log_file}" >&2 || true
            return 1
        fi
        sleep 0.02
    done
    [ -s "${port_file}" ] || return 1
    PORT="$(cat "${port_file}")"
}

finish_server() {
    local log_file="${TMP_ROOT}/server.log"
    if wait "${SERVER_PID}"; then
        SERVER_PID=""
        return 0
    fi
    SERVER_PID=""
    cat "${log_file}" >&2 || true
    return 1
}

run_lua() {
    local file="$1"
    "$BINARY" "$file"
}

# 1. Round-trip complet : fragmentation client/serveur, Ping/Pong, binaire, Close.
start_server roundtrip
cat > "${TMP_ROOT}/roundtrip.lua" <<EOF
local ws, err = babet.websocket.connect("ws://127.0.0.1:${PORT}/bidi?session=test", {
    timeout = 5,
    max_message_bytes = 200000,
    max_frame_bytes = 100000,
})
assert(ws, err)
assert(ws:send_text(string.rep("x", 70000)) == 70000)
local text = assert(ws:recv())
assert(text.type == "text" and text.data == "hello world")
local binary = assert(ws:recv())
assert(binary.type == "binary" and binary.data == "\0\1\255")
assert(ws:ping("client-ping"))
assert(ws:close(1000, "done", 5))
EOF
if run_lua "${TMP_ROOT}/roundtrip.lua" && finish_server; then
    record_pass "ws round-trip covers masking, fragmentation, Ping/Pong, binary and Close"
else
    record_fail "ws round-trip covers masking, fragmentation, Ping/Pong, binary and Close"
fi

# 2. Handshake Sec-WebSocket-Accept strict.
start_server bad-handshake
cat > "${TMP_ROOT}/bad_handshake.lua" <<EOF
local ws, err = babet.websocket.connect("ws://127.0.0.1:${PORT}/", { timeout = 5 })
assert(ws == nil and type(err) == "string" and err:find("handshake", 1, true), tostring(err))
EOF
if run_lua "${TMP_ROOT}/bad_handshake.lua" && finish_server; then
    record_pass "invalid Sec-WebSocket-Accept is rejected"
else
    record_fail "invalid Sec-WebSocket-Accept is rejected"
fi

# 3. Aucune extension n'a été offerte : toute réponse Extension est refusée.
start_server unsolicited-extension
cat > "${TMP_ROOT}/extension.lua" <<EOF
local ws, err = babet.websocket.connect("ws://127.0.0.1:${PORT}/", { timeout = 5 })
assert(ws == nil and type(err) == "string" and err:find("extension", 1, true), tostring(err))
EOF
if run_lua "${TMP_ROOT}/extension.lua" && finish_server; then
    record_pass "unsolicited WebSocket extension is rejected"
else
    record_fail "unsolicited WebSocket extension is rejected"
fi

# 4. Aucun sous-protocole n'a été offert : toute sélection est refusée.
start_server unsolicited-protocol
cat > "${TMP_ROOT}/protocol.lua" <<EOF
local ws, err = babet.websocket.connect("ws://127.0.0.1:${PORT}/", { timeout = 5 })
assert(ws == nil and type(err) == "string" and err:find("subprotocol", 1, true), tostring(err))
EOF
if run_lua "${TMP_ROOT}/protocol.lua" && finish_server; then
    record_pass "unsolicited WebSocket subprotocol is rejected"
else
    record_fail "unsolicited WebSocket subprotocol is rejected"
fi

# 5. Un espace avant ':' dans un nom de header n'est pas normalisé.
start_server malformed-header
cat > "${TMP_ROOT}/malformed_header.lua" <<EOF
local ws, err = babet.websocket.connect("ws://127.0.0.1:${PORT}/", { timeout = 5 })
assert(ws == nil and type(err) == "string" and err:find("malformed HTTP response header", 1, true), tostring(err))
EOF
if run_lua "${TMP_ROOT}/malformed_header.lua" && finish_server; then
    record_pass "malformed handshake header name is rejected"
else
    record_fail "malformed handshake header name is rejected"
fi

# 6. Un serveur ne doit jamais masquer ses frames.
start_server masked-server
cat > "${TMP_ROOT}/masked.lua" <<EOF
local ws = assert(babet.websocket.connect("ws://127.0.0.1:${PORT}/", { timeout = 5 }))
local msg, err = ws:recv(5)
assert(msg == nil and type(err) == "string" and err:find("protocol error", 1, true), tostring(err))
EOF
if run_lua "${TMP_ROOT}/masked.lua" && finish_server; then
    record_pass "masked server frame is rejected with protocol close"
else
    record_fail "masked server frame is rejected with protocol close"
fi

# 7. Une longueur annoncée trop grande est rejetée avant lecture/allocation du payload.
start_server oversize
cat > "${TMP_ROOT}/oversize.lua" <<EOF
local ws = assert(babet.websocket.connect("ws://127.0.0.1:${PORT}/", {
    timeout = 5,
    max_message_bytes = 32,
    max_frame_bytes = 32,
}))
local msg, err = ws:recv(5)
assert(msg == nil and type(err) == "string" and err:find("max_frame_bytes", 1, true), tostring(err))
EOF
if run_lua "${TMP_ROOT}/oversize.lua" && finish_server; then
    record_pass "oversized announced frame is rejected before payload allocation"
else
    record_fail "oversized announced frame is rejected before payload allocation"
fi

# 8. Une raison Close UTF-8 invalide doit produire 1007, pas 1002.
start_server invalid-close-utf8
cat > "${TMP_ROOT}/invalid_close_utf8.lua" <<EOF
local ws = assert(babet.websocket.connect("ws://127.0.0.1:${PORT}/", { timeout = 5 }))
local msg, err = ws:recv(5)
assert(msg == nil and type(err) == "string" and err:find("UTF%-8"), tostring(err))
EOF
if run_lua "${TMP_ROOT}/invalid_close_utf8.lua" && finish_server; then
    record_pass "invalid UTF-8 Close reason is rejected with close code 1007"
else
    record_fail "invalid UTF-8 Close reason is rejected with close code 1007"
fi

# 9. WSS local : CA explicite + hostname/IP verification.
CERT="${TMP_ROOT}/cert.pem"
KEY="${TMP_ROOT}/key.pem"
cat > "${TMP_ROOT}/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = 127.0.0.1
[v3]
subjectAltName = IP:127.0.0.1
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
EOF
if openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "${KEY}" -out "${CERT}" -config "${TMP_ROOT}/openssl.cnf" >/dev/null 2>&1; then
    start_server secure --cert "${CERT}" --key "${KEY}"
    cat > "${TMP_ROOT}/secure.lua" <<EOF
local ws, err = babet.websocket.connect("wss://127.0.0.1:${PORT}/secure", {
    timeout = 5,
    ca_cert = [[${CERT}]],
})
assert(ws, err)
local msg = assert(ws:recv())
assert(msg.type == "text" and msg.data == "secure")
assert(ws:close(1000, "done", 5))
EOF
    if run_lua "${TMP_ROOT}/secure.lua" && finish_server; then
        record_pass "wss accepts a locally trusted certificate with SAN IP verification"
    else
        record_fail "wss accepts a locally trusted certificate with SAN IP verification"
    fi
else
    record_fail "local WSS certificate generation"
fi

echo "websocket runtime regression: ${pass} PASS / ${fail} FAIL"
[ "${fail}" -eq 0 ]
