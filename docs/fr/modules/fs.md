> [English](../../en/modules/fs.md) | **Français**

# `babet` fs — système de fichiers

Un ensemble plat d'opérations système de fichiers exposées
directement sur `babet` (pas de sous-namespace, précède la
convention). Couvre les besoins quotidiens que `os.*` et `io.*` de
Lua ne gèrent pas : listing récursif, copie avec attributs,
hashing, manipulation de chemins, attributs, liens.

## Pourquoi

`io` et `os` de Lua te donnent `open`, `rename`, `remove`, et c'est
à peu près tout. Tout ce qui va au-delà — lister un dossier, copie
récursive, calculer un hash, interroger mtime — demande des
programmes externes ou du FFI bas niveau. `babet` rassemble ça
dans un set unique de fonctions qui se comportent de manière
cohérente (chemins en string, erreurs en `(nil, "...")`).

Tous les chemins sont acceptés en string. L'expansion du tilde
(`~/x`) n'est **pas** automatique — l'appelant doit résoudre
`$HOME` lui-même si besoin. Les fonctions n'expansent jamais les
globs ; pour filtrer, utilise `babet.find` avec une regex
`name`/`iname`/`path`.

## API — Existence, type, attributs

| Fonction                                     | Renvoie                                                                                                                               |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `babet.fileExists(path)`                     | `boolean`                                                                                                                             |
| `babet.isFile(path)`                         | `boolean` (true seulement pour fichiers réguliers)                                                                                    |
| `babet.isDir(path)`                          | `boolean`                                                                                                                             |
| `babet.fileSize(path)`                       | `integer` octets \| `(nil, err)`                                                                                                      |
| `babet.getAttributes(path)`                  | `table` avec **`mode`, `owner`, `group`** (uniquement) \| `(nil, err)`                                                     |
| `babet.setAttributes(path, uid, gid, mode?)` | `(true, nil)` \| `(nil, err)` — set owner/group, optionnellement le mode                                                              |
| `babet.symlinkAttr(path, uid, gid)`          | `(true, nil)` \| `(nil, err)` — change owner/group du lien **lui-même** (lchown, ne suit pas le symlink) ; pendant de `setAttributes` |
| `babet.getMode(path)`                        | `integer` octal \| `(nil, err)`                                                                                                       |
| `babet.setMode(path, mode)`                  | `(true, nil)` \| `(nil, err)` — `mode` est un integer (utilise `0x1ed` pour `0755`, ou construis-le avec `tonumber("755", 8)`)        |

> Canonique : camelCase pour les composés Babet (`isFile`, `isDir`,
> `symlinkAttr`), minuscules pour les noms hérités de POSIX (`mkdir`,
> `chdir`, `touch`...). Les anciens noms `isfile`, `isdir` et
> `symlinkattr` restent des alias **dépréciés** des mêmes fonctions.

## API — Création, suppression, déplacement

| Fonction                 | Renvoie                                                                                   |
| ------------------------ | ----------------------------------------------------------------------------------------- |
| `babet.touch(path)`      | `(true, nil)` \| `(nil, err)` — crée le fichier ou met à jour mtime                       |
| `babet.mkdir(path)`      | `(true, nil)` \| `(nil, err)` — **toujours récursif** (`mkdir -p` natif), voir ci-dessous |
| `babet.rmdir(path)`      | `(true, nil)` \| `(nil, err)` — seulement dossiers vides                                  |
| `babet.rmdirAll(path)`   | `(true, nil)` \| `(nil, err)` — récursif                                                  |
| `babet.remove(path)`     | `(true, nil)` \| `(nil, err)` — fichier ou symlink                                        |
| `babet.rename(old, new)` | `(true, nil)` \| `(nil, err)`                                                             |
| `babet.chdir(path)`      | `(true, nil)` \| `(nil, err)`                                                             |

> `chdir` mute le répertoire courant de TOUT le processus : il est
> interdit dès qu'un `workers.spawn` a eu lieu (`(nil, err)`,
> définitif). Voir la note dans [sys](sys.md).

| Fonction                       | Renvoie                                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------------------ |
| `babet.currentDir()`           | `string` (absolu)                                                                                |
| `babet.link(target, linkpath)` | `(true, nil)` \| `(nil, err)` — crée un lien **symbolique** (toujours ; pas de liens durs en v1) |

### `mkdir` en détail

`babet.mkdir(path)` garantit que le dossier existe à la fin de
l'appel :

- **Toujours récursif** : les parents manquants sont créés en une
  seule fois (`mkdir -p` natif — il n'y a **pas** d'option à passer,
  contrairement à ce qu'une ancienne version de cette page indiquait).
- **Idempotent** : si le dossier (ou un symlink vers un dossier)
  existe déjà, succès silencieux.
- **Erreur claire** si un non-dossier bloque le chemin — un fichier
  au chemin cible ou au milieu de celui-ci : `(nil, err)` avec
  « Not a directory ».

```lua
-- crée data/, data/cache/ et data/cache/img/ d'un coup
assert(babet.mkdir("data/cache/img"))

-- le rappeler ne coûte rien : le dossier existe déjà, succès
assert(babet.mkdir("data/cache/img"))

-- un fichier bloque le chemin -> erreur propre
babet.touch("bloqueur")
local r, err = babet.mkdir("bloqueur/sous")
-- r == nil, err contient "Not a directory"
```

> Signature héritée : un second paramètre booléen existe encore
> (`mkdir(path, ignore_if_exists)`) mais il est **déconseillé** : sur
> Linux, son seul effet observable est de transformer l'erreur « un
> symlink pendant occupe le chemin » en succès silencieux… sans rien
> créer. Ne l'utilise pas.

## API — Manipulation de chemins

Ces fonctions opèrent sur des *strings* de chemin — elles ne
touchent pas le système de fichiers.

| Fonction                   | Renvoie                                             | Exemple                            |
| -------------------------- | --------------------------------------------------- | ---------------------------------- |
| `babet.getBasename(path)`  | `string` \| `(nil, err)` — dernière composante      | `"/etc/hostname"` → `"hostname"`   |
| `babet.getPath(path)`      | `string` \| `(nil, err)` — dossier parent (dirname) | `"/etc/hostname"` → `"/etc"`       |
| `babet.getFilename(path)`  | `string` \| `(nil, err)` — basename sans extension  | `"report.tar.gz"` → `"report.tar"` |
| `babet.getExtension(path)` | `string` \| `(nil, err)` — extension finale         | `"report.tar.gz"` → `".gz"`        |

## API — Listing et recherche

| Fonction                         | Renvoie                                                  |
| -------------------------------- | -------------------------------------------------------- |
| `babet.listFiles(path, recursive?)` | `(table, nil)` \| `(nil, err)` — fichiers réguliers ; `recursive` (booléen, défaut `false`) descend dans les sous-dossiers |
| `babet.find(path, opts?)`           | **`(table, nil)`** \| `(nil, err)` — table des chemins correspondants (voir opts ci-dessous)                              |
| `babet.createFileIterator(path)`    | **`(iterator, nil)`** \| `(nil, err)` — userdata avec `:next()` et `:close()`                                             |

**`find` renvoie une table de chemins**, pas une fonction : on
l'itère avec `ipairs`, pas avec `for x in ...`. Toujours **récursif**
(borne la profondeur avec `mindepth`/`maxdepth`). `opts` accepte :

- `name = "..."` — **regex ECMAScript** (pas un glob shell) testée
  sur le nom de fichier seul. Ex. `name = ".*%.lua$"` en Lua
  s'écrit `name = ".*\\.lua$"`.
- `iname = "..."` — comme `name`, insensible à la casse.
- `path = "..."` — regex ECMAScript testée sur le chemin complet.
- `type = "f"` / `"d"` — restreint aux fichiers ou aux dossiers.
- `mindepth = N` / `maxdepth = N` — bornes de profondeur
  (entiers ; un non-entier lève, cf. contrat).

`createFileIterator` rend un **userdata** à piloter à la main :

```lua
local it = assert(babet.createFileIterator("/etc"))
while true do
    local entry = it:next()   -- chemin suivant, ou nil à la fin
    if not entry then break end
    print(entry)
end
it:close()                    -- libère (sinon au GC)
```

## API — Copie

| Fonction                          | Renvoie                                  |
| --------------------------------- | ---------------------------------------- |
| `babet.copy(src, dst)`            | `(true, nil)` \| `(nil, err)` — écrase si dst existe |
| `babet.copyTree(src, dst, continue_on_error?)` | `(true, nil)` \| `(nil, err)` — récursif |
| `babet.moveTree(src, dst)`        | `(true, nil)` \| `(nil, err)`            |

`copy(src, dst)` prend **exactement deux arguments**, aucune
option (une ancienne version de cette page annonçait `preserve` /
`overwrite` : ils n'existent pas ; `copy` écrase la destination si
elle existe).

`copyTree(src, dst, continue_on_error?)` : le troisième argument
est un **booléen** (défaut `false`). À `true`, les erreurs par
entrée sont journalisées sur stderr et la copie continue au lieu
de s'arrêter à la première.

## API — Hashes et checksums

Empreintes du contenu des fichiers. Résultat en **string hex
minuscule** sauf mention contraire. Note le suffixe `sum` — ce
sont les noms enregistrés dans `babet.*`.

| Fonction                    | Algorithme          | Notes                                                                                 |
| --------------------------- | ------------------- | ------------------------------------------------------------------------------------- |
| `babet.crc32sum(path)`      | CRC-32 (IEEE 802.3) | **Non cryptographique**. Pour intégrité / détection d'erreur accidentelle uniquement. |
| `babet.md5sum(path)`        | MD5                 | Legacy. Ne pas utiliser pour la sécurité.                                             |
| `babet.sha1sum(path)`       | SHA-1               | Legacy. Ne pas utiliser pour la sécurité.                                             |
| `babet.sha256sum(path)`     | SHA-256             |                                                                                       |
| `babet.sha384sum(path)`     | SHA-384             |                                                                                       |
| `babet.sha512sum(path)`     | SHA-512             |                                                                                       |
| `babet.sha3_256sum(path)`   | SHA3-256            |                                                                                       |
| `babet.sha3_384sum(path)`   | SHA3-384            |                                                                                       |
| `babet.sha3_512sum(path)`   | SHA3-512            |                                                                                       |
| `babet.blake2b512sum(path)` | BLAKE2b-512         |                                                                                       |

Chaque renvoie `string` (hex) ou `(nil, err)`. Le fichier est
streamé, pas chargé entièrement en RAM. Les fichiers non-réguliers
(dossiers, sockets, …) sont refusés avec `(nil, "<algo>: not a
regular file")`.

MD5 et SHA-1 sont exposés pour la compatibilité (Git, systèmes
legacy) — ne pas les utiliser pour de nouveaux usages
cryptographiques. **CRC-32 est encore plus loin du cryptographique**
: un attaquant peut produire des collisions trivialement. À utiliser
pour de l'intégrité / détection de changement, jamais pour de
l'authentification.

## API — Checksums en mémoire

Calcule un hash d'octets déjà en mémoire, sans aller-retour par un
fichier temporaire. Binary-safe (les NUL intégrés sont autorisés).

| Fonction            | Renvoie                                |
| ------------------- | -------------------------------------- |
| `babet.crc32(data)` | `string` — 8 caractères hex minuscules |

Ne peut pas échouer à l'exécution (calcul pur). Les mauvais types
d'argument lèvent via `luaL_error`. Comme `crc32sum`, **non
cryptographique**.

## Exemples rapides

```lua
-- Prédicats
if babet.isDir("/etc") and babet.fileExists("/etc/hostname") then
    print("taille :", babet.fileSize("/etc/hostname"))
end

-- Manipulation de chemins (string pur)
local base = babet.getBasename("/var/log/syslog.1")  -- "syslog.1"
local dir  = babet.getPath("/var/log/syslog.1")      -- "/var/log"
local ext  = babet.getExtension("/var/log/syslog.1") -- ".1"

-- Listing récursif
for _, entry in ipairs(assert(babet.find("/var/log",
        { name = ".*\\.log$", type = "f" }))) do
    print(entry)
end

-- Copie avec attributs
babet.copyTree("./src", "/tmp/backup")

-- Hash d'une tarball de release
local sha, err = babet.sha256sum("/tmp/babet-1.7.0.tar.gz")
if sha then print("SHA256 :", sha) end

-- Check d'intégrité rapide (NON cryptographique, mais rapide)
local crc = babet.crc32sum("/tmp/babet-1.7.0.tar.gz")
print("CRC32 :", crc)                -- ex. "a1b2c3d4"

-- CRC32 en mémoire sur des octets arbitraires (binary-safe, NUL OK)
print(babet.crc32("abc"))         -- "352441c2"
print(babet.crc32(""))            -- "00000000"

-- Owner et permissions
local mode_755 = tonumber("755", 8)  -- octal -> integer
assert(babet.setMode("/srv/myapp/run.sh", mode_755))
-- en root seulement :
-- assert(babet.setAttributes("/srv/myapp", 1000, 1000))
```

## Contrat d'erreur

- Toutes les fonctions suivent la convention `(nil, err)` en cas
  d'échec runtime (fichier inexistant, permission refusée, etc.).
- Les mauvais **types** d'argument lèvent via `luaL_error`.
- **`setAttributes(path, uid, gid)`** rejette les UIDs/GIDs négatifs
  et les valeurs au-dessus du max `uid_t`/`gid_t` (typiquement
  `2^32 - 1`). Sans ce check de borne haute, une valeur au-dessus
  de la limite serait silencieusement tronquée — pire cas vers
  UID 0 (root). Même logique que le module [`user`](user.md).
- Sécurité des chemins : `copy`, `copyTree`, `moveTree` utilisent
  `lexically_relative()` et des guards `is_within()` composant par
  composant pour empêcher des évasions par symlink hors de
  l'arborescence de destination. Voir [`security`](../security.md).

## Décisions de design

- **Namespace plat** : `fileExists` plutôt que `fs.exists`,
  `getAttributes` plutôt que `fs.attr.get`. Raison purement
  historique — ces fonctions précèdent la convention par module.
  Stable maintenant ; renommer casserait tous les scripts.
- **`get*` / `set*` pour les attributs de chemin**
  (`getMode`/`setMode`, `getAttributes`/`setAttributes`) mais des
  verbes nus pour les actions FS (`remove`, `touch`, `mkdir`). Les
  paires get/set existent parce que les deux directions sont
  nécessaires ; les autres sont des opérations unidirectionnelles.
- **La manipulation de chemins est séparée de l'accès FS**.
  `getBasename`, `getPath`, etc. n'opèrent que sur des strings —
  elles ne stat pas le chemin. Utilise `fileExists` si tu veux
  savoir si le chemin existe réellement.
- **Les hashes ont un suffixe `sum`** pour matcher les outils Unix
  standard (`md5sum`, `sha256sum`, etc.). Découvrable pour qui
  est familier de la ligne de commande.
- **`copy` est mono-fichier, `copyTree` est récursif**. Lua n'a
  pas la surcharge de fonctions par type, donc les séparer évite
  l'ambiguïté "est-ce que `copy('dir', 'dir')` voulait dire
  récursif ?".

## Hors v1

- Glob matching en fonction standalone (`babet.glob`). Utilise
  `find` avec `name = ".*\\.lua$"` (regex) pour le cas courant.
- I/O asynchrone. Utilise plutôt [`workers`](workers.md) pour le
  traitement parallèle de fichiers.
- BLAKE2s (seul BLAKE2b-512 est exposé via OpenSSL EVP).
