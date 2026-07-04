> [English](../../en/modules/strings.md) | **Français**

# `babet` strings — manipulation de chaînes

Une seule fonction : découper une chaîne par séparateur en table.
Précède la convention par sous-namespace, vit directement sur
`babet`.

## Pourquoi

Découper une chaîne par délimiteur est l'une des opérations string
les plus courantes, et la stdlib Lua n'en a pas par défaut
(`string.gmatch` marche mais demande d'échapper les patterns). Une
fonction dédiée est plus découvrable et évite le piège du pattern
escaping.

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.split(s [, sep [, max_splits]])` | `table` (array) des sous-chaînes |

- `s` : la chaîne à découper. Binaire-safe : les octets NUL sont
  préservés.
- `sep` : séparateur optionnel — **un seul caractère**, littéral
  (pas de pattern). Une chaîne vide, ou l'omission de l'argument,
  bascule en **mode caractères** : `s` est découpée en caractères
  individuels. Plus d'un caractère → lève.
- `max_splits` : nombre maximal de coupes, optionnel (défaut `-1` =
  illimité). Le reste non découpé atterrit dans le dernier élément ;
  `0` renvoie donc `{ s }`. Ignoré en mode caractères.

Si `sep` n'apparaît pas dans `s`, le résultat est une table à un
élément contenant `s` en entier.

Cas limites de la chaîne vide (comportement historique, figé et
testé) :

- `babet.split("", sep)` renvoie `{ "" }` — une entrée vide, pas une
  table vide.
- `babet.split("")` (mode caractères) renvoie `{}` — table vide.

## Exemple rapide

```lua
local parts = babet.split("a,b,c,d", ",")
-- parts == { "a", "b", "c", "d" }

local one = babet.split("hello", ",")
-- one == { "hello" }

-- Mode caractères (sep omis ou vide)
local chars = babet.split("abc")
-- chars == { "a", "b", "c" }

-- Nombre de coupes borné : le reste dans le dernier élément
local kv = babet.split("clé,val,ue", ",", 1)
-- kv == { "clé", "val,ue" }
```

## Contrat d'erreur

- **Mauvais type d'argument** → lève via `luaL_error`.
- **`sep` de plus d'un caractère** → lève.
- **`max_splits` non entier ou < -1** → lève.
- Sinon, réussit toujours.

## Décisions de design

- **Séparateur littéral, pas un pattern Lua**. Le cas courant est
  le découpage de données CSV-like, où on veut que `.` signifie un
  vrai point, pas "n'importe quel caractère". Si on a besoin de
  pattern matching, on retombe sur `string.gmatch`.
- **Les entrées vides sont préservées**. `"a,,b"` se découpe en
  `{"a", "", "b"}`. Les consommateurs qui veulent filtrer les
  strings vides le font en une ligne de Lua.
- **`split("", sep)` renvoie `{ "" }`**. C'est la conséquence
  naturelle de la règle "entrées vides préservées" (zéro séparateur
  trouvé → un élément, la chaîne entière — qui se trouve être
  vide). Comportement observable depuis la v1, donc figé plutôt que
  changé.
- **Mode caractères quand `sep` est omis ou vide**. Il n'y a pas de
  séparateur par défaut : sans séparateur, la seule interprétation
  cohérente d'un découpage est caractère par caractère. Précision :
  le découpage se fait par **octets**, pas par points de code
  Unicode — un caractère UTF-8 multi-octets sera éclaté.

## Hors v1

- Découpage basé pattern (avec règles d'échappement). Utilise
  `string.gmatch` si nécessaire.
- Séparateurs multi-caractères.
- Miroir `joinTable(t, sep)` — `table.concat` existe déjà dans la
  stdlib.
