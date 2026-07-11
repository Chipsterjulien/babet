> [English](../../en/modules/tables.md) | **Français**

# `babet` tables — helpers de manipulation de tables

Deux helpers qui comblent des manques évidents de la bibliothèque
standard Lua : une vraie deep copy, et un merge multi-sources.

## Pourquoi

La stdlib Lua n'a pas de deep copy intégrée ni de merge multi-tables.
Les deux sont des besoins courants : merger une config defaults +
overrides, snapshotter une table avant mutation, copier une
arborescence d'options. Les écrire à chaque script est répétitif et
source d'erreurs (oublier la metatable, les cycles, etc.).

Ces deux fonctions vivent directement sur la table `babet` (pas
de sous-namespace) parce qu'elles précèdent la convention par module
adoptée pour les ajouts récents.

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.mergeTables(t1, t2, ...)` | nouvelle `table` — clés string mergées (le dernier écrit gagne), clés numériques append en ordre |
| `babet.deepCopyTable(t)` | nouvelle `table`, copiée récursivement |

`mergeTables` est variadique — **deux tables minimum** (moins :
lève), autant que tu veux au-delà.
Les entrées ne sont pas mutées. Le merge a deux règles :

- **Clés string** : les tables suivantes écrasent les précédentes
  à la même clé (le dernier écrit gagne). Le remplacement est
  **shallow** : une valeur-table écrase la précédente **en bloc**,
  il n'y a pas de merge récursif des sections imbriquées. Et les
  valeurs sont **référencées, pas copiées** — le résultat partage
  ses sous-tables avec les entrées ; combine avec `deepCopyTable`
  si tu veux un résultat indépendant.
- **Clés numériques (partie array)** : concaténées dans l'ordre où
  les tables sont passées, puis dans l'ordre 1..n à l'intérieur
  de chaque table. Donc `mergeTables({1, 2}, {3, 4})` donne
  `{1, 2, 3, 4}`, pas `{3, 4}`.

`deepCopyTable` copie les tables imbriquées récursivement. Les
cycles sont détectés (pas de boucle infinie), et les sous-tables
partagées ne sont copiées qu'une fois (la structure est préservée,
pas dupliquée). La **métatable** de chaque table copiée est posée
telle quelle sur la copie (référence partagée — la métatable
elle-même n'est pas dupliquée). Les valeurs non-table (nombres,
strings, booleans, fonctions, userdata) sont référencées telles
quelles. Profondeur maximale : **75 niveaux** (au-delà : lève
`"Table is too deep to copy (max depth 75 exceeded)"`).

## Exemple rapide

```lua
-- Clés string : le dernier écrit gagne
local defaults = { port = 8080, host = "localhost", debug = false }
local user_cfg = { port = 9000, debug = true }
local cfg = babet.mergeTables(defaults, user_cfg)
-- cfg.port  == 9000      (user_cfg a override)
-- cfg.host  == "localhost"
-- cfg.debug == true

-- Clés numériques : append en ordre
local a = { 1, 2 }
local b = { 3, 4 }
local merged = babet.mergeTables(a, b)
-- merged == { 1, 2, 3, 4 }   (PAS { 3, 4 })

-- Deep copy : snapshot avant mutation
local snapshot = babet.deepCopyTable(cfg)
cfg.port = 9999             -- N'AFFECTE PAS snapshot
print(snapshot.port)        -- toujours 9000
```

## Contrat d'erreur

- **Mauvais type d'argument** (passer une non-table à l'une ou
  l'autre des fonctions) → lève via `luaL_error`.
- Aucune des deux fonctions ne renvoie d'erreur via `(nil, err)`.
  Elles réussissent ou lèvent.

## Décisions de design

- **Les valeurs shallow sont référencées, pas deep-copiées**, dans
  `deepCopyTable`. Copier des fonctions ou des userdata n'a pas de
  sens, et copier des valeurs immuables (nombres, strings, booleans)
  ne change rien. Seules les tables sont dupliquées récursivement.
- **Les metatables ne sont pas copiées** dans `deepCopyTable`. C'est
  un choix conscient : préserver une metatable à travers une copie
  peut surprendre l'appelant (la copie déclenche encore des
  callbacks `__index` qui mutent l'original). Si tu dois copier
  avec metatable, fais-le explicitement avec
  `setmetatable(babet.deepCopyTable(t), getmetatable(t))`.
- **`mergeTables` est shallow**. Si deux tables sources partagent
  une sous-table à la même clé string, le résultat référence la
  dernière telle quelle — il ne récurse pas dedans. Combine avec
  `deepCopyTable` si tu veux une sémantique merge-puis-isole.
- **Les clés numériques sont append, pas écrasées**. Ce choix
  vient du cas d'usage Lua le plus courant : combiner des tables
  type liste (`{1, 2}` + `{3, 4}` → `{1, 2, 3, 4}`). Si tu voulais
  une sémantique d'écrasement sur les clés numériques, construis
  une table de destination et assigne explicitement.

## Hors v1

Additif — pourrait être ajouté plus tard sans casser le SemVer :

- Un `deepMergeTables` qui récurse dans les tables imbriquées quand
  les deux sources ont une table à la même clé. Demande courante,
  mais la sémantique autour des listes vs maps devient ambiguë,
  d'où pas dans v1.
- Un `equalsTables` pour comparaison structurelle profonde. Facile
  à écrire en Lua pur, n'a pas émergé comme besoin réel.
