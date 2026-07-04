-- =====================================================================
-- verif_ca.lua — diagnostic du chargement des CA système (audit v21)
--
-- Contexte : socket.connect_tls charge les CA via
-- SSL_CTX_set_default_verify_paths PUIS probe une liste de chemins
-- connus (Debian, Fedora/RHEL, openSUSE…). babet.http s'appuie sur le
-- chargement par défaut de cpp-httplib, sans ce probing. Ce script
-- détermine si les deux chemins trouvent les CA sur CETTE machine.
--
-- Usage : ./babet verif_ca.lua        (depuis n'importe où)
-- Verdict imprimé en dernière ligne : FERMÉ ou LOT 10 NÉCESSAIRE.
-- =====================================================================

local HOST = "example.com"
local URL = "https://" .. HOST .. "/"

local function show(label, ok, extra)
    print(string.format("  [%s] %s%s", ok and "OK  " or "FAIL", label,
        extra and (" — " .. tostring(extra)) or ""))
    return ok
end

print("=== Diagnostic CA https (" .. HOST .. ") ===")

-- 1. http.get, verify par défaut (activé) : LE test qui nous intéresse.
local r1, e1 = babet.http.get(URL)
local t1 = show("http.get, verify par défaut",
    r1 ~= nil and r1.status ~= nil,
    r1 and ("status " .. tostring(r1.status)) or e1)

-- 2. http.get, verify désactivé : isole le problème CA du reste
--    (réseau, DNS, TLS). Si 2 passe mais pas 1, c'est bien les CA.
local r2, e2 = babet.http.get(URL, { verify = false })
local t2 = show("http.get, verify = false",
    r2 ~= nil and r2.status ~= nil,
    r2 and ("status " .. tostring(r2.status)) or e2)

-- 3. socket.connect_tls, verify par défaut : le chemin qui probe les
--    emplacements CA connus. Point de comparaison.
local s3, e3 = babet.socket.connect_tls(HOST, 443)
local t3 = show("socket.connect_tls, verify par défaut",
    s3 ~= nil, s3 and "handshake OK" or e3)
if s3 then s3:close() end

print("")
if t1 then
    print("VERDICT : FERMÉ — cpp-httplib trouve les CA système ici.")
    print("(Point d'audit soldé. Garde ce script sous la main pour")
    print("tester Ubuntu/RPi à l'occasion : le risque identifié visait")
    print("surtout les layouts Fedora/RHEL, /etc/pki/tls.)")
elseif t2 and t3 then
    print("VERDICT : LOT 10 NÉCESSAIRE — le réseau et le probing socket")
    print("fonctionnent, mais http ne trouve pas les CA : il faut")
    print("aligner le chargement CA de http.cpp sur celui de socket.cpp")
    print("(set_ca_cert_path avec la même liste de chemins probés).")
elseif not t2 then
    print("VERDICT : INDÉTERMINÉ — même verify=false échoue : problème")
    print("réseau/DNS/proxy, pas un problème de CA. Vérifie la")
    print("connectivité puis relance.")
else
    print("VERDICT : INATTENDU — http passe en verify=false mais")
    print("connect_tls échoue aussi : envoie-moi les trois lignes")
    print("ci-dessus, on regarde ensemble.")
end
