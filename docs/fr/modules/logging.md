> [English](../../en/modules/logging.md) | **Français**

# `logging` — logger avec niveaux (module Lua)

Un logger standard avec niveaux : `debug`, `info`, `warn`,
`error`, `fatal`. Embarqué en tant que module Lua pur, chargé via
`require("logging")`. Pas dans le namespace `babet` — c'est un
module bibliothèque, comme `inspect`.

## Pourquoi

Chaque script non trivial finit par réinventer une variante de
"niveaux + timestamps + sortie fichier optionnelle". Standardiser
enlève le bikeshed et rend la sortie de log cohérente entre les
scripts Babet.

## API

```lua
local log = require("logging")
```

| Fonction                                                                               | Renvoie                                                                                                                 |
| -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `log.trace(...)`, `log.debug(...)`, `log.info(...)`, `log.warn(...)`, `log.error(...)` | rien — chacune émet si son niveau est ≥ au seuil courant. **Ne lèvent jamais** (même si le sink casse)                  |
| `log.set_level(lvl)`                                                                   | `lvl` = nom (`"trace"`…`"error"`, insensible à la casse) **ou** constante (`log.INFO`). Inconnu → lève                  |
| `log.set_output(out)`                                                                  | `out` = **tout objet répondant à `:write`** (handle `io.open`, table custom). Défaut : `io.stderr`. Mauvais type → lève |
| `log.set_color(bool)`                                                                  | active/désactive les couleurs ANSI (défaut : **off**). Non-boolean strict → lève                                        |
| `log.TRACE` … `log.ERROR`                                                              | constantes numériques des niveaux (10, 20, 30, 40, 50)                                                                  |

> Une ancienne version de cette page documentait un niveau `fatal`
> qui n'a jamais existé (appeler `log.fatal` plante : nil call) et
> omettait `trace` et `set_color`. Les cinq niveaux réels :
> `trace=10`, `debug=20`, `info=30` (seuil par défaut), `warn=40`,
> `error=50`.

Les messages sont préfixés `YYYY-MM-DD HH:MM:SS [NIVEAU]` (niveau
paddé à 5 caractères : `[INFO ]`, `[ERROR]`). Plusieurs arguments
sont joints par des espaces, comme `print`. Couleurs (opt-in via
`set_color(true)`) : trace gris, debug cyan, **info sans couleur**
(le cas nominal reste neutre), warn jaune, error rouge.

## Exemple rapide

```lua
local log = require("logging")
log.set_level("info")   -- trace et debug deviennent des no-ops

log.info("démarrage, pid =", babet.pid())
log.warn("tentative", 3, "sur", 5)
log.error("connexion échouée :", err)

-- Optionnel : router vers un fichier (objet :write-able)
local f = io.open("/var/log/myapp.log", "a")
if not f then
    log.error("impossible d'ouvrir le log ; on reste sur stderr")
else
    log.set_output(f)
end
```

Sortie :

```
2026-06-11 14:32:01 [INFO ] démarrage, pid = 12345
2026-06-11 14:32:05 [WARN ] tentative 3 sur 5
2026-06-11 14:32:05 [ERROR] connexion échouée : timeout
```

## Contrat d'erreur

- **`set_level` / `set_output` / `set_color`** : argument invalide
  (niveau inconnu, objet sans `:write`, non-boolean) → **lève** via
  `error()` — c'est un bug du programmeur, pas une condition
  d'exécution.
- **Les fonctions d'émission ne lèvent jamais** : l'écriture est
  entourée d'un `pcall` — un sink qui casse en cours de route
  (disque plein, fichier fermé) fait perdre le message en silence,
  jamais crasher le script.

## Décisions de design

- **Module Lua pur**. Pas besoin de C++, et être en Lua signifie
  que les scripts peuvent le monkey-patcher (ex : ajouter une
  sortie format JSON) au niveau appelant sans recompiler Babet.
- **Cinq niveaux, `trace` à `error` — pas de `fatal`**. `error` +
  `os.exit(1)` explicite vaut mieux qu'un niveau qui tue le process
  en douce ; et cinq niveaux suffisent à presque tout le monde.
- **Couleurs opt-in, `info` toujours neutre**. Le cas nominal ne
  doit pas crier ; seuls les écarts (warn, error) se voient.
- **Sink global unique**. Plusieurs loggers / loggers
  hiérarchiques / niveaux par module est un piège de feature creep.
  Si tu as besoin de plusieurs destinations, écris un wrapper.

## Hors v1

- Sortie JSON / logging structuré. Facile à bricoler au niveau
  script si nécessaire.
- Rotation des logs. Utilise `logrotate(8)` sur le fichier de
  sortie.
- Sortie asynchrone / buffered. Optimisation prématurée pour
  l'usage typique.
