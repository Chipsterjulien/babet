> [English](../../en/modules/tls.md) | **Français**

# TLS — connexion chiffrée directe, STARTTLS, certificats et SNI

Le support TLS de Babet repose sur les mêmes userdata que
[`babet.socket`](socket.md). Après le handshake, les méthodes `send`, `recv`,
`recv_line`, `recv_all`, `set_timeout`, `peer`, `sockname` et `close` restent
identiques.

Deux modes sont disponibles :

- `babet.socket.connect_tls()` pour une connexion TLS dès le premier octet ;
- `sock:starttls()` pour transformer en place une connexion TCP après une
  négociation applicative en clair.

Le module couvre :

- TLS 1.2 minimum, avec TLS 1.3 négocié lorsqu'il est disponible ;
- la vérification du certificat activée par défaut ;
- la vérification du hostname ;
- SNI, indépendamment de l'activation de la vérification ;
- les autorités système et des CA supplémentaires par appel ;
- un timeout global connexion TCP + handshake pour `connect_tls` ;
- un comportement fail-closed après le début d'un STARTTLS raté.

Il ne fournit pas de serveur TLS, de certificat client, d'ALPN, de pinning de
clé publique, d'OCSP applicatif ni de réglage fin des suites cryptographiques.

## Table des matières du module

- [Conventions essentielles](#tls-conventions)
- [Vue d'ensemble de l'API](#tls-api-summary)
- [Options TLS](#tls-options)
- [Connexion TLS directe](#tls-connect)
- [Transformer une connexion avec STARTTLS](#tls-starttls)
- [Vérification, hostname et SNI](#tls-hostname-sni)
- [Autorités de certification](#tls-ca)
- [Versions TLS](#tls-versions)
- [Timeouts](#tls-timeouts)
- [État du socket après une erreur](#tls-failure-state)
- [Exemples complets](#tls-examples)
- [Contrat d'erreur](#tls-errors)
- [Sécurité et limites](#tls-design)

<a id="tls-conventions"></a>
## Conventions essentielles

### Vérification activée par défaut

Cette forme vérifie la chaîne de certification et l'identité du serveur :

```lua
local sock = assert(babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
}))
```

`verify = false` est un opt-out explicite destiné aux tests ou à un protocole
qui applique une autre authentification forte. Il désactive **à la fois** la
validation de chaîne et la vérification du hostname :

```lua
local sock = assert(babet.socket.connect_tls("127.0.0.1", 8443, {
    verify = false,
    timeout = 5,
}))
```

Cette option chiffre le transport, mais ne protège pas contre un attaquant
actif de type homme-du-milieu.

### Même API de flux après le handshake

```lua
local sock = assert(babet.socket.connect_tls("irc.example.net", 6697, {
    timeout = 10,
}))
assert(sock:set_timeout(120))
assert(sock:send("PING :hello\r\n"))
local line = assert(sock:recv_line())
```

Le timeout du handshake et le timeout d'I/O sont distincts.

### SNI n'est pas la vérification

SNI indique au serveur quel virtual host sélectionner. La vérification décide
si le certificat reçu est digne de confiance et correspond au nom attendu.

Babet envoie SNI lorsqu'un hostname DNS est disponible, même avec
`verify = false`. Désactiver la vérification ne doit pas empêcher un serveur
multi-sites de choisir le bon certificat ou le bon endpoint.

<a id="tls-api-summary"></a>
## Vue d'ensemble de l'API

```lua
local sock, err = babet.socket.connect_tls(host, port, opts?)
local ok, err = sock:starttls(opts?)
```

Les deux formes utilisent la même table d'options :

```lua
{
    verify = true,
    hostname = "example.com",
    ca_cert = "/path/ca-bundle.pem",
    ca_path = "/path/certs",
    min_version = "1.2",
    timeout = 10,
}
```

| Champ | Type | Défaut | Rôle |
| --- | --- | --- | --- |
| `verify` | booléen strict | `true` | vérifie la chaîne et le hostname |
| `hostname` | string | host de `connect_tls` | nom attendu et nom SNI s'il est DNS |
| `ca_cert` | string | aucune CA supplémentaire | fichier PEM ajouté au trust store |
| `ca_path` | string | aucun dossier supplémentaire | dossier OpenSSL de CA hashées |
| `min_version` | `"1.2"` ou `"1.3"` | `"1.2"` | version TLS minimale |
| `timeout` | nombre fini `>= 0` | `0` | budget du handshake, en secondes |

Les champs inconnus sont actuellement ignorés. Une faute comme
`hostnme = "example.com"` ne produit donc pas d'erreur et ne remplace pas
`hostname`.

<a id="tls-options"></a>
## Options TLS détaillées

### `verify`

Doit être un vrai booléen Lua :

```lua
verify = true
verify = false
```

`verify = 1` et `verify = "yes"` sont refusés.

Avec `true`, Babet configure `SSL_VERIFY_PEER` et une vérification d'identité
avec `SSL_set1_host`.

### `hostname`

Sert à deux choses :

1. identité de référence pour le certificat lorsque `verify = true` ;
2. valeur SNI lorsqu'il s'agit d'un nom DNS.

```lua
local sock = assert(babet.socket.connect_tls("203.0.113.10", 443, {
    hostname = "api.example.com",
    timeout = 10,
}))
```

Cette forme connecte l'adresse IP fournie mais vérifie le certificat pour
`api.example.com` et envoie ce nom en SNI.

Un hostname qui est lui-même une adresse IP est utilisé pour la vérification
OpenSSL, mais n'est pas envoyé comme SNI, conformément au rôle DNS du champ
`server_name`.

### `ca_cert` et `ca_path`

Ces options ajoutent des autorités à celles déjà chargées pour cet appel. Elles
ne remplacent pas le trust store système et ne constituent pas du pinning.
Cela vaut pour `connect_tls` comme pour `starttls`. Une chaîne vide n'ajoute
aucune autorité. À l'inverse, le `ca_cert` non vide de [`HTTP`](http.md#http-tls)
remplace les autorités par défaut pour la requête ; les options de même nom
n'ont donc pas une politique identique entre les deux modules.

```lua
local sock = assert(babet.socket.connect_tls("service.internal", 443, {
    ca_cert = "/etc/myapp/internal-root.pem",
    timeout = 10,
}))
```

`ca_path` doit désigner un répertoire préparé selon les conventions OpenSSL,
avec les liens hashés attendus. Un simple dossier rempli de PEM arbitraires ne
suffit pas nécessairement.

### `min_version`

`"1.2"` et `"1.3"` sont les seules valeurs acceptées. Il s'agit d'une version
**minimale**, pas d'une version maximale.

```lua
local sock = assert(babet.socket.connect_tls("example.com", 443, {
    min_version = "1.3",
    timeout = 10,
}))
```

### `timeout`

`0` signifie aucun timeout de handshake. Une valeur positive est arrondie à au
moins 1 ms et doit rester représentable en millisecondes système.

<a id="tls-connect"></a>
## `babet.socket.connect_tls(host, port, opts?)`

Établit une connexion TCP puis réalise immédiatement un handshake TLS client.

```lua
local sock, err = babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
})
if not sock then
    error(err)
end
```

### Hostname par défaut

Lorsque `opts.hostname` est absent, le premier argument `host` sert de nom de
référence et de SNI s'il s'agit d'un nom DNS.

```lua
-- Vérifie et envoie example.com automatiquement.
local sock = assert(babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
}))
```

Avec une connexion par IP vers un certificat DNS, passe explicitement le nom :

```lua
local sock = assert(babet.socket.connect_tls("192.0.2.15", 443, {
    hostname = "www.example.com",
    timeout = 10,
}))
```

### Deadline globale

Après la résolution DNS, le même budget couvre :

- les tentatives de connexion TCP sur toutes les adresses ;
- le handshake TLS.

Le handshake ne reçoit pas un nouveau budget complet après la connexion.
Comme pour `socket.connect`, la résolution DNS synchrone reste hors deadline.

### Timeout d'I/O après succès

`opts.timeout` n'est pas conservé dans le socket. Après succès, le timeout
d'I/O par défaut vaut `0` :

```lua
local sock = assert(babet.socket.connect_tls("example.com", 443, {
    timeout = 10,
}))
assert(sock:set_timeout(15))
```

<a id="tls-starttls"></a>
## `sock:starttls(opts?)`

Transforme en place un socket TCP connecté après la négociation STARTTLS du
protocole applicatif.

```lua
local ok, err = sock:starttls({
    hostname = "mail.example.com",
    timeout = 10,
})
```

En succès, la méthode renvoie exactement `(true, nil)` et toutes les lectures
et écritures suivantes passent par TLS.

### Préconditions

Le socket doit être :

- ouvert ;
- connecté, pas en écoute ;
- encore en TCP clair ;
- sans octets plaintext conservés dans le buffer de lecture de Babet.

### Hostname obligatoire avec vérification

Contrairement à `connect_tls`, `starttls` ne mémorise pas le hostname utilisé
lors de la connexion TCP. Avec `verify = true`, `opts.hostname` est donc
obligatoire :

```lua
assert(sock:starttls({
    hostname = "smtp.example.com",
    timeout = 10,
}))
```

Cette omission est refusée **avant** le début du handshake, et le socket TCP
reste utilisable en clair.

### Consommer le plaintext avant l'upgrade

Si `recv_line()` ou `recv_all()` a déjà retiré des octets du noyau puis a
expiré, ces octets restent tamponnés. Babet refuse STARTTLS tant qu'ils ne sont
pas consommés :

```lua
local line, err = sock:recv_line(0.2)
if not line and err == "timeout" then
    -- Finir de consommer/résoudre la réponse plaintext avant starttls.
end
```

Cela empêche de présenter des octets applicatifs en clair au décodeur TLS.

### Déroulement applicatif

Babet n'envoie pas la commande `STARTTLS` à ta place. Le script doit suivre le
protocole :

1. connexion TCP ;
2. dialogue initial ;
3. commande STARTTLS ;
4. vérification de la réponse positive ;
5. appel à `sock:starttls()` ;
6. reprise du protocole chiffré, souvent avec une nouvelle salutation.

<a id="tls-hostname-sni"></a>
## Vérification, hostname et SNI

Les combinaisons importantes sont les suivantes :

| Connexion | `verify` | `hostname` | Vérification | SNI |
| --- | --- | --- | --- | --- |
| host DNS `example.com` | `true` | absent | `example.com` | `example.com` |
| IP `192.0.2.5` | `true` | `api.example.com` | `api.example.com` | `api.example.com` |
| IP `192.0.2.5` | `true` | absent | vérification de l'IP | aucun SNI |
| host DNS | `false` | absent | aucune | host DNS |
| IP | `false` | `api.example.com` | aucune | `api.example.com` |
| IP | `false` | absent | aucune | aucun SNI |

Avec `verify = false`, fournir `hostname` reste utile pour un virtual host TLS,
même si le certificat n'est pas vérifié.

SNI est envoyé avant que le serveur choisisse son certificat. La vérification
du hostname intervient ensuite sur le certificat présenté. Les deux mécanismes
sont donc liés dans l'usage courant, mais conceptuellement indépendants.

<a id="tls-ca"></a>
## Autorités de certification

Babet utilise un OpenSSL embarqué statiquement. Le contexte TLS socket tente :

1. les chemins par défaut d'OpenSSL ;
2. les variables `SSL_CERT_FILE` et `SSL_CERT_DIR` prises en compte par
   OpenSSL ;
3. plusieurs emplacements de CA connus sous Linux et BSD ;
4. les CA supplémentaires `ca_cert` et `ca_path` de l'appel.

Les CA personnalisées sont isolées par connexion. Charger une CA pour un appel
ne la rend pas fiable pour les connexions suivantes.

```lua
local a = assert(babet.socket.connect_tls("internal.example", 443, {
    ca_cert = "/tmp/test-root.pem",
    timeout = 5,
}))
a:close()

-- Cet appel ne réutilise pas /tmp/test-root.pem.
local b, err = babet.socket.connect_tls("internal.example", 443, {
    timeout = 5,
})
```

### CA supplémentaire, pas certificat serveur piné

Si `ca_cert` contient une autorité capable de signer plusieurs certificats,
tous les certificats valides pour le hostname et cette autorité peuvent être
acceptés. Pour du pinning strict, ajoute une vérification applicative externe ;
Babet n'expose pas actuellement le certificat pair ni son empreinte.

<a id="tls-versions"></a>
## Versions TLS

Le contexte refuse les protocoles antérieurs à TLS 1.2.

- défaut : minimum TLS 1.2 ;
- `min_version = "1.3"` : minimum TLS 1.3 ;
- TLS 1.3 est négocié automatiquement avec le défaut si le serveur le propose.

Babet ne permet pas de forcer un maximum. La version finale dépend d'OpenSSL et
du serveur.

<a id="tls-timeouts"></a>
## Timeouts

### `connect_tls`

```lua
local sock, err = babet.socket.connect_tls(host, port, {
    timeout = 5,
})
```

Le budget couvre TCP + handshake après DNS.

### `starttls`

```lua
local ok, err = sock:starttls({
    hostname = host,
    timeout = 5,
})
```

Le budget couvre uniquement le handshake STARTTLS. Il ne reprend pas le
timeout défini par `sock:set_timeout()`.

### I/O après le handshake

```lua
assert(sock:set_timeout(30))
local line, err = sock:recv_line()
```

Les opérations TLS utilisent un descripteur non bloquant en interne, piloté
par OpenSSL et `poll`, afin de respecter la deadline globale même lorsque
`SSL_read` ou `SSL_write` réclame une autre direction d'I/O.

<a id="tls-failure-state"></a>
## État du socket après une erreur

### `connect_tls`

Une erreur ne renvoie aucun socket. Les ressources TCP/TLS intermédiaires sont
fermées.

### `starttls` avant le handshake

Les erreurs suivantes laissent le socket TCP inchangé :

- options invalides ;
- hostname manquant avec `verify = true` ;
- plaintext tamponné ;
- échec de préparation du contexte TLS ou de configuration avant
  `SSL_connect` ;
- échec de passage non bloquant avant le handshake.

Le script peut corriger le problème et continuer en clair si le protocole le
permet.

### `starttls` après le début du handshake

Dès que `SSL_connect` a commencé, tout échec ferme définitivement le socket :

- timeout ;
- interruption ;
- certificat invalide ;
- alerte TLS ;
- erreur de protocole ou d'I/O.

Le flux peut déjà contenir un ClientHello ou avoir consommé des octets du pair.
Le réutiliser en clair serait ambigu et dangereux. Babet adopte donc un
comportement **fail-closed**.

```lua
local ok, err = sock:starttls(opts)
if not ok then
    -- Si le handshake a commencé, les appels suivants signaleront "closed".
    sock:close() -- reste idempotent
end
```

### `send` après une tentative d'écriture TLS

Après le premier `SSL_write` d'un appel `send`, tout abandon (timeout,
interruption ou erreur) ferme le transport. OpenSSL peut avoir commencé un
record sans encore annoncer d'octets applicatifs écrits : il ne suffit donc
pas de tester si un compteur d'envoi est positif. Le diagnostic initial est
conservé ; les appels suivants signalent un socket fermé et `close()` reste
idempotent. La fermeture précède l'appel d'un éventuel callback de signal.

Un timeout avant toute tentative `SSL_write` laisse le socket utilisable.

<a id="tls-examples"></a>
## Exemples complets

### Client HTTPS minimal sur socket brut

Pour une requête HTTP classique, préfère [`babet.http`](http.md). Cet exemple
montre seulement l'API de flux :

```lua
local S = babet.socket
local sock = assert(S.connect_tls("example.com", 443, { timeout = 10 }))
assert(sock:set_timeout(10))

assert(sock:send(
    "GET / HTTP/1.1\r\n" ..
    "Host: example.com\r\n" ..
    "Connection: close\r\n\r\n"
))

local response = assert(sock:recv_all(nil, 8 * 1024 * 1024))
print(response)
sock:close()
```

### Connexion par IP avec nom de certificat

```lua
local sock = assert(babet.socket.connect_tls("203.0.113.20", 443, {
    hostname = "api.example.com",
    ca_cert = "/etc/myapp/ca.pem",
    timeout = 5,
}))
```

### SMTP STARTTLS simplifié

```lua
local S = babet.socket
local sock = assert(S.connect("mail.example.com", 587, 5))
assert(sock:set_timeout(10))

local banner = assert(sock:recv_line())
assert(banner:match("^220"), banner)

assert(sock:send("EHLO client.example\r\n"))
repeat
    local line = assert(sock:recv_line())
    if line:match("^250[ -]STARTTLS") then
        -- capability vue
    end
until line:match("^250 ")

assert(sock:send("STARTTLS\r\n"))
local reply = assert(sock:recv_line())
assert(reply:match("^220"), reply)

assert(sock:starttls({
    hostname = "mail.example.com",
    timeout = 10,
}))

-- SMTP demande généralement un nouvel EHLO après STARTTLS.
assert(sock:send("EHLO client.example\r\n"))
```

Cet exemple ne constitue pas un client SMTP complet : il faut parser toutes les
réponses multi-lignes, authentifier et gérer les codes d'erreur.

### Test local auto-signé

```lua
local sock = assert(babet.socket.connect_tls("127.0.0.1", 8443, {
    verify = false,
    hostname = "dev.local", -- SNI reste envoyé
    timeout = 3,
}))
```

N'utilise pas cette configuration en production.

<a id="tls-errors"></a>
## Contrat d'erreur

### Erreurs Lua levées

```lua
babet.socket.connect_tls({}, 443)
babet.socket.connect_tls("host", "443")
```

Le host doit être une string stricte et le port un entier Lua strict.

### Erreurs `(nil, err)`

- host vide, NUL ou port hors plage ;
- table d'options invalide ;
- mauvais type ou mauvaise valeur d'un champ ;
- CA illisible ou invalide ;
- DNS ou connexion TCP ;
- timeout ou interruption ;
- échec du handshake ;
- vérification de chaîne ou de hostname ;
- précondition STARTTLS non satisfaite.

Les messages OpenSSL peuvent varier selon la version. Teste les états stables
comme `"timeout"` ou `"interrupted"`, et journalise le message complet pour le
diagnostic.

Les écritures internes à OpenSSL sont protégées contre `SIGPIPE`, y compris
pendant le handshake, la lecture et la fermeture. Une erreur de transport est
rapportée par l’API au lieu de tuer le programme ; `close()` reste une fermeture
best-effort. Le gestionnaire `babet.signal` de l’application n’est pas remplacé.

<a id="tls-design"></a>
## Sécurité et limites

- **Ne désactive pas `verify` en production.** Le chiffrement sans
  authentification n'empêche pas un MITM.
- **Passe le vrai hostname attendu.** Ne vérifie jamais un nom fourni par le
  pair lui-même.
- **CA privée.** Protège le fichier CA et déploie une rotation maîtrisée.
- **STARTTLS stripping.** Le protocole applicatif doit exiger STARTTLS, pas
  simplement l'utiliser lorsqu'il est annoncé. Un attaquant pourrait supprimer
  la capability dans un canal clair si ton application accepte un downgrade.
- **Pas d'ALPN.** Babet socket n'est pas adapté à HTTP/2, qui négocie
  normalement `h2` via ALPN.
- **Pas de certificat client.** Les protocoles mTLS ne sont pas supportés par
  cette API.
- **Pas d'accès au certificat pair.** Impossible de faire du pinning ou une
  inspection avancée directement en Lua.
- **Pas de serveur TLS.** `listen()` et `accept()` créent des sockets TCP ;
  aucune méthode `accept_tls` n'est exposée.
- **Vérification de révocation.** Babet ne fournit pas de politique OCSP/CRL
  applicative supplémentaire au comportement d'OpenSSL.
