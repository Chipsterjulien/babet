<p align="center">
  <img src="docs/assets/babet-closed.png" alt="Babet — pomme de pin" width="200">
</p>

# Babet

> *Babet*, n.m. — mot régional du sud-est de la France
> (Lyonnais, Forez, Dauphiné, Savoie et Suisse romande voisine)
> désignant une pomme de pin. Petite, légère, pleine de graines et
> capable d’allumer un feu — comme ce binaire.

Babet est un binaire Lua 5.5 autonome pour le scripting et l’automatisation
sous Linux, écrit en C++23. OpenSSL, SQLite, miniz, nlohmann/json,
cpp-httplib et tomlplusplus sont liés statiquement : un seul binaire, sans
dépendance système autre que glibc.

Version stable et auditée actuelle : **2.5.0**. Voir le
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
   archives ZIP sécurisées `babet.archive` et le téléchargement direct
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
C++23, CMake, `wget` et `unzip`.

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

### Créer, inspecter puis extraire une archive ZIP en sécurité

```lua
local created, err = babet.archive.create("projet", "projet.zip", {
    compression_level = 9,
    overwrite = true,
})
assert(created, err)

local info, err = babet.archive.list("upload.zip", {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
assert(info, err)

local result
result, err = babet.archive.extract("upload.zip", "restore", {
    overwrite = false,
})
assert(result, err)
```

La création refuse les symlinks source, objets non pris en charge, noms
d’entrée dangereux et toute sortie située dans l’arbre source. L’extraction
refuse les chemins absolus, composants `..`, symlinks ZIP et parents symlinkés.
L’archive est publiée atomiquement en bloc ; chaque fichier extrait est
contrôlé puis publié atomiquement.

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
