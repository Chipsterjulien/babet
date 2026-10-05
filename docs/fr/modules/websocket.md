> [English](../../en/modules/websocket.md) | **Français**

# WEBSOCKET — client RFC 6455 pour `ws://` et `wss://`

`babet.websocket` fournit un **client** WebSocket synchrone. Il implémente
nativement la négociation d'ouverture et les frames RFC 6455. Il convient aux
protocoles qui ont besoin d'un transport bidirectionnel par messages, notamment
WebDriver BiDi.

Babet reste volontairement générique : il connaît WebSocket, TLS, les timeouts
et la fermeture, mais pas Selenium, WebDriver BiDi, JSON-RPC, les événements du
navigateur ou les identifiants de commandes applicatifs.

## Vue d'ensemble de l'API

```lua
local ws, err = babet.websocket.connect(url, opts?)

local n, err = ws:send_text(data, timeout?)
local n, err = ws:send_binary(data, timeout?)
local message, err = ws:recv(timeout?)
local ok, err = ws:ping(data?, timeout?)
local ok, err = ws:set_timeout(seconds)
local ok, err = ws:close(code?, reason?, timeout?)
```

`recv()` renvoie un message applicatif complet :

```lua
{ type = "text",   data = "..." }
{ type = "binary", data = "..." }
{ type = "close",  code = 1000, reason = "..." }
```

Les Ping reçus sont automatiquement suivis d'un Pong et ne remontent pas comme
messages applicatifs. Les Pong sont consommés en interne.

## `babet.websocket.connect(url, opts?)`

Seuls les schémas `ws://` et `wss://` sont acceptés ; la casse du schéma URI est ignorée en ASCII.

```lua
local ws = assert(babet.websocket.connect(
    "ws://127.0.0.1:9222/session/abc",
    { timeout = 5 }
))
```

Connexion chiffrée :

```lua
local ws = assert(babet.websocket.connect(
    "wss://example.net/events",
    { timeout = 5 }
))
```

Le parseur accepte les noms DNS, IPv4, IPv6 entre crochets, ports explicites,
chemins et query strings. L'userinfo et les fragments sont refusés. Les espaces
et octets de contrôle du target HTTP doivent être percent-encodés par l'appelant.

### Options

`opts` est une table brute et stricte : les métaméthodes ne sont pas appelées,
les noms d'options doivent être des chaînes et les champs inconnus sont refusés.

| Option | Défaut | Contrat |
| --- | ---: | --- |
| `timeout` | `0` | secondes finies `>= 0`; une deadline pour TCP, TLS et HTTP Upgrade |
| `verify` | `true` | vérifie la chaîne du certificat et l'identité pour `wss://` |
| `ca_cert` | aucun | fichier CA PEM ajouté aux autorités par défaut pour cette connexion |
| `ca_path` | aucun | dossier CA OpenSSL ajouté aux autorités par défaut pour cette connexion |
| `hostname` | hôte de l'URL | override d'identité TLS/SNI |
| `min_version` | `"1.2"` | `"1.2"` ou `"1.3"` |
| `max_message_bytes` | 16 Mio | plafond du message complet réassemblé |
| `max_frame_bytes` | 16 Mio | plafond des frames de données applicatives ; doit rester <= au plafond message ; les frames de contrôle gardent leur plafond RFC indépendant de 125 octets |

Les deux plafonds sont des entiers stricts dans `1..2147483648`.

Le timeout du constructeur devient également le timeout d'I/O par défaut du
WebSocket. `set_timeout()` permet ensuite de le modifier.

### Exemples des options

Borner toute la séquence TCP/TLS/Upgrade après la résolution DNS :

```lua
local ws = assert(babet.websocket.connect("ws://127.0.0.1:9222/events", {
    timeout = 2,
}))
```

Utiliser un fichier CA privé pour un service `wss://` local ou interne :

```lua
local ws = assert(babet.websocket.connect("wss://automation.internal/events", {
    ca_cert = "/etc/myapp/automation-ca.pem",
}))
```

Pour WSS, `ca_cert` et `ca_path` **ajoutent** des autorités à celles déjà
chargées depuis les chemins par défaut d'OpenSSL, ses variables d'environnement
et les emplacements de distributions reconnus. Ils ne limitent pas la
confiance au fichier ou dossier fourni. Une chaîne vide n'ajoute rien ; les
CA d'un appel ne sont pas conservées par les connexions suivantes.

Cette politique correspond à [`TLS socket`](tls.md#tls-ca) et diffère de
[`HTTP`](http.md#http-tls), dont le fichier `ca_cert` non vide remplace les
autorités par défaut. Ce n'est pas du pinning de certificat ou de clé :
plusieurs certificats d'une même CA peuvent être acceptés. Avec `verify = true`,
l'identité du serveur reste vérifiée.

Utiliser un dossier de certificats CA compatible avec OpenSSL :

```lua
local ws = assert(babet.websocket.connect("wss://automation.internal/events", {
    ca_path = "/etc/myapp/certs",
}))
```

Surcharger l'identité TLS de référence et le SNI tout en se connectant à une
autre adresse. C'est utile pour un routage local ou des tests contrôlés ; le
certificat reste vérifié pour `automation.internal` :

```lua
local ws = assert(babet.websocket.connect("wss://127.0.0.1:9443/events", {
    hostname = "automation.internal",
    ca_cert = "/etc/myapp/automation-ca.pem",
}))
```

Exiger TLS 1.3 au lieu du minimum TLS 1.2 par défaut :

```lua
local ws = assert(babet.websocket.connect("wss://example.net/events", {
    min_version = "1.3",
}))
```

Désactiver la vérification du certificat uniquement dans un environnement de
test volontairement contrôlé :

```lua
local ws = assert(babet.websocket.connect("wss://127.0.0.1:9443/events", {
    verify = false,
}))
```

`verify = false` désactive à la fois la vérification de la chaîne et celle de
l'identité de référence. Ne pas l'utiliser sur un réseau non fiable ni en
production.

Borner séparément le message complet et les frames de données applicatives :

```lua
local ws = assert(babet.websocket.connect("ws://127.0.0.1:9222/events", {
    max_message_bytes = 8 * 1024 * 1024,
    max_frame_bytes = 1 * 1024 * 1024,
}))
```

Un `max_frame_bytes` volontairement faible ne réduit pas le plafond RFC des
frames de contrôle : Ping, Pong et Close peuvent toujours transporter jusqu'à
125 octets.

Configuration sécurisée combinée :

```lua
local ws = assert(babet.websocket.connect("wss://127.0.0.1:9443/bidi", {
    timeout = 5,
    ca_cert = "/etc/myapp/automation-ca.pem",
    hostname = "automation.internal",
    min_version = "1.3",
    max_message_bytes = 8 * 1024 * 1024,
    max_frame_bytes = 512 * 1024,
}))
```

## Négociation d'ouverture

Le client envoie une requête HTTP/1.1 Upgrade avec la version WebSocket 13 et
un `Sec-WebSocket-Key` aléatoire. La réponse n'est acceptée que si :

- le statut est `101 Switching Protocols` ;
- `Upgrade` vaut `websocket` sans tenir compte de la casse ;
- `Connection` contient le token `Upgrade` ;
- `Sec-WebSocket-Accept` correspond exactement au SHA-1 + Base64 du GUID RFC ;
- le serveur n'a négocié aucune extension non demandée ;
- le serveur n'a sélectionné aucun sous-protocole non demandé.

Le bloc d'en-têtes de réponse est plafonné à 64 Kio.

La 2.22.0 n'expose pas encore les en-têtes personnalisés, cookies,
sous-protocoles, proxies HTTP ni extensions WebSocket comme
`permessage-deflate`.

## Envoyer du texte

```lua
local n, err = ws:send_text('{"id":1,"method":"session.status","params":{}}')
assert(n, err)
```

Le texte doit être un UTF-8 valide. La valeur renvoyée est le nombre d'octets
applicatifs et non la taille réellement envoyée sur le réseau.

Les gros messages sont automatiquement fragmentés en frames de continuation.
Chaque frame cliente est masquée avec une nouvelle clé aléatoire 32 bits issue
du générateur cryptographique OpenSSL, y compris en `wss://`.

Une fois l'émission d'une frame tentée, un abandon (timeout, interruption ou
erreur de transport) ferme la connexion. Cette règle couvre aussi les messages
fragmentés, Ping et les réponses Pong automatiques pendant `recv`. Le premier
appel garde son erreur ; les opérations suivantes renvoient `closed` et
`close()` reste idempotent. La fermeture précède tout callback de signal.

Les erreurs de validation avant émission (UTF-8, taille du message, arguments)
laissent la connexion utilisable. Un timeout de réception qui n'abandonne
aucune écriture conserve l'état de réception et reste reprenable.

## Envoyer du binaire

```lua
local n = assert(ws:send_binary("A\0B\255"))
assert(n == 4)
```

Les messages binaires sont des chaînes Lua arbitraires : NUL et UTF-8 invalide
sont autorisés.

## Recevoir des messages

```lua
local message, err = ws:recv(2)
assert(message, err)

if message.type == "text" then
    print(message.data)
elseif message.type == "binary" then
    -- chaîne binaire
elseif message.type == "close" then
    print(message.code, message.reason)
end
```

`recv()` réassemble les messages texte/binaires fragmentés et accepte des
frames de contrôle entre deux fragments. Le texte n'est validé en UTF-8
qu'après réassemblage complet.

Les frames du serveur doivent être non masquées. Bits RSV réservés, opcodes
réservés, longueurs non minimales, contrôle fragmenté et Close mal formé sont
des erreurs de protocole.

La longueur annoncée des frames de données applicatives est comparée à
`max_frame_bytes` **avant** l'allocation ou la lecture du payload. Les frames
de contrôle gardent leur plafond RFC fixe de 125 octets : une limite de données
volontairement basse ne peut donc pas empêcher Ping/Pong ou Close. Le message
réassemblé est plafonné séparément par `max_message_bytes`.

## Ping et Pong

```lua
assert(ws:ping("health"))
```

Le payload d'un Ping est limité à 125 octets. Un Ping reçu pendant `recv()` est
immédiatement renvoyé comme Pong avant la poursuite de l'attente du prochain
message applicatif.

## Fermeture

```lua
assert(ws:close(1000, "done", 2))
```

`close()` valide le code et la raison UTF-8, envoie une frame Close masquée,
puis attend le Close distant avec la même deadline absolue. La raison est
limitée à 123 octets pour que code + raison tiennent dans les 125 octets d'une
frame de contrôle.

Si le pair ferme en premier, `recv()` valide sa frame, lui répond si nécessaire,
ferme le transport et renvoie un message `type = "close"`.

Le GC reste volontairement best-effort : un userdata oublié ferme TCP/TLS mais
ne lance pas une négociation WebSocket potentiellement bloquante.

## Erreurs de protocole

Babet échoue de manière conservative :

- erreur de framing/protocole -> Close `1002` si possible ;
- UTF-8 invalide -> Close `1007` ;
- plafond frame/message dépassé -> Close `1009`.

Les pannes de transport et expirations restent `(nil, err)`. Un signal POSIX
géré interrompt l'attente, déclenche le callback différé puis renvoie
`(nil, "interrupted")`.

Sur `wss://`, les écritures TLS internes au handshake, à l’envoi et à la
lecture sont protégées contre `SIGPIPE`. Une erreur de transport ne tue pas
le programme et ne remplace pas le gestionnaire de signal de l’application.

## Exemple WebDriver BiDi

WebDriver BiDi transporte ses messages sur WebSocket. Une session WebDriver
renvoie un `webSocketUrl`; Babet a uniquement besoin de cette URL :

```lua
local ws = assert(babet.websocket.connect(webSocketUrl, {
    timeout = 10,
    max_message_bytes = 8 * 1024 * 1024,
}))

local command = assert(babet.json.encode({
    id = 1,
    method = "session.status",
    params = {},
}))
assert(ws:send_text(command))

local message = assert(ws:recv())
assert(message.type == "text")
local decoded = assert(babet.json.decode(message.data))
print(decoded.id)
```

Le binding Selenium doit conserver en Lua les identifiants de commandes, les
réponses en attente, abonnements et callbacks d'événements. `babet.websocket`
reste uniquement la couche transport.

## Concurrence et boucles graphiques

L'API est synchrone. Un `recv()` sans timeout dans le thread principal d'une
boucle graphique bloque cette boucle. Utilise un worker Babet, une stratégie de
thread dédiée dans l'hôte ou des attentes courtes et bornées selon le cas.

Chaque worker possède son propre état Lua et peut ouvrir sa propre connexion
WebSocket. Un userdata WebSocket n'est pas sérialisable entre workers.

## Sécurité et limites

- `wss://` vérifie les certificats par défaut et impose TLS 1.2 minimum.
- chaque frame cliente utilise une nouvelle clé de masquage cryptographiquement
  forte ;
- aucune extension de compression n'est négociée, ce qui évite l'amplification
  de décompression et l'état supplémentaire associé ;
- les limites frame/message empêchent un pair de provoquer des allocations
  non bornées via une longueur annoncée ;
- une frame serveur non conforme est refusée plutôt que normalisée ;
- la résolution DNS reste synchrone et n'est pas elle-même bornée par la
  deadline socket ; utilise une adresse numérique si ce point est critique.
