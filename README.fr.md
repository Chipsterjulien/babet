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

Version actuelle : **2.24.2**. Voir le
[journal des modifications français](CHANGELOG.fr.md) ou le
[changelog anglais](CHANGELOG.md).

La [vue d'ensemble de l'architecture](ARCHITECTURE.fr.md) résume les rôles de `--create-exe`, des plugins natifs, de `libbabet` et de la GUI système optionnelle.

Babet 2.24.2 aligne la version compilée et la documentation de publication
après l'incohérence de la publication 2.24.1. Elle conserve les correctifs
de l'audit décrits ci-dessous.

Babet 2.24.1 regroupe les corrections de l'audit : préservation des fichiers,
réseau et processus, durée de vie des ressources Lua, validation de l'image
exécutable et installation atomique. Voir les
[notes de compatibilité](CHANGELOG.fr.md#2241---2026-10-05), notamment les
quatre valeurs renvoyées par `db:query` et la reconstruction des applications
générées avec le nouveau runtime.

Babet 2.24.0 ajoute le backend GTK 4 optionnel [`babet.gui`](GUI_DESIGN.md),
chargé paresseusement depuis le système cible au lieu d'être lié dans Babet.
Cette version formalise aussi les artefacts de release du SDK développeur par
architecture et conserve le durcissement post-audit GUI/embedding ainsi que le
contrat de build OpenSSL/GC de sections validé par le harnais de release. Babet
sans GUI et les applications `--create-exe` sans GUI conservent leur autonomie ;
une application GUI reste mono-fichier mais exige explicitement GTK 4 sur la
cible.

Babet 2.23.0 a introduit le SDK développeur statique `libbabet`, l'API étroite
Lua vers hôte, la première ABI expérimentale de plugins natifs Linux, le support
terminal `ncursesw` statique et l'expérience de prototype FLTK séparé désormais
retirée. Les plugins natifs restent des bibliothèques partagées explicitement
chargées et totalement de confiance, réservées au CLI original ; les
applications générées, workers et contextes d'embedding refusent leur chargement.

Babet 2.22.2 ajoute un client WebSocket RFC 6455 natif via
`babet.websocket`. Il prend en charge `ws://` et `wss://` vérifié, la
validation stricte de l'Upgrade, le masquage client cryptographiquement
aléatoire, les messages texte/binaires fragmentés, Ping/Pong automatique, des
plafonds de frame/message et une fermeture complète. Le transport reste
générique et peut servir directement à un binding WebDriver BiDi.

Babet 2.21.1 renforce `babet.find()` sur les arborescences vivantes. Le
parcours utilise désormais une pile explicite d'itérateurs, avance chaque parent
avant d'ouvrir un enfant et ne traite localement que les courses de disparition
`ENOENT`. Un enfant disparu ne fait plus échouer toute la recherche et ne masque
plus les frères encore présents ; toute autre erreur d'inspection ou de parcours
reste fatale.

Babet 2.21.0 ajoute `xdev = true` à `babet.find()`. Le parcours mémorise
le périphérique de la racine, conserve les points de montage étrangers dans
les résultats possibles et élague leurs descendants, sans modifier le
comportement historique lorsque l'option est absente ou fausse. Le contrat est
identique dans les workers.

Babet 2.20.0 a ajouté les sockets de flux Unix nommées avec validation
stricte, mode final exact, deadline globale de connexion, nettoyage du
listener vérifié par inode, support des workers et les mêmes méthodes
binary-safe que TCP.

La version ajoute aussi `db:backup(path, opts?)`, une sauvegarde SQLite
synchrone fondée sur `sqlite3_backup`. Elle prend en charge les sources WAL,
les écritures concurrentes, les deadlines monotones globales, les tentatives
réellement non bloquantes et la publication atomique d'une destination complète.
Une erreur conserve la destination existante et nettoie les fichiers
temporaires. Babet reste limité à Linux.

Babet s’utilise de trois façons :

1. **Interpréteur Lua** : `babet script.lua` ou `babet dossier/`
   (recherche de `main.lua`).
2. **Créateur d’exécutable** : `babet --create-exe ./monprojet application`
   produit un exécutable autonome contenant le script et ses modules `require`.
   Une application générée est finale : elle refuse `--create-exe` / `-c` ;
   il faut utiliser le binaire Babet original pour empaqueter une autre
   application.
3. **Bibliothèque de bindings** : les scripts disposent notamment de
   `babet.base64`, `babet.json`, `babet.http`, `babet.sqlite`, `babet.socket`, `babet.websocket`,
   `babet.inotify`, `babet.curses`, `babet.gui`, `babet.workers`, `babet.user`, `babet.exec`,
   `babet.writeFileAtomic`, le streaming `babet.spawn`, les pipelines `babet.pipeline` / `babet.spawnPipeline`, les
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

Chaque invocation top-level de `run_tests.sh` enregistre aussi la sortie complète,
sans couleurs, dans `babet-tests.txt` en remplaçant le journal précédent.

Le premier build télécharge et compile les dépendances. Il faut un compilateur
C++23, CMake 3.22 ou plus récent, `wget`, `unzip` et `xz`.

### Confiner une recherche récursive à un système de fichiers

```lua
local entries = assert(babet.find("/srv", {
    xdev = true,
    type = "f",
    path_iglob = "**/*.log",
}))
```

Un point de montage appartenant à un autre système de fichiers peut encore
apparaître dans le résultat, mais Babet ne descend pas dans son contenu. Le
contrat correspond à l'usage utile de `find -xdev`, sans lancer de commande
shell externe. La décision repose sur `st_dev` : un sous-volume Btrfs peut être
élagué, contrairement à un bind mount du même système de fichiers.

### Ouvrir SQLite avec une politique de connexion explicite

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
    foreign_keys = true,
}))

assert(db:exec("INSERT INTO jobs(name) VALUES(?)", { "index" }))
print(assert(db:last_insert_rowid()))
print(assert(db:changes()), assert(db:total_changes()))
```

Utilise `{ readonly = true }` pour une base existante qui ne doit être ni
créée ni modifiée. La lecture seule reste compatible avec `busy_timeout` et
`foreign_keys`, mais refuse volontairement `wal = true`. Cela empêche seulement
de demander un changement de mode ; une base déjà en WAL reste lisible si
SQLite peut utiliser ses fichiers compagnons.

### Isoler une étape SQLite récupérable avec un savepoint

```lua
local ok, err = db:transaction(function(tx)
    assert(tx:exec("INSERT INTO jobs(name) VALUES(?)", { "obligatoire" }))

    local optional_ok = tx:savepoint(function(inner)
        assert(inner:exec(
            "INSERT INTO jobs(name) VALUES(?)", { "facultatif" }))
    end)

    if not optional_ok then
        -- Seule l'étape facultative a été annulée. La transaction continue.
    end
end, "immediate")

assert(ok, err)
```

Le `RELEASE` réussi d'un savepoint interne ne valide jamais la transaction
externe. Une erreur Lua du callback revient au savepoint généré, le retire et
renvoie `(nil, err)`.

### Sauvegarder SQLite sans copie de fichier incohérente

```lua
assert(db:backup("state-backup.db", {
    timeout = 10,
    pages_per_step = 64,
    sleep = 0.005,
}))
```

`db:backup()` utilise `sqlite3_backup`, accepte les sources WAL et publie la
destination atomiquement seulement après une copie complète. Les timeouts sont
basés sur une deadline monotone globale ; une erreur ne laisse pas de base
partielle. Utilise `overwrite = true` uniquement pour remplacer explicitement
une ancienne sauvegarde fermée.

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


### Encoder ou décoder une donnée binaire en Base64

```lua
local source = "\0\1\2capture\255"
local encoded, err = babet.base64.encode(source, {
    url_safe = true,
    padding = false,
})
assert(encoded, err)

local decoded
decoded, err = babet.base64.decode(encoded, {
    url_safe = true,
    allow_unpadded = true,
    max_output = 32 * 1024 * 1024,
})
assert(decoded, err)
assert(decoded == source)
```

Le module est binaire, n'exige pas d'UTF-8 et refuse par défaut les alphabets
mélangés, les espaces, le padding mal placé et les bits finaux non canoniques.
Il est également disponible dans les workers.

### Publier atomiquement un fichier de configuration

```lua
local ok, err = babet.writeFileAtomic("runtime/state.json", json_data, {
    overwrite = true,
    permissions = tonumber("600", 8),
})
assert(ok, err)
```

Le contenu est écrit dans un temporaire privé du même dossier puis publié
atomiquement. L’écrasement est refusé par défaut, les parents symboliques et la
destination finale symbolique sont refusés, et la durabilité est activée par
défaut.

### Attendre ou annuler proprement un worker

```lua
local job = assert(babet.workers.spawn([[
    while not worker.cancelled() do
        local ok, command = worker.recv(0.1)
        if ok then process(command) end
    end
    return "cancelled"
]]))

local ok, result = job:join(0.05)
if ok == nil then
    assert(result == "timeout")
    assert(job:cancel())
    ok, result = job:join(2)
end
assert(ok, result)
```

`status()` observe `running`, `done` ou `error` sans consommer le résultat.
Un timeout de `join()` ne modifie pas le job. `cancel()` reste volontairement
coopératif : il réveille `worker.recv()`, pose le drapeau lu par
`worker.cancelled()`, réveille également l’attente de channel en cours sans
fermer le channel partagé et laisse l’outbox disponible pour un dernier message.


### Relier directement plusieurs workers par des channels

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
local results = assert(babet.workers.channel({ capacity = 16 }))

local producer = assert(babet.workers.spawn([[
    for i = 1, 10 do
        assert(worker.channels.tasks:send({ id = i, value = i * 10 }, 2))
    end
    return true
]], nil, {
    channels = { tasks = tasks },
}))

local consumer = assert(babet.workers.spawn([[
    for _ = 1, 10 do
        local ok, task = worker.channels.tasks:recv(2)
        assert(ok, task)
        assert(worker.channels.results:send({
            id = task.id,
            result = task.value * 2,
        }, 2))
    end
    return true
]], nil, {
    channels = { tasks = tasks, results = results },
}))

for _ = 1, 10 do
    local ok, result = results:recv(2)
    assert(ok, result)
    print(result.id, result.result)
end

assert(producer:join(2))
assert(consumer:join(2))
```

Les messages producteur vers consommateur ne repassent pas par le parent. Un
channel est FIFO, multi-producteurs, multi-consommateurs et fermé avec drainage
des messages déjà présents.

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

### Créer, inspecter, vérifier et extraire ZIP ou TAR en sécurité

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
    max_path_length = 8192,
    max_total_name_bytes = 2 * 1024 * 1024,
})
assert(info, err)
assert(info.duplicates == 0 and info.conflicts == 0)

local manifest
manifest, err = babet.archive.read("upload.zip", "manifest.json", {
    max_size = 1024 * 1024,
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
assert(manifest, err)

local verified
verified, err = babet.archive.test("upload.zip", {
    max_entries = 2000,
    max_total_size = 512 * 1024 * 1024,
})
assert(verified, err)
assert(verified.files + verified.directories == verified.entries)

local tar_info
tar_info, err = babet.archive.list("source.tar.xz")
assert(tar_info, err)
assert(tar_info.format == "tar")
assert(tar_info.compression == "xz")

local plan
plan, err = babet.archive.extract("source.tar", "restore", {
    dry_run = true,
    include = { "src/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
    overwrite = true,
})
assert(plan, err)
assert(plan.would_create + plan.would_overwrite + plan.would_skip
    == plan.entries)
assert(not babet.fileExists("restore"))

local result
result, err = babet.archive.extract("source.tar", "restore", {
    include = { "src/**", "README.md" },
    exclude = { "src/generated/**", "**/*.tmp" },
    overwrite = false,
})
assert(result, err)

local one
one, err = babet.archive.extractFile(
    "source.tar", "docs/readme.txt", "readme.txt")
assert(one, err)
```

La création, le listing, la vérification et l’extraction ZIP continuent d’utiliser miniz. Les
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
`archive.test()` lit entièrement les données vérifiables et refuse aussi les
archives techniquement corrompues, ambiguës ou dangereuses, sans créer de
fichier. `archive.extract()` réutilise désormais exactement les mêmes globs
sûrs bornés `include` et `exclude` que la création, sur les chemins internes
normalisés ; les exclusions gagnent, les sous-arbres exclus sont élagués et
seuls les parents nécessaires sont créés. Les entrées hors sélection ne
participent pas aux collisions de sortie, mais les limites globales restent
appliquées à l’archive entière. L’extraction refuse toujours les chemins
sélectionnés absolus, composants `..`, liens, types spéciaux, fichiers TAR
sparse et parents symlinkés. Les fichiers retenus sont tous préparés avant
publication, puis publiés atomiquement un par un. Avec `dry_run = true`, le
même plan, les mêmes filtres, limites et contrôles de destination sont exécutés
sans création, écriture, chmod, renommage ni suppression ; le résultat indique
`would_create`, `would_overwrite`, `would_skip` et l’éventuelle création de la
racine. Cette prévisualisation décrit un instantané et ne remplace pas les
contrôles refaits par l’extraction réelle. Utiliser `archive.test()` en amont
lorsqu’il faut vérifier aussi l’intégrité des payloads ZIP ignorés.
`archive.read()` charge un fichier régulier dans une chaîne Lua binaire avec
une limite mémoire de 8 Mio par défaut et de 256 Mio au maximum. La sélection
se fait par nom brut exact ou par l’index 1-based fourni par `archive.list()` ;
un nom dupliqué est refusé tant qu’un index ne désambiguïse pas explicitement
l’occurrence. Aucun nom n’est nettoyé et aucune écriture n’a lieu : un chemin
dangereux peut être lu comme donnée, tout en restant signalé par
`list().entries[i].safe_path = false` et interdit à l’extraction.

## Embedding C / libbabet expérimental

Le Lot 6 introduit la première frontière d'embedding réellement exercée. Un
hôte C ou C++ peut viser le petit header C
[`include/babet/babet.h`](include/babet/babet.h) et le runtime statique
`libbabet.a` produit dans le build CMake. Un build normal crée aussi un SDK
statique déplaçable sous `build/sdk/` : les headers C publics
(`babet.h` ainsi que l’ABI développeur `plugin.h` du Lot 11), un unique
`libbabet.a` aplati qui incorpore les dépendances statiques épinglées de Babet,
ainsi que la documentation et les exemples développeur. Un hôte C externe peut donc compiler contre ce
SDK déplacé sans connaître l'arborescence des dépendances ; le lien final utilise
un driver C++ avec les bibliothèques système Linux normales (`-ldl -pthread
-lm`, plus `-latomic` en 32 bits). `release.sh` empaquette ce SDK comme artefact
de release versionné et propre à l'architecture, avec son propre checksum SHA256. L'API reste volontairement réduite et
expérimentale :
contexte opaque, cycle create/search-root/run/error/destroy, helpers de
version/statut, un seul contexte actif par processus et utilisation sur le
même thread. Un répertoire explicite de modules Lua peut être configuré une
seule fois avant la première exécution ; il alimente à la fois `package.path`
du contexte principal et les workers. Une petite API `babet_value` permet aussi
d'échanger des globals scalaires (`nil`, booléen, entier signé 64 bits, double
et chaîne binaire) sans exposer `lua_State`, et d'appeler une fonction globale
Lua avec des arguments scalaires et un résultat scalaire. Le Lot 10 ajoute le
sens inverse : l'hôte peut enregistrer des fonctions scalaires sous
`babet.host.<nom>` à travers la même frontière C pure. Babet copie les chaînes
et diagnostics des callbacks, les workers n'héritent pas des enregistrements et
une réentrée `babet_context_*` depuis un callback hôte actif est refusée avec
`BABET_STATUS_REENTRANT_CALL`. Tables structurées, désenregistrement de fonction
hôte, résolution de méthodes pointées et multi-retours restent différés. Aucun
détail Lua/C++ ne fait partie de l'ABI publique.

Le binaire officiel `babet` continue d'embarquer le runtime dans son propre
fichier et ne dépend **pas** d'un `libbabet.so` au runtime. Le packaging en
bibliothèque partagée et plusieurs contextes concurrents restent différés ; le
Lot 6 valide volontairement d’abord le chemin du SDK statique. Les API Babet process-wide (`chdir`, environnement,
signaux, enfants, terminal) restent de vrais effets sur le processus hôte et ne
sont pas sandboxées. Le guide pratique développeur est [`EMBEDDING.fr.md`](EMBEDDING.fr.md), avec de petits exemples C exécutables sous [`examples/embedding/`](examples/embedding/). Le contrat architectural détaillé et ses raisons restent dans [`EMBEDDING_DESIGN.md`](EMBEDDING_DESIGN.md), et le contrat Lua -> fonctions hôte est isolé dans [`HOST_FUNCTIONS_DESIGN.md`](HOST_FUNCTIONS_DESIGN.md).

Le compagnon FLTK séparé livré comme expérience en 2.23.0 a rempli son rôle :
il a exercé `libbabet` et l'API de callbacks Lua vers hôte, mais il n'est plus
la direction GUI active. Le développement post-2.23 définit plutôt une API Lua
optionnelle `babet.gui` dont le premier backend Linux sera GTK 4 chargé
paresseusement depuis le système. GTK ne devient pas une dépendance de lien du
Babet normal ; l'usage GUI est l'exception explicite où une application générée
mono-fichier peut exiger un runtime système cible. Voir
[`GUI_DESIGN.md`](GUI_DESIGN.md).

Le Lot 11 ajoute séparément un chemin de **plugins natifs expérimentaux** pour
des extensions Linux `.so` totalement de confiance qui ne doivent pas entrer
dans le cœur de Babet (par exemple des wrappers de SDK constructeur). Le
chargement reste explicite via `babet.plugin.load(path)` et renvoie une table
locale de callbacks scalaires ; les plugins réutilisent la frontière C
`babet_host_call_*` du Lot 10 et ne voient jamais `lua_State *`. Un plugin
chargé avec succès reste chargé jusqu'à la fin du processus. Il n'y a ni
`libbabet.so`, ni gestionnaire de paquets, ni résolution de dépendances, ni
découverte automatique ; les applications `--create-exe`, les workers et les
hôtes d'embedding externes refusent le chargement natif dans cette première
version. Voir [`NATIVE_PLUGINS.fr.md`](NATIVE_PLUGINS.fr.md) et
[`NATIVE_PLUGIN_DESIGN.md`](NATIVE_PLUGIN_DESIGN.md).

## Validation avant une release

Une seule commande sélectionne les sanitizers de release adaptés à
l'architecture native, restaure et valide le build normal, puis lance les smoke
tests réseau :

```sh
./run_tests.sh --release
```

Comme les modes normal, `--sanitizers` et `--ubsan`, la validation `--release` enregistre
la sortie complète sans couleurs dans `babet-tests.txt`, toujours sous ce même
nom et en remplaçant le journal précédent. C’est ce fichier qu’il faut
transmettre pour faire contrôler un résultat de tests.

Les contrôles bloquants du cadrage HTTP et de TLS utilisent des serveurs
HTTP/HTTPS locaux générés à la volée. Les sondes HTTPS publiques sont
informatives par défaut, afin qu’une panne tierce, un proxy, un filtrage DNS ou
une interception TLS n’invalide pas la release. Pour les rendre bloquantes :

```sh
BABET_SMOKE_STRICT_EXTERNAL=1 ./run_tests.sh --release
```

L’étape réseau nécessite les commandes `python3` et `openssl`. Les contrôles
HTTP et TLS bloquants restent locaux ; le contrôle TCP borné utilise une
adresse réservée TEST-NET.

Sur x86_64 et AArch64, la première étape utilise ASan + UBSan. Sur
`linux-armhf`, elle utilise explicitement UBSan seul : sur le builder ARMv6 de
référence, le runtime ASan de GCC 12 échoue avant `main()` même sur un programme
C minimal, alors qu'un test `libatomic` isolé et UBSan passent. Le bilan ARMHF
ne revendique donc jamais une validation ASan. Pour un diagnostic manuel :

```sh
./run_tests.sh --sanitizers
./run_tests.sh --ubsan
./run_tests.sh
```

Valgrind est facultatif ; ASan + UBSan restent la paire principale sur
x86_64/AArch64, tandis que la gate officielle `linux-armhf` utilise UBSan seul
et l’indique explicitement dans son bilan.

## Documentation

- Invariants du projet et garde-fous d’architecture : [`INVARIANTS.md`](INVARIANTS.md)
- Design de la GUI dynamique optionnelle : [`GUI_DESIGN.md`](GUI_DESIGN.md)
- Guide utilisateur GUI Lua : [`docs/fr/modules/gui.md`](docs/fr/modules/gui.md)
- Guide développeur des plugins natifs (Lot 11) : [`NATIVE_PLUGINS.fr.md`](NATIVE_PLUGINS.fr.md)
- Contrat ABI/loader des plugins natifs : [`NATIVE_PLUGIN_DESIGN.md`](NATIVE_PLUGIN_DESIGN.md)
- Feuille de route de développement actuelle : [`todo`](todo)

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
