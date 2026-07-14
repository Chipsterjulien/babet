> [English](../../en/modules/time.md) | **Français**

# `babet` time - horloges, sommeil, dates et durées

Babet expose deux horloges sub-seconde, un sommeil interruptible et des
utilitaires simples pour les timestamps ISO 8601 et les durées compactes.

Les fonctions historiques restent disponibles à la racine :

- `babet.monotonic()` ;
- `babet.now()` ;
- `babet.sleep(amount [, unit])`.

Les mêmes fonctions existent sous `babet.time`, avec quatre utilitaires
supplémentaires : `iso`, `parse_iso`, `parse_duration` et
`format_duration`.

## Table des matières du module

- [API](#time-api)
- [`monotonic()` et `now()`](#time-clocks)
- [`sleep(amount [, unit])`](#time-sleep)
- [`babet.time.iso([ts])`](#time-iso)
- [`babet.time.parse_iso(text)`](#time-parse-iso)
- [`babet.time.parse_duration(text)`](#time-parse-duration)
- [`babet.time.format_duration(seconds)`](#time-format-duration)
- [Contrat d'erreur récapitulatif](#time-errors)
- [Limites et choix de conception](#time-limits)

<a id="time-api"></a>
## API

| Fonction | Résultat |
| --- | --- |
| `babet.monotonic()` | `number`, ou exceptionnellement `(nil, err)` si `clock_gettime` échoue |
| `babet.now()` | `number`, ou exceptionnellement `(nil, err)` si `clock_gettime` échoue |
| `babet.sleep(amount [, unit])` | `(true, nil)` ou `(nil, err)` |
| `babet.time.iso([ts])` | `string` UTC |
| `babet.time.parse_iso(text)` | `(integer, nil)` ou `(nil, "parse_iso: ...")` |
| `babet.time.parse_duration(text)` | `(integer, nil)` ou `(nil, "parse_duration: ...")` |
| `babet.time.format_duration(seconds)` | `string` compacte, par exemple `"1d2h3m4s"` |

Les alias `babet.time.now`, `babet.time.monotonic` et `babet.time.sleep`
utilisent exactement les mêmes bindings et le même contrat que leurs noms à
la racine.

<a id="time-clocks"></a>
## `monotonic()` et `now()`

```lua
local started = babet.monotonic()
do_something()
local elapsed = babet.monotonic() - started
print(string.format("durée : %.3f s", elapsed))

local timestamp = babet.now()
print(timestamp)
```

`monotonic()` repose sur `CLOCK_MONOTONIC`. Sa valeur part d'une origine
arbitraire, généralement liée au démarrage du système. Elle sert à mesurer
une durée, car elle ne subit pas les sauts de l'horloge civile.

`now()` repose sur `CLOCK_REALTIME`. Il renvoie le temps POSIX en secondes
depuis le 1er janvier 1970 UTC, avec une partie fractionnaire. Il convient
aux timestamps, mais pas à la mesure d'une durée : l'horloge civile peut être
corrigée.

Les deux fonctions :

- n'acceptent aucun argument ;
- renvoient une seule valeur `number` en fonctionnement normal ;
- peuvent théoriquement renvoyer `(nil, err)` si l'appel système
  `clock_gettime` échoue.

<a id="time-sleep"></a>
## `sleep(amount [, unit])`

```lua
assert(babet.sleep(250, "ms"))
assert(babet.time.sleep(0.5))       -- 0,5 seconde
assert(babet.sleep(1000, "us"))
```

`amount` doit être un véritable `number` Lua, fini et positif ou nul. Les
floats sont acceptés. Une chaîne numérique comme `"100"` est refusée.

`unit` doit être une véritable `string` Lua :

| Unité | Signification |
| --- | --- |
| `"s"` | secondes, valeur par défaut |
| `"ms"` | millisecondes |
| `"us"` | microsecondes |

Une durée nulle réussit immédiatement. Une unité textuelle inconnue conserve
le comportement historique suivant :

```lua
local ok, err = babet.sleep(1, "minutes")
-- ok == nil
-- err == "Invalid time unit"
```

Si un signal géré par [`babet.signal`](signal.md) arrive pendant l'attente,
son callback Lua est dispatché puis `sleep` renvoie
`(nil, "interrupted")`. Un signal non géré provoquant `EINTR` ne raccourcit
pas l'attente : Babet reprend avec le temps restant.

Une autre erreur de `nanosleep` renvoie `(nil, "sleep: <description>")`.

<a id="time-iso"></a>
## `babet.time.iso([ts])`

`iso` formate une seconde Unix en UTC :

```lua
print(babet.time.iso(0))
-- 1970-01-01T00:00:00Z

print(babet.time.iso())
-- heure courante, à la seconde entière
```

Sans argument, `iso()` utilise l'heure courante. Avec un argument :

- `ts` doit être un véritable `number` Lua ;
- un entier ou un float fini est accepté ;
- une fraction est arrondie vers moins l'infini ;
- la valeur doit tenir dans un entier signé 64 bits.

L'arrondi est important avant l'époque Unix :

```lua
babet.time.iso(0.9)   -- 1970-01-01T00:00:00Z
babet.time.iso(-0.5)  -- 1969-12-31T23:59:59Z
```

Pour les années usuelles, le résultat possède la forme
`YYYY-MM-DDTHH:MM:SSZ`. Les timestamps extrêmes valides en `int64` peuvent
produire une année signée de plus de quatre chiffres. Ce résultat étendu
n'est pas forcément accepté par `parse_iso`, dont la grammaire impose une
année sur exactement quatre chiffres.

`iso` n'applique ni locale ni fuseau local et ne conserve pas les fractions
de seconde.

<a id="time-parse-iso"></a>
## `babet.time.parse_iso(text)`

Le parseur accepte volontairement un sous-ensemble strict et déterministe :

```text
YYYY-MM-DDTHH:MM:SSZ
YYYY-MM-DD HH:MM:SSZ
YYYY-MM-DDTHH:MM:SS.fraction+HH:MM
YYYY-MM-DDTHH:MM:SS.fraction-HH:MM
```

Règles exactes :

- `text` doit être une véritable `string` Lua ;
- l'année comporte exactement quatre chiffres et va de `0001` à `9999` ;
- le calendrier grégorien est validé, y compris les années bissextiles ;
- le séparateur est `T` majuscule ou un espace ;
- heures `00..23`, minutes `00..59`, secondes `00..59` ;
- les secondes intercalaires `:60` sont refusées ;
- la fraction est facultative, mais le point doit être suivi d'au moins un
  chiffre ; tous ses chiffres sont ignorés, sans arrondi ;
- la timezone est obligatoire : `Z` majuscule, `+HH:MM` ou `-HH:MM` ;
- les offsets acceptés vont de `00:00` à `23:59` ;
- `+0200`, `+02`, `z`, les espaces en début ou en fin et les données
  supplémentaires sont refusés ;
- un octet NUL embarqué n'est jamais tronqué : il rend la chaîne invalide.

Exemple :

```lua
local ts = assert(babet.time.parse_iso(
    "2026-06-17T10:00:00+02:00"))

assert(ts == babet.time.parse_iso("2026-06-17T08:00:00Z"))
```

Une chaîne syntaxiquement ou calendriquement invalide renvoie
`(nil, "parse_iso: ...")`. Un mauvais type ou un mauvais nombre d'arguments
lève une erreur Lua.

<a id="time-parse-duration"></a>
## `babet.time.parse_duration(text)`

Le format est une suite sans espace de couples `nombre + unité` :

```lua
assert(babet.time.parse_duration("45s") == 45)
assert(babet.time.parse_duration("1h30m") == 5400)
assert(babet.time.parse_duration("2d12h") == 216000)
```

Unités disponibles :

| Unité | Secondes |
| --- | ---: |
| `d` | 86400 |
| `h` | 3600 |
| `m` | 60 |
| `s` | 1 |

Les unités doivent apparaître au plus une fois et dans l'ordre strict
`d > h > m > s`. Les signes, décimales, espaces et unités `w`, `ms`, `us`
ou `ns` sont refusés. Un octet NUL embarqué n'est pas tronqué et provoque
également une erreur de parsing.

Les composantes ne sont pas normalisées : `"1h90m"` est valide et vaut
9000 secondes. Les zéros de tête et les composantes nulles ordonnées sont
également acceptés, par exemple `"0001s"` et `"0d0h0m0s"`.

Le total doit rester compris entre `0` et `math.maxinteger` sur la
configuration 64 bits de Babet. Les dépassements renvoient une erreur de
parsing.

Une chaîne invalide renvoie `(nil, "parse_duration: ...")`. Un mauvais type
ou un mauvais nombre d'arguments lève une erreur Lua.

<a id="time-format-duration"></a>
## `babet.time.format_duration(seconds)`

```lua
babet.time.format_duration(0)      -- "0s"
babet.time.format_duration(90)     -- "1m30s"
babet.time.format_duration(90061)  -- "1d1h1m1s"
```

`seconds` doit être un véritable `number` Lua, entier et positif ou nul. Un
float de valeur entière comme `3.0` est accepté ; `3.7`, `"3"`, NaN, Inf et
les valeurs négatives lèvent une erreur Lua.

La sortie est la représentation canonique utilisée par Babet :

- unités dans l'ordre `d`, `h`, `m`, `s` ;
- composantes nulles omises ;
- zéro représenté par `"0s"`.

Pour tout entier valide `n >= 0` :

```lua
assert(babet.time.parse_duration(
    babet.time.format_duration(n)) == n)
```

L'inverse n'est pas textuellement garanti, car le parseur accepte aussi des
formes non normalisées comme `"90m"` ou `"0h"`.

<a id="time-errors"></a>
## Contrat d'erreur récapitulatif

| Situation | Comportement |
| --- | --- |
| Mauvais type ou mauvaise arité | erreur Lua |
| NaN, Inf, durée négative ou valeur numérique hors plage | erreur Lua |
| Unité textuelle inconnue dans `sleep` | `(nil, "Invalid time unit")` |
| Signal géré pendant `sleep` | `(nil, "interrupted")` après dispatch du callback |
| Texte ISO ou durée invalide | `(nil, "parse_iso: ...")` ou `(nil, "parse_duration: ...")` |
| Échec système d'horloge ou de sommeil | `(nil, err)` |

<a id="time-limits"></a>
## Limites et choix de conception

- `monotonic()` sert aux durées ; `now()` sert aux timestamps.
- `iso` est un formateur UTC fixe, pas un remplaçant général de `os.date`.
- Aucun fuseau nommé, changement d'heure, locale ou calcul calendaire n'est
  fourni.
- Les fractions ISO sont ignorées et ne sont pas renvoyées par `iso`.
- `parse_duration` manipule des secondes entières uniquement.
- `CLOCK_BOOTTIME`, les durées négatives et les unités semaine/mois/année ne
  sont pas exposés.
