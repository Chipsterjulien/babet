> [English](../../en/modules/inotify.md) | **Français**

# `babet.inotify` — surveillance d'événements fichier

Wrappe `inotify(7)` de Linux pour la délivrance instantanée
d'événements fichier — pas de polling. Utilisé pour le rechargement
à chaud de configuration, la surveillance de dossiers de dépôt, le
tailing de logs, les triggers de synchronisation de fichiers, etc.

## Pourquoi

Poller un dossier avec `listDir` chaque seconde est gaspilleur
(CPU + lookups inode) et laggy. `inotify` est le mécanisme dédié
du kernel : le kernel ne réveille ton script que quand quelque
chose change réellement, avec une latence sub-milliseconde.

L'API Lua expose un contrat minimal sur un syscall notoirement
délicat. Le débordement de queue est explicitement remonté (la
seule chose pire que de perdre des événements silencieusement,
c'est de ne pas te le dire).

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.inotify.new()` | `watcher` (userdata) \| `(nil, err)` |
| `w:add(path, events)` | `integer` wd (watch descriptor) \| `(nil, err)` |
| `w:remove(wd)` | `(true, nil)` \| `(nil, err)` |
| `w:read(timeout?)` | `table` d'événements \| `(nil, "timeout")` \| `(nil, "interrupted")` \| `(nil, err)` |
| `w:close()` | `(true, nil)` — idempotent |

`read(timeout?)` : omis = **bloque** jusqu'au prochain événement ;
`0` = **non bloquant** (rend les événements déjà en attente, sinon
`(nil, "timeout")`) ; `t > 0` = attend au plus `t` secondes.
Attention : cette convention diverge de celle de `workers` où `0`
signifie aussi non-bloquant mais de `socket` où `set_timeout(0)`
signifie infini — ici, « rends-moi ce qu'il y a maintenant » est le
cas d'usage dominant.

### Argument `events`

Une liste 1..N stricte de strings de noms d'événements. Noms
acceptables :

| Nom | Déclenché quand |
| --- | --- |
| `"access"` | fichier accédé |
| `"modify"` | contenu modifié |
| `"attrib"` | métadonnées changées (perms, mtime, …) |
| `"close_write"` | un fichier ouvert en écriture est fermé |
| `"close_nowrite"` | un fd read-only est fermé |
| `"close"` | alias combiné : `close_write` **ou** `close_nowrite` |
| `"open"` | fichier ouvert |
| `"moved_from"` | fichier déplacé hors du dossier surveillé |
| `"moved_to"` | fichier déplacé dans le dossier surveillé |
| `"move"` | alias combiné : `moved_from` **ou** `moved_to` |
| `"create"` | fichier/dossier créé dans le dossier surveillé |
| `"delete"` | fichier/dossier supprimé du dossier surveillé |
| `"delete_self"` | le chemin surveillé lui-même est supprimé |
| `"move_self"` | le chemin surveillé est déplacé |

### Événement renvoyé par `read`

```lua
{
    wd     = 1,                  -- watch descriptor
    name   = "newfile.txt",      -- "" si la cible est le chemin surveillé lui-même
    events = { create = true, close_write = true },
    is_dir = false,
    cookie = 0,                  -- non-zero apparie moved_from / moved_to
}
```

Événement synthétique spécial pour le **débordement de queue** :

```lua
{ wd = -1, events = { overflow = true } }
```

Quand tu vois ça, la queue kernel a manqué de place et des
événements ont été perdus. Re-scanne les chemins surveillés pour
récupérer l'état.

## Exemple rapide

```lua
local w = assert(babet.inotify.new())
assert(w:add("/srv/incoming", { "close_write", "moved_to" }))

babet.signal.handle("TERM", function() w:close(); os.exit(0) end)

while true do
    local events, err = w:read()      -- bloque jusqu'à quelque chose
    if not events then
        if err == "interrupted" then break end
        io.stderr:write("inotify : ", err, "\n"); break
    end
    for _, ev in ipairs(events) do
        if ev.events.overflow then
            rescan()                    -- queue saturée, récupère
        else
            handle_new_file("/srv/incoming/" .. ev.name)
        end
    end
end
```

## Contrat d'erreur

- **`read(t)`** où `t` est NaN/Inf/négatif → lève via
  `luaL_error`.
- **`add(path, events)`** avec une table `events` non-liste
  (sparse, clés extra, éléments non-string) → `(nil, err)`.
- **`add` sur un chemin inexistant** → `(nil, "no such file or
  directory")`.
- **`read`** :
  - table `events` en cas de succès.
  - `(nil, "timeout")` si le timeout est écoulé.
  - `(nil, "interrupted")` si un signal géré est arrivé.
  - `(nil, err)` sur autres erreurs.
- **Méthodes après `close`** → `(nil, "inotify: closed")`.

## Décisions de design

- **Non-récursif en v1**. `inotify(7)` lui-même n'est pas
  récursif ; surveiller un arbre signifie le parcourir et
  appeler `add` sur chaque sous-dossier, puis gérer les
  événements `create` pour étendre la surveillance. C'est un vrai
  travail de design avec des subtilités (races entre le parcours
  et la délivrance d'événements, gestion du débordement) et
  méritera un module dédié si/quand nécessaire. Constructible en
  Lua pur au-dessus.
- **Liste d'événements obligatoire, pas de "all" implicite**.
  Surveiller tout sature la queue et force chaque événement à
  traverser Lua. Forcer l'appelant à choisir les événements rend
  le coût visible.
- **Le débordement est remonté explicitement**, jamais avalé. Le
  kernel a une queue finie (`/proc/sys/fs/inotify/max_queued_events`,
  défaut 16384). Quand elle déborde, des événements sont perdus.
  La seule action appropriée est de re-scanner ; perdre
  silencieusement le signal flinguerait toute la fiabilité.
- **`read()` est interruptible par signal**. Un `read()` qui
  bloque pour toujours en ignorant `SIGTERM` est le bug classique
  de l'arrêt gracieux. Voir [`signal`](signal.md).
- **`IN_CLOEXEC`** sur le fd : pas hérité par les sous-process
  `exec`utés, cohérent avec les sockets.

## Hors v1

- Surveillance récursive. À ajouter au niveau script (walk +
  add) ou attendre une option `recursive = true`.
- Plusieurs watchers par process. Faisable aujourd'hui en créant
  plusieurs instances `inotify.new()` ; pas de registre intégré.
- Sémantique `IN_MASK_ADD` (ajouter des événements à un watch
  existant). Actuellement `add(path, events)` remplace le mask.
  Besoin rare.
