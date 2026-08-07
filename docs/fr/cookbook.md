> [English](../en/cookbook.md) | **Français**

# Cookbook

Recettes concrètes pour des tâches de scripting courantes. Chaque
recette est courte et autonome ; copie, adapte, déploie.

## Surveiller un dossier et envoyer les nouveaux fichiers par email

Un dossier de dépôt qui mailise chaque fichier dès qu'il arrive.
Utilise `babet.inotify` pour le réveil instantané (pas de
polling), et écoute `close_write` + `moved_to` pour garantir que
le fichier est complet.

```lua
local w = assert(babet.inotify.new())
assert(w:add("/srv/incoming", { "close_write", "moved_to" }))

babet.signal.handle("TERM", function()
    w:close()
    os.exit(0)
end)

while true do
    local events, err = w:read()
    if not events then
        if err == "interrupted" then break end
        io.stderr:write("inotify: ", err, "\n"); break
    end
    for _, ev in ipairs(events) do
        if ev.events.overflow then
            -- queue saturée : rescanne le dossier
            -- (des événements ont été perdus)
        else
            local path = "/srv/incoming/" .. ev.name
            send_email(path)
            os.remove(path)
        end
    end
end
```

## S'assurer qu'un user système existe, puis basculer dessus

Check typique à l'install avant de lancer un daemon sous un
utilisateur non-root.

```lua
local function ensure_user(name)
    if babet.user.exists(name) then return true end
    local ok, err = babet.exec("useradd", {
        "--system",
        "--home-dir", "/var/lib/" .. name,
        "--create-home",
        "--shell", "/usr/sbin/nologin",
        name,
    })
    if not ok then
        return nil, "useradd a échoué : " .. tostring(err)
    end
    return true
end

assert(ensure_user("myapp"))
local u = assert(babet.user.get("myapp"))
babet.chdir(u.home)
```

## Récupérer beaucoup d'URLs en parallèle

`babet.workers` fait tourner du Lua sur plusieurs cœurs. Le temps
total est proche du fetch le plus lent, pas de la somme.

```lua
local urls = { "https://a.example/", "https://b.example/",
               "https://c.example/", "https://d.example/" }

local jobs = {}
for i, url in ipairs(urls) do
    jobs[i] = babet.workers.spawn([[
        local url = worker.args.url
        local r, err = babet.http.get(url, { timeout = 10 })
        if not r then return { error = err } end
        return { status = r.status, length = #r.body }
    ]], { url = url })
end

for i, job in ipairs(jobs) do
    local ok, result = job:join()
    print(i, ok, result and result.status or result.error)
end
```

## Utiliser WebSocket comme transport WebDriver BiDi

Une fois que la session WebDriver a renvoyé son `webSocketUrl`, Babet peut
transporter les messages JSON BiDi sans rien connaître de Selenium. Ce petit
dispatcher séquentiel résout une commande à la fois et sépare les événements
spontanés :

```lua
local ws = assert(babet.websocket.connect(webSocketUrl, {
    timeout = 5,
    max_message_bytes = 8 * 1024 * 1024,
}))

local next_id = 0
local function bidi_command(method, params)
    next_id = next_id + 1
    local id = next_id
    assert(ws:send_text(assert(babet.json.encode({
        id = id,
        method = method,
        params = params or {},
    }))))

    while true do
        local message = assert(ws:recv())
        assert(message.type == "text", "BiDi attend des messages JSON texte")
        local packet = assert(babet.json.decode(message.data))
        if packet.id == id then
            return packet
        end
        if packet.method then
            print("Événement BiDi :", packet.method)
        end
    end
end

local status = bidi_command("session.status", {})
print(assert(babet.json.encode(status)))
assert(ws:close())
```

Un binding Selenium complet remplacera cette boucle séquentielle par sa propre
table de commandes en attente et son dispatcher d'événements. Le transport
WebSocket reste générique.

## Arrêt propre d'un script long-running

Attraper `SIGTERM` / `SIGINT` pour que le script puisse fermer
ses ressources proprement. Fonctionne avec `systemctl stop` et
Ctrl-C.

```lua
local log = require("logging")
log.set_level("info")

local running = true
babet.signal.handle("TERM", function()
    log.info("SIGTERM, arrêt en cours")
    running = false
end)
babet.signal.handle("INT", function()
    log.info("Ctrl-C, arrêt en cours")
    running = false
end)

while running do
    -- boucle principale ; les appels bloquants renvoient
    -- (nil, "interrupted") quand un signal géré arrive, donc la
    -- boucle sort rapidement.
    local line, err = sock:recv_line()
    if not line then
        if err == "interrupted" then break end
        log.error("recv : ", err); break
    end
    process(line)
end

sock:close()
log.info("arrêt propre")
```

## Lire une config TOML, valider, persister en SQLite

```lua
-- Charger le TOML
local f = assert(io.open("config.toml", "r"))
local body = f:read("a"); f:close()
local cfg, perr = babet.toml.decode(body)
if not cfg then error("config.toml : " .. perr) end

-- Valider (checks manuels simples ; pour un vrai schéma, bâtis-le en Lua)
assert(type(cfg.server) == "table", "section [server] absente")
assert(type(cfg.server.host) == "string", "server.host absent")
assert(math.type(cfg.server.port) == "integer", "server.port doit être un entier")

-- Ouvrir la db, persister
local db = assert(babet.sqlite.open("state.db", { wal = true }))
db:exec([[CREATE TABLE IF NOT EXISTS config (k TEXT PRIMARY KEY, v TEXT)]])
db:exec("INSERT OR REPLACE INTO config VALUES (?, ?)",
        { "host", cfg.server.host })
db:exec("INSERT OR REPLACE INTO config VALUES (?, ?)",
        { "port", tostring(cfg.server.port) })
db:close()
```

## Cache avec TTL lisible, échéances en timestamps ISO

Parser un TTL depuis une config (`"15m"`, `"2h30m"`, `"1d"`),
calculer une échéance, et la logger dans un format UTC uniforme
sur lequel `grep` à travers les fichiers de log marche vraiment.

```lua
-- Config depuis TOML, CLI, env, peu importe.
local raw_ttl = "15m"

local ttl, err = babet.time.parse_duration(raw_ttl)
if not ttl then error("TTL invalide '" .. raw_ttl .. "' : " .. err) end

local deadline = babet.now() + ttl
print(string.format("[%s] entrée cache créée, expire à %s (TTL %s)",
    babet.time.iso(),
    babet.time.iso(deadline),
    babet.time.format_duration(ttl)))

-- ...plus tard, ailleurs dans le script :
if babet.now() >= deadline then
    print("[" .. babet.time.iso() .. "] cache miss : entrée expirée")
end
```

Propriétés utiles de ce pattern :

- `babet.time.iso()` est toujours UTC, toujours 20 caractères,
  toujours la même forme. `grep` et `sort` marchent directement
  sur les timestamps.
- `parse_duration("15m")` renvoie un entier, donc `now() + ttl`
  est exact (pas de drift float sur les longues durées).
- `format_duration(ttl)` est aller-retour : `parse_duration(
  format_duration(n)) == n` pour tout `n >= 0`. Sûr à utiliser
  comme représentation canonique dans les logs ou les bases.

## Pretty-print d'une valeur Lua

Le module `inspect` (embarqué) donne une sortie lisible pour les
tables imbriquées.

```lua
local inspect = require("inspect")
print(inspect({ a = 1, b = { c = 2, d = { 3, 4, 5 } } }))
-- { a = 1, b = { c = 2, d = { 3, 4, 5 } } }
```

## Hello there

Le script Babet minimum :

```lua
babet.helloThere()
```
