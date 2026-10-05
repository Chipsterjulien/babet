> [English](../../en/modules/http.md) | **Français**

# HTTP — requêtes web synchrones, headers, corps, TLS et limites

`babet.http` est un client HTTP/HTTPS synchrone construit sur cpp-httplib et
OpenSSL. Il convient aux APIs web, webhooks, appels REST simples, réponses en
mémoire bornées et téléchargements directs vers un fichier.

Le module couvre :

- HTTP et HTTPS ;
- GET, HEAD, OPTIONS, POST, PUT, PATCH et DELETE ;
- paramètres de query encodés et normalisés ;
- headers de requête ;
- corps texte ou binaire ;
- réponses binaires ;
- headers répétés ;
- redirections optionnelles ;
- vérification TLS activée par défaut ;
- timeout de connexion et budget global ;
- taille maximale de réponse en mémoire ;
- téléchargement GET en streaming avec remplacement atomique du fichier final.

Il ne fournit pas d'upload en streaming, de callbacks de réception, de session
persistante exposée, de cookies, de multipart/form-data, de helper de formulaire
URL-encoded, de proxy, de serveur HTTP, de WebSocket, ni d'HTTP/2 ou HTTP/3.

## Table des matières du module

- [Conventions essentielles](#http-conventions)
- [Vue d'ensemble de l'API](#http-api-summary)
- [`request(opts)`](#http-request)
- [`get(url, opts?)`](#http-get)
- [`download(url, destination, opts?)`](#http-download)
- [`post` et ses formes d'appel](#http-post)
- [URL, fragments et query](#http-url-query)
- [Méthodes HTTP](#http-methods)
- [Headers de requête](#http-request-headers)
- [Corps de requête et Content-Type](#http-body)
- [Timeouts](#http-timeout)
- [TLS et CA](#http-tls)
- [Redirections](#http-redirects)
- [Taille maximale de réponse](#http-max-body)
- [Taille et sécurité du téléchargement](#http-max-file)
- [Tables de réponse](#http-response)
- [Exemples complets](#http-examples)
- [Contrat d'erreur](#http-errors)
- [Sécurité et limites](#http-design)

<a id="http-conventions"></a>
## Conventions essentielles

### Client synchrone

L'appel bloque le thread courant jusqu'à la réponse ou l'erreur. Pour lancer
plusieurs requêtes indépendantes en parallèle, utilise des
[`workers`](workers.md), chacun avec sa propre requête.

### Statut HTTP et erreur de transport

Une réponse HTTP reçue est un succès de transport, même avec un statut 404 ou
500 :

```lua
local response, err = babet.http.get(url, { timeout = 10 })
assert(response, err)

if response.status >= 200 and response.status < 300 then
    print(response.body)
else
    io.stderr:write("HTTP ", response.status, "\n", response.body)
end
```

Un échec DNS, TCP, TLS, timeout ou limite de corps renvoie `(nil, err)`.

### Corps binaires

Le corps de requête et `response.body` sont binary-safe :

```lua
local response = assert(babet.http.post(url, "AB\0CD", {
    timeout = 10,
}))
assert(#response.body >= 0)
```

Les URL, méthodes, noms de headers, chemins de CA et valeurs destinées à une
API C ne peuvent pas contenir de NUL. Les URL et headers refusent aussi CR/LF
pour empêcher l'injection de lignes HTTP.

### Options inconnues

Les champs inconnus de la table sont actuellement ignorés. Cette faute ne
produit donc pas d'erreur :

```lua
local r = babet.http.get(url, { timeot = 5 }) -- typo : pas de timeout
```

Utilise exactement les noms documentés et centralise éventuellement la
construction des options dans ton application.

<a id="http-api-summary"></a>
## Vue d'ensemble de l'API

```lua
local response, err = babet.http.request(opts)
local response, err = babet.http.get(url, opts?)
local result, err = babet.http.download(url, destination, opts?)
local response, err = babet.http.post(url)
local response, err = babet.http.post(url, body)
local response, err = babet.http.post(url, opts)
local response, err = babet.http.post(url, body, opts)
local response, err = babet.http.post(url, nil, opts)
```

### Table d'options

| Champ | Type | Défaut | Rôle |
| --- | --- | --- | --- |
| `url` | string | obligatoire pour `request` | URL absolue `http://` ou `https://` |
| `method` | string | `"GET"` | méthode supportée, insensible à la casse |
| `headers` | table | `{}` | noms string, valeurs string ou number |
| `body` | string binaire | absent | corps, méthodes à corps uniquement |
| `query` | table | absente | clés string, valeurs string ou number |
| `timeout` | nombre fini `> 0` | défauts internes | secondes, connexion + budget global |
| `verify` | booléen strict | `true` | vérification du certificat HTTPS |
| `ca_cert` | string | autorités par défaut d'OpenSSL | fichier PEM utilisé à la place des autorités par défaut pour cette requête |
| `follow_redirects` | booléen strict | `false` | suit les redirections |
| `max_body_size` | entier `1..2 Gio` | `64 MiB` | cap mémoire pour `request`/`get`/`post` |
| `max_file_size` | entier positif | `8 Gio` | cap du fichier reçu par `download` |

Les wrappers `get` et `post` remplacent toujours `url` et `method`, même si la
table fournie contient d'autres valeurs.

<a id="http-request"></a>
## `babet.http.request(opts)`

Forme générale pour toutes les méthodes :

```lua
local response, err = babet.http.request({
    url = "https://api.example.com/items/42",
    method = "DELETE",
    headers = {
        ["Authorization"] = "Bearer " .. token,
    },
    timeout = 10,
})
```

Le premier argument doit être une table. `opts.url` doit être présent et être
une string stricte. Les erreurs dans les champs renvoient `(nil, err)` plutôt
que de lever, sauf mauvais type du premier argument.

<a id="http-get"></a>
## `babet.http.get(url, opts?)`

Raccourci qui copie superficiellement `opts`, puis impose :

```lua
opts.url = url
opts.method = "GET"
```

```lua
local response, err = babet.http.get(
    "https://api.example.com/health",
    { timeout = 5 }
)
```

Le second argument doit être absent, `nil` ou une table.

Un corps est interdit pour GET, y compris via `opts.body` :

```lua
local response, err = babet.http.get(url, { body = "x" })
-- nil, "http: body not allowed for GET"
```


<a id="http-download"></a>
## `babet.http.download(url, destination, opts?)`

Télécharge une réponse GET directement dans un fichier, sans accumuler le corps
dans Lua ni dans une chaîne C++ :

```lua
local result, err = babet.http.download(
    "https://example.com/archive.tar.gz",
    "downloads/archive.tar.gz",
    {
        timeout = 120,
        follow_redirects = true,
        max_file_size = 4 * 1024 * 1024 * 1024,
    }
)
assert(result, err)
assert(result.saved, "HTTP " .. result.status)
print(result.path, result.bytes)
```

L'appel reste synchrone, mais les chunks reçus sont écrits progressivement dans
un fichier temporaire placé dans le même dossier. La destination finale est
remplacée par un unique `renameat` seulement après réception complète de la
réponse finale, synchronisation et fermeture du temporaire.

Le wrapper impose toujours GET. Il accepte les options communes `headers`,
`query`, `timeout`, `verify`, `ca_cert` et `follow_redirects`. `body` est refusé.
`max_file_size` remplace `max_body_size` pour cet appel :

- entier Lua strictement positif ;
- défaut : 8 Gio ;
- configurable jusqu'à `math.maxinteger` ;
- appliqué aux octets réellement transmis au receiver fichier.

Seule une réponse finale 2xx est validée. Une réponse 1xx, 3xx non suivie, 4xx
ou 5xx reçue n'est pas une erreur de transport : `download` renvoie une table
avec `saved = false`, supprime le temporaire et laisse une éventuelle
destination existante strictement inchangée.

Le contrat du chemin est volontairement strict :

- le dossier parent doit déjà exister ;
- Babet ne crée pas les dossiers parents ;
- les composants `..` sont refusés ;
- les composants parents qui sont des symlinks sont refusés ;
- un symlink exactement à la destination est remplacé comme inode, sans suivre
  ni modifier sa cible ;
- le temporaire est créé dans le même dossier avec `O_EXCL` et supprimé après
  toute erreur ;
- une destination existante reste intacte après erreur DNS, TCP, TLS, timeout,
  limite de taille, statut HTTP non-2xx ou écriture disque.

Le renommage atomique empêche les lecteurs d'observer un fichier final partiel.
L'API ne fournit pas de reprise, callback de progression, durabilité garantie du
dossier parent après crash, ni préservation des métadonnées de l'ancien fichier.
Le nouveau fichier est créé avec le mode `0666` filtré par l'umask du processus.

<a id="http-post"></a>
## `babet.http.post` et ses formes d'appel

### Sans corps

```lua
local response, err = babet.http.post(url)
local response, err = babet.http.post(url, { timeout = 5 })
local response, err = babet.http.post(url, nil, { timeout = 5 })
```

Dans ces formes, aucun champ `body` n'est ajouté par le wrapper. La requête POST
peut donc être envoyée sans corps explicite.

### Corps positionnel

```lua
local response, err = babet.http.post(url, "payload", {
    timeout = 5,
})
```

Le corps doit être une string. Un nombre, un booléen ou une table à cette
position lève une erreur Lua, sauf qu'une table au deuxième argument est
interprétée comme `opts`.

### Corps dans `opts`

```lua
local response, err = babet.http.post(url, {
    body = "payload",
    timeout = 5,
})
```

### Priorité

Si un corps positionnel et `opts.body` sont fournis, le corps positionnel
gagne :

```lua
local response = assert(babet.http.post(url, "used", {
    body = "ignored",
    timeout = 5,
}))
```

<a id="http-url-query"></a>
## URL, fragments et query

### URL absolue

Babet accepte uniquement les schemes `http` et `https` :

```lua
https://example.com:8443/path?existing=1#fragment
```

L'URL doit contenir un host non vide. Les littéraux IPv6 entre crochets sont
pris en charge :

```lua
local r, err = babet.http.get("http://[::1]:8080/", { timeout = 2 })
```

Le fragment `#...` n'est jamais envoyé au serveur.

Babet n'effectue pas une validation RFC exhaustive du host avant de le passer à
cpp-httplib. Les erreurs de résolution ou de syntaxe restantes apparaissent au
transport.

### Ajouter une query

```lua
local response = assert(babet.http.get("https://example.com/search", {
    query = {
        q = "lua socket",
        page = 2,
    },
    timeout = 10,
}))
```

Les clés doivent être des strings. Les valeurs peuvent être des strings ou des
numbers. Babet protège les délimiteurs et les octets non ASCII, puis
cpp-httplib 0.45.0 normalise la query avant l'envoi. Le format effectivement
envoyé suit donc les conventions suivantes :

- l'espace devient `+` ;
- `+` devient `%2B` ;
- `/` et `?` restent littéraux dans une valeur ;
- les octets UTF-8 non ASCII sont percent-encodés en `%HH` ;
- `&`, `=` et `%` sont percent-encodés lorsqu'ils appartiennent à une clé ou
  une valeur.

Par exemple, `q = "lua socket"` devient `q=lua+socket`, tandis que
`path = "a/b"` reste `path=a/b`.

Si l'URL contient déjà `?a=b`, les nouveaux paramètres sont ajoutés avec `&`.
La query déjà présente est elle aussi normalisée par cpp-httplib : `%20` peut
devenir `+` et `%2F` peut devenir `/`. Le fragment `#...` est supprimé avant
l'envoi.

L'ordre d'itération d'une table Lua n'est pas garanti : ne signe pas une URL en
supposant l'ordre produit par `query`. Pour une signature canonique, construis
toi-même une URL déjà ordonnée et tiens compte de la normalisation décrite
ci-dessus.

Les NUL présents dans une clé ou une valeur sont envoyés sous la forme `%00`,
car la query est traitée comme des octets. Assure-toi que le serveur accepte ce
contenu.

<a id="http-methods"></a>
## Méthodes HTTP

Méthodes supportées :

- GET ;
- HEAD ;
- OPTIONS ;
- POST ;
- PUT ;
- PATCH ;
- DELETE.

La casse est normalisée : `method = "put"` devient PUT.

```lua
local response = assert(babet.http.request({
    url = "https://api.example.com/items/42",
    method = "PATCH",
    body = '{"enabled":true}',
    headers = { ["Content-Type"] = "application/json" },
    timeout = 10,
}))
```

GET, HEAD et OPTIONS refusent un champ `body`. POST, PUT, PATCH et DELETE
acceptent un corps absent, vide ou non vide.

Il n'existe pas de raccourci `put`, `patch` ou `delete` dans la version
actuelle : utilise `request`.

<a id="http-request-headers"></a>
## Headers de requête

```lua
headers = {
    ["Accept"] = "application/json",
    ["Authorization"] = "Bearer " .. token,
    ["X-Retry"] = 3,
}
```

### Noms

Une clé doit être une string non vide composée uniquement de caractères HTTP
`token` : lettres, chiffres et ``!#$%&'*+-.^_`|~``.

Sont notamment refusés :

- espace ou tabulation ;
- `:` ;
- CR/LF ;
- NUL ;
- clé non string.

Cette validation empêche l'injection d'un second header ou d'une ligne de
requête.

### Valeurs

Une valeur peut être une string ou un number. Les nombres sont convertis en
texte avec la conversion Lua.

NUL, CR et LF sont refusés. Les booléens, tables et autres types sont refusés.

### Doublons

Une table Lua ne peut contenir qu'une valeur par clé exacte. Le binding ne
fournit pas de forme permettant d'émettre plusieurs headers de requête portant
le même nom. Pour les listes combinables, construis une valeur séparée par des
virgules lorsque le standard du header l'autorise. Ne combine pas ainsi
`Cookie` ou d'autres champs sans vérifier leur syntaxe.

### Casse

Les noms sont transmis avec la casse fournie. HTTP traite les noms de headers
sans tenir compte de la casse. Pour détecter `Content-Type`, Babet compare en
minuscules.

<a id="http-body"></a>
## Corps de requête et `Content-Type`

### Corps absent et corps vide

Ces deux cas sont distincts :

```lua
-- Aucun champ body.
babet.http.post(url, { timeout = 5 })

-- Corps explicitement présent, mais vide.
babet.http.post(url, "", { timeout = 5 })
```

Lorsque `body` existe sur une méthode à corps et qu'aucun `Content-Type` n'est
fourni, Babet utilise :

```text
application/octet-stream
```

Avec un corps absent, aucun Content-Type par défaut n'est ajouté.

### JSON

```lua
local payload = assert(babet.json.encode({
    name = "babet",
    enabled = true,
}))

local response = assert(babet.http.post(url, payload, {
    headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    },
    timeout = 10,
}))
```

### Formulaire URL-encoded

Babet ne fournit pas de helper `form`. Encode explicitement le corps et le
header :

```lua
local body = "user=julien&active=1" -- encoder chaque champ si non fiable
local response = assert(babet.http.post(url, body, {
    headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
    },
    timeout = 10,
}))
```

La table `query` ne doit pas être détournée pour produire automatiquement un
corps de formulaire : elle modifie uniquement l'URL.

### Multipart

Aucun constructeur multipart n'est fourni. Pour des uploads complexes ou du
streaming de gros fichiers, utilise un outil spécialisé via `babet.exec`, par
exemple `curl`, en transmettant les valeurs sensibles par arguments ou fichiers
plutôt que par concaténation shell.

<a id="http-timeout"></a>
## `opts.timeout`

```lua
local response, err = babet.http.get(url, { timeout = 10 })
```

Le timeout doit être un nombre fini strictement positif. Les valeurs positives
inférieures à 1 ms sont arrondies à 1 ms. Le maximum représentable est environ
`INT_MAX` millisecondes.

Babet configure deux protections cpp-httplib :

- timeout de connexion ;
- timeout maximal global de la requête.

La première limite atteinte gagne.

### Limite DNS

Comme les sockets bruts, la résolution DNS synchrone peut se produire hors du
budget effectivement contrôlé par cpp-httplib. Un résolveur bloqué peut donc
faire dépasser la durée demandée.

### Toujours en fournir un

Sans `opts.timeout`, Babet laisse les valeurs internes de cpp-httplib et du
système s'appliquer. Pour tout serveur distant, passe explicitement une limite.

<a id="http-tls"></a>
## HTTPS, vérification et CA

### Vérification par défaut

```lua
local response = assert(babet.http.get("https://example.com/", {
    timeout = 10,
}))
```

`verify = true` par défaut. Le certificat et le hostname de l'URL sont
vérifiés par cpp-httplib/OpenSSL.

### CA spécifique

```lua
local response = assert(babet.http.get("https://internal.example/", {
    ca_cert = "/etc/myapp/internal-ca.pem",
    timeout = 10,
}))
```

Avec un `ca_cert` non vide, HTTP utilise les autorités de ce fichier **à la
place des autorités par défaut** pour la requête. Sans `ca_cert`, ou avec
`ca_cert = ""`, il charge les autorités par défaut d'OpenSSL, en tenant compte
de `SSL_CERT_FILE` et `SSL_CERT_DIR`. Le fichier explicite n'est pas ajouté
aux autorités par défaut. Cette règle s'applique aussi à `http.download`.

Cette politique diffère de [`socket.connect_tls` et `starttls`](tls.md#tls-ca),
ainsi que de [`websocket.connect`](websocket.md), qui **ajoutent** leurs CA
personnalisées aux autorités déjà chargées. HTTP n'expose pas `ca_path` et
n'effectue pas leur recherche supplémentaire des emplacements de CA connus
des distributions.

Exemple : si A appartient aux autorités par défaut et si le fichier fourni
contient uniquement B, HTTP accepte un serveur signé par B et rejette un
serveur signé uniquement par A. TLS socket et WSS continuent d'accepter A et
B. Dans tous les cas, `verify = true` vérifie aussi l'identité du serveur.
La configuration d'un appel ne rend pas B fiable pour les appels suivants.

Choisir un fichier de CA n'est pas du pinning d'un certificat serveur ou
d'une clé : plusieurs certificats signés par une autorité du fichier peuvent
être acceptés, à condition de réussir les autres vérifications TLS.

### Désactiver la vérification

```lua
local response = assert(babet.http.get("https://127.0.0.1:8443/", {
    verify = false,
    timeout = 3,
}))
```

Réserve cette forme aux tests contrôlés. Il n'existe pas d'option `hostname`
HTTP séparée : le host de l'URL est utilisé.

<a id="http-redirects"></a>
## `follow_redirects`

Par défaut, une redirection reste visible :

```lua
local r = assert(babet.http.get(url, { timeout = 10 }))
if r.status == 301 or r.status == 302 or r.status == 307 or r.status == 308 then
    print(r.headers.location)
end
```

Pour suivre automatiquement :

```lua
local r = assert(babet.http.get(url, {
    follow_redirects = true,
    timeout = 10,
}))
```

La table de réponse décrit alors la réponse finale. Babet n'expose pas
l'historique des hops ni une option `max_redirects`; la limite interne de
cpp-httplib s'applique.

Lorsqu'une redirection change de schéma, d'hôte ou de port, cpp-httplib 0.45
retire automatiquement les headers `Host`, `Authorization` et
`Proxy-Authorization` avant la requête suivante. Une redirection de même origine
conserve `Authorization`. Les autres headers ajoutés par le script, notamment
`Cookie` ou un secret personnalisé, ne bénéficient pas d'une suppression
générale : évite donc de suivre une destination non fiable avec de tels headers.

Avant d'activer le suivi sur une URL non fiable, considère aussi :

- le passage HTTPS vers HTTP ;
- l'accès à une adresse interne ou à un service de métadonnées cloud ;
- la destination finale réellement autorisée par ton application.

La suite de tests locale vérifie qu'un header `Authorization` n'est pas transmis
lors d'une redirection vers une autre origine.

<a id="http-max-body"></a>
## `max_body_size`

La réponse est entièrement accumulée en mémoire avant d'être renvoyée.

```lua
local response, err = babet.http.get(url, {
    timeout = 30,
    max_body_size = 8 * 1024 * 1024,
})
```

- défaut : 64 MiB ;
- minimum : 1 octet ;
- maximum : 2 GiB ;
- type : entier Lua strictement positif.

Dès que le flux dépasserait la limite, Babet annule la réception et renvoie :

```lua
nil, "http: response body exceeds max_body_size"
```

Aucun corps partiel n'est exposé. Le header `Content-Length` n'est pas la seule
protection : la limite s'applique aux chunks réellement reçus, y compris avec
un transfert chunked ou une longueur absente/trompeuse.

Babet prend en charge les trois cadrages de corps HTTP/1.1 utilisés ici :
`Content-Length`, `Transfer-Encoding: chunked` et corps terminé par la fermeture
de connexion. Babet 2.9.1 corrige spécifiquement les deux derniers avec
cpp-httplib 0.45.0 ; les limites portent toujours sur les octets réellement
livrés au receiver de Babet.

Pour un gros payload GET, utilise
[`babet.http.download`](#http-download) au lieu d'augmenter cette limite en
mémoire.

<a id="http-max-file"></a>
## `max_file_size` et sécurité du fichier

`max_file_size` s'applique uniquement à `download`. La limite porte sur les
octets du corps reçus, pas seulement sur le `Content-Length` annoncé. Si le
flux dépasserait le plafond, Babet annule, supprime le temporaire, préserve la
destination existante et renvoie :

```lua
nil, "http: response body exceeds max_file_size"
```

Le défaut de 8 Gio est un garde-fou, pas une recommandation d'accepter tout
fichier de cette taille. Choisis la plus petite limite compatible avec
l'artefact attendu. Un manque d'espace ou une erreur du système de fichiers
renvoie aussi `(nil, err)` avec la même garantie de nettoyage.

<a id="http-response"></a>
## Tables de réponse

### Réponse en mémoire


```lua
{
    status = 200,
    body = "...",
    headers = {
        ["content-type"] = "application/json",
        ["set-cookie"] = "b=2",
    },
    headers_multi = {
        ["content-type"] = { "application/json" },
        ["set-cookie"] = { "a=1", "b=2" },
    },
}
```

### `status`

Nombre entier du statut HTTP reçu.

### `body`

Chaîne binaire complète, éventuellement vide. Pour HEAD, le corps est vide,
même si `Content-Length` décrit la taille qu'aurait eue une réponse GET.

### `headers`

Table avec noms en minuscules. Si un header apparaît plusieurs fois, la
dernière occurrence rencontrée gagne. Cette vue est pratique pour les headers
simples mais insuffisante pour `Set-Cookie`.

### `headers_multi`

Chaque nom en minuscules pointe toujours vers une séquence de toutes les
occurrences, même lorsqu'il n'y en a qu'une.

```lua
for _, cookie in ipairs(response.headers_multi["set-cookie"] or {}) do
    print(cookie)
end
```

L'ordre des occurrences suit celui fourni par cpp-httplib. L'ordre des noms
dans `pairs()` n'est pas garanti.

### Résultat d'un téléchargement

```lua
{
    status = 200,
    saved = true,
    bytes = 123456,
    path = "downloads/archive.tar.gz",
    headers = { ... },
    headers_multi = { ... },
}
```

- `status`, `headers` et `headers_multi` gardent le sens décrit ci-dessus ;
- `saved` vaut vrai uniquement si le statut final est 2xx et si le commit
  atomique a réussi ;
- `bytes` indique le nombre d'octets de corps reçus, y compris pour un non-2xx ;
- `path` existe uniquement lorsque `saved` vaut vrai ;
- aucun champ `body` n'est créé volontairement.

<a id="http-examples"></a>
## Exemples complets

### GET JSON

```lua
local response, err = babet.http.get("https://api.example.com/v1/status", {
    headers = { ["Accept"] = "application/json" },
    query = { verbose = 1 },
    timeout = 10,
    max_body_size = 1024 * 1024,
})
assert(response, err)

if response.status ~= 200 then
    error("HTTP " .. response.status .. ": " .. response.body)
end

local data, decode_err = babet.json.decode(response.body)
assert(data, decode_err)
```

### POST JSON authentifié

```lua
local body = assert(babet.json.encode({ title = "hello" }))
local response, err = babet.http.post(
    "https://api.example.com/v1/items",
    body,
    {
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        },
        timeout = 15,
        max_body_size = 2 * 1024 * 1024,
    }
)
assert(response, err)
```

### PUT binaire

```lua
local file = assert(io.open("image.bin", "rb"))
local payload = file:read("a")
file:close()

local response = assert(babet.http.request({
    url = "https://upload.example.com/blob/42",
    method = "PUT",
    body = payload,
    headers = { ["Content-Type"] = "application/octet-stream" },
    timeout = 30,
    max_body_size = 1024 * 1024,
}))
```

Le fichier est lu entièrement en mémoire avant l'appel. Cette recette ne
convient pas à un très gros fichier.

### Télécharger un artefact de release

```lua
assert(babet.mkdir("downloads"))
local result, err = babet.http.download(
    "https://example.com/releases/tool.tar.gz",
    "downloads/tool.tar.gz",
    {
        timeout = 120,
        follow_redirects = true,
        max_file_size = 512 * 1024 * 1024,
    }
)
assert(result, err)
if not result.saved then
    error("statut HTTP inattendu " .. result.status)
end
print(result.bytes, "octets enregistrés dans", result.path)
```

### Gérer 404 séparément des erreurs réseau

```lua
local response, err = babet.http.get(url, { timeout = 5 })
if not response then
    io.stderr:write("transport impossible: ", err, "\n")
elseif response.status == 404 then
    print("ressource absente")
elseif response.status >= 400 then
    io.stderr:write("erreur HTTP ", response.status, "\n")
else
    print(response.body)
end
```

### Requêtes parallèles avec WORKERS

```lua
local jobs = {}
for i, url in ipairs(urls) do
    jobs[i] = assert(babet.workers.spawn([[
        local url = worker.args.url
        local r, err = babet.http.get(url, {
            timeout = 10,
            max_body_size = 1024 * 1024,
        })
        if not r then error(err) end
        return { status = r.status, size = #r.body }
    ]], { url = url }))
end

for i, job in ipairs(jobs) do
    local ok_result, value = job:join()
    if ok_result then
        print(urls[i], value.status, value.size)
    else
        io.stderr:write(urls[i], ": ", value, "\n")
    end
end
```

<a id="http-errors"></a>
## Contrat d'erreur

### Erreurs Lua levées

Mauvais type des arguments positionnels :

```lua
babet.http.request("not a table")
babet.http.get(42)
babet.http.get(url, "not a table")
babet.http.post(url, 42)
babet.http.download(url, 42)
babet.http.download(url, "fichier", "pas une table")
```

### Erreurs `(nil, err)`

- `opts.url` absent ou non string ;
- URL sans scheme/host, scheme non supporté, CR/LF ou NUL ;
- méthode non supportée ;
- corps sur GET/HEAD/OPTIONS ;
- champ d'option au mauvais type ou hors plage ;
- query invalide ;
- nom ou valeur de header invalide ;
- DNS, connexion, TLS, envoi, lecture ou timeout ;
- corps de réponse dépassant `max_body_size` ou `max_file_size` ;
- chemin de destination ou erreur du système de fichiers ;
- échec d'allocation interne converti en `(nil, "http: out of memory")` ;
- autre exception interne convertie en `(nil, "http: internal failure")`.

### Pas une erreur Babet

Un statut 1xx, 3xx, 4xx ou 5xx reçu produit une table normale. Pour `download`,
seul un 2xx est enregistré ; les autres statuts renvoient `saved = false`.
L'application définit sa propre politique.

Les opérations réseau internes, y compris le handshake et la fermeture TLS,
sont protégées contre `SIGPIPE` sans remplacer le gestionnaire de signal de
l’application. Une rupture de transport remonte comme une erreur HTTP ; une
erreur de fermeture best-effort ne retire pas une réponse déjà reçue.

<a id="http-design"></a>
## Sécurité et limites

- **SSRF.** Une URL contrôlée par un utilisateur peut viser loopback, le LAN,
  des sockets metadata cloud ou des services administratifs. Valide scheme,
  host, port et redirections selon ton modèle de menace.
- **Headers sensibles.** N'inclus pas un token dans les logs. Réfléchis à son
  comportement en cas de redirection inter-domaines.
- **TLS.** Garde `verify = true`. Une CA privée est préférable à
  `verify = false`.
- **Limites.** Réduis `max_body_size` ou `max_file_size` au minimum attendu.
- **Compression.** Selon les capacités compilées de cpp-httplib et les headers,
  le corps peut être traité par la bibliothèque ; la limite Babet porte sur les
  octets livrés au receiver.
- **Streaming ciblé.** `request`, `get` et `post` gardent la réponse en mémoire.
  `download` streame uniquement une réponse GET vers un fichier ; les uploads
  restent en mémoire.
- **Validation de l'artefact.** Le remplacement atomique évite un fichier final
  partiel, mais l'appelant doit encore valider statut, taille attendue et somme
  cryptographique.
- **Pas de session exposée.** Chaque appel construit un nouveau client ; aucun
  cookie jar ou pool de connexions n'est garanti à travers les appels.
- **Pas de formulaire/multipart automatique.** Encode explicitement ou utilise
  un outil spécialisé.
- **DNS synchrone.** Le resolver peut dépasser le timeout demandé.
- **API HTTP uniquement.** Pour un protocole custom, utilise SOCKET/TLS.
