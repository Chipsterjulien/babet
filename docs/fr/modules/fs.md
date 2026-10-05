> [English](../../en/modules/fs.md) | **Français**

# FS — fichiers, dossiers, chemins, recherche, copie, permissions et sommes de contrôle

Les fonctions de ce chapitre sont exposées directement dans la table globale
`babet`. Il n’existe pas de sous-table `babet.fs` : ce namespace plat est
historique et fait désormais partie de l’API stable.

Le module FS couvre :

- la vérification de l’existence et du type d’un chemin ;
- la création, l’écriture atomique et la suppression de fichiers et de dossiers ;
- le changement de répertoire courant ;
- la manipulation lexicale des chemins ;
- le listing, l’itération et la recherche récursive ;
- la copie et le déplacement d’arborescences ;
- les liens symboliques ;
- les permissions, propriétaires et groupes Unix ;
- les sommes de contrôle CRC-32, MD5, SHA et BLAKE2.

## Table des matières du module

- [Conventions générales](#fs-conventions)
- [Vue d’ensemble de l’API](#fs-api-summary)
- [Existence, type et taille](#fs-predicates)
  - [`fileExists`](#fileexists)
  - [`isFile` / `isfile`](#isfile)
  - [`isDir` / `isdir`](#isdir)
  - [`fileSize`](#filesize)
- [Répertoire courant](#fs-cwd)
  - [`currentDir`](#currentdir)
  - [`chdir`](#chdir)
- [Manipulation lexicale des chemins](#fs-paths)
  - [`getBasename`](#getbasename)
  - [`getFilename`](#getfilename)
  - [`getExtension`](#getextension)
  - [`getPath`](#getpath)
  - [`joinPath`](#joinpath)
- [Créer, supprimer, renommer et lier](#fs-actions)
  - [`touch`](#touch)
  - [`writeFileAtomic`](write-file-atomic.md)
  - [`mkdir`](#mkdir)
  - [`remove`](#remove)
  - [`rmdir`](#rmdir)
  - [`rmdirAll`](#rmdirall)
  - [`rename`](#rename)
  - [`link`](#link)
- [Lister, itérer et rechercher](#fs-list-search)
  - [`listFiles`](#listfiles)
  - [`createFileIterator`](#createfileiterator)
  - [`find`](#find)
- [Copier et déplacer](#fs-copy-move)
  - [`copy`](#copy)
  - [`copyTree`](#copytree)
  - [`moveTree`](#movetree)
- [Permissions et attributs Unix](#fs-attributes)
  - [`getMode` / `setMode`](#getmode-setmode)
  - [`getAttributes` / `setAttributes`](#getattributes-setattributes)
  - [`symlinkAttr` / `symlinkattr`](#symlinkattr)
- [Sommes de contrôle de fichiers](#fs-checksums)
- [CRC-32 en mémoire](#crc32-memory)
- [Contrat d’erreur](#fs-errors)
- [Décisions et limites](#fs-design)

<a id="fs-conventions"></a>
## Conventions générales

### Chemins

Les chemins sont des chaînes Lua. Ils peuvent être relatifs ou absolus.

Babet ne réalise pas automatiquement :

- l’expansion de `~` ;
- l’expansion de variables comme `$HOME` ;
- l’expansion des globs `*.lua` ;
- la normalisation générale de `.` et `..` dans les fonctions lexicales.

Par exemple :

```lua
local home = assert(babet.env("HOME"))
local config = babet.joinPath(home, ".config", "mon-app")
```

Un octet NUL dans un chemin est toujours refusé. Selon la fonction, une
mauvaise signature lève une erreur Lua, tandis qu’une erreur du système de
fichiers est généralement renvoyée sous la forme `(nil, err)`.

### Liens symboliques

Il n’existe pas une règle unique valable pour toutes les fonctions :

- `isFile`, `isDir`, `fileSize`, `getMode`, `getAttributes` et les checksums
  suivent un lien valide vers sa cible ;
- `remove` supprime le lien lui-même, y compris s’il est cassé ;
- `rmdir` et `rmdirAll` refusent une racine symbolique ;
- `symlinkAttr` modifie le propriétaire et le groupe du lien lui-même ;
- `listFiles`, `createFileIterator` et `find` ne descendent pas dans un lien
  symbolique vers un dossier ;
- `copyTree` et `moveTree` refusent une racine source ou destination
  symbolique, mais gèrent les liens présents à l’intérieur de l’arbre.

Chaque fonction détaille ci-dessous son comportement exact.

### Ordre des résultats

`listFiles`, `createFileIterator` et `find` suivent l’ordre fourni par le
système de fichiers. Cet ordre n’est pas trié et ne doit pas être considéré
comme stable.

Trie explicitement le résultat lorsque l’ordre compte :

```lua
local files = assert(babet.listFiles("documents", true))
table.sort(files)
```

### Valeurs de retour

La convention la plus fréquente est :

```lua
local value, err = fonction(...)
if not value then
    print(err)
end
```

Une action réussie renvoie généralement `(true, nil)`. Quelques fonctions
pures ou méthodes d’itérateur ont une forme différente ; ces exceptions sont
signalées dans leur section.

<a id="fs-api-summary"></a>
## Vue d’ensemble de l’API

### Vérifier et inspecter

| Fonction | Résultat en cas de succès |
| --- | --- |
| `babet.fileExists(path)` | `(boolean, nil)` — vrai uniquement pour un fichier régulier |
| `babet.isFile(path)` | `(boolean, nil)` — même prédicat fonctionnel que `fileExists` |
| `babet.isDir(path)` | `(boolean, nil)` — vrai pour un dossier |
| `babet.fileSize(path)` | `(integer, nil)` — taille d’un fichier régulier en octets |
| `babet.currentDir()` | `(string, nil)` — répertoire courant |
| `babet.getMode(path)` | `(integer, nil)` — mode Unix `0000..07777` |
| `babet.getAttributes(path)` | `(table, nil)` — `{mode, owner, group}` |

### Manipuler des chemins

| Fonction | Résultat en cas de succès |
| --- | --- |
| `babet.getBasename(path)` | `(string, nil)` |
| `babet.getFilename(path)` | `(string, nil)` |
| `babet.getExtension(path)` | `(string, nil)` |
| `babet.getPath(path)` | `(string, nil)` |
| `babet.joinPath(a, b, ...)` | `string` |
| `babet.joinPath({a, b, ...})` | `string` |

### Agir sur le système de fichiers

| Fonction | Résultat en cas de succès |
| --- | --- |
| `babet.touch(path)` | `(true, nil)` |
| `babet.writeFileAtomic(path, data, opts?)` | `(true, nil)` — publication binaire atomique et durable ; [chapitre détaillé](write-file-atomic.md) |
| `babet.mkdir(path)` | `(true, nil)` — récursif et idempotent |
| `babet.remove(path)` | `(true, nil)` — fichier régulier ou symlink |
| `babet.rmdir(path)` | `(true, nil)` — dossier réel et vide |
| `babet.rmdirAll(path)` | `(true, nil)` — dossier réel, suppression récursive |
| `babet.rename(source, destination)` | `(true, nil)` |
| `babet.link(target, linkpath)` | `(true, nil)` — crée un symlink |
| `babet.chdir(path)` | `(true, nil)` |

### Lister et rechercher

| Fonction | Résultat en cas de succès |
| --- | --- |
| `babet.listFiles(path, recursive?)` | `(table, nil)` |
| `babet.createFileIterator(path, recursive?)` | `(iterator, nil)` |
| `babet.find(path, opts?)` | `(table, nil)` |

### Copier et déplacer

| Fonction | Résultat en cas de succès |
| --- | --- |
| `babet.copy(source, destination)` | `(true, nil)` — un fichier |
| `babet.copyTree(source, destination, continue_on_error?)` | `(true, nil)` — un arbre |
| `babet.moveTree(source, destination)` | `(true, nil)` — un arbre |

### Modifier les attributs

| Fonction | Résultat en cas de succès |
| --- | --- |
| `babet.setMode(path, mode)` | `(true, nil)` |
| `babet.setAttributes(path, uid, gid, mode?)` | `(true, nil)` |
| `babet.symlinkAttr(path, uid, gid)` | `(true, nil)` |

<a id="fs-predicates"></a>
## Existence, type et taille

<a id="fileexists"></a>
### `babet.fileExists(path)`

Vérifie si `path` désigne un **fichier régulier**.

```lua
local exists, err = babet.fileExists("rapport.txt")
```

Résultats :

- fichier régulier : `(true, nil)` ;
- dossier, lien cassé ou chemin absent : `(false, nil)` ;
- lien valide vers un fichier régulier : `(true, nil)` ;
- véritable erreur d’inspection : `(nil, err)`.

Malgré son nom historique, `fileExists` ne répond pas « vrai » pour tous les
types de chemins. Pour un dossier, utilise `isDir`.

```lua
local is_file = assert(babet.fileExists("archive.tar"))
local is_dir  = assert(babet.isDir("sauvegardes"))
```

<a id="isfile"></a>
### `babet.isFile(path)` et `babet.isfile(path)`

`isFile` est le nom canonique. `isfile` est un alias déprécié conservé pour
compatibilité.

La fonction teste le même type de chemin que `fileExists` : un fichier
régulier, en suivant un éventuel symlink valide.

```lua
local regular, err = babet.isFile("programme.lua")
if err then
    print("Inspection impossible :", err)
elseif regular then
    print("C’est un fichier régulier")
end
```

Un chemin inexistant renvoie `(false, nil)` et non une erreur.

<a id="isdir"></a>
### `babet.isDir(path)` et `babet.isdir(path)`

`isDir` est le nom canonique. `isdir` est un alias déprécié.

```lua
local directory, err = babet.isDir("assets")
```

Résultats :

- dossier réel : `(true, nil)` ;
- lien valide vers un dossier : `(true, nil)` ;
- fichier, lien cassé ou chemin absent : `(false, nil)` ;
- erreur d’accès ou d’inspection : `(nil, err)`.

<a id="filesize"></a>
### `babet.fileSize(path)`

Renvoie la taille d’un fichier régulier en octets.

```lua
local size, err = babet.fileSize("video.mp4")
if not size then
    print("Taille inaccessible :", err)
else
    print(size, "octets")
end
```

La fonction suit un symlink valide vers un fichier. Elle refuse les dossiers
et les autres types de fichiers.

```lua
local size, err = babet.fileSize("documents")
-- size == nil ; err indique que le chemin n’est pas un fichier régulier
```

<a id="fs-cwd"></a>
## Répertoire courant

<a id="currentdir"></a>
### `babet.currentDir()`

Renvoie le répertoire de travail courant du processus.

```lua
local cwd, err = babet.currentDir()
assert(cwd, err)
print(cwd)
```

Le résultat est le chemin courant tel que fourni par le système de fichiers,
généralement absolu.

<a id="chdir"></a>
### `babet.chdir(path)`

Change le répertoire courant de tout le processus.

```lua
local previous = assert(babet.currentDir())
assert(babet.chdir("/tmp"))
print(assert(babet.currentDir()))
assert(babet.chdir(previous))
```

Le chemin est résolu vers sa forme canonique : les composants `.` et `..` et
les symlinks sont résolus avant le changement.

Le répertoire courant est partagé par tous les threads. Pour cette raison,
`chdir` est définitivement refusé dès que le premier `babet.workers.spawn()` a
été effectué, même si le worker est déjà terminé. La première tentative de
chargement GTK via `gui.available()` ou `gui.init()` déclenche la même règle,
même si elle échoue. Configure le répertoire avant ces appels ;
`babet.currentDir()` reste disponible en lecture. Voir le [contrat GUI](gui.md).

```lua
assert(babet.chdir("/srv/mon-app")) -- à faire avant tout spawn
local worker = assert(babet.workers.spawn("return true"))

local ok, err = babet.chdir("/tmp")
-- ok == nil ; err explique que chdir est interdit après workers.spawn
```

<a id="fs-paths"></a>
## Manipulation lexicale des chemins

Ces fonctions traitent uniquement des chaînes. Elles ne vérifient pas que le
chemin existe.

<a id="getbasename"></a>
### `babet.getBasename(path)`

Renvoie la dernière composante, extension comprise.

```lua
local name = assert(babet.getBasename("/var/log/app.log"))
print(name) -- app.log
```

Un chemin qui ne possède pas de dernière composante exploitable, comme `/`,
renvoie `(nil, err)`.

<a id="getfilename"></a>
### `babet.getFilename(path)`

Renvoie la dernière composante sans sa dernière extension.

```lua
print(assert(babet.getFilename("report.tar.gz"))) -- report.tar
print(assert(babet.getFilename("README")))        -- README
```

<a id="getextension"></a>
### `babet.getExtension(path)`

Renvoie la dernière extension, point compris.

```lua
print(assert(babet.getExtension("report.tar.gz"))) -- .gz
```

Un nom sans extension renvoie `(nil, err)`, pas une chaîne vide.

```lua
local ext, err = babet.getExtension("README")
-- ext == nil
```

<a id="getpath"></a>
### `babet.getPath(path)`

Renvoie le dossier parent lexical.

```lua
print(assert(babet.getPath("/var/log/app.log"))) -- /var/log
```

Un nom simple sans composante parent, par exemple `app.log`, renvoie
`(nil, err)` plutôt que `"."`.

<a id="joinpath"></a>
### `babet.joinPath(...)`

Deux formes sont acceptées :

```lua
local path = babet.joinPath("var", "lib", "mon-app", "data.db")
```

```lua
local path = babet.joinPath({ "var", "lib", "mon-app", "data.db" })
```

Il faut au moins deux segments non vides. En cas de succès, `joinPath` renvoie
**une seule valeur**, la chaîne assemblée. En cas d’échec, elle renvoie
`(nil, err)`.

Dans la forme table, Babet lit directement les entrées réellement stockées dans
la partie tableau, dans l’ordre brut `1..n`. Les métaméthodes `__len` et
`__index` ne sont pas appelées et ne peuvent donc pas fabriquer de segments.
Une entrée brute manquante est refusée au lieu d’être fournie par `__index`. Les
clés qui n’appartiennent pas à la partie tableau ne constituent pas des
segments et sont ignorées.

La fonction ne fait qu’ajuster le séparateur `/` à la jonction des segments :

```lua
print(babet.joinPath("/var/", "/log", "app.log"))
-- /var/log/app.log
```

Elle ne normalise pas les composants `.` ou `..` et ne traite pas un segment
absolu ultérieur comme un nouveau point de départ :

```lua
print(babet.joinPath("base", "..", "autre")) -- base/../autre
print(babet.joinPath("base", "/autre"))       -- base/autre
```

Ne mélange pas la forme table et les arguments séparés ; lorsque le premier
argument est une table, son contenu constitue la liste complète des segments.

<a id="fs-actions"></a>
## Créer, supprimer, renommer et lier

<a id="touch"></a>
### `babet.touch(path)`

Crée un fichier vide lorsque le chemin n’existe pas, ou met à jour la date de
dernière modification d’un chemin existant.

```lua
assert(babet.touch("cache/ready.flag"))
```

Le dossier parent doit déjà exister : `touch` ne le crée pas.

```lua
local ok, err = babet.touch("absent/sous/dossier/fichier.txt")
-- ok == nil si absent/sous/dossier n’existe pas
```

Pour créer d’abord les parents :

```lua
assert(babet.mkdir("cache/images"))
assert(babet.touch("cache/images/index.dat"))
```

Sur un chemin existant, la fonction met à jour son horodatage ; elle peut donc
également toucher un dossier, comme la commande Unix `touch`. Un symlink final
valide est suivi vers sa cible.

`touch` n’ouvre jamais un chemin existant dans un mode tronquant. Le parent et
la cible existante sont épinglés avant l’opération : si un fichier apparaît
pendant une course de création, il est repris sans perdre son contenu. Un
symlink final pendant est refusé ; Babet ne crée pas sa cible absente à travers
un chemin de lien encore mutable.

<a id="mkdir"></a>
### `babet.mkdir(path)`

Crée un dossier avec une sémantique équivalente à `mkdir -p` :

- la création est **toujours récursive** ;
- les parents manquants sont créés ;
- rappeler la fonction sur un dossier existant réussit ;
- un fichier ou un autre non-dossier bloquant le chemin produit `(nil, err)`.

```lua
assert(babet.mkdir("data/cache/images"))
-- crée data, data/cache et data/cache/images si nécessaire
```

```lua
assert(babet.mkdir("data/cache/images"))
-- succès également lorsque le dossier existe déjà
```

Il n’existe **aucune option pour désactiver la récursivité**. Pour exiger que
le parent existe déjà, vérifie-le avant l’appel :

```lua
local parent = "data/cache"
assert(babet.isDir(parent), "le parent doit déjà exister")
assert(babet.mkdir(babet.joinPath(parent, "images")))
```

Les nouveaux dossiers utilisent les permissions `0777` filtrées par l’umask
du processus. Le mode du dossier source n’entre pas en jeu.

<a id="remove"></a>
### `babet.remove(path)`

Supprime uniquement :

- un fichier régulier ;
- un lien symbolique, valide ou cassé.

```lua
assert(babet.remove("temp.txt"))
```

```lua
-- le lien est supprimé, pas sa cible
assert(babet.link("fichier-important.txt", "raccourci"))
assert(babet.remove("raccourci"))
```

La fonction refuse les dossiers, FIFO, sockets, devices et autres types
spéciaux.

```lua
local ok, err = babet.remove("mon-dossier")
-- ok == nil ; utiliser rmdir ou rmdirAll
```

<a id="rmdir"></a>
### `babet.rmdir(path)`

Supprime un **vrai dossier vide**.

```lua
assert(babet.mkdir("cache-vide"))
assert(babet.rmdir("cache-vide"))
```

La fonction refuse :

- un dossier non vide ;
- un fichier ;
- un symlink, même s’il pointe vers un dossier ou se termine par `/` ou `/.` ;
- un chemin absent.

```lua
local ok, err = babet.rmdir("dossier-non-vide")
```

<a id="rmdirall"></a>
### `babet.rmdirAll(path)`

Supprime récursivement un **vrai dossier racine** et tout son contenu.

```lua
assert(babet.rmdirAll("build-temp"))
```

La racine doit exister et être un dossier réel. Un fichier ou un symlink vers
un dossier est refusé, y compris avec un suffixe `/`, `/.` ou `/./`.

Les symlinks situés *à l’intérieur* du dossier supprimé sont supprimés comme
des entrées ; leur cible extérieure n’est pas parcourue.

```lua
local is_dir = babet.isDir("build-temp")
if is_dir then
    assert(babet.rmdirAll("build-temp"))
end
```

<a id="rename"></a>
### `babet.rename(source, destination)`

Renomme ou déplace une entrée sur le même système de fichiers.

```lua
assert(babet.rename("ancien.txt", "nouveau.txt"))
```

La fonction accepte les fichiers, dossiers et symlinks, y compris les liens
cassés. Elle ne crée pas le dossier parent de destination.

Sous Linux, elle suit la sémantique de `rename(2)` : une destination existante
peut être remplacée lorsque les types sont compatibles. Une traversée de
systèmes de fichiers échoue ; `rename` n’effectue pas de fallback copie +
suppression.

```lua
local ok, err = babet.rename("/tmp/a.txt", "/autre-montage/a.txt")
-- peut échouer avec cross-device link
```

Pour déplacer une arborescence avec fallback cross-filesystem, utilise
`moveTree`.

<a id="link"></a>
### `babet.link(target, linkpath)`

Crée toujours un **lien symbolique**, jamais un lien dur.

La cible est enregistrée exactement telle qu’elle est fournie :

```lua
assert(babet.link("../shared/config.toml", "app/config.toml"))
```

Une cible relative reste relative, et une cible inexistante est autorisée :

```lua
assert(babet.link("future-file.txt", "dangling-link"))
```

Contrairement à `touch` et `copy`, `link` crée récursivement les dossiers
parents explicites de `linkpath` :

```lua
assert(babet.link("../../data.db", "a/b/c/database"))
-- crée a/, a/b/ et a/b/c/ si nécessaire
```

Le chemin du lien ne doit pas déjà être occupé.

<a id="fs-list-search"></a>
## Lister, itérer et rechercher

Les trois API ne renvoient pas les chemins sous la même forme :

| Fonction | Forme des chemins renvoyés |
| --- | --- |
| `listFiles(root, ...)` | relatifs à `root` |
| `createFileIterator(root, ...)` | tels que produits depuis `root` : préfixés par le chemin fourni |
| `find(root, ...)` | tels que produits depuis `root` : préfixés par le chemin fourni |

<a id="listfiles"></a>
### `babet.listFiles(path, recursive?)`

Renvoie une table séquentielle contenant uniquement les fichiers réguliers.
Les dossiers ne sont jamais inclus.

#### Listing non récursif — comportement par défaut

```lua
local files, err = babet.listFiles("assets")
assert(files, err)

for _, relative_path in ipairs(files) do
    print(relative_path)
end
```

Seuls les fichiers directement contenus dans `assets` sont renvoyés.

#### Listing récursif

```lua
local files, err = babet.listFiles("assets", true)
assert(files, err)

table.sort(files)
for _, relative_path in ipairs(files) do
    print(relative_path)
end
```

Les chemins sont relatifs à la racine demandée :

```text
logo.png
icons/open.png
icons/close.png
```

et non :

```text
assets/logo.png
assets/icons/open.png
```

#### Symlinks

- un symlink valide vers un fichier régulier est inclus sous le nom du lien ;
- un lien cassé est ignoré ;
- un symlink vers un dossier n’est ni inclus comme fichier, ni parcouru ;
- une boucle de symlinks de dossiers ne provoque donc pas de récursion infinie.

```lua
local files = assert(babet.listFiles("collection", true))
-- un lien collection/externe -> /autre/dossier n’est pas suivi
```

Le second argument est facultatif et vaut `false` par défaut. Lorsqu’il est
présent, il doit être un booléen Lua strict : nombres et chaînes ne sont pas
convertis. La fonction accepte exactement un ou deux arguments.

<a id="createfileiterator"></a>
### `babet.createFileIterator(path, recursive?)`

Crée un véritable userdata paresseux possédant deux méthodes :

- `iterator:next()` — `(chemin, nil)`, `(nil, err)` ou `(nil, nil)` à la fin ;
- `iterator:close()` — libère explicitement l’itérateur natif.

Seul l’itérateur de dossier est créé au départ. L’arbre avance d’une entrée à
chaque appel à `next()` : un gros parcours n’est plus copié dans un
`std::vector` avant le premier résultat et la mémoire ne croît plus avec le
nombre total de fichiers.

#### Non récursif

```lua
local iterator, err = babet.createFileIterator("assets")
assert(iterator, err)

while true do
    local path, next_err = iterator:next()
    assert(not next_err, next_err)
    if path == nil then
        break
    end
    print(path) -- assets/logo.png, etc.
end

iterator:close()
```

#### Récursif

```lua
local iterator = assert(babet.createFileIterator("assets", true))
while true do
    local path, next_err = iterator:next()
    assert(not next_err, next_err)
    if not path then break end
    print(path)
end
iterator:close()
```

L’ouverture de la racine peut toujours échouer immédiatement et renvoie
`(nil, err)`. Une erreur rencontrée plus tard pendant l’inspection ou
l’avancement du dossier est différée jusqu’à l’appel à `next()` correspondant,
qui renvoie `(nil, err)`. La fin normale possède le résultat distinct
`(nil, nil)`.

Comportement des symlinks :

- lien valide vers un fichier régulier : inclus sous le chemin du lien ;
- lien cassé, boucle ou cible inaccessible : ignoré ;
- lien vers un dossier : non parcouru ;
- véritable erreur d’inspection d’une entrée ou d’avancement : renvoyée par
  `next()`.

Le code existant qui ne lit que la première valeur reste compatible, mais il ne
peut pas distinguer la fin d’une erreur de parcours différée ; le nouveau code
doit contrôler la seconde valeur. Après `close()`, appeler `next()` lève une
erreur Lua. Oublier `close()` n’est pas fatal : le garbage collector finit par
libérer l’objet. L’argument facultatif `recursive` doit être un booléen Lua
strict et le constructeur accepte exactement un ou deux arguments.

<a id="find"></a>
### `babet.find(path, opts?)`

Recherche récursivement les entrées d’un dossier et renvoie une table de
chemins.

Les deux appels suivants sont équivalents :

```lua
local entries = assert(babet.find("src"))
local entries = assert(babet.find("src", nil))
```

Sans option, fichiers **et** dossiers sont inclus. La racine elle-même n’est
pas incluse.

#### Options

| Option | Type | Défaut | Effet |
| --- | --- | --- | --- |
| `type` | string | aucun filtre | `"f"` pour fichiers, `"d"` pour dossiers |
| `glob` | string | absent | glob borné sur le nom complet, sensible à la casse |
| `iglob` | string | absent | glob borné sur le nom complet, casse ASCII ignorée |
| `path_glob` | string | absent | glob borné sur le chemin complet renvoyé, sensible à la casse |
| `path_iglob` | string | absent | glob borné sur le chemin complet renvoyé, casse ASCII ignorée |
| `name` | string | absent | regex RE2 sur le nom complet, sensible à la casse |
| `iname` | string | absent | regex RE2 sur le nom complet, insensible à la casse |
| `path` | string | absent | regex RE2 recherchée dans le chemin complet |
| `mindepth` | integer | `0` | profondeur minimale incluse |
| `maxdepth` | integer | sans limite pratique | profondeur maximale incluse |
| `xdev` | boolean | `false` | ne descend pas dans un dossier dont `st_dev` diffère de celui de la racine |

Toutes les options présentes sont combinées avec un **ET logique**. Un motif
vide agit comme un filtre absent, conformément au comportement historique des
champs regex.

#### Filtres glob sûrs

Utilise les champs glob pour les recherches ordinaires sur les noms de
fichiers, en particulier lorsque le motif peut provenir d’une personne non
fiable :

```lua
local lua_files = assert(babet.find("src", {
    type = "f",
    glob = "*.lua",
}))

local images = assert(babet.find("assets", {
    type = "f",
    iglob = "*.jpg",
}))
```

Le langage glob est volontairement réduit :

- `*` : zéro ou plusieurs octets sauf `/` ;
- `**` : zéro ou plusieurs octets, y compris `/` ;
- `?` : exactement un octet sauf `/` ;
- `\x` : octet littéral `x`.

La correspondance est ancrée sur la totalité du nom ou du chemin. Les crochets,
accolades et extensions glob du shell n’ont aucune signification particulière
et sont comparés littéralement. Chaque motif est limité à 4096 octets. Le
moteur n’utilise aucun backtracking récursif : son travail reste borné de façon
polynomiale par la taille du motif et du candidat.

`path_glob` et `path_iglob` comparent le chemin complet renvoyé en utilisant
`/` comme séparateur. Il faut employer `**` lorsqu’un joker doit traverser des
dossiers :

```lua
local tests = assert(babet.find(".", {
    type = "f",
    path_glob = "**/tests/**/*.lua",
}))
```

Les variantes insensibles à la casse ne replient que les lettres ASCII. Les
octets UTF-8 hors ASCII sont comparés exactement, ce qui rend le comportement
indépendant de la locale du processus.

#### Expressions régulières RE2 bornées

Les champs historiques `name`, `iname` et `path` utilisent désormais le moteur
RE2 lié statiquement. `name` et `iname` correspondent au nom complet :

```lua
local images = assert(babet.find("assets", {
    type = "f",
    iname = ".*\\.(png|jpg|jpeg)$",
}))
```

`path` effectue une recherche regex partielle dans le chemin complet :

```lua
local tests = assert(babet.find(".", {
    type = "f",
    path = "/tests/",
}))
```

Chaque regex est limitée à 4096 octets et compilée avec un budget mémoire RE2
de 1 Mio. La correspondance reste linéaire : lorsque le cache DFA atteint son
budget, RE2 utilise son NFA borné au lieu d’un backtracking exponentiel. Babet
active le mode Latin-1 de RE2 afin que chaque octet d’un chemin Linux reste
traitable, y compris pour un nom qui n’est pas un UTF-8 valide. `iname`
désactive la sensibilité à la casse dans RE2, sans consulter la locale du
processus.

RE2 refuse volontairement les constructions qui nécessitent du backtracking ou
un état non régulier, notamment les références arrière et les assertions de
regard avant/arrière. Un tel motif fait échouer tout l’appel avec `(nil, err)`.
Utilise les globs sûrs pour les filtres simples et RE2 lorsqu’un regroupement,
une alternative, une classe de caractères ou une répétition bornée est vraiment
utile.

#### Limiter la profondeur

La profondeur `0` correspond aux enfants directs de la racine :

```lua
local direct_children = assert(babet.find("src", {
    maxdepth = 0,
}))
```

Les enfants d’un sous-dossier sont à la profondeur `1` :

```lua
local one_level_below = assert(babet.find("src", {
    mindepth = 1,
    maxdepth = 1,
}))
```

`mindepth` filtre uniquement les résultats ; les dossiers moins profonds sont
tout de même traversés pour atteindre les niveaux demandés.

#### Arborescences vivantes et dossiers disparus

`babet.find()` parcourt l'arborescence avec une pile explicite d'itérateurs de
dossiers. Avant d'ouvrir un dossier enfant, Babet avance l'itérateur du parent
vers le frère suivant. Si le dossier disparaît dans cet intervalle, son
`ENOENT` reste local à ce sous-arbre disparu : la recherche l'ignore et reprend
depuis le parent déjà positionné.

La même règle s'applique lorsqu'un dossier en cours d'énumération disparaît :
ce cadre devenu inutilisable est retiré et le parcours reprend dans son parent.
Ce comportement vaut avec ou sans `xdev`, conserve l'ordre préfixe pour les
entrées encore présentes et ne transforme pas les autres erreurs en succès
partiel. Les erreurs de permission, d'entrée/sortie, les boucles de symlinks et
toute erreur autre qu'`ENOENT` font toujours échouer l'appel complet avec
`(nil, err)`.

#### Rester sur le système de fichiers de la racine

`xdev = true` mémorise le champ Linux `st_dev` de la racine réellement
parcourue, puis empêche la descente dans tout dossier appartenant à un autre
périphérique. L'option est un booléen strict et vaut `false` par défaut : son
absence ne change donc aucun parcours historique.

```lua
local local_entries = assert(babet.find("/srv/application", {
    xdev = true,
}))
```

Comme avec `find -xdev`, le point de montage étranger lui-même reste visible et
peut correspondre à `type`, `name`, `path`, aux globs et aux limites de
profondeur. Seuls ses enfants sont élagués. Par exemple, cette recherche peut
renvoyer le dossier monté `/srv/application/cache`, mais aucun fichier placé
sous ce montage :

```lua
local local_logs = assert(babet.find("/srv/application", {
    xdev = true,
    type = "f",
    path_iglob = "**/*.log",
    maxdepth = 8,
}))
```

La comparaison porte sur le périphérique de la racine, même lorsque le chemin
de racine est un symlink valide vers un dossier. Les symlinks rencontrés dans
l'arborescence ne sont toujours pas suivis. La comparaison est strictement
fondée sur `st_dev`, comme `find -xdev` : un sous-volume Btrfs peut donc être
élagué, tandis qu'un bind mount du même système de fichiers conserve le même
`st_dev` et n'est pas élagué.

Si un candidat disparaît pendant l'inspection supplémentaire de `xdev`, la
même règle limitée à `ENOENT` s'applique et le sous-arbre disparu est ignoré.
Une erreur lors de l'inspection de la racine, ou toute autre erreur lors de
l'inspection d'un point de descente, fait échouer l'appel avec `(nil, err)`.

#### Symlinks et erreurs

Le parcours ne descend pas dans les symlinks de dossiers. Les tests de type
suivent néanmoins une cible valide : un symlink vers un fichier peut donc
correspondre à `type = "f"`, et un symlink vers un dossier peut apparaître
avec `type = "d"` sans que son contenu soit parcouru.

Une regex invalide ou trop longue, un glob invalide ou trop long, ou une erreur de parcours
fait échouer tout l’appel avec `(nil, err)`. Il n’existe pas de mode « continuer
malgré les erreurs » pour `find`.

<a id="fs-copy-move"></a>
## Copier et déplacer

<a id="copy"></a>
### `babet.copy(source, destination)`

Copie un seul fichier avec `std::filesystem::copy_file` et écrase une
destination fichier existante.

```lua
assert(babet.copy("config/default.toml", "config/local.toml"))
```

Le dossier parent de destination doit déjà exister :

```lua
assert(babet.mkdir("backup/config"))
assert(babet.copy("config/app.toml", "backup/config/app.toml"))
```

Comportement important :

- un symlink source valide est suivi et donne un nouveau fichier régulier ;
- un symlink destination valide est suivi : la cible du lien est écrasée ;
- un dossier source ou destination n’est pas accepté ;
- les permissions ordinaires du fichier source sont copiées selon la
  sémantique du système ; owner, group et horodatages ne sont pas garantis ;
- l’opération ne bénéficie pas du confinement renforcé de `copyTree`.

Utilise `copyTree` pour une arborescence ou lorsque la destination doit être
protégée contre les redirections par symlink.

<a id="copytree"></a>
### `babet.copyTree(source, destination, continue_on_error?)`

Copie récursivement un dossier source dans un dossier destination.

```lua
assert(babet.copyTree("site", "backup/site"))
```

#### Valeur par défaut de `continue_on_error`

Le troisième argument est facultatif et vaut **`true` par défaut**. Lorsqu’il
est présent, il doit être un booléen Lua strict ; la fonction accepte exactement
deux ou trois arguments.

Cela signifie qu’en cas d’erreur limitée à une entrée :

1. un avertissement est écrit sur `stderr` ;
2. la copie tente de poursuivre avec les autres entrées ;
3. l’appel final renvoie `(nil, "completed with warnings ...")`.

Le succès partiel n’est donc jamais présenté comme un succès total.

```lua
local ok, err = babet.copyTree("source", "destination")
if not ok then
    print(err) -- peut signaler des warnings après une copie partielle
end
```

#### Mode strict

Passe explicitement `false` pour arrêter la copie à la première erreur :

```lua
local ok, err = babet.copyTree("source", "destination", false)
assert(ok, err)
```

Passe explicitement `true` lorsque tu souhaites rendre le choix visible dans
le code :

```lua
local ok, err = babet.copyTree("source", "destination", true)
```

#### Destination et fusion

- la destination est créée récursivement si elle n’existe pas ;
- si elle existe, le contenu est fusionné ;
- les fichiers réguliers existants sont remplacés ;
- un symlink déjà présent dans la destination, comme composant intermédiaire
  ou comme fichier final, est refusé ;
- les deux arborescences doivent être disjointes : la destination ne peut être
  ni la source elle-même, ni un de ses descendants, ni un de ses ancêtres ;
- la racine source et la racine destination ne doivent pas être des symlinks.

#### Métadonnées

Lorsqu’un nouveau fichier est créé :

- les bits ordinaires `rwx` du fichier source sont conservés ;
- `setuid`, `setgid` et sticky sont retirés ;
- le nouvel inode appartient à l’utilisateur et au groupe déterminés par le
  système pour le processus appelant ;
- les horodatages ne sont pas conservés.

Les dossiers créés utilisent `0777` filtré par l’umask. Le mode, owner, group
et les dates des dossiers sources ne sont pas reproduits.

#### Symlinks internes

Les liens symboliques présents dans l’arbre sont recréés :

- les cibles relatives restent identiques ;
- les liens cassés restent des liens cassés ;
- une cible absolue située à l’intérieur de la source est réécrite pour viser
  l’élément correspondant dans la destination ;
- une cible absolue extérieure reste inchangée.

Les symlinks de dossiers ne sont jamais parcourus comme des dossiers.

<a id="movetree"></a>
### `babet.moveTree(source, destination)`

Déplace récursivement une arborescence.

```lua
assert(babet.moveTree("staging/site", "public/site"))
```

#### Chemin rapide

Lorsque la destination n’existe pas, que le déplacement reste sur le même
filesystem et qu’aucun lien absolu interne ne doit être réécrit, Babet renomme
l’arbre complet. L’opération est alors rapide et conserve les inodes et leurs
métadonnées.

#### Fusion ou traversée de filesystem

Lorsque la destination existe, que le déplacement traverse un filesystem, ou
qu’un lien interne doit être réécrit, Babet utilise un fallback entrée par
entrée :

- scan complet de la source avant la première modification ;
- création des dossiers de destination ;
- création des symlinks de destination ;
- déplacement des autres entrées ;
- suppression des seuls liens scannés, puis des dossiers devenus vides,
  du plus profond jusqu’à la racine.

Le nettoyage final ne supprime jamais récursivement le contenu restant. Un
fichier ajouté après le scan reste dans la source : le dossier non vide fait
échouer le déplacement, même si d’autres entrées ont déjà été transférées.
Les identités des liens et dossiers sont revérifiées avant leur suppression ;
cela ne rend pas l’ensemble de l’opération transactionnel face aux mutations
concurrentes.

Dans ce fallback, un fichier copié vers un nouvel inode conserve ses bits
`rwx` ordinaires, mais pas les bits spéciaux, l’owner, le group ou les dates.
Les dossiers créés suivent l’umask.

Entre deux filesystems, seuls les fichiers réguliers bénéficient du fallback
copie puis suppression. Une FIFO est refusée sans attendre un écrivain. Sur
un même filesystem, son déplacement par renommage reste possible.

Avant une ouverture en lecture pour copier, Babet vérifie l'inode au moyen
d'un descripteur Linux `O_PATH`, qui n'ouvre pas les périphériques pour leurs
opérations d'entrée/sortie. Seul un fichier régulier est ensuite ouvert via
`/proc/self/fd`, en conservant le même inode même si son chemin a été remplacé.
Cette étape partagée par `copyTree` et le fallback de `moveTree` nécessite
procfs ; son échec refuse la copie sans publier le fichier de destination.

Après une copie EXDEV, `moveTree` garde l'inode source épinglé et compare son
identité avec le chemin source avant la suppression. Un remplacement détecté
provoque une erreur en conservant le remplaçant et la copie déjà publiée. Ce
contrôle ne rend pas `lstat` puis `unlink` atomiques : il reste nécessaire
d'éviter les modifications concurrentes de l'arbre pendant le déplacement.

#### Garde-fous

- la source doit être un vrai dossier, pas un symlink ;
- la destination racine ne doit pas être un symlink ;
- la destination ne peut être ni la source, ni un descendant, ni un ancêtre
  de la source, y compris après résolution des chemins ;
- un symlink préexistant dans la destination de fusion est refusé ;
- les liens internes utilisent les mêmes règles de réécriture que `copyTree`.

`moveTree` réduit les risques d’état partiel en scannant l’arbre avant de le
modifier et en préparant les symlinks en premier. Il n’est toutefois pas une
transaction générale : une erreur survenant après plusieurs déplacements de
fichiers peut laisser une partie des entrées dans la source et une partie dans
la destination. Le message d’erreur doit alors être traité comme nécessitant
une vérification manuelle des deux arbres.

<a id="fs-attributes"></a>
## Permissions et attributs Unix

Les modes sont des entiers. Lua ne possède pas de littéral `0o755` : utilise
une chaîne octale lorsque l’API l’accepte, ou `tonumber("755", 8)`.

```lua
local mode_755 = tonumber("755", 8)
```

<a id="getmode-setmode"></a>
### `babet.getMode(path)` et `babet.setMode(path, mode)`

`getMode` renvoie les permissions ordinaires et les bits spéciaux dans
l’intervalle `0000..07777`.

```lua
local mode, err = babet.getMode("run.sh")
assert(mode, err)
print(string.format("%04o", mode))
```

`setMode` accepte deux formes :

```lua
assert(babet.setMode("run.sh", "755"))
```

```lua
assert(babet.setMode("run.sh", tonumber("755", 8)))
```

Une chaîne est interprétée en base 8. Un nombre est pris comme valeur entière
directe. Les valeurs non entières, négatives ou supérieures à `07777` sont
refusées.

Les bits spéciaux peuvent être demandés explicitement :

```lua
assert(babet.setMode("outil", "4755"))
local mode = assert(babet.getMode("outil"))
assert(mode == tonumber("4755", 8))
```

Ces fonctions suivent un symlink vers sa cible.

<a id="getattributes-setattributes"></a>
### `babet.getAttributes(path)`

Renvoie uniquement les trois champs suivants :

```lua
local attrs, err = babet.getAttributes("fichier.txt")
assert(attrs, err)

print(attrs.mode)  -- integer 0000..07777
print(attrs.owner) -- UID
print(attrs.group) -- GID
```

La table ne contient ni taille, ni mtime, ni type de fichier.

La fonction suit un symlink vers sa cible.

### `babet.setAttributes(path, uid, gid, mode?)`

Modifie le propriétaire et le groupe, puis éventuellement le mode.

Sans mode :

```lua
local attrs = assert(babet.getAttributes("fichier.txt"))
assert(babet.setAttributes(
    "fichier.txt",
    attrs.owner,
    attrs.group
))
```

Avec mode :

```lua
assert(babet.setAttributes(
    "fichier.txt",
    1000,
    1000,
    tonumber("640", 8)
))
```

Contrairement à `setMode`, le quatrième argument doit être un **entier** ; une
chaîne comme `"640"` n’est pas acceptée.

Validation avant modification :

- UID et GID doivent être des entiers non négatifs dans la plage de `uid_t`
  et `gid_t` ;
- le mode doit être compris entre `0` et `07777`.

POSIX ne fournit pas d’opération atomique combinant `chown` et `chmod`. Babet
résout le chemin une seule fois, épingle cette cible, puis effectue la lecture
des métadonnées, le `chown`, le `chmod` éventuel et tout rollback sur le même
inode. Un remplacement du chemin pendant l’appel ne peut donc pas rediriger la
phase suivante vers une nouvelle cible. Si le `chmod` échoue après un `chown`
réussi, Babet tente de restaurer l’owner, le group et le mode d’origine ; une
restauration incomplète est signalée dans le message d’erreur.

L’appel suit un symlink final, mais la cible sélectionnée au début reste
épinglée même si le lien est modifié concurremment. Les droits nécessaires
dépendent du système et de l’identité du processus ; changer l’owner exige
généralement les privilèges root.

<a id="symlinkattr"></a>
### `babet.symlinkAttr(path, uid, gid)` et `babet.symlinkattr(...)`

`symlinkAttr` est le nom canonique. `symlinkattr` est un alias déprécié.

La fonction applique `lchown` et ne suit donc pas un lien symbolique :

```lua
assert(babet.symlinkAttr("raccourci", 1000, 1000))
```

Elle modifie l’UID et le GID du lien lui-même, pas ceux de sa cible. Elle ne
modifie pas le mode.

UID et GID sont validés comme dans `setAttributes`.

<a id="fs-checksums"></a>
## Sommes de contrôle de fichiers

Toutes les fonctions suivantes lisent le fichier en flux et renvoient une
chaîne hexadécimale en minuscules :

| Fonction | Algorithme | Longueur hex | Usage conseillé |
| --- | --- | ---: | --- |
| `babet.crc32sum(path)` | CRC-32 IEEE | 8 | détection d’erreurs accidentelles uniquement |
| `babet.md5sum(path)` | MD5 | 32 | compatibilité legacy, pas sécurité |
| `babet.sha1sum(path)` | SHA-1 | 40 | compatibilité legacy, pas sécurité |
| `babet.sha256sum(path)` | SHA-256 | 64 | intégrité cryptographique courante |
| `babet.sha384sum(path)` | SHA-384 | 96 | intégrité cryptographique |
| `babet.sha512sum(path)` | SHA-512 | 128 | intégrité cryptographique |
| `babet.sha3_256sum(path)` | SHA3-256 | 64 | intégrité cryptographique |
| `babet.sha3_384sum(path)` | SHA3-384 | 96 | intégrité cryptographique |
| `babet.sha3_512sum(path)` | SHA3-512 | 128 | intégrité cryptographique |
| `babet.blake2b512sum(path)` | BLAKE2b-512 | 128 | intégrité cryptographique |
| `babet.blake2s256sum(path)` | BLAKE2s-256 | 64 | intégrité cryptographique |

Exemple :

```lua
local digest, err = babet.sha256sum("release.tar.gz")
assert(digest, err)
print(digest)
```

Vérification avec une valeur attendue :

```lua
local expected = "..."
local actual = assert(babet.sha256sum("release.tar.gz"))
assert(actual == expected, "checksum incorrect")
```

Contrat commun :

- seuls les fichiers réguliers sont acceptés ;
- un symlink valide vers un fichier régulier est suivi ;
- les dossiers, FIFO, sockets, devices et pseudo-fichiers non réguliers sont
  refusés ;
- une erreur de lecture renvoie `(nil, err)` et ne produit jamais le digest
  trompeur d’un contenu partiel ;
- le contenu n’est pas chargé entièrement en mémoire.

CRC-32, MD5 et SHA-1 ne doivent pas servir à authentifier des données face à
un attaquant. Pour un nouveau contrôle d’intégrité, préfère SHA-256, SHA-3 ou
BLAKE2.

<a id="crc32-memory"></a>
## CRC-32 en mémoire

### `babet.crc32(data)`

Calcule le CRC-32 d’une chaîne Lua déjà en mémoire. Les chaînes Lua étant
binary-safe, les octets NUL sont acceptés.

```lua
print(babet.crc32("abc")) -- 352441c2
print(babet.crc32(""))    -- 00000000
```

```lua
local bytes = "a\0b\0c"
local digest = babet.crc32(bytes)
```

En cas de succès, cette fonction renvoie une seule chaîne, sans seconde valeur
`nil`. Un mauvais nombre ou type d’arguments lève une erreur Lua.

<a id="fs-errors"></a>
## Contrat d’erreur

### Erreurs Lua levées

Une mauvaise signature ou un type incompatible lève généralement une erreur
Lua :

```lua
babet.fileSize({})       -- erreur Lua
babet.mkdir("a", true)  -- erreur Lua : mkdir accepte exactement un argument
```

Les chemins contenant un octet NUL sont refusés avant tout appel système.

### Erreurs renvoyées

Les échecs du système de fichiers sont normalement renvoyés :

```lua
local ok, err = babet.remove("absent.txt")
if not ok then
    print(err)
end
```

Les prédicats `fileExists`, `isFile` et `isDir` traitent un chemin simplement
absent comme une réponse normale `(false, nil)`. Une vraie erreur d’inspection
reste `(nil, err)`.

### Opérations partielles

- `copyTree` en mode continuation peut copier certaines entrées puis renvoyer
  une erreur de synthèse indiquant des warnings ;
- `moveTree` peut laisser un état partagé entre source et destination si une
  erreur survient tard dans le fallback entrée par entrée ;
- `setAttributes` tente un rollback si la phase `chmod` échoue après `chown`,
  mais signale explicitement si ce rollback n’est pas complet.

<a id="fs-design"></a>
## Décisions et limites

- **Namespace plat historique** : `babet.fileExists`, pas
  `babet.fs.fileExists`.
- **Noms canoniques** : `isFile`, `isDir` et `symlinkAttr`. Les formes
  `isfile`, `isdir` et `symlinkattr` sont dépréciées.
- **`mkdir` toujours récursif** : l’API ne possède pas de variante
  non récursive.
- **`copy` pour un fichier, `copyTree` pour un arbre** : aucune surcharge
  implicite selon le type de la source.
- **Le glob est un filtre de `find`, pas une fonction autonome** : utilise
  `glob`, `iglob`, `path_glob` ou `path_iglob` dans `babet.find`.
- **Pas de tri automatique** : appelle `table.sort` lorsqu’un ordre stable est
  nécessaire.
- **Pas de préservation complète des métadonnées dans les copies** : les
  permissions ordinaires des fichiers sont prises en charge, mais pas les
  propriétaires, groupes, dates ou modes des dossiers.
- **Pas d’I/O asynchrone** : utilise les [workers](workers.md) pour paralléliser
  des traitements indépendants.
