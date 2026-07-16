# Compression - flux gzip, xz, bzip2 et zstd autonomes

## Périmètre

`babet.compression` compresse ou décompresse les octets d’un seul fichier
régulier. Il traite des **flux autonomes**, et non des archives :

- gzip (`.gz` par convention) ;
- xz (`.xz`) ;
- bzip2 (`.bz2`) ;
- Zstandard (`.zst`).

Un flux autonome ne contient ni nom d’entrée portable, ni arborescence, ni
permissions, ni métadonnées d’archive. Utilisez
[`babet.archive`](archive.md) pour les ZIP et les TAR, notamment `.tar.gz`,
`.tar.xz`, `.tar.bz2` et `.tar.zst`.

## Vue d’ensemble de l’API

```lua
local ok, err = babet.compression.compress(
    source, destination, format [, opts]
)

local ok, err = babet.compression.decompress(
    source, destination [, opts]
)
```

Les deux fonctions renvoient :

- `true, nil` en cas de succès ;
- `nil, "message"` en cas d’erreur opérationnelle ou d’option.

Un mauvais type pour un argument obligatoire, un octet NUL intégré ou une
arité incorrecte provoque une erreur Lua. Les options inconnues sont refusées.

## `compress(source, destination, format [, opts])`

`source`, `destination` et `format` sont des chaînes Lua strictes. Les chemins
ne doivent être ni vides ni contenir d’octet NUL.

`format` doit être exactement l’une de ces valeurs :

```text
"gzip"  "xz"  "bzip2"  "zstd"
```

L’extension du fichier n’est ni examinée ni ajoutée automatiquement. Cet appel
est donc valide :

```lua
local ok, err = babet.compression.compress(
    "donnees.bin",
    "donnees.compressees",
    "zstd"
)
```

La table facultative accepte :

| Champ | Type | Défaut | Signification |
| --- | --- | ---: | --- |
| `overwrite` | booléen | `false` | Remplacer atomiquement un fichier destination régulier existant. |
| `level` | entier Lua | selon le format | Choisir explicitement le niveau de compression. |

`level` est un entier Lua strict. Les flottants, chaînes numériques et valeurs
hors limites sont refusés avant l’ouverture du fichier source. Les niveaux
acceptés et les valeurs utilisées lorsque le champ est absent sont :

| Format | Minimum | Maximum | Défaut |
| --- | ---: | ---: | ---: |
| gzip | `0` | `9` | `6` |
| xz | `0` | `9` | `6` |
| bzip2 | `1` | `9` | `9` |
| zstd | `1` | `22` | `3` |

Un niveau plus élevé privilégie généralement le taux de compression au prix de
plus de temps processeur et parfois de davantage de mémoire. Pour gzip, le
niveau `0` produit un flux valide sans compression DEFLATE. Les niveaux xz les
plus élevés peuvent consommer beaucoup de mémoire ; ils ne doivent être choisis
qu’explicitement.

### Exemple

```lua
local ok, err = babet.compression.compress(
    "base.dump",
    "base.dump.zst",
    "zstd",
    { overwrite = true, level = 10 }
)

if not ok then
    io.stderr:write(err, "\n")
    return 1
end
```

## `decompress(source, destination [, opts])`

Le format est détecté à partir des octets du flux et non de son extension.
Renommer `fichier.gz` en `fichier.bin` ne change donc pas son décodage. Les
données non compressées et les formats non pris en charge sont refusés.

La table facultative accepte :

| Champ | Type | Défaut | Signification |
| --- | --- | ---: | --- |
| `overwrite` | booléen | `false` | Remplacer atomiquement un fichier destination régulier existant. |
| `max_output_size` | entier Lua | 1 Gio | Nombre maximal d’octets décompressés acceptés. |

`max_output_size` doit être compris entre `1` et `68719476736` octets
(64 Gio). La limite est contrôlée avant chaque écriture. En cas de dépassement,
le fichier temporaire est supprimé et la destination n’est pas publiée.

### Exemple

```lua
local ok, err = babet.compression.decompress(
    "base.dump.zst",
    "base.dump",
    {
        overwrite = true,
        max_output_size = 4 * 1024 * 1024 * 1024,
    }
)

if not ok then
    io.stderr:write(err, "\n")
    return 1
end
```

## Flux concaténés et intégrité

Les membres gzip, flux xz, membres bzip2 et frames zstd valides concaténés sont
décodés dans leur ordre au sein du même fichier destination.

Les décodeurs vérifient les informations d’intégrité obligatoires ainsi que
tout checksum facultatif présent dans le flux. Les frames zstd produites par
Babet activent le checksum de contenu facultatif. Une frame zstd externe qui ne
le contient pas reste lisible, mais le format ne peut alors pas détecter toute
altération possible des données. Babet refuse :

- les flux tronqués ;
- les checksums ou frames corrompus ;
- les octets arbitraires ajoutés après le dernier membre ou la dernière frame ;
- les entrées dont la signature ne correspond à aucun format pris en charge.

## Garanties sur les fichiers et la publication

Le module applique une politique fail-closed :

- la source doit être un véritable fichier régulier ;
- une source qui est un symlink est refusée ;
- les parents de la source et de la destination doivent déjà exister et sont
  ouverts composant par composant avec `O_NOFOLLOW` ;
- les composants `..` sont refusés dans ces chemins parents ;
- un symlink ou un objet non régulier en destination est refusé ;
- la source et la destination ne doivent pas désigner le même inode, y compris
  via un lien physique ;
- le descripteur source est épinglé et sa taille ainsi que ses timestamps sont
  revérifiés avant publication ;
- la sortie est écrite progressivement dans un temporaire de mode `0600` situé
  dans le dossier destination ;
- le fichier terminé est synchronisé, placé en mode `0644`, puis publié
  atomiquement ;
- avec `overwrite = false`, la publication ne peut pas remplacer une
  destination apparue concurremment ;
- les temporaires sont supprimés lors des échecs antérieurs à la publication.

Le module n’utilise jamais de shell et ne déduit jamais le nom de destination
de métadonnées compressées.

## Données binaires et mémoire

Les entrées et sorties sont des flux d’octets. Les octets NUL et les contenus
binaires arbitraires sont préservés.

La compression et la décompression utilisent des buffers de travail bornés de
64 Kio. L’entrée ou la sortie complète n’est chargée ni dans l’état Lua ni dans
une chaîne C++ unique. `max_output_size` borne en plus l’expansion lors de la
décompression. Le décodeur xz possède un plafond mémoire interne de 256 Mio et
le décodeur zstd refuse les fenêtres supérieures à 128 Mio.

## Workers

`babet.compression` est enregistré dans chaque état Lua worker. Plusieurs
workers peuvent traiter des fichiers différents en parallèle. Les règles
ordinaires de collision du système de fichiers restent applicables lorsque
plusieurs workers visent la même destination.

## Exemples d’erreur

```lua
local ok, err = babet.compression.compress(
    "entree.bin", "entree.bin.gz", "zip"
)
-- nil, "compression: format must be 'gzip', 'xz', 'bzip2', or 'zstd'"

ok, err = babet.compression.decompress(
    "gros.gz", "gros.bin", { max_output_size = 1024 }
)
-- nil, "compression: decompressed output exceeds opts.max_output_size"
```

Une opération en échec doit toujours être traitée avant d’utiliser la
destination.
