> [English](../../en/modules/exec.md) | **Français**

# EXEC - programmes externes, capture et streaming

Babet propose deux API complémentaires pour lancer un programme externe sans
shell implicite :

- `babet.exec` envoie éventuellement une entrée complète, capture `stdout` et
  `stderr` en mémoire, puis attend la fin du programme ;
- `babet.spawn` renvoie immédiatement un objet processus pilotable, afin de lire
  et écrire progressivement sans accumuler automatiquement les flux en RAM.

Le module EXEC couvre :

- la recherche d'un programme dans `PATH` ;
- la construction sûre de `argv`, sans parsing shell ;
- un répertoire de travail spécifique au processus enfant ;
- la fusion d'un environnement personnalisé avec celui de Babet ;
- l'envoi d'une chaîne binaire sur l'entrée standard ;
- la capture binaire de `stdout` et `stderr` ;
- un timeout couvrant le lancement, les échanges et l'attente finale ;
- une limite de mémoire distincte pour chaque flux de sortie ;
- l'arrêt du groupe de processus enfant en cas de timeout.

Il ne fournit pas de redirection directe vers un fichier, de pipeline implicite
ni d'interpréteur de commandes. Les redirections ou pipelines restent à
construire explicitement dans le script ou via un shell lancé volontairement.

## Table des matières du module

- [Conventions essentielles](#exec-conventions)
- [Vue d'ensemble de l'API](#exec-api-summary)
- [Signature et arguments](#exec-signature)
  - [`cmd` et recherche du programme](#exec-command)
  - [`args` et absence de shell](#exec-args)
  - [Utiliser explicitement un shell](#exec-shell)
- [Options](#exec-options)
  - [`cwd`](#exec-cwd)
  - [`env`](#exec-env)
  - [`stdin`](#exec-stdin)
  - [`timeout`](#exec-timeout)
  - [`max_output`](#exec-max-output)
- [Table de résultat](#exec-result)
  - [Code de sortie normal](#exec-exit-code)
  - [Fin par signal](#exec-signal-code)
  - [Timeout](#exec-result-timeout)
  - [Troncature](#exec-result-truncation)
- [Exemples complets](#exec-examples)
  - [Capture simple](#exec-example-basic)
  - [Arguments contenant des espaces](#exec-example-argv)
  - [Traiter un code non nul](#exec-example-nonzero)
  - [Capturer `stderr`](#exec-example-stderr)
  - [Envoyer du texte ou du binaire sur stdin](#exec-example-stdin)
  - [Modifier l'environnement](#exec-example-env)
  - [Changer de répertoire](#exec-example-cwd)
  - [Borner le temps](#exec-example-timeout)
  - [Borner la sortie](#exec-example-output)
  - [Créer un helper applicatif](#exec-example-helper)
- [Processus en streaming avec `babet.spawn`](#spawn-overview)
  - [Signature et options](#spawn-signature)
  - [Méthodes du processus](#spawn-methods)
  - [Lire stdout et stderr](#spawn-reading)
  - [Écrire sur stdin](#spawn-writing)
  - [Attendre, terminer et fermer](#spawn-lifecycle)
  - [Exemple de boucle de streaming](#spawn-example)
  - [Limites et prévention des blocages](#spawn-limits)
- [Contrat d'erreur](#exec-errors)
- [Processus, signaux et sécurité](#exec-process-security)
- [Décisions et limites](#exec-design)

<a id="exec-conventions"></a>
## Conventions essentielles

### Aucun shell implicite

Cette forme :

```lua
local result, err = babet.exec("printf", { "%s\n", "hello world" })
```

lance directement `printf`. Chaque élément de la table `args` devient un slot
séparé de `argv`. Les espaces, `$`, `*`, `;`, `>`, les guillemets et les autres
caractères spéciaux ne sont pas interprétés par un shell.

Cette propriété évite la plupart des problèmes de quoting et des injections de
commandes.

### Une sortie non nulle n'est pas une erreur de lancement

Un programme qui démarre correctement puis renvoie le code `1`, `2` ou `127`
produit normalement une table de résultat. L'appelant décide si ce code est
acceptable.

```lua
local result, err = babet.exec("grep", { "needle", "data.txt" })
assert(result, err)

if result.code == 0 then
    print("motif trouvé")
elseif result.code == 1 then
    print("aucune correspondance")
else
    error(result.stderr)
end
```

`assert(babet.exec(...))` vérifie seulement que Babet a pu lancer et suivre le
programme. Il ne vérifie pas `result.code`.

### Les chaînes de données sont binaires

`opts.stdin`, `result.stdout` et `result.stderr` sont des chaînes Lua
binary-safe. Elles peuvent contenir des octets NUL et ne sont pas limitées à du
texte UTF-8.

Les chaînes transmises à des API POSIX qui attendent une chaîne C - `cmd`, les
éléments de `args`, `cwd`, les noms et valeurs de variables d'environnement -
ne peuvent en revanche pas contenir d'octet NUL.

<a id="exec-api-summary"></a>
## Vue d'ensemble de l'API

```lua
local result, err = babet.exec(cmd, args?, opts?)
```

| Élément | Type | Défaut | Rôle |
| --- | --- | --- | --- |
| `cmd` | string stricte | obligatoire | programme ou chemin à exécuter |
| `args` | séquence de strings | aucun argument | éléments `argv[1]..argv[n]` |
| `opts.cwd` | string | répertoire courant hérité | répertoire de travail de l'enfant |
| `opts.env` | table string -> string | environnement hérité | variables ajoutées ou remplacées |
| `opts.stdin` | string binaire | stdin fermé immédiatement | données envoyées à l'enfant |
| `opts.timeout` | nombre fini > 0 | aucune limite | budget global en secondes |
| `opts.max_output` | integer `1..2 Gio` | 10 Mio | cap par flux capturé |

Résultats principaux :

| Situation | Résultat |
| --- | --- |
| programme lancé et terminé | `(result, nil)` |
| programme lancé puis timeout | `(result, nil)` avec `timed_out = true` |
| code de sortie non nul | `(result, nil)` avec `code ~= 0` |
| programme introuvable ou `cwd` invalide | `(nil, err)` |
| `args` ou `opts` invalides | `(nil, err)` |
| `cmd` absent ou non string | erreur Lua levée |

<a id="exec-signature"></a>
## Signature et arguments

<a id="exec-command"></a>
### `cmd` et recherche du programme

`cmd` doit être une véritable chaîne Lua.

```lua
local result, err = babet.exec("git", { "status", "--short" })
```

Si `cmd` ne contient pas de `/`, Babet demande à la libc de rechercher le
programme dans le `PATH` du processus Babet.

```lua
local result = assert(babet.exec("python3", { "--version" }))
```

Si `cmd` contient un `/`, il est traité comme un chemin direct.

```lua
local result = assert(babet.exec("/usr/bin/id", { "-u" }))
```

Un chemin relatif contenant `/` est résolu dans le répertoire de l'enfant,
après application éventuelle de `opts.cwd`.

```lua
local result = assert(babet.exec("./tool", {}, {
    cwd = "/opt/my-app/bin",
}))
```

#### Nuance sur `PATH` et `opts.env`

L'environnement final du programme enfant peut contenir un `PATH` remplacé via
`opts.env`. Toutefois, avec l'implémentation Linux actuelle basée sur
`execvpe`, la recherche initiale de `cmd` utilise le `PATH` du processus Babet,
pas la valeur `PATH` fournie dans `opts.env`.

```lua
local result, err = babet.exec("my-private-tool", {}, {
    env = { PATH = "/opt/private/bin" },
})
```

Cette forme ne garantit donc pas que `/opt/private/bin/my-private-tool` sera
trouvé. Utilise un chemin direct :

```lua
local result, err = babet.exec("/opt/private/bin/my-private-tool", {}, {
    env = { PATH = "/opt/private/bin" },
})
```

Le nouveau `PATH` sera bien visible **dans** le programme enfant et par les
sous-commandes qu'il lancera ensuite.

<a id="exec-args"></a>
### `args` et absence de shell

`args` est facultatif. Il doit être une table représentant une séquence dense
`1..n` de chaînes.

```lua
local result = assert(babet.exec("cp", {
    "--",
    "fichier avec espaces.txt",
    "destination/",
}))
```

Babet lit uniquement la partie séquence déterminée par Lua, de `1` à `#args`.
Pour un comportement prévisible :

- utilise des indices consécutifs à partir de `1` ;
- ne laisse aucun trou ;
- ne place pas de métadonnées dans la même table ;
- utilise uniquement des chaînes.

```lua
-- Correct
local args = { "-c", "print('ok')" }

-- Incorrect : valeur numérique
local result, err = babet.exec("lua", { "-e", 42 })
-- result == nil ; err indique que tous les arguments doivent être strings
```

`argv[0]` est automatiquement défini à `cmd`. Le premier élément de `args`
devient `argv[1]`.

<a id="exec-shell"></a>
### Utiliser explicitement un shell

Les opérateurs `|`, `>`, `&&`, `;`, les variables `$NAME` et les globs ne sont
interprétés que si tu lances volontairement un shell.

```lua
local result = assert(babet.exec("sh", {
    "-c",
    "printf '%s\n' \"$HOME\" | sed 's#^#home=#'",
}))
```

Les données incorporées dans une commande shell doivent alors être quotées avec
les règles du shell. Pour des valeurs non fiables, préfère les transmettre via
`args`, `stdin` ou `env` plutôt que de les concaténer dans le script `-c`.

<a id="exec-options"></a>
## Options

Le troisième argument est facultatif. S'il est fourni, il doit être une table.
Les champs inconnus sont actuellement ignorés ; une faute de frappe comme
`timeot = 5` ne déclenche donc pas d'erreur. Utilise exactement les noms
ci-dessous.

<a id="exec-cwd"></a>
### `opts.cwd`

Définit le répertoire courant du programme enfant sans modifier celui du
processus Babet.

```lua
local result, err = babet.exec("pwd", {}, {
    cwd = "/var/tmp",
})
assert(result, err)
print(result.stdout) -- /var/tmp
```

Le `chdir` est réalisé dans l'enfant avant le lancement du programme. Il affecte
notamment :

- les chemins relatifs utilisés par le programme ;
- un `cmd` relatif contenant `/` ;
- les composantes relatives du `PATH` utilisé pour la recherche.

Si le dossier n'existe pas ou n'est pas accessible, Babet renvoie `(nil, err)`.
Le répertoire courant de Babet reste inchangé.

<a id="exec-env"></a>
### `opts.env`

`env` est une table dont chaque clé et chaque valeur doit être une chaîne.
L'environnement est **fusionné** avec celui du processus Babet.

```lua
local result = assert(babet.exec("sh", {
    "-c", "printf '%s' \"$APP_MODE\"",
}, {
    env = { APP_MODE = "production" },
}))

assert(result.stdout == "production")
```

Règles :

- une clé fournie remplace la variable héritée de même nom ;
- une clé absente reste héritée ;
- une valeur `""` crée ou conserve une variable définie mais vide ;
- il n'existe pas d'option pour supprimer complètement une variable ;
- une clé doit être non vide et ne pas contenir `=` ;
- clés et valeurs refusent les octets NUL ;
- les types autres que string sont refusés.

Définie mais vide n'est pas la même chose qu'absente :

```lua
local result = assert(babet.exec("sh", { "-c", [[
    if [ "${TOKEN+x}" = x ] && [ -z "$TOKEN" ]; then
        printf 'defined-empty'
    fi
]] }, {
    env = { TOKEN = "" },
}))

assert(result.stdout == "defined-empty")
```

L'environnement est préparé dans le parent avant `fork`, ce qui évite d'appeler
`setenv` dans un enfant issu d'un processus multithreadé.

<a id="exec-stdin"></a>
### `opts.stdin`

`stdin` est une chaîne envoyée intégralement à l'entrée standard du programme.

```lua
local result = assert(babet.exec("sha256sum", { "-" }, {
    stdin = "hello world\n",
}))
print(result.stdout)
```

La chaîne est binary-safe :

```lua
local payload = "A\0B\0C"
local result = assert(babet.exec("cat", {}, { stdin = payload }))
assert(result.stdout == payload)
```

Si `stdin` est absent ou `nil`, Babet ferme immédiatement le pipe d'entrée. Le
programme enfant observe donc un EOF. Une chaîne vide produit elle aussi un EOF,
après l'ouverture normale du pipe.

Babet écrit et lit les trois pipes concurremment pour éviter les deadlocks avec
un programme qui produit beaucoup de sortie avant de consommer toute son entrée.

<a id="exec-timeout"></a>
### `opts.timeout`

`timeout` est un nombre fini strictement positif exprimé en secondes.

```lua
local result = assert(babet.exec("sleep", { "30" }, {
    timeout = 0.5,
}))

assert(result.timed_out)
```

Le budget commence avant la préparation du lancement et couvre :

1. la préparation de l'environnement ;
2. `fork` ;
3. le `chdir` de l'enfant ;
4. l'appel `exec` ;
5. l'envoi de stdin ;
6. la capture de stdout et stderr ;
7. l'attente finale du processus.

La résolution interne est la milliseconde. Une valeur inférieure à `0.001`
se comporte donc comme une échéance quasiment immédiate et ne doit pas être
utilisée pour une temporisation précise.

La valeur doit rester inférieure ou égale à `INT_MAX` millisecondes, soit
environ 24,8 jours. Les valeurs nulles, négatives, NaN, infinies ou trop grandes
sont refusées avec `(nil, err)`.

À l'expiration après le lancement :

1. Babet envoie `SIGTERM` au groupe de processus ;
2. il laisse jusqu'à 2 secondes pour une sortie propre ;
3. il envoie `SIGKILL` si nécessaire ;
4. il draine encore les sorties pendant une fenêtre bornée.

<a id="exec-max-output"></a>
### `opts.max_output`

`max_output` limite le nombre d'octets conservés **pour chaque flux**.

```lua
local result = assert(babet.exec("yes", {}, {
    timeout = 0.2,
    max_output = 4096,
}))

assert(#result.stdout == 4096)
assert(result.stdout_truncated)
```

Valeurs :

- défaut : `10 * 1024 * 1024`, soit 10 Mio ;
- minimum : 1 octet ;
- maximum : `2 * 1024 * 1024 * 1024`, soit 2 Gio ;
- type : nombre entier Lua.

La limite est indépendante : jusqu'à 10 Mio de stdout **et** 10 Mio de stderr
par défaut.

Une fois la limite atteinte, Babet continue à lire et à jeter le surplus. Cette
étape est essentielle : arrêter de lire remplirait le pipe et pourrait bloquer
le programme enfant. Les premiers octets sont conservés ; les derniers sont
perdus.

<a id="exec-result"></a>
## Table de résultat

Après un lancement réussi, le premier résultat est toujours une table avec les
six champs suivants :

```lua
{
    stdout = "...",
    stderr = "...",
    code = 0,
    timed_out = false,
    stdout_truncated = false,
    stderr_truncated = false,
}
```

| Champ | Type | Signification |
| --- | --- | --- |
| `stdout` | string binaire | premiers octets capturés sur la sortie standard |
| `stderr` | string binaire | premiers octets capturés sur la sortie d'erreur |
| `code` | integer | code normal, convention signal, ou `-1` si indisponible |
| `timed_out` | boolean | Babet a déclenché l'arrêt pour dépassement du budget |
| `stdout_truncated` | boolean | stdout a dépassé `max_output` |
| `stderr_truncated` | boolean | stderr a dépassé `max_output` |

<a id="exec-exit-code"></a>
### Code de sortie normal

Quand le programme appelle `exit(n)` ou retourne depuis `main`, `code` vaut le
statut POSIX `0..255`.

```lua
local result = assert(babet.exec("sh", { "-c", "exit 7" }))
assert(result.code == 7)
assert(not result.timed_out)
```

<a id="exec-signal-code"></a>
### Fin par signal

Quand le processus est terminé par un signal, Babet utilise la convention :

```text
code = 128 + numéro_du_signal
```

Par exemple, `SIGKILL` vaut généralement 9 sous Linux, donc `code == 137`.
Cette convention est pratique mais ne remplace pas un champ séparé indiquant le
signal exact ; aucun tel champ n'existe actuellement.

<a id="exec-result-timeout"></a>
### Timeout

`timed_out == true` signifie que Babet a atteint son échéance et a commencé la
procédure d'arrêt. Le champ `code` dépend de la façon dont le programme s'est
terminé :

- code volontaire si le programme intercepte `SIGTERM` et sort proprement ;
- souvent `143` pour `SIGTERM` ;
- souvent `137` après `SIGKILL` ;
- exceptionnellement `-1` si le statut n'a pas pu être obtenu dans la fenêtre
  de nettoyage bornée.

Ne teste donc pas uniquement `code == 137` pour reconnaître un timeout :
utilise `timed_out`.

La sortie produite avant l'échéance est conservée dans la limite de
`max_output`.

<a id="exec-result-truncation"></a>
### Troncature

Les flags `stdout_truncated` et `stderr_truncated` indiquent uniquement que le
flux correspondant a dépassé `max_output`.

```lua
if result.stdout_truncated then
    print("stdout incomplet : augmente max_output ou redirige vers un fichier")
end
```

Dans un cas noyau extrêmement pathologique où un descendant échappe au groupe
et maintient un pipe ouvert après `SIGKILL`, Babet peut abandonner le drainage
pour ne pas rester bloqué indéfiniment. Cette cause rare n'est pas représentée
par les flags de troncature, qui restent réservés au cap mémoire.

<a id="exec-examples"></a>
## Exemples complets

<a id="exec-example-basic"></a>
### Capture simple

```lua
local result, err = babet.exec("git", { "rev-parse", "HEAD" })
assert(result, err)

if result.code ~= 0 then
    error("git a échoué : " .. result.stderr)
end

local commit = result.stdout:gsub("%s+$", "")
print(commit)
```

<a id="exec-example-argv"></a>
### Arguments contenant des espaces

```lua
local filename = "rapport juillet 2026.txt"
local result = assert(babet.exec("printf", {
    "nom=<%s>\n",
    filename,
}))

assert(result.stdout == "nom=<rapport juillet 2026.txt>\n")
```

Aucun guillemet supplémentaire n'est nécessaire autour de `filename` : la
frontière d'argument est déjà représentée par la table Lua.

<a id="exec-example-nonzero"></a>
### Traiter un code non nul

```lua
local result, err = babet.exec("diff", {
    "--brief",
    "config.old",
    "config.new",
})
assert(result, err)

if result.code == 0 then
    print("fichiers identiques")
elseif result.code == 1 then
    print("fichiers différents")
else
    error("diff impossible : " .. result.stderr)
end
```

<a id="exec-example-stderr"></a>
### Capturer `stderr`

```lua
local result = assert(babet.exec("sh", {
    "-c", "printf out; printf err >&2",
}))

assert(result.stdout == "out")
assert(result.stderr == "err")
```

<a id="exec-example-stdin"></a>
### Envoyer du texte ou du binaire sur stdin

```lua
local csv = "name,score\nAlice,18\nBob,15\n"
local result = assert(babet.exec("sort", {}, { stdin = csv }))
print(result.stdout)
```

```lua
local bytes = string.char(0x00, 0x01, 0xFE, 0xFF)
local result = assert(babet.exec("cat", {}, { stdin = bytes }))
assert(result.stdout == bytes)
```

<a id="exec-example-env"></a>
### Modifier l'environnement

```lua
local result = assert(babet.exec("sh", { "-c", [[
    printf 'mode=%s lang=%s' "$APP_MODE" "$LANG"
]] }, {
    env = {
        APP_MODE = "test",
        LANG = "C",
    },
}))

print(result.stdout)
```

Seules les clés fournies sont remplacées. Les autres variables, notamment
`HOME`, restent héritées.

<a id="exec-example-cwd"></a>
### Changer de répertoire

```lua
local result = assert(babet.exec("find", {
    ".", "-maxdepth", "1", "-type", "f",
}, {
    cwd = "/var/log",
}))

print(result.stdout)
```

Le CWD du script principal n'est pas modifié.

<a id="exec-example-timeout"></a>
### Borner le temps

```lua
local result, err = babet.exec("sh", {
    "-c", "printf started; sleep 30",
}, {
    timeout = 1.0,
})
assert(result, err)

if result.timed_out then
    print("commande interrompue après le budget")
    print("sortie disponible :", result.stdout)
end
```

<a id="exec-example-output"></a>
### Borner la sortie

```lua
local result = assert(babet.exec("sh", {
    "-c", "yes log-line | head -n 100000",
}, {
    max_output = 64 * 1024,
}))

if result.stdout_truncated then
    print("seuls les 64 premiers Kio ont été conservés")
end
```

Pour des gigaoctets, ne capture pas en mémoire. Lance explicitement un shell et
redirige vers un fichier choisi avec soin :

```lua
local result = assert(babet.exec("sh", {
    "-c", "my-command > /var/tmp/my-command.log 2>&1",
}, {
    timeout = 600,
}))
```

<a id="exec-example-helper"></a>
### Créer un helper applicatif

```lua
local function run_checked(cmd, args, opts)
    local result, err = babet.exec(cmd, args, opts)
    if not result then
        return nil, err
    end
    if result.timed_out then
        return nil, string.format("%s: timeout", cmd)
    end
    if result.code ~= 0 then
        local detail = result.stderr ~= "" and result.stderr or result.stdout
        return nil, string.format(
            "%s: code %d: %s",
            cmd,
            result.code,
            detail
        )
    end
    return result
end

local result, err = run_checked("git", { "status", "--short" }, {
    cwd = "/srv/project",
    timeout = 10,
})
assert(result, err)
print(result.stdout)
```

<a id="spawn-overview"></a>
## Processus en streaming avec `babet.spawn`

`babet.spawn` utilise le même moteur de lancement sécurisé que `babet.exec`,
mais ne capture pas automatiquement les flux et n'attend pas la fin du
programme. Il renvoie un userdata représentant le processus enfant :

```lua
local process, err = babet.spawn("yt-dlp", {
    "--newline",
    "https://example.invalid/video",
})
assert(process, err)
```

Le processus dispose de trois pipes non bloquants : stdin, stdout et stderr. Le
script décide quand lire, écrire, attendre ou arrêter le groupe de processus.
Cette API est adaptée aux programmes longs, aux sorties volumineuses et à
l'affichage de progression en temps réel.

<a id="spawn-signature"></a>
### Signature et options

```lua
local process, err = babet.spawn(command, args?, opts?)
```

| Élément | Type | Défaut | Rôle |
| --- | --- | --- | --- |
| `command` | string stricte | obligatoire | programme ou chemin à lancer |
| `args` | array dense de strings | aucun argument | `argv[1]..argv[n]` |
| `opts.cwd` | string | répertoire courant hérité | répertoire de l'enfant |
| `opts.env` | table string -> string | environnement hérité | variables ajoutées/remplacées |
| `opts.launch_timeout` | nombre fini > 0 | attente illimitée | borne la phase `chdir` + `exec` |

Contrairement à `babet.exec`, les options inconnues sont refusées. `spawn`
n'accepte pas `stdin`, `timeout` ni `max_output` : stdin est écrit avec
`process:write()`, la durée de vie est pilotée avec `wait()`/`terminate()`, et
les sorties sont lues progressivement.

`launch_timeout` couvre uniquement la phase de lancement avant que le nouvel
exécutable soit établi. Il ne limite pas la durée totale du programme.

La recherche dans `PATH`, le traitement des chemins contenant `/`, la fusion de
`env` et l'absence de shell implicite suivent les mêmes règles que `exec`.

<a id="spawn-methods"></a>
### Méthodes du processus

| Méthode | Retour | Rôle |
| --- | --- | --- |
| `process:read_stdout([max_bytes [, timeout]])` | `(data, nil)` ou `(nil, reason)` | lit au plus `max_bytes` sur stdout |
| `process:read_stderr([max_bytes [, timeout]])` | `(data, nil)` ou `(nil, reason)` | lit au plus `max_bytes` sur stderr |
| `process:write(data [, timeout])` | `(bytes_written, nil)` ou `(nil, reason)` | écrit une partie de `data` sur stdin |
| `process:close_stdin()` | `(true, nil)` | ferme stdin, de façon idempotente |
| `process:is_running()` | `boolean` ou `(nil, err)` | vérifie l'état sans bloquer |
| `process:pid()` | integer | renvoie le PID attribué |
| `process:wait([timeout])` | `(result, nil)` ou `(nil, reason)` | attend la fin sans tuer au timeout |
| `process:terminate([grace_period])` | `(result, nil)` ou `(nil, err)` | envoie SIGTERM puis SIGKILL si nécessaire |
| `process:kill()` | `(result, nil)` ou `(nil, err)` | envoie SIGKILL au groupe |
| `process:close()` | `(true, nil)` | nettoie les pipes et un enfant encore actif |

Les raisons courtes `"timeout"`, `"closed"` et `"interrupted"` sont typées,
comme pour les sockets. Les autres erreurs portent le préfixe `process:` ou
`spawn:`.

La table renvoyée par `wait`, `terminate` et `kill` contient :

```lua
{
    code = 0,          -- code normal, ou 128 + signal
    exited = true,     -- fin normale via exit/_exit
    signaled = false,  -- fin causée par un signal
    signal = nil,      -- numéro du signal si signaled == true
}
```

Un second appel à `wait()` après la fin renvoie le même résultat : le statut est
mis en cache après le `waitpid` initial.

<a id="spawn-reading"></a>
### Lire stdout et stderr

Les lectures sont binary-safe. Par défaut, elles lisent au plus 64 Kio et sont
non bloquantes (`timeout = 0`). La taille maximale par appel est 16 Mio.

```lua
local chunk, err = process:read_stdout(64 * 1024, 0.25)

if chunk then
    io.write(chunk)
elseif err == "timeout" then
    -- rien de disponible pendant 250 ms
elseif err == "closed" then
    -- EOF définitif sur stdout
else
    error(err)
end
```

`"closed"` indique l'EOF du flux concerné, pas nécessairement la fin du
processus. Un enfant peut fermer stdout puis continuer à travailler.

Il faut drainer stdout **et** stderr. Lire un seul flux tandis que l'autre se
remplit peut bloquer le programme enfant lorsque le pipe noyau devient plein.

<a id="spawn-writing"></a>
### Écrire sur stdin

`write` accepte une chaîne Lua binaire, y compris des octets NUL. Le pipe est
non bloquant : même après une attente réussie, l'appel peut n'écrire qu'une
partie de la chaîne. La valeur renvoyée doit donc être utilisée pour reprendre à
l'octet suivant.

```lua
local function write_all(process, data)
    local offset = 1
    while offset <= #data do
        local written, err = process:write(data:sub(offset), 1)
        assert(written, err)
        offset = offset + written
    end
end

write_all(process, payload)
assert(process:close_stdin())
```

Une chaîne vide renvoie `(0, nil)`. Après `close_stdin`, `write` renvoie
`(nil, "closed")`. Fermer stdin est souvent indispensable pour que des outils
comme `cat`, `sort` ou `ffmpeg` sachent que l'entrée est terminée.

<a id="spawn-lifecycle"></a>
### Attendre, terminer et fermer

`wait()` sans argument attend la fin du processus. `wait(timeout)` rend
`(nil, "timeout")` si le délai expire, sans envoyer de signal et sans rendre
l'objet inutilisable.

```lua
local result, err = process:wait(0)
if not result and err == "timeout" then
    -- le processus tourne encore
end
```

`terminate(grace_period)` envoie SIGTERM à tout le groupe. Si le groupe ne se
termine pas avant la fin de la période de grâce, Babet envoie SIGKILL. La grâce
par défaut est de deux secondes. `kill()` envoie directement SIGKILL.

`close()` est idempotent. Si l'enfant tourne encore, il est terminé et réapé de
façon bornée, puis les trois pipes sont fermés. Le garbage collector et la
métaméthode Lua `__close` effectuent le même nettoyage :

```lua
local process <close> = assert(babet.spawn("long-job"))
-- nettoyage automatique en quittant la portée
```

Une fermeture explicite reste recommandée, car le moment d'exécution du garbage
collector n'est pas déterministe.

<a id="spawn-example"></a>
### Exemple de boucle de streaming

```lua
local process, err = babet.spawn("yt-dlp", {
    "--newline",
    "-f", "bestvideo+bestaudio/best",
    url,
})
assert(process, err)

local stdout_open, stderr_open = true, true

while stdout_open or stderr_open do
    if stdout_open then
        local data, read_err = process:read_stdout(64 * 1024, 0.1)
        if data then
            io.write(data)
            io.flush()
        elseif read_err == "closed" then
            stdout_open = false
        elseif read_err ~= "timeout" then
            error(read_err)
        end
    end

    if stderr_open then
        local data, read_err = process:read_stderr(64 * 1024, 0)
        if data then
            io.stderr:write(data)
            io.stderr:flush()
        elseif read_err == "closed" then
            stderr_open = false
        elseif read_err ~= "timeout" then
            error(read_err)
        end
    end
end

local result, wait_err = process:wait(5)
assert(result, wait_err)
process:close()

if result.code ~= 0 then
    error("yt-dlp a quitté avec le code " .. result.code)
end
```

<a id="spawn-limits"></a>
### Limites et prévention des blocages

- `wait()` ne draine pas les sorties. Appeler `wait()` immédiatement sur un
  enfant très bavard peut bloquer si ses pipes deviennent pleins. Draine les
  deux flux pendant son exécution, ou utilise `babet.exec` pour une petite
  sortie capturée automatiquement.
- Écrire une grosse entrée à un programme qui réémet simultanément beaucoup de
  données exige d'alterner écriture et lecture. Un unique `write_all` avant
  toute lecture peut remplir les pipes dans les deux sens.
- Il n'existe pas encore d'attente multi-processus ou de callback Lua appelé
  depuis le C++. Le pilotage reste volontairement explicite et réentrant.
- stdout et stderr sont toujours séparés. Babet ne les fusionne pas et ne crée
  pas de pipeline entre deux objets processus.
- `close()` et `terminate()` ciblent le groupe de processus créé au lancement.
  Un descendant qui change volontairement de groupe ou de session peut échapper
  à ce contrôle, comme avec `babet.exec`.

<a id="exec-errors"></a>
## Contrat d'erreur

### Erreurs Lua levées

Seule la signature du premier argument utilise une erreur Lua :

```lua
babet.exec()   -- lève : commande manquante
babet.exec(42) -- lève : cmd doit être une string
```

Utilise `pcall` uniquement si une mauvaise signature peut provenir de données
non maîtrisées.

### Erreurs renvoyées `(nil, err)`

Les validations suivantes ne lèvent pas ; elles renvoient `(nil, err)` :

- `args` n'est ni une table ni `nil` ;
- un élément de `args` n'est pas une string ;
- `opts` n'est ni une table ni `nil` ;
- `cwd`, `stdin`, `timeout`, `max_output` ou `env` ont un mauvais type ;
- une clé d'environnement est vide, contient `=` ou un NUL ;
- une valeur d'environnement contient un NUL ;
- timeout nul, négatif, non fini ou trop grand ;
- `max_output` nul, négatif, fractionnaire ou supérieur à 2 Gio ;
- programme introuvable ou non exécutable ;
- `cwd` invalide ;
- échec de `pipe`, `fork`, `poll`, `waitpid` ou autre erreur interne système.

```lua
local result, err = babet.exec("echo", "hello")
assert(result == nil)
print(err) -- args must be a table
```

### Situations renvoyant une table

Ces situations ne sont pas des erreurs de l'API :

- le programme renvoie un code non nul ;
- le programme écrit sur `stderr` ;
- le timeout expire après ou pendant le lancement ;
- la sortie dépasse `max_output`.

<a id="exec-process-security"></a>
## Processus, signaux et sécurité

### Groupe de processus

L'enfant crée son propre groupe. En cas de timeout, Babet signale le groupe et
pas seulement le PID direct. Cela couvre normalement les descendants lancés
par un shell ou par le programme.

Un descendant qui appelle volontairement `setsid` ou change de groupe peut
échapper à cette stratégie. `babet.exec` n'est pas un sandbox et ne remplace
pas systemd, les cgroups, les namespaces ou les limites de ressources.

### Interaction avec `babet.signal`

`babet.exec` n'est pas signal-aware. Un signal géré reçu pendant l'appel ne
fait pas renvoyer `(nil, "interrupted")`. Le handler C marque le signal comme
en attente ; le callback Lua ne pourra être dispatché qu'après le retour dans
la VM Lua, généralement via le hook d'instructions du module SIGNAL.

Utilise `opts.timeout` pour borner une commande longue. Pour interrompre une
commande à la demande, conçois un protocole externe ou lance-la via un service
supervisé.

### Mémoire

`stdin` est conservé en mémoire par le script, et stdout/stderr sont capturés en
mémoire dans les limites choisies. Le défaut autorise environ 20 Mio de capture
au total, plus les allocations du programme et des chaînes Lua.

<a id="exec-design"></a>
## Décisions et limites

- Linux/POSIX uniquement : l'implémentation utilise `fork`, `execvpe`, `poll`,
  les groupes de processus et les signaux.
- Aucun shell implicite.
- Aucun pipeline natif entre plusieurs appels `exec`.
- Un seul bloc `stdin`, pas de producteur streaming.
- Capture complète retournée à la fin, pas de callback ligne par ligne.
- Pas de redirection native de stdin/stdout/stderr vers des fichiers ou fd.
- Pas de champ séparé `signal` dans la table de résultat.
- Pas de modification/unset complet de l'environnement : `env` fusionne et une
  chaîne vide reste une variable définie.
- Les champs inconnus de `opts` sont ignorés.
- La recherche initiale dans `PATH` suit actuellement l'environnement du
  processus Babet, même si `opts.env.PATH` est remplacé.
- Les callbacks de `babet.signal` ne sont pas dispatchés pendant l'appel.

Pour les règles de sécurité générales, consulte
[`Sécurité`](../security.md).
