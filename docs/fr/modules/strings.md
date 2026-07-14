> [English](../../en/modules/strings.md) | **Français**

# `babet` strings — découpage de chaînes

Babet expose une seule fonction de manipulation de chaînes :
`babet.split`. Elle est enregistrée directement dans la table `babet`, sans
sous-namespace, pour conserver l'API historique.

## Table des matières du module

- [API](#strings-api)
- [Mode séparateur](#strings-separator)
  - [Limiter le nombre de coupes](#strings-max-splits)
- [Mode octets](#strings-bytes)
- [Chaînes binaires et octets NUL](#strings-binary)
- [Chaîne vide](#strings-empty)
- [Contrat d'erreur](#strings-errors)
- [Limites et choix de conception](#strings-limits)

<a id="strings-api"></a>
## API

```lua
local parts = babet.split(s [, sep [, max_splits]])
```

La fonction exige **entre un et trois arguments** et renvoie exactement une
valeur : une table dense indexée de `1` à `n`.

| Argument | Type et comportement |
| --- | --- |
| `s` | Chaîne Lua obligatoire. Les nombres ne sont pas convertis implicitement. Les octets NUL sont préservés. |
| `sep` | Chaîne Lua facultative. Omission ou chaîne vide : mode octets. Sinon, elle doit contenir exactement **un octet**, utilisé littéralement. |
| `max_splits` | Entier Lua facultatif, supérieur ou égal à `-1`. `-1` signifie illimité, `0` interdit toute coupe. Utilisé uniquement lorsque `sep` contient un octet. |

`nil` n'est pas une valeur de remplacement pour un argument facultatif :
`babet.split("abc", nil)` lève une erreur. Pour fournir `max_splits` en mode
octets, il faut passer explicitement `""` comme deuxième argument.

<a id="strings-separator"></a>
## Mode séparateur

Lorsque `sep` contient exactement un octet, chaque occurrence de cet octet
provoque une coupe. Le séparateur est **littéral** : il ne s'agit ni d'un
pattern Lua ni d'une expression régulière.

```lua
babet.split("a,b,c", ",")
-- { "a", "b", "c" }

babet.split("a.b.c", ".")
-- { "a", "b", "c" }  -- le point n'est pas un joker
```

Les entrées vides sont conservées, y compris en début, entre deux séparateurs
et en fin de chaîne :

```lua
babet.split(",a", ",")
-- { "", "a" }

babet.split("a,,b", ",")
-- { "a", "", "b" }

babet.split("a,", ",")
-- { "a", "" }
```

Si le séparateur n'apparaît pas, le résultat contient la chaîne entière :

```lua
babet.split("hello", ",")
-- { "hello" }
```

<a id="strings-max-splits"></a>
### Limiter le nombre de coupes

`max_splits` compte les **coupes**, pas le nombre d'éléments produits. Le reste
non découpé est placé tel quel dans le dernier élément.

```lua
babet.split("a,b,c,d", ",", 2)
-- { "a", "b", "c,d" }

babet.split("a,b,c", ",", 0)
-- { "a,b,c" }

babet.split("a,b,c", ",", -1)
-- { "a", "b", "c" }
```

Toute valeur supérieure au nombre de séparateurs disponibles produit le même
résultat que `-1`.

<a id="strings-bytes"></a>
## Mode octets

Si `sep` est omis ou vaut `""`, la chaîne est découpée octet par octet. Il
n'existe donc **aucun séparateur espace par défaut**.

```lua
babet.split("ab c")
-- { "a", "b", " ", "c" }

babet.split("abc", "")
-- { "a", "b", "c" }
```

`max_splits`, lorsqu'il est fourni dans ce mode, est toujours validé mais
n'est pas utilisé :

```lua
babet.split("abc", "", 0)
-- { "a", "b", "c" }
```

Ce mode travaille sur des **octets**, pas sur des points de code Unicode. Un
caractère UTF-8 multi-octets est donc séparé en plusieurs chaînes d'un octet :

```lua
local bytes = babet.split("é")
-- #bytes == 2 en UTF-8
-- table.concat(bytes) == "é"
```

De même, un séparateur UTF-8 multi-octets comme `"é"` est refusé, car `sep`
doit contenir zéro ou un octet. Pour découper sur une chaîne de plusieurs
octets, il faut utiliser du Lua (`string.find`, `string.gmatch`, etc.) ou une
fonction dédiée.

<a id="strings-binary"></a>
## Chaînes binaires et octets NUL

Le sujet, le séparateur et les éléments produits sont manipulés avec leur
longueur Lua exacte. Un octet NUL ne tronque donc rien :

```lua
local parts = babet.split("a\0b,c", ",")
-- { "a\0b", "c" }

local parts2 = babet.split("a\0b", "\0")
-- { "a", "b" }
```

Le contenu UTF-8 reste également intact lorsqu'il est séparé par un octet
ASCII :

```lua
babet.split("été:ok", ":")
-- { "été", "ok" }
```

<a id="strings-empty"></a>
## Chaîne vide

Deux comportements historiques différents sont conservés :

```lua
babet.split("", ",")
-- { "" }

babet.split("")
-- {}

babet.split("", "")
-- {}
```

En mode séparateur, zéro séparateur trouvé signifie un élément contenant la
chaîne entière, même si elle est vide. En mode octets, une chaîne de zéro
octet ne produit aucun élément.

<a id="strings-errors"></a>
## Contrat d'erreur

Toutes les erreurs sont des erreurs Lua levées ; `split` ne possède pas de
chemin de retour `(nil, err)`.

La fonction lève notamment dans les cas suivants :

- moins d'un ou plus de trois arguments ;
- `s` n'est pas une vraie chaîne Lua ;
- `sep` est présent mais n'est pas une vraie chaîne Lua ;
- `sep` contient plus d'un octet ;
- `max_splits` n'est pas un entier Lua ;
- `max_splits` est inférieur à `-1`.

Les conversions implicites nombre-vers-chaîne ne sont pas acceptées :

```lua
babet.split(123, ",")       -- erreur
babet.split("123", 2)       -- erreur
babet.split("a,b", ",", "1") -- erreur
```

<a id="strings-limits"></a>
## Limites et choix de conception

- Ce n'est pas un parseur CSV : aucune gestion des guillemets, échappements ou
  lignes n'est effectuée.
- Les séparateurs multi-octets et les patterns Lua ne sont pas pris en charge.
- Les entrées vides sont volontairement conservées.
- Un équivalent `join` n'est pas exposé, car `table.concat` remplit déjà ce
  rôle dans la bibliothèque standard Lua.
