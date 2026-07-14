> [English](../../en/modules/inotify.md) | **Français**

# `babet.inotify` — surveillance du système de fichiers

`babet.inotify` expose une interface minimale au mécanisme Linux
`inotify(7)`. Les notifications proviennent du noyau : il n'est pas
nécessaire de parcourir périodiquement les dossiers surveillés.

Le module est **spécifique à Linux** et la surveillance n'est pas
récursive.

## Table des matières du module

- [API](#inotify-api)
- [Créer un watcher](#inotify-new)
- [Ajouter une surveillance](#inotify-add)
  - [Option `onlydir`](#inotify-onlydir)
- [Lire les événements](#inotify-read)
  - [Débordement de la file](#inotify-overflow)
  - [Interruption par signal](#inotify-signal)
- [Retirer et fermer](#inotify-remove-close)
- [Exemple](#inotify-example)
- [Contrat d'erreur](#inotify-errors)
- [Limites](#inotify-limits)

<a id="inotify-api"></a>
## API

| Fonction | Résultat |
| --- | --- |
| `babet.inotify.new()` | `watcher` \| `(nil, err)` |
| `w:add(path, events [, opts])` | `wd` entier \| `(nil, err)` |
| `w:read([timeout])` | tableau d'événements \| `(nil, "timeout")` \| `(nil, "interrupted")` \| `(nil, err)` |
| `w:remove(wd)` | `(true, nil)` \| `(nil, err)` |
| `w:close()` | `(true, nil)` |

Les signatures sont strictes : les arguments supplémentaires lèvent une
erreur Lua. `close()` est idempotente et le ramasse-miettes ferme aussi
un watcher oublié.

<a id="inotify-new"></a>
## Créer un watcher

```lua
local watcher, err = babet.inotify.new()
if not watcher then
    error(err)
end
```

Chaque appel crée une instance indépendante. Le descripteur inotify est
ouvert avec `IN_NONBLOCK` et `IN_CLOEXEC` : `read()` pilote lui-même
l'attente, et le descripteur n'est pas transmis aux programmes lancés
par `exec`.

<a id="inotify-add"></a>
## Ajouter une surveillance

```lua
local wd, err = watcher:add(path, events [, opts])
```

`path` doit être une chaîne sans octet NUL. Il peut désigner un dossier
ou un fichier existant.

`events` est une liste stricte et non vide, indexée de `1` à `N`, sans
trou ni clé supplémentaire. Chaque élément doit être l'un des noms
suivants :

| Nom | Événement demandé |
| --- | --- |
| `"access"` | lecture ou accès au fichier |
| `"modify"` | contenu modifié |
| `"attrib"` | attributs ou métadonnées modifiés |
| `"close_write"` | descripteur ouvert en écriture fermé |
| `"close_nowrite"` | descripteur non ouvert en écriture fermé |
| `"close"` | combinaison de `close_write` et `close_nowrite` |
| `"open"` | fichier ouvert |
| `"moved_from"` | entrée déplacée hors du dossier surveillé |
| `"moved_to"` | entrée déplacée dans le dossier surveillé |
| `"move"` | combinaison de `moved_from` et `moved_to` |
| `"create"` | entrée créée dans le dossier surveillé |
| `"delete"` | entrée supprimée du dossier surveillé |
| `"delete_self"` | cible surveillée supprimée |
| `"move_self"` | cible surveillée déplacée |

<a id="inotify-onlydir"></a>
### Option `onlydir`

```lua
local wd = assert(watcher:add(path, { "create" }, {
    onlydir = true,
}))
```

`onlydir` doit être un booléen lorsqu'elle est présente :

- `true` ajoute le masque Linux `IN_ONLYDIR` et refuse donc une cible qui
  n'est pas un dossier ;
- `false` conserve le comportement normal ;
- les autres champs de `opts` sont actuellement ignorés.

Ajouter de nouveau un watch sur la même cible suit la sémantique native
d'inotify : le masque existant est remplacé, car `IN_MASK_ADD` n'est pas
utilisé.

<a id="inotify-read"></a>
## Lire les événements

```lua
local events, err = watcher:read([timeout])
```

Le timeout est exprimé en secondes et accepte les valeurs décimales :

- argument omis ou `nil` : attente illimitée ;
- `0` : lecture non bloquante des événements déjà disponibles ;
- valeur positive : attente bornée.

Un timeout négatif, NaN, infini ou trop grand renvoie `(nil, err)`. Un
argument d'un mauvais type lève une erreur Lua.

Une lecture réussie renvoie une liste de tables :

```lua
{
    {
        wd = 1,
        name = "photo.jpg",
        events = { create = true, close_write = true },
        is_dir = false,
        cookie = 0,
    },
}
```

- `wd` est le watch descriptor renvoyé par `add` ;
- `name` est le nom de l'entrée concernée, ou `""` pour un événement
  portant sur la cible surveillée elle-même ;
- `events` contient un booléen vrai pour chaque bit reçu ;
- `is_dir` reflète `IN_ISDIR` ;
- `cookie` permet d'apparier `moved_from` et `moved_to` ; hors déplacement,
  il vaut généralement `0`.

En plus des événements demandables par `add`, le noyau peut produire :

- `events.ignored` lorsque le watch est retiré, automatiquement ou par
  `remove` ;
- `events.unmount` lorsque le système de fichiers surveillé est démonté.

Un appel peut renvoyer plusieurs événements, car le module lit et décode
un lot complet de la file noyau.

<a id="inotify-overflow"></a>
### Débordement de la file

Lorsque la file inotify déborde, certains événements sont perdus. Le
module renvoie explicitement :

```lua
{
    wd = -1,
    name = "",
    events = { overflow = true },
    is_dir = false,
    cookie = 0,
}
```

Le programme doit alors rescanner les chemins surveillés pour reconstruire
un état fiable.

<a id="inotify-signal"></a>
### Interruption par signal

Si un signal géré par `babet.signal` arrive pendant l'attente, son callback
Lua est exécuté puis `read()` renvoie `(nil, "interrupted")`.

<a id="inotify-remove-close"></a>
## Retirer et fermer

```lua
assert(watcher:remove(wd))
assert(watcher:close())
```

Après `remove(wd)`, le noyau place normalement un événement `ignored`
dans la file. `remove` sur un identifiant invalide renvoie `(nil, err)`.

Après `close`, `add`, `read` et `remove` renvoient une erreur indiquant
que le watcher est fermé. `close` peut être appelée plusieurs fois.

<a id="inotify-example"></a>
## Exemple

```lua
local watcher = assert(babet.inotify.new())
local wd = assert(watcher:add("/srv/incoming", {
    "close_write",
    "moved_to",
}, {
    onlydir = true,
}))

while true do
    local events, err = watcher:read()
    if not events then
        if err == "interrupted" then
            break
        end
        error(err)
    end

    for _, event in ipairs(events) do
        if event.events.overflow then
            rescan_directory()
        elseif event.wd == wd then
            process_entry(event.name)
        end
    end
end

watcher:close()
```

<a id="inotify-errors"></a>
## Contrat d'erreur

- mauvais nombre ou mauvais type d'arguments : erreur Lua ;
- valeur invalide, erreur système ou watcher fermé : `(nil, err)` ;
- `read` sans événement avant l'échéance : `(nil, "timeout")` ;
- signal géré pendant `read` : `(nil, "interrupted")` ;
- `remove` et `close` réussis : `(true, nil)`.

Les erreurs système sont préfixées par `"inotify: "` et conservent la
description fournie par le système.

<a id="inotify-limits"></a>
## Limites

- Linux uniquement ;
- pas de surveillance récursive ;
- pas de `IN_DONT_FOLLOW`, `IN_ONESHOT` ni `IN_MASK_ADD` ;
- une instance peut contenir plusieurs watches et plusieurs instances
  indépendantes peuvent coexister dans le même processus.
