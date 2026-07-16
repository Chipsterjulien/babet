# Archive — opérations ZIP et TAR sécurisées avec gzip, xz, bzip2 ou zstd

## Périmètre

Le sous-module `babet.archive` crée, inspecte et extrait des archives **ZIP**,
**TAR** et **TAR compressées avec gzip, xz, bzip2 ou zstd**, sans lancer de
commande externe :

```lua
babet.archive.create(source_ou_sources, archive [, opts])
babet.archive.list(archive [, opts])
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

Les quatre fonctions suivent le contrat habituel :

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

Les options communes à `list()`, `extract()` et `extractFile()` sont :

| Option | Défaut | Maximum accepté | Effet |
| --- | ---: | ---: | --- |
| `max_entries` | `10000` | `100000` | nombre maximal d’entrées dans l’archive |
| `max_entry_size` | `256 * 1024 * 1024` | `8 * 1024^3` | taille décompressée maximale d’une entrée non répertoire |
| `max_total_size` | `1024 * 1024 * 1024` | `64 * 1024^3` | somme maximale des tailles décompressées des entrées non répertoire |
| `max_compression_ratio` | `1000` | `1000000000` | rapport par entrée pour ZIP ; rapport global octets fichiers décompressés / taille archive pour TAR gzip, xz, bzip2 ou zstd ; sans effet pour TAR brut |

Les trois limites entières doivent être des **entiers Lua strictement positifs**.
`max_compression_ratio` doit être un nombre fini supérieur ou égal à `1`.
`NaN`, l’infini, les booléens et les chaînes numériques sont refusés.

Indépendamment des options, la somme des longueurs des noms d’entrées est
bornée en interne à 64 Mio. Cette limite fixe borne la mémoire consacrée aux
métadonnées, y compris lorsque `max_entries` est relevé explicitement.
Les allocations réalisées par le lecteur ZIP miniz sont en outre plafonnées à
128 Mio par archive. Le répertoire central et ses commentaires ne peuvent donc
pas provoquer une allocation mémoire arbitraire avant l’application des
limites entrée par entrée. L’inspection TAR fonctionne en flux : Babet lit les
données de chaque entrée sans les conserver en mémoire, à la fois pour atteindre
l’en-tête suivant et pour détecter les données tronquées. Pour TAR gzip, Babet
effectue en plus une validation progressive et bornée avec zlib, car libarchive
ne vérifie pas lui-même le CRC/ISIZE de la bande-annonce gzip ; les bandes-
annonces corrompues et les données finales non gzip sont donc refusées. Le
bourrage nul standard après un membre gzip reste accepté. Pour TAR zstd, Babet
effectue une validation progressive et bornée indépendante avec libzstd : les
frames complètes et les frames concaténées valides sont acceptées, tandis que
corruption, troncature ou données finales étrangères sont refusées avant
publication.

Pour une extraction complète, l’arbre de sortie est aussi borné en interne à
100000 répertoires uniques, parents implicites compris, et à 64 Mio de chemins
de répertoires normalisés cumulés. Une poignée d’entrées extrêmement profondes
ne peut donc pas provoquer une explosion non bornée du nombre de `mkdir` ou de
la mémoire consacrée aux préfixes.

Ces limites sont appliquées pendant l’inspection de **toute l’archive**, y
compris avec `list()` et `extractFile()`. Ainsi, `extractFile()` ne contourne
pas la politique globale en sélectionnant une petite entrée au milieu d’une
archive dont les métadonnées annoncent une expansion excessive.

Une entrée non vide qui annonce une taille compressée nulle est toujours
refusée. Les répertoires ne comptent pas dans `max_entry_size`,
`max_total_size` ni le rapport de compression, mais ils comptent dans
`max_entries`.

Exemple :

```lua
local info, err = babet.archive.list("upload.zip", {
    max_entries = 2000,
    max_entry_size = 64 * 1024 * 1024,
    max_total_size = 512 * 1024 * 1024,
    max_compression_ratio = 200,
})
```

Les clés inconnues sont refusées. Les options propres à la création et à
l’extraction ne sont pas acceptées par `list()`.

<a id="babetarchivelist"></a>

## `babet.archive.list`

```lua
local info, err = babet.archive.list(archive [, opts])
```

`archive` est le chemin d’un fichier ZIP, TAR brut, TAR gzip, TAR xz, TAR
bzip2 ou TAR zstd.
L’extension ne sert pas à la détection. Le chemin peut être un symlink vers un fichier
régulier : Babet ouvre une seule fois sa cible et conserve ce même descripteur
pendant toute l’analyse. Les répertoires, FIFO, sockets et périphériques sont
refusés avant l’analyse du format ; l’ouverture non bloquante évite notamment
qu’un FIFO sans écrivain suspende `list()`.

Pour un ZIP, Babet essaie d’abord le lecteur miniz existant. Si le même fichier
épinglé n’est pas un ZIP, Babet rembobine ce descripteur et n’active que le
lecteur TAR de libarchive avec les filtres intégrés `none`, `gzip`, `xz`,
`bzip2` et `zstd`.
Aucun décompresseur externe ne peut être lancé par ce chemin. Les archives TAR
concaténées sont parcourues intégralement ; les données finales qui ne forment
pas un TAR, les contenus tronqués et les données attachées à une entrée non
régulière sont refusés. La fonction applique ensuite les limites précédentes et
renvoie :

```lua
{
    format = "zip",           -- "zip" ou "tar"
    compression = "none",    -- "none", "gzip", "xz", "bzip2" ou "zstd" pour TAR
    entries = {
        {
            name = "docs/readme.txt", -- nom brut de l’entrée
            path = "docs/readme.txt", -- chemin normalisé pour l’extraction
            type = "file",            -- voir les types d’entrées pris en charge ci-dessous
            size = 1234,
            compressed_size = 530,
            crc32 = 305419896,         -- entier non signé sur 32 bits
            compression_method = 8,
            encrypted = false,
            supported = true,
            safe_path = true,
            extractable = true,
            reason = nil,
            unix_mode = 420,           -- 0644, ou nil sans mode Unix
            sparse = false,
            link_target = nil,         -- cible d’un symlink/hard link TAR
        },
    },
    count = 1,
    total_size = 1234,
    archive_size = 666,
    zip64 = false,             -- nil pour TAR
}
```

`path` retire le `/` terminal d’une entrée répertoire. Il n’est renseigné de
façon utile que si `safe_path == true`.

Pour un ZIP, `extractable` indique que l’entrée possède un chemin acceptable,
un type pris en charge, une méthode de compression comprise par miniz et
qu’elle n’est pas chiffrée. Pour un TAR, les fichiers réguliers et répertoires
sûrs sont extractibles. Les fichiers sparse, symlinks, hard links, FIFO,
périphériques et autres types spéciaux TAR sont inspectés mais refusés avec une
raison explicite. `extractable` ne prédit jamais les conflits avec la
destination ni les doublons entre entrées.

Les champs propres au ZIP conservent leurs valeurs exactes antérieures. Pour un
TAR, `compressed_size`, `crc32` et `compression_method` valent `nil`, car TAR ne
porte ni compression ni CRC par entrée. `encrypted` vaut `false`, `supported`
indique que libarchive a pu analyser l’entrée, et `sparse` signale les
métadonnées de fichier creux. `link_target` contient la cible brute annoncée
pour un symlink ou hard link TAR lorsque libarchive l’expose, et vaut `nil`
sinon. Les types TAR retournés
par ce lot sont `file`, `directory`, `symlink`, `hardlink`, `fifo`,
`character_device`, `block_device`, `socket` et `unsupported`.

`unix_mode` contient uniquement les bits `0000` à `7777` annoncés par une
archive créée sur un système Unix. Il vaut `nil` lorsque cette information
n’existe pas. La présence d’un mode ne signifie pas qu’il sera conservé : voir
[`preserve_permissions`](#permissions).

Les noms ZIP lus dans une archive existante sont des chaînes d’octets. Les
chemins TAR sont les chaînes natives renvoyées par libarchive après traitement
des en-têtes TAR, y compris les préfixes ustar, noms longs GNU et champs `path`
pax. Les comparaisons sont exactes et sensibles à la casse, et Babet
n’effectue aucune normalisation Unicode supplémentaire. Cette tolérance
d’inspection n’affaiblit pas `create()`, qui n’émet que des
noms UTF-8 valides en ZIP comme en TAR.

<a id="babetarchiveextract"></a>

## `babet.archive.extract`

```lua
local result, err = babet.archive.extract(
    archive,
    destination
    [, opts]
)
```

Options supplémentaires :

| Option | Défaut | Comportement |
| --- | --- | --- |
| `overwrite` | `false` | autorise le remplacement atomique d’un fichier régulier existant |
| `preserve_permissions` | `false` | conserve les bits Unix ordinaires `rwx` lorsqu’ils sont disponibles |

Ces deux valeurs doivent être de vrais booléens Lua.

`archive` peut être un ZIP, un TAR brut, un TAR gzip, un TAR xz, un TAR bzip2
ou un TAR zstd ;
format et compression sont détectés par le contenu, pas par l’extension. Avant toute écriture de fichier, Babet :

1. inspecte intégralement l’archive et applique les limites ;
2. refuse toute entrée non extractible ;
3. refuse les chemins de sortie dupliqués ;
4. refuse les conflits où un même chemin devrait être à la fois fichier et
   répertoire ;
5. vérifie les éléments déjà présents dans la destination.

Pour un TAR, Babet relit ensuite le **même fichier épinglé** depuis le début,
compare chaque en-tête avec le plan issu de l’inspection, puis transmet les
blocs des fichiers réguliers à la couche de destination sécurisée. Une entrée
ajoutée, supprimée ou dont les métadonnées diffèrent entre les deux passes fait
échouer l’opération. Cette vérification ne constitue pas un instantané : une
modification concurrente de données de même taille peut encore être détectée
par une erreur de lecture, mais n’est pas garantie d’être distinguée si les
en-têtes restent identiques.

Le résultat est :

```lua
{
    files = 12,
    directories = 3, -- entrées répertoire explicites dans l’archive
    bytes = 987654,  -- octets décompressés des fichiers
    path = "restauration",
}
```

`directories` ne compte pas les parents implicites créés pour atteindre un
fichier.

Exemple :

```lua
local result, err = babet.archive.extract("backup.tar", "restore", {
    overwrite = false,
    preserve_permissions = true,
    max_total_size = 2 * 1024 * 1024 * 1024,
})

if not result then
    error(err)
end

print(result.files, result.bytes)
```

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

| Type | `create()` | `list()` | `extract()` | `extractFile()` |
| --- | --- | --- | --- | --- |
| fichier régulier | pris en charge | inspecté | pris en charge, sauf TAR sparse | pris en charge, sauf TAR sparse |
| répertoire | pris en charge si activé | inspecté | pris en charge | non sélectionnable |
| fichier TAR sparse | jamais créé | identifié en TAR | refusé | refusé s’il est sélectionné |
| symlink | refusé s’il est sélectionné | identifié | refusé | refusé |
| hard link | jamais créé | identifié en TAR | refusé | refusé s’il est sélectionné |
| FIFO, socket, périphérique, type inconnu | refusé s’il est sélectionné | identifié si exposé | refusé | refusé |
| entrée chiffrée | jamais créée | identifiée en ZIP | refusée | refusée |
| méthode de compression ZIP inconnue | jamais créée | identifiée | refusée | refusée |

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
- chemin absolu, traversée, doublon ou conflit ;
- entrée chiffrée, symlink ou type non pris en charge ;
- destination existante sans `overwrite = true` ;
- symlink ou type dangereux dans la destination ;
- manque d’espace, permissions insuffisantes ou erreur d’E/S.

Le module est synchrone : l’appel ne revient qu’après la fin de la création, de
l’inspection ou de l’extraction. Il n’expose pas encore de progression, d’annulation ou de
timeout.

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
