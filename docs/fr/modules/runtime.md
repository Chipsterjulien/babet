# Contexte de lancement et ressources

Disponible depuis Babet 2.35.0.

`babet.runtimeInfo()` renvoie `table, nil`. C'est une copie indépendante.

| Champ | Script | Dossier | Application générée |
| --- | --- | --- | --- |
| `mode` | `"file"` | `"directory"` | `"embedded"` |
| `projectDir` | dossier absolu du script | dossier absolu du projet | `nil` |
| `scriptPath` | chemin absolu du script | chemin absolu de `main.lua` | `"main.lua"` |
| `executablePath` | chemin du runtime | chemin du runtime | chemin de l'application |

Les chemins sont capturés au lancement et ne suivent pas le répertoire courant.
Ce sont des informations de localisation, pas une preuve d'identité après un
renommage. Les workers héritent de ce contexte. Un hôte C d'embedding utilise
`mode="host"`, avec les champs inconnus absents ; ses workers peuvent connaître
le dossier configuré par l'hôte.

## Ressources embarquées

- `babet.embedded.read(nom)` → `octets, nil` ou `nil, erreur`.
- `babet.embedded.list()` → tableau trié de noms, puis `nil`, ou `nil, erreur`.

Ces fonctions exigent une application créée avec `-c` / `--create-exe` ; elles
ne cherchent jamais de remplacement sur disque. Les noms sont relatifs à la
racine du ZIP, sensibles à la casse et utilisent `/`. La liste contient les
fichiers, dont `main.lua`, sans les entrées de répertoire. Une ressource absente
renvoie `nil, erreur`. La lecture préserve tous les octets : NUL, BOM, fins de
ligne et fichiers vides. Elle utilise l'image réellement exécutée, via
`/proc/self/exe`, même après le remplacement de son chemin.

Limites : 16 Mio décompressés par fichier ; 16 Mio au total pour les noms listés,
terminateurs compris. Un gros fichier peut être présent dans l'archive sans
être lisible par cette API.

```lua
local info = assert(babet.runtimeInfo())
local css
if info.mode == 'embedded' then
    css = assert(babet.embedded.read('assets/style.css'))
else
    local f = assert(io.open(info.projectDir .. '/assets/style.css', 'rb'))
    css = f:read('a')
    f:close()
end
```

## Globales strictes

`babet.strict()` ou `babet.strict(true)` active une erreur lors de la lecture
d'une globale absente. `babet.strict(false)` désactive ce contrôle. Retour :
`true, nil`, ou `nil, erreur` si `_G` possède une métatable étrangère, qui n'est
jamais remplacée. Les écritures restent autorisées ; une valeur `nil` équivaut
à une absence. Utiliser `rawget(_G, 'nom')` pour une recherche facultative.
Chaque état Lua doit activer le contrôle, y compris les workers. Il ne concerne
pas les autres tables, n'analyse pas statiquement le code et n'est pas une
protection de sécurité. Aucune nouvelle option CLI n'est introduite.

## Retours multiples et arité

L'arité des API existantes reste stricte. Lua transmet tous les résultats d'un
appel placé en dernier argument : `f(babet.getPath(x))` peut donc transmettre
deux arguments. Utiliser `f((babet.getPath(x)))` pour ne transmettre que le
premier. Pour traiter l'erreur, préférer `local path, err = babet.getPath(x)`,
vérifier `path`, puis appeler `f(path)`. Les `nil` supplémentaires ne sont pas
ignorés implicitement.
