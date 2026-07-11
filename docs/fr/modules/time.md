> [English](../../en/modules/time.md) | **Français**

# `babet` time — horloges monotone et temps réel

Deux horloges avec précision sub-seconde et un sleep qui respecte
les unités `s`/`ms`/`us` ainsi que les signaux. Comble les trous de
`os.time` / `os.clock`. Les trois fonctions historiques vivent
directement sur `babet` ; les utilitaires de dates et durées vivent
sous la sous-table `babet.time` (qui expose aussi les trois
premières en alias).

## Pourquoi

`os.time()` ne donne que des secondes, et `os.clock()` mesure le
temps CPU, pas le temps réel. Aucun des deux n'est approprié pour
mesurer des durées réelles (latence de requête, backoff de retry,
timeouts). Et `os` n'a pas de sleep portable sub-seconde.

`babet.monotonic()` et `babet.now()` exposent
`CLOCK_MONOTONIC` (durées) et `CLOCK_REALTIME` (timestamps), avec
`babet.sleep()` qui respecte l'interruption par signal.

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.monotonic()` | `number` — secondes depuis une epoch arbitraire (immune aux changements d'horloge) |
| `babet.now()` | `number` — temps POSIX (secondes depuis 1970-01-01 UTC) |
| `babet.sleep(amount, unit?)` | `(true, nil)` \| `(nil, "interrupted")` |

`unit` pour `sleep` est l'un de `"s"` (défaut), `"ms"`, `"us"`.
Les floats sont acceptés. (Pas de `"ns"` : nanosleep ne garantit de
toute façon pas cette granularité, et le code ne l'accepte pas.)

## API — utilitaires de dates et durées (v1.8.0+)

Ajoutées sous la sous-table `babet.time`. Les trois fonctions
plates ci-dessus y sont aussi exposées en alias (`babet.time.now`,
`babet.time.monotonic`, `babet.time.sleep`) pour l'ergonomie.

| Fonction | Renvoie |
| --- | --- |
| `babet.time.iso(ts?)` | `string` — `"YYYY-MM-DDTHH:MM:SSZ"` (UTC). Sans argument, formate l'heure courante. |
| `babet.time.parse_iso(s)` | `(integer, nil)` \| `(nil, "parse_iso: ...")` — timestamp Unix en secondes. |
| `babet.time.parse_duration(s)` | `(integer, nil)` \| `(nil, "parse_duration: ...")` — nombre de secondes. |
| `babet.time.format_duration(n)` | `string` — style `"1d2h3m4s"`, compact, composantes nulles omises. |

**Format ISO 8601 accepté par `parse_iso`** — pragmatique, avec
une règle stricte : **un suffixe de timezone est obligatoire**.

- Séparateur date/heure : `T` ou espace.
- Timezone : `Z` (UTC), `+HH:MM`, ou `-HH:MM`. **Pas** de
  `+0200`, `+02`, ni d'absence — tous rejetés. Heures `00..23`,
  minutes `00..59`.
- Fractions de seconde (`.123`) acceptées mais ignorées.
- Une string sans timezone est rejetée explicitement plutôt
  qu'interprétée comme UTC, parce que la plupart des timestamps
  réels sans `Z` sont locaux, pas UTC, et la mauvaise
  interprétation silencieuse est une source de bug classique.

**Format de durée accepté par `parse_duration`** :

- Unités : `s`, `m` (minute), `h`, `d`. Pas de `w`, `mo`, `y`,
  `ms`, `us`, `ns` en v1.
- Composition sans espace : `"1h30m"`, `"2d12h"`, `"45m30s"`,
  `"1d1h1m1s"`.
- Unités en ordre **strictement décroissant** (`d > h > m > s`).
  `"30m1h"` est rejeté.
- Pas d'unité dupliquée : `"1h1h"` est rejeté.
- Pas de signe, pas d'espace. String vide rejetée. Un nombre nu
  sans unité (`"5"`) est rejeté.
- `"0s"` est la seule représentation canonique de zéro (matche
  `format_duration(0)`).

**Invariant aller-retour** : pour tout entier `n >= 0`,
`parse_duration(format_duration(n)) == n`. Vérifié dans la suite
de tests sur un échantillon représentatif.

## Exemple rapide

```lua
-- Mesurer une durée en toute sécurité (immune aux sauts NTP / DST)
local t0 = babet.monotonic()
do_something()
local elapsed = babet.monotonic() - t0
print(string.format("durée %.3f s", elapsed))

-- Timestamper un événement
local now = babet.now()
db:exec("INSERT INTO events (ts, kind) VALUES (?, ?)", { now, "ping" })

-- Dormir 100 ms, mais se réveiller sur un signal
local ok, err = babet.sleep(100, "ms")
if not ok and err == "interrupted" then
    print("réveillé par un signal")
end

-- Timestamp ISO 8601 pour les logs (toujours UTC)
print("event at " .. babet.time.iso())          -- "2026-06-17T14:32:01Z"
print(babet.time.iso(0))                        -- "1970-01-01T00:00:00Z"

-- Parser une ligne de log en timestamp Unix
local ts = assert(babet.time.parse_iso("2026-06-17T10:00:00+02:00"))
-- ts vaut 1781683200 (qui est 2026-06-17T08:00:00Z)

-- Durées lisibles par un humain
local cache_ttl = babet.time.parse_duration("2h30m")  -- 9000
print("cache valide pendant " .. babet.time.format_duration(cache_ttl))
-- "cache valide pendant 2h30m"
```

## Contrat d'erreur

- **`monotonic()` / `now()`** : ne peuvent pas échouer. Renvoient
  toujours un number.
- **`sleep(amount, unit)`** :
  - `(true, nil)` si le sleep s'est terminé normalement.
  - `(nil, "interrupted")` si un signal géré est arrivé pendant le
    sleep (voir [`signal`](signal.md)).
- **NaN / Inf / amount négatif** → lève via `luaL_error`.
- **String d'unit inconnue** → lève via `luaL_error`.
- **`iso(ts)` hors bornes int64** (`|ts|` au-delà de ce que le
  calendrier peut représenter) → lève via `luaL_error`
  (`"iso: value out of int64 range"`).

## Décisions de design

- **Deux horloges, deux fonctions, pas de flag**. `monotonic()`
  pour les durées, `now()` pour les timestamps. Les fondre en une
  fonction avec paramètre inviterait au mauvais choix.
- **`now()` pour le temps réel**, pas `realtime()` — plus court,
  et le sens naturel en anglais matche ce qu'on attend (l'heure
  actuelle).
- **`sleep` conscient des signaux**. Un sleep de 60 secondes qui
  ignore `SIGTERM` est le bug classique de l'arrêt gracieux.
  `sleep()` renvoie `(nil, "interrupted")` pour que l'appelant
  puisse sortir proprement.
- **Pas de helper "format date"**. `os.date(format, babet.now())`
  marche très bien, et une fonction dupliquée ne serait qu'un
  wrapper.

## Hors v1

- `babet.boottime()` (`CLOCK_BOOTTIME` — inclut le suspend).
  Rarement utile, facile à ajouter plus tard.
- Helpers `babet.utcnow()` / `localnow()` qui renvoient des
  strings pré-formatées. Trivial en Lua, sans valeur ajoutée.
