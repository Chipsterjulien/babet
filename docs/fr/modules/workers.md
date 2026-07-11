> [English](../../en/modules/workers.md) | **Français**

# `babet.workers` — jobs parallèles

Exécute du code Lua sur de vrais threads OS. Utile pour le travail
I/O-bound qui bénéficie de la concurrence (fetcher beaucoup
d'URLs, scanner beaucoup de fichiers, traiter des batches) et le
travail CPU-bound sur des machines multi-cœurs.

## Pourquoi

Lua a des coroutines, mais elles tournent coopérativement sur un
seul thread OS — très bien pour les machines à états, pas pour
utiliser plusieurs cœurs. Et beaucoup de tâches sont I/O-bound :
100 requêtes HTTP qui prennent 500 ms chacune mettent quand même
50 s séquentiellement, mais ~500 ms en parallèle.

`babet.workers` spawn de vrais threads OS, chacun faisant
tourner son propre état Lua isolé, communiquant avec le parent
via les arguments passés et les valeurs de retour. Pas d'état
partagé signifie pas de locks, pas de data races — juste envoyer
du travail, récupérer des résultats.

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.workers.spawn(code, args?, opts?)` | `job` (userdata) \| `(nil, err)` |
| `job:join()` | `(true, result)` \| `(false, err)` — **bloquant**, voir piège ci-dessous |
| `job:poll()` | `string` — `"running"` \| `"done"` \| `"error"`, non-bloquant |
| `job:send(v, timeout?)` | `(true)` \| `(false, err)` — vers l'inbox du worker |
| `job:recv(timeout?)` | `(true, v)` \| `(false, err)` — depuis l'outbox du worker |
| `job:close()` | ferme les deux queues ; débloque worker et parent |

`opts` : `inbox_capacity` / `outbox_capacity` (entiers, défaut 64) —
tailles des files de messages.

`timeout` (secondes) pour `send`/`recv` : omis ou `nil` = blocage
indéfini ; `0` = non-bloquant (`err == "full"` / `"empty"`) ; sinon
attente bornée (`err == "timeout"`). Une queue fermée rend
`err == "closed"`. Côté worker, `worker.send(v, timeout?)` et
`worker.recv(timeout?)` sont symétriques.

**Piège `join()` : interblocage possible.** `join()` attend la fin
du worker sans échéance. Si le worker est bloqué dans un
`worker.recv()` sans timeout (il attend un message qui ne viendra
jamais), `join()` ne rend jamais la main — le parent et le worker
s'attendent mutuellement. Contrairement au ramasse-miettes (qui
ferme les queues avant de joindre), `join()` ne ferme rien. Règles
pratiques : appelle `job:close()` avant `join()` quand le worker
peut être en attente de message ; ou utilise des timeouts finis
dans les `worker.recv()` ; et `job:poll()` pour tester sans bloquer.

### Argument `code`

Une string source Lua qui tourne dans le worker. Le namespace
complet `babet` est disponible, plus une globale `worker` avec :

- `worker.args` — le deuxième argument passé à `spawn`.
- `worker.send(v, timeout?)` / `worker.recv(timeout?)` — le canal
  de messages vers/depuis le parent (mêmes conventions de timeout
  que côté parent, cf. table ci-dessus).

La valeur de la dernière expression du worker (ou `return value`)
est ce que `join()` renvoie comme `result`.

### Argument `args`

Toute valeur qui peut être deep-copiée entre états Lua : `nil`,
booleans, numbers, strings, tables des mêmes. **Pas** : fonctions,
userdata, threads, tables avec cycles. Les tables sont
deep-copiées — pas de partage. Profondeur maximale : **32
niveaux** d'imbrication (au-delà : `(nil, "workers: spawn: value
too deeply nested")`). Mêmes règles pour la valeur de retour du
worker et pour les messages `send`/`recv`.

## Exemples rapides

### Fetches HTTP parallèles

```lua
local urls = {
    "https://a.example/",
    "https://b.example/",
    "https://c.example/",
    "https://d.example/",
}

local jobs = {}
for i, url in ipairs(urls) do
    jobs[i] = babet.workers.spawn([[
        local url = worker.args.url
        local r, err = babet.http.get(url, { timeout = 10 })
        if not r then return { ok = false, err = err } end
        return { ok = true, status = r.status, length = #r.body }
    ]], { url = url })
end

for i, job in ipairs(jobs) do
    local ok, result = job:join()
    if ok then
        print(i, result.status or result.err)
    else
        print(i, "worker crashed :", result)
    end
end
```

### Travail CPU-bound avec cancellation

La cancellation est **coopérative**, construite avec le canal de
messages : le parent envoie `"stop"`, le worker vérifie son inbox
périodiquement avec `worker.recv(0)` (non bloquant).

```lua
local jobs = {}
for i = 1, 4 do
    jobs[i] = babet.workers.spawn([[
        local chunk = worker.args.chunk
        local total = 0
        for x = chunk.from, chunk.to do
            if x % 1000 == 0 then
                local got, msg = worker.recv(0) -- non bloquant
                if got and msg == "stop" then
                    return { cancelled = true, partial = total }
                end
            end
            total = total + heavy_compute(x)
        end
        return { total = total }
    ]], { chunk = { from = i * 1000, to = (i + 1) * 1000 - 1 } })
end

-- ... plus tard, si nécessaire :
-- for _, j in ipairs(jobs) do j:send("stop") end
-- puis join() pour récupérer les résultats partiels.
```

### Pattern pool de workers

```lua
local function map_parallel(items, code, max_concurrent)
    -- pas de cpu_count() en v1 : fixe une valeur, ou détecte :
    -- tonumber(babet.exec("nproc").stdout)
    max_concurrent = max_concurrent or 4
    local results = {}
    local i = 1
    local active = {}

    while i <= #items or next(active) do
        -- en lancer autant que possible
        while i <= #items and #active < max_concurrent do
            active[#active + 1] = {
                index = i,
                job = babet.workers.spawn(code, { item = items[i] }),
            }
            i = i + 1
        end
        -- moissonner les finis
        for k = #active, 1, -1 do
            local entry = active[k]
            if entry.job:poll() ~= "running" then
                local ok, result = entry.job:join()
                results[entry.index] = ok and result or { err = result }
                table.remove(active, k)
            end
        end
        if next(active) then babet.sleep(10, "ms") end
    end
    return results
end
```

## Contrat d'erreur

- **`spawn`** : `(nil, err)` si le thread OS ne peut pas être créé
  (rare — généralement des limites de ressources).
- **`join`** :
  - `(true, result)` — worker terminé normalement ; `result` est
    sa valeur de retour (ou `nil` s'il n'a pas retourné).
  - `(false, err)` — worker crashé avec une erreur non
    attrapée ; `err` est le message d'erreur + traceback.
  - `(false, "workers: join: result already consumed")` — `join`
    déjà appelé sur ce job.
  - `join()` n'a **pas** de timeout : il bloque jusqu'à la fin du
    worker (cf. le piège d'interblocage plus haut).
- **Mauvais types d'argument** → lève via `luaL_error`.

## Partage de données

Les workers ne partagent pas l'état Lua. La communication se fait :

- **En entrée** : via l'argument `args` de `spawn` (deep-copié
  dans l'état du worker).
- **En sortie** : via la valeur de retour du worker (deep-copiée
  en retour).
- **Effets de bord** : un worker peut écrire dans un fichier,
  appender dans un log, requêter une base de données — mais la
  coordination via ces effets de bord est la responsabilité du
  script.

Si deux workers écrivent dans le même fichier SQLite, positionne
`wal=true` à `open` pour qu'ils ne se verrouillent pas mutuellement.
SQLite gère la synchronisation correctement avec WAL ; dans
`busy_timeout` tu peux configurer combien de temps attendre sur
une db occupée.

## Décisions de design

- **Un état Lua par worker, pas de partage**. L'alternative —
  état partagé avec locks — est une source bien connue de bugs
  subtils et on ne pense pas que les locks niveau Lua valent le
  travail de design à ce niveau. Le message-passing pur est plus
  simple.
- **Pas de thread pool global**. Chaque `spawn` crée un nouveau
  thread OS, chaque `join` le ferme. Pour les boucles serrées,
  construis un pool en Lua (voir l'exemple ci-dessus). Le modèle
  plus simple gagne en lisibilité.
- **Le premier `spawn` verrouille `setenv` et `chdir`** —
  définitivement, même après `join`. L'environnement et le
  répertoire courant sont des états process-wide ; les muter
  pendant qu'un worker tourne est une course de données. Fixe-les
  avant le premier worker. Voir la note dans [sys](sys.md).
- **`babet.signal` n'est pas disponible dans les workers**.
  Les signaux sont process-wide ; seul le thread principal peut
  les gérer sensément.

## Hors v1

> Note (audit v21) : les éléments ci-dessous relèvent du design
> initial et ne sont **pas implémentés à ce jour** — l'ancienne
> version de cette page les présentait à tort comme disponibles :
> `job:join(timeout)`, `job:done()` (utiliser `job:poll()`),
> `job:cancel()` / `worker.cancelled()` (une cancellation
> coopérative peut se construire dès aujourd'hui avec
> `job:send("stop")` + un `worker.recv(0)` périodique), et
> `babet.workers.cpu_count()`.

- Channels **entre workers** (worker↔worker — le canal
  parent↔worker existe déjà : `send`/`recv`). À ajouter plus tard si un
  cas d'usage montre que le pattern est courant.
- Mémoire partagée (mmap). Idem.
- Futures I/O async (style `spawn().then(...)`). Hors scope ;
  utilise une boucle de polling avec `job:poll()`.
