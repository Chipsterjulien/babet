# Archive — opérations ZIP et TAR sécurisées avec gzip, xz, bzip2 ou zstd

## Périmètre

Le sous-module `babet.archive` crée, inspecte, lit en mémoire et extrait des archives **ZIP**,
**TAR** et **TAR compressées avec gzip, xz, bzip2 ou zstd**, sans lancer de
commande externe :

```lua
babet.archive.create(source_ou_sources, archive [, opts])
babet.archive.list(archive [, opts])
babet.archive.read(archive, nom_ou_index [, opts])
babet.archive.test(archive [, opts])
babet.archive.extract(archive, destination [, opts])
babet.archive.extractFile(archive, entry, destination [, opts])
```

La création, l’inspection et l’extraction ZIP continuent d’utiliser miniz. Les
opérations TAR utilisent le backend libarchive lié statiquement ; gzip
s’appuie sur zlib, xz sur XZ Utils/liblzma, bzip2 sur libbz2 et zstd sur
Zstandard/libzstd, également liés statiquement. Les lecteurs détectent le conteneur et la compression à partir
du contenu. Pour `create()`, `.tar` sélectionne un TAR brut, `.tar.gz` et
`.tgz` un TAR gzip, `.tar.xz` ou `.txz` un TAR xz, `.tar.bz2`, `.tbz2` ou
`.tbz` un TAR bzip2, et `.tar.zst`, `.tar.zstd` ou `.tzst` un TAR zstd.
`opts.format` peut remplacer l’extension. Les flux compressés autonomes sont
traités séparément par [`babet.compression`](compression.md).

Les six fonctions suivent le contrat habituel :

```lua
local result, err = babet.archive.list("backup.zip")
if not result then
    io.stderr:write(err, "\n")
end
```

Elles renvoient `(résultat, nil)` en cas de succès et `(nil, message)` en cas
d’échec. Une mauvaise arité, une destination obligatoire qui n’est pas une
chaîne, ou une source qui n’est ni une chaîne ni une table provoque une erreur
Lua. Une liste de sources ou une table d’options invalide renvoie
`(nil, message)`.

## Table des matières

- [`babet.archive.create`](#babetarchivecreate)
- [Options d’inspection/extraction et limites anti-bombe](#options-dinspectionextraction-et-limites-anti-bombe)
- [`babet.archive.list`](#babetarchivelist)
- [`babet.archive.read`](#babetarchiveread)
- [`babet.archive.test`](#babetarchivetest)
- [`babet.archive.extract`](#babetarchiveextract)
- [`babet.archive.extractFile`](#babetarchiveextractfile)
- [Règles de chemins](#règles-de-chemins)
- [Protection de la destination](#protection-de-la-destination)
- [Publication atomique et nettoyage](#publication-atomique-et-nettoyage)
- [Permissions](#permissions)
- [Types d’entrées pris en charge](#types-dentrées-pris-en-charge)
- [Erreurs et limites connues](#erreurs-et-limites-connues)

<a id="babetarchivecreate"></a>

## `babet.archive.create`

```lua
local result, err = babet.archive.create(
    source_ou_sources,
    archive
    [, opts]
)
```

Le premier argument accepte deux contrats distincts :

- une **chaîne** conserve le comportement historique : elle doit désigner un
  répertoire existant, et Babet archive son contenu sans inclure le nom du
  répertoire source lui-même ;
- une **table séquentielle non vide** (`1..n`, sans trou ni autre clé) sélectionne
  explicitement des fichiers réguliers et/ou des répertoires provenant
  éventuellement d’emplacements différents. Chaque source est placée sous son
  dernier composant : `/tmp/rapport.txt` devient `rapport.txt`, et
  `/opt/projet/docs` devient `docs/` avec tout son contenu. Une source absolue
  est acceptée, mais aucun composant du chemin hôte n’est exposé dans
  l’archive.

Dans le mode liste, le dernier composant doit être stable : `.` et la racine du
système de fichiers sont refusés, ainsi que tout composant `..`. Deux sources
ayant le même dernier composant sont une collision et font échouer l’opération,
même si leurs contenus internes seraient différents. Répéter la même source est
donc également refusé. L’ordre fourni par la table ne modifie pas l’ordre final :
les entrées sont toujours triées par leur nom d’archive.

Dans les deux modes, le parcours utilise des descripteurs et ne suit aucun
symlink. Un symlink dans le chemin d’une source de premier niveau est toujours
refusé. Dans un arbre parcouru, un symlink, FIFO, socket, périphérique ou autre
objet non pris en charge fait échouer l’opération lorsqu’il est sélectionné ;
un objet retiré par les filtres n’est pas ouvert. Les noms d’entrées produits
par `create()` doivent
être en UTF-8 valide. Linux autorise des noms contenant des octets arbitraires,
mais Babet refuse ceux qui ne peuvent pas être représentés de manière sûre et
cohérente dans les deux formats de sortie.

### Format de sortie

Sans `opts.format`, `create()` applique les règles suivantes :

- une destination terminée par `.tar` (sans distinction de casse) crée un TAR
  POSIX pax non compressé ;
- `.tar.gz` et `.tgz` (sans distinction de casse) créent un TAR POSIX pax
  compressé avec gzip ;
- `.tar.xz` et `.txz` (sans distinction de casse) créent un TAR POSIX pax
  compressé avec xz ;
- `.tar.bz2`, `.tbz2` et `.tbz` (sans distinction de casse) créent un TAR
  POSIX pax compressé avec bzip2 ;
- `.tar.zst`, `.tar.zstd` et `.tzst` (sans distinction de casse) créent un TAR
  POSIX pax compressé avec zstd ;
- toute autre destination conserve le comportement historique antérieur à la
  2.6 et produit un ZIP, quelle que soit son extension.

`opts.format = "zip"`, `"tar"`, `"tar.gz"`, `"tar.xz"`, `"tar.bz2"` ou
`"tar.zst"` impose explicitement le backend. Le format explicite prime toujours sur le suffixe. Ainsi, `format = "zip"` peut
créer un ZIP nommé `backup.tar.gz`, tandis que `format = "tar"` peut créer un
TAR non compressé nommé `backup.tgz`, `backup.txz`, `backup.tbz2` ou `backup.tzst`. Le
format réel est
déterminé par l’option explicite ou le contenu, jamais par une confiance
aveugle dans l’extension.

Options de création :

| Option | Défaut | Comportement |
| --- | ---: | --- |
| `format` | déduit | chaîne stricte : `"zip"`, `"tar"`, `"tar.gz"`, `"tar.xz"`, `"tar.bz2"` ou `"tar.zst"` |
| `compression_level` | `6` | ZIP/gzip/xz : `0` à `9` ; bzip2 : `1` à `9` ; zstd : `0` à `19` |
| `overwrite` | `false` | remplace atomiquement une archive régulière existante |
| `deterministic` | `true` | ordre stable et dates fixes propres au format |
| `include_directories` | `true` | émet les entrées de dossiers, y compris les dossiers vides |
| `include` | aucune | tableau dense de globs sûrs sensibles à la casse sélectionnant les chemins d’entrée |
| `exclude` | aucune | tableau dense de globs sûrs retirés après inclusion ; l’exclusion gagne toujours |
| `max_entries` | `10000` | nombre maximal d’entrées ; plafond fixe `100000` |
| `max_file_size` | `256 * 1024 * 1024` | taille maximale d’un fichier source ; plafond fixe 8 Gio |
| `max_total_size` | `1024 * 1024 * 1024` | somme maximale des octets source ; plafond fixe 64 Gio |

Pour un TAR brut, fournir explicitement `compression_level` est une erreur.
Pour ZIP, TAR gzip et TAR xz, le niveau `0` est valide et le niveau `9` est le
maximum. TAR bzip2 accepte les niveaux `1` à `9` ; le niveau `0` est refusé car
les tailles de bloc libbz2 commencent à 100 Kio. TAR zstd accepte les niveaux
`0` à `19` ; Babet exclut volontairement les niveaux ultra `20` à `22`.

Toutes les options entières exigent de vrais entiers Lua. Les options
booléennes exigent de vrais booléens Lua. Les clés inconnues sont refusées.
`format` est sensible à la casse et n’accepte aucun alias.

### Filtres d’inclusion et d’exclusion

`include` et `exclude` sont des tableaux denses facultatifs de chaînes Lua non
vides. Une liste `include` absente ou vide conserve le comportement historique
et sélectionne initialement toutes les entrées prises en charge. Avec une liste
`include` non vide, une entrée est sélectionnée si au moins un motif
correspond. `exclude` est ensuite appliqué et gagne toujours, même lorsque le
même chemin correspond aussi à `include`.

Les motifs s’appliquent au chemin complet qui sera stocké dans l’archive, avec
`/` comme séparateur. La forme historique à chaîne utilise donc des chemins
relatifs au répertoire source, tandis qu’une liste explicite inclut le nom final
de chaque source (`docs/readme.md`, `report.txt`, etc.). La correspondance est
ancrée, orientée octets et sensible à la casse :

- `*` correspond à zéro ou plusieurs octets sauf `/` ;
- `**` correspond à zéro ou plusieurs octets, y compris `/` ;
- `?` correspond à exactement un octet sauf `/` ;
- `\x` protège l’octet suivant `x`.

Un répertoire est testé sous les formes `chemin` et `chemin/`. Ainsi,
`build/**` sélectionne ou exclut le dossier `build/` lui-même ainsi que tous ses
descendants. Un dossier directement exclu est élagué avant son ouverture : rien
de son sous-arbre n’est inspecté ni archivé. Lorsqu’un fichier profond est
inclus, `include_directories = true` conserve tous ses dossiers parents
nécessaires même s’ils ne correspondent pas directement à `include`. Un dossier
vide correspondant à un motif n’est conservé que si les entrées de dossiers
sont activées. Avec `include_directories = false`, seuls les fichiers réguliers
sélectionnés sont émis et leurs parents restent implicites.

Le filtrage définit le plan réellement sélectionné. Un symlink, FIFO, socket,
périphérique ou nom UTF-8 invalide qui est exclu, ou qui ne correspond pas à
une liste `include` non vide, est ignoré ; le même objet fait toujours échouer
la création lorsqu’il est sélectionné. Les chemins fournis comme sources
explicites de premier niveau sont toujours validés avant filtrage et doivent
eux-mêmes rester des fichiers réguliers ou de vrais répertoires accessibles
sans symlink. Il est valide qu’aucun motif ne corresponde : Babet crée alors un
ZIP ou TAR vide valide.

Le moteur de glob sûr n’effectue aucun backtracking récursif. Chaque motif est
limité à 4096 octets. `include` et `exclude` sont limités ensemble à 256 motifs
et 256 Kio de texte, un million d’évaluations de motifs et un budget fixe de
100 000 000 cellules de correspondance par création. Dépasser une limite provoque un échec
avant publication. L’ordre des motifs n’affecte ni la sélection ni les octets
d’une archive déterministe.

Tous les chemins source sont validés et chaque arbre non élagué est analysé
avant la création du fichier temporaire de sortie. `max_entries`,
`max_file_size` et `max_total_size` s’appliquent uniquement aux entrées retenues
par les filtres. Chaque nom sélectionné est borné à 4096 octets et leur somme à
64 Mio. Le parcours conserve des plafonds fixes de 100000 sources/objets du
système de fichiers et 256 niveaux de répertoires, indépendamment de
`include_directories` ; les descendants d’un dossier élagué ne sont pas
visités. Les fichiers sont ensuite rouverts depuis leur
descripteur source épinglé avec `O_NOFOLLOW`. Le périphérique, l’inode, la
taille, la date de modification et la date de changement sont vérifiés avant et
après la lecture en flux ; un fichier modifié pendant la création provoque un
échec et la suppression du temporaire.

Le parent de destination doit déjà exister et ne contenir aucun symlink ni
composant `..`. La destination doit être absente sauf avec `overwrite = true`,
et ne peut jamais être un symlink ou un répertoire. L’archive ne peut pas être
créée dans le répertoire source historique ni dans l’un des répertoires d’une
liste explicite ; elle ne peut pas non plus remplacer directement un fichier
sélectionné.

Le résultat indique le format sélectionné :

```lua
{
    files = 12,
    directories = 3,
    bytes = 987654,
    sources = 1,
    path = "backup.tar",
    format = "tar",
    compression = "none",
    compression_level = nil,
    deterministic = true,
    include_patterns = 0,
    exclude_patterns = 0,
}
```

`sources` contient le nombre de chemins fournis : `1` pour le contrat historique
à répertoire unique, ou la longueur de la liste explicite.
`include_patterns` et `exclude_patterns` indiquent le nombre de motifs compilés
pour l’appel. Pour ZIP et TAR gzip, xz, bzip2 ou zstd, `compression_level`
contient le niveau entier
effectif. Pour un TAR brut, il vaut `nil`. Le champ d’archive `compression` vaut
`"gzip"`, `"xz"`, `"bzip2"` ou `"zstd"` pour un TAR compressé et `"none"` sinon. La compression
des entrées ZIP reste indiquée par les métadonnées par entrée renvoyées par
`list()`.

Avec le mode déterministe par défaut, des contenus, un format, des versions de dépendances
épinglées et des options identiques produisent des archives strictement identiques octet par
octet :

- les entrées ZIP utilisent la date DOS fixe du 1er janvier 1980 à 00:00:00 ;
- les entrées TAR utilisent l’époque Unix zéro, les UID/GID `0`, des noms de
  propriétaire/groupe vides, le mode `0644` pour les fichiers et `0755` pour
  les répertoires ;
- un TAR gzip écrit en plus une date nulle dans l’en-tête gzip, afin que le flux
  externe n’introduise pas l’heure courante ;
- un flux xz ne contient aucune date courante et son preset LZMA2 est fixé par
  `compression_level` ;
- un flux bzip2 ne contient aucune date courante et sa taille de bloc est fixée
  par `compression_level` ;
- une frame zstd ne contient aucune date courante, active son checksum de frame
  et utilise le niveau fixé par `compression_level`.

Avec `deterministic = false`, l’ordre trié reste stable. ZIP utilise la date de
modification source, qui doit être comprise entre 1980 et 2107 dans le fuseau
local. TAR conserve la date de modification source avec sa précision en
nanosecondes lorsqu’elle est représentable par la plateforme et n’est pas
limité par la plage DOS du ZIP.

Les propriétaires, ACL, attributs étendus et bits de permission source ne sont
pas copiés. TAR utilise le writer POSIX pax restreint de libarchive : les noms
ordinaires utilisent des en-têtes ustar portables lorsque c’est possible, et
les chemins longs ou métadonnées nécessitant une extension utilisent des
en-têtes pax. ZIP64 est activé automatiquement lorsque la préanalyse indique
que les champs ZIP classiques risquent d’être dépassés. Les petits ZIP restent
des ZIP classiques.

La préanalyse et les contrôles empêchent les substitutions par symlink et
détectent la modification de chaque fichier réellement archivé. La création
n’est toutefois pas un instantané du système de fichiers : un fichier ajouté
après l’analyse de son répertoire peut être absent du résultat ; un fichier
déjà recensé puis supprimé ou renommé fait normalement échouer sa réouverture.
Les renommages concurrents de répertoires ne sont pas signalés comme conflit
transactionnel.

Avec `include_directories = false`, les répertoires vides ne peuvent pas être
représentés et sont donc omis. Dans une liste explicite, le préfixe correspondant
au nom du répertoire sélectionné reste présent pour ses fichiers réguliers. Les
parents nécessaires sont recréés implicitement pendant l’extraction.

Exemples :

```lua
local zip, err = babet.archive.create("projet", "projet.zip", {
    compression_level = 9,
    overwrite = true,
})
assert(zip, err)

local selection, list_err = babet.archive.create({
    "bin/babet",
    "README.md",
    "docs",
}, "publication.tar.zst", {
    compression_level = 19,
})
assert(selection, list_err)
-- Entrées : babet, README.md, docs/, docs/...

local filtree, filter_err = babet.archive.create("projet", "sources.tar.zst", {
    include = { "src/**", "README.fr.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
})
assert(filtree, filter_err)

local tar
tar, err = babet.archive.create("projet", "projet.tar", {
    deterministic = true,
})
assert(tar, err)

local gzip
gzip, err = babet.archive.create("projet", "projet.tar.gz", {
    compression_level = 9,
})
assert(gzip, err)

local xz
xz, err = babet.archive.create("projet", "projet.tar.xz", {
    compression_level = 9,
})
assert(xz, err)

local bzip2
bzip2, err = babet.archive.create("projet", "projet.tar.bz2", {
    compression_level = 9,
})
assert(bzip2, err)

local zstd
zstd, err = babet.archive.create("projet", "projet.tar.zst", {
    compression_level = 19,
})
assert(zstd, err)

local named
named, err = babet.archive.create("projet", "sauvegarde.data", {
    format = "tar.zst",
})
assert(named, err)
```

## Options d’inspection/extraction et limites anti-bombe

Les options suivantes sont communes à `list()`, `read()`, `test()`, `extract()`
et `extractFile()`. Elles sont appliquées à **l’archive entière**, même lorsque
`read()` ou `extractFile()` ne demande qu’une seule entrée : sélectionner un
petit fichier ne permet donc jamais de contourner les limites globales.

| Option | Défaut | Maximum accepté | Effet |
| --- | ---: | ---: | --- |
| `max_entries` | `10000` | `100000` | nombre maximal d’entrées exposées par l’archive |
| `max_entry_size` | `256 * 1024 * 1024` | `8 * 1024^3` | taille décompressée maximale d’une entrée non répertoire |
| `max_total_size` | `1024 * 1024 * 1024` | `64 * 1024^3` | somme maximale des tailles décompressées des entrées non répertoire |
| `max_path_length` | `64 * 1024` | `1024 * 1024` | longueur maximale, en octets, d’un nom brut d’entrée inspecté |
| `max_total_name_bytes` | `64 * 1024 * 1024` | `64 * 1024 * 1024` | somme maximale, en octets, de tous les noms d’entrées ; cette option sert à resserrer la limite fixe |
| `max_compression_ratio` | `1000` | `1000000000` | rapport par entrée pour ZIP ; rapport global octets fichiers décompressés / taille archive pour TAR gzip, xz, bzip2 ou zstd ; sans effet pour TAR brut |

Les cinq limites entières doivent être de **vrais entiers Lua strictement
positifs**. Les flottants, même écrits `10.0`, les booléens, les chaînes
numériques, zéro et les valeurs supérieures au plafond sont refusés.
`max_compression_ratio` doit être un nombre fini supérieur ou égal à `1` ;
`NaN` et l’infini sont refusés. Une clé inconnue est toujours une erreur.

`max_path_length` borne la quantité de métadonnées que Babet accepte de lire ;
elle ne rend pas un long chemin extractible. La politique de sécurité de
l’extraction reste plus stricte : un nom de plus de **4096 octets** est signalé
par `list()` avec `safe_path = false`, même lorsque sa longueur reste sous
`max_path_length`. Avec la valeur par défaut, il est donc possible d’inspecter
et de diagnostiquer un nom de 4097 octets sans jamais autoriser son extraction.
L’appelant peut réduire `max_path_length` afin de refuser l’archive avant même
la construction de la table Lua.

`max_total_name_bytes` vaut déjà son plafond fixe par défaut. Elle permet de
resserrer le budget de noms pour une archive non fiable, mais pas de l’élargir.
Le résultat de `list()` expose la consommation réelle dans
`total_name_bytes`. Les allocations internes du lecteur ZIP miniz sont en
outre plafonnées à 128 Mio par archive, de sorte qu’un répertoire central ou
des commentaires ZIP excessifs ne puissent pas provoquer une allocation
arbitraire avant les contrôles entrée par entrée.

L’inspection TAR fonctionne en flux : Babet lit les données de chaque entrée
sans les conserver en mémoire, afin d’atteindre l’en-tête suivant et de
détecter les contenus tronqués. Pour TAR gzip, une validation progressive et
bornée avec zlib contrôle aussi CRC et ISIZE de chaque membre ; le bourrage nul
standard reste accepté, mais une bande-annonce corrompue ou des octets finaux
étrangers sont refusés. Pour TAR zstd, une validation progressive indépendante
avec libzstd exige des frames complètes, accepte les frames concaténées valides
et refuse corruption, troncature ou données finales étrangères. Les filtres xz
et bzip2 restent entièrement consommés par libarchive.

Pour une extraction complète, l’arbre de sortie est également borné en interne
à 100000 répertoires uniques, parents implicites compris, et à 64 Mio de chemins
de répertoires normalisés cumulés. Ces plafonds fixes ne sont pas réglables.

Une entrée non vide qui annonce une taille compressée nulle est refusée. Les
répertoires ne comptent ni dans `max_entry_size`, ni dans `max_total_size`, ni
dans le rapport de compression, mais ils comptent dans `max_entries` et dans
les budgets de noms.

### Un exemple par limite

Limiter seulement le nombre d’entrées :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 2000,
})
assert(result, err)
```

Limiter seulement la taille d’une entrée :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entry_size = 64 * 1024 * 1024,
})
assert(result, err)
```

Limiter seulement la taille totale annoncée :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_size = 512 * 1024 * 1024,
})
assert(result, err)
```

Limiter seulement la longueur d’un nom brut :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_path_length = 8192,
})
assert(result, err)
```

Limiter seulement le budget cumulé des noms :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_name_bytes = 2 * 1024 * 1024,
})
assert(result, err)
```

Limiter seulement le rapport de compression :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_compression_ratio = 200,
})
assert(result, err)
```

Combiner toutes les protections pour une archive reçue d’un tiers :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 2000,
    max_entry_size = 64 * 1024 * 1024,
    max_total_size = 512 * 1024 * 1024,
    max_path_length = 8192,
    max_total_name_bytes = 2 * 1024 * 1024,
    max_compression_ratio = 200,
})
assert(result, err)
```

Les options propres à la création ou à l’écriture, telles que `overwrite`,
`preserve_permissions`, `format`, `dry_run`, `include` ou `exclude`, ne sont
pas acceptées par `list()`, `read()` ou `test()`. `read()` accepte en plus
`max_size`, documentée dans sa section ; cette option est refusée par les cinq
autres fonctions.

<a id="babetarchivelist"></a>

## `babet.archive.list`

```lua
local info, err = babet.archive.list(archive [, opts])
```

`archive` est le chemin d’un fichier ZIP, TAR brut, TAR gzip, TAR xz, TAR
bzip2 ou TAR zstd. Le format et la compression sont détectés par le **contenu**,
jamais par l’extension : un TAR zstd nommé `sauvegarde.bin` est reconnu, tandis
qu’un fichier nommé `sauvegarde.tar.zst` mais contenant autre chose est refusé.
Les suffixes usuels `.tar`, `.tar.gz`, `.tgz`, `.tar.xz`, `.txz`, `.tar.bz2`,
`.tbz`, `.tbz2`, `.tar.zst`, `.tar.zstd` et `.tzst` ne sont donc que des
conventions de nommage.

Le chemin source peut être un symlink vers un fichier régulier. Babet ouvre sa
cible une seule fois et conserve ce même descripteur pendant toute l’analyse.
Les répertoires, FIFO, sockets et périphériques sont refusés avant l’analyse du
format ; l’ouverture non bloquante empêche notamment qu’un FIFO sans écrivain
suspende l’appel.

Babet essaie d’abord le lecteur ZIP miniz. Si le fichier épinglé n’est pas un
ZIP, le même descripteur est rembobiné puis confié au lecteur TAR libarchive,
avec uniquement les filtres intégrés `none`, `gzip`, `xz`, `bzip2` et `zstd`.
Aucun décompresseur externe n’est lancé. Les archives ZIP fractionnées et les
archives multivolumes ne sont pas prises en charge. Une archive standard vide
est valide et renvoie `count = 0`.

`list()` ne crée **aucun fichier, aucun dossier et aucun fichier temporaire**.
Elle conserve l’ordre physique/logique des entrées tel qu’il apparaît dans
l’archive : aucun tri, aucune déduplication et aucune réorganisation ne sont
effectués. `entries[1]` représente toujours la première entrée rencontrée,
`entries[2]` la deuxième, etc. Cette stabilité permet aux champs `index`,
`duplicate_of` et `conflict_with` de référencer directement la table retournée.

La fonction renvoie exactement deux valeurs : `(info, nil)` en cas de succès
et `(nil, message)` en cas d’échec.

### Structure retournée

```lua
{
    format = "zip",           -- "zip" ou "tar"
    compression = "none",    -- "none", "gzip", "xz", "bzip2" ou "zstd"
    entries = {
        {
            index = 1,
            name = "docs/readme.txt", -- nom brut, chaîne Lua binaire
            path = "docs/readme.txt", -- chemin normalisé si safe_path == true
            valid_utf8 = true,
            type = "file",
            size = 1234,

            compressed_size = 530,     -- ZIP uniquement, sinon nil
            crc32 = 305419896,          -- ZIP uniquement, sinon nil
            compression_method = 8,    -- ZIP uniquement, sinon nil
            encrypted = false,
            supported = true,

            safe_path = true,
            extractable = true,
            reason = nil,

            unix_mode = 420,            -- 0644, ou nil
            mtime = 1750000000,         -- secondes Unix, ou nil
            mtime_nsec = nil,           -- TAR uniquement, ou nil
            uid = nil,                  -- TAR uniquement, ou nil
            gid = nil,                  -- TAR uniquement, ou nil
            sparse = false,
            link_target = nil,

            duplicate = false,
            duplicate_of = nil,
            conflict = false,
            conflict_with = nil,
            conflict_reason = nil,
        },
    },
    count = 1,
    total_size = 1234,
    archive_size = 666,
    total_name_bytes = 19,
    duplicates = 0,
    conflicts = 0,
    zip64 = false,             -- nil pour TAR
}
```

`format` décrit le conteneur. Pour ZIP, `compression` vaut toujours `"none"`,
car la compression est choisie entrée par entrée et apparaît dans
`compression_method`. Pour TAR, `compression` vaut `"none"`, `"gzip"`,
`"xz"`, `"bzip2"` ou `"zstd"` selon le filtre détecté.

`count` est le nombre d’éléments de `entries`. `total_size` est la somme des
tailles déclarées des entrées non répertoire. `archive_size` est la taille du
fichier d’archive épinglé. `total_name_bytes` est la somme exacte des longueurs
en octets des champs `name`. `zip64` est un booléen pour ZIP et vaut `nil` pour
TAR.

### Champs communs à chaque entrée

- `index` est l’indice Lua 1-based de l’entrée dans l’ordre de l’archive ;
- `name` conserve le nom brut sous forme de chaîne Lua binaire ;
- `path` est la forme normalisée prévue pour l’extraction. Un `/` terminal de
  répertoire est retiré. Ce champ n’est utilisable comme chemin que lorsque
  `safe_path == true` ; il peut être vide pour une entrée dangereuse ;
- `valid_utf8` indique si `name` est un encodage UTF-8 strictement valide.
  Babet ne convertit, ne remplace et ne normalise jamais les octets ;
- `type` vaut `file`, `directory`, `symlink`, `hardlink`, `fifo`,
  `character_device`, `block_device`, `socket` ou `unsupported` ;
- `size` est la taille décompressée déclarée. Pour un répertoire ou un objet
  spécial elle vaut normalement `0`, selon les métadonnées réellement lues ;
- `safe_path` ne juge que le nom : chemin relatif, séparateur `/`, composants
  non vides, absence de `.` et `..`, absence de préfixe de lecteur Windows,
  absence d’octet NUL, type cohérent avec un `/` terminal et longueur maximale
  extractible de 4096 octets ;
- `extractable` juge l’entrée isolément : chemin sûr, type autorisé, absence de
  chiffrement et méthode prise en charge. Il ne tient volontairement pas compte
  d’un doublon ou d’une collision avec une autre entrée ; consulter aussi
  `duplicate` et `conflict` ;
- `reason` vaut `nil` lorsque l’entrée est isolément extractible, sinon une
  raison stable telle que `symlink entries are refused` ou
  `entry path contains '.' or '..'` ;
- `unix_mode` contient les bits `0000` à `7777` lorsqu’ils sont disponibles,
  sinon `nil`. La valeur décimale `420` correspond à `0644` ;
- `mtime` est l’heure de modification en secondes depuis l’époque Unix lorsque
  le backend peut la fournir, sinon `nil` ;
- `mtime_nsec` est la partie nanoseconde d’un timestamp TAR lorsque celui-ci
  est présent. Elle vaut `nil` pour ZIP ;
- `uid` et `gid` sont les identifiants numériques TAR lorsqu’ils sont
  explicitement présents, sinon `nil`. Ils valent toujours `nil` pour ZIP ;
- `sparse` signale un fichier TAR creux ;
- `link_target` contient la cible brute d’un symlink ou d’un hard link TAR
  lorsque libarchive l’expose, sinon `nil`.

Pour ZIP, `mtime` provient du timestamp DOS de l’entrée converti par miniz en
`time_t`. Le format ZIP ne stocke ni fuseau horaire ni nanosecondes : la valeur
est donc une information de calendrier locale à interpréter avec prudence.
Pour TAR, `mtime` peut être négatif ou supérieur à la plage DOS et
`mtime_nsec` conserve la précision disponible. L’absence d’une métadonnée est
toujours représentée par `nil`, jamais par une valeur inventée.

### Champs propres au ZIP

`compressed_size`, `crc32` et `compression_method` reprennent les métadonnées
du répertoire central ZIP. `encrypted` signale le drapeau de chiffrement et
`supported` indique si miniz reconnaît la méthode de compression. Ces champs
permettent l’inspection, mais `crc32` n’est pas une preuve d’intégrité :
`list()` ne décompresse pas tous les payloads ZIP. Une archive peut donc avoir
un répertoire central lisible tout en contenant une donnée compressée dont le
CRC ne sera détecté qu’à la lecture/extraction. Pour une validation complète des en-têtes locaux, des données et des CRC,
utiliser [`archive.test()`](#babetarchivetest).

Pour TAR, `compressed_size`, `crc32` et `compression_method` valent `nil`,
`encrypted` vaut `false`, et `supported` indique que l’en-tête a pu être
interprété. La compression éventuelle concerne le flux TAR entier et apparaît
dans le champ global `compression`.

### Noms binaires, chemins dangereux et normalisation

Les noms ZIP sont des chaînes d’octets issues du répertoire central. Les noms
TAR sont les chaînes natives fournies par libarchive après traitement des
préfixes ustar, noms longs GNU et champs pax `path`. Les comparaisons sont
exactes, orientées octets et sensibles à la casse. Aucune normalisation Unicode
n’est appliquée : deux représentations Unicode visuellement identiques restent
deux noms distincts. Un nom UTF-8 invalide est conservé et signalé par
`valid_utf8 = false` ; il n’est pas automatiquement déclaré dangereux si les
autres règles de chemin sont respectées.

Les chemins absolus, les composants `.` ou `..`, les doubles `/`, les
backslashes, les préfixes `C:`, les noms vides, les octets NUL et les noms de
plus de 4096 octets sont signalés par `safe_path = false` et une `reason`
explicite. `list()` continue à inspecter les autres entrées tant que les limites
de métadonnées restent respectées. Elle ne tente jamais de corriger silencieusement
un chemin dangereux.

### Doublons et collisions

Les diagnostics sont attachés à la **deuxième occurrence et aux suivantes** :

- `duplicate = true` signifie que le même champ `name`, octet pour octet, a déjà
  été rencontré. `duplicate_of` contient l’indice de la première occurrence ;
- `conflict = true` signifie que le chemin de sortie sûr et normalisé de cette
  entrée ne peut pas coexister avec une entrée antérieure. `conflict_with`
  contient l’indice antérieur retenu et `conflict_reason` vaut actuellement
  `duplicate output path` ou `file/directory path conflict` ;
- `duplicates` compte les occurrences exactes supplémentaires ;
- `conflicts` compte les occurrences supplémentaires qui rendraient le plan
  d’extraction ambigu ou impossible.

Un doublon exact dont le chemin est sûr est donc à la fois un `duplicate` et un
`conflict`. Deux noms bruts différents, par exemple `docs/` et `docs`, ne sont
pas des doublons, mais ils entrent en collision après normalisation et le second
porte `conflict = true`. Une entrée dangereuse peut être signalée comme doublon
brut, mais elle n’entre pas dans le calcul des collisions de sortie puisqu’elle
n’a pas de chemin d’extraction sûr.

`list()` ne transforme pas ces diagnostics en erreur : son rôle est précisément
de permettre l’examen d’une archive suspecte. `extract()` continue en revanche
à refuser les doublons et collisions avant toute écriture.

Exemple de diagnostic :

```lua
local info, err = babet.archive.list("upload.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if not entry.safe_path then
        print(entry.index, entry.name, entry.reason)
    elseif entry.duplicate then
        print(entry.index, "duplique l’entrée", entry.duplicate_of)
    elseif entry.conflict then
        print(entry.index, entry.conflict_reason,
            "avec l’entrée", entry.conflict_with)
    end
end
```

### Exemples d’utilisation

Afficher simplement le contenu dans l’ordre de l’archive :

```lua
local info, err = babet.archive.list("backup.tar.zst")
assert(info, err)

print(info.format, info.compression, info.count)
for _, entry in ipairs(info.entries) do
    print(entry.index, entry.type, entry.path, entry.size)
end
```

Exploiter les métadonnées disponibles sans supposer qu’elles existent :

```lua
local info, err = babet.archive.list("package.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if entry.mtime ~= nil then
        print(entry.name, os.date("%Y-%m-%d %H:%M:%S", entry.mtime))
    end
    if entry.unix_mode ~= nil then
        print(string.format("mode=%04o", entry.unix_mode))
    end
    if entry.uid ~= nil then
        print("uid/gid", entry.uid, entry.gid)
    end
end
```

Refuser soi-même toute archive ambiguë avant de poursuivre un traitement :

```lua
local info, err = babet.archive.list("upload.zip")
assert(info, err)

if info.duplicates ~= 0 or info.conflicts ~= 0 then
    error("archive ambiguë")
end

for _, entry in ipairs(info.entries) do
    if not entry.safe_path or not entry.extractable then
        error((entry.reason or "entrée refusée") .. ": " .. entry.name)
    end
end
```

Traiter correctement un nom non UTF-8 :

```lua
local info, err = babet.archive.list("legacy.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if not entry.valid_utf8 then
        -- La chaîne reste binaire : afficher les octets plutôt que la passer
        -- à une interface qui exige du texte UTF-8.
        local bytes = {}
        for i = 1, #entry.name do
            bytes[#bytes + 1] = string.format("%02x", entry.name:byte(i))
        end
        print(entry.index, table.concat(bytes))
    end
end
```

Utiliser `list()` dans un worker :

```lua
local worker, err = babet.workers.spawn([[
local info, list_err = babet.archive.list(worker.args.archive, {
    max_entries = 5000,
})
if not info then error(list_err) end
return {
    format = info.format,
    compression = info.compression,
    count = info.count,
    duplicates = info.duplicates,
    conflicts = info.conflicts,
}
]], { archive = "backup.tar.zst" })
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.format, result.count)
```

La fonction et tous ses champs ont le même comportement dans l’état Lua
principal, en mode dossier, en mode embarqué et dans les workers.

### Ce que `list()` valide — et ce qu’elle ne garantit pas

Pour ZIP, Babet valide la structure nécessaire à l’ouverture et à la lecture du
répertoire central, les nombres et tailles annoncés, les chemins et les limites.
Les données compressées des fichiers ne sont pas toutes lues : un CRC de
payload invalide peut donc rester invisible à ce stade.

Pour TAR et TAR compressé, atteindre l’en-tête suivant impose de consommer les
données de chaque entrée ; Babet détecte ainsi de nombreuses troncatures,
en-têtes invalides et erreurs du flux externe. Cette lecture complète ne change
pas le rôle de l’API : `list()` retourne un inventaire, tandis que [`archive.test()`](#babetarchivetest) transforme la lecture
complète et les règles de sécurité agrégées en un verdict strict.

Une archive techniquement lisible mais contenant des chemins dangereux, liens
ou objets spéciaux est volontairement retournée avec ses diagnostics. Une
archive dont le format est inconnu, dont la structure ne peut pas être lue, qui
dépasse une limite ou dont le flux TAR est tronqué renvoie `(nil, message)`.



<a id="babetarchiveread"></a>

## `babet.archive.read`

```lua
local data, err = babet.archive.read(
    archive,
    nom_brut_ou_index
    [, opts]
)
```

`read()` charge **un fichier régulier** dans une chaîne Lua binaire, sans créer
de destination, de fichier temporaire ni de répertoire. Elle reconnaît par le
contenu les mêmes formats que `list()` : ZIP, TAR brut, TAR gzip, TAR xz, TAR
bzip2 et TAR zstd.

Le succès renvoie exactement `(data, nil)`. `data` peut être vide et peut
contenir des octets NUL ou du texte non UTF-8. Une erreur renvoie exactement
`(nil, message)`.

### Sélection par nom brut ou par index

Le deuxième argument accepte deux formes strictes :

- une **chaîne** recherche le nom brut exact, octet pour octet et avec respect
  de la casse ;
- un **entier** sélectionne l’index 1-based exposé dans
  `list().entries[i].index`.

Un flottant tel que `2.0`, un booléen ou une table n’est pas converti
silencieusement en index. Un nom ne peut pas contenir d’octet NUL. Les noms
longs GNU et pax d’un TAR sont ceux déjà décodés et exposés par `list()`.

Lecture directe par nom :

```lua
local manifest, err = babet.archive.read(
    "package.tar.zst",
    "manifest.json"
)
assert(manifest, err)
```

Lecture par index obtenu sans supposer l’ordre de l’archive :

```lua
local info, err = babet.archive.list("package.zip")
assert(info, err)

local target
for _, entry in ipairs(info.entries) do
    if entry.name == "assets/logo.bin" then
        target = entry.index
        break
    end
end
assert(target, "assets/logo.bin absent")

local logo
logo, err = babet.archive.read("package.zip", target)
assert(logo, err)
```

La sélection par nom est refusée si le même nom brut apparaît plusieurs fois :
Babet ne choisit jamais silencieusement la première ou la dernière occurrence.
Après inspection de `duplicate` et `duplicate_of`, un index explicite peut lire
l’occurrence voulue :

```lua
local info, err = babet.archive.list("duplicated.zip")
assert(info, err)

for _, entry in ipairs(info.entries) do
    if entry.name == "settings.json" then
        print(entry.index, entry.duplicate, entry.duplicate_of)
    end
end

-- Choix explicite de la deuxième occurrence.
local data
data, err = babet.archive.read("duplicated.zip", 7)
assert(data, err)
```

L’index désambiguïse uniquement l’entrée à lire. Il ne supprime, ne trie et ne
réécrit aucune entrée de l’archive.

### Noms dangereux et types refusés

Comme `read()` n’utilise jamais le nom comme chemin de destination, un fichier
régulier nommé `../config`, `/absolute` ou avec un nom non UTF-8 peut être lu
par son nom brut ou son index. Aucune normalisation ni « réparation » n’est
appliquée. Le script doit consulter `valid_utf8`, `safe_path`, `duplicate` et
`conflict` dans `list()` avant de réutiliser ce nom dans un autre contexte :

```lua
local info, err = babet.archive.list("untrusted.zip")
assert(info, err)

local entry = assert(info.entries[1])
print(entry.name, entry.valid_utf8, entry.safe_path)

local data
data, err = babet.archive.read("untrusted.zip", entry.index)
assert(data, err)
```

Cette tolérance est sûre uniquement parce qu’aucune écriture n’a lieu. Les
règles strictes de confinement restent inchangées pour `extract()` et
`extractFile()`.

Les répertoires, symlinks, hard links, FIFO, sockets, périphériques, types
inconnus, entrées ZIP chiffrées, méthodes ZIP non prises en charge et fichiers
TAR sparse sont refusés. `read()` ne suit jamais un lien contenu dans
l’archive.

### Limite mémoire `max_size`

`read()` ajoute une option propre :

| Option | Défaut | Maximum accepté | Effet |
| --- | ---: | ---: | --- |
| `max_size` | `8 * 1024 * 1024` | `256 * 1024 * 1024` | nombre maximal d’octets renvoyés dans la chaîne Lua |

`max_size` doit être un véritable entier Lua entre `1` et `268435456`. La
limite est inclusive : une entrée produisant exactement `max_size` octets est
acceptée.

```lua
local config, err = babet.archive.read(
    "package.tar.gz",
    "config.json",
    { max_size = 1024 * 1024 }
)
assert(config, err)
```

Babet refuse tôt une taille annoncée supérieure à `max_size`, puis applique la
même limite au callback qui reçoit les octets réellement décompressés. Un ZIP
mensonger qui annonce une petite taille mais produit davantage est donc arrêté
avant que le tampon borné ne puisse être dépassé. La vérification porte sur les
octets binaires, pas sur un nombre de caractères Unicode.

`max_size` ne remplace pas `max_entry_size` :

- `max_size` borne uniquement la valeur Lua demandée ;
- `max_entry_size`, `max_total_size`, `max_entries`, `max_path_length`,
  `max_total_name_bytes` et `max_compression_ratio` continuent de protéger
  l’archive entière.

Exemple combiné pour une archive non fiable :

```lua
local manifest, err = babet.archive.read(
    "upload.tar.xz",
    "manifest.json",
    {
        max_size = 512 * 1024,
        max_entries = 2000,
        max_entry_size = 64 * 1024 * 1024,
        max_total_size = 512 * 1024 * 1024,
        max_path_length = 8192,
        max_total_name_bytes = 2 * 1024 * 1024,
        max_compression_ratio = 200,
    }
)
assert(manifest, err)
```

### Intégrité et consommation de l’archive

Pour ZIP, Babet inspecte les métadonnées de l’archive, puis décompresse
intégralement l’entrée sélectionnée avec miniz. Une erreur de méthode, de
décompression, de taille produite ou de CRC fait échouer la lecture.

Pour TAR, la première passe inspecte et consomme toute l’archive. La seconde
passe compare chaque en-tête au plan inspecté, transmet seulement les blocs du
fichier choisi au tampon mémoire borné et consomme toutes les autres entrées
jusqu’à la fin. Les validations supplémentaires des flux gzip et zstd restent
appliquées. Une corruption ou une troncature ailleurs dans le TAR peut donc
faire échouer la lecture du petit fichier demandé.

`read()` n’est pas un alias de `test()` : elle valide complètement la donnée
sélectionnée et les structures nécessaires à sa lecture, tandis que `test()`
décompresse tous les payloads ZIP et applique en plus le verdict global de
sécurité sur toutes les entrées.

### Utilisation dans un worker

L’API est disponible dans les workers. Une chaîne UTF-8 ordinaire peut être
renvoyée directement. Pour une donnée binaire contenant NUL ou des octets non
UTF-8, le worker doit la traiter sur place ou renvoyer un résultat
sérialisable, par exemple sa taille et son CRC :

```lua
local worker, err = babet.workers.spawn([[
local data, read_err = babet.archive.read(
    worker.args.archive,
    worker.args.index,
    { max_size = worker.args.max_size }
)
if not data then error(read_err) end
return {
    size = #data,
    crc32 = babet.crc32(data),
}
]], {
    archive = "assets.tar.bz2",
    index = 3,
    max_size = 4 * 1024 * 1024,
})
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.size, result.crc32)
```

Cette restriction au retour du worker vient du contrat de sérialisation des
workers, pas de `archive.read()` : la lecture elle-même reste entièrement
binaire.

<a id="babetarchivetest"></a>

## `babet.archive.test`

```lua
local result, err = babet.archive.test(archive [, opts])
```

`test()` vérifie intégralement une archive **sans rien extraire et sans rien
écrire**. Elle accepte les mêmes formats détectés par contenu que `list()` :
ZIP, TAR brut, TAR gzip, TAR xz, TAR bzip2 et TAR zstd. Elle accepte exactement
les mêmes six limites anti-bombe documentées plus haut et refuse toute autre
option.

Le contrat est volontairement strict : un succès signifie que l’archive est à
la fois **techniquement valide** et **entièrement sûre selon les règles
d’extraction de Babet**. Une archive lisible mais contenant un chemin dangereux,
un doublon, une collision, un symlink, un hard link, un fichier sparse, un
objet spécial, une entrée chiffrée ou une méthode ZIP non prise en charge
renvoie donc `(nil, message)`. `test()` ne renvoie pas une table `warnings` ni
un champ `safe = false` : pour obtenir un inventaire détaillé d’une archive
suspecte sans la valider, utiliser `list()`.

Le chemin source suit le même contrat que `list()` : un symlink vers un fichier
régulier est accepté, tandis qu’un répertoire, FIFO, socket ou périphérique est
refusé sans blocage. Le fichier ouvert est épinglé par descripteur pendant toute
la vérification. L’extension ne participe jamais au choix du backend.

### Vérifications techniques

Pour un ZIP, Babet contrôle notamment :

- les métadonnées EOCD et ZIP64, avec refus des archives fractionnées ou
  multivolumes ;
- le répertoire central et les limites annoncées ;
- l’en-tête local de **chaque** entrée, y compris les fichiers vides et les
  répertoires ;
- l’identité du nom local et du nom central, les drapeaux, la méthode, les
  tailles, le CRC, les champs ZIP64 locaux et les data descriptors, avec
  ou sans signature ;
- les bornes de chaque zone locale, l’absence de chevauchement entre entrées et
  l’absence de recouvrement avec le répertoire central ;
- la décompression complète de chaque entrée non répertoire, la taille réellement
  produite et son CRC.

Pour TAR, le lecteur consomme l’intégralité des données et vérifie les en-têtes,
checksums TAR disponibles, tailles, troncatures, padding et données finales.
Pour TAR gzip, xz, bzip2 ou zstd, le flux de compression est lui aussi consommé
jusqu’à sa fin ; les erreurs d’intégrité, frames ou membres tronqués et octets
finaux étrangers sont refusés selon les garanties du codec et du backend.

Une archive vide correctement formée est valide. Une erreur de lecture, un
format inconnu, une structure ambiguë, une limite dépassée ou une incohérence
entre métadonnées et données provoque `(nil, message)`.

### Vérifications de sécurité

Après la validation technique, Babet applique aux entrées, dans leur ordre
d’archive, les mêmes règles que l’extraction réelle :

- chemin relatif non vide utilisant uniquement `/`, sans `.` ni `..`, sans
  double séparateur, backslash, préfixe de lecteur ou octet NUL ;
- longueur extractible maximale de 4096 octets ;
- uniquement des fichiers réguliers et répertoires ordinaires ;
- aucun symlink, hard link, FIFO, socket, périphérique, objet non pris en charge
  ou fichier sparse ;
- aucun doublon exact, doublon de chemin de sortie ou conflit fichier/dossier ;
- aucune entrée ZIP chiffrée ou utilisant une méthode non prise en charge.

Le premier diagnostic est déterministe : Babet conserve l’ordre de lecture de
l’archive et arrête la vérification au premier échec selon les phases ci-dessus.
Un succès garantit donc que `files + directories == entries`.

### Structure retournée

```lua
{
    format = "tar",
    compression = "zstd",
    entries = 42,
    files = 35,
    directories = 7,
    total_size = 12345678,
    archive_size = 3456789,
    total_name_bytes = 812,
    zip64 = nil,
}
```

- `format` vaut `"zip"` ou `"tar"` ;
- `compression` vaut `"none"`, `"gzip"`, `"xz"`, `"bzip2"` ou `"zstd"` ;
- `entries`, `files` et `directories` comptent les entrées validées ;
- `total_size` est la somme des tailles décompressées des fichiers réguliers ;
- `archive_size` est la taille en octets du fichier archive épinglé ;
- `total_name_bytes` est la somme des longueurs brutes des noms ;
- `zip64` est un booléen pour ZIP et `nil` pour TAR.

La fonction renvoie exactement `(result, nil)` en cas de succès et
`(nil, message)` en cas d’échec.

### Exemples d’utilisation

Vérifier simplement une archive avant de la conserver :

```lua
local result, err = babet.archive.test("upload.zip")
if not result then
    io.stderr:write("archive refusée : ", err, "\n")
    return 1
end

print(result.format, result.entries, result.total_size)
```

Vérifier un TAR compressé, même lorsque son extension est trompeuse :

```lua
local result, err = babet.archive.test("sauvegarde.bin")
assert(result, err)
assert(result.format == "tar")
assert(result.compression == "zstd")
```

Resserrer uniquement le nombre d’entrées :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 500,
})
assert(result, err)
```

Resserrer uniquement la taille d’un fichier :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entry_size = 16 * 1024 * 1024,
})
assert(result, err)
```

Resserrer uniquement la taille totale :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_size = 128 * 1024 * 1024,
})
assert(result, err)
```

Resserrer uniquement la longueur des noms :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_path_length = 4096,
})
assert(result, err)
```

Resserrer uniquement le budget cumulé des noms :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_total_name_bytes = 1024 * 1024,
})
assert(result, err)
```

Resserrer uniquement le rapport de compression :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_compression_ratio = 100,
})
assert(result, err)
```

Combiner toutes les limites pour une archive non fiable :

```lua
local result, err = babet.archive.test("upload.zip", {
    max_entries = 500,
    max_entry_size = 16 * 1024 * 1024,
    max_total_size = 128 * 1024 * 1024,
    max_path_length = 4096,
    max_total_name_bytes = 1024 * 1024,
    max_compression_ratio = 100,
})
assert(result, err)
```

Distinguer une inspection diagnostique d’un verdict strict :

```lua
local info, list_err = babet.archive.list("upload.zip")
assert(info, list_err)

local verified, test_err = babet.archive.test("upload.zip")
if not verified then
    print("contenu visible mais archive refusée :", test_err)
end
```

Utiliser `test()` dans un worker :

```lua
local worker, err = babet.workers.spawn([[
local result, test_err = babet.archive.test(worker.args.archive, {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
if not result then error(test_err) end
return result
]], { archive = "backup.tar.zst" })
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.format, result.compression, result.entries)
```

Le comportement et le contrat de retour sont identiques en mode dossier, en
mode embarqué, en mode embarqué via `PATH` et dans les workers.

<a id="babetarchiveextract"></a>

## `babet.archive.extract`

```lua
local result, err = babet.archive.extract(
    archive,
    destination
    [, opts]
)
```

`archive` peut être un ZIP, un TAR brut, un TAR gzip, un TAR xz, un TAR bzip2
ou un TAR zstd. Le format et la compression sont détectés par le contenu, pas
par l'extension.

Options acceptées :

| Option | Défaut | Comportement |
| --- | ---: | --- |
| `overwrite` | `false` | autorise le remplacement atomique d'un fichier régulier existant |
| `dry_run` | `false` | prévisualise l'extraction et vérifie les données sélectionnées sans modifier le système de fichiers |
| `preserve_permissions` | `false` | conserve les bits Unix ordinaires `rwx` lorsqu'ils sont disponibles |
| `include` | aucune | tableau dense de globs sûrs sélectionnant les chemins internes normalisés |
| `exclude` | aucune | tableau dense de globs sûrs retirés après inclusion ; l'exclusion gagne toujours |
| `max_entries` | `10000` | nombre maximal d'entrées analysées ; plafond fixe `100000` |
| `max_entry_size` | `256 * 1024 * 1024` | taille décompressée maximale d'une entrée ; plafond fixe 8 Gio |
| `max_total_size` | `1024 * 1024 * 1024` | somme maximale des tailles déclarées ; plafond fixe 64 Gio |
| `max_path_length` | `64 * 1024` | longueur maximale d'un nom brut ; plafond fixe 1 Mio |
| `max_total_name_bytes` | `64 * 1024 * 1024` | somme maximale des longueurs de noms ; plafond fixe 64 Mio |
| `max_compression_ratio` | `1000` | rapport décompressé/compressé maximal, entre `1` et `1000000000` |

Les booléens doivent être de vrais booléens Lua, les limites entières de vrais
entiers Lua strictement positifs et `max_compression_ratio` un nombre fini. Les
clés inconnues, les arguments supplémentaires et les options propres à
`create()` sont refusés. `dry_run`, `include` et `exclude` ne sont acceptées que
par `extract()`, pas par `list()`, `read()`, `test()` ni `extractFile()`.

### Sélection par globs sûrs

`include` et `exclude` réutilisent exactement le même moteur borné que
[`archive.create()`](#babetarchivecreate). Il n'existe pas de second moteur ni
de variante propre à l'extraction.

Une liste `include` absente ou vide conserve le comportement historique et
sélectionne initialement toutes les entrées. Avec une liste `include` non vide,
une entrée est retenue si au moins un motif correspond. `exclude` est appliqué
ensuite et gagne toujours, même lorsqu'un chemin correspond aussi à
`include`.

Les motifs sont ancrés sur le **chemin interne normalisé complet** de l'entrée,
avec `/` comme séparateur. Les comparaisons sont orientées octets et sensibles
à la casse :

- `*` correspond à zéro ou plusieurs octets sauf `/` ;
- `**` correspond à zéro ou plusieurs octets, y compris `/` ;
- `?` correspond à exactement un octet sauf `/` ;
- `\x` protège l'octet suivant `x`.

Un répertoire est testé sous les formes `chemin` et `chemin/`. Exclure
`src/generated` ou `src/generated/**` exclut donc le répertoire et coupe tout
son sous-arbre, même si l'archive ne contient pas d'entrée de répertoire
explicite. Les seuls parents nécessaires aux fichiers retenus sont créés ; un
répertoire explicite non sélectionné n'est pas créé. Un répertoire vide n'est
restauré que si son entrée explicite est sélectionnée.

Les mêmes limites que pour la création sont appliquées : chaque motif est
limité à 4096 octets ; `include` et `exclude` sont limités ensemble à 256
motifs et 256 Kio de texte, un million d'évaluations et un budget fixe de
100 000 000 cellules de correspondance par appel. Le graphe normalisé utilisé
pour propager l'exclusion des répertoires est en outre plafonné à 100000 chemins
de répertoire uniques et à 64 Mio de texte cumulé. Dépasser une limite fait
échouer l'opération avant toute publication. L'ordre des motifs ne modifie pas
la sélection.

### Simulation sans écriture avec `dry_run`

Avec `dry_run = true`, Babet construit exactement le même plan qu'une extraction
réelle, mais n'appelle aucune opération de création, d'écriture, de chmod, de
renommage, de suppression ni de publication. L'archive est épinglée et analysée,
les mêmes limites et filtres sont appliqués, les entrées sélectionnées sont
validées, puis la destination est parcourue uniquement en lecture avec
`openat`/`fstatat` et `O_NOFOLLOW`. Aucun dossier racine, parent implicite,
fichier temporaire ou entrée finale n'est créé.

Le contrôle de destination conserve la politique réelle :

- une racine absente est acceptée et signalée par
  `would_create_destination = true` ;
- une racine ou un parent existant qui est un symlink ou un objet non dossier
  est refusé ;
- une entrée sélectionnée absente compte dans `would_create` ;
- un fichier régulier existant compte dans `would_overwrite` uniquement avec
  `overwrite = true` ; avec `overwrite = false`, l'appel échoue comme
  l'extraction réelle ;
- un répertoire explicite sélectionné et déjà présent compte dans
  `would_skip`, car l'extraction réelle le conserve et ne modifie pas son mode ;
- un conflit fichier/répertoire ou une cible finale symlinkée reste une erreur.

`would_create`, `would_overwrite` et `would_skip` comptent seulement les
**entrées explicites sélectionnées dans l'archive**. Leur somme vaut donc
`entries`. La racine de destination et les parents implicites nécessaires ne
sont pas inclus dans ces compteurs ; la racine dispose de son booléen séparé.
Lorsque des filtres actifs ne sélectionnent rien, le comportement reste celui de
l'extraction réelle : la destination n'est pas inspectée et
`would_create_destination` vaut `false`. À l'inverse, une archive vide sans
filtre prévisualise bien la création éventuelle de sa racine.

La simulation vérifie réellement les données qui seraient extraites. Pour ZIP,
chaque fichier régulier sélectionné est décompressé vers un consommateur nul et
son CRC est contrôlé ; les payloads ZIP non sélectionnés restent ignorés, comme
pour l'extraction sélective réelle. Pour TAR, la seconde passe consomme le flux
complet brut ou compressé et compare de nouveau les en-têtes au plan initial,
sans transmettre les données au système de fichiers. `archive.test()` reste
l'API à utiliser lorsqu'il faut vérifier tous les payloads ZIP, y compris ceux
qui seraient ignorés.

Le résultat décrit un **instantané**. Un autre processus peut modifier la
destination après le retour de `dry_run`; la simulation n'est donc jamais une
garantie qu'une extraction ultérieure réussira ni qu'elle produira les mêmes
compteurs. L'extraction réelle recommence tous les contrôles et épingle les
descripteurs nécessaires avant toute publication.

### Validation, entrées ignorées et intégrité

Babet épingle d'abord le fichier d'archive et inspecte **toutes les entrées et les métadonnées nécessaires au plan** afin
d'appliquer les limites globales avant d'ouvrir la destination. La sélection
est ensuite calculée sur les noms normalisés. Seules les entrées retenues
participent au plan de sortie :

- un doublon, une collision fichier/répertoire, un lien ou un objet spécial
  présent uniquement hors sélection n'empêche pas l'extraction ;
- une entrée dangereuse sélectionnée reste refusée avant toute écriture ;
- avec une liste `include` non vide, un chemin dangereux sans forme normalisée
  ne peut correspondre à aucun motif et reste hors sélection ;
- avec seulement `exclude`, le comportement historique « tout sélectionner »
  reste actif : un chemin dangereux ne peut pas être rendu sûr par un motif
  d'exclusion et fait donc échouer l'appel ;
- les collisions déjà présentes sur le disque mais situées hors sélection ne
  sont ni remplacées ni modifiées.

Cette politique permet d'extraire une partie sûre d'une archive mixte sans
présenter `exclude` comme un mécanisme de réparation de chemins invalides.
Toutes les limites d'entrées, de tailles, de noms et de rapport de compression
continuent à porter sur l'archive inspectée entière, pas seulement sur les
fichiers retenus.

Pour ZIP, les payloads ignorés ne sont pas décompressés et leur CRC n'est donc
pas vérifié par l'extraction sélective. Pour TAR, le lecteur doit avancer dans
le flux jusqu'aux en-têtes suivants, y compris dans un flux compressé, mais
`extract()` n'est pas l'API de vérification complète. Appeler
[`archive.test()`](#babetarchivetest) avant l'extraction lorsqu'il faut garantir
l'intégrité de **toutes** les entrées, y compris celles qui seront ignorées.

Avant toute publication, Babet refuse les entrées retenues non extractibles,
les sorties retenues dupliquées, les conflits fichier/répertoire retenus et les
objets existants incompatibles dans la destination. Les fichiers sélectionnés
sont préparés dans la destination sécurisée puis publiés atomiquement. Pour
TAR, le même fichier épinglé est relu depuis le début et chaque en-tête est
comparé au plan issu de la première passe.

Lorsque des filtres actifs ne sélectionnent rien, l'appel réussit sans créer la
destination. Sans filtre, une archive vide conserve le comportement historique
et crée le répertoire racine de destination.

### Valeur de retour

La fonction renvoie exactement `(result, nil)` ou `(nil, message)` :

```lua
{
    entries = 28,     -- entrées réellement sélectionnées
    files = 24,       -- fichiers réguliers sélectionnés
    directories = 4, -- répertoires explicites sélectionnés
    skipped = 15,     -- entrées de l'archive non sélectionnées
    bytes = 987654,   -- octets décompressés des fichiers sélectionnés
    path = "restauration",
}
```

Avec `dry_run = true`, la même table reçoit en plus :

```lua
{
    dry_run = true,
    would_create = 20,
    would_overwrite = 3,
    would_skip = 5,
    would_create_destination = false,
}
```

Ces champs supplémentaires sont absents d'une extraction réelle afin de ne pas
modifier son contrat historique. `directories` ne compte pas les parents
implicites créés pour atteindre un fichier. `entries == files + directories`
pour une extraction réussie, puisque les liens et objets spéciaux sélectionnés
sont refusés. En simulation réussie, `would_create + would_overwrite +
would_skip == entries`. `skipped` vaut `0` lorsqu'aucun filtre n'est actif.

### Exemples

Prévisualiser une extraction vers une destination absente :

```lua
local plan, err = babet.archive.extract("backup.zip", "restore", {
    dry_run = true,
})
assert(plan, err)
assert(plan.dry_run == true)
assert(plan.would_create_destination == true)
assert(not babet.fileExists("restore"))
```

Prévisualiser les remplacements autorisés dans une destination existante :

```lua
local plan, err = babet.archive.extract("backup.tar.zst", "restore", {
    dry_run = true,
    overwrite = true,
    preserve_permissions = true,
})
assert(plan, err)
print(plan.would_create, plan.would_overwrite, plan.would_skip)
```

Sans `overwrite = true`, un fichier final déjà présent reste une erreur :

```lua
local plan, err = babet.archive.extract("backup.zip", "restore", {
    dry_run = true,
})
assert(plan == nil and type(err) == "string")
```

Combiner simulation, sélection et limites :

```lua
local plan, err = babet.archive.extract("project.tar.xz", "output", {
    dry_run = true,
    include = { "src/**", "docs/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
    overwrite = true,
    preserve_permissions = true,
    max_entries = 20000,
    max_total_size = 2 * 1024 * 1024 * 1024,
})
assert(plan, err)
assert(plan.would_create + plan.would_overwrite + plan.would_skip
    == plan.entries)
assert(not babet.fileExists("output"))
```

Extraire seulement deux zones précises :

```lua
local result, err = babet.archive.extract("project.tar.zst", "output", {
    include = {
        "src/**",
        "README.md",
    },
})
assert(result, err)
print(result.entries, result.skipped)
```

Exclure les fichiers temporaires tout en conservant le reste :

```lua
local result, err = babet.archive.extract("backup.zip", "restore", {
    exclude = {
        "**/*.tmp",
        "cache/**",
    },
})
assert(result, err)
```

Combiner inclusion et exclusion, avec priorité aux exclusions :

```lua
local result, err = babet.archive.extract("project.tar.xz", "output", {
    include = {
        "src/**",
        "docs/**",
        "README.md",
    },
    exclude = {
        "src/generated/**",
        "**/*.tmp",
    },
    overwrite = false,
    preserve_permissions = true,
    max_total_size = 2 * 1024 * 1024 * 1024,
})
assert(result, err)
```

Utiliser `?` et protéger un caractère `*` littéral :

```lua
local result, err = babet.archive.extract("assets.zip", "assets", {
    include = {
        "icons/icon-?.png", -- icon-a.png, mais pas icon-large.png
        "docs/file\\*.txt", -- nom contenant réellement un astérisque
    },
})
assert(result, err)
```

Gérer une sélection vide sans créer de dossier :

```lua
local result, err = babet.archive.extract("package.zip", "unused", {
    include = { "does-not-exist/**" },
})
assert(result, err)
assert(result.entries == 0 and result.skipped > 0)
assert(not babet.fileExists("unused"))
```

Utiliser les filtres dans un worker :

```lua
local worker, err = babet.workers.spawn([[
local result, extract_err = babet.archive.extract(
    worker.args.archive,
    worker.args.destination,
    {
        include = { "docs/**", "README.md" },
        exclude = { "docs/drafts/**" },
    }
)
if not result then error(extract_err) end
return result
]], {
    archive = "package.tar.gz",
    destination = "documentation",
})
assert(worker, err)

local joined, result = worker:join()
assert(joined, result)
print(result.files, result.skipped)
```

Prévisualiser dans un worker sans créer la destination :

```lua
local worker, err = babet.workers.spawn([[
local plan, extract_err = babet.archive.extract(
    worker.args.archive, worker.args.destination, {
        dry_run = true,
        include = { "manifest.json", "docs/**" },
    })
if not plan then error(extract_err) end
return plan
]], {
    archive = "package.tar.gz",
    destination = "preview-only",
})
assert(worker, err)

local joined, plan = worker:join()
assert(joined, plan)
assert(plan.dry_run == true)
assert(not babet.fileExists("preview-only"))
```

Le contrat, les limites et la sélection sont identiques en mode dossier, en
mode embarqué, en mode embarqué via `PATH` et dans les workers.

<a id="babetarchiveextractfile"></a>

## `babet.archive.extractFile`

```lua
local result, err = babet.archive.extractFile(
    archive,
    entry,
    destination
    [, opts]
)
```

`archive` peut être un ZIP, un TAR brut, un TAR gzip, un TAR xz, un TAR bzip2
ou un TAR zstd ; la
détection repose sur le contenu et non sur l’extension. Le ZIP reste traité par miniz. Le TAR utilise
la même source épinglée et la même lecture libarchive en deux passes que
l’extraction complète.

`entry` est le **nom brut exact** exposé par `list()`. La recherche est sensible
à la casse et échoue si le nom est absent ou apparaît plusieurs fois. Pour TAR,
les noms longs GNU et les enregistrements pax `path` sont recherchés après leur
décodage par libarchive, exactement tels qu’ils figurent dans
`list().entries[i].name`.

Seule une entrée de type fichier régulier peut être sélectionnée. Les fichiers
TAR sparse, symlinks, hard links, répertoires et types spéciaux sont refusés
lorsqu’ils sont sélectionnés. Le chemin de l’entrée n’est pas reproduit : le
contenu est écrit exactement dans le chemin `destination` fourni par
l’appelant.

```lua
local result, err = babet.archive.extractFile(
    "package.tar",
    "assets/logo.bin",
    "cache/current-logo.bin",
    { overwrite = true }
)
```

Résultat :

```lua
{
    bytes = 4096,
    path = "cache/current-logo.bin",
    entry = "assets/logo.bin",
}
```

Les limites anti-bombe restent calculées sur l’ensemble de l’archive. Pour TAR,
la première passe consomme et valide tous les flux de données. La seconde
compare chaque en-tête avec le plan inspecté et parcourt l’archive jusqu’à sa
fin avant de publier le fichier temporaire sélectionné. Les données des autres
fichiers réguliers sont ignorées ; un chemin dangereux, un type spécial ou un
fichier sparse non sélectionné n’empêche donc pas de choisir un fichier
régulier sûr. En revanche, toute donnée malformée ou tronquée ailleurs dans
l’archive fait échouer l’opération sans publier la destination.

## Règles de chemins

Pour une extraction complète, chaque nom d’entrée doit respecter toutes les
règles suivantes :

- entre 1 et 4096 octets ;
- aucun octet NUL ;
- aucun `\` ;
- pas de `/` initial ;
- pas de préfixe de lecteur comme `C:` dans le premier composant ;
- aucun composant vide (`a//b`) ;
- aucun composant `.` ou `..` ;
- un `/` terminal uniquement pour une véritable entrée répertoire.

Les chemins restent relatifs à la destination. Babet ne transforme jamais un
nom Windows en chemin Linux et ne « nettoie » jamais silencieusement une
traversée : l’archive est refusée. Avec `extractFile()`, les mêmes règles
s’appliquent au nom de l’entrée sélectionnée ; les noms dangereux non
sélectionnés ne deviennent jamais des chemins de destination.

`read()` constitue volontairement l’exception : comme elle n’écrit rien, elle
peut sélectionner un fichier régulier au nom dangereux par son nom brut ou son
index. Elle ne normalise jamais ce nom et ne l’utilise jamais comme chemin.

Les doublons sont détectés après normalisation du `/` terminal des
répertoires. Une archive contenant deux sorties identiques, ou `node` comme
fichier puis `node/child`, est refusée avant extraction.

## Protection de la destination

La sécurité ne repose pas seulement sur une comparaison de chaînes. Babet
parcourt la destination composant par composant avec des descripteurs de
répertoire et refuse de suivre les symlinks :

- un symlink dans le chemin racine de destination est refusé ;
- un parent symlinké sous la destination est refusé ;
- une cible finale symlinkée est refusée, même avec `overwrite = true` ;
- un fichier ne peut remplacer qu’un fichier régulier ;
- une entrée répertoire ne peut utiliser qu’un répertoire existant ou nouveau.

Les répertoires déjà présents sont acceptés s’ils sont réels et restent
inchangés. Babet ne modifie pas leurs permissions.

Le chemin de destination lui-même est fourni par le script et peut être
absolu ou relatif. Les règles sur `..` décrites plus haut concernent les noms
non fiables contenus dans l’archive.

## Publication atomique et nettoyage

`create()` écrit le ZIP, TAR brut, TAR gzip ou TAR xz complet dans un
temporaire unique de mode
`0600`, placé dans le répertoire de destination. Son nom interne court ne
reprend pas le nom de sortie, afin qu’une destination valide proche de la
limite `NAME_MAX` reste créable. Après finalisation du répertoire central ZIP
par miniz ou du flux TAR par libarchive, Babet vide les tampons, exécute
`fsync`, passe le fichier en `0644`, le publie
atomiquement, puis synchronise le répertoire parent. Sans écrasement, la
publication par hard link refuse toute cible apparue entre-temps ; avec
écrasement, un `rename` du même répertoire remplace atomiquement la cible. Toute
erreur antérieure à la publication supprime le temporaire et laisse l’ancienne
destination intacte. Si le `fsync` final du répertoire parent échoue, la nouvelle
archive est déjà publiée atomiquement, mais l’appel renvoie une erreur car la
persistance après panne ne peut pas être confirmée.

Chaque fichier extrait est écrit progressivement vers un fichier temporaire
unique créé dans son répertoire final avec le mode `0600`. Les noms temporaires
sont choisis de façon à ne jamais entrer en collision avec une sortie déclarée
par l’archive. L’écriture est bornée par la taille annoncée. Pour ZIP, miniz
vérifie la décompression et le CRC. Pour TAR, libarchive fournit les blocs en
flux et Babet vérifie leur ordre, leurs bornes et la taille finale annoncée.
Pour un TAR enveloppé dans gzip, Babet valide en plus le CRC et l’ISIZE de
chaque membre gzip avec zlib avant toute publication. Le temporaire reçoit
ensuite ses permissions finales.

Tous les fichiers d’une extraction complète sont préparés avant le début de la
publication : une erreur de lecture, de décompression ou de CRC ne publie donc
aucun fichier. `extractFile()` conserve lui aussi son fichier sélectionné en
temporaire jusqu’à la fin de la lecture vérifiée de toute l’archive. Les
temporaires sont supprimés et les nouveaux répertoires encore vides créés
**sous** la destination sont retirés. Les composants du chemin racine de
destination qui ont dû être créés peuvent rester présents.

La publication est atomique **fichier par fichier** :

- sans écrasement, Babet utilise une création qui échoue si la cible existe ;
- avec écrasement, le temporaire du même répertoire remplace atomiquement le
  fichier régulier cible.

L’opération entière n’est toutefois pas une transaction multi-fichiers. Une
erreur système très tardive pendant la publication ou la mise en permissions
des répertoires peut survenir après la publication de fichiers précédents. Ces
fichiers peuvent alors rester présents, et un ancien fichier déjà remplacé
n’est pas restauré.

Pour l’extraction, la publication atomique protège contre un fichier
partiellement visible, mais ne garantit pas la persistance après une panne
brutale : les fichiers et répertoires extraits ne sont pas tous synchronisés
par `fsync`. `create()` applique la séquence plus forte de synchronisation du
fichier et du parent décrite plus haut.

## Permissions

Par défaut :

```text
fichiers                               0644
répertoires finaux                     0755
temporaires                             0600
répertoires d’archive pendant la préparation 0700
composants créés du chemin destination 0755 (soumis à l’umask)
```

Avec `preserve_permissions = true`, Babet conserve uniquement les neuf bits
ordinaires propriétaire/groupe/autres (`0777`) des modes Unix annoncés par le
ZIP ou le TAR. Les bits setuid, setgid et sticky sont systématiquement
supprimés.

Les permissions d’un répertoire créé sont appliquées seulement après
l’extraction de son contenu, afin qu’un mode final restrictif comme `0000`
n’empêche pas l’opération en cours. Les répertoires préexistants ne sont jamais
rechmodés.

Les UID, GID, ACL, attributs étendus et dates ne sont pas restaurés.

## Types d’entrées pris en charge

| Type | `create()` | `list()` | `read()` | `extract()` | `extractFile()` |
| --- | --- | --- | --- | --- | --- |
| fichier régulier | pris en charge | inspecté | pris en charge, sauf TAR sparse | pris en charge, sauf TAR sparse | pris en charge, sauf TAR sparse |
| répertoire | pris en charge si activé | inspecté | non sélectionnable | pris en charge | non sélectionnable |
| fichier TAR sparse | jamais créé | identifié en TAR | refusé | refusé | refusé s’il est sélectionné |
| symlink | refusé s’il est sélectionné | identifié | refusé | refusé | refusé |
| hard link | jamais créé | identifié en TAR | refusé | refusé | refusé s’il est sélectionné |
| FIFO, socket, périphérique, type inconnu | refusé s’il est sélectionné | identifié si exposé | refusé | refusé | refusé |
| entrée chiffrée | jamais créée | identifiée en ZIP | refusée | refusée | refusée |
| méthode de compression ZIP inconnue | jamais créée | identifiée | refusée | refusée | refusée |

Pendant la création, un symlink ou objet spécial retiré par les filtres est
ignoré plutôt qu’ouvert. Les entrées de répertoires ne sont émises qu’avec
`include_directories = true`.

Pour la création de fichiers réguliers, ZIP, gzip et xz acceptent les niveaux
`0` à `9` ; bzip2 accepte `1` à `9` ; zstd accepte `0` à `19` ; un TAR brut
stocke les octets source sans compression.

Une entrée ZIP qui ressemble à un hard link mais est encodée comme fichier
régulier est traitée comme un fichier régulier indépendant ; aucun lien n’est
créé.

## Erreurs et limites connues

Les causes courantes d’échec sont notamment :

- source absente ou dangereuse, symlink source, nom source non UTF-8, type
  source non pris en charge, format de création invalide, option réservée au ZIP
  utilisée pour TAR ou date hors de la plage ZIP ;
- archive de sortie dans la source, parent de destination dangereux ou symlink cible ;
- fichier d’archive absent, illisible, non régulier, non pris en charge ou malformé ;
- données TAR tronquées, données finales qui ne constituent pas un TAR,
  contenu attaché à une entrée TAR non régulière ou changement détecté entre
  l’inspection et l’extraction ;
- métadonnées incohérentes ou CRC invalide ;
- limite anti-bombe dépassée ;
- `max_size` dépassée pendant une lecture en mémoire ;
- nom dupliqué ambigu pour `read()` sans index explicite ;
- chemin absolu, traversée, doublon ou conflit ;
- entrée chiffrée, symlink ou type non pris en charge ;
- destination existante sans `overwrite = true` ;
- symlink ou type dangereux dans la destination ;
- manque d’espace, permissions insuffisantes ou erreur d’E/S.

Le module est synchrone : l'appel ne revient qu'après la fin de la création, de
l'inspection, de la lecture ou de l'extraction. Il n'expose pas encore de
progression, d'annulation ou de timeout.

Les six fonctions publiques `create()`, `list()`, `read()`, `test()`,
`extract()` et `extractFile()` partagent la même frontière d'exception C++.
Un échec d'allocation interne devient `(nil, "archive: out of memory")` ; une
autre exception interne devient `(nil, "archive: internal failure")` ou
`(nil, "archive: unknown internal failure")`. Aucune exception C++ ne traverse
la frontière Lua.

Le fichier d’archive ne doit pas être modifié simultanément. Une troncature ou
modification ZIP provoque normalement une erreur de lecture, décompression ou
CRC. Le TAR est parcouru en flux par libarchive ; les TAR concaténés sont lus
jusqu’à leur fin et les données tronquées ou finales qui ne constituent pas un
TAR sont refusées. Aucun des deux backends ne fournit d’instantané concurrent.
La destination ne doit pas non plus être réorganisée simultanément par un autre
processus. Les parcours refusent les symlinks et revérifient les types avant
publication, mais un acteur qui renomme activement des répertoires peut faire
échouer l’opération et rendre le nettoyage de ses temporaires seulement
« meilleur effort ».

La création TAR brute, TAR gzip, TAR xz, TAR bzip2 et TAR zstd est prise en
charge. Les flux compressés autonomes restent volontairement hors de cette API
d’archive et sont traités par [`babet.compression`](compression.md).

Les archives multi-disques ne constituent pas une cible prise en charge. ZIP64
est accepté lorsque miniz peut le lire, tout en restant soumis aux limites
configurées.
