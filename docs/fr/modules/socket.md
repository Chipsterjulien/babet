> [English](../../en/modules/socket.md) | **Français**

# SOCKET — client et serveur TCP, flux binaires, lignes et timeouts

`babet.socket` fournit des sockets TCP synchrones pour écrire des clients et
serveurs de protocoles personnalisés : IRC, SMTP en clair avant STARTTLS,
protocoles ligne par ligne, flux binaires ou petits services internes.

Le module couvre :

- la connexion TCP à un hostname ou une adresse IP ;
- l'écoute sur une interface précise ou sur toutes les interfaces ;
- l'acceptation de clients ;
- l'envoi intégral d'une chaîne binaire ;
- la lecture par blocs, par lignes ou jusqu'à la fermeture distante ;
- des timeouts globaux par socket ou par appel ;
- l'obtention des adresses locale et distante ;
- la fermeture explicite et le nettoyage automatique par le GC ;
- l'interaction avec les signaux gérés par Babet.

Il ne fournit pas UDP, les sockets Unix, l'I/O asynchrone, le multiplexage de
milliers de connexions, ni un protocole applicatif prêt à l'emploi. Pour HTTP,
utilise [`babet.http`](http.md). Pour TLS direct ou STARTTLS, consulte
[`TLS`](tls.md).

## Table des matières du module

- [Conventions essentielles](#socket-conventions)
- [Vue d'ensemble de l'API](#socket-api-summary)
- [Créer une connexion cliente](#socket-connect)
- [Créer un serveur](#socket-listen)
- [Accepter un client](#socket-accept)
- [Configurer le timeout par défaut](#socket-set-timeout)
- [Envoyer des données](#socket-send)
- [Lire au plus N octets](#socket-recv)
- [Lire une ligne](#socket-recv-line)
- [Lire jusqu'à EOF](#socket-recv-all)
- [Mélanger les méthodes de lecture](#socket-pending)
- [Adresses locale et distante](#socket-addresses)
- [Fermer et laisser le GC nettoyer](#socket-close)
- [Signaux et interruptions](#socket-signals)
- [Exemples complets](#socket-examples)
- [Contrat d'erreur](#socket-errors)
- [Sécurité, performances et limites](#socket-design)

<a id="socket-conventions"></a>
## Conventions essentielles

### TCP synchrone et bloquant

Chaque appel s'exécute dans le thread courant. Sans timeout, `connect`,
`accept`, `send` et les lectures peuvent attendre indéfiniment.

Pour une application qui gère plusieurs connexions indépendantes, utilise des
[`workers`](workers.md) ou conçois une boucle autour de plusieurs processus.
Babet n'expose pas `select`, `poll` ou `epoll` directement à Lua.

### Chaînes binaires

Les données envoyées et reçues sont des chaînes Lua binary-safe. Elles peuvent
contenir des octets NUL :

```lua
local sent = assert(sock:send("AB\0CD"))
local data = assert(sock:recv(5, 2))
assert(#data == 5 and data:byte(3) == 0)
```

Les hostnames utilisent en revanche une chaîne C et ne peuvent pas contenir de
NUL.

### Timeouts

Les timeouts sont exprimés en **secondes** et peuvent être fractionnaires.

- `nil` ou argument omis : utilise le timeout par défaut du socket ;
- `0` : attente infinie ;
- nombre positif : budget global pour l'appel ;
- valeur positive inférieure à 1 ms : arrondie à 1 ms ;
- nombre négatif, NaN, infini ou trop grand : erreur.

Une deadline est créée une seule fois par appel. Elle n'est pas renouvelée à
chaque octet ou à chaque tentative interne.

### Valeurs de retour

Une création ou une lecture réussie renvoie la valeur utile et `nil` comme
seconde valeur implicite :

```lua
local sock, err = babet.socket.connect("127.0.0.1", 9000, 5)
local data, err = sock:recv(4096, 2)
```

Les actions `set_timeout`, `starttls` et `close` renvoient exactement :

```lua
true, nil
```

Une erreur d'usage positionnelle lève une erreur Lua. Une erreur de valeur,
de transport ou de timeout renvoie généralement `(nil, err)`.

<a id="socket-api-summary"></a>
## Vue d'ensemble de l'API

### Constructeurs

```lua
local sock, err = babet.socket.connect(host, port, timeout?)
local server, err = babet.socket.listen(host, port, backlog?)
```

| Argument | Type | Défaut | Rôle |
| --- | --- | --- | --- |
| `host` de `connect` | string stricte non vide | obligatoire | hostname ou adresse IP |
| `host` de `listen` | string stricte | obligatoire | interface ; `""` signifie toutes les interfaces |
| `port` | entier Lua `0..65535` | obligatoire | port TCP ; `0` est utile avec `listen` pour laisser le noyau choisir |
| `timeout` | nombre fini `>= 0` | `0` | timeout de connexion en secondes |
| `backlog` | entier Lua `1..INT_MAX` | `16` | taille demandée de la file d'attente |

Les chaînes numériques comme `"443"` et les floats comme `443.0` sont refusés
pour `port` et `backlog`, même si leur valeur mathématique est entière.

### Méthodes communes

```lua
local n, err = sock:send(data)
local data, err = sock:recv(count, timeout?)
local line, err, partial = sock:recv_line(timeout?)
local data, err = sock:recv_all(timeout?, max_bytes?)
local ok, err = sock:set_timeout(seconds)
local addr, err = sock:peer()
local addr, err = sock:sockname()
local ok, err = sock:close()
```

### Méthode d'un socket d'écoute

```lua
local client, err = server:accept(timeout?)
```

Un socket d'écoute refuse `send`, `recv`, `recv_line`, `recv_all`, `peer` et
`starttls`. Un socket connecté refuse `accept`.

<a id="socket-connect"></a>
## `babet.socket.connect(host, port, timeout?)`

Ouvre une connexion TCP cliente.

```lua
local sock, err = babet.socket.connect("example.net", 9000, 5)
if not sock then
    error(err)
end
```

### Résolution et adresses multiples

Babet appelle `getaddrinfo()` puis essaie les adresses retournées dans l'ordre.
Le timeout est partagé entre toutes les tentatives IPv4/IPv6 : ce n'est pas un
nouveau budget par adresse.

La résolution DNS elle-même est synchrone et se déroule avant cette deadline.
Un résolveur lent peut donc faire durer l'appel plus longtemps que `timeout`.
Pour éviter le DNS, utilise une adresse numérique :

```lua
local sock = assert(babet.socket.connect("127.0.0.1", 9000, 2))
```

### Timeout de connexion non conservé

Le troisième argument borne uniquement la connexion. Le socket créé possède un
timeout d'I/O par défaut de `0`, donc infini.

```lua
local sock = assert(babet.socket.connect("127.0.0.1", 9000, 2))
assert(sock:set_timeout(5)) -- nécessaire pour les I/O suivantes
```

### Erreurs typiques

- hostname vide ou contenant un NUL : `(nil, err)` ;
- port hors plage : `(nil, err)` ;
- mauvais type positionnel : erreur Lua ;
- refus de connexion, DNS, route ou autre erreur système : `(nil, "socket: …")` ;
- expiration : `(nil, "timeout")` ;
- signal géré pendant l'attente : `(nil, "interrupted")`.

<a id="socket-listen"></a>
## `babet.socket.listen(host, port, backlog?)`

Crée un socket TCP d'écoute avec `SO_REUSEADDR`.

### Écouter uniquement en loopback

```lua
local server = assert(babet.socket.listen("127.0.0.1", 9000))
```

Cette forme n'accepte pas les connexions provenant des autres interfaces.

### Écouter sur toutes les interfaces

```lua
local server = assert(babet.socket.listen("", 9000))
```

Une chaîne vide active `AI_PASSIVE`. Selon l'adresse sélectionnée par le
système, le socket peut être IPv4 ou IPv6. Pour imposer une famille, fournis
explicitement `"0.0.0.0"` ou `"::"`.

> Écouter sur toutes les interfaces expose le service au réseau. Ajoute une
> authentification et des règles de pare-feu adaptées.

### Demander un port libre au noyau

```lua
local server = assert(babet.socket.listen("127.0.0.1", 0))
local local_addr = assert(server:sockname())
print(local_addr.host, local_addr.port)
```

C'est la méthode recommandée pour les tests : elle évite les collisions de
ports.

### Backlog

```lua
local server = assert(babet.socket.listen("127.0.0.1", 9000, 128))
```

Le backlog est une demande faite au noyau. Le système peut le plafonner. Ce
n'est ni un nombre maximal de clients simultanés ni une limite applicative.

<a id="socket-accept"></a>
## `server:accept(timeout?)`

Attend et accepte une connexion cliente.

```lua
local client, err = server:accept(10)
if not client then
    if err == "timeout" then
        print("aucun client")
    else
        error(err)
    end
end
```

Le timeout positionnel remplace celui défini par `server:set_timeout()` pour cet
appel uniquement.

Le socket accepté :

- est un socket connecté, pas un socket d'écoute ;
- possède un timeout d'I/O par défaut de `0` ;
- n'hérite donc pas du timeout du serveur ;
- est fermé automatiquement à l'exécution d'un processus enfant grâce à
  `CLOEXEC`.

```lua
local client = assert(server:accept(10))
assert(client:set_timeout(5))
```

<a id="socket-set-timeout"></a>
## `sock:set_timeout(seconds)`

Définit le timeout par défaut des opérations suivantes :

- `send` ;
- `recv` ;
- `recv_line` ;
- `recv_all` ;
- `accept` sur un serveur.

```lua
assert(sock:set_timeout(3.5))
```

`0` rétablit les attentes infinies :

```lua
assert(sock:set_timeout(0))
```

Ce timeout ne s'applique pas rétroactivement à `connect`, ni au handshake de
`starttls`. `starttls` utilise uniquement `opts.timeout`.

Une valeur positionnelle sur `recv`, `recv_line`, `recv_all` ou `accept` prime
sur le défaut :

```lua
assert(sock:set_timeout(10))
local data, err = sock:recv(4096, 0.2) -- 200 ms pour cet appel
local data2, err2 = sock:recv(4096)   -- à nouveau 10 s
local data3, err3 = sock:recv(4096, 0) -- infini pour cet appel
```

<a id="socket-send"></a>
## `sock:send(data)`

Envoie la chaîne complète.

```lua
local count, err = sock:send("PING\r\n")
assert(count, err)
assert(count == 6)
```

Contrairement à l'appel POSIX `send(2)`, Babet boucle sur les écritures
partielles. En succès, `count == #data`.

La chaîne peut être vide ou binaire :

```lua
assert(sock:send(""))
assert(sock:send("AB\0CD") == 5)
```

`send` n'accepte pas de timeout positionnel. Il utilise le timeout défini par
`set_timeout()`. Sur TLS, les appels `SSL_write` sont découpés en blocs sûrs
lorsque nécessaire.

Une erreur après l'envoi de certains octets ne fournit pas le nombre partiel à
Lua. Pour un protocole nécessitant une reprise transactionnelle, ajoute un
mécanisme applicatif d'identifiant ou d'acquittement.

<a id="socket-recv"></a>
## `sock:recv(count, timeout?)`

Lit **au plus** `count` octets et renvoie dès qu'au moins un octet est
disponible.

```lua
local chunk, err = sock:recv(4096, 5)
```

Ce n'est pas un équivalent de « lire exactement N octets ». Une lecture peut
renvoyer moins que `count` sans que la connexion soit fermée.

`count` doit être un entier Lua strict compris entre `1` et `16 MiB`.

### Lire exactement N octets

```lua
local function recv_exact(sock, wanted, timeout)
    local chunks = {}
    local total = 0

    while total < wanted do
        local chunk, err = sock:recv(wanted - total, timeout)
        if not chunk then
            return nil, err
        end
        chunks[#chunks + 1] = chunk
        total = total + #chunk
    end

    return table.concat(chunks)
end

local header = assert(recv_exact(sock, 12, 5))
```

Attention : dans ce helper, `timeout` est appliqué séparément à chaque appel.
Pour imposer un budget global applicatif, calcule une échéance avec
`babet.monotonic()` et passe le temps restant.

### EOF et timeout

- fermeture distante avant tout octet : `(nil, "closed")` ;
- expiration : `(nil, "timeout")` ;
- interruption par signal : `(nil, "interrupted")`.

<a id="socket-recv-line"></a>
## `sock:recv_line(timeout?)`

Lit jusqu'au prochain LF (`\n`) et renvoie la ligne sans le LF final.

```lua
local line, err = sock:recv_line(10)
```

Si le LF est précédé d'un CR, le CR est aussi retiré :

```text
hello\n   -> "hello"
hello\r\n -> "hello"
```

Un CR situé ailleurs dans la ligne est conservé.

### Limite de ligne

Une ligne est limitée à **8 MiB**. Une ligne plus longue renvoie une erreur
`line too long`. Les octets de cette ligne surdimensionnée ne sont pas exposés
comme résultat partiel ; ferme généralement la connexion, car le protocole est
alors désynchronisé.

### EOF avant LF

Si le pair ferme la connexion avant le LF, la méthode renvoie trois valeurs :

```lua
local line, err, partial = sock:recv_line(5)
if not line and err == "closed" then
    print("fragment final :", partial)
end
```

`partial` est toujours une chaîne, éventuellement vide.

### Timeout avant LF

Lors d'un timeout ou d'une interruption, les octets déjà lus sont conservés
internement. Ils ne sont pas renvoyés comme troisième valeur, mais seront
livrés en premier lors de la lecture suivante.

```lua
local line, err = sock:recv_line(0.2)
if not line and err == "timeout" then
    -- un prochain recv_line(), recv() ou recv_all() reprend sans perte
end
```

<a id="socket-recv-all"></a>
## `sock:recv_all(timeout?, max_bytes?)`

Lit jusqu'à la fermeture distante et renvoie tout le flux concaténé.

```lua
local body, err = sock:recv_all(10)
```

Ici, EOF est le terminateur normal et constitue un succès. Cette fonction est
adaptée aux protocoles où la fermeture délimite le message. Elle est inadaptée
à une connexion persistante qui reste ouverte après la réponse.

### Limite mémoire

```lua
local body, err = sock:recv_all(10, 4 * 1024 * 1024)
```

- défaut : **64 MiB** ;
- valeur minimale : `1` ;
- maximum configurable : **2 GiB** ;
- type : entier Lua strict.

Au dépassement, le résultat est `(nil, err)` sans chaîne partielle.
Les octets déjà consommés restent cependant dans le buffer interne. Un nouvel
appel avec une limite supérieure peut reprendre le flux :

```lua
local body, err = sock:recv_all(2, 1024)
if not body and err:find("max_bytes", 1, true) then
    body = assert(sock:recv_all(2, 4096))
end
```

Le même principe s'applique après un timeout ou une interruption : les octets
accumulés ne sont pas perdus.

<a id="socket-pending"></a>
## Mélanger `recv`, `recv_line` et `recv_all`

Les trois méthodes partagent un buffer d'octets en attente. Cela garantit que
changer de méthode après un timeout ne réordonne pas le flux.

```lua
-- Le pair a envoyé "abc" sans LF.
local line, err = sock:recv_line(0.1)
assert(line == nil and err == "timeout")

-- Les trois octets déjà consommés par recv_line restent disponibles.
local prefix = assert(sock:recv(3, 1))
assert(prefix == "abc")
```

La règle reste toutefois simple : utilise de préférence une seule stratégie de
framing par phase de protocole. Mélanger volontairement les lectures peut être
utile pour lire un header ligne par ligne puis un corps de taille connue, mais
le code applicatif doit savoir exactement où se trouve la frontière.

Avant `starttls`, tout plaintext tamponné doit être consommé. Babet refuse le
handshake si ce buffer n'est pas vide, afin de ne pas confondre des octets en
clair avec des records TLS.

<a id="socket-addresses"></a>
## `sock:peer()` et `sock:sockname()`

Les deux méthodes renvoient une table :

```lua
{
    host = "127.0.0.1",
    port = 9000,
}
```

- `peer()` : endpoint distant d'un socket connecté ;
- `sockname()` : endpoint local du socket.

```lua
local remote = assert(sock:peer())
local local_addr = assert(sock:sockname())
print(remote.host, remote.port)
print(local_addr.host, local_addr.port)
```

Les adresses sont numériques : Babet ne réalise pas de reverse DNS.
`peer()` est refusé sur un socket d'écoute. `sockname()` fonctionne aussi sur
un serveur et permet de retrouver le port choisi après `listen(..., 0)`.

<a id="socket-close"></a>
## `sock:close()` et nettoyage automatique

`close()` est idempotent :

```lua
assert(sock:close())
assert(sock:close())
```

Après fermeture, les autres méthodes renvoient une erreur indiquant que le
socket est fermé.

Le userdata possède le descripteur et l'éventuelle session TLS. Si le script
oublie `close()`, le garbage collector ferme finalement les ressources.
N'utilise pas ce mécanisme pour le contrôle normal du cycle de vie : le moment
du GC n'est pas déterministe.

Les sockets créés et acceptés sont marqués close-on-exec. Un programme lancé
par [`babet.exec`](exec.md) n'hérite pas silencieusement des connexions ou du
port d'écoute.

<a id="socket-signals"></a>
## Signaux et interruptions

Lorsque l'attente noyau est interrompue par un signal enregistré avec
[`babet.signal`](signal.md), les opérations concernées peuvent renvoyer :

```lua
nil, "interrupted"
```

Le callback Lua est dispatché avant le retour. Les octets déjà retirés du flux
par `recv_line` ou `recv_all` restent tamponnés.

```lua
local stopping = false
babet.signal.handle("TERM", function()
    stopping = true
end)

while not stopping do
    local client, err = server:accept(1)
    if client then
        -- traiter le client
    elseif err ~= "timeout" and err ~= "interrupted" then
        error(err)
    end
end
```

Consulte la page [`SIGNAL`](signal.md) pour l'ordre, la coalescence et les
appels effectivement interruptibles.

<a id="socket-examples"></a>
## Exemples complets

### Petit serveur ligne par ligne

```lua
local S = babet.socket
local server = assert(S.listen("127.0.0.1", 9000, 64))
assert(server:set_timeout(1))

print("écoute sur 127.0.0.1:9000")

while true do
    local client, err = server:accept()
    if client then
        assert(client:set_timeout(30))

        local line, read_err = client:recv_line()
        if line then
            assert(client:send("echo: " .. line .. "\n"))
        elseif read_err ~= "closed" then
            io.stderr:write(read_err, "\n")
        end

        client:close()
    elseif err ~= "timeout" then
        error(err)
    end
end
```

### Client avec longueur préfixée

```lua
local function recv_exact(sock, n, timeout)
    local out, size = {}, 0
    while size < n do
        local part, err = sock:recv(n - size, timeout)
        if not part then return nil, err end
        out[#out + 1] = part
        size = size + #part
    end
    return table.concat(out)
end

local sock = assert(babet.socket.connect("127.0.0.1", 9000, 3))
assert(sock:set_timeout(5))

assert(sock:send(string.pack(">I4", 5) .. "hello"))
local raw_len = assert(recv_exact(sock, 4, 5))
local len = string.unpack(">I4", raw_len)
local payload = assert(recv_exact(sock, len, 5))
print(payload)
sock:close()
```

### Lire une réponse délimitée par EOF

```lua
local sock = assert(babet.socket.connect("127.0.0.1", 9001, 3))
assert(sock:send("request\n"))
local response = assert(sock:recv_all(10, 8 * 1024 * 1024))
print(#response)
```

Cette forme suppose que le serveur ferme sa moitié d'écriture pour signaler la
fin.

<a id="socket-errors"></a>
## Contrat d'erreur

### Erreurs Lua levées

Les mauvais types positionnels lèvent une erreur Lua, par exemple :

```lua
babet.socket.connect("localhost", "9000") -- port string
sock:send(42)                              -- données non string
sock:recv(4096.0)                          -- float, pas entier Lua
sock:set_timeout("5")                      -- string, pas nombre
```

Utilise `pcall` uniquement lorsque l'appel reçoit des valeurs dont le type n'a
pas déjà été validé.

### Erreurs renvoyées

Les valeurs hors plage et les erreurs d'exécution renvoient `(nil, err)` :

- port négatif ou supérieur à 65535 ;
- backlog nul ou trop grand ;
- timeout invalide ;
- count de `recv` hors limite ;
- `max_bytes` invalide ;
- DNS, connexion, lecture, écriture ou fermeture ;
- méthode incompatible avec le type de socket ;
- socket déjà fermé ;
- `"timeout"`, `"closed"` ou `"interrupted"` lorsque ces états sont
  spécifiquement identifiés.

Ne compare une erreur complète que pour les chaînes stables et typées comme
`"timeout"`, `"closed"` et `"interrupted"`. Les messages système peuvent
varier selon la libc et le noyau.

<a id="socket-design"></a>
## Sécurité, performances et limites

- **Pas d'authentification.** Un socket TCP brut ne prouve pas l'identité du
  pair et ne chiffre rien.
- **Pas de limite implicite de protocole.** `recv_line` et `recv_all` possèdent
  des caps, mais ton protocole doit aussi valider tailles, commandes et
  fréquences.
- **Timeouts recommandés.** Configure un timeout sur toute donnée contrôlée par
  un pair distant pour éviter les connexions lentes infinies.
- **Écoute réseau.** Préfère loopback lorsque le service n'a pas besoin d'être
  public.
- **Résolution DNS hors deadline.** La partie `getaddrinfo()` reste synchrone.
- **Un appel par thread.** N'utilise pas le même userdata simultanément depuis
  plusieurs états Lua. Les userdata ne sont de toute façon pas transportables
  par WORKERS.
- **Ordre TCP, pas messages.** TCP est un flux ; les frontières de `send` ne
  sont pas conservées à la réception.
- **Pas de half-close exposé.** Babet n'expose pas `shutdown(SHUT_WR)` ; seule
  la fermeture complète est disponible.
- **Pas de keepalive configuré.** Les options TCP avancées ne sont pas exposées.
