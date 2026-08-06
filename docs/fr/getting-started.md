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

En interne, Babet append un ZIP à son propre binaire et lit
`main.lua` (plus tous les modules `require`) depuis ce ZIP au
runtime. Le `myapp` résultant est totalement autonome — pas
besoin d'avoir Babet installé sur la machine cible, juste
glibc.

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
babet --version    # babet 2.18.0
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
