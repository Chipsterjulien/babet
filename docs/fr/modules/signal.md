> [English](../../en/modules/signal.md) | **Français**

# SIGNAL — arrêt propre, rechargement et signaux POSIX

`babet.signal` permet au script principal d'installer un callback Lua pour un
petit ensemble de signaux POSIX, d'ignorer un signal ou de restaurer son
comportement système par défaut.

Le module couvre :

- l'arrêt propre sur `TERM` et `INT` ;
- le rechargement de configuration sur `HUP` ;
- deux signaux applicatifs, `USR1` et `USR2` ;
- le choix explicite d'ignorer ou de restaurer un signal ;
- l'interruption de certains appels bloquants Babet ;
- le dispatch différé et sûr des callbacks dans le thread Lua principal.

Il ne permet pas d'envoyer un signal, de consulter une file de signaux, de
configurer un masque POSIX ou d'installer des handlers depuis un worker.

## Table des matières du module

- [Conventions essentielles](#signal-conventions)
- [Vue d'ensemble de l'API](#signal-api-summary)
- [Signaux pris en charge](#signal-supported)
- [`handle(name, fn)` — installer ou remplacer](#signal-handle)
- [`handle(name, nil)` — retirer un callback](#signal-handle-remove)
- [`ignore(name)` — ignorer](#signal-ignore)
- [`default(name)` — restaurer le comportement système](#signal-default)
- [Exécution des callbacks](#signal-dispatch)
  - [Thread principal et contexte sûr](#signal-main-thread)
  - [Ordre de dispatch](#signal-order)
  - [Coalescence des occurrences](#signal-coalescing)
  - [Erreurs du callback](#signal-callback-errors)
- [Interaction avec les appels bloquants](#signal-blocking)
- [Interaction avec `debug.sethook`](#signal-debug-hook)
- [Exemples complets](#signal-examples)
  - [Arrêt propre sur `TERM` et `INT`](#signal-example-shutdown)
  - [Recharger une configuration avec `HUP`](#signal-example-reload)
  - [Interrompre une attente socket](#signal-example-socket)
  - [Ignorer temporairement `PIPE`](#signal-example-ignore)
  - [Observer les erreurs du callback](#signal-example-pcall)
- [Contrat d'erreur](#signal-errors)
- [Workers, concurrence et limites](#signal-workers)
- [Fonctionnalités absentes](#signal-not-provided)

<a id="signal-conventions"></a>
## Conventions essentielles

### Les succès renvoient une seule valeur

Les trois fonctions renvoient uniquement le booléen `true` en cas de succès.
Elles ne renvoient pas un second `nil`.

```lua
local ok = babet.signal.ignore("PIPE")
assert(ok == true)
```

Une panne rare de `sigaction(2)` renvoie en revanche deux valeurs :

```lua
local ok, err = babet.signal.ignore("PIPE")
if not ok then
    io.stderr:write(err, "\n")
end
```

### Les noms sont stricts

Un nom de signal doit être une véritable chaîne Lua, sans octet NUL, dans la
casse indiquée par la documentation.

```lua
assert(babet.signal.handle("TERM", function() end))
```

Les formes suivantes sont invalides :

```lua
babet.signal.handle("term", function() end) -- casse incorrecte
babet.signal.handle(15, function() end)     -- nombre, pas string
babet.signal.handle("TERM\0X", function() end)
```

### Un callback ne reçoit aucun argument

Le callback est appelé sans paramètre. Installe une fonction différente pour
chaque signal lorsque le code doit savoir lequel est arrivé.

```lua
babet.signal.handle("USR1", function()
    print("USR1")
end)
```

<a id="signal-api-summary"></a>
## Vue d'ensemble de l'API

```lua
local ok, err = babet.signal.handle(name, callback_or_nil)
local ok, err = babet.signal.ignore(name)
local ok, err = babet.signal.default(name)
```

| Fonction | Succès | Échec système rare | Mauvais appel |
| --- | --- | --- | --- |
| `handle(name, fn)` | `true` | `(nil, err)` | erreur Lua levée |
| `handle(name, nil)` | `true` | `(nil, err)` | erreur Lua levée |
| `ignore(name)` | `true` | `(nil, err)` | erreur Lua levée |
| `default(name)` | `true` | `(nil, err)` | erreur Lua levée |

`handle(name)` sans deuxième argument est volontairement refusé. Il faut écrire
explicitement `handle(name, nil)` pour retirer un callback.

<a id="signal-supported"></a>
## Signaux pris en charge

| Nom Babet | Signal POSIX | Usage courant | Comportement système usuel |
| --- | --- | --- | --- |
| `"TERM"` | `SIGTERM` | demande d'arrêt propre, notamment par systemd | termine le processus |
| `"INT"` | `SIGINT` | interruption clavier, généralement Ctrl-C | termine le processus |
| `"HUP"` | `SIGHUP` | rechargement d'une configuration | termine souvent le processus |
| `"USR1"` | `SIGUSR1` | événement applicatif libre | termine le processus |
| `"USR2"` | `SIGUSR2` | second événement applicatif libre | termine le processus |
| `"PIPE"` | `SIGPIPE` | écriture sur un pipe ou socket fermé | termine le processus |

Les noms `KILL` et `STOP` ne peuvent pas être exposés : POSIX interdit de les
intercepter ou de les ignorer.

Les signaux dangereux ou réservés à d'autres mécanismes internes — par exemple
`SEGV`, `BUS`, `FPE`, `ILL`, `CHLD` et `ALRM` — ne font pas partie de la liste
blanche.

<a id="signal-handle"></a>
## `handle(name, fn)` — installer ou remplacer

```lua
local ok, err = babet.signal.handle(name, fn)
```

- `name` est l'un des six noms supportés ;
- `fn` doit être une fonction Lua ;
- le handler POSIX précédent est remplacé ;
- un callback Lua déjà enregistré pour le même signal est remplacé ;
- le callback est conservé dans la registry Lua tant qu'il n'est pas retiré.

```lua
local stopping = false

assert(babet.signal.handle("TERM", function()
    stopping = true
end))
```

Remplacer le callback :

```lua
assert(babet.signal.handle("USR1", function()
    print("première version")
end))

assert(babet.signal.handle("USR1", function()
    print("nouvelle version")
end))
```

Après le second appel, seule la nouvelle fonction peut être exécutée.

<a id="signal-handle-remove"></a>
## `handle(name, nil)` — retirer un callback

```lua
local ok, err = babet.signal.handle(name, nil)
```

Cette forme :

1. efface le callback Lua associé ;
2. restaure `SIG_DFL`, le comportement système par défaut.

```lua
assert(babet.signal.handle("HUP", reload_config))

-- Plus tard : retrait explicite.
assert(babet.signal.handle("HUP", nil))
```

`handle("TERM")` sans second argument n'est **pas** un raccourci : il lève une
erreur, afin d'éviter une désinstallation accidentelle due à un argument
oublié.

<a id="signal-ignore"></a>
## `ignore(name)` — ignorer

```lua
local ok, err = babet.signal.ignore(name)
```

`ignore` installe `SIG_IGN` et efface tout callback Lua précédemment associé.
Le noyau ignore ensuite le signal.

```lua
assert(babet.signal.ignore("PIPE"))
```

Cette forme est utile lorsqu'une application préfère recevoir les erreurs
d'écriture normales plutôt que d'être terminée par `SIGPIPE`.

L'ignorance reste active jusqu'à un nouvel appel à `handle`, `default` ou
`handle(name, nil)` pour ce même signal.

<a id="signal-default"></a>
## `default(name)` — restaurer le comportement système

```lua
local ok, err = babet.signal.default(name)
```

`default` installe `SIG_DFL` et efface tout callback Lua. Pour `TERM`, `INT`,
`HUP`, `USR1`, `USR2` et généralement `PIPE`, le prochain signal correspondant
terminera le processus selon les règles du système.

```lua
assert(babet.signal.ignore("PIPE"))
-- ... section où SIGPIPE doit être ignoré ...
assert(babet.signal.default("PIPE"))
```

`handle(name, nil)` et `default(name)` ont le même effet système. `default` est
plus explicite lorsqu'aucun callback n'est en jeu.

<a id="signal-dispatch"></a>
## Exécution des callbacks

Le vrai handler POSIX n'appelle jamais Lua. Il se contente de poser un flag de
type `sig_atomic_t`, opération compatible avec le contexte asynchrone d'un
signal.

Le callback Lua est exécuté plus tard, depuis un point sûr :

1. un signal supporté arrive ;
2. le handler C marque ce signal comme en attente ;
3. le thread principal remarque le flag depuis le hook d'instructions ou la
   sortie d'un appel bloquant interrompu ;
4. Babet remet le flag à zéro ;
5. Babet appelle le callback Lua avec zéro argument.

<a id="signal-main-thread"></a>
### Thread principal et contexte sûr

Le callback tourne toujours dans l'état Lua principal, jamais dans le handler
POSIX et jamais dans un worker. Il peut donc utiliser normalement Lua et les
modules Babet.

```lua
babet.signal.handle("USR1", function()
    -- Ceci est exécuté dans un contexte Lua normal.
    local now = babet.time.now()
    print("USR1 à", now)
end)
```

Cette liberté ne signifie pas qu'un callback doive être long. Une fonction
courte qui positionne un booléen ou enfile une action reste plus simple à
raisonner.

<a id="signal-order"></a>
### Ordre de dispatch

Lorsque plusieurs signaux différents sont en attente au même point de
dispatch, Babet les traite dans l'ordre fixe de sa liste blanche :

1. `TERM` ;
2. `INT` ;
3. `HUP` ;
4. `USR1` ;
5. `USR2` ;
6. `PIPE`.

Ce n'est ni l'ordre d'enregistrement des callbacks ni une garantie de l'ordre
exact d'arrivée au niveau du noyau.

Par exemple, si `USR1` puis `TERM` arrivent avant le prochain dispatch, le
callback `TERM` est exécuté avant le callback `USR1`.

<a id="signal-coalescing"></a>
### Coalescence des occurrences

Babet maintient un flag par type de signal, pas un compteur ni une file.
Plusieurs occurrences identiques reçues avant le prochain dispatch sont donc
coalescées en un seul appel du callback.

```text
USR1, USR1, USR1 avant le dispatch -> un appel du callback USR1
```

Un nouveau signal identique reçu **pendant** l'exécution du callback peut
reposer le flag et être traité lors d'un dispatch ultérieur.

N'utilise donc pas ce module comme compteur fiable d'événements. Pour ne perdre
aucune occurrence métier, utilise une queue, un pipe, une socket ou un autre
mécanisme de messages.

<a id="signal-callback-errors"></a>
### Erreurs du callback

Babet appelle le callback avec `lua_pcall`. Une erreur non attrapée est retirée
de la pile et silencieusement ignorée ; elle ne remonte pas au code qui était
en cours d'exécution.

```lua
babet.signal.handle("USR1", function()
    error("invisible pour l'appelant")
end)
```

Pour journaliser une erreur, protège explicitement le corps :

```lua
babet.signal.handle("USR1", function()
    local ok, err = pcall(function()
        refresh_metrics()
    end)
    if not ok then
        io.stderr:write("USR1: ", tostring(err), "\n")
    end
end)
```

<a id="signal-blocking"></a>
## Interaction avec les appels bloquants

Babet installe les handlers sans `SA_RESTART`. Certains appels bloquants
internes peuvent donc être interrompus par un signal géré. Lorsque le thread
principal constate qu'un signal Babet est en attente, il dispatche les
callbacks puis renvoie généralement une erreur typée `"interrupted"`.

Les familles actuellement intégrées à ce mécanisme comprennent notamment :

- `babet.sleep(...)` ;
- `watcher:read(...)` du module Inotify ;
- les attentes TCP : connexion, acceptation et réception ;
- les handshakes et attentes TLS.

Exemple :

```lua
local data, err = peer:recv(4096, 30)
if not data then
    if err == "interrupted" then
        -- Un callback a déjà été dispatché : re-vérifier l'état du programme.
    elseif err == "timeout" then
        -- Aucun octet reçu avant l'échéance.
    else
        -- Fermeture ou erreur réseau.
    end
end
```

Toutes les fonctions Babet ne sont pas interruptibles par ce mécanisme.
`babet.exec`, par exemple, applique son propre timeout et n'expose pas une
sortie `"interrupted"` sur signal géré.

Un syscall peut aussi recevoir un `EINTR` sans qu'un signal géré par Babet soit
en attente. Dans ce cas, les boucles internes reprennent normalement leur
attente au lieu de produire un faux `"interrupted"`.

<a id="signal-debug-hook"></a>
## Interaction avec `debug.sethook`

En dehors des fonctions bloquantes intégrées, Babet utilise un hook Lua de type
`count`, déclenché environ toutes les 10 000 instructions, pour vérifier les
flags en attente.

Lua ne permet qu'un hook actif par état. Par conséquent :

- le premier `signal.handle(...)` remplace un hook utilisateur déjà installé ;
- un appel ultérieur à `debug.sethook(...)` remplace le hook de Babet ;
- après ce remplacement, les callbacks ne seront plus dispatchés par le compte
  d'instructions, mais pourront encore l'être à la sortie des appels bloquants
  intégrés ;
- retirer tous les callbacks avec `handle(name, nil)`, `ignore(name)` ou
  `default(name)` ne désinstalle pas le hook de Babet et ne restaure pas un hook
  utilisateur précédemment remplacé. Le hook reste actif, mais ne fait rien tant
  qu'aucun callback Babet n'est enregistré.

Évite de combiner `babet.signal` et un hook de debug personnalisé dans le même
état Lua, sauf si cette interaction est volontaire et maîtrisée.

<a id="signal-examples"></a>
## Exemples complets

<a id="signal-example-shutdown"></a>
### Arrêt propre sur `TERM` et `INT`

```lua
local running = true

local function request_stop()
    running = false
end

assert(babet.signal.handle("TERM", request_stop))
assert(babet.signal.handle("INT", request_stop))

while running do
    do_one_iteration()

    local slept, err = babet.sleep(250, "ms")
    if not slept and err ~= "interrupted" then
        io.stderr:write(tostring(err), "\n")
        break
    end
    -- En cas de "interrupted", le callback a déjà été exécuté et
    -- la boucle re-vérifie running.
end

close_resources()
```

Pour une boucle réseau, utilise directement le retour `"interrupted"` de la
socket plutôt qu'un `pcall`.

<a id="signal-example-reload"></a>
### Recharger une configuration avec `HUP`

Il est souvent préférable que le callback ne fasse que poser un drapeau. Le
chargement complet s'effectue ensuite dans la boucle normale.

```lua
local running = true
local reload_requested = false

assert(babet.signal.handle("TERM", function()
    running = false
end))

assert(babet.signal.handle("HUP", function()
    reload_requested = true
end))

while running do
    if reload_requested then
        reload_requested = false
        local new_config, err = load_config()
        if new_config then
            config = new_config
        else
            io.stderr:write("reload: ", err, "\n")
        end
    end

    do_one_iteration(config)
end
```

<a id="signal-example-socket"></a>
### Interrompre une attente socket

```lua
local running = true

assert(babet.signal.handle("TERM", function()
    running = false
end))

while running do
    local client, err = server:accept(60)
    if client then
        serve(client)
    elseif err == "interrupted" then
        -- Le callback TERM a pu mettre running à false.
    elseif err ~= "timeout" then
        io.stderr:write("accept: ", err, "\n")
    end
end

server:close()
```

<a id="signal-example-ignore"></a>
### Ignorer temporairement `PIPE`

```lua
assert(babet.signal.ignore("PIPE"))

local sent, err = socket:send(payload)
if not sent then
    io.stderr:write("send: ", err, "\n")
end

assert(babet.signal.default("PIPE"))
```

Attention : restaurer `SIGPIPE` à son comportement par défaut signifie qu'une
écriture ultérieure sur un pipe fermé peut terminer le processus.

<a id="signal-example-pcall"></a>
### Observer les erreurs du callback

```lua
local function safe_handler(label, fn)
    return function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok then
            io.stderr:write(label, ": ", tostring(err), "\n")
        end
    end
end

assert(babet.signal.handle("USR2", safe_handler("USR2", function()
    rotate_logs()
end)))
```

<a id="signal-errors"></a>
## Contrat d'erreur

### Erreurs Lua levées

Les situations suivantes lèvent immédiatement une erreur Lua :

- appel depuis un worker ;
- `name` absent, non string ou contenant un NUL ;
- nom non supporté ou casse incorrecte ;
- `handle` sans deuxième argument ;
- callback différent d'une fonction ou de `nil`.

```lua
local ok, err = pcall(function()
    babet.signal.handle("TERM")
end)
assert(not ok)
```

Le nom non supporté lève également une erreur ; il ne produit pas `(nil, err)`.

```lua
local ok, err = pcall(function()
    babet.signal.ignore("QUIT")
end)
```

### Erreur système renvoyée

Si `sigaction(2)` échoue, la fonction renvoie :

```lua
nil, "signal: sigaction failed: ..."
```

Ce cas est rare avec les six signaux autorisés, mais l'appelant peut conserver
la convention `(ok, err)` lorsqu'il souhaite le traiter.

<a id="signal-workers"></a>
## Workers, concurrence et limites

Les dispositions de signal sont globales au processus, pas propres à un
thread. Babet impose donc les règles suivantes :

- `handle`, `ignore` et `default` sont réservés au thread principal ;
- leur utilisation dans un worker lève une erreur explicite ;
- les workers bloquent les six signaux supportés afin qu'ils restent gérés par
  le thread principal ;
- les workers ne peuvent ni voir ni consommer les flags en attente du parent.

Un worker doit être contrôlé par ses queues de messages, pas par
`babet.signal` :

```lua
local job = assert(babet.workers.spawn([[
    while true do
        local ok, message = worker.recv()
        if not ok then
            return "closed"
        end
        if message == "stop" then
            return "stopped"
        end
    end
]]))

-- Le handler principal transforme le signal en message applicatif.
babet.signal.handle("TERM", function()
    job:send("stop", 0)
end)
```

Ce callback reste volontairement bref. Une queue pleine peut faire échouer
l'envoi non bloquant ; une application robuste conserve également un drapeau
de secours.

<a id="signal-not-provided"></a>
## Fonctionnalités absentes

Le module ne fournit pas actuellement :

- `kill(pid, name)` pour envoyer un signal ;
- `list()` pour obtenir les noms supportés ;
- `is_pending()` ou un compteur d'occurrences ;
- `sigprocmask` ou un masque par thread ;
- `signalfd` ;
- les signaux autres que les six noms listés ;
- un hook de debug chaînable avec celui de l'utilisateur.

Pour envoyer un signal depuis Lua, un programme externe reste possible :

```lua
local result, err = babet.exec("kill", {
    "-TERM",
    tostring(pid),
})
assert(result, err)
assert(result.code == 0, result.stderr)
```

La réception reste soumise aux règles POSIX normales et au modèle de dispatch
décrit dans cette page.
