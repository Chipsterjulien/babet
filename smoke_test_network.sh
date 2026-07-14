#!/usr/bin/env bash
# smoke_test_network.sh — Tests d'intégration réseau pour Babet.
#
# Ce script complète le harnais hermétique/offline avec quelques contrôles
# réels. Les invariants appartenant à Babet sont bloquants. Les sondes vers
# Google et l'AUR restent visibles mais sont non bloquantes par défaut, car un
# service tiers, un proxy, un filtrage DNS ou une panne transitoire ne doit pas
# suffire à invalider une release.
#
# Pour rendre aussi les sondes tierces bloquantes :
#   BABET_SMOKE_STRICT_EXTERNAL=1 ./smoke_test_network.sh ./test/babet

set -u

BIN="${1:-./test/babet}"
if [ ! -x "$BIN" ]; then
    echo "Usage: $0 [chemin/vers/babet]"
    echo "Binaire introuvable ou non exécutable : $BIN"
    exit 1
fi

TMPDIR=$(mktemp -d -t babet-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

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

    echo "$script" > "$TMPDIR/main.lua"

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        set +e
        output=$(env -u SSL_CERT_FILE -u SSL_CERT_DIR \
                 "$BIN" "$TMPDIR" 2>&1)
        rc=$?
        set -e

        if [ ${rc} -eq 0 ] && echo "$output" | grep -qE "$expected_pattern"; then
            echo "[PASS] $name"
            PASS=$((PASS + 1))
            return 0
        fi

        if [ ${attempt} -lt ${attempts} ]; then
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

echo "=== Smoke tests réseau (binaire normal) ==="
echo "binaire : $BIN"
echo "tmpdir  : $TMPDIR"
if [ "$STRICT_EXTERNAL" = "1" ]; then
    echo "mode    : strict (Google/AUR bloquants)"
else
    echo "mode    : normal (Google/AUR informatifs)"
fi
echo

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

# 2. Certificat public valide : vérifie le trust store système sans ca_cert.
# Même infrastructure que les cas BadSSL ci-dessous, afin de réduire le
# nombre de dépendances externes tout en testant réellement verify=true.
run_case "HTTPS certificat public valide accepté sans ca_cert" \
'local r, e = babet.http.request{
    url = "https://sha256.badssl.com/",
    timeout = 15,
    headers = { ["User-Agent"] = "babet-smoke-test" }
}
if r then print("STATUS=" .. r.status) else print("ERR=" .. tostring(e)) end' \
'STATUS=(2|3)[0-9][0-9]' required 2

# 3. Certificat expiré : verify=true doit le rejeter.
run_case "HTTPS expired cert rejeté par verify=true" \
'local r, e = babet.http.request{
    url = "https://expired.badssl.com/", timeout = 15
}
if r then print("UNEXPECTED_OK=" .. r.status)
else print("ERR=" .. tostring(e)) end' \
'^ERR=' required 2

# 4. Même certificat, verify=false : le bypass explicite doit fonctionner.
run_case "HTTPS expired cert accepté avec verify=false" \
'local r, e = babet.http.request{
    url = "https://expired.badssl.com/", verify = false, timeout = 15
}
if r then print("STATUS=" .. r.status) else print("ERR=" .. tostring(e)) end' \
'STATUS=(2|3)[0-9][0-9]' required 2

# 5. Sondes réelles et utiles, mais dépendantes de services tiers. Elles sont
# relancées une fois et produisent un avertissement en cas d'indisponibilité.
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
