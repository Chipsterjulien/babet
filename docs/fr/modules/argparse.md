> [English](../../en/modules/argparse.md) | **Français**

# `argparse` — arguments de ligne de commande

`argparse` est un module Lua pur embarqué dans Babet. Il construit un
parseur déclaratif pour les flags, les options à valeur et les arguments
positionnels :

```lua
local argparse = require("argparse")
local parser = argparse("mon-script", "Description facultative")
```

Le module ne fait ni `print` ni `os.exit`. Il renvoie l'aide et les erreurs
au script, qui décide comment les présenter et quel code de sortie utiliser.

## Table des matières du module

- [Chargement et métadonnées](#argparse-loading)
- [API](#argparse-api)
- [Déclarer des flags et des options](#argparse-declare-options)
- [Déclarer des positionnels](#argparse-positionals)
- [Table `opts`](#argparse-opts)
  - [Champs communs](#argparse-opts-common)
  - [Champs réservés aux valeurs](#argparse-opts-values)
  - [Destination](#argparse-destination)
- [Source des arguments](#argparse-source)
  - [Table globale `arg`](#argparse-global-arg)
  - [Array explicite](#argparse-explicit-array)
- [Formes reconnues](#argparse-forms)
- [Valeurs par défaut, choix et conversion](#argparse-defaults)
- [Résultats de `parse`](#argparse-results)
  - [Succès normal](#argparse-result-success)
  - [Aide intégrée](#argparse-result-help)
  - [Erreur utilisateur](#argparse-result-user-error)
  - [Erreur de programmation](#argparse-result-programming-error)
- [Exemple complet](#argparse-example)
- [Texte produit par `get_usage`](#argparse-usage)
- [Limites de la version actuelle](#argparse-limits)

<a id="argparse-loading"></a>
## Chargement et métadonnées

```lua
local argparse = require("argparse")

print(argparse._VERSION)      -- "babet argparse 1.1.0"
print(argparse._DESCRIPTION)  -- description en anglais
```

`require("argparse")` renvoie une table appelable. Le constructeur accepte
zéro, un ou deux arguments :

```lua
argparse()                         -- programme affiché : "prog"
argparse("outil")                  -- nom du programme
argparse("outil", "Description") -- nom et description
```

`prog` et `description` doivent être des chaînes lorsqu'ils sont fournis.
Un argument supplémentaire ou un mauvais type lève une erreur Lua : il
s'agit d'une erreur de programmation, pas d'une erreur de ligne de commande.

<a id="argparse-api"></a>
## API

| Méthode | Résultat | Rôle |
| --- | --- | --- |
| `parser:flag(spec [, opts])` | `parser` | Déclare un flag sans valeur. |
| `parser:option(spec [, opts])` | `parser` | Déclare une option qui consomme une valeur. |
| `parser:argument(name [, opts])` | `parser` | Déclare un argument positionnel. |
| `parser:parse([src])` | `res, err` | Parse `src` ou la table globale `arg`. |
| `parser:get_usage()` | chaîne | Génère le texte d'aide. |

Les méthodes du builder sont chaînables :

```lua
local parser = argparse("copie")
    :flag("-v --verbose")
    :option("-o --output")
    :argument("source")
```

Les arités sont strictes. Par exemple,
`parser:option("-o", {}, "extra")` et `parser:get_usage(true)` lèvent une
erreur Lua.

<a id="argparse-declare-options"></a>
## Déclarer des flags et des options

`spec` est une seule chaîne contenant un ou plusieurs noms séparés par des
espaces :

```lua
parser:flag("-v")
parser:flag("--verbose")
parser:flag("-v --verbose")
parser:option("-o --output")
```

Chaque nom doit :

- commencer par un ou deux tirets ;
- contenir au moins un caractère après les tirets ;
- ne pas contenir `=` ;
- ne pas être dupliqué dans la même spec ni dans le parseur.

Les noms suivants sont réservés et ne peuvent pas être déclarés :

- `-` : traité comme un positionnel littéral ;
- `--` : termine le parsing des options ;
- `-h` et `--help` : aide intégrée.

Un nom à trois tirets comme `---verbose` est également refusé.

Toutes les validations sont effectuées avant de modifier le parseur. Si une
erreur du builder est interceptée par `pcall`, aucune option ni aucun alias
partiel n'est conservé.

<a id="argparse-positionals"></a>
## Déclarer des positionnels

```lua
parser:argument("input")
parser:argument("output", { required = false })
```

Le nom doit être une chaîne non vide, sans espace et sans tiret initial.
Les positionnels sont attribués strictement de gauche à droite.

Un positionnel est requis par défaut. Il devient optionnel si :

- `required = false` est indiqué ; ou
- une valeur `default` est fournie sans préciser `required`.

Tous les positionnels requis doivent précéder les positionnels optionnels.
Le builder refuse donc ce cas ambigu :

```lua
parser
    :argument("facultatif", { required = false })
    :argument("requis") -- erreur Lua
```

<a id="argparse-opts"></a>
## Table `opts`

`opts` doit être une table ou `nil`. Les champs inconnus et les champs dont
le type est incorrect lèvent immédiatement une erreur Lua. Cela permet de
détecter un nom mal orthographié comme `hlep` au lieu de `help`.

<a id="argparse-opts-common"></a>
### Champs communs

| Champ | Type | Effet |
| --- | --- | --- |
| `help` | chaîne | Texte ajouté par `get_usage()`. |
| `default` | toute valeur Lua | Valeur utilisée lorsque l'élément est absent. |
| `dest` | chaîne non vide | Clé utilisée dans la table résultat. |
| `required` | booléen | Exige la présence de l'élément. |

Ces quatre champs sont acceptés par `flag`, `option` et `argument`.

<a id="argparse-opts-values"></a>
### Champs réservés aux valeurs

| Champ | Type | Effet |
| --- | --- | --- |
| `choices` | array dense de chaînes | Autorise uniquement certaines valeurs brutes. |
| `convert` | fonction | Convertit la chaîne brute en une valeur Lua. |

`choices` et `convert` sont acceptés par `option` et `argument`, mais pas par
`flag`, puisqu'un flag ne consomme aucune valeur.

Le builder copie l'array `choices`. Une modification ultérieure de la table
fournie ne change donc pas le parseur.

<a id="argparse-destination"></a>
### Destination

Sans `dest`, la destination est :

1. le premier nom long sans `--`, s'il existe ;
2. sinon le premier nom court sans son premier `-`.

```lua
parser:option("-o --output") -- destination : "output"
parser:flag("-v")            -- destination : "v"
```

Une destination doit être unique dans tout le parseur. Les destinations
`help` et `usage` sont réservées au résultat de l'aide intégrée.

```lua
parser:flag("-q", { dest = "quiet" })
```

<a id="argparse-source"></a>
## Source des arguments

<a id="argparse-global-arg"></a>
### Table globale `arg`

Sans argument, `parse()` lit la table globale `arg` aux indices `1`, `2`,
et ainsi de suite jusqu'au premier trou :

```lua
local result, err = parser:parse()
```

Les indices `0` et négatifs sont ignorés. `parse(nil)` est équivalent à
`parse()`.

Chaque valeur rencontrée doit être une chaîne. Si `arg` n'est pas une table,
le parseur utilise une liste vide.

<a id="argparse-explicit-array"></a>
### Array explicite

Pour les tests ou une source construite par le programme :

```lua
local result, err = parser:parse({ "-v", "input.txt" })
```

La table doit être un array dense indexé de `1` à `n`, sans trou, sans clé
supplémentaire et composé uniquement de chaînes. Une source invalide est une
erreur de parsing et renvoie `(nil, err)` ; elle ne lève pas d'exception.

<a id="argparse-forms"></a>
## Formes reconnues

Une option à valeur accepte :

```text
--long valeur
--long=valeur
-s valeur
-s=valeur
```

Une valeur inline vide est valide :

```lua
parser:parse({ "--output=" }) -- output == ""
```

Les options restent actives après un positionnel tant que `--` n'a pas été
rencontré :

```text
input.txt --verbose
```

`--` termine le parsing des options. Tous les tokens suivants deviennent des
positionnels, même s'ils commencent par `-` :

```lua
parser:parse({ "--", "-5" })
```

Avant `--`, un token comme `-5` est interprété comme un nom d'option. Pour
un nombre négatif fourni comme valeur d'une option, aucun séparateur n'est
nécessaire :

```lua
parser:parse({ "--count", "-5", "input.txt" })
```

Le token suivant une option à valeur est toujours consommé littéralement,
même s'il ressemble à une option ou s'il vaut `--` :

```lua
parser:parse({ "--output", "--verbose" })
-- output == "--verbose" ; le flag verbose n'est pas activé
```

Le token isolé `-` est un positionnel. Les options répétées sont acceptées :
la dernière valeur gagne. Un flag répété reste simplement à `true`.

Les formes suivantes ne sont pas prises en charge :

- options courtes agglomérées, par exemple `-abc` pour trois flags ;
- valeur courte collée, par exemple `-ofile.txt` ;
- positionnels variadiques.

Un nom déclaré littéralement `-abc` reste toutefois une option normale si la
spec contient exactement ce nom ; il n'est jamais décomposé.

<a id="argparse-defaults"></a>
## Valeurs par défaut, choix et conversion

L'ordre appliqué à une valeur fournie par l'utilisateur est :

1. contrôle de `choices` sur la chaîne brute ;
2. appel de `convert` avec cette chaîne.

```lua
parser:option("-n --count", {
    choices = { "1", "2", "3" },
    convert = tonumber,
})
```

Les éléments de `choices` sont toujours des chaînes. Si la valeur brute ne
figure pas dans la liste, `parse()` renvoie `(nil, err)` sans appeler le
convertisseur.

Un convertisseur peut renvoyer :

- toute valeur non `nil`, y compris `false`, pour réussir ;
- `nil` pour échouer avec le message générique `invalid value` ;
- `nil, "raison"` pour fournir une raison ;
- lever une erreur, qui est interceptée et devient `conversion error`.

Les valeurs `default` sont des valeurs Lua déjà prêtes : elles ne sont ni
contrôlées par `choices` ni passées à `convert`. Elles gardent leur type et,
pour une table, leur identité. Une option `required = true` reste requise
même si un `default` est présent.

Pour un flag :

- absent, il vaut `default` si ce champ est défini, sinon `false` ;
- présent, il vaut toujours `true`.

Une option ou un positionnel absent avec un défaut `nil` n'ajoute pas de clé
observable dans la table résultat, conformément au comportement des tables
Lua.

<a id="argparse-results"></a>
## Résultats de `parse`

<a id="argparse-result-success"></a>
### Succès normal

```lua
local result, err = parser:parse()
-- result : table
-- err    : nil
```

La table est indexée par les destinations déclarées.

<a id="argparse-result-help"></a>
### Aide intégrée

Avant `--`, `-h` ou `--help` arrête immédiatement le parsing et renvoie :

```lua
{
    help = true,
    usage = "...",
}, nil
```

Les options requises, les positionnels manquants et les tokens qui suivent
ne sont pas vérifiés. Après `--`, `-h` et `--help` sont de simples
positionnels.

L'aide est un succès et n'est pas ajoutée à une table de résultat normale.
Les destinations `help` et `usage` sont donc réservées pour éviter toute
ambiguïté dans le code appelant.

<a id="argparse-result-user-error"></a>
### Erreur utilisateur

Les erreurs de ligne de commande renvoient `(nil, message)` :

```text
unknown option '--bad'
option '--output' requires a value
flag '-v' does not take a value
missing required option '--output'
missing required argument 'input'
argument 'mode': invalid choice 'other'
option '--count': invalid value
unexpected argument 'extra'
```

`parse()` intercepte les erreurs levées par `convert`. Une valeur utilisateur
ne fait donc pas remonter l'exception du convertisseur.

<a id="argparse-result-programming-error"></a>
### Erreur de programmation

Le constructeur et le builder lèvent une erreur Lua pour :

- une mauvaise arité ;
- un type incorrect ;
- une spec vide ou inutilisable ;
- un nom ou une destination réservé ;
- un nom ou une destination dupliqué ;
- un champ `opts` inconnu ;
- un array `choices` invalide ;
- un positionnel requis placé après un positionnel optionnel.

La mauvaise arité de `parse` est également une erreur de programmation.
En revanche, une table `src` mal formée renvoie `(nil, err)`.

<a id="argparse-example"></a>
## Exemple complet

```lua
local argparse = require("argparse")

local parser = argparse("convert", "Convertit un fichier.")
    :flag("-v --verbose", { help = "Plus de détails" })
    :option("-o --output", { default = "out.txt" })
    :option("-n --count", {
        choices = { "1", "2", "3" },
        convert = tonumber,
        default = 1,
    })
    :argument("input")

local args, err = parser:parse()
if args and args.help then
    print(args.usage)
    return
end
if not args then
    io.stderr:write("erreur : ", err, "\n")
    io.stderr:write(parser:get_usage(), "\n")
    os.exit(2)
end

print(args.input, args.output, args.count, args.verbose)
```

<a id="argparse-usage"></a>
## Texte produit par `get_usage`

`get_usage()` renvoie une chaîne et n'écrit rien. Les titres et le message de
l'aide intégrée sont fixes et en anglais : `Usage`, `Arguments`, `Options` et
`show this help`. Il n'existe pas encore d'API de traduction, de largeur de
colonne ou de groupes visuels.

Le texte affiche les positionnels et les aides déclarées, mais n'ajoute pas
automatiquement les valeurs par défaut, les choix ni le caractère requis des
options.

<a id="argparse-limits"></a>
## Limites de la version actuelle

Ne sont pas exposés :

- les sous-commandes ;
- les positionnels variadiques (`nargs`) ;
- les groupes mutuellement exclusifs ;
- les options répétables accumulées dans un array ;
- les options courtes agglomérées ;
- la personnalisation ou la localisation du texte d'aide ;
- une option permettant de désactiver l'aide intégrée.
