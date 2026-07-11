> [English](../../en/modules/http.md) | **Français**

# `babet.http` — client HTTP

Un client HTTP/HTTPS simple basé sur
[cpp-httplib](https://github.com/yhirose/cpp-httplib), réutilisant
l'OpenSSL embarqué. Synchrone, bloquant, avec timeouts.

## Pourquoi

Presque chaque script non trivial doit parler à une API HTTP. Sans
client intégré, on en vient à utiliser `curl` via `exec`, avec
tout l'overhead de quoting et de spawn de process. `babet.http`
rend une requête accessible en une ligne, avec la vérification TLS
par défaut.

## API

| Fonction                      | Renvoie                                                                                      |
| ----------------------------- | -------------------------------------------------------------------------------------------- |
| `babet.http.request(opts)`    | `response` (table) \| `(nil, err)` — méthodes : GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE |
| `babet.http.get(url, opts?)`  | raccourci pour `request{ method="GET", url=url, ... }`                                       |
| `babet.http.post(url, opts?)` | raccourci pour `request{ method="POST", url=url, ... }`                                      |

> Pas de raccourcis `put`/`delete`/`patch` en v1 (une ancienne
> version de cette page les annonçait à tort) : passe par
> `request{ method = "PUT", ... }`. Voir « Hors v1 ».

### Table `opts`

| Champ              | Type                                                                                                               | Défaut                                                                                             |
| ------------------ | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| `url`              | string (requis pour `request`)                                                                                     | —                                                                                                  |
| `method`           | string — GET, HEAD, OPTIONS, POST, PUT, PATCH, DELETE                                                              | `"GET"`                                                                                            |
| `headers`          | table de `name = value`                                                                                            | `{}`                                                                                               |
| `body`             | string (interdit pour GET/HEAD/OPTIONS)                                                                            | `""`                                                                                               |
| `query`            | table `{ clé = valeur }` — encodée URL et ajoutée à l'URL (`?a=b&c=d`), fusion propre avec une query déjà présente | —                                                                                                  |
| `timeout`          | number (secondes)                                                                                                  | **aucun** — sans lui, les défauts internes de cpp-httplib s'appliquent ; passe-le systématiquement |
| `verify`           | boolean (vérification cert TLS)                                                                                    | `true`                                                                                             |
| `ca_cert`          | string (chemin du fichier CA bundle)                                                                               | défaut système                                                                                     |
| `follow_redirects` | boolean                                                                                                            | **`false`** — le suivi est opt-in ; limite de hops interne à cpp-httplib                           |

### Table `response`

```lua
{
    status = 200,
    body = "...",
    headers = {                 -- clés normalisées en minuscules
        ["content-type"] = "application/json",
        ["content-length"] = "42",
    },
}
```

> En-têtes **dupliqués** dans la réponse : la dernière valeur gagne
> (une clé = une string). Conséquence connue : si un serveur envoie
> plusieurs `Set-Cookie`, seul le dernier est visible. Si ce besoin
> devient réel, `headers` pourra porter une table de strings pour
> les clés répétées — voir « Hors v1 ».

## Exemples rapides

```lua
-- GET simple
local r, err = babet.http.get("https://api.example.com/health")
if r then
    print(r.status, r.body)
end

-- POST JSON avec header d'auth
local r, err = babet.http.post("https://api.example.com/v1/things", {
    headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. token,
    },
    body = babet.json.encode({ name = "widget", count = 7 }),
    timeout = 10,
})

-- Cert auto-signé (dev / CA privée)
local r = babet.http.get("https://internal.svc/", {
    ca_cert = "/etc/myapp/internal-ca.crt",
})

-- Désactiver la vérification (TESTS UNIQUEMENT)
local r = babet.http.get("https://expired.badssl.com/",
                            { verify = false })
```

## Contrat d'erreur

- **Mauvais types d'argument** → lève via `luaL_error`.
- **Erreurs réseau** (DNS, connect, timeout, TLS) →
  `(nil, "http: <description>")`.
- **`body` sur GET/HEAD/OPTIONS** → `(nil, "http: body not
  allowed for <méthode>")` — signalé, jamais ignoré en silence.
- **Méthode inconnue** → `(nil, "http: unsupported method '...'")`.
- **Les erreurs de statut HTTP ne sont pas des erreurs** — un
  `404` renvoie un `response` normal avec `status = 404`. La
  sémantique du statut est la responsabilité de l'appelant.

## TLS / trust store

Babet embarque sa propre OpenSSL statique, donc il n'hérite pas
automatiquement de la config `ca-certificates` de la distro. Deux
mécanismes garantissent que `verify=true` fonctionne d'emblée :

1. L'OpenSSL embarquée est compilée avec `--openssldir=/etc/ssl`,
   couvrant Arch, Debian, Ubuntu, Alpine, Gentoo.
2. `babet.socket.connect_tls` sonde en plus les chemins de CA
   bundles connus (Fedora/RHEL, OpenSUSE, FreeBSD, NetBSD).
   **`babet.http`, lui, s'appuie sur les défauts OpenSSL seuls**
   (mécanisme 1) : sur un layout exotique où le point 1 ne suffit
   pas, `http` peut nécessiter `ca_cert` là où `connect_tls`
   fonctionne. `tools/verif_ca.lua` diagnostique les deux chemins.

Tu peux override par appel avec `ca_cert`, ou globalement via les
variables d'environnement `SSL_CERT_FILE` / `SSL_CERT_DIR`. Voir [`security`](../security.md) et
[`tls`](tls.md) pour les détails.

## Décisions de design

- **Synchrone, bloquant**. Les scripts font généralement du
  request-response one-shot ; le sync est plus simple et
  suffisant. Pour beaucoup d'appels parallèles, utilise
  [`workers`](workers.md).
- **`verify=true` par défaut**. Désactiver la vérification TLS
  doit être explicite (`verify=false`). Pas de downgrade
  silencieux.
- **Le statut HTTP n'est pas une erreur**. L'appelant décide si
  `404` ou `500` est un échec ; l'appel réseau lui-même a réussi.
- **Headers normalisés en clés minuscules** dans la réponse, pour
  que les lookups case-insensitive marchent directement
  (`r.headers["content-type"]`).
- **Redirects opt-in**. Une redirection non suivie est visible
  (`status = 301/302` + header `location`) ; la suivre est une
  décision de l'appelant (`follow_redirects = true`). La limite de
  hops est celle de cpp-httplib, pas la nôtre.

## Hors v1

- Raccourcis `put` / `delete` / `patch` — couverts par
  `request{ method = ... }` ; sucre trivial à ajouter si le besoin
  se confirme.
- `opts.ca_path` (dossier de CA par appel) et `opts.max_redirects`
  — une ancienne version de cette page les documentait à tort.
- En-têtes de réponse répétés en table de strings (cas
  `Set-Cookie` multiples).
- Streaming du body de réponse (ex : pour télécharger de gros
  fichiers). Actuellement `body` est lu entièrement en mémoire.
- HTTP/2 / HTTP/3.
- WebSockets (utilise [`socket`](socket.md) + TLS + une
  bibliothèque de framing Lua si nécessaire).
- Côté serveur. cpp-httplib le supporte, mais exposer un serveur
  HTTP robuste à Lua est un design à part entière.
