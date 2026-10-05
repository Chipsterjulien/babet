> [English](../en/getting-started.md) | **Français**

# Pour démarrer

## Téléchargement

Des binaires précompilés pour x86_64, aarch64 (RPi4) et armv6l
(RPi0) sont disponibles sur la
[page des releases](https://github.com/Chipsterjulien/babet/releases).

## Compilation depuis les sources

Babet embarque toutes ses dépendances (Lua, OpenSSL, SQLite, miniz,
libarchive, zlib, XZ Utils/liblzma, bzip2/libbz2, Zstandard/libzstd,
RE2, Abseil, nlohmann/json, cpp-httplib, tomlplusplus), donc les seuls
prérequis sur ton système sont :

- un compilateur C++23 (GCC ou Clang récent)
- CMake (≥ 3.22)
- `wget`, `unzip` et `xz`

```sh
git clone https://github.com/Chipsterjulien/babet.git
cd babet
./build_local.sh        # télécharge les deps et compile
                        # (~5 min au premier lancement, plus vite après)
./run_tests.sh          # harness offline — doit terminer avec 0 FAIL
```

Le script de build télécharge chaque dépendance depuis une source amont
épinglée, vérifie son SHA256, puis la compile statiquement. Plusieurs
bibliothèques disposent d’un miroir ou d’une URL de secours explicite. Lorsqu’il
n’existe aucun miroir, le script indique le nom exact de l’archive à déposer
manuellement dans `downloads/` ; le même contrôle SHA256 reste appliqué avant
l’extraction.

Le binaire produit est dans `test/babet`.

## Trois manières de lancer un script Lua

Babet supporte trois modes de lancement :

### 1. Mode dossier

Pointe le binaire vers un dossier contenant `main.lua` :

```sh
echo 'print("hello from Babet")' > main.lua
./test/babet .
```

`require("X")` dans `main.lua` cherche `X.lua` dans le même dossier.

### 2. Mode embarqué (binaire autonome)

Empaquète un script et ses modules dans un binaire autonome :

```sh
./test/babet --create-exe . myapp
./myapp        # lance main.lua depuis le ZIP embarqué
```

Les dossiers de métadonnées de contrôle de version `.git`, `.svn` et
`.hg` sont exclus automatiquement, à n’importe quelle profondeur.

En interne, Babet ajoute un ZIP à son propre binaire et y lit `main.lua` et
les modules Lua empaquetés. La machine cible n'a pas besoin d'une installation
séparée de Babet. Les dépendances de la plateforme restent nécessaires ; une
application utilisant la [GUI](modules/gui.md) requiert aussi GTK4 à l'exécution.
Une application générée est un artefact final : un lancement avec
`--create-exe` ou `-c` est refusé avant l'exécution de son `main.lua`. Il faut
utiliser le binaire Babet original pour créer un autre exécutable.

**Origine des modules.** Pour un module que `require` n'a pas déjà chargé,
`package.preload` est consulté avant le ZIP. Le chargeur embarqué cherche
`nom.lua`, puis `nom/init.lua`. Si les deux entrées sont absentes, les chargeurs
Lua habituels restent actifs : `package.path` peut fournir un module Lua sur
disque et `package.cpath` un module natif compatible avec l'ABI Lua. Une erreur
de lecture ou de compilation d'un module trouvé dans le ZIP arrête le
chargement ; elle ne déclenche pas ce repli sur disque. Ces règles s'appliquent
aussi aux workers des applications générées.

`package.loadlib` reste disponible pour charger explicitement une bibliothèque
native sur disque. Cette API Lua est distincte de l'API des plugins Babet,
qui reste refusée dans les applications générées. L'empaquetage ne garantit
donc pas que tout chargement provienne exclusivement du ZIP et ne crée pas de
[sandbox](security.md). Pour distribuer une application autonome, inclus ses
modules Lua dans le projet empaqueté et vérifie ses besoins en ressources ou
bibliothèques externes.

Le `main.lua` et les modules embarqués acceptent le BOM UTF-8 initial et la
première ligne de commentaire `#`/shebang comme les fichiers Lua sur disque,
y compris dans les workers. Les numéros de ligne sont conservés ; le bytecode
Lua reste chargeable avec ces préfixes. Les modules sont lus dans l’inode de
l’exécutable en cours : remplacer ou supprimer son chemin ne mélange pas les
modules de l’application lancée avec ceux d’une nouvelle version.

Le démarrage nécessite un `/proc/self/exe` accessible et lisible. Une erreur
d'ouverture ou de lecture de cette image arrête Babet avec le code 1 et un
diagnostic ; elle ne transforme pas une application générée en CLI ou builder.

Le builder inscrit désormais dans sa copie du runtime un descripteur indiquant
qu'il s'agit d'une application et précisant la position et la taille du ZIP.
Cette identité est lue dans l'image chargée : des octets ressemblant à du ZIP
dans un runtime nu ne changent pas son mode. Une application dont le ZIP est
tronqué, suivi de données supplémentaires, illisible ou dépourvu de `main.lua`
est refusée avant toute interprétation des arguments.

Pour bénéficier de cette protection, reconstruire les applications avec le
nouveau binaire Babet. Les anciens exécutables gardent leur runtime embarqué.
Utiliser `--create-exe` : concaténer manuellement un ZIP au nouveau runtime ne
le transforme plus en application. Si `strip` est souhaité, l'appliquer au
runtime **avant** de générer l'application, puis préserver le fichier généré.

Ne pas compresser le runtime avec UPX : cela masque le descripteur dans le
fichier et empêche `--create-exe` de fonctionner. `build_and_deploy.sh` conserve
désormais le binaire du build, même si UPX est installé, et vérifie la création
puis l'exécution d'une petite application avant de remplacer le Babet installé.
Cette vérification utilise un dossier temporaire dans `build/` et fonctionne
donc même si `$TMPDIR` est monté `noexec`. L'installation prépare un fichier
en mode `0755` dans le dossier cible, puis remplace le chemin final par renommage atomique :
un Babet déjà lancé continue avec son ancien binaire et un échec de copie
laisse l'installation précédente intacte.

Chaque fichier Lua embarqué (`*.lua`, dont `main.lua` et `*/init.lua`) est
limité à **16 Mio décompressés**, borne comprise. Le packaging refuse les
scripts plus volumineux avant publication, indique leur nom dans l’archive
et conserve une éventuelle ancienne sortie. Le ZIP terminé est également
vérifié pour couvrir un fichier ayant grossi pendant l’empaquetage. La politique
de taille des autres ressources reste inchangée. Le loader conserve ce contrôle
pour les archives altérées qui se présentent avec un descripteur valide.

### 3. Embarqué via PATH (dossier + auto-détection)

Si Babet est sur `$PATH` et qu'on fait `chmod +x main.lua`
après avoir ajouté une ligne shebang :

```lua
#!/usr/bin/env babet
print("hello")
```

```sh
chmod +x main.lua
./main.lua
```

Babet utilise le dossier du script comme dossier de travail,
donc `require("helpers")` trouvera `helpers.lua` à côté de
`main.lua`.

## Invocation en ligne de commande

En plus des trois modes de lancement ci-dessus, Babet accepte
quelques flags standards :

| Flag | Effet |
| --- | --- |
| `-h`, `--help` | Affiche l'aide et sort avec code `0`. |
| `-V`, `--version` | Affiche `babet <version>` et sort avec code `0`. |
| `-c <dir> <out>`, `--create-exe <dir> <out>` | Crée un exécutable autonome nommé `<out>` en embarquant `<dir>` (qui doit contenir `main.lua`). |

Tout autre argument commençant par `-` est traité comme une
**option inconnue** : Babet affiche `Unknown option: ...` + un
indice pour utiliser `--help`, et sort en code `1` plutôt que
d'essayer de l'interpréter comme un nom de dossier. Les dossiers
dont le nom commence légitimement par `-` peuvent toujours être
passés via `./-dirname` (convention POSIX).

```sh
babet --version    # babet 2.22.0
babet --help       # usage complet
babet --bogus      # Unknown option: --bogus
                      # Try 'babet --help' for more information.
```

La même version est aussi exposée aux scripts via
`babet.VERSION` (plus `babet.VERSION_MAJOR` / `VERSION_MINOR`
/ `VERSION_PATCH` en integer) — voir [`sys`](modules/sys.md).

## Premier script

Une fois le binaire compilé, essaie ceci :

```lua
-- main.lua
print("Babet dit bonjour")
print("PID :", babet.pid())
print("Hôte :", babet.hostname())

local r, err = babet.http.get("https://example.com/")
if r then
    print("Status :", r.status)
else
    print("Échec HTTP :", err)
end
```

Lance-le avec `./test/babet .` (ou un autre mode au choix).

## Pour aller plus loin

- Chaque module a sa propre page sous [`modules/`](modules/).
- Le module [`user`](modules/user.md) est un petit exemple complet
  du pattern de documentation utilisé partout — lis-le comme la
  référence canonique.
- Pour les utilitaires de dates et durées (timestamps ISO 8601,
  durées lisibles comme `"5m"` ou `"2h30m"`), voir
  [`time`](modules/time.md) — la sous-table `babet.time.*`
  couvre le parsing et le formatage.
- Vois [`security.md`](security.md) avant d'exposer des scripts
  Babet à quoi que ce soit qui pourrait recevoir de l'input non
  fiable.
