> [English](../../en/modules/json.md) | **Français**

# `babet.json` — encodage et décodage JSON

Le module `babet.json` s'appuie sur **nlohmann/json 3.11.3**. Il
convertit les valeurs Lua en texte JSON et inversement, avec deux
sentinelles pour représenter sans ambiguïté `null` et le tableau vide
`[]`.

## Table des matières du module

- [API](#json-api)
- [Correspondance des types](#json-types)
  - [Lua vers JSON](#json-lua-to-json)
  - [JSON vers Lua](#json-json-to-lua)
- [`null`](#json-null)
- [Objet vide, tableau vide et `as_array`](#json-empty-containers)
- [Options de `encode`](#json-encode-options)
- [Chaînes, UTF-8 et octets NUL](#json-strings)
- [Nombres](#json-numbers)
- [Ordre des objets et clés dupliquées](#json-order)
- [Contrat d'erreur](#json-errors)
- [Limites](#json-limits)

<a id="json-api"></a>
## API

| Élément | Contrat |
| --- | --- |
| `babet.json.encode(value [, opts])` | Renvoie `texte, nil` ou `nil, err` |
| `babet.json.decode(text)` | Renvoie `valeur, nil` ou `nil, err` |
| `babet.json.null` | Sentinelle représentant le `null` JSON |
| `babet.json.empty_array` | Sentinelle constante qui s'encode en `[]` |
| `babet.json.as_array(t)` | Marque `t` comme tableau JSON et renvoie la même table |

`encode` accepte exactement un ou deux arguments. `decode` exige
exactement **une chaîne Lua** : un nombre n'est pas converti
implicitement en texte. `as_array` exige exactement une table.

<a id="json-types"></a>
## Correspondance des types

<a id="json-lua-to-json"></a>
### Lua vers JSON

| Lua | JSON |
| --- | --- |
| `nil` passé directement à `encode` | `null` |
| `babet.json.null` | `null` |
| `babet.json.empty_array` | `[]` |
| booléen | booléen |
| entier Lua | nombre entier JSON |
| flottant Lua fini | nombre JSON flottant |
| chaîne UTF-8 valide | chaîne JSON |
| table vide non marquée | objet vide `{}` |
| clés entières exactement `1..n` | tableau JSON |
| clés uniquement de type chaîne | objet JSON |

Dans une table Lua, affecter `nil` supprime la clé avant même
l'encodage. Utilise `babet.json.null` pour conserver explicitement une
clé dont la valeur JSON doit être `null`.

Une table mixant clés chaînes et entières, un tableau à trous, ou une
table contenant une clé non représentable (`0`, entier négatif,
flottant, booléen, table, etc.) ne peut pas être convertie : `encode`
renvoie alors `nil, err`.

<a id="json-json-to-lua"></a>
### JSON vers Lua

| JSON | Lua |
| --- | --- |
| `null` | `babet.json.null` |
| booléen | booléen |
| entier signé dans la plage Lua | entier Lua |
| entier non signé supérieur à `math.maxinteger` | flottant Lua |
| nombre JSON flottant | flottant Lua |
| chaîne | chaîne Lua |
| tableau | table séquentielle `1..n` |
| objet | table à clés chaînes |

Un entier JSON trop grand pour `lua_Integer` est converti en flottant
plutôt que de reboucler en valeur négative. Cette conversion peut perdre
de la précision, comme toute conversion vers un nombre IEEE 754.

<a id="json-null"></a>
## `null`

Lua ne peut pas conserver une valeur `nil` dans une table. La
sentinelle partagée `babet.json.null` comble cette différence :

```lua
local J = babet.json

local value = assert(J.decode([[{"answer":null}]]))
assert(value.answer == J.null)

local text = assert(J.encode({ answer = J.null }))
-- text représente {"answer":null}
```

Teste la sentinelle par identité avec `==`. C'est une table spéciale,
mais elle ne doit pas être utilisée comme une table de données.

<a id="json-empty-containers"></a>
## Objet vide, tableau vide et `as_array`

Une table Lua vide est ambiguë. Babet choisit l'objet JSON par défaut :

```lua
local J = babet.json

assert(J.encode({}) == "{}")
assert(J.encode(J.empty_array) == "[]")
assert(J.encode(J.as_array({})) == "[]")
```

`empty_array` est une sentinelle partagée destinée aux valeurs que l'on
ne souhaite pas modifier. `as_array(t)` est préférable pour un tableau
construit dynamiquement : il marque la table avec une métatable interne,
la laisse mutable et renvoie exactement la même table.

```lua
local tags = {}
-- table.insert(tags, ...) peut ne jamais être appelé

local text = assert(J.encode({ tags = J.as_array(tags) }))
-- {"tags":[]}
```

Points importants :

- `as_array` est idempotent ;
- le marquage **remplace toute métatable préexistante** sur la table ;
- la forme n'est vérifiée qu'au moment de `encode` : une table marquée
  contenant des clés chaînes ou des trous produit `nil, err` ;
- `as_array(J.null)` et `as_array(J.empty_array)` lèvent une erreur Lua ;
- seul un tableau JSON **vide** décodé reçoit automatiquement ce
  marquage. Un tableau non vide décodé puis entièrement vidé devient une
  table vide ordinaire et se ré-encode donc en `{}` ; appelle
  `as_array(t)` pour conserver `[]` dans ce cas ;
- les écritures ordinaires sur les sentinelles sont refusées. Comme pour
  toute table Lua, `rawset` contourne les métaméthodes : ne modifie pas
  les sentinelles.

<a id="json-encode-options"></a>
## Options de `encode`

La table optionnelle ne contient qu'une option interprétée :

```lua
local compact = assert(babet.json.encode({ a = 1 }))
local pretty  = assert(babet.json.encode({ a = 1 }, { indent = 4 }))
```

- `indent = 0..256` active la mise en forme avec retours à la ligne ;
- `indent = 0` n'ajoute aucun espace d'indentation, mais conserve les
  retours à la ligne de la sortie formatée ;
- option absente, `nil` ou entier négatif : sortie compacte ;
- une valeur non entière ou supérieure à `256` lève une erreur Lua ;
- les autres champs de la table d'options sont ignorés. En particulier,
  l'ancienne option documentée par erreur `pretty` n'existe pas.

<a id="json-strings"></a>
## Chaînes, UTF-8 et octets NUL

Les chaînes JSON doivent être en UTF-8 valide. Les caractères Unicode
sont conservés dans la sortie ; Babet ne force pas leur conversion en
séquences `\uXXXX`.

Les chaînes Lua peuvent contenir des octets NUL. Ils sont binary-safe
côté Lua et sont échappés conformément au JSON lors de l'encodage. Cela
vaut aussi pour les clés d'objets :

```lua
local J = babet.json
local original = "a\0b"
local text = assert(J.encode({ [original] = original }))
local back = assert(J.decode(text))
assert(back[original] == original)
```

Une chaîne ou une clé contenant une séquence UTF-8 invalide fait échouer
l'encodage avec `nil, err`. Un texte JSON contenant une chaîne UTF-8
invalide est également refusé par `decode`.

<a id="json-numbers"></a>
## Nombres

Babet préserve le sous-type Lua lorsque le JSON le permet : `42` devient
un entier Lua, tandis que `42.0` et `1e3` deviennent des flottants. À
l'encodage, un flottant Lua comme `3.0` reste un nombre JSON flottant.

`NaN`, `+Inf` et `-Inf` ne font pas partie du standard JSON et sont
refusés avec `nil, err`.

<a id="json-order"></a>
## Ordre des objets et clés dupliquées

L'ordre des membres d'un objet JSON n'a pas de signification sémantique
et ne doit pas être utilisé comme contrat. Le backend actuel les émet
généralement dans l'ordre lexicographique des clés, mais un appelant doit
comparer les données décodées, pas le texte brut, lorsque l'ordre n'est
pas imposé par un format externe.

Lors du décodage d'un objet JSON contenant plusieurs fois la même clé,
la dernière valeur remplace les précédentes.

<a id="json-errors"></a>
## Contrat d'erreur

Les erreurs de conversion ou de parsing sont renvoyées et ne lèvent pas
d'exception Lua :

```lua
local value, err = babet.json.decode("{ invalide")
if not value then
    print(err) -- préfixé par "json:"
end
```

Cela comprend notamment :

- JSON invalide, données supplémentaires après le document ou UTF-8
  invalide ;
- table mixte, à trous ou avec des clés non représentables ;
- fonction, userdata ou thread impossible à encoder ;
- `NaN` ou infinité ;
- cycle ou profondeur d'imbrication excessive.

Les erreurs d'utilisation de l'API lèvent en revanche une erreur Lua :

- mauvaise arité ;
- argument de `decode` qui n'est pas une chaîne ;
- second argument de `encode` qui n'est ni une table ni `nil` ;
- `opts.indent` non entier ou supérieur à `256` ;
- argument invalide pour `as_array`.

Les erreurs de parsing fournies par nlohmann/json indiquent la position
de l'échec, généralement sous forme de ligne et de colonne.

<a id="json-limits"></a>
## Limites

La profondeur maximale de conversion est de **1000 niveaux** dans les
deux sens. Cette limite sert également de garde-fou contre les tables
cycliques. Le module construit le document complet en mémoire : il ne
propose pas d'API de streaming.
