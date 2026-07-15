# Archive — création, inspection et extraction ZIP sécurisées

## Périmètre

Le sous-module `babet.archive` crée, inspecte et extrait des archives **ZIP**
sans passer par une commande externe :

```lua
babet.archive.create(source, archive [, opts])
babet.archive.list(archive [, opts])
babet.archive.extract(archive, destination [, opts])
babet.archive.extractFile(archive, entry, destination [, opts])
```

Le module reste volontairement limité au format ZIP et ne prend pas en charge
TAR, GZIP, XZ, BZIP2 ou Zstandard.

Les quatre fonctions suivent le contrat habituel :

```lua
local result, err = babet.archive.list("backup.zip")
if not result then
    io.stderr:write(err, "\n")
end
```

Elles renvoient `(résultat, nil)` en cas de succès et `(nil, message)` en cas
d’échec. Une mauvaise arité ou un argument obligatoire qui n’est pas une
chaîne provoque une erreur Lua. Une table d’options invalide renvoie
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
    source,
    archive
    [, opts]
)
```

`source` doit être un répertoire existant. Babet archive son contenu, pas le
nom du répertoire source lui-même. Le parcours utilise des descripteurs et ne
suit aucun symlink. Un symlink dans le chemin ou l’arbre source, ainsi qu’un
FIFO, socket, périphérique ou autre objet non pris en charge, fait échouer
l’opération avant la publication de l’archive. Les noms d’entrées produits par
`create()` doivent être en UTF-8 valide : Linux autorise des noms contenant des
octets arbitraires, mais Babet refuse ceux qui produiraient un ZIP annonçant à
tort un nom UTF-8.

Options de création :

| Option | Défaut | Comportement |
| --- | ---: | --- |
| `compression_level` | `6` | entier de `0` (stockage) à `9` |
| `overwrite` | `false` | remplace atomiquement une archive régulière existante |
| `deterministic` | `true` | trie les noms et utilise la date fixe indépendante du fuseau : 1er janvier 1980 à 00:00:00 |
| `include_directories` | `true` | écrit les entrées répertoire, y compris les répertoires vides |
| `max_entries` | `10000` | nombre maximal d’entrées ; plafond absolu `100000` |
| `max_file_size` | `256 * 1024 * 1024` | taille maximale d’un fichier source ; plafond 8 Gio |
| `max_total_size` | `1024 * 1024 * 1024` | total maximal des octets source ; plafond 64 Gio |

Toutes les options entières exigent de vrais entiers Lua. Les options
booléennes exigent de vrais booléens Lua. Les clés inconnues sont refusées.

L’arbre source complet est analysé avant la création du fichier temporaire de
sortie. Chaque nom est borné à 4096 octets et leur somme à 64 Mio. Le parcours
possède aussi des plafonds fixes de 100000 objets du système de fichiers et 256
niveaux de répertoires, indépendamment de `include_directories`. Les fichiers
sont ensuite rouverts depuis le descripteur du répertoire source avec
`O_NOFOLLOW`. Le périphérique, l’inode, la taille, la date de modification et
la date de changement sont vérifiés avant et après compression ; un fichier
modifié pendant la création provoque un échec et la suppression du temporaire.

Le parent de destination doit déjà exister et ne contenir aucun symlink ni
composant `..`. La destination doit être absente sauf avec `overwrite = true`,
et ne peut jamais être un symlink ou un répertoire. L’archive ne peut pas être
créée dans l’arbre source, ce qui évite son auto-inclusion accidentelle.

Résultat :

```lua
{
    files = 12,
    directories = 3,
    bytes = 987654,
    path = "backup.zip",
    compression_level = 6,
    deterministic = true,
}
```

Avec le mode déterministe par défaut, des contenus et options identiques
produisent des archives strictement identiques octet par octet, y compris entre
plusieurs fuseaux horaires locaux. Avec `deterministic = false`, l’ordre trié
reste stable mais chaque entrée utilise la date de modification source, qui doit
être représentable dans le champ DOS du ZIP, donc comprise entre 1980 et 2107
dans le fuseau local. Les propriétaires, ACL, attributs étendus et bits de
permission ne sont pas copiés.
L’archive finale reçoit le mode `0644` ; les fichiers extraits gardent les
valeurs sûres décrites plus bas.

La sortie ZIP64 est activée automatiquement lorsque la préanalyse indique que
le nombre d’entrées classique ou les champs de taille sur 4 Gio risquent d’être
dépassés. Les petites archives restent des ZIP classiques.

La préanalyse et les contrôles de fichiers empêchent les substitutions par
symlink et détectent la modification de chaque fichier réellement archivé. La
création n’est toutefois pas un instantané du système de fichiers : un fichier
ajouté après l’analyse de son répertoire peut être absent du résultat ; un
fichier déjà recensé puis supprimé ou renommé fait normalement échouer sa
réouverture. Les renommages concurrents de répertoires ne sont pas signalés
comme conflit transactionnel.

Avec `include_directories = false`, les répertoires vides ne peuvent pas être
représentés et sont donc omis.

Exemple :

```lua
local result, err = babet.archive.create("projet", "projet.zip", {
    compression_level = 9,
    overwrite = true,
    max_total_size = 2 * 1024 * 1024 * 1024,
})
if not result then
    error(err)
end
```

## Options d’inspection/extraction et limites anti-bombe

Les options communes à `list()`, `extract()` et `extractFile()` sont :

| Option | Défaut | Maximum accepté | Effet |
| --- | ---: | ---: | --- |
| `max_entries` | `10000` | `100000` | nombre maximal d’entrées dans l’archive |
| `max_entry_size` | `256 * 1024 * 1024` | `8 * 1024^3` | taille décompressée maximale d’une entrée non répertoire |
| `max_total_size` | `1024 * 1024 * 1024` | `64 * 1024^3` | somme maximale des tailles décompressées des entrées non répertoire |
| `max_compression_ratio` | `1000` | `1000000000` | rapport maximal `taille décompressée / taille compressée`, entrée par entrée |

Les trois limites entières doivent être des **entiers Lua strictement positifs**.
`max_compression_ratio` doit être un nombre fini supérieur ou égal à `1`.
`NaN`, l’infini, les booléens et les chaînes numériques sont refusés.

Indépendamment des options, la somme des longueurs des noms d’entrées est
bornée en interne à 64 Mio. Cette limite fixe borne la mémoire consacrée aux
métadonnées, y compris lorsque `max_entries` est relevé explicitement.
Les allocations réalisées par le lecteur ZIP miniz sont en outre plafonnées à
128 Mio par archive. Le répertoire central et ses commentaires ne peuvent donc
pas provoquer une allocation mémoire arbitraire avant l’application des
limites entrée par entrée.

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

`archive` est le chemin d’un fichier ZIP. Le chemin peut être un symlink vers un fichier régulier : Babet ouvre une fois sa cible et conserve ce
même descripteur pendant l’analyse. Les répertoires, FIFO, sockets et
périphériques sont refusés avant le parseur ZIP ; l’ouverture non bloquante évite
notamment qu’un FIFO sans écrivain suspende `list()`, `extract()` ou
`extractFile()`. La fonction ouvre ensuite le répertoire central, applique les
limites précédentes et renvoie :

```lua
{
    entries = {
        {
            name = "docs/readme.txt", -- nom brut de l’entrée
            path = "docs/readme.txt", -- chemin normalisé pour l’extraction
            type = "file",            -- file, directory, symlink, unsupported
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
        },
    },
    count = 1,
    total_size = 1234,
    archive_size = 666,
    zip64 = false,
}
```

`path` retire le `/` terminal d’une entrée répertoire. Il n’est renseigné de
façon utile que si `safe_path == true`.

`extractable` indique que l’entrée possède un chemin acceptable, un type pris
en charge, une méthode de compression comprise par miniz et qu’elle n’est pas
chiffrée. Il ne prédit pas les conflits avec la destination ni les doublons
entre plusieurs entrées. Lorsque la valeur est `false`, `reason` décrit la
première raison de refus.

`unix_mode` contient uniquement les bits `0000` à `7777` annoncés par une
archive créée sur un système Unix. Il vaut `nil` lorsque cette information
n’existe pas. La présence d’un mode ne signifie pas qu’il sera conservé : voir
[`preserve_permissions`](#permissions).

Les noms lus dans une archive existante sont des chaînes d’octets. La
comparaison est exacte et sensible à la casse ; aucune normalisation Unicode
n’est appliquée. Cette tolérance d’inspection n’affaiblit pas `create()`, qui
n’émet que des noms UTF-8 valides.

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

Avant toute écriture de fichier, Babet :

1. inspecte toutes les métadonnées et applique les limites ;
2. refuse toute entrée non extractible ;
3. refuse les chemins de sortie dupliqués ;
4. refuse les conflits où un même chemin devrait être à la fois fichier et
   répertoire ;
5. vérifie les éléments déjà présents dans la destination.

Le résultat est :

```lua
{
    files = 12,
    directories = 3, -- entrées répertoire explicites dans le ZIP
    bytes = 987654,  -- octets décompressés des fichiers
    path = "restauration",
}
```

`directories` ne compte pas les parents implicites créés pour atteindre un
fichier.

Exemple :

```lua
local result, err = babet.archive.extract("backup.zip", "restore", {
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

`entry` est le **nom brut exact** présent dans l’archive. La recherche est
sensible à la casse. Elle échoue si le nom est absent ou apparaît plusieurs
fois.

Seule une entrée de type fichier régulier peut être sélectionnée. Le chemin de
l’entrée n’est pas reproduit : le contenu est écrit exactement dans le chemin
`destination` fourni par l’appelant.

```lua
local result, err = babet.archive.extractFile(
    "package.zip",
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

Les limites anti-bombe restent calculées sur l’ensemble de l’archive. En
revanche, les autres entrées ne sont pas extraites : une entrée non sélectionnée
qui possède un chemin dangereux ou un type non extractible n’empêche pas de
sélectionner une entrée sûre.

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
traversée : l’archive est refusée.

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

`create()` écrit le ZIP complet dans un temporaire unique de mode `0600`, placé
dans le répertoire de destination. Son nom interne court ne reprend pas le nom
de sortie, afin qu’une destination valide proche de la limite `NAME_MAX` reste
créable. Après finalisation du répertoire central,
Babet vide les tampons, exécute `fsync`, passe le fichier en `0644`, le publie
atomiquement, puis synchronise le répertoire parent. Sans écrasement, la
publication par hard link refuse toute cible apparue entre-temps ; avec
écrasement, un `rename` du même répertoire remplace atomiquement la cible. Toute
erreur antérieure à la publication supprime le temporaire et laisse l’ancienne
destination intacte. Si le `fsync` final du répertoire parent échoue, la nouvelle
archive est déjà publiée atomiquement, mais l’appel renvoie une erreur car la
persistance après panne ne peut pas être confirmée.

Chaque fichier extrait est extrait progressivement vers un fichier temporaire unique
créé dans son répertoire final avec le mode `0600`. Les noms temporaires sont
choisis de façon à ne jamais entrer en collision avec une sortie déclarée par
l’archive. L’écriture est bornée par la taille annoncée. miniz vérifie la
décompression et le CRC avant que le fichier soit publié. Le temporaire reçoit
ensuite ses permissions finales.

Tous les fichiers d’une extraction complète sont préparés avant le début de la
publication : une erreur de lecture, de décompression ou de CRC ne publie donc
aucun fichier. Les temporaires sont supprimés et les nouveaux répertoires
encore vides créés **sous** la destination sont retirés. Les composants du
chemin racine de destination qui ont dû être créés peuvent rester présents.

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
ZIP. Les bits setuid, setgid et sticky sont systématiquement supprimés.

Les permissions d’un répertoire créé sont appliquées seulement après
l’extraction de son contenu, afin qu’un mode final restrictif comme `0000`
n’empêche pas l’opération en cours. Les répertoires préexistants ne sont jamais
rechmodés.

Les UID, GID, ACL, attributs étendus et dates ne sont pas restaurés.

## Types d’entrées pris en charge

| Type | `create()` | `list()` | `extract()` / `extractFile()` |
| --- | --- | --- | --- |
| fichier régulier | pris en charge, stocké au niveau `0` ou DEFLATE sinon | inspecté | pris en charge |
| répertoire | pris en charge avec `include_directories = true` | inspecté | pris en charge par `extract()` |
| symlink | toujours refusé | identifié | toujours refusé |
| FIFO, socket, périphérique ou type de système de fichiers inconnu | toujours refusé | identifié | refusé |
| entrée chiffrée | non créée | identifiée | refusée |
| méthode de compression inconnue | non créée | identifiée | refusée |

Une entrée ZIP qui ressemble à un hard link mais est encodée comme fichier
régulier est traitée comme un fichier régulier indépendant ; aucun lien n’est
créé.

## Erreurs et limites connues

Les causes courantes d’échec sont notamment :

- source absente ou dangereuse, symlink source, nom source non UTF-8,
  date hors de la plage ZIP ou type source non pris en charge ;
- archive de sortie dans la source, parent de destination dangereux ou symlink cible ;
- fichier absent, illisible, non régulier ou ZIP malformé ;
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

Le fichier ZIP ne doit pas être modifié simultanément. Une troncature ou une
modification pendant l’opération provoque normalement une erreur de lecture,
de décompression ou de CRC, mais aucun instantané concurrent n’est garanti.
La destination ne doit pas non plus être réorganisée simultanément par un autre
processus. Les parcours refusent les symlinks et revérifient les types avant
publication, mais un acteur qui renomme activement des répertoires peut faire
échouer l’opération et rendre le nettoyage de ses temporaires seulement
« meilleur effort ».

Les archives multi-disques ne constituent pas une cible prise en charge. ZIP64
est accepté lorsque miniz peut le lire, tout en restant soumis aux limites
configurées.
