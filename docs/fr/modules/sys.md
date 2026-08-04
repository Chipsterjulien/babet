> [English](../../en/modules/sys.md) | **Français**

# SYS - processus, machine, environnement, exécutables, version et mémoire Lua

Les fonctions de ce chapitre sont exposées directement dans la table globale
`babet`. Il n'existe pas de sous-table `babet.sys` : ce namespace plat est
historique et fait partie de l'API stable.

Le chapitre SYS couvre :

- l'identité du processus Babet ;
- le nom de la machine et les informations du noyau ;
- la lecture et la modification de variables d'environnement ;
- la recherche d'un programme exécutable ;
- les constantes de version du runtime ;
- la mémoire utilisée par l'état Lua courant.

Le répertoire de travail courant est lui aussi un état global du processus,
mais ses fonctions `currentDir` et `chdir` sont documentées dans
[FS - Répertoire courant](fs.md#fs-cwd), avec les autres fonctions de chemins.

## Table des matières du module

- [Conventions générales](#sys-conventions)
- [Vue d'ensemble de l'API](#sys-api-summary)
- [Constantes de version](#sys-version)
- [Identifier le processus et la machine](#sys-process-host)
  - [`pid`](#pid)
  - [`hostname`](#hostname)
  - [`uname`](#uname)
- [Rechercher un exécutable](#sys-which)
  - [Recherche dans `PATH`](#which-path)
  - [Chemin direct](#which-direct)
  - [Programme absent ou non exécutable](#which-errors)
- [Variables d'environnement](#sys-environment)
  - [`env`](#env)
  - [`setenv`](#setenv)
  - [Valeur vide et variable absente](#env-empty-unset)
  - [Interaction avec les workers](#env-workers)
- [Mémoire de la VM Lua](#sys-memory)
  - [`getMemoryUsage`](#getmemoryusage)
  - [`getDetailedMemoryUsage`](#getdetailedmemoryusage)
  - [Ce qui est mesuré et ce qui ne l'est pas](#memory-scope)
- [Contrat d'erreur](#sys-errors)
- [Décisions et limites](#sys-design)

<a id="sys-conventions"></a>
## Conventions générales

### Fonctions plates

Toutes les fonctions s'appellent directement depuis `babet` :

```lua
local pid = babet.pid()
local home = babet.env("HOME")
```

Les formes suivantes n'existent pas :

```lua
-- Incorrect : aucune sous-table babet.sys
-- babet.sys.pid()
-- babet.sys.env("HOME")
```

### Chaînes strictes

`env`, `setenv` et `which` exigent de véritables chaînes Lua. Les nombres ne
sont pas convertis automatiquement.

```lua
local ok, err = pcall(function()
    return babet.env(42)
end)

-- ok == false ; err décrit une mauvaise signature
```

Un octet NUL est toujours refusé. Cette règle évite qu'une chaîne Lua soit
silencieusement tronquée lorsqu'elle est transmise à une API C.

### État global du processus

L'environnement et le répertoire courant appartiennent au **processus entier**,
pas à un script ou à un worker particulier.

- `setenv` modifie l'environnement vu par le runtime et les futurs programmes
  lancés avec `babet.exec` ;
- `chdir` modifie la résolution de tous les chemins relatifs ;
- ces deux mutations sont définitivement interdites après le premier
  `babet.workers.spawn()`.

Cette restriction évite des courses de données entre threads.

<a id="sys-api-summary"></a>
## Vue d'ensemble de l'API

| Fonction ou constante | Résultat |
| --- | --- |
| `babet.VERSION` | chaîne `major.minor.patch` du runtime |
| `babet.VERSION_MAJOR` | composante majeure entière |
| `babet.VERSION_MINOR` | composante mineure entière |
| `babet.VERSION_PATCH` | composante patch entière |
| `babet.pid()` | PID du processus, sous forme d'integer |
| `babet.hostname()` | hostname, ou `(nil, err)` |
| `babet.uname()` | table système, ou `(nil, err)` |
| `babet.which(name)` | chemin d'un exécutable, ou `(nil, err)` |
| `babet.env(name)` | valeur de la variable, ou `nil` si elle est absente |
| `babet.setenv(name, value)` | `(true, nil)` ou `(nil, err)` |
| `babet.getMemoryUsage()` | mémoire de l'état Lua courant en octets |
| `babet.getDetailedMemoryUsage()` | deux integers actuellement identiques |

<a id="sys-version"></a>
## Constantes de version

Les quatre constantes décrivent le binaire Babet qui exécute le script.

```lua
print(babet.VERSION)       -- par exemple "2.15.0"
print(babet.VERSION_MAJOR) -- par exemple 2
print(babet.VERSION_MINOR) -- par exemple 15
print(babet.VERSION_PATCH) -- par exemple 0
```

`babet.VERSION` correspond à la sortie de :

```text
babet --version
```

Les composantes entières permettent de comparer des versions sans parser une
chaîne.

```lua
local function version_at_least(major, minor, patch)
    local current = {
        babet.VERSION_MAJOR,
        babet.VERSION_MINOR,
        babet.VERSION_PATCH,
    }
    local wanted = { major, minor, patch }

    for i = 1, 3 do
        if current[i] ~= wanted[i] then
            return current[i] > wanted[i]
        end
    end
    return true
end

assert(version_at_least(2, 9, 0), "Babet >= 2.9.0 requis")
```

La cohérence suivante est garantie par les tests :

```lua
assert(babet.VERSION == string.format(
    "%d.%d.%d",
    babet.VERSION_MAJOR,
    babet.VERSION_MINOR,
    babet.VERSION_PATCH
))
```

<a id="sys-process-host"></a>
## Identifier le processus et la machine

<a id="pid"></a>
### `babet.pid()`

Renvoie le PID du processus Babet sous forme d'integer strictement positif.
L'appel ne peut pas échouer sur un système POSIX supporté.

```lua
local pid = babet.pid()
print("PID Babet :", pid)
```

Les workers sont des threads du même processus. Ils voient donc le même PID que
le thread principal ; `pid()` ne permet pas d'identifier un worker particulier.

```lua
local main_pid = babet.pid()
local worker = assert(babet.workers.spawn([[
    return babet.pid()
]]))

local joined, worker_pid = worker:join()
assert(joined and worker_pid == main_pid)
```

<a id="hostname"></a>
### `babet.hostname()`

Renvoie le nom d'hôte configuré pour la machine.

```lua
local host, err = babet.hostname()
assert(host, err)
print("Machine :", host)
```

Signature :

```lua
local host, err = babet.hostname()
```

Résultats :

- succès : `host` est une chaîne non vide et `err` vaut `nil` ;
- erreur système : `(nil, "hostname: ...")`.

Le hostname n'est pas nécessairement un nom DNS pleinement qualifié. Il peut
être un nom court défini localement.

<a id="uname"></a>
### `babet.uname()`

Renvoie les cinq champs POSIX principaux de `uname(2)` dans une table.

```lua
local info, err = babet.uname()
assert(info, err)

print("Système :", info.sysname)
print("Noeud    :", info.nodename)
print("Noyau    :", info.release)
print("Version  :", info.version)
print("Machine  :", info.machine)
```

Table renvoyée :

```lua
{
    sysname  = "Linux",
    nodename = "station",
    release  = "6.12.0-arch1-1",
    version  = "#1 SMP PREEMPT_DYNAMIC ...",
    machine  = "x86_64",
}
```

| Champ | Signification |
| --- | --- |
| `sysname` | nom du système d'exploitation ou du noyau |
| `nodename` | nom du noeud réseau, souvent proche du hostname |
| `release` | version de publication du noyau |
| `version` | chaîne de build détaillée du noyau |
| `machine` | architecture matérielle exposée par le noyau |

En cas d'échec de `uname(2)`, la fonction renvoie `(nil, "uname: ...")`.
Cette erreur est extrêmement rare, mais elle fait partie du contrat réel.

<a id="sys-which"></a>
## Rechercher un exécutable

Signature :

```lua
local path, err = babet.which(name)
```

`name` doit être une chaîne sans octet NUL.

<a id="which-path"></a>
### Recherche dans `PATH`

Lorsque `name` ne contient aucun `/`, Babet parcourt la variable
`PATH` de gauche à droite et renvoie le premier candidat qui est :

- un fichier régulier ;
- exécutable par le processus courant.

```lua
local shell, err = babet.which("sh")
assert(shell, err)
print(shell) -- généralement /usr/bin/sh ou /bin/sh
```

Le chemin renvoyé est normalisé en chemin absolu lorsque le système le permet.

Pour vérifier uniquement la présence d'un programme :

```lua
if babet.which("ffmpeg") then
    print("ffmpeg est disponible")
end
```

`PATH` est lu au moment de l'appel. Une modification effectuée avec `setenv`
avant les workers est donc prise en compte par les appels suivants.

```lua
local old_path = babet.env("PATH")
assert(babet.setenv("PATH", "/opt/mon-app/bin:/usr/bin"))
local tool = babet.which("mon-outil")
```

Une composante vide de `PATH`, comme dans `:/usr/bin` ou `/bin::/usr/bin`,
représente le répertoire courant conformément à la convention Unix.

<a id="which-direct"></a>
### Chemin direct

Lorsque l'argument contient un `/`, `PATH` n'est pas consulté. Le chemin est
testé directement.

```lua
local sh, err = babet.which("/bin/sh")
assert(sh, err)
```

Un chemin relatif contenant `/` est également accepté :

```lua
local tool, err = babet.which("./bin/mon-outil")
assert(tool, err)
```

Un symlink valide vers un fichier régulier exécutable est accepté, car
l'inspection suit sa cible.

<a id="which-errors"></a>
### Programme absent ou non exécutable

Si aucun exécutable valide n'est trouvé :

```lua
local path, err = babet.which("programme-introuvable")
-- path == nil
-- err  == "which: 'programme-introuvable' not found in PATH"
```

Un fichier présent mais non exécutable est traité comme introuvable :

```lua
local path, err = babet.which("./script-sans-bit-x")
assert(path == nil)
print(err)
```

Sont également refusés :

- les dossiers ;
- les symlinks cassés ;
- les fichiers non réguliers ;
- les fichiers auxquels le processus n'a pas le droit d'exécution.

<a id="sys-environment"></a>
## Variables d'environnement

<a id="env"></a>
### `babet.env(name)`

Lit une variable d'environnement du processus.

```lua
local home = babet.env("HOME")
if home then
    print("HOME :", home)
end
```

Signature :

```lua
local value = babet.env(name)
```

Résultats :

- variable définie : sa valeur sous forme de chaîne ;
- variable absente : `nil` seul, sans message d'erreur.

Cela permet l'idiome :

```lua
local port = babet.env("APP_PORT") or "8080"
```

`name` doit être une chaîne. Les formes suivantes lèvent une erreur Lua :

```lua
-- babet.env()       -- argument manquant
-- babet.env(42)     -- aucune conversion automatique
-- babet.env({})     -- mauvais type
-- babet.env("A\0B") -- NUL embarqué
```

<a id="setenv"></a>
### `babet.setenv(name, value)`

Crée une variable d'environnement ou remplace sa valeur existante.

```lua
local ok, err = babet.setenv("APP_MODE", "production")
assert(ok, err)
assert(babet.env("APP_MODE") == "production")
```

Un second appel écrase la valeur :

```lua
assert(babet.setenv("APP_MODE", "test"))
assert(babet.env("APP_MODE") == "test")
```

`name` et `value` doivent être de vraies chaînes Lua.

Erreurs d'appelant, qui lèvent une erreur Lua :

```lua
-- babet.setenv()
-- babet.setenv("APP_MODE")
-- babet.setenv(42, "test")
-- babet.setenv("APP_MODE", 42)
```

Erreurs renvoyées sous la forme `(nil, err)` :

```lua
local ok, err = babet.setenv("BAD=NAME", "x")
-- ok == nil ; err indique un nom invalide
```

Un nom vide, un nom contenant `=` ou un octet NUL est refusé. Un octet NUL
dans la valeur est également refusé.

<a id="env-empty-unset"></a>
### Valeur vide et variable absente

Une valeur vide reste une valeur définie :

```lua
assert(babet.setenv("APP_OPTION", ""))
assert(babet.env("APP_OPTION") == "")
```

Elle est donc différente d'une variable absente :

```lua
local value = babet.env("VARIABLE_ABSENTE")
assert(value == nil)
```

Babet n'expose pas encore `unsetenv`. Il n'est pas possible de retirer une
variable avec `setenv(name, nil)` : `nil` est un mauvais type et l'appel lève
une erreur Lua.

<a id="env-workers"></a>
### Interaction avec les workers

`setenv` est autorisé uniquement avant le premier `workers.spawn()`.

```lua
assert(babet.setenv("APP_MODE", "production"))

local worker = assert(babet.workers.spawn([[
    return babet.env("APP_MODE")
]]))

local joined, value = worker:join()
assert(joined and value == "production")
```

Après le premier spawn, même si le worker est déjà terminé :

```lua
local ok, err = babet.setenv("APP_MODE", "test")
-- ok == nil
-- err explique que l'environnement partagé ne peut plus être modifié
```

L'interdiction est permanente pour la durée du processus, y compris si le
premier spawn a échoué. Prépare donc `PATH`, les variables d'application et le
répertoire courant avant de lancer les workers.

<a id="sys-memory"></a>
## Mémoire de la VM Lua

Les deux fonctions effectuent d'abord un cycle complet du ramasse-miettes Lua.
Le résultat reflète donc la mémoire encore utilisée après collecte, et l'appel
peut provoquer une pause proportionnelle à la taille de l'état Lua.

<a id="getmemoryusage"></a>
### `babet.getMemoryUsage()`

Renvoie le nombre d'octets actuellement comptabilisés par le gestionnaire de
mémoire de l'état Lua courant.

```lua
local bytes = babet.getMemoryUsage()
print(string.format("Lua utilise %d octets", bytes))
```

Le résultat est un integer positif.

Exemple de comparaison avant/après :

```lua
local before = babet.getMemoryUsage()

local values = {}
for i = 1, 10000 do
    values[i] = string.rep("x", 100)
end

local after = babet.getMemoryUsage()
print("Variation Lua :", after - before, "octets")
```

La mesure n'est pas un outil de profiling précis : l'allocateur, l'internement
des chaînes et les optimisations du GC peuvent faire varier le résultat.

<a id="getdetailedmemoryusage"></a>
### `babet.getDetailedMemoryUsage()`

Renvoie deux integers :

```lua
local used, total = babet.getDetailedMemoryUsage()
```

Dans la version actuelle, les deux valeurs sont **strictement identiques** :

```lua
assert(used == total)
```

La deuxième valeur est conservée uniquement pour la stabilité de l'API. Lua
n'expose pas séparément une mesure fiable de fragmentation ou de mémoire
réservée mais inutilisée.

Pour un nouveau code qui n'a besoin que d'une mesure, préfère :

```lua
local bytes = babet.getMemoryUsage()
```

<a id="memory-scope"></a>
### Ce qui est mesuré et ce qui ne l'est pas

La mesure couvre la mémoire gérée par **l'état Lua qui exécute l'appel**.

Elle ne représente pas :

- le RSS total du processus ;
- la pile native ;
- les allocations C++ du runtime ;
- les buffers OpenSSL, SQLite, HTTP ou sockets ;
- le code de l'exécutable et les bibliothèques partagées ;
- les états Lua des autres workers.

Dans un worker, la fonction mesure uniquement l'état Lua isolé de ce worker.
Pour mesurer la mémoire globale du processus, utilise un outil système comme
`/proc`, `ps`, `smem`, Valgrind ou un profiler adapté.

<a id="sys-errors"></a>
## Contrat d'erreur

| Situation | Comportement |
| --- | --- |
| argument manquant ou mauvais type | erreur Lua, récupérable avec `pcall` |
| NUL dans `env`, `setenv` ou `which` | erreur Lua pour `env`, `(nil, err)` pour `setenv` et `which` |
| variable absente dans `env` | `nil` seul |
| exécutable introuvable | `(nil, err)` |
| erreur de `hostname` ou `uname` | `(nil, err)` |
| `setenv` invalide ou refusé après un worker | `(nil, err)` |
| `pid` | toujours un integer |
| fonctions mémoire | toujours un ou deux integers après un GC complet |

Une exception C++ inattendue dans `which`, `env`, `setenv`, `hostname`, `uname`
ou `pid` est arrêtée par la frontière commune et devient
`(nil, "sys: out of memory")`, `(nil, "sys: internal failure")` ou
`(nil, "sys: unknown internal failure")`.

Il s’agit d’une frontière de sûreté interne, pas d’un nouvel état runtime
attendu. Le retour ordinaire d’une variable `env` absente reste un seul `nil`,
et `pid` reste un seul integer.

Exemple de traitement d'un échec runtime :

```lua
local tool, err = babet.which("outil-optionnel")
if not tool then
    print("Fonction désactivée :", err)
end
```

Exemple de traitement d'une mauvaise signature :

```lua
local ok, err = pcall(function()
    return babet.env(42)
end)

if not ok then
    print("Erreur de programmation :", err)
end
```

<a id="sys-design"></a>
## Décisions et limites

- Les fonctions historiques restent directement sous `babet` pour ne pas
  casser les scripts existants.
- `which` renvoie le premier exécutable trouvé, pas la liste de tous les
  candidats.
- `which` respecte le `PATH` du processus et les droits du processus courant ;
  son résultat peut donc différer selon l'utilisateur ou l'environnement.
- `env` distingue une variable absente (`nil`) d'une variable définie à la
  chaîne vide (`""`).
- `setenv` écrase toujours une valeur existante.
- Aucune fonction `unsetenv` ni dump complet de l'environnement n'est exposé.
- `pid` est le PID du processus, commun à tous les workers.
- Les fonctions mémoire provoquent volontairement un GC complet et ne mesurent
  pas le processus entier.
- Pour les comptes système, consulte le module
  [User - utilisateurs système](user.md).
