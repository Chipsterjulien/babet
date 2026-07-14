> [English](../../en/modules/tables.md) | **Français**

# `babet` tables — fusion et copie de tables Lua

Deux helpers historiques vivent directement dans la table `babet` :

- `babet.mergeTables(...)` construit une nouvelle table à partir de plusieurs
  sources ;
- `babet.deepCopyTable(t)` copie récursivement les **valeurs** qui sont des
  tables.

Ils travaillent sur les entrées réellement stockées dans les tables Lua. Les
métaméthodes `__pairs` et `__index` ne fournissent donc pas de champs virtuels à
copier ou à fusionner.

## Table des matières du module

- [API](#tables-api)
- [`babet.mergeTables(t1, t2, ...)`](#tables-merge)
  - [Clés entières positives : concaténation](#tables-positive-keys)
  - [Toutes les autres clés : dernier écrivain gagnant](#tables-other-keys)
  - [Fusion superficielle](#tables-shallow)
- [`babet.deepCopyTable(t)`](#tables-deep-copy)
  - [Valeurs et graphe partagé](#tables-values)
  - [Les clés ne sont pas copiées](#tables-keys)
  - [Métatables et accès brut](#tables-metatables)
  - [Profondeur maximale](#tables-depth)
- [Contrat d'erreur](#tables-errors)
- [Limites et choix de conception](#tables-limits)
- [Hors v1](#tables-not-exposed)

<a id="tables-api"></a>
## API

| Fonction | Renvoie |
| --- | --- |
| `babet.mergeTables(t1, t2, ...)` | une nouvelle table |
| `babet.deepCopyTable(t)` | une nouvelle table |

Les deux fonctions renvoient exactement une valeur en cas de succès. Elles ne
renvoient jamais `(nil, err)` : une erreur d'appel ou de profondeur est levée.

<a id="tables-merge"></a>
## `babet.mergeTables(t1, t2, ...)`

Au moins deux arguments sont obligatoires et chacun doit être une table. Il
n'existe pas de limite d'arité propre à l'API au-delà des limites générales de
Lua.

Les sources ne sont pas modifiées. Le résultat est une table ordinaire sans
métatable, même si les sources en possèdent une.

<a id="tables-positive-keys"></a>
### Clés entières positives : concaténation

Toute clé que Lua représente comme un entier `>= 1` est traitée comme une
position de liste. Cela inclut une clé écrite `2.0`, que Lua canonicalise en
entier.

Pour chaque source, ces clés sont parcourues par ordre numérique croissant,
puis leurs valeurs sont ajoutées à la suite du résultat. Les trous et les
indices d'origine sont donc compactés :

```lua
local r = babet.mergeTables(
    { [4] = "d", [2] = "b" },
    { [7] = "g", [1] = "a" }
)

-- r == { "b", "d", "a", "g" }
```

Une même position présente dans plusieurs sources n'est pas écrasée : chaque
valeur est ajoutée.

<a id="tables-other-keys"></a>
### Toutes les autres clés : dernier écrivain gagnant

Les clés chaînes, booléennes, tables, fonctions, threads, userdata, light userdata ainsi que
les clés numériques flottantes, nulles ou négatives conservent leur identité.
Une source ultérieure écrase la valeur précédente pour la même clé :

```lua
local key = {}
local r = babet.mergeTables(
    { mode = "safe", [key] = 1, [0] = "a" },
    { mode = "fast", [key] = 2, [0] = "b" }
)

-- r.mode == "fast"
-- r[key]  == 2
-- r[0]    == "b"
```

<a id="tables-shallow"></a>
### Fusion superficielle

Les valeurs ne sont jamais copiées. Une sous-table placée dans le résultat est
la même table que dans la source :

```lua
local nested = { enabled = false }
local r = babet.mergeTables({ nested = nested }, {})

r.nested.enabled = true
-- nested.enabled == true
```

Pour obtenir ensuite un graphe indépendant pour les valeurs-table, utilise :

```lua
local isolated = babet.deepCopyTable(
    babet.mergeTables(defaults, overrides)
)
```

<a id="tables-deep-copy"></a>
## `babet.deepCopyTable(t)`

La fonction exige exactement une table. Elle crée une nouvelle table pour la
racine et pour chaque **valeur** qui est elle-même une table.

<a id="tables-values"></a>
### Valeurs et graphe partagé

Les cycles parcourus par les valeurs sont pris en charge et l'identité du
graphe est préservée :

```lua
local shared = { value = 42 }
local source = { a = shared, b = shared }
source.self = source

local copy = babet.deepCopyTable(source)

-- copy ~= source
-- copy.a ~= shared
-- copy.a == copy.b
-- copy.self == copy
```

Les valeurs non-table — nombres, chaînes, booléens, fonctions, threads,
userdata et light userdata — sont réutilisées telles quelles.

<a id="tables-keys"></a>
### Les clés ne sont pas copiées

Toutes les clés conservent leur valeur et leur identité d'origine. En
particulier, une table utilisée comme clé reste la table source :

```lua
local key = { id = 1 }
local source = {
    [key] = "value",
    key_as_value = key,
}
local copy = babet.deepCopyTable(source)

-- copy[key] == "value"          -- clé originale conservée
-- copy.key_as_value ~= key      -- valeur-table copiée
-- copy[copy.key_as_value] == nil
```

La fonction est donc une copie profonde des **valeurs-table**, pas une copie
structurelle des clés-table.

<a id="tables-metatables"></a>
### Métatables et accès brut

La métatable réelle de chaque table copiée est attachée à la copie **par
référence**. Elle n'est pas dupliquée. Modifier cette métatable affecte donc la
source et la copie.

Seules les paires réellement stockées sont parcourues. Un champ obtenu par
`__index` ou inventé par `__pairs` n'est pas matérialisé dans la copie. Une fois
la métatable partagée attachée, ses comportements restent naturellement actifs
sur la copie.

<a id="tables-depth"></a>
### Profondeur maximale

La racine est à la profondeur `0`. Jusqu'à **75 descentes vers de nouvelles
valeurs-table** sont acceptées, soit au maximum 76 tables sur un chemin racine
comprise. Une 76e descente vers une table encore inconnue lève :

```text
Table is too deep to copy (max depth 75 exceeded)
```

Une référence vers une table déjà copiée ne crée pas un nouveau niveau : un
cycle peut donc se refermer exactement à la limite.

<a id="tables-errors"></a>
## Contrat d'erreur

Les erreurs sont levées via l'API Lua :

- `mergeTables` avec moins de deux arguments ;
- tout argument non-table de `mergeTables` ;
- nombre d'arguments différent de un pour `deepCopyTable` ;
- argument non-table de `deepCopyTable` ;
- profondeur maximale dépassée.

```lua
local ok, err = pcall(babet.deepCopyTable, 42)
-- ok == false ; err contient "Argument must be a table"
```

<a id="tables-limits"></a>
## Limites et choix de conception

- `mergeTables` n'est pas un deep merge : une sous-table ultérieure remplace la
  référence précédente en bloc.
- Les métatables des sources sont ignorées par `mergeTables` ; son résultat
  n'en possède aucune.
- `deepCopyTable` partage les métatables et les clés-table avec la source.
- Une métatable faible (`__mode`) reste faible sur la copie puisqu'elle est
  partagée.
- L'ordre des clés de map n'est pas défini. Seul l'ordre des clés entières
  positives de `mergeTables` est garanti.
- La sélection ordonnée des clés-listes de `mergeTables` privilégie un code sûr
  face aux erreurs Lua ; son coût est quadratique par source en nombre de clés
  entières positives. Ce helper vise donc surtout des tables de taille modérée.

<a id="tables-not-exposed"></a>
## Hors v1

Des fonctions comme `deepMergeTables` ou une comparaison structurelle profonde
pourraient être ajoutées séparément. Elles ne font pas partie de l'API actuelle.
