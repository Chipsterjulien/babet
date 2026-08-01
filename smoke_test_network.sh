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
FIXTURE_PID=""

cleanup() {
    if [ -n "$FIXTURE_PID" ] && kill -0 "$FIXTURE_PID" 2>/dev/null; then
        kill "$FIXTURE_PID" 2>/dev/null || true
        wait "$FIXTURE_PID" 2>/dev/null || true
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

start_local_http_fixtures() {
    require_tool openssl
    require_tool python3

    local ca_key="$TMPDIR/ca.key"
    local ca_cert="$TMPDIR/ca.crt"
    local server_key="$TMPDIR/server.key"
    local server_csr="$TMPDIR/server.csr"
    local server_cert="$TMPDIR/server.crt"
    local server_ext="$TMPDIR/server.ext"
    local port_file="$TMPDIR/https.port"
    local http_port_file="$TMPDIR/http.port"
    local server_log="$TMPDIR/local-network-server.log"

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
import threading

cert_file, key_file, port_file, http_port_file = sys.argv[1:5]

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/chunked":
            body = b"chunked-" * 16384
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            for start in range(0, len(body), 4096):
                chunk = body[start:start + 4096]
                self.wfile.write(("%X\r\n" % len(chunk)).encode("ascii"))
                self.wfile.write(chunk)
                self.wfile.write(b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        elif self.path == "/close-delimited":
            body = b"close---" * 16384
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        else:
            body = b"babet local TLS smoke test\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, _format, *_args):
        pass

http_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
http_server.daemon_threads = True

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

temporary = http_port_file + ".tmp"
with open(temporary, "w", encoding="ascii") as handle:
    handle.write(str(http_server.server_address[1]))
    handle.flush()
    os.fsync(handle.fileno())
os.replace(temporary, http_port_file)

threading.Thread(target=http_server.serve_forever, daemon=True).start()
server.serve_forever()
PY

    python3 "$TMPDIR/https_server.py" \
        "$server_cert" "$server_key" "$port_file" "$http_port_file" \
        >"$server_log" 2>&1 &
    FIXTURE_PID=$!

    local i
    for ((i = 0; i < 50; i++)); do
        if [ -s "$port_file" ] && [ -s "$http_port_file" ]; then
            TLS_PORT=$(cat "$port_file")
            HTTP_PORT=$(cat "$http_port_file")
            TLS_CA_CERT="$ca_cert"
            return 0
        fi
        if ! kill -0 "$FIXTURE_PID" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done

    echo "[FAIL] démarrage des serveurs HTTP/HTTPS locaux"
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

start_local_http_fixtures
TLS_URL="https://127.0.0.1:${TLS_PORT}/"
HTTP_URL="http://127.0.0.1:${HTTP_PORT}/"

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

# Le certificat a un CN=localhost mais aussi un SAN iPAddress=127.0.0.1.
# L'appel passe volontairement le littéral IP sans opts.hostname : il valide
# SSL_set1_host() à travers le libssl statique réellement lié à Babet, et non
# le comportement de l'OpenSSL utilisé par la ligne de commande.
run_case "TLS vérifie un SAN IP sans hostname explicite" \
"local s, e = babet.socket.connect_tls(\"127.0.0.1\", $TLS_PORT, {
    verify = true, ca_cert = \"$TLS_CA_CERT\", timeout = 5
})
if s then s:close(); print(\"IP_SAN_OK\")
else print(\"ERR=\" .. tostring(e)) end" \
'^IP_SAN_OK$' required 1

# 4. Le téléchargement vers fichier emprunte le même chemin TLS, mais avec un
# receiver de corps différent. Vérifie le CA, le contenu binaire, le nombre
# d'octets et le commit atomique sur le binaire normal final.
run_case "HTTPS download local accepté avec ca_cert" \
"local path = \"$TMPDIR/tls-download.bin\"
local r, e = babet.http.download(\"$TLS_URL\", path, {
    ca_cert = \"$TLS_CA_CERT\", timeout = 5, max_file_size = 1024
})
if not r then
    print(\"ERR=\" .. tostring(e))
elseif not r.saved then
    print(\"NOT_SAVED=\" .. tostring(r.status))
else
    local f = io.open(path, \"rb\")
    local body = f and f:read(\"*a\") or nil
    if f then f:close() end
    if body == \"babet local TLS smoke test\\n\" then
        print(\"DOWNLOADED=\" .. r.bytes .. \" STATUS=\" .. r.status)
    else
        print(\"BAD_BODY=\" .. tostring(body))
    end
end" \
'^DOWNLOADED=27 STATUS=200$' required 1

# 5. Garde indépendante contre la régression AUR de Babet 2.9.0 : une réponse
# chunked réelle en HTTPS doit fonctionner avec le receiver mémoire comme avec
# le receiver fichier. Ce smoke local aurait échoué avec
# set_payload_max_length(0), même si le grand corpus principal était modifié.
run_case "HTTPS local accepte une réponse chunked" \
"local opts = {
    ca_cert = \"$TLS_CA_CERT\", timeout = 5, max_body_size = 131072
}
local chunked, chunked_err = babet.http.get(\"${TLS_URL}chunked\", opts)
local chunk_path = \"$TMPDIR/tls-chunked.bin\"
local dchunk, dchunk_err = babet.http.download(
    \"${TLS_URL}chunked\", chunk_path, {
        ca_cert = \"$TLS_CA_CERT\", timeout = 5, max_file_size = 131072
    })
if not chunked or not dchunk then
    print(\"ERR=\" .. table.concat({
        tostring(chunked_err), tostring(dchunk_err)
    }, \" | \"))
else
    local function read_all(path)
        local file = io.open(path, \"rb\")
        if not file then return nil end
        local body = file:read(\"*a\")
        file:close()
        return body
    end
    local expected_chunked = string.rep(\"chunked-\", 16384)
    local file_chunked = read_all(chunk_path)
    if chunked.body == expected_chunked
        and file_chunked == expected_chunked
        and dchunk.bytes == #expected_chunked then
        print(\"CHUNKED_OK=131072\")
    else
        print(\"BAD_CHUNKED_CONTENT\")
    end
end" \
'^CHUNKED_OK=131072$' required 1

# 6. La même valeur erronée affectait aussi le chemin sans Content-Length.
# Ce framing est testé sur HTTP local : une fermeture TCP est alors le
# délimiteur normal du corps, sans introduire les exigences de fermeture TLS
# (`close_notify`) propres à OpenSSL et indépendantes du protocole HTTP.
run_case "HTTP local accepte une réponse terminée par fermeture" \
"local opts = { timeout = 5, max_body_size = 131072 }
local closed, closed_err = babet.http.get(
    \"${HTTP_URL}close-delimited\", opts)
local close_path = \"$TMPDIR/http-close.bin\"
local dclose, dclose_err = babet.http.download(
    \"${HTTP_URL}close-delimited\", close_path, {
        timeout = 5, max_file_size = 131072
    })
if not closed or not dclose then
    print(\"ERR=\" .. table.concat({
        tostring(closed_err), tostring(dclose_err)
    }, \" | \"))
else
    local file = io.open(close_path, \"rb\")
    local file_closed = file and file:read(\"*a\") or nil
    if file then file:close() end
    local expected_closed = string.rep(\"close---\", 16384)
    if closed.body == expected_closed
        and file_closed == expected_closed
        and dclose.bytes == #expected_closed then
        print(\"CLOSE_OK=131072\")
    else
        print(\"BAD_CLOSE_CONTENT\")
    end
end" \
'^CLOSE_OK=131072$' required 1

# 7. Le bypass explicite verify=false doit également permettre la connexion.
run_case "HTTPS certificat local accepté avec verify=false" \
"local r, e = babet.http.request{
    url = \"$TLS_URL\", verify = false, timeout = 5
}
if r then print(\"STATUS=\" .. r.status) else print(\"ERR=\" .. tostring(e)) end" \
'^STATUS=200$' required 1

# 8. Sondes publiques utiles, mais dépendantes du réseau, du proxy et des
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
