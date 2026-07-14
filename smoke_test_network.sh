#!/usr/bin/env bash
# smoke_test_network.sh — Tests d'intégration réseau pour Babet.
#
# Les invariants appartenant à Babet sont vérifiés localement et sont
# bloquants. Les sondes vers des services publics restent visibles mais sont
# non bloquantes par défaut : une panne tierce, un proxy, un filtrage DNS ou
# une interception TLS ne doit pas suffire à invalider une release.
#
# Pour rendre aussi les sondes externes bloquantes :
#   BABET_SMOKE_STRICT_EXTERNAL=1 ./smoke_test_network.sh ./test/babet

set -u

BIN="${1:-./test/babet}"
if [ ! -x "$BIN" ]; then
    echo "Usage: $0 [chemin/vers/babet]"
    echo "Binaire introuvable ou non exécutable : $BIN"
    exit 1
fi

TMPDIR=$(mktemp -d -t babet-smoke-XXXXXX)
HTTPS_PID=""

cleanup() {
    if [ -n "$HTTPS_PID" ] && kill -0 "$HTTPS_PID" 2>/dev/null; then
        kill "$HTTPS_PID" 2>/dev/null || true
        wait "$HTTPS_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

PASS=0
FAIL=0
WARN=0
STRICT_EXTERNAL="${BABET_SMOKE_STRICT_EXTERNAL:-0}"

# run_case NOM SCRIPT PATTERN [required|advisory] [attempts]
run_case() {
    local name="$1"
    local script="$2"
    local expected_pattern="$3"
    local severity="${4:-required}"
    local attempts="${5:-1}"
    local output=""
    local rc=1
    local attempt

    printf '%s\n' "$script" > "$TMPDIR/main.lua"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        set +e
        output=$(env -u SSL_CERT_FILE -u SSL_CERT_DIR \
                 "$BIN" "$TMPDIR" 2>&1)
        rc=$?
        set -e

        if [ "$rc" -eq 0 ] && printf '%s\n' "$output" | grep -qE "$expected_pattern"; then
            echo "[PASS] $name"
            PASS=$((PASS + 1))
            return 0
        fi

        if [ "$attempt" -lt "$attempts" ]; then
            sleep 1
        fi
    done

    if [ "$severity" = "advisory" ] && [ "$STRICT_EXTERNAL" != "1" ]; then
        echo "[WARN] $name"
        WARN=$((WARN + 1))
    else
        echo "[FAIL] $name"
        FAIL=$((FAIL + 1))
    fi
    echo "       tentatives        : $attempts"
    echo "       code de sortie    : $rc"
    echo "       attendu (pattern) : $expected_pattern"
    echo "       reçu              : $output"
    return 0
}

require_tool() {
    local tool="$1"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[FAIL] outil requis absent : $tool"
        exit 1
    fi
}

start_local_https_fixture() {
    require_tool openssl
    require_tool python3

    local ca_key="$TMPDIR/ca.key"
    local ca_cert="$TMPDIR/ca.crt"
    local server_key="$TMPDIR/server.key"
    local server_csr="$TMPDIR/server.csr"
    local server_cert="$TMPDIR/server.crt"
    local server_ext="$TMPDIR/server.ext"
    local port_file="$TMPDIR/https.port"
    local server_log="$TMPDIR/https-server.log"

    cat > "$server_ext" <<'EXT'
subjectAltName=IP:127.0.0.1,DNS:localhost
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT

    if ! openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
        -subj "/CN=Babet Smoke Test CA" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$ca_key" -out "$ca_cert" \
        >"$TMPDIR/openssl-ca.log" 2>&1; then
        echo "[FAIL] génération de l'autorité TLS locale"
        cat "$TMPDIR/openssl-ca.log"
        exit 1
    fi

    if ! openssl req -newkey rsa:2048 -nodes -sha256 \
        -subj "/CN=localhost" \
        -keyout "$server_key" -out "$server_csr" \
        >"$TMPDIR/openssl-csr.log" 2>&1; then
        echo "[FAIL] génération de la requête de certificat TLS locale"
        cat "$TMPDIR/openssl-csr.log"
        exit 1
    fi

    if ! openssl x509 -req -sha256 -days 1 \
        -in "$server_csr" -CA "$ca_cert" -CAkey "$ca_key" \
        -CAcreateserial -extfile "$server_ext" -out "$server_cert" \
        >"$TMPDIR/openssl-sign.log" 2>&1; then
        echo "[FAIL] signature du certificat TLS local"
        cat "$TMPDIR/openssl-sign.log"
        exit 1
    fi

    cat > "$TMPDIR/https_server.py" <<'PY'
import http.server
import os
import ssl
import sys

cert_file, key_file, port_file = sys.argv[1:4]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        body = b"babet local TLS smoke test\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certfile=cert_file, keyfile=key_file)
server.socket = context.wrap_socket(server.socket, server_side=True)

temporary = port_file + ".tmp"
with open(temporary, "w", encoding="ascii") as handle:
    handle.write(str(server.server_address[1]))
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, port_file)
server.serve_forever()
PY

    python3 "$TMPDIR/https_server.py" \
        "$server_cert" "$server_key" "$port_file" \
        >"$server_log" 2>&1 &
    HTTPS_PID=$!

    local i
    for ((i = 0; i < 50; i++)); do
        if [ -s "$port_file" ]; then
            TLS_PORT=$(cat "$port_file")
            TLS_CA_CERT="$ca_cert"
            return 0
        fi
        if ! kill -0 "$HTTPS_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    echo "[FAIL] démarrage du serveur HTTPS local"
    cat "$server_log" 2>/dev/null || true
    exit 1
}

echo "=== Smoke tests réseau (binaire normal) ==="
echo "binaire : $BIN"
echo "tmpdir  : $TMPDIR"
if [ "$STRICT_EXTERNAL" = "1" ]; then
    echo "mode    : strict (sondes externes bloquantes)"
else
    echo "mode    : normal (sondes externes informatives)"
fi
echo

start_local_https_fixture
TLS_URL="https://127.0.0.1:${TLS_PORT}/"

# 1. Timeout TCP borné vers TEST-NET-1.
run_case "socket.connect vers 192.0.2.1 reste borné" \
'local t0 = babet.time.monotonic()
local sock, err = babet.socket.connect("192.0.2.1", 65000, 0.5)
local elapsed = babet.time.monotonic() - t0
if sock then
    sock:close()
    print("UNEXPECTED_OK")
elseif elapsed <= 3.0 then
    print(string.format("BOUNDED=%.3f ERR=%s", elapsed, tostring(err)))
else
    print(string.format("TOO_SLOW=%.3f ERR=%s", elapsed, tostring(err)))
end' \
'^BOUNDED=' required 1

# 2. Le certificat local n'est pas dans le trust store : verify=true doit
# refuser la connexion. Le test est hermétique et ne dépend d'aucun site.
run_case "HTTPS certificat local inconnu rejeté par verify=true" \
"local r, e = babet.http.request{
    url = \"$TLS_URL\", timeout = 5
}
if r then print(\"UNEXPECTED_OK=\" .. r.status)
else print(\"ERR=\" .. tostring(e)) end" \
'^ERR=' required 1

# 3. La même connexion doit réussir lorsque l'autorité explicite est fournie.
run_case "HTTPS certificat local accepté avec ca_cert" \
"local r, e = babet.http.request{
    url = \"$TLS_URL\", ca_cert = \"$TLS_CA_CERT\", timeout = 5
}
if r then print(\"STATUS=\" .. r.status) else print(\"ERR=\" .. tostring(e)) end" \
'^STATUS=200$' required 1

# 4. Le bypass explicite verify=false doit également permettre la connexion.
run_case "HTTPS certificat local accepté avec verify=false" \
"local r, e = babet.http.request{
    url = \"$TLS_URL\", verify = false, timeout = 5
}
if r then print(\"STATUS=\" .. r.status) else print(\"ERR=\" .. tostring(e)) end" \
'^STATUS=200$' required 1

# 5. Sondes publiques utiles, mais dépendantes du réseau, du proxy et des
# services tiers. Elles sont relancées une fois et restent informatives par
# défaut. BABET_SMOKE_STRICT_EXTERNAL=1 les rend bloquantes.
run_case "HTTPS certificat public valide sans ca_cert" \
'local r, e = babet.http.request{
    url = "https://sha256.badssl.com/", timeout = 15,
    headers = { ["User-Agent"] = "babet-smoke-test" }
}
if r then print("STATUS=" .. r.status) else print("ERR=" .. tostring(e)) end' \
'STATUS=(2|3)[0-9][0-9]' advisory 2

run_case "HTTPS google.com (sonde externe)" \
'local r, e = babet.http.request{
    url = "https://www.google.com/", timeout = 15,
    headers = { ["User-Agent"] = "babet-smoke-test" }
}
if r then print("STATUS=" .. r.status) else print("ERR=" .. tostring(e)) end' \
'STATUS=(2|3)[0-9][0-9]' advisory 2

run_case "HTTPS AUR API (sonde yaourt)" \
'local r, e = babet.http.request{
    url = "https://aur.archlinux.org/rpc/v5/info?arg[]=google-chrome",
    timeout = 15,
    headers = { ["User-Agent"] = "babet-smoke-test" }
}
if r then print("STATUS=" .. r.status) else print("ERR=" .. tostring(e)) end' \
'STATUS=200' advisory 2

echo
echo "=========================================="
echo "Résultat : $PASS PASS / $FAIL FAIL / $WARN WARN"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
