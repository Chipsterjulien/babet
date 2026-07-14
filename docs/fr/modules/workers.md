> [English](../../en/modules/workers.md) | **Français**

# WORKERS — threads OS, états Lua isolés et files de messages

`babet.workers` exécute du code Lua dans de vrais threads POSIX. Chaque worker
possède son propre `lua_State`, reçoit une copie sérialisée de ses arguments et
communique avec le parent par deux files de messages bornées.

Le module couvre :

- le lancement d'un chunk Lua dans un thread OS ;
- le passage d'une table d'arguments initiale ;
- la récupération bloquante ou non bloquante du premier résultat ;
- une inbox parent vers worker et une outbox worker vers parent ;
- des timeouts et une contre-pression par capacité de queue ;
- la fermeture coopérative d'un canal ;
- le chargement des modules Babet, bundlés et utilisateur dans chaque état ;
- l'isolation de la mémoire Lua entre les threads.

Il ne fournit pas de mémoire Lua partagée, de terminaison forcée, de timeout
sur `join()`, de pool global ni de canal direct worker vers worker.

## Table des matières du module

- [Conventions essentielles](#workers-conventions)
- [Vue d'ensemble de l'API](#workers-api-summary)
- [`spawn(code, args?, opts?)`](#workers-spawn)
  - [`code`](#workers-code)
  - [`args` et `worker.args`](#workers-args)
  - [Capacités des queues](#workers-capacities)
  - [Moment où `setenv` et `chdir` sont verrouillés](#workers-process-lock)
- [Valeurs transférables](#workers-transfer)
  - [Scalaires et chaînes](#workers-transfer-scalars)
  - [Tables listes et objets](#workers-transfer-tables)
  - [Valeurs refusées](#workers-transfer-rejected)
  - [Copies, identité et profondeur](#workers-transfer-copy)
- [Résultat final du worker](#workers-result)
  - [`join()` — attendre et consommer](#workers-join)
  - [`poll()` — tester et consommer](#workers-poll)
  - [Ne pas combiner `poll()` terminé puis `join()`](#workers-consumption)
- [Messages parent vers worker](#workers-parent-send)
- [Messages worker vers parent](#workers-parent-recv)
- [API `worker.send` et `worker.recv`](#workers-worker-side)
- [Timeouts et raisons d'échec](#workers-timeouts)
- [`close()` et cycle de vie des queues](#workers-close)
- [Chargement des modules et environnement du worker](#workers-state)
- [Exemples complets](#workers-examples)
  - [Calcul simple avec `join`](#workers-example-join)
  - [Arguments structurés](#workers-example-args)
  - [Suivi non bloquant avec `poll`](#workers-example-poll)
  - [Worker persistant requête/réponse](#workers-example-service)
  - [Envoyer et recevoir `nil`](#workers-example-nil)
  - [Fermeture puis drainage de l'outbox](#workers-example-drain)
  - [Contre-pression et timeout](#workers-example-backpressure)
  - [Annulation coopérative](#workers-example-cancel)
  - [Pool borné corrigé](#workers-example-pool)
- [Interblocages à éviter](#workers-deadlocks)
- [Contrat d'erreur](#workers-errors)
- [Garbage collector et destruction](#workers-gc)
- [Signaux, environnement et concurrence](#workers-concurrency)
- [Fonctionnalités absentes](#workers-not-provided)

<a id="workers-conventions"></a>
## Conventions essentielles

### Chaque worker possède un état Lua distinct

Une table, une globale ou un module modifié dans le parent n'est pas partagé
avec le worker. Les données traversent uniquement par sérialisation :

- `args` lors de `spawn` ;
- `job:send` et `worker.recv` ;
- `worker.send` et `job:recv` ;
- la première valeur retournée par le chunk.

Il n'existe donc pas de data race sur les objets Lua eux-mêmes. Les effets
externes — fichiers, sockets, bases de données, processus — restent en revanche
partagés au niveau du système et doivent être coordonnés par l'application.

### Les résultats utilisent une convention proche de `pcall`

`join()` renvoie :

```lua
true, valeur_metier
false, message_erreur
```

Cette convention permet au worker de retourner légitimement `nil` :

```lua
local ok, value = job:join()
if ok then
    -- value peut être nil.
else
    io.stderr:write(value, "\n")
end
```

Les méthodes de queue renvoient également un booléen en première position, ce
qui permet de transporter `nil` sans ambiguïté.

### Le résultat final est consommable une seule fois

Dès que `join()` récupère le résultat, ou que `poll()` renvoie `"done"` ou
`"error"`, ce résultat est consommé. Tout nouvel appel à `join()` ou `poll()`
renvoie un diagnostic `result already consumed`.

<a id="workers-api-summary"></a>
## Vue d'ensemble de l'API

### Côté parent

```lua
local job, err = babet.workers.spawn(code, args?, opts?)

local ok, value = job:join()
local state, value = job:poll()

local ok, err = job:send(value, timeout?)
local ok, value_or_err = job:recv(timeout?)
local ok, err = job:close()
```

| API | Résultat principal | Bloquante |
| --- | --- | --- |
| `spawn` | `job` ou `(nil, err)` | création seulement |
| `job:join()` | `(true, result)` ou `(false, err)` | oui, sans timeout |
| `job:poll()` | `("running", nil)`, `("done", result)` ou `("error", err)` | non |
| `job:send(v, t?)` | `(true, nil)`, `(false, reason)` ou `(nil, err)` | selon `t` |
| `job:recv(t?)` | `(true, value)` ou `(false, reason)` | selon `t` |
| `job:close()` | `(true, nil)` | non |

### Côté worker

Le chunk reçoit une table globale `worker` :

```lua
worker.args
worker.send(value, timeout?)
worker.recv(timeout?)
```

| API | Résultat |
| --- | --- |
| `worker.args` | copie de `args`, ou `nil` |
| `worker.send(v, t?)` | `(true, nil)` ou `(false, reason_or_error)` |
| `worker.recv(t?)` | `(true, value)` ou `(false, reason)` |

<a id="workers-spawn"></a>
## `spawn(code, args?, opts?)`

```lua
local job, err = babet.workers.spawn(code, args?, opts?)
```

En succès, `spawn` renvoie uniquement le userdata `job`. Le thread peut être
encore en cours, déjà terminé ou déjà en erreur au moment où le parent reçoit
ce userdata.

Les erreurs de chargement ou d'exécution du chunk ont lieu **dans** le worker :
`spawn` peut donc réussir, puis `join()` ou `poll()` rapporter l'erreur.

```lua
local job = assert(babet.workers.spawn("this is not valid Lua"))
local ok, err = job:join()
assert(not ok)
```

<a id="workers-code"></a>
### `code`

`code` est obligatoire et doit être une véritable chaîne Lua. Les nombres ne
sont pas convertis implicitement.

```lua
local job = assert(babet.workers.spawn([[
    return 6 * 7
]]))
```

Le code est chargé comme un chunk texte dans un nouvel état Lua. Il ne s'agit
pas d'une fonction capturant les upvalues du parent.

```lua
local factor = 3

-- factor n'existe pas dans le worker : il faut le transmettre dans args.
local job = assert(babet.workers.spawn([[
    return worker.args.value * worker.args.factor
]], {
    value = 14,
    factor = factor,
}))
```

Les octets NUL présents dans `code` ne sont pas tronqués par le binding, mais
un NUL rend normalement le chunk invalide pour le parseur Lua. Utilise une
chaîne source Lua ordinaire.

<a id="workers-args"></a>
### `args` et `worker.args`

`args` est facultatif. Il doit être une table ou `nil`.

```lua
local job = assert(babet.workers.spawn([[
    return worker.args.left + worker.args.right
]], {
    left = 20,
    right = 22,
}))
```

Dans le worker :

- `worker.args` contient une copie désérialisée de la table ;
- sans `args`, `worker.args == nil` ;
- modifier `worker.args` ne modifie jamais la table du parent ;
- les métatables et l'identité des sous-tables ne traversent pas.

Un scalaire direct n'est pas accepté comme deuxième argument :

```lua
babet.workers.spawn("return worker.args", 42) -- erreur Lua levée
```

Emballe-le dans une table :

```lua
babet.workers.spawn("return worker.args.value", { value = 42 })
```

<a id="workers-capacities"></a>
### Capacités des queues

`opts` peut définir :

```lua
{
    inbox_capacity = 64,
    outbox_capacity = 64,
}
```

- `inbox_capacity` : nombre maximal de messages parent vers worker ;
- `outbox_capacity` : nombre maximal de messages worker vers parent ;
- défaut : 64 messages pour chaque queue ;
- plage autorisée : entier de `1` à `1 000 000` ;
- la valeur doit être un vrai nombre Lua, pas la chaîne `"64"` ;
- la taille porte sur le **nombre de messages**, pas sur leur taille en octets.

```lua
local job = assert(babet.workers.spawn(code, nil, {
    inbox_capacity = 8,
    outbox_capacity = 32,
}))
```

Une capacité plus grande consomme potentiellement davantage de mémoire et ne
remplace pas une stratégie de drainage. Une petite capacité applique une
contre-pression plus tôt.

Les champs inconnus de `opts` sont actuellement ignorés.

<a id="workers-process-lock"></a>
### Moment où `setenv` et `chdir` sont verrouillés

Après validation des types et capacités, le premier appel à `spawn` marque le
processus comme ayant utilisé les workers. À partir de cet instant :

- `babet.setenv(...)` est définitivement refusé ;
- `babet.chdir(...)` est définitivement refusé ;
- la restriction reste active après `join()` ;
- elle reste active même si la sérialisation de `args`, l'initialisation des
  queues ou `pthread_create` échoue ensuite.

Un appel rejeté **avant** ce marquage — par exemple `spawn(42)` ou une capacité
non entière — ne verrouille pas l'environnement.

Configure donc le répertoire courant et l'environnement avant le premier
worker.

<a id="workers-transfer"></a>
## Valeurs transférables

Le format de transport interne est JSON. Les mêmes règles s'appliquent à :

- `args` ;
- les messages dans les deux sens ;
- la première valeur de retour du worker.

<a id="workers-transfer-scalars"></a>
### Scalaires et chaînes

| Valeur Lua | Transférable | Remarque |
| --- | --- | --- |
| `nil` | oui | devient JSON `null`, puis redevient `nil` |
| booléen | oui | identité préservée |
| entier | oui | redevient normalement un entier Lua |
| nombre flottant fini | oui | `NaN`, `+Inf` et `-Inf` refusés |
| string texte | oui | doit passer le validateur UTF-8 et ne contenir aucun NUL |

Contrairement à plusieurs APIs de fichiers ou de sockets, les messages workers
ne sont **pas binary-safe**. Une chaîne contenant `\0` ou des octets non
acceptés comme UTF-8 est refusée.

<a id="workers-transfer-tables"></a>
### Tables listes et objets

Une table est transférable sous l'une de ces deux formes.

#### Liste dense non vide

```lua
{ "a", "b", "c" }
```

Toutes les clés doivent être les entiers consécutifs `1..n`, sans trou ni
autre clé.

#### Objet à clés string

```lua
{
    name = "alice",
    age = 30,
}
```

Toutes les clés doivent être des strings acceptées par le validateur de texte.

Une table vide est sérialisée comme un **objet vide** `{}`, pas comme un array
vide. Il n'existe pas de marqueur équivalent à `babet.json.empty_array` dans le
transport workers.

Les tables mixtes ou creuses sont refusées :

```lua
{ [1] = "a", [3] = "c" }      -- trou
{ [1] = "a", label = "x" }   -- liste + map
{ [0] = "zero" }              -- clé numérique hors 1..n
```

<a id="workers-transfer-rejected"></a>
### Valeurs refusées

Ne traversent pas les états Lua :

- fonctions et closures ;
- userdata : socket, statement SQLite, watcher, job, fichier, etc. ;
- coroutines/threads Lua ;
- tables cycliques ;
- tables mixtes ou creuses ;
- clés non string dans une table objet ;
- nombres `NaN` ou infinis ;
- chaînes avec NUL ou octets non acceptés comme UTF-8 ;
- structures imbriquées au-delà de la limite.

Un chemin, une URL ou une configuration sérialisable doit être transmis à la
place de l'objet système lui-même. Le worker ouvre ensuite sa propre ressource.

```lua
-- Incorrect : socket est un userdata.
babet.workers.spawn(code, { socket = peer })

-- Correct : transmettre les paramètres de connexion.
babet.workers.spawn(code, {
    host = "127.0.0.1",
    port = 9000,
})
```

<a id="workers-transfer-copy"></a>
### Copies, identité et profondeur

Le transport crée une copie par valeur :

- aucune référence Lua n'est partagée ;
- les métatables sont perdues ;
- deux références vers la même sous-table deviennent deux tables séparées ;
- les cycles sont refusés ;
- la profondeur maximale est de 32 niveaux selon le compteur interne de
  sérialisation.

```lua
local shared = { value = 1 }
local args = { a = shared, b = shared }

-- Dans le worker, worker.args.a et worker.args.b ont le même contenu,
-- mais ne sont pas la même table.
```

La limite protège les piles C++ et Lua contre des structures pathologiques.

<a id="workers-result"></a>
## Résultat final du worker

Quand le chunk termine normalement, seule sa **première** valeur de retour est
sérialisée.

```lua
return "first", "second", "third"
```

Le parent reçoit uniquement `"first"`.

Pour transporter plusieurs résultats, utilise une table :

```lua
return {
    value = 42,
    elapsed = 0.12,
}
```

Sans `return`, ou avec `return nil`, le résultat métier est `nil`.

Une erreur Lua non attrapée devient l'état `error`. Le texte transmis est un
diagnostic, mais Babet n'ajoute pas automatiquement de traceback. Le worker
peut utiliser `xpcall(..., debug.traceback)` s'il souhaite en construire un.

<a id="workers-join"></a>
### `join()` — attendre et consommer

```lua
local ok, value = job:join()
```

`join()` :

- attend sans timeout la fin de la pthread ;
- ne ferme aucune queue avant d'attendre ;
- consomme définitivement le résultat ;
- renvoie `(true, value)` en terminaison normale ;
- renvoie `(false, err)` en erreur Lua, erreur interne ou résultat invalide.

```lua
local ok, value = job:join()
if ok then
    print("résultat", value)
else
    io.stderr:write("worker: ", value, "\n")
end
```

Même lorsqu'il renvoie `nil`, un succès reste reconnaissable : `ok == true`.

<a id="workers-poll"></a>
### `poll()` — tester et consommer

```lua
local state, value = job:poll()
```

| `state` | `value` | Consommé |
| --- | --- | --- |
| `"running"` | `nil` | non |
| `"done"` | résultat, éventuellement `nil` | oui |
| `"error"` | message | oui |

```lua
while true do
    local state, value = job:poll()
    if state == "running" then
        babet.sleep(10, "ms")
    elseif state == "done" then
        print("terminé", value)
        break
    else
        io.stderr:write("worker: ", value, "\n")
        break
    end
end
```

Lorsque l'état n'est plus `running`, `poll()` rejoint rapidement la pthread
déjà terminée et consomme son résultat.

<a id="workers-consumption"></a>
### Ne pas combiner `poll()` terminé puis `join()`

Cette séquence est incorrecte :

```lua
local state = job:poll()
if state ~= "running" then
    local ok, result = job:join() -- résultat déjà consommé
end
```

Utilise directement les deux valeurs de `poll()` :

```lua
local state, value = job:poll()
if state == "done" then
    use_result(value)
elseif state == "error" then
    report_error(value)
end
```

Ou utilise `poll()` uniquement tant qu'il renvoie `running`, puis choisis une
architecture dans laquelle un autre mécanisme indique qu'il faut appeler
`join()` sans avoir consommé le résultat. Dans la plupart des boucles, utiliser
`poll()` jusqu'au résultat final est plus simple.

<a id="workers-parent-send"></a>
## Messages parent vers worker

```lua
local ok, err = job:send(value, timeout?)
```

`job:send` sérialise `value`, puis l'ajoute à l'inbox du worker en FIFO.

Résultats :

- `(true, nil)` : message accepté ;
- `(false, "full")` : queue pleine avec timeout `0` ;
- `(false, "timeout")` : queue restée pleine jusqu'à l'échéance ;
- `(false, "closed")` : inbox fermée ;
- `(nil, err)` : valeur non sérialisable ou erreur interne de sérialisation.

```lua
local ok, err = job:send({ command = "scan", path = "/tmp" }, 1)
if not ok then
    io.stderr:write("send: ", err, "\n")
end
```

Le succès signifie seulement que le message est en queue, pas que le worker l'a
déjà traité.

<a id="workers-parent-recv"></a>
## Messages worker vers parent

```lua
local ok, value_or_err = job:recv(timeout?)
```

`job:recv` retire le plus ancien message de l'outbox.

Résultats :

- `(true, value)` : message reçu ; `value` peut être `nil` ;
- `(false, "empty")` : queue vide avec timeout `0` ;
- `(false, "timeout")` : aucun message avant l'échéance ;
- `(false, "closed")` : queue fermée et entièrement drainée.

Lorsqu'une queue est fermée mais contient encore des messages, ceux-ci sont
rendus avant `"closed"`.

```lua
while true do
    local ok, message = job:recv(0)
    if ok then
        process(message)
    elseif message == "empty" then
        break
    elseif message == "closed" then
        break
    else
        error(message)
    end
end
```

<a id="workers-worker-side"></a>
## API `worker.send` et `worker.recv`

Dans le chunk :

```lua
local ok, message_or_err = worker.recv(timeout?)
local ok, err = worker.send(value, timeout?)
```

`worker.recv` lit l'inbox alimentée par `job:send`. `worker.send` écrit dans
l'outbox lue par `job:recv`.

Les règles FIFO, capacités, timeouts et fermeture sont symétriques.

Différence de convention sur une erreur de sérialisation :

- `job:send` renvoie `(nil, err)` ;
- `worker.send` renvoie `(false, err)`.

Cette différence conserve la convention booléenne du code worker.

```lua
local job = assert(babet.workers.spawn([[
    while true do
        local ok, message = worker.recv()
        if not ok then
            return "inbox closed"
        end

        local sent, err = worker.send({ echo = message })
        if not sent then
            return { send_error = err }
        end
    end
]]))
```

<a id="workers-timeouts"></a>
## Timeouts et raisons d'échec

Les quatre méthodes de messages partagent le même contrat :

| `timeout` Lua | Comportement |
| --- | --- |
| absent ou `nil` | attente indéfinie |
| `0` | tentative immédiate, non bloquante |
| `0 < t <= 86400` | attente d'au plus `t` secondes |
| négatif, NaN, Inf ou `> 86400` | erreur Lua levée |
| autre type, y compris `"1"` | erreur Lua levée |

La résolution interne est la milliseconde. Une durée strictement positive est
arrondie vers le haut : `0.0005` seconde attend au moins 1 ms et n'est pas
transformé en mode non bloquant.

Les raisons de queue sont :

| Raison | Signification |
| --- | --- |
| `"full"` | envoi immédiat, queue pleine |
| `"empty"` | réception immédiate, queue vide |
| `"timeout"` | échéance positive atteinte |
| `"closed"` | envoi sur queue fermée, ou réception sur queue fermée et vide |

Des diagnostics internes comme `"out of memory"` ou `"internal mutex error"`
peuvent exceptionnellement apparaître à la place.

<a id="workers-close"></a>
## `close()` et cycle de vie des queues

```lua
local ok, err = job:close()
```

`job:close()` :

- ferme uniquement l'**inbox** parent vers worker ;
- est idempotent ;
- renvoie `(true, nil)` ;
- débloque un `worker.recv()` en attente, qui obtient `(false, "closed")` une
  fois les messages déjà présents drainés ;
- rend les futurs `job:send()` impossibles avec `(false, "closed")` ;
- laisse l'outbox ouverte afin que le parent puisse encore recevoir les
  derniers messages du worker.

Il ne termine pas de force le thread et ne consomme pas son résultat final.

Le worker ferme automatiquement **les deux** queues lorsqu'il termine, en
succès ou en erreur. Le parent peut néanmoins drainer les messages déjà placés
dans l'outbox avant de recevoir `"closed"`.

Pour demander proprement à un worker qui attend des commandes de finir :

```lua
assert(job:close())
local ok, result = job:join()
```

Le worker doit traiter `worker.recv() == false, "closed"` comme une condition de
sortie.

<a id="workers-state"></a>
## Chargement des modules et environnement du worker

Chaque thread crée un nouvel état Lua et :

- ouvre les bibliothèques standard Lua ;
- enregistre le namespace complet `babet` ;
- expose les modules bundlés via `require` ;
- configure le chargement des modules utilisateur de la même manière que le
  projet parent, en mode dossier ou embarqué ;
- expose `worker.args`, `worker.send` et `worker.recv` ;
- ne copie pas la table globale `arg` du parent : `arg == nil` dans le worker.

```lua
local job = assert(babet.workers.spawn([[
    local inspect = require("inspect")
    local mymod = require("mymod")
    return inspect({ answer = mymod.answer() })
]]))
```

Les états Lua sont isolés, mais les threads appartiennent au même processus :

- même PID ;
- même répertoire courant process-wide ;
- même environnement process-wide ;
- même système de fichiers et mêmes ressources externes accessibles ;
- compte mémoire Lua mesuré séparément dans chaque état.

Babet interdit les mutations de cwd et d'environnement après le premier
`spawn`, ce qui stabilise ces deux états globaux.

<a id="workers-examples"></a>
## Exemples complets

<a id="workers-example-join"></a>
### Calcul simple avec `join`

```lua
local job, err = babet.workers.spawn([[
    return 21 * 2
]])
assert(job, err)

local ok, result = job:join()
assert(ok, result)
print(result) -- 42
```

<a id="workers-example-args"></a>
### Arguments structurés

```lua
local job = assert(babet.workers.spawn([[
    local total = 0
    for _, value in ipairs(worker.args.values) do
        total = total + value
    end
    return {
        name = worker.args.name,
        total = total,
    }
]], {
    name = "batch A",
    values = { 10, 20, 12 },
}))

local ok, result = job:join()
assert(ok, result)
print(result.name, result.total)
```

<a id="workers-example-poll"></a>
### Suivi non bloquant avec `poll`

```lua
local job = assert(babet.workers.spawn([[
    babet.sleep(200, "ms")
    return "ready"
]]))

while true do
    local state, value = job:poll()

    if state == "running" then
        update_ui()
        babet.sleep(10, "ms")
    elseif state == "done" then
        print(value)
        break
    else
        error(value)
    end
end
```

Il ne faut pas appeler `join()` après la branche `done` ou `error` : le résultat
a déjà été consommé par `poll()`.

<a id="workers-example-service"></a>
### Worker persistant requête/réponse

```lua
local job = assert(babet.workers.spawn([[
    while true do
        local ok, request = worker.recv()
        if not ok then
            return "parent closed inbox"
        end

        if request.op == "stop" then
            return "stopped"
        elseif request.op == "square" then
            local sent, err = worker.send({
                id = request.id,
                value = request.value * request.value,
            })
            if not sent then
                return { error = err }
            end
        end
    end
]], nil, {
    inbox_capacity = 16,
    outbox_capacity = 16,
}))

for i = 1, 5 do
    assert(job:send({ id = i, op = "square", value = i }))
end

for _ = 1, 5 do
    local ok, response = job:recv(2)
    assert(ok, response)
    print(response.id, response.value)
end

assert(job:send({ op = "stop" }))
local ok, result = job:join()
assert(ok, result)
print(result)
```

<a id="workers-example-nil"></a>
### Envoyer et recevoir `nil`

Le booléen de statut distingue un vrai message `nil` d'une queue vide.

```lua
local job = assert(babet.workers.spawn([[
    local ok, value = worker.recv()
    assert(ok)
    assert(value == nil)

    assert(worker.send(nil))
    return "done"
]]))

assert(job:send(nil))

local got, value = job:recv()
assert(got == true)
assert(value == nil)

local ok, result = job:join()
assert(ok and result == "done")
```

<a id="workers-example-drain"></a>
### Fermeture puis drainage de l'outbox

```lua
local job = assert(babet.workers.spawn([[
    assert(worker.send("ready"))

    local ok, reason = worker.recv()
    assert(not ok and reason == "closed")

    assert(worker.send("closing"))
    return "finished"
]]))

local ok, first = job:recv(1)
assert(ok and first == "ready")

assert(job:close()) -- ferme seulement l'inbox

local got, last = job:recv(1)
assert(got and last == "closing")

local joined, result = job:join()
assert(joined and result == "finished")
```

<a id="workers-example-backpressure"></a>
### Contre-pression et timeout

```lua
local job = assert(babet.workers.spawn([[
    babet.sleep(500, "ms")
    while true do
        local ok, message = worker.recv()
        if not ok then return "closed" end
        if message == "stop" then return "done" end
    end
]], nil, {
    inbox_capacity = 2,
}))

assert(job:send("one", 0))
assert(job:send("two", 0))

local ok, reason = job:send("three", 0)
assert(ok == false and reason == "full")

local waited, why = job:send("three", 0.1)
assert(waited == false and why == "timeout")

job:close()
job:join()
```

<a id="workers-example-cancel"></a>
### Annulation coopérative

Il n'existe pas de `job:cancel()`. Le parent envoie une commande, et le worker
la vérifie périodiquement.

```lua
local job = assert(babet.workers.spawn([[
    local total = 0

    for i = 1, worker.args.limit do
        total = total + expensive_step(i)

        if i % 1000 == 0 then
            local ok, message = worker.recv(0)
            if ok and message == "stop" then
                return {
                    cancelled = true,
                    partial = total,
                }
            elseif not ok and message == "closed" then
                return {
                    cancelled = true,
                    partial = total,
                }
            end
        end
    end

    return { cancelled = false, total = total }
]], { limit = 1000000 }))

-- Plus tard :
local sent, err = job:send("stop", 0.5)
if not sent then
    io.stderr:write("cancel: ", err, "\n")
end

local ok, result = job:join()
assert(ok, result)
```

L'annulation reste coopérative : un worker bloqué dans un appel non interruptible
ou qui ne consulte jamais sa queue ne s'arrête pas sur ce message.

<a id="workers-example-pool"></a>
### Pool borné corrigé

Cette boucle limite le nombre de pthreads simultanées et utilise directement le
résultat de `poll()` sans appeler ensuite `join()`.

```lua
local function map_parallel(items, code, max_concurrent)
    max_concurrent = max_concurrent or 4

    local next_index = 1
    local active = {}
    local results = {}

    while next_index <= #items or #active > 0 do
        while next_index <= #items and #active < max_concurrent do
            local job, err = babet.workers.spawn(code, {
                item = items[next_index],
            })
            assert(job, err)

            active[#active + 1] = {
                index = next_index,
                job = job,
            }
            next_index = next_index + 1
        end

        for i = #active, 1, -1 do
            local entry = active[i]
            local state, value = entry.job:poll()

            if state == "done" then
                results[entry.index] = value
                table.remove(active, i)
            elseif state == "error" then
                results[entry.index] = { error = value }
                table.remove(active, i)
            end
        end

        if #active > 0 then
            babet.sleep(10, "ms")
        end
    end

    return results
end
```

Chaque `spawn` crée tout de même un nouveau thread et un nouvel état Lua. Ce
pattern borne la concurrence ; il ne réutilise pas des workers persistants.

<a id="workers-deadlocks"></a>
## Interblocages à éviter

### Worker en attente de l'inbox, parent dans `join()`

```lua
-- Worker
local ok, message = worker.recv() -- attend indéfiniment

-- Parent
job:join() -- attend le worker
```

Les deux côtés s'attendent. Ferme d'abord l'inbox ou envoie une commande :

```lua
job:close()
job:join()
```

### Worker bloqué sur une outbox pleine

Si le worker utilise `worker.send()` sans timeout, que l'outbox est pleine et
que le parent appelle `join()` sans la drainer, aucun côté ne peut progresser.

Solutions :

- le parent lit régulièrement `job:recv()` ;
- le worker utilise un timeout fini ;
- l'outbox possède une capacité adaptée ;
- le protocole sépare clairement la phase de messages et la phase de join.

### Oublier que `poll()` consomme

Un code qui attend `poll() ~= "running"`, puis appelle `join()`, ne se bloque
pas mais perd le vrai résultat au profit de `already consumed`. Utilise les
deux valeurs de `poll()`.

### GC potentiellement bloquant

Abandonner la dernière référence à un worker encore actif peut déclencher un
`__gc` qui ferme les queues puis attend le thread. Le GC débloque les attentes
de queue, mais ne peut pas interrompre un calcul infini ou un syscall externe
non borné.

<a id="workers-errors"></a>
## Contrat d'erreur

### Erreurs Lua levées par mauvais usage

Sont notamment levés :

- `code` absent ou non string ;
- `args` non table et non `nil` ;
- `opts` non table et non `nil` ;
- capacités non numériques, non entières, hors `1..1 000 000` ;
- timeout non numérique, négatif, non fini ou supérieur à 86 400 secondes ;
- appel d'une méthode sur un objet qui n'est pas un job.

```lua
local ok, err = pcall(function()
    babet.workers.spawn(42)
end)
assert(not ok)
```

### Échecs renvoyés par `spawn`

`spawn` renvoie `(nil, err)` pour les erreurs d'exécution rencontrées avant ou
pendant la création :

- `args` non transférables ;
- échec de sérialisation JSON ;
- initialisation d'une queue impossible ;
- échec de `pthread_create`.

```lua
local job, err = babet.workers.spawn("return 1", {
    fn = function() end,
})
assert(job == nil)
```

### Erreurs finales du worker

`join()` renvoie `(false, err)` et `poll()` renvoie `("error", err)` pour :

- syntaxe Lua invalide ;
- erreur Lua non attrapée ;
- valeur de retour non transférable ;
- exception C++ interne interceptée ;
- corruption ou erreur interne lors de la désérialisation.

Le diagnostic ne contient pas automatiquement de traceback complet.

### Sérialisation des messages

- `job:send` : `(nil, err)` si la valeur ne peut pas être sérialisée ;
- `worker.send` : `(false, err)` pour la même situation ;
- `recv` : `(false, err)` sur une anomalie interne de désérialisation.

<a id="workers-gc"></a>
## Garbage collector et destruction

Le userdata possède un `__gc` de sécurité. Lorsqu'il est collecté :

1. l'inbox et l'outbox sont fermées ;
2. les attentes de queue sont réveillées ;
3. Babet appelle `pthread_join` si nécessaire ;
4. les primitives pthread et les chaînes internes sont détruites.

Cette séquence évite de libérer un état encore utilisé par un thread. Elle peut
toutefois bloquer si le worker ne peut pas terminer.

Ne compte pas sur le GC comme mécanisme normal de synchronisation. Conserve le
job, termine le protocole, puis appelle `join()` ou consomme le résultat avec
`poll()`.

`tostring(job)` renvoie une indication comme :

```text
Worker(running)
Worker(done)
Worker(error)
```

Cette chaîne reflète l'état interne instantané, pas le fait que le résultat a
déjà été consommé.

<a id="workers-concurrency"></a>
## Signaux, environnement et concurrence

### Signaux

Les six signaux gérés par `babet.signal` sont bloqués dans chaque pthread
worker. `babet.signal.handle`, `ignore` et `default` lèvent une erreur dans un
worker. Le thread principal reste le seul propriétaire des callbacks POSIX.

### Environnement et cwd

`setenv` et `chdir` modifient un état process-wide qui ne peut pas être muté en
sécurité pendant que d'autres threads l'utilisent. Babet les interdit donc
après le premier `spawn`.

### Ressources externes

Deux workers peuvent ouvrir des fichiers, bases SQLite ou sockets distincts.
Lorsqu'ils ciblent la même ressource externe, la sérialisation workers ne
fournit aucun verrou automatique.

Pour SQLite, chaque worker doit ouvrir sa propre connexion. `wal = true` et un
`busy_timeout` adapté peuvent améliorer la concurrence, mais ne remplacent pas
la conception correcte des transactions.

### Coût

Chaque `spawn` crée :

- une pthread ;
- un état Lua complet ;
- les modules Babet ;
- deux queues et leurs buffers ;
- des copies JSON des données transférées.

Évite de créer un worker pour une opération minuscule. Regroupe le travail ou
utilise quelques workers persistants lorsque le protocole le permet.

<a id="workers-not-provided"></a>
## Fonctionnalités absentes

Le module ne fournit pas actuellement :

- `job:join(timeout)` ;
- `job:cancel()` ou une terminaison forcée ;
- `worker.cancelled()` ;
- `job:done()` — utilise `poll()` ;
- `babet.workers.cpu_count()` ;
- un pool global réutilisable ;
- des canaux directs worker vers worker ;
- de la mémoire Lua partagée ;
- le transfert de fonctions, userdata ou coroutines ;
- un format binaire pour les messages ;
- le transfert automatique de plusieurs valeurs de retour.

Une annulation coopérative et un pool borné peuvent être construits en Lua avec
les exemples de cette page. Pour le nombre de CPU, un programme externe peut
être interrogé avec `babet.exec("nproc")`, en vérifiant sa table de résultat.
