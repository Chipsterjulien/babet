> [English](README.md) | **Français**

<p align="center">
  <img src="docs/assets/babet-closed.png" alt="Babet — pomme de pin" width="200">
</p>

# Babet

> *Babet*, n.m. — mot régional du sud-est de la France
> (Lyonnais, Forez, Dauphiné, Savoie et Suisse romande voisine)
> désignant une pomme de pin. Petite, légère, pleine de graines et
> capable d’allumer un feu — comme ce binaire.

Babet est un binaire Lua 5.5 autonome pour le scripting et l’automatisation
sous Linux, écrit en C++23. OpenSSL, SQLite, miniz, libarchive, zlib,
liblzma, libbz2, libzstd, RE2, Abseil, nlohmann/json, cpp-httplib et
tomlplusplus sont liés statiquement : un seul binaire, sans dépendance système
autre que glibc.

Version stable et auditée actuelle : **2.7.0**. Voir le
[journal des modifications français](CHANGELOG.fr.md) ou le
[changelog anglais](CHANGELOG.md).

Babet s’utilise de trois façons :

1. **Interpréteur Lua** : `babet script.lua` ou `babet dossier/`
   (recherche de `main.lua`).
2. **Créateur d’exécutable** : `babet --create-exe ./monprojet application`
   produit un exécutable autonome contenant le script et ses modules `require`.
3. **Bibliothèque de bindings** : les scripts disposent notamment de
   `babet.json`, `babet.http`, `babet.sqlite`, `babet.socket`,
   `babet.inotify`, `babet.workers`, `babet.user`, `babet.exec`, le streaming
   `babet.spawn`, les pipelines `babet.pipeline` / `babet.spawnPipeline`, les
   archives ZIP et TAR sécurisées `babet.archive`, les flux autonomes
   gzip/xz/bzip2/zstd via `babet.compression` et le téléchargement direct
   `babet.http.download`.

## Démarrage rapide

```sh
git clone https://github.com/Chipsterjulien/babet.git
cd babet
./build_local.sh
./run_tests.sh
./test/babet --help
```

Le premier build télécharge et compile les dépendances. Il faut un compilateur
C++23, CMake 3.22 ou plus récent, `wget`, `unzip` et `xz`.

### Télécharger une grosse réponse HTTP sans la garder en mémoire

```lua
assert(babet.mkdir("downloads"))
local result, err = babet.http.download(
    "https://example.com/archive.tar.gz",
    "downloads/archive.tar.gz",
    {
        timeout = 120,
        follow_redirects = true,
        max_file_size = 512 * 1024 * 1024,
    }
)
assert(result, err)
assert(result.saved, "HTTP " .. result.status)
```

La réponse est écrite dans un temporaire du même dossier, puis validée
atomiquement uniquement pour un statut final 2xx. Une destination existante est
préservée après erreur réseau, TLS, taille, disque ou statut non-2xx.


### Compresser ou décompresser un flux autonome

```lua
local ok, err = babet.compression.compress(
    "base.dump", "base.dump.zst", "zstd",
    { overwrite = true }
)
assert(ok, err)

ok, err = babet.compression.decompress(
    "base.dump.zst", "base.dump",
    { overwrite = true, max_output_size = 4 * 1024 * 1024 * 1024 }
)
assert(ok, err)
```

Le décompresseur détecte gzip, xz, bzip2 ou zstd à partir des octets du flux.
Les sources et destinations doivent être des fichiers réguliers accessibles
sans composant parent symlinké ; la sortie est préparée dans le dossier
destination puis publiée atomiquement. Le plafond de décompression par défaut
est de 1 Gio.

### Créer, inspecter et extraire ZIP ou TAR en sécurité

```lua
local created, err = babet.archive.create("projet", "projet.zip", {
    compression_level = 9,
    overwrite = true,
})
assert(created, err)

local tar_created
tar_created, err = babet.archive.create("projet", "projet.tar")
assert(tar_created, err)
assert(tar_created.format == "tar")

local selection
selection, err = babet.archive.create({
    "bin/babet",
    "README.fr.md",
    "docs",
}, "publication.tar.zst", {
    include = { "babet", "README.fr.md", "docs/**" },
    exclude = { "docs/brouillons/**", "**/*.tmp" },
})
assert(selection, err)

local info, err = babet.archive.list("upload.zip", {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
assert(info, err)

local tar_info
tar_info, err = babet.archive.list("source.tar.xz")
assert(tar_info, err)
assert(tar_info.format == "tar")
assert(tar_info.compression == "xz")

local result
result, err = babet.archive.extract("source.tar", "restore", {
    overwrite = false,
})
assert(result, err)

local one
one, err = babet.archive.extractFile(
    "source.tar", "docs/readme.txt", "readme.txt")
assert(one, err)
```

La création, le listing et l’extraction ZIP continuent d’utiliser miniz. Les
opérations TAR brutes, gzip, xz, bzip2 ou zstd utilisent les backends
libarchive, zlib, XZ Utils/liblzma, libbz2 et libzstd liés statiquement. Les
lecteurs détectent le format et la compression à partir du contenu ;
`archive.create()` déduit TAR de `.tar`, TAR gzip de `.tar.gz` ou `.tgz`, TAR xz
de `.tar.xz` ou `.txz`, TAR bzip2 de `.tar.bz2`, `.tbz2` ou `.tbz`, et TAR zstd
de `.tar.zst`, `.tar.zstd` ou `.tzst`. Il accepte `format = "tar"`,
`format = "tar.gz"`, `format = "tar.xz"`, `format = "tar.bz2"` ou
`format = "tar.zst"`. Le premier argument peut aussi être une liste dense de
fichiers et répertoires sans racine commune : chaque source est rangée sous son
nom final, les collisions sont refusées et l’ordre de la liste n’affecte pas la
sortie déterministe. La création accepte aussi des tableaux bornés de globs sûrs
`include` et `exclude`, sensibles à la casse et appliqués aux chemins finaux de
l’archive ; les exclusions gagnent et les dossiers exclus sont élagués. La
création refuse les symlinks sélectionnés, objets non pris en charge, noms
d’entrée dangereux et toute sortie située dans un arbre source.
L’extraction
refuse les chemins absolus, composants `..`, liens et types spéciaux de
l’archive, fichiers TAR sparse et parents symlinkés. Les fichiers extraits sont
tous préparés avant publication, puis publiés atomiquement un par un.

## Validation avant une release

Une seule commande exécute les tests ASan/UBSan, restaure et valide le build
normal, puis lance les smoke tests réseau :

```sh
./run_tests.sh --release
```

Les contrôles TLS bloquants de Babet utilisent un serveur HTTPS local généré
à la volée. Les sondes HTTPS publiques sont informatives par défaut, afin
qu’une panne tierce, un proxy, un filtrage DNS ou une interception TLS
n’invalide pas la release. Pour les rendre bloquantes :

```sh
BABET_SMOKE_STRICT_EXTERNAL=1 ./run_tests.sh --release
```

L’étape réseau nécessite les commandes `python3` et `openssl`. Les contrôles
TLS bloquants restent locaux ; le contrôle TCP borné utilise une adresse
réservée TEST-NET.

Valgrind est facultatif ; ASan et UBSan sont les contrôles mémoire et
comportement indéfini principaux du projet.

## Documentation

- [Manuel français](docs/fr/README.md)
- [English manual](docs/en/README.md)
- [Manuel PDF français](docs/manual-fr.pdf)
- [English PDF manual](docs/manual-en.pdf)

Pour reconstruire les PDF :

```sh
cd docs
./build_doc.sh fr
./build_doc.sh en
```

Pandoc et un moteur LaTeX, par exemple XeLaTeX, sont nécessaires.

## Releases

La procédure du mainteneur est décrite dans [`RELEASING.md`](RELEASING.md).
Les binaires précompilés sont disponibles sur la
[page des releases GitHub](https://github.com/Chipsterjulien/babet/releases).

## Méthode de développement

Babet est développé par un auteur humain avec une assistance importante de
plusieurs IA pour l’exploration, la génération initiale et les audits croisés.
Chaque suggestion est vérifiée face au code source et aux tests avant d’être
appliquée : les outils d’IA peuvent inventer des API ou signaler des bugs qui
n’existent pas.

Les décisions d’architecture, le harnais de tests et la validation de chaque
release restent sous la responsabilité de l’auteur.

## Licence

Voir [LICENSE](LICENSE).
