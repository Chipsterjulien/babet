> [English](../../en/modules/socket.md) | **Français**

# `babet.socket` — sockets TCP client et serveur

Sockets TCP bas niveau avec timeouts, conscience des signaux, et
un petit set de helpers haut niveau (`recv_line`, `recv_all`).
Base pour tout protocole personnalisé — le bot IRC, un daemon
JSON-over-TCP, etc. Voir [`tls`](tls.md) pour la variante
chiffrée.

## Pourquoi

Pour les besoins HTTP courants il y a [`http`](http.md). Mais
beaucoup de scripts doivent parler un protocole line-oriented
personnalisé (IRC, Redis, daemons de style telnet), où un vrai
socket TCP avec timeouts est l'outil approprié. Lua n'a pas de
TCP intégré, et `LuaSocket` est une dépendance séparée ;
`babet.socket` rend les patterns courants accessibles en une
ligne.

## API

### Constructeurs

| Fonction | Renvoie |
| --- | --- |
| `babet.socket.connect(host, port, timeout?)` | `socket` \| `(nil, err)` |
| `babet.socket.listen(host, port, backlog?)` | `server_socket` \| `(nil, err)` |

- `timeout` : secondes (float), optionnel — défaut infini (bloquant).
  C'est le budget des tentatives TCP **après résolution DNS** :
  deadline **globale**, toutes adresses A/AAAA confondues. Si le DNS
  renvoie plusieurs adresses (dual-stack typique), les tentatives
  successives se partagent le même budget — jamais `timeout` par
  adresse. Au dépassement : `(nil, "timeout")`. Limite connue : la
  résolution DNS elle-même (`getaddrinfo`, synchrone) n'est pas
  couverte par cette deadline ni interruptible par signal — un
  resolver lent peut ajouter son propre délai en amont.
- `backlog` : entier > 0, optionnel — défaut 16. Taille de la file
  d'attente `listen(2)`.

> **TLS** : `babet.socket.connect_tls(host, port, opts?)` et
> `s:starttls(opts?)` existent aussi — ils ont leur page dédiée,
> voir [`tls`](tls.md).

Un `connect` — avec ou sans timeout — interrompu par un signal géré
via [`signal`](signal.md) renvoie `(nil, "interrupted")` après avoir
dispatché le callback, comme `recv`/`accept`.

### Méthodes (socket client)

| Méthode | Renvoie |
| --- | --- |
| `s:send(data)` | `integer` octets envoyés \| `(nil, err)` — envoie **tout** (boucle interne sur les écritures partielles) |
| `s:recv(n, timeout?)` | `string` \| `(nil, "timeout")` \| `(nil, "interrupted")` \| `(nil, err)` |
| `s:recv_line(timeout?)` | `string` (sans `\n`) \| `(nil, …)` |
| `s:recv_all(timeout?)` | `string` (lit jusqu'à EOF) \| `(nil, …)` |
| `s:set_timeout(seconds)` | positionne le timeout par défaut (`0` = infini). NaN/Inf/négatif → `(nil, err)` ; plancher interne 1 ms pour les valeurs positives minuscules |
| `s:close()` | idempotent |
| `s:peer()` | table `{host, port}` \| `(nil, err)` — endpoint distant |
| `s:sockname()` | table `{host, port}` \| `(nil, err)` — endpoint local |

`recv_line` lit jusqu'à trouver `\n` (LF). CR est strippé s'il est
présent (`\r\n` → renvoyé sans le `\r` final). A un cap dur de
8 MiB pour empêcher un DoS via une ligne unique sans fin.

### Méthodes (socket serveur)

| Méthode | Renvoie |
| --- | --- |
| `srv:accept(timeout?)` | `socket` \| `(nil, …)` |
| `srv:close()` | idempotent |

## Exemples rapides

### Client TCP echo

```lua
-- timeout de 5 s pour le connect COMPLET (toutes adresses DNS
-- confondues) ; omets-le pour un connect bloquant.
local s = assert(babet.socket.connect("localhost", 4000, 5))

s:send("hello\n")
local reply, err = s:recv_line()
print("reçu :", reply)
s:close()
```

### Serveur line-protocol simple avec arrêt propre

```lua
local sig = babet.signal
local srv = assert(babet.socket.listen("0.0.0.0", 4000))
local running = true
sig.handle("TERM", function() running = false end)
sig.handle("INT", function() running = false end)

while running do
    local client, err = srv:accept(1.0)        -- timeout 1 s
    if not client then
        if err == "timeout" or err == "interrupted" then
            -- boucle et re-vérifie `running`
        else
            io.stderr:write("accept : ", err, "\n"); break
        end
    else
        repeat
            local line = client:recv_line(30)
            if line then client:send("tu as dit : " .. line .. "\n") end
        until not line
        client:close()
    end
end
srv:close()
```

## Contrat d'erreur

- **Erreurs de connect** (DNS, refusé, réseau) → `(nil, "socket: ...")`.
  Dépassement du timeout → `(nil, "timeout")` (nu). Signal géré
  pendant le connect → `(nil, "interrupted")`.
- **Erreurs de bind** (port utilisé, permission) → `(nil, "socket: ...")`.
- **`recv`** :
  - `string` (n'importe quelle longueur jusqu'à `n` demandé).
  - String vide `""` quand le peer ferme proprement. Pas une
    erreur.
  - `(nil, "timeout")` si pas de données dans le timeout.
  - `(nil, "interrupted")` si un signal géré est arrivé.
  - `(nil, "line too long")` pour `recv_line` au-delà du cap 8 MiB.
  - `(nil, err)` sur autres erreurs.
- **`send`** : peut renvoyer moins d'octets que demandé.
  Encapsule dans une boucle si tu dois envoyer une quantité
  fixe (ou utilise des sémantiques `recv_all`-symétriques dans
  ton protocole).
- **Méthodes après `close`** → `(nil, "socket: closed")`.
- **Timeouts NaN/Inf**, timeouts négatifs → lève via
  `luaL_error`.

## Décisions de design

- **Single-threaded, I/O bloquant**. Pas de `select`/`poll`
  exposé — utilise [`workers`](workers.md) pour les connexions
  concurrentes, ou des timeouts courts dans une boucle de polling
  pour les cas simples.
- **`recv_line` a un cap 8 MiB**. Protège contre un peer qui
  envoie des mégaoctets sans jamais envoyer `\n`. Configurable
  plus tard si un cas d'usage demande plus.
- **Blocage conscient des signaux**. Tous les `recv*`, `accept` —
  et `connect`, y compris sans timeout — renvoient `"interrupted"`
  sur signal géré, pour que le script puisse sortir proprement.
- **Timeout de `connect` global, pas par adresse** (audit v21). La
  deadline est créée une fois pour l'appel entier ; un host
  dual-stack dont la première adresse traîne ne multiplie pas le
  délai. Contrepartie assumée : une adresse de secours n'a que le
  budget restant.
- **`recv` renvoie `""` sur fermeture propre, pas `nil`**. Permet
  aux scripts de distinguer "le distant est parti" (`""`) de "pas
  encore de données" (`"timeout"`) sans inventer encore une autre
  sentinelle.

## Hors v1

- Sockets UDP. Facile à ajouter additivement
  (`babet.socket.udp.*`).
- Sockets domaine Unix. Même raisonnement.
- Multiplexage natif (`select`/`poll`/`epoll` exposé à Lua).
  Utilise plutôt les workers ou le polling à timeout court.
