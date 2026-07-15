> [English](../../en/modules/pipeline.md) | **Français**

# Pipelines de processus

Babet fournit deux API complémentaires pour relier plusieurs programmes par des
pipes POSIX, sans passer par un shell :

- `babet.pipeline()` exécute le pipeline jusqu'à sa fin et capture les flux ;
- `babet.spawnPipeline()` rend immédiatement un objet pilotable en streaming.

Dans les deux cas, stdout d'une étape est connecté directement à stdin de la
suivante. Le parent n'intercepte que stdin de la première étape, stdout de la
dernière et stderr de chaque étape séparément.

## Syntaxe commune des commandes

```lua
local commands = {
    { "printf", { "orange\npomme\norange\n" } },
    { "grep", { "orange" } },
    { "sort", { "-u" } },
}
```

`commands` doit être un tableau dense de 2 à 32 étapes. Chaque étape prend l'une
des formes suivantes :

```lua
{ command }
{ command, args }
{ command, args, opts }
```

Pour fournir `opts` sans argument, utilise explicitement `{ command, {}, opts }` ;
les tableaux troués sont refusés.

- `command` est une chaîne non vide sans octet NUL ;
- `args` est un tableau dense de chaînes sans octet NUL ;
- `opts.cwd` définit le répertoire de travail de l'étape ;
- `opts.env` ajoute ou remplace des variables d'environnement pour l'étape.

Aucune chaîne n'est interprétée par un shell : jokers, redirections, variables,
guillemets et opérateurs comme `|`, `&&` ou `>` n'ont aucun sens spécial.

Les options globales `cwd` et `env` servent de valeurs par défaut. Un `cwd`
local remplace le `cwd` global. L'environnement local est fusionné après
l'environnement global et gagne en cas de nom identique. Toutes les commandes
sont validées avant le premier `fork()`.

Comme pour `exec()` et `spawn()`, lorsqu’une commande ne contient pas `/`, sa
recherche initiale utilise le `PATH` du processus Babet, pas un `PATH` remplacé
dans `opts.env` ou dans l’environnement local d’une étape. Pour lancer un outil
présent uniquement dans ce nouveau `PATH`, utilisez son chemin explicite ou
modifiez le `PATH` de Babet avant le lancement.

# `babet.pipeline()` — exécution complète

## Signature

```lua
result, err = babet.pipeline(commands [, opts])
```

Exemple :

```lua
local result, err = babet.pipeline({
    { "printf", { "orange\npomme\norange\n" } },
    { "grep", { "orange" } },
    { "sort", { "-u" } },
}, {
    timeout = 10,
    max_output = 16 * 1024 * 1024,
})

assert(result, err)
print(result.stdout)
```

## Options

| Option | Type | Description |
|---|---|---|
| `cwd` | chaîne | Répertoire de travail par défaut de toutes les étapes. |
| `env` | table chaîne vers chaîne | Variables fusionnées avec l'environnement de Babet. |
| `stdin` | chaîne binaire | Données écrites progressivement dans la première étape, puis stdin est fermé. |
| `timeout` | nombre fini strictement positif, au plus `10^12` | Délai global en secondes, lancement, E/S et attente finale compris. |
| `max_output` | entier de 1 à 2 Gio | Plafond distinct pour stdout final et chaque stderr ; défaut : 10 Mio. |

Les clés inconnues sont refusées. `stdin`, stdout et stderr sont binaires et
peuvent contenir des octets NUL. Le timeout a une résolution interne d’une
milliseconde ; les valeurs supérieures à `10^12` secondes sont refusées.

## Résultat

Après le lancement effectif de toutes les étapes, une terminaison non nulle ou
un signal ne constitue pas une erreur d'API. Babet renvoie :

```lua
{
    stdout = "...",
    stderr = { "stderr étape 1", "stderr étape 2", ... },
    stages = {
        {
            launched = true,
            code = 0,
            exited = true,
            signaled = false,
            signal = nil,
        },
        -- ...
    },
    code = 0,
    all_succeeded = true,
    failed_index = nil,
    timed_out = false,
    stdout_truncated = false,
    stderr_truncated = { false, false, ... },
}
```

`code` est celui de la dernière étape, comme pour un pipeline Unix. Il vaut le
code de sortie normal ou `128 + numéro_du_signal`. Dans le cas pathologique où
un statut reste indisponible après un nettoyage borné consécutif à un timeout,
il vaut `-1` pour l’étape concernée. `all_succeeded` n'est vrai que si toutes
les étapes ont réussi. `failed_index` indique la première étape dont le code
n'est pas zéro, même si la dernière réussit.

Une étape intermédiaire non nulle n'arrête pas artificiellement les autres.
Les pipes conservent leur comportement POSIX normal ; un producteur amont peut
notamment recevoir `SIGPIPE` si le consommateur ferme son entrée.

## Timeout, gros volumes et troncature

Le timeout de `pipeline()` couvre le lancement, l'écriture de stdin, le drainage
de stdout et stderr et l'attente finale. S'il expire avant que toutes les étapes
aient terminé `chdir` et `exec`, l'appel renvoie `nil, err` avec le message
`"pipeline: launch timed out"` après rollback des étapes déjà créées. Après un lancement complet,
l'expiration produit une table de résultat avec `timed_out == true` : Babet ferme
stdin, envoie `SIGTERM` aux groupes de toutes les étapes, puis `SIGKILL` aux
survivants et récupère les enfants directs.

Les descripteurs sont non bloquants et pilotés avec `poll()`. stdin, stdout
final et tous les stderr progressent simultanément, ce qui évite les deadlocks
classiques avec de gros volumes. Après `max_output`, les octets supplémentaires
sont jetés mais le flux continue d'être drainé ; le drapeau de troncature
correspondant est alors vrai.

# `babet.spawnPipeline()` — streaming

## Signature

```lua
pipeline, err = babet.spawnPipeline(commands [, opts])
```

Options globales :

| Option | Type | Description |
|---|---|---|
| `cwd` | chaîne | Répertoire de travail par défaut de toutes les étapes. |
| `env` | table chaîne vers chaîne | Variables fusionnées avec l'environnement de Babet. |
| `launch_timeout` | nombre fini strictement positif | Délai couvrant uniquement la création et le lancement complet des étapes, au plus `INT_MAX` millisecondes (environ 24,8 jours). |

`spawnPipeline()` n'accepte ni `stdin`, ni `timeout`, ni `max_output` : le
script écrit et lit progressivement et choisit lui-même ses limites. Un succès
renvoie un userdata et `nil` ; une erreur de validation ou de lancement renvoie
`nil, err` après nettoyage des étapes déjà créées.

```lua
local pipeline, err = babet.spawnPipeline({
    { "cat" },
    { "tr", { "a-z", "A-Z" } },
})
assert(pipeline, err)

local written, write_err = pipeline:write("bonjour\n")
assert(written, write_err)
assert(pipeline:close_stdin())

local chunks = {}
while true do
    local data, read_err = pipeline:read_stdout(64 * 1024, 1)
    if data then
        chunks[#chunks + 1] = data
    elseif read_err == "closed" then
        break
    elseif read_err ~= "timeout" then
        error(read_err)
    end
end

local status, wait_err = pipeline:wait(5)
assert(status, wait_err)
assert(status.code == 0)
print(table.concat(chunks))
```

## Méthodes de lecture

```lua
data, err = pipeline:read_stdout([max_bytes [, timeout]])
data, err = pipeline:read_stderr(stage [, max_bytes [, timeout]])
```

- `max_bytes` vaut 64 Kio par défaut et doit être compris entre 1 et 16 Mio ;
- `timeout` est exprimé en secondes, vaut zéro par défaut, doit être fini et
  positif ou nul, et ne peut pas dépasser `INT_MAX` millisecondes, soit environ
  24,8 jours ;
- `stage` est un indice de 1 au nombre d'étapes ;
- une arité invalide, un indice invalide ou un `max_bytes` invalide lève une erreur Lua, comme les méthodes de `babet.spawn()` ;
- un timeout invalide renvoie `nil, err` ;
- un succès renvoie une chaîne binaire non vide et `nil` ;
- aucune donnée immédiatement disponible renvoie `nil, "timeout"` ;
- la fin du flux, ou une lecture après sa fermeture, renvoie
  `nil, "closed"`.

Chaque appel lit au plus un bloc. Il n'existe aucune capture cachée : le script
est responsable de conserver, limiter ou jeter les données reçues. Les stderr
restent indépendants ; il faut donc drainer ceux susceptibles de produire assez
de données pour remplir leur pipe.

## Écriture et fermeture de stdin

```lua
count, err = pipeline:write(data [, timeout])
ok, err = pipeline:close_stdin()
```

`write()` accepte une chaîne binaire. Il peut n'écrire qu'une partie de la
chaîne ; `count` indique le nombre d'octets réellement transmis. Une chaîne
vide renvoie `0, nil`. Après timeout, l'objet reste réutilisable. Une entrée
fermée par le script ou par le processus aval renvoie `nil, "closed"` sans
livrer `SIGPIPE` au processus Babet.

`close_stdin()` ferme l'entrée de la première étape et est idempotente. Elle
doit être appelée lorsque plus aucune donnée ne sera écrite, sinon un programme
attendant EOF peut ne jamais terminer.

Exemple d'écriture complète :

```lua
local offset = 1
while offset <= #data do
    local count, err = pipeline:write(data:sub(offset), 1)
    if count then
        offset = offset + count
    elseif err ~= "timeout" then
        error(err)
    end
    -- Pendant un gros transfert, drainer aussi stdout et les stderr.
end
assert(pipeline:close_stdin())
```

## État et identifiants

```lua
running = pipeline:is_running([stage])
pids = pipeline:pids()
```

Sans indice, `is_running()` est vrai tant qu'au moins une étape directe n'a pas
été récupérée. Avec un indice, il décrit uniquement cette étape. L'appel interroge les statuts
sans blocage et ne consomme pas le résultat final : `wait()` reste utilisable
ensuite.

`pids()` renvoie les PID directs dans l'ordre des étapes. Ils sont fournis pour
le diagnostic ; le script ne doit pas supposer qu'ils restent valides après la
fin du pipeline.

## Attente et résultat final

```lua
status, err = pipeline:wait([timeout])
```

Sans timeout, `wait()` attend tous les enfants directs. Avec un timeout fini et
positif ou nul, `nil, "timeout"` laisse le pipeline intact et réutilisable. Une
fois tous les statuts acquis, les appels suivants sont idempotents et renvoient
le même résultat :

```lua
{
    stages = {
        { launched = true, code = 0, exited = true,
          signaled = false, signal = nil },
        -- ...
    },
    code = 0,
    all_succeeded = true,
    failed_index = nil,
}
```

`wait()` **ne draine pas** stdout ou stderr. Un pipeline qui remplit un pipe peut
donc rester bloqué avant de terminer. Il faut lire les flux pendant l'exécution,
exactement comme avec `babet.spawn()`.

## Arrêt explicite

```lua
status, err = pipeline:terminate([grace_period])
status, err = pipeline:kill()
```

`terminate()` envoie `SIGTERM` à chaque groupe de processus, laisse
`grace_period` secondes — 2 secondes par défaut — aux processus pour terminer,
puis envoie `SIGKILL` aux survivants. La période de grâce doit tenir dans
`INT_MAX` millisecondes, soit environ 24,8 jours. `kill()` envoie directement
`SIGKILL`. Les deux méthodes ferment
stdin et renvoient la même table de statuts que `wait()` lorsque tous les
enfants directs ont été récupérés.

Chaque étape possède son propre groupe. Avant de récupérer le processus direct,
Babet supprime les descendants encore présents dans ce groupe, y compris lors
d'une terminaison normale où la commande a quitté sans attendre un enfant lancé
en arrière-plan. Le PID du leader reste ainsi réservé jusqu'au signal et ne peut
pas être recyclé vers un processus étranger.

Pour `terminate()`, les leaders terminés restent volontairement non récupérés
pendant toute la période de grâce : les descendants conservent ce délai pour
réagir à `SIGTERM`, puis le groupe reçoit `SIGKILL` avant la récupération finale.
Une étape qui crée volontairement une nouvelle session ou un nouveau groupe de
processus échappe à cette garantie POSIX.

## `close()`, GC et Lua `<close>`

```lua
ok, err = pipeline:close()
```

`close()` est idempotente. Elle ferme les descripteurs, tente `SIGTERM`, utilise
`SIGKILL` si nécessaire et récupère les enfants directs. Après fermeture, les
lectures et écritures renvoient `nil, "closed"`, et `is_running()` renvoie
`false`. Un statut déjà entièrement acquis reste accessible par `wait()`.

Le même nettoyage est appelé par `__gc` et `__close`. L'usage recommandé est :

```lua
local pipeline <close> = assert(babet.spawnPipeline({
    { "producteur" },
    { "consommateur" },
}))
```

Le GC constitue un filet de sécurité, pas un mécanisme de synchronisation :
utilisez `wait()`, `terminate()` ou `close()` explicitement lorsque le moment du
nettoyage compte.

## Erreurs de lancement et réutilisation

Les erreurs de validation, de pipe, de `fork`, de `chdir` ou d'`exec`, ainsi
qu'un `launch_timeout`, renvoient `nil, err`. Si une étape échoue pendant le lancement, toutes celles déjà créées
sont arrêtées et récupérées ; aucun objet partiellement valide n'est exposé.

Les erreurs non destructives `"timeout"` et `"interrupted"` autorisent un
nouvel appel. `"closed"` signifie que le flux ou l'objet concerné ne peut plus
servir pour cette opération. Une erreur système plus grave est renvoyée sous
forme de texte et doit être traitée comme telle.
