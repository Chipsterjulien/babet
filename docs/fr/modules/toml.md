> [English](../../en/modules/toml.md) | **Français**

# `babet.toml` - décodage TOML

Le module `babet.toml` s'appuie sur **toml++ 3.4.0** et décode des
documents conformes à **TOML 1.0.0**. Les extensions situées hors du profil TOML 1.0 et prises en charge
optionnellement par cette version de toml++ sont désactivées.

La v1 expose uniquement le décodage d'une chaîne. Elle ne lit pas un
fichier à ta place et ne fournit pas d'encodeur.

## Table des matières du module

- [API](#toml-api)
- [Correspondance des types](#toml-types)
  - [Entiers et flottants](#toml-numbers)
- [Chaînes, UTF-8 et clés](#toml-strings)
- [Arrays et tables](#toml-containers)
  - [Ambiguïté des conteneurs vides](#toml-empty-containers)
- [Dates et heures](#toml-dates)
- [Ordre et informations perdues](#toml-order)
- [Contrat d'erreur](#toml-errors)
- [Limites](#toml-limits)
- [Non exposé en v1](#toml-not-exposed)

<a id="toml-api"></a>
## API

| Fonction | Contrat |
| --- | --- |
| `babet.toml.decode(text)` | Renvoie `table, nil` ou `nil, err` |

`decode` exige exactement **un argument**, qui doit être une véritable
chaîne Lua. Un nombre n'est pas converti implicitement en texte et tout
argument supplémentaire est refusé.

Pour lire un fichier :

```lua
local file = assert(io.open("config.toml", "rb"))
local text = assert(file:read("*a"))
file:close()

local config, err = babet.toml.decode(text)
if not config then
    error(err)
end
```

Un document TOML possède toujours une table à sa racine. Une chaîne vide
ou composée uniquement de commentaires produit donc une table Lua vide.

<a id="toml-types"></a>
## Correspondance des types

| TOML | Lua |
| --- | --- |
| string | string |
| integer signé sur 64 bits | integer Lua |
| float | number Lua |
| boolean | boolean |
| array | table séquentielle `1..n` |
| table, inline table ou dotted table | table à clés chaînes |
| array of tables | table séquentielle de tables |
| local date/time et date-time | string normalisée |

TOML ne possède pas de valeur équivalente à `nil` ou au `null` JSON.

<a id="toml-numbers"></a>
### Entiers et flottants

Les entiers TOML occupent la plage signée complète sur 64 bits, de
`math.mininteger` à `math.maxinteger`, et sont conservés exactement. Les
notations décimale, hexadécimale, octale et binaire produisent toutes un
entier Lua. Une valeur hors de cette plage est une erreur de parsing.

Les flottants deviennent des nombres Lua. TOML autorise également les
valeurs spéciales suivantes :

```lua
local values = assert(babet.toml.decode([[
positive = inf
negative = -inf
invalid  = nan
]]))

assert(values.positive == math.huge)
assert(values.negative == -math.huge)
assert(values.invalid ~= values.invalid) -- propriété de NaN
```

Comme en Lua, `NaN` ne se compare égal à aucune valeur, pas même à lui-même.

<a id="toml-strings"></a>
## Chaînes, UTF-8 et clés

Le document TOML doit être en UTF-8 valide. Les chaînes basiques,
littérales et multilignes sont décodées avant d'être renvoyées à Lua : les
séquences d'échappement TOML deviennent les caractères correspondants.

Les chaînes Lua sont binary-safe. Une séquence TOML comme `\u0000` peut
donc produire un octet NUL dans une valeur **ou dans une clé citée**, sans
troncature :

```lua
local value = assert(babet.toml.decode([[
"a\u0000b" = "x\u0000y"
]]))

assert(value["a\0b"] == "x\0y")
```

Un octet NUL brut injecté dans le texte TOML n'est pas traité comme une fin
de chaîne C : le parseur voit l'intégralité du buffer et refuse le document.
Il en va de même pour une séquence UTF-8 invalide.

Les clés nues, citées et pointées suivent les règles TOML :

```lua
local value = assert(babet.toml.decode([[
"a.b" = 1
site."google.com" = true
physical.color = "orange"
]]))

assert(value["a.b"] == 1)              -- point littéral dans une clé citée
assert(value.site["google.com"] == true)
assert(value.physical.color == "orange")
```

Une clé citée vide (`""`) est valide en TOML et devient la clé Lua `""`.

<a id="toml-containers"></a>
## Arrays et tables

Les arrays TOML deviennent des séquences Lua indexées à partir de `1`. TOML
1.0 autorise les arrays hétérogènes :

```lua
local value = assert(babet.toml.decode([[
items = [1, "two", true, { name = "three" }]
]]))

assert(value.items[1] == 1)
assert(value.items[2] == "two")
assert(value.items[3] == true)
assert(value.items[4].name == "three")
```

Les sections, inline tables et dotted keys aboutissent toutes à des tables
Lua ordinaires. La syntaxe d'origine n'est pas conservée.

<a id="toml-empty-containers"></a>
### Ambiguïté des conteneurs vides

Un array vide `[]` et une table vide `{}` deviennent tous deux une table Lua
vide :

```lua
local value = assert(babet.toml.decode([[
a = []
b = {}
]]))

assert(type(value.a) == "table" and next(value.a) == nil)
assert(type(value.b) == "table" and next(value.b) == nil)
```

Aucune métatable ni sentinelle ne mémorise leur type TOML d'origine. Cette
perte d'information est sans conséquence pour la lecture courante d'une
configuration, mais elle empêche un round-trip fidèle.

<a id="toml-dates"></a>
## Dates et heures

TOML distingue quatre types temporels. Lua n'ayant pas de type date natif,
Babet les convertit en chaînes :

| Type TOML | Forme Lua |
| --- | --- |
| local date | `YYYY-MM-DD` |
| local time | `HH:MM:SS[.fraction]` |
| local date-time | `YYYY-MM-DDTHH:MM:SS[.fraction]` |
| offset date-time | `YYYY-MM-DDTHH:MM:SS[.fraction]Z` ou avec `+/-HH:MM` |

```lua
local value = assert(babet.toml.decode([[
date = 1979-05-27
time = 07:32:00.1234
local_dt = 1979-05-27T07:32:00
utc_dt = 1979-05-27T07:32:00Z
]]))
```

La valeur temporelle est conservée, mais sa **graphie** peut être
normalisée par toml++ : séparateur canonique, fraction ou notation UTC. Les
commentaires et l'orthographe exacte du document ne sont pas disponibles.
Après conversion, une date TOML est également indiscernable d'une chaîne
TOML contenant le même texte.

<a id="toml-order"></a>
## Ordre et informations perdues

Une table TOML n'a pas d'ordre sémantique garanti et une table Lua ne doit
pas être parcourue en supposant l'ordre du fichier. Le décodage ne conserve
pas :

- les commentaires ;
- l'ordre lexical des clés ;
- les espaces et retours à la ligne ;
- le choix entre section, inline table et dotted keys ;
- la graphie d'origine des nombres et des dates ;
- le type d'un conteneur vide.

Le module est donc destiné à **lire les valeurs**, pas à éditer puis réécrire
un document TOML à l'identique.

<a id="toml-errors"></a>
## Contrat d'erreur

Une erreur de syntaxe ou de valeur TOML renvoie :

```lua
local value, err = babet.toml.decode("answer = ")
assert(value == nil)
print(err) -- toml: ... (line ..., col ...)
```

Le message est préfixé par `toml:` et contient la ligne et la colonne
indiquées par toml++.

Sont notamment renvoyés sous forme de `(nil, err)` :

- syntaxe invalide ou clé redéfinie ;
- entier hors de la plage signée 64 bits ;
- UTF-8 invalide ou caractère de contrôle interdit ;
- extension non disponible dans le profil TOML 1.0 utilisé.

Les erreurs d'utilisation de l'API lèvent en revanche une erreur Lua :

- argument absent ;
- argument qui n'est pas une chaîne ;
- argument supplémentaire.

<a id="toml-limits"></a>
## Limites

Le document complet est parsé et converti en mémoire. Il n'existe pas d'API
de streaming, de `decode_file`, de validation de schéma ni d'accès aux
positions source des valeurs. La conversion récursive protège la pile Lua ;
une profondeur impossible à convertir est renvoyée comme une erreur `toml:`.

<a id="toml-not-exposed"></a>
## Non exposé en v1

- `babet.toml.encode` ;
- `babet.toml.decode_file` ;
- options de parsing ou activation des extensions hors TOML 1.0 ;
- nœuds conservant commentaires, ordre et positions source ;
- sentinelles distinguant arrays et tables vides ;
- validation de schéma.
