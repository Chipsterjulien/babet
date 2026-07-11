> [English](../../en/modules/sys.md) | **Français**

# `babet` sys — utilitaires système

Helpers d'introspection processus et hôte : PID, hostname, infos
kernel, lookup d'exécutable, variables d'environnement.

## Pourquoi

La stdlib Lua a `os.getenv` et `os.execute`, mais rien pour le PID,
le hostname, les infos kernel, ou un `which` portable. Ce sont des
besoins de scripting universels qui ne méritent pas un détour par
`popen`.

Ces fonctions vivent directement sur `babet` (plat, pas de
sous-table) parce qu'elles précèdent la convention par module
adoptée pour les ajouts récents.

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.pid()` | `integer` — PID du processus courant |
| `babet.hostname()` | `string` \| `(nil, err)` — hostname système |
| `babet.uname()` | `table` avec `sysname`, `nodename`, `release`, `version`, `machine` |
| `babet.which(cmd)` | `string` (chemin complet dans PATH) \| `(nil, "which: '<cmd>' not found in PATH")` |
| `babet.env(name)` | `string` \| `nil` — comme `os.getenv`, en cohérent |
| `babet.setenv(name, value)` | `(true, nil)` \| `(nil, err)` |
| `babet.getMemoryUsage()` | `integer` — mémoire de la VM Lua en octets (après un GC complet) |
| `babet.getDetailedMemoryUsage()` | `(integer, integer)` — actuellement les deux valeurs sont égales au compteur GC en octets ; gardé en deux retours pour la stabilité d'API |

## Constantes runtime

La même table `babet` expose aussi des constantes qui décrivent
le binaire Babet qui exécute le script. Utile pour le logging,
pour conditionner une feature à une version minimum, ou pour
sanity-checker le runtime.

| Constante | Type | Exemple |
| --- | --- | --- |
| `babet.VERSION` | `string` | `"2.1.1"` |
| `babet.VERSION_MAJOR` | `integer` | `2` |
| `babet.VERSION_MINOR` | `integer` | `1` |
| `babet.VERSION_PATCH` | `integer` | `1` |

La version string est ce que `babet --version` affiche. Les
composantes integer sont là pour faire des comparaisons
programmatiques sans parser la string.

```lua
-- Logger le runtime
print("tourne sous Babet " .. babet.VERSION)

-- Conditionner une feature à une version minimum
local need_minor = 1
if babet.VERSION_MAJOR < 2
   or (babet.VERSION_MAJOR == 2 and babet.VERSION_MINOR < need_minor) then
    error("ce script nécessite Babet >= 2." .. need_minor)
end
```

## Exemple rapide

```lua
print("Sur :", babet.hostname(), "PID :", babet.pid())

local u = babet.uname()
print("Kernel :", u.sysname, u.release, u.machine)

-- Trouver un binaire
local sh, err = babet.which("bash")
if sh then
    babet.exec({ sh, "-c", "echo hello" })
end

-- Lire/écrire env
print("HOME :", babet.env("HOME"))
babet.setenv("MY_VAR", "value")

-- Introspection mémoire (force un GC complet d'abord)
print("Mémoire VM Lua :", babet.getMemoryUsage(), "octets")
local a, b = babet.getDetailedMemoryUsage()
print("Détaillé :", a, b)
```

## Contrat d'erreur

- **`pid()`** : ne peut pas échouer, retourne toujours un integer.
- **`hostname()`** / **`which()`** : `(value, nil)` en succès,
  `(nil, err_string)` en échec.
- **`env(name)`** : `value` si défini, `nil` sinon. Lève seulement
  sur un argument non convertible en string (`nil`, table…) — un
  nombre est converti (`env(42)` cherche `"42"`).
- **`setenv(name, value)`** : `(true, nil)` en succès, `(nil, err)`
  en échec (rare — généralement OOM ou nom invalide).
- **`uname()`** : ne peut pas échouer sur un système supporté,
  renvoie toujours la table complète.
- **Mauvais type d'argument** (ex : `which({})`) → lève via
  `luaL_error` après coercion string par convention Lua. Passe une
  table ou booléen pour forcer une vraie erreur.

## Décisions de design

- **`env(name)` renvoie `nil`, pas `""`, pour les variables non
  définies**. Cohérent avec `os.getenv`. Les tests doivent utiliser
  `env("X") == nil`, pas `env("X") == ""`.
- **`which` renvoie le chemin absolu**, pas juste "oui/non". C'est
  plus utile : on peut `exec` le chemin renvoyé directement. Pour
  un check booléen, utilise `which(cmd) ~= nil`.
- **`uname()` renvoie une table, pas plusieurs valeurs**. Reste
  forward-compatible si un champ est ajouté un jour (ex :
  `domainname`).
- **`setenv` et les workers ne se mélangent pas** (audit v21 ;
  règle **appliquée par le runtime** depuis la revue croisée).
  POSIX ne synchronise pas `setenv`/`getenv` entre threads : un
  `babet.setenv` pendant qu'un worker — ou le runtime lui-même
  (résolution DNS, locale, `exec`) — lit l'environnement est une
  course de données. `babet.setenv` (et `babet.chdir`, dont le
  répertoire courant est lui aussi partagé par tout le processus)
  rendent donc `(nil, err)` dès qu'un `workers.spawn` a eu lieu —
  définitivement, même après `join`, même si le spawn a échoué. La
  transition est sérialisée par le même verrou que les mutations :
  aucun worker ne peut naître pendant un `setenv`/`chdir`. Fixe
  environnement et répertoire courant **avant** le premier worker.

## Hors v1

Additif — pourrait être ajouté plus tard :

- `unsetenv` — retirer une variable héritée n'est pas possible en
  v1 (`setenv(name, nil)` **lève** : la valeur doit être une
  string ; une valeur vide reste une variable définie). Et depuis
  le verrou workers, toute mutation d'env est de toute façon
  interdite après le premier `spawn`.
- `getuid` / `getgid` / `getppid` / `getlogin`.
- Dump complet de l'environnement en table.

Pour les lookups d'utilisateurs (UID → nom, etc.) voir le module
dédié [`user`](user.md) — il utilise NSS, qui est le bon backend
pour cette question.
