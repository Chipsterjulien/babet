> [English](../../en/modules/workers.md) | **Français**

# WORKERS — threads OS, états Lua isolés, queues et channels

`babet.workers` exécute du code Lua dans de vrais threads POSIX. Chaque worker
possède son propre `lua_State`, reçoit une copie sérialisée de ses arguments et
communique avec le parent par deux files de messages bornées. Des channels
partagés peuvent également relier directement le parent et plusieurs workers,
ou plusieurs workers entre eux, sans retransiter par l'inbox/outbox du parent.

Le module couvre :

- le lancement d'un chunk Lua dans un thread OS ;
- le passage d'une table d'arguments initiale ;
- la récupération bloquante ou non bloquante du premier résultat ;
- une inbox parent vers worker et une outbox worker vers parent ;
- des channels directs, bornés, FIFO, multi-producteurs et
  multi-consommateurs ;
- des timeouts et une contre-pression par capacité de queue ;
- la fermeture avec drainage et le réveil des appels bloqués ;
- le chargement des modules Babet, bundlés et utilisateur dans chaque état ;
- l'isolation de la mémoire Lua entre les threads ;
- un pool borné de workers persistants qui réutilise les pthreads et les
  états Lua entre plusieurs tâches.

Il ne fournit pas de mémoire Lua partagée, de terminaison forcée ni de channels
entre processus OS distincts. L'annulation disponible est strictement
coopérative.

## Table des matières du module

- [Conventions essentielles](#workers-conventions)
- [Vue d'ensemble de l'API](#workers-api-summary)
- [`spawn(code, args?, opts?)`](#workers-spawn)
  - [`code`](#workers-code)
  - [`args` et `worker.args`](#workers-args)
  - [Capacités des queues](#workers-capacities)
  - [Transmission de channels par `opts.channels`](#workers-spawn-channels)
  - [Moment où `setenv` et `chdir` sont verrouillés](#workers-process-lock)
- [Valeurs transférables](#workers-transfer)
  - [Scalaires et chaînes](#workers-transfer-scalars)
  - [Tables listes et objets](#workers-transfer-tables)
  - [Valeurs refusées](#workers-transfer-rejected)
  - [Copies, identité, profondeur et budgets](#workers-transfer-copy)
- [Résultat final du worker](#workers-result)
  - [`status()` — observer sans consommer](#workers-status)
  - [`done()` — test booléen non consommant](#workers-done)
  - [`join(timeout?)` — attendre et consommer](#workers-join)
  - [`poll()` — tester et consommer](#workers-poll)
  - [Ne pas combiner `poll()` terminé puis `join()`](#workers-consumption)
- [Messages parent vers worker](#workers-parent-send)
- [Messages worker vers parent](#workers-parent-recv)
- [API `worker.send`, `worker.recv` et `worker.cancelled`](#workers-worker-side)
- [Channels directs partagés](#workers-channels)
  - [Créer un channel et choisir sa capacité](#workers-channel-create)
  - [`send` et `recv`](#workers-channel-send-recv)
  - [`close` et `is_closed`](#workers-channel-close)
  - [Concurrence, ordre et durée de vie](#workers-channel-lifetime)
- [Timeouts et raisons d'échec](#workers-timeouts)
- [`close()` et cycle de vie des queues](#workers-close)
- [`cancel()` et annulation coopérative](#workers-cancel)
- [Chargement des modules et environnement du worker](#workers-state)
- [Nombre de CPU disponibles](#workers-cpu-count)
- [Pool borné réutilisable](#workers-pool)
  - [Création et options](#workers-pool-create)
  - [Soumission et tâches](#workers-pool-submit)
  - [Isolation et réutilisation des états](#workers-pool-isolation)
  - [Contre-pression et timeouts](#workers-pool-backpressure)
  - [Fermeture, annulation et join](#workers-pool-lifecycle)
  - [Channels partagés dans les tâches](#workers-pool-channels)
- [Exemples complets](#workers-examples)
  - [Calcul simple avec `join`](#workers-example-join)
  - [Arguments structurés](#workers-example-args)
  - [Suivi non bloquant avec `poll`](#workers-example-poll)
  - [Worker persistant requête/réponse](#workers-example-service)
  - [Envoyer et recevoir `nil`](#workers-example-nil)
  - [Fermeture puis drainage de l'outbox](#workers-example-drain)
  - [Contre-pression et timeout](#workers-example-backpressure)
  - [Parent vers worker avec un channel](#workers-example-channel-parent-worker)
  - [Worker vers worker sans relais du parent](#workers-example-channel-worker-worker)
  - [Plusieurs producteurs et consommateurs](#workers-example-channel-mpmc)
  - [Annulation coopérative](#workers-example-cancel)
  - [Pool natif pour plusieurs tâches](#workers-example-pool)
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
- les méthodes `send` et `recv` d'un channel partagé ;
- la première valeur retournée par le chunk.

Il n'existe donc pas de data race sur les objets Lua eux-mêmes. Les effets
externes — fichiers, sockets, bases de données, processus — restent en revanche
partagés au niveau du système et doivent être coordonnés par l'application.

### Les résultats utilisent une convention proche de `pcall`

`join(timeout?)` renvoie :

```lua
true, valeur_metier
false, message_erreur
nil, "timeout"
```

Le troisième état signifie uniquement que le worker est encore actif. Le
résultat n'est alors ni rejoint ni consommé.

Cette convention permet au worker de retourner légitimement `nil` :

```lua
local ok, value = job:join(0.5)
if ok == true then
    -- value peut être nil.
elseif ok == false then
    io.stderr:write(value, "\n")
else
    assert(value == "timeout")
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
local channel, err = babet.workers.channel(opts?)
local cpu_count = babet.workers.cpu_count()
local pool, err = babet.workers.pool(opts?)

local state = job:status()
local finished = job:done()
local ok, value_or_reason = job:join(timeout?)
local state, value = job:poll()
local ok, err = job:cancel()

local ok, err = job:send(value, timeout?)
local ok, value_or_err = job:recv(timeout?)
local ok, err = job:close()

local ok, err = channel:send(value, timeout?)
local ok, value_or_reason = channel:recv(timeout?)
local ok, err = channel:close()
local closed = channel:is_closed()
```

| API | Résultat principal | Bloquante |
| --- | --- | --- |
| `spawn` | `job` ou `(nil, err)` | création seulement |
| `job:status()` | `"running"`, `"done"` ou `"error"` | non, ne consomme jamais |
| `job:done()` | booléen | non, ne consomme jamais |
| `job:join(t?)` | `(true, result)`, `(false, err)` ou `(nil, "timeout")` | selon `t` |
| `job:poll()` | `("running", nil)`, `("done", result)` ou `("error", err)` | non |
| `job:cancel()` | `(true, nil)` | non |
| `job:send(v, t?)` | `(true, nil)`, `(false, reason)` ou `(nil, err)` | selon `t` |
| `job:recv(t?)` | `(true, value)` ou `(false, reason)` | selon `t` |
| `job:close()` | `(true, nil)` | non |
| `workers.channel(opts?)` | `channel` ou `(nil, err)` | création seulement |
| `channel:send(v, t?)` | `(true, nil)`, `(false, reason)` ou `(nil, err)` | selon `t` |
| `channel:recv(t?)` | `(true, value)`, `(false, reason)` ou `(nil, err)` | selon `t` |
| `channel:close()` | `(true, nil)` | non |
| `channel:is_closed()` | booléen | non |
| `workers.cpu_count()` | entier positif | non |
| `workers.pool(opts?)` | `pool` ou `(nil, err)` | crée les workers persistants |
| `pool:submit(code, args?, t?)` | `task` ou `(nil, reason)` | selon `t` |
| `task:done()` | booléen | non, ne consomme jamais |
| `task:status()` | `"running"`, `"done"` ou `"error"` | non |
| `task:join(t?)` | `(true, result)`, `(false, err)` ou `(nil, "timeout")` | selon `t` |
| `task:poll()` | `("running", nil)`, `("done", result)` ou `("error", err)` | non |
| `pool:close(t?)` | `(true, nil)` ou `(false, reason)` | selon `t` |
| `pool:cancel()` | `(true, nil)` | non ; annulation coopérative |
| `pool:join(t?)` | `(true, nil)`, `(false, err)` ou `(nil, "timeout")` | selon `t` |
| `pool:stats()` | `(table, nil)` ou `(nil, err)` | non |

### Côté worker

Le chunk reçoit une table globale `worker` :

```lua
worker.args
worker.channels
worker.send(value, timeout?)
worker.recv(timeout?)
worker.cancelled()
```

| API | Résultat |
| --- | --- |
| `worker.args` | copie de `args`, ou `nil` |
| `worker.channels` | table des handles transmis par `opts.channels` |
| `worker.send(v, t?)` | `(true, nil)` ou `(false, reason_or_error)` |
| `worker.recv(t?)` | `(true, value)` ou `(false, reason)` |
| `worker.cancelled()` | booléen, sans effet de bord |

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
- les métatables et l'identité des sous-tables ne traversent pas ;
- la sérialisation lit les entrées brutes et n'invoque ni `__len` ni `__index`.

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
- la valeur doit être un véritable entier Lua ; la chaîne `"64"` et le flottant `64.0` sont refusés ;
- la taille porte sur le **nombre de messages**, pas sur leur taille en octets.

```lua
local job = assert(babet.workers.spawn(code, nil, {
    inbox_capacity = 8,
    outbox_capacity = 32,
}))
```

Toute clé inconnue de `opts` est refusée par une erreur Lua. Cela détecte
immédiatement les fautes de frappe :

```lua
babet.workers.spawn("return 1", nil, {
    inbox_capcity = 16, -- erreur : option inconnue
})
```

Les noms d'options doivent être de vraies chaînes sans suffixe NUL caché ; les
clés numériques sont également refusées.

Une capacité plus grande consomme potentiellement davantage de mémoire et ne
remplace pas une stratégie de drainage. Une petite capacité applique une
contre-pression plus tôt.

<a id="workers-spawn-channels"></a>
### Transmission de channels par `opts.channels`

Un channel est une ressource partagée spéciale. Il ne traverse jamais la
sérialisation JSON de `worker.args` et ne peut pas être envoyé comme un message.
Il doit être transmis explicitement dans le champ `channels` :

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
local results = assert(babet.workers.channel({ capacity = 16 }))

local job = assert(babet.workers.spawn([[
    local ok, task = worker.channels.tasks:recv(2)
    if not ok then return task end

    assert(worker.channels.results:send({
        id = task.id,
        result = task.value * 2,
    }, 2))

    return true
]], nil, {
    channels = {
        tasks = tasks,
        results = results,
    },
}))
```

Dans le nouvel état Lua :

- `worker.channels` existe toujours et vaut une table vide si aucun channel
  n'a été transmis ;
- chaque clé de `opts.channels` devient un champ de `worker.channels` ;
- plusieurs noms peuvent référencer le même channel ;
- le parent et tous les workers reçoivent des userdata distincts qui pointent
  vers la même queue C++ ;
- les noms doivent être des chaînes UTF-8 non vides et sans octet NUL ;
- chaque valeur doit être un channel créé par `babet.workers.channel()`.

Exemple avec le même channel sous deux noms :

```lua
local shared = assert(babet.workers.channel())

local job = assert(babet.workers.spawn([[
    assert(worker.channels.output:send("hello"))
    local ok, value = worker.channels.input:recv()
    return ok and value
]], nil, {
    channels = {
        input = shared,
        output = shared,
    },
}))
```

Un channel placé dans `args` reste un userdata non sérialisable et est refusé :

```lua
local channel = assert(babet.workers.channel())

local job, err = babet.workers.spawn("return true", {
    channel = channel,
})

assert(job == nil)
assert(err:find("userdata", 1, true))
```


<a id="workers-process-lock"></a>
### Moment où `setenv`, `chdir` et `os.setlocale` sont verrouillés

Après validation des types et capacités, le premier appel à `spawn` marque le
processus comme ayant utilisé les workers. À partir de cet instant :

- `babet.setenv(...)` est définitivement refusé ;
- `babet.chdir(...)` est définitivement refusé ;
- `os.setlocale(locale, catégorie)` lève une erreur Lua si `locale` n'est pas
  `nil`, y compris pour `""` et pour la locale déjà active ;
- la restriction reste active après `join()` ;
- elle reste active même si la sérialisation de `args`, l'initialisation des
  queues ou `pthread_create` échoue ensuite.

Un appel rejeté **avant** ce marquage — par exemple `spawn(42)` ou une capacité
non entière — ne verrouille pas l'environnement.

La première tentative de chargement GTK par `gui.available()` ou `gui.init()`
déclenche le même verrouillage, avant l'entrée dans la bibliothèque native,
même si le chargement ou l'initialisation échoue. Cette règle couvre aussi les
threads créés par GTK sans `workers.spawn` ; voir le [contrat GUI](gui.md).

Configure donc le répertoire courant, l'environnement et la locale avant le
premier worker ou appel de chargement GUI. `os.setlocale()` et
`os.setlocale(nil, catégorie)` restent
disponibles en lecture dans tous les états. Avant le verrouillage, le contrat
standard Lua est conservé : un nom de locale en cas de succès, ou un seul
`nil` si la locale n'est pas disponible. La validation des arguments reste
identique à celle de Lua.

Le verrouillage persiste aussi après destruction et recréation d'un contexte
d'intégration. Ces règles protègent les points d'entrée Lua de Babet ; les
plugins natifs et les programmes hôtes restent responsables de leurs propres
mutations d'état global et de leurs threads.

<a id="workers-transfer"></a>
## Valeurs transférables

Le format de transport interne est JSON. Les mêmes règles s'appliquent à :

- `args` ;
- les messages dans les deux sens ;
- les messages envoyés dans les channels ;
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
- la sentinelle lightuserdata réservée à SQLite `babet.sqlite.NULL` ;
- coroutines/threads Lua ;
- tables cycliques ;
- tables mixtes ou creuses ;
- clés non string dans une table objet ;
- nombres `NaN` ou infinis ;
- chaînes avec NUL ou octets non acceptés comme UTF-8 ;
- structures imbriquées ou développées au-delà des limites de profondeur,
  de nœuds ou d'octets.

Un chemin, une URL ou une configuration sérialisable doit être transmis à la
place de l'objet système lui-même. Le worker ouvre ensuite sa propre ressource.

La sentinelle NULL est refusée avec un diagnostic qui nomme explicitement
`babet.sqlite.NULL`. Convertis-la en valeur métier comme
`{ kind = "sql-null" }` si cette intention doit traverser une frontière worker
ou channel.

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
### Copies, identité, profondeur et budgets

Le transport crée une copie par valeur :

- aucune référence Lua n'est partagée ;
- les métatables sont perdues ;
- deux références vers la même sous-table deviennent deux tables séparées ;
- les cycles sont refusés ;
- la profondeur maximale est de 32 niveaux selon le compteur interne de
  sérialisation ;
- une opération peut développer au plus **1 000 000 de valeurs JSON** ;
- la représentation estimée doit rester dans un budget conservateur de
  **64 Mio**.

```lua
local shared = { value = 1 }
local args = { a = shared, b = shared }

-- Dans le worker, worker.args.a et worker.args.b ont le même contenu,
-- mais ne sont pas la même table.
```

La limite de profondeur protège les piles C++ et Lua. Les deux budgets
supplémentaires empêchent une petite structure Lua de produire une quantité
exponentielle de données lorsque la même sous-table ou la même chaîne est
référencée de nombreuses fois.

Chaque valeur développée consomme exactement un nœud et un coût fixe de
32 octets. Chaque occurrence d'une chaîne, y compris une clé d'objet, consomme
également un majorant de `6 × taille_en_octets + 2`. Le facteur six couvre le
pire échappement JSON d'un octet de contrôle. Les deux plafonds se recouvrent
volontairement : ils bornent à la fois le nombre d'objets du DOM JSON et la
charge textuelle développée.

Ces limites s'appliquent indépendamment à chaque opération : arguments de
`spawn`, résultat final, `job:send`, `worker.send` ou `channel:send`. Une valeur
refusée n'est pas ajoutée à la queue. Le contrôle identique effectué à la
réception vérifie la cohérence du message ; la borne mémoire principale est
appliquée à l'émission, avant la copie des chaînes et avant la publication du
JSON interne.

Les plafonds font partie du contrat public. Les réduire dans une version
ultérieure pourrait rendre invalides des transferts auparavant acceptés et
devrait être annoncé comme un changement incompatible.

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

<a id="workers-status"></a>
### `status()` — observer sans consommer

```lua
local state = job:status()
```

`status()` renvoie exactement l'une des chaînes suivantes :

| État | Signification |
| --- | --- |
| `"running"` | le chunk ou son nettoyage est encore en cours |
| `"done"` | le worker a terminé normalement |
| `"error"` | le worker a terminé avec une erreur |

La méthode ne bloque pas, ne rejoint pas la pthread et ne consomme jamais le
résultat. Elle reste donc utilisable avant et après `join()` :

```lua
while job:status() == "running" do
    update_interface()
    babet.sleep(10, "ms")
end

local ok, result = job:join()
assert(ok, result)
assert(job:status() == "done")
```

`status()` ne distingue volontairement pas un worker en cours d'annulation :
tant que le chunk n'est pas terminé, l'état reste `"running"`.

<a id="workers-done"></a>
### `done()` — test booléen non consommant

```lua
if job:done() then
    print("le worker a terminé")
end
```

`done()` renvoie `false` tant que le statut interne vaut `"running"`, puis
`true` pour `"done"` comme pour `"error"`. La méthode ne rejoint pas la
pthread, ne désérialise pas le résultat et ne le consomme jamais. Elle est donc
adaptée aux boucles d'événements qui ont seulement besoin de savoir si un
`join()` ou un `poll()` final peut maintenant être tenté.

<a id="workers-join"></a>
### `join(timeout?)` — attendre et consommer

```lua
local ok, value_or_reason = job:join(timeout?)
```

Le timeout utilise les mêmes secondes que les queues :

- absent ou `nil` : attente indéfinie ;
- `0` : test immédiat ;
- nombre fini strictement positif jusqu'à `86400` : attente bornée ;
- valeur négative, NaN, infinie, chaîne numérique ou argument supplémentaire :
  erreur Lua levée.

Trois états de retour existent :

```lua
true, result       -- terminaison normale, résultat consommé
false, err         -- terminaison en erreur, résultat consommé
nil, "timeout"     -- worker encore actif, rien n'est consommé
```

Exemple avec reprise après expiration :

```lua
local ok, value = job:join(0.05)

if ok == nil then
    assert(value == "timeout")
    print("le worker continue")

    -- Le même job reste entièrement utilisable.
    ok, value = job:join(2)
end

if ok then
    print("résultat", value)
else
    io.stderr:write("worker: ", value, "\n")
end
```

Un timeout :

- ne ferme aucune queue ;
- ne demande aucune annulation ;
- ne rejoint pas la pthread ;
- ne consomme ni le résultat ni l'erreur ;
- permet encore `status`, `send`, `recv`, `close`, `cancel` et un nouvel appel à
  `join`.

Le timeout borne uniquement cet appel à `join()`. Si le worker reste actif puis
que sa dernière référence est collectée, notamment pendant la fermeture de
l'état Lua, son `__gc` doit encore effectuer un `pthread_join()` sans timeout et
peut donc bloquer la fin du programme.

Même lorsqu'un worker retourne légitimement `nil`, un succès reste
reconnaissable grâce à `ok == true`.

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
- `(false, "closed")` : inbox fermée par `close()` ou par la fin du worker ;
- `(false, "cancelled")` : annulation demandée par `cancel()` ;
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
## API `worker.send`, `worker.recv` et `worker.cancelled`

Dans le chunk :

```lua
local ok, message_or_err = worker.recv(timeout?)
local ok, err = worker.send(value, timeout?)
local cancelled = worker.cancelled()
```

`worker.recv` lit l'inbox alimentée par `job:send`. `worker.send` écrit dans
l'outbox lue par `job:recv`. `worker.cancelled()` lit sans blocage le drapeau
posé par `job:cancel()`.

Après une annulation :

- `worker.cancelled()` renvoie `true` ;
- le prochain `worker.recv()` renvoie `(false, "cancelled")` et ne livre plus
  les commandes qui attendaient encore dans l'inbox ; lorsque l'annulation
  devient visible juste après un `pop` réussi, cette commande extraite est
  volontairement abandonnée plutôt que livrée après la frontière de protocole ;
  une commande déjà rendue au Lua peut naturellement être en cours ;
- `worker.send()` reste disponible pour un dernier résultat, un diagnostic ou
  un accusé d'arrêt si l'outbox possède déjà une place ; un envoi bloqué sur une
  outbox pleine est réveillé et renvoie `(false, "cancelled")` ;
- le chunk décide lui-même quand et comment terminer.

Les règles FIFO, capacités, timeouts et fermeture restent symétriques en dehors
de ce cas d'annulation.

Différence de convention sur une erreur de sérialisation :

- `job:send` renvoie `(nil, err)` ;
- `worker.send` renvoie `(false, err)`.

Cette différence conserve la convention booléenne du code worker.

```lua
local job = assert(babet.workers.spawn([[
    while not worker.cancelled() do
        local ok, message = worker.recv(0.2)

        if ok then
            process(message)
        elseif message == "cancelled" then
            break
        elseif message ~= "timeout" then
            return { error = message }
        end
    end

    worker.send({ stopped = true })
    return "cancelled"
]]))
```


<a id="workers-channels"></a>
## Channels directs partagés

Un channel est une file bornée partagée entre le parent et autant de workers
que nécessaire. Contrairement à l'inbox et à l'outbox d'un `job`, il n'est pas
attaché à un worker particulier : tout handle du même channel peut produire ou
consommer des messages.

Le channel est :

- thread-safe ;
- multi-producteurs et multi-consommateurs ;
- borné en nombre de messages ;
- FIFO selon l'ordre d'insertion effectif ;
- fermé explicitement avec drainage des messages déjà présents.

<a id="workers-channel-create"></a>
### Créer un channel et choisir sa capacité

```lua
local channel, err = babet.workers.channel(opts?)
```

L'unique option est :

```lua
{
    capacity = 64,
}
```

- défaut : 64 messages ;
- minimum : 1 ;
- maximum : 1 000 000 ;
- la valeur doit être un entier Lua strict ;
- la capacité compte les messages, pas les octets.

```lua
local tasks = assert(babet.workers.channel({
    capacity = 16,
}))
```

Les options inconnues, les clés non textuelles, les noms contenant un octet NUL
et les capacités hors limites lèvent une erreur Lua. Une erreur d'allocation ou
d'initialisation renvoie `(nil, err)`.

<a id="workers-channel-send-recv"></a>
### `send` et `recv`

```lua
local ok, err = channel:send(value, timeout?)
local ok, value_or_reason = channel:recv(timeout?)
```

`send` renvoie :

- `(true, nil)` lorsque le message a été ajouté ;
- `(false, "full")` pour une tentative immédiate sur un channel plein ;
- `(false, "timeout")` lorsque l'échéance positive expire ;
- `(false, "closed")` après fermeture ;
- `(false, "cancelled")` dans un worker dont le job a été annulé ;
- `(nil, err)` si la valeur n'est pas sérialisable ou en cas d'erreur interne.

`recv` renvoie :

- `(true, value)` lorsqu'un message est retiré ; `value` peut être `nil` ;
- `(false, "empty")` pour une tentative immédiate sur un channel vide ;
- `(false, "timeout")` lorsque l'échéance positive expire ;
- `(false, "closed")` lorsque le channel est fermé **et entièrement drainé** ;
- `(false, "cancelled")` dans un worker dont le job a été annulé ;
- `(nil, err)` lors d'une anomalie interne de désérialisation.

```lua
local channel = assert(babet.workers.channel({ capacity = 1 }))

assert(channel:send(nil, 0))

local ok, value = channel:recv(0)
assert(ok == true)
assert(value == nil)

local got, reason = channel:recv(0)
assert(got == false and reason == "empty")
```

Les mêmes valeurs JSON que pour les workers sont acceptées. Un channel, un job,
un socket, `babet.sqlite.NULL` ou tout autre userdata/lightuserdata ne peut pas
être envoyé comme message. Un envoi refusé ne publie rien dans le channel. Pour
une capture Selenium binaire, envoie de préférence son chemin, ou conserve sa
forme Base64 puis utilise `babet.base64.decode()` au point de consommation.

Dans un worker, `job:cancel()` réveille également un `channel:send()` ou
`channel:recv()` bloqué pour **ce worker uniquement**. L'appel renvoie alors
`(false, "cancelled")` sans fermer le channel partagé ni perturber les autres
participants. Après annulation, les nouveaux `send` et `recv` de ce worker
renvoient aussi `"cancelled"`; utilise `worker.send()` pour un dernier accusé
d'arrêt vers le parent.

<a id="workers-channel-close"></a>
### `close` et `is_closed`

```lua
local ok, err = channel:close()
local closed = channel:is_closed()
```

`close()` est global et idempotent. Dès son retour :

- aucun nouvel envoi n'est accepté ;
- `is_closed()` renvoie `true` ;
- tous les `send()` et `recv()` bloqués sont réveillés ;
- les messages déjà en file restent disponibles ;
- après le dernier message, `recv()` renvoie `(false, "closed")`.

```lua
local channel = assert(babet.workers.channel({ capacity = 2 }))
assert(channel:send("one"))
assert(channel:send("two"))
assert(channel:close())
assert(channel:close()) -- idempotent
assert(channel:is_closed())

local ok1, one = channel:recv()
local ok2, two = channel:recv()
local ok3, reason = channel:recv()

assert(ok1 and one == "one")
assert(ok2 and two == "two")
assert(not ok3 and reason == "closed")
```

<a id="workers-channel-lifetime"></a>
### Concurrence, ordre et durée de vie

Tous les handles créés pour un même channel référencent la même structure C++.
Le parent et chaque état Lua possèdent néanmoins leur propre userdata.

- détruire un handle local ne ferme pas le channel pour les autres ;
- `close()` ferme explicitement la ressource pour tous les handles ;
- lorsque la dernière référence disparaît, Babet ferme la queue, réveille les
  éventuels waiters et détruit les messages restants ;
- la sortie d'un worker ne rend donc pas invalides les handles encore détenus
  par le parent ou d'autres workers.

Le FIFO décrit l'ordre d'insertion réel. Deux `send()` concurrents provenant de
producteurs différents n'ont pas d'ordre déterministe garanti. En revanche, les
envois successifs d'un même producteur restent ordonnés.

Une grande capacité n'impose aucune limite à la taille individuelle d'un
message. Comme le transport produit une représentation JSON intermédiaire, les
messages volumineux sont copiés et peuvent consommer beaucoup de mémoire. Pour
des données binaires importantes, un fichier publié atomiquement et son chemin
sont généralement préférables.

<a id="workers-timeouts"></a>
## Timeouts et raisons d'échec

Les quatre méthodes de messages et `join(timeout?)` partagent les mêmes règles
de validation des durées :

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
| `"cancelled"` | `job:send`, `worker.recv` ou méthode de channel appelée dans un worker annulé |

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

<a id="workers-cancel"></a>
## `cancel()` et annulation coopérative

```lua
local ok, err = job:cancel()
```

`job:cancel()` :

- pose un drapeau atomique visible par `worker.cancelled()` ;
- ferme l'inbox afin de réveiller immédiatement un `worker.recv()` bloqué ;
- réveille aussi le `channel:send()` ou `channel:recv()` actuellement bloqué
  dans ce worker, sans fermer le channel global ;
- fait renvoyer `(false, "cancelled")` aux futurs `job:send()` ;
- laisse l'outbox ouverte, accepte un dernier message si une place est
  immédiatement disponible et réveille un `worker.send()` bloqué sur une
  outbox pleine avec `(false, "cancelled")` ;
- ne rejoint pas le thread ;
- ne consomme pas le résultat final ;
- est idempotent et renvoie toujours `(true, nil)` pour un job valide.

```lua
assert(job:cancel())

local got, final = job:recv(1)
if got then
    print("dernier message", final)
end

local ok, result = job:join(2)
if ok == nil then
    error("le worker n'a pas coopéré dans le délai")
end
assert(ok, result)
```

Ce mécanisme n'utilise jamais `pthread_cancel()` et n'interrompt pas brutalement
Lua, SQLite, un verrou C++ ou une transaction. Un worker doit donc consulter
`worker.cancelled()` ou revenir régulièrement dans `worker.recv()`.

Un worker bloqué dans un appel système non interruptible ou une boucle qui ne
vérifie jamais le drapeau peut rester actif. Les attentes de channel Babet et
un `worker.send()` attendant une place dans l'outbox sont réveillés par
l'annulation. `join(timeout)` permet au parent de rester borné dans les autres
cas, mais Babet ne force pas la terminaison.

`close()` et `cancel()` sont distincts :

- `close()` signifie « aucune autre commande » et laisse drainer les commandes
  déjà en file ; `worker.recv()` finit par renvoyer `"closed"` ;
- `cancel()` signifie « abandonne le travail en cours dès que possible » ; les
  commandes encore en inbox ne sont plus livrées et `worker.recv()` renvoie
  `"cancelled"`. Une commande déjà extraite avant l'annulation peut être en
  cours de traitement : l'arrêt reste coopératif.

<a id="workers-state"></a>
## Chargement des modules et environnement du worker

Chaque thread crée un nouvel état Lua et :

- ouvre les bibliothèques standard Lua ;
- enregistre le namespace complet `babet` ;
- expose les modules bundlés via `require` ;
- configure le chargement des modules utilisateur de la même manière que le
  projet parent, en mode dossier ou embarqué ;
- expose `worker.args`, `worker.channels`, `worker.send`, `worker.recv` et
  `worker.cancelled` ;
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
- même locale C partagée par le processus ;
- même système de fichiers et mêmes ressources externes accessibles ;
- compte mémoire Lua mesuré séparément dans chaque état.

Babet interdit les mutations de cwd, d'environnement et de locale via ces API
Lua après le premier `spawn` ou la première tentative de chargement GTK.

`os.exit(...)` lève une erreur Lua dans chaque worker, y compris ses coroutines
et les workers imbriqués. Une erreur non interceptée fait renvoyer
`(false, err)` à `job:join()` ; `pcall` peut l'intercepter sans fermer l'état
Lua du worker. Utilise `return` pour terminer normalement un worker. Cette
règle vaut aussi pour `require("os").exit` et les alias sauvegardés.
Dans le CLI et les exécutables générés, `os.exit` conserve les arguments de Lua,
restaure l'interface et termine le processus sans callbacks natifs `atexit`.
Sans `close=true`, il n'attend pas les workers ; avec une valeur vraie de
`close`, la fermeture Lua peut attendre leurs appels natifs non coopératifs.
Voir le [contrat de sortie](../runtime-exit.md), notamment pour l'embedding.

<a id="workers-cpu-count"></a>
## Nombre de CPU disponibles

```lua
local count = babet.workers.cpu_count()
assert(math.type(count) == "integer" and count >= 1)
```

`cpu_count()` renvoie le nombre de CPU que le processus courant peut utiliser.
Sous Linux, Babet consulte d'abord l'affinité effective avec
`sched_getaffinity()`, ce qui respecte les ensembles de CPU imposés au
processus. Si cette information n'est pas disponible, `_SC_NPROCESSORS_ONLN`
est utilisé, avec un dernier repli à `1`.

La fonction n'accepte aucun argument. Elle sert notamment de valeur par défaut
à `workers.pool()`.

<a id="workers-pool"></a>
## Pool borné réutilisable

`workers.pool()` construit un nombre fixe de workers persistants. Chaque worker
crée une seule pthread et un seul `lua_State`, puis traite plusieurs tâches
successives reçues par un channel interne. Le pool évite ainsi le coût d'un
`workers.spawn()` complet pour chaque petite opération tout en conservant une
borne stricte sur la concurrence et le nombre de tâches en vol.

Le pool est implémenté en Lua embarqué au-dessus des primitives natives
`workers.spawn()` et `workers.channel()`. Il suit donc les mêmes limites de
sérialisation, de profondeur, de budget mémoire et d'annulation coopérative.

<a id="workers-pool-create"></a>
### Création et options

```lua
local pool, err = babet.workers.pool({
    size = math.min(babet.workers.cpu_count(), 8),
    queue_capacity = 64,
    channels = {
        progress = progress_channel,
    },
})
assert(pool, err)
```

Options acceptées :

| Option | Défaut | Contrat |
| --- | ---: | --- |
| `size` | `min(cpu_count(), 1024)` | entier de `1` à `1024` |
| `queue_capacity` | `max(64, size * 4)` | entier de `1` à `1 000 000` |
| `channels` | aucune | table nom -> channel partagée avec chaque tâche |

Les noms `__babet_pool_tasks` et `__babet_pool_results` sont réservés aux deux
channels internes. Une option ou un nom inconnu est refusé immédiatement.

Le nombre maximal de tâches acceptées mais pas encore collectées vaut :

```text
min(queue_capacity + size, 1 000 000)
```

Cette borne inclut les tâches en cours d'exécution et celles encore présentes
dans la file.

<a id="workers-pool-submit"></a>
### Soumission et tâches

```lua
local task, err = pool:submit([[
    return worker.args.left + worker.args.right
]], { left = 20, right = 22 }, 1.0)
assert(task, err)

assert(task:done() == false or task:done() == true)
local ok, result = task:join(2)
assert(ok and result == 42)
```

`submit(code, args?, timeout?)` accepte le même type de chunk texte et la même
table sérialisable que `workers.spawn()`. Le timeout porte sur l'admission dans
le pool : il peut être nécessaire d'attendre qu'une place se libère dans la
borne des tâches en vol ou dans le channel de travail.

Une tâche expose :

- `task:done()` : booléen non consommant ;
- `task:status()` : `"running"`, `"done"` ou `"error"` ;
- `task:poll()` : test non bloquant qui consomme un résultat terminé ;
- `task:join(timeout?)` : attente puis consommation du résultat.

Comme pour un job normal, la première valeur retournée est la seule transmise
et le résultat se consomme une seule fois. Une erreur de chargement ou
l'exception Lua d'une tâche devient l'erreur de cette tâche sans arrêter le
worker persistant. Si la valeur retournée n'est pas sérialisable, le pool la
convertit également en erreur de tâche puis continue à traiter les suivantes.

<a id="workers-pool-isolation"></a>
### Isolation et réutilisation des états

Chaque tâche reçoit une table globale fraîche dont `_G` pointe vers elle-même.
Une affectation globale ordinaire ne fuit donc pas vers la tâche suivante :

```lua
local first = assert(pool:submit("temporary = 42; return temporary"))
local second = assert(pool:submit("return temporary"))

assert(select(2, first:join()) == 42)
assert(select(2, second:join()) == nil)
```

Les bibliothèques et le cache `package.loaded` appartiennent néanmoins à l'état
Lua persistant du worker. Modifier explicitement une table de module partagée,
`package.loaded`, le registre C d'un module ou une ressource externe peut donc
être visible par une tâche ultérieure exécutée sur le même worker. Le pool
isole les globales ordinaires ; il ne recrée pas un état Lua complet par tâche.

Dans une tâche, la table `worker` expose volontairement seulement :

```lua
worker.args
worker.channels
worker.cancelled()
```

Les inbox/outbox privées `worker.send()` et `worker.recv()` ne font pas partie
du contrat des tâches de pool. Utilise `opts.channels` pour une communication
persistante supplémentaire.

<a id="workers-pool-backpressure"></a>
### Contre-pression et timeouts

```lua
local pool = assert(babet.workers.pool({
    size = 1,
    queue_capacity = 1,
}))

local a = assert(pool:submit("babet.sleep(1); return 'a'"))
local b = assert(pool:submit("babet.sleep(1); return 'b'"))
local c, reason = pool:submit("return 'c'", nil, 0)
assert(c == nil and reason == "timeout")
```

Avec un worker et une place de queue, deux tâches au maximum sont en vol : une
en cours et une en attente. Un timeout nul est non bloquant. Une valeur
strictement positive, au plus `86400`, utilise une deadline monotone et peut
renvoyer `"timeout"`. Un timeout absent attend tant que les workers restent
sains.

Le pool collecte les résultats pendant les attentes de soumission et de
fermeture. La capacité du channel de résultats est égale à la borne des tâches
en vol, de sorte qu'un worker ne reste pas bloqué simplement parce que le
parent n'a pas encore appelé `join()` sur chaque tâche.

<a id="workers-pool-lifecycle"></a>
### Fermeture, annulation et `join`

`pool:close(timeout?)` refuse les nouvelles soumissions et place un marqueur
d'arrêt par worker **après** toutes les tâches déjà acceptées. Le FIFO du
channel garantit donc leur traitement avant l'arrêt normal des threads.

`pool:join(timeout?)` appelle automatiquement `close()` si nécessaire, collecte
tous les résultats en attente puis joint chaque worker persistant. Un timeout ne
consomme ni les résultats de tâche encore disponibles ni les jointures de
workers déjà terminées ; le même pool peut être rejoint à nouveau pour achever
le nettoyage :

```lua
local task = assert(pool:submit("return 42"))
assert(pool:join(5))
assert(select(2, task:join(0)) == 42)
```

`pool:cancel()` ferme immédiatement l'admission, marque les tâches encore en
vol comme `"cancelled"`, ferme le channel de travail et demande l'annulation de
chaque worker. Une tâche déjà en cours ne peut s'arrêter que si son code revient
ou consulte `worker.cancelled()`. Il n'existe ni `pthread_cancel()` ni arrêt
forcé.

Un pool rejoint ne peut pas être rejoint une seconde fois. `pool:stats()`
renvoie notamment `size`, `queue_capacity`, `max_pending`, `pending`,
`accepting`, `closing`, `cancelled` et `joined`.

<a id="workers-pool-channels"></a>
### Channels partagés dans les tâches

```lua
local progress = assert(babet.workers.channel({ capacity = 16 }))
local pool = assert(babet.workers.pool({
    size = 2,
    channels = { progress = progress },
}))

local task = assert(pool:submit([[
    assert(worker.channels.progress:send({ percent = 100 }))
    return "done"
]]))

local received, message = progress:recv(2)
assert(received and message.percent == 100)
assert(task:join(2))
assert(pool:join(2))
```

Les handles sont partagés avec tous les workers du pool et restent soumis au
contrat FIFO, borné et multi-producteurs/multi-consommateurs des channels
normaux. Le pool ne ferme jamais automatiquement les channels fournis par
l'utilisateur.

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


<a id="workers-example-channel-parent-worker"></a>
### Parent vers worker avec un channel

```lua
local tasks = assert(babet.workers.channel({ capacity = 8 }))

local job = assert(babet.workers.spawn([[
    local ok, task = worker.channels.tasks:recv(2)
    assert(ok, task)
    return task.left + task.right
]], nil, {
    channels = { tasks = tasks },
}))

assert(tasks:send({ left = 20, right = 22 }, 2))

local ok, result = job:join(2)
assert(ok and result == 42)
```

<a id="workers-example-channel-worker-worker"></a>
### Worker vers worker sans relais du parent

```lua
local tasks = assert(babet.workers.channel({ capacity = 16 }))
local results = assert(babet.workers.channel({ capacity = 16 }))

local producer = assert(babet.workers.spawn([[
    for i = 1, 10 do
        assert(worker.channels.tasks:send({ id = i, value = i * 10 }, 2))
    end
    return "producer done"
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
    return "consumer done"
]], nil, {
    channels = { tasks = tasks, results = results },
}))

for expected = 1, 10 do
    local ok, item = results:recv(2)
    assert(ok, item)
    assert(item.id == expected)
    assert(item.result == expected * 20)
end

assert(producer:join(2))
assert(consumer:join(2))
assert(tasks:close())
assert(results:close())
```

Le message producteur vers consommateur ne transite jamais par le parent.

<a id="workers-example-channel-mpmc"></a>
### Plusieurs producteurs et consommateurs

```lua
local tasks = assert(babet.workers.channel({ capacity = 32 }))
local results = assert(babet.workers.channel({ capacity = 32 }))
local jobs = {}

for producer_id = 1, 2 do
    jobs[#jobs + 1] = assert(babet.workers.spawn([[
        for i = 1, 100 do
            assert(worker.channels.tasks:send({
                producer = worker.args.id,
                sequence = i,
            }, 2))
        end
        return true
    ]], { id = producer_id }, {
        channels = { tasks = tasks },
    }))
end

for _ = 1, 2 do
    jobs[#jobs + 1] = assert(babet.workers.spawn([[
        while true do
            local ok, task = worker.channels.tasks:recv(2)
            if not ok then
                assert(task == "closed")
                break
            end
            assert(worker.channels.results:send(task, 2))
        end
        return true
    ]], nil, {
        channels = { tasks = tasks, results = results },
    }))
end

assert(jobs[1]:join(3))
assert(jobs[2]:join(3))
assert(tasks:close())

local seen = {}
for _ = 1, 200 do
    local ok, item = results:recv(3)
    assert(ok, item)
    local key = item.producer .. ":" .. item.sequence
    assert(not seen[key])
    seen[key] = true
end

assert(results:close())
assert(jobs[3]:join(3))
assert(jobs[4]:join(3))
```

Avec plusieurs consommateurs, la répartition des messages dépend de
l'ordonnancement des threads ; elle n'est pas prédictible, mais chaque message
n'est retiré que par un seul consommateur.

<a id="workers-example-cancel"></a>
### Annulation coopérative native

```lua
local job = assert(babet.workers.spawn([[
    local total = 0

    for i = 1, worker.args.limit do
        total = total + expensive_step(i)

        if i % 1000 == 0 and worker.cancelled() then
            worker.send({
                stopped = true,
                partial = total,
            })
            return {
                cancelled = true,
                partial = total,
            }
        end
    end

    return { cancelled = false, total = total }
]], { limit = 1000000 }))

-- Plus tard :
assert(job:cancel())

-- L'outbox reste drainable après cancel().
local got, progress = job:recv(0.5)
if got then
    print("partiel", progress.partial)
end

local ok, result = job:join(2)
if ok == nil then
    error("annulation non observée dans les deux secondes")
end
assert(ok, result)
```

Exemple combinant `worker.recv()` et le drapeau :

```lua
local job = assert(babet.workers.spawn([[
    while not worker.cancelled() do
        local ok, command = worker.recv(0.1)

        if ok then
            execute(command)
        elseif command == "cancelled" then
            break
        elseif command ~= "timeout" then
            return { error = command }
        end
    end

    worker.send({ stopped = true })
    return "cancelled"
]]))

assert(job:cancel())
local ok, result = job:join(2)
assert(ok and result == "cancelled")
```

L'annulation reste coopérative : elle ne coupe pas arbitrairement un appel
système ni du code qui ne consulte jamais le drapeau.

<a id="workers-example-pool"></a>
### Pool natif pour plusieurs tâches

```lua
local pool = assert(babet.workers.pool({
    size = math.min(4, babet.workers.cpu_count()),
    queue_capacity = 16,
}))

local tasks = {}
for index = 1, 100 do
    tasks[index] = assert(pool:submit([[
        return worker.args.value * worker.args.value
    ]], { value = index }))
end

assert(pool:close(5))

local results = {}
for index, task in ipairs(tasks) do
    local ok, value = task:join(5)
    assert(ok, value)
    results[index] = value
end

assert(pool:join(5))
assert(results[10] == 100)
```

Le nombre de pthreads reste fixe pendant les cent tâches. `close()` peut être
appelé avant la collecte des résultats : le pool traite toutes les soumissions
acceptées, tandis que chaque `task:join()` récupère son résultat par identifiant.

<a id="workers-deadlocks"></a>
## Interblocages à éviter

### Worker en attente de l'inbox, parent dans `join()`

```lua
-- Worker
local ok, message = worker.recv() -- attend indéfiniment

-- Parent
job:join() -- attend le worker
```

Les deux côtés s'attendent. Ferme l'inbox, envoie une commande, ou demande
l'annulation :

```lua
job:cancel()
local ok, result = job:join(2)
assert(ok ~= nil, result) -- nil signifie que le worker n'a pas encore coopéré
```

### Worker bloqué sur une outbox pleine

Si le worker utilise `worker.send()` sans timeout, que l'outbox est pleine et
que le parent appelle `join()` sans la drainer, aucun côté ne peut progresser.

Solutions :

- le parent lit régulièrement `job:recv()` ;
- le worker utilise un timeout fini ;
- l'outbox possède une capacité adaptée ;
- le protocole sépare clairement la phase de messages et la phase de join ;
- lors d'une annulation, le parent appelle `job:cancel()` avant le `join()`
  borné : l'annulation réveille désormais l'envoi bloqué sans supprimer les
  messages déjà placés dans l'outbox.

### Producteurs bloqués sur un channel plein

Un channel borné peut créer le même cycle d'attente qu'une outbox : les
producteurs attendent de la place, tandis que le parent appelle `join()` avant
que les consommateurs aient drainé la queue.

Prévoir explicitement qui consomme, qui ferme le channel et à quel moment. Les
boucles longues doivent utiliser des timeouts finis ou une stratégie de
fermeture afin qu'une erreur d'un participant ne bloque pas tous les autres.

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
- option inconnue ou nom d'option non chaîne dans `opts` ;
- capacités non numériques, non entières, hors `1..1 000 000` ;
- timeout non numérique, négatif, non fini ou supérieur à 86 400 secondes ;
- argument supplémentaire à `join`, `status`, `cancel` ou
  `worker.cancelled` ;
- appel d'une méthode sur un objet qui n'est ni le job ni le channel attendu ;
- arité, option ou capacité invalide de `workers.channel()` ;
- table `opts.channels` invalide, nom vide/non UTF-8/avec NUL ou valeur qui n'est pas un channel.

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
- dépassement d'un budget de sérialisation ;
- échec de sérialisation JSON ;
- initialisation d'une queue ou du signal de terminaison impossible ;
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
- `channel:send` : `(nil, err)` pour la même situation ;
- `job:recv` et `worker.recv` : `(false, err)` sur une anomalie interne ;
- `channel:recv` : `(nil, err)` sur une anomalie interne.

<a id="workers-gc"></a>
## Garbage collector et destruction

Le userdata possède un `__gc` de sécurité. Lorsqu'il est collecté :

1. le drapeau d'annulation est posé ;
2. l'inbox et l'outbox sont fermées ;
3. les attentes de queue sont réveillées ;
4. Babet appelle `pthread_join` si nécessaire ;
5. les primitives pthread, le signal de terminaison et les chaînes internes
   sont détruits.

Cette séquence évite de libérer un état encore utilisé par un thread. Elle peut
toutefois bloquer si le worker ne peut pas terminer.

Ne compte pas sur le GC comme mécanisme normal de synchronisation. Conserve le
job, termine le protocole, puis appelle `join()` ou consomme le résultat avec
`poll()`.

Un pool est un objet Lua qui possède plusieurs userdata workers. Abandonner les
dernières références au pool et à ses tâches sans `pool:join()` délègue à terme
chaque thread aux finaliseurs de ces userdata et peut donc bloquer la collecte
ou la fermeture de l'état Lua. Le code normal doit appeler explicitement
`close()` ou `cancel()`, puis rejouer `pool:join()` jusqu'à sa réussite.

Les handles de channel possèdent également un `__gc`, mais sa portée est locale :
il libère uniquement la référence détenue par cet état Lua. Il ne remplace
jamais `channel:close()` et ne ferme pas la ressource tant que d'autres handles
existent.

`tostring(channel)` renvoie `WorkerChannel(open)` ou
`WorkerChannel(closed)` selon l'état global instantané.

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

### `os.execute` et `io.popen` dans un worker

Dans les états workers, ces deux fonctions lancent `/bin/sh -c` avec un
masque de signaux vide dans l'enfant. Les signaux bloqués pour protéger les
threads workers ne restent donc pas bloqués dans la commande, même si le
shell conserve normalement le masque hérité. Le masque du worker lui-même
reste inchangé. Les dispositions explicitement ignorées restent héritables
selon les règles habituelles d'exécution des programmes.

Le lancement et l'attente de `os.execute` dans un worker ne modifient pas les
dispositions globales de `SIGINT` et `SIGQUIT` : ils ne désactivent donc pas
temporairement le gestionnaire de signaux du thread principal.

Les contrats Lua restent disponibles : `os.execute()` renvoie un booléen de
disponibilité du shell ; une commande terminée renvoie `true` ou `nil`, puis
`"exit"` ou `"signal"` et le code correspondant. Un échec natif de lancement ou
d'attente renvoie `nil, message, errno`. `io.popen` accepte `"r"` et `"w"` et
renvoie un fichier Lua ordinaire, ou `nil, message, errno` si le lancement
échoue. Ses méthodes, `io.type`, `close`, `<close>` et le GC continuent de
fonctionner ; la fermeture attend et récolte l'enfant. Les extrémités de
pipe conservées par le parent ne sont pas héritées après un autre `exec`.

Ces appels restent bloquants. Ni `job:cancel()` ni l'expiration d'un
`job:join(timeout)` ne terminent automatiquement la commande ; la fermeture
d'un fichier `io.popen`, y compris pendant le GC, peut attendre sa fin.
Les fonctions de l'état Lua principal conservent leur implémentation standard.

### Environnement et cwd

`setenv` et `chdir` modifient un état process-wide qui ne peut pas être muté en
sécurité pendant que d'autres threads l'utilisent. Babet les interdit donc
après le premier `spawn` ou la première tentative de chargement GTK.

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
- les handles des channels explicitement transmis ;
- des copies JSON des données transférées.

Évite de créer un worker pour une opération minuscule. Regroupe le travail ou
utilise quelques workers persistants lorsque le protocole le permet.

<a id="workers-not-provided"></a>
## Fonctionnalités absentes

Le module ne fournit pas actuellement :

- une terminaison forcée d'un worker ;
- l'annulation individuelle et forcée d'une tâche de pool ;
- le redimensionnement dynamique d'un pool après sa création ;
- des channels entre processus OS distincts ;
- de la mémoire Lua partagée ;
- le transfert de fonctions, userdata ou coroutines ;
- un format binaire pour les messages ;
- le transfert automatique de plusieurs valeurs de retour.

Le pool 2.18 est local à l'état Lua qui l'a créé. Il ne constitue pas un
ordonnanceur global partagé entre plusieurs processus Babet et ne déplace pas
une tâche déjà commencée d'un worker vers un autre.
