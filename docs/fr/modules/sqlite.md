> [English](../../en/modules/sqlite.md) | **Français**

# `babet.sqlite` — base de données SQL embarquée

`babet.sqlite` embarque SQLite 3.53.1 et expose une API Lua complète mais
volontairement compacte : connexions en lecture/écriture ou lecture seule,
clés étrangères par connexion, compteurs de changements, exécution SQL
directe, itérateurs paresseux, statements préparés réutilisables, transactions
assistées, savepoints imbriqués et bind BLOB et `NULL` explicites.

## Table des matières du module

- [API](#sqlite-api)
  - [Ouverture et fermeture](#sqlite-open-close)
  - [Compteurs de connexion](#sqlite-counters)
  - [Exécution directe](#sqlite-direct)
  - [Statements préparés réutilisables](#sqlite-prepared)
  - [Transactions assistées](#sqlite-transactions)
  - [Savepoints imbriqués](#sqlite-savepoints)
  - [Paramètres SQL](#sqlite-parameters)
  - [Valeurs NULL explicites](#sqlite-nulls)
  - [BLOB explicites](#sqlite-blobs)
  - [Texte SQL et octets NUL](#sqlite-sql-text)
- [Lecture des lignes et mapping de types](#sqlite-rows)
- [Cycle de vie](#sqlite-lifetime)
- [Contrat d'erreur](#sqlite-errors)
- [Exemples complets](#sqlite-examples)
- [Fonctions non exposées](#sqlite-not-exposed)

<a id="sqlite-api"></a>
## API

<a id="sqlite-open-close"></a>
### Ouverture et fermeture

| Fonction | Renvoie |
| --- | --- |
| `babet.sqlite.open(path, opts?)` | `db` (userdata) \| `(nil, err)` |
| `babet.sqlite.blob(data)` | wrapper BLOB opaque |
| `babet.sqlite.NULL` | sentinelle lightuserdata exacte pour binder SQL `NULL` |
| `db:close()` | `(true, nil)` — idempotent |
| `db:in_transaction()` | boolean \| `(nil, err)` |
| `db:transaction(callback, mode?)` | `true, ...résultats_callback` \| `(nil, err)` |
| `db:savepoint(callback)` | `true, ...résultats_callback` \| `(nil, err)` |
| `db:last_insert_rowid()` | entier \| `(nil, err)` |
| `db:changes()` | entier \| `(nil, err)` |
| `db:total_changes()` | entier \| `(nil, err)` |

Par défaut, `open` ouvre ou crée une base en lecture/écriture. Avec
`readonly = true`, il ouvre une base existante sans la créer et SQLite refuse
les écritures. Le chemin spécial `":memory:"` crée une base uniquement en
mémoire, perdue à la fermeture. Le chemin doit être une chaîne sans octet NUL.

`opts` est une table facultative :

| Champ | Type | Défaut |
| --- | --- | --- |
| `wal` | boolean — demande `PRAGMA journal_mode=WAL` | `false` |
| `busy_timeout` | entier de `0` à `3600000` ms | `0` — aucun délai d'attente |
| `readonly` | boolean — ouverture sans création ni écriture | `false` |
| `foreign_keys` | boolean — impose les contraintes de clés étrangères | `false` |

`wal = true` demande le mode WAL, mais SQLite peut conserver un autre mode
lorsque WAL n'est pas applicable. C'est notamment le cas de `":memory:"`.

`busy_timeout` demande à SQLite de réessayer pendant la durée indiquée lorsque
la base est verrouillée. La valeur `0` laisse remonter immédiatement
`SQLITE_BUSY`.

`readonly = true` utilise le mode natif `SQLITE_OPEN_READONLY`. Une base
absente produit `(nil, err)` et aucun fichier n'est créé. Les lectures restent
autorisées ; une instruction d'écriture produit `(nil, err)`. Cette option se
combine avec `busy_timeout` et `foreign_keys`, mais pas avec `wal = true` : la
combinaison contradictoire lève une erreur Lua avant l'ouverture. Ce refus
concerne uniquement la demande de **passer** la base en mode WAL. Il n'empêche
pas `readonly = true` d'ouvrir une base qui utilise déjà WAL, sans fournir
`wal = true`. SQLite doit alors pouvoir utiliser les fichiers compagnons
`-wal` et `-shm` ; un système de fichiers entièrement en lecture seule peut
échouer si le fichier `-shm` nécessaire n'existe pas déjà ou n'est pas
utilisable.

`foreign_keys = true` active l'intégrité référentielle avant la première
instruction de la connexion. Le réglage est propre à chaque connexion et ne
valide pas rétroactivement les lignes déjà stockées. La valeur par défaut
`false` conserve le comportement SQLite historique de Babet.

Chaque option peut être utilisée seule. Pour définir uniquement l'attente sur
verrou :

```lua
local db = assert(babet.sqlite.open("state.db", { busy_timeout = 2500 }))
```

Pour demander WAL en gardant l'attente par défaut :

```lua
local db = assert(babet.sqlite.open("state.db", { wal = true }))
```

Pour ouvrir uniquement en lecture :

```lua
local db = assert(babet.sqlite.open("state.db", { readonly = true }))
```

Pour activer les clés étrangères sur une connexion d'écriture :

```lua
local db = assert(babet.sqlite.open("state.db", { foreign_keys = true }))
```

Pour combiner WAL, attente sur verrou et clés étrangères :

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2500,
    foreign_keys = true,
}))
```

La table `opts` est stricte : un champ inconnu, une clé d'option non chaîne,
un mauvais type ou un délai hors limites lève une erreur Lua. Les options sont
lues directement dans la table ; une métaméthode `__index` ne peut ni les
fournir ni les masquer. Les types et combinaisons incompatibles sont contrôlés
avant l'acquisition du handle natif. Une erreur de contrat ne crée donc ni
fichier ni connexion.

Pour un lecteur strict combinant les options compatibles :

```lua
local db = assert(babet.sqlite.open("state.db", {
    readonly = true,
    busy_timeout = 2500,
    foreign_keys = true,
}))
```

`db:in_transaction()` renvoie `true` dès que la connexion se trouve dans une
transaction, qu'elle ait été ouverte par `db:transaction()`, par un
`db:savepoint()` externe ou par un `BEGIN` SQL manuel.

<a id="sqlite-counters"></a>
### Compteurs de connexion

Les trois méthodes suivantes lisent directement l'état de la connexion. Elles
n'exécutent aucun SQL, renvoient toujours un entier Lua sur une connexion
ouverte et sont disponibles dans les workers.

#### `db:last_insert_rowid()`

Renvoie le ROWID du dernier `INSERT` réussi sur cette connexion, ou `0` tant
qu'aucun ROWID n'a été inséré. La valeur reste celle du dernier `INSERT`
concerné après un `SELECT`, un `UPDATE`, un `DELETE`, et même après le rollback
d'un `INSERT` qui avait réussi avant l'annulation.

```lua
local db = assert(babet.sqlite.open(":memory:"))
assert(db:exec("CREATE TABLE messages(id INTEGER PRIMARY KEY, body TEXT)"))
assert(db:exec("INSERT INTO messages(body) VALUES(?)", { "Bonjour" }))
local id = assert(db:last_insert_rowid())
print(id) -- 1
```

Une instruction réussie ne garantit pas qu'une ligne a été insérée. Avec
`INSERT OR IGNORE`, une contrainte peut être ignorée et
`last_insert_rowid()` conserve alors le ROWID précédent. Pour une insertion
d'une ligne qui peut être ignorée, vérifier `changes() == 1` avant le ROWID :

```lua
assert(db:exec("INSERT OR IGNORE INTO messages(body) VALUES(?)",
    { "message unique" }))
assert(db:changes() == 1, "message non inséré")
local id = assert(db:last_insert_rowid())
```

#### `db:changes()`

Renvoie le nombre de lignes modifiées par le dernier `INSERT`, `UPDATE` ou
`DELETE` terminé sur cette connexion. Les modifications auxiliaires de
triggers, d'actions de clés étrangères ou de la résolution `REPLACE` ne sont
pas incluses dans ce compteur du dernier statement.

```lua
assert(db:exec(
    "UPDATE messages SET body = ? WHERE id IN (?, ?)",
    { "archivé", 1, 2 }
))
print(assert(db:changes())) -- 0, 1 ou 2 selon les lignes présentes
```

#### `db:total_changes()`

Renvoie le cumul des lignes modifiées depuis l'ouverture de la connexion. Ce
cumul inclut les changements produits par les triggers et les actions de clés
étrangères, mais pas les suppressions internes de `REPLACE`. Il repart de zéro
pour chaque nouvelle connexion.

```lua
local before = assert(db:total_changes())
assert(db:exec("INSERT INTO messages(body) VALUES ('un'), ('deux')"))
local delta = assert(db:total_changes()) - before
assert(delta == 2)
```

Pour utiliser les trois compteurs ensemble après une insertion :

```lua
assert(db:exec("INSERT INTO messages(body) VALUES(?)", { "nouveau" }))
local id = assert(db:last_insert_rowid())
local statement_rows = assert(db:changes())
local connection_rows = assert(db:total_changes())
print(id, statement_rows, connection_rows)
```

Ces valeurs appartiennent uniquement au handle `db` courant : une autre
connexion, y compris dans un autre worker, possède ses propres compteurs. Après
`db:close()`, les trois méthodes renvoient `(nil, "sqlite: connection closed")`.

<a id="sqlite-direct"></a>
### Exécution directe

| Fonction | Renvoie |
| --- | --- |
| `db:exec(sql)` | `(true, nil)` \| `(nil, err)` — plusieurs instructions acceptées |
| `db:exec(sql, params)` | `(true, nil)` \| `(nil, err)` — **une seule** instruction |
| `db:query(sql, params?)` | `stmt` temporaire appelable \| `(nil, err)` |
| `stmt:close()` | `(true, nil)` — idempotent |

#### `db:exec`

Sans table `params`, `exec` accepte plusieurs instructions séparées par des
points-virgules. Elles sont préparées et exécutées dans l'ordre. L'exécution
s'arrête à la première erreur ; les instructions précédentes restent acquises
si elles ne se trouvaient pas dans une transaction explicite.

Avec une table `params`, une seule instruction est acceptée. Les espaces,
points-virgules et commentaires SQL finaux (`-- ...` ou `/* ... */`) ne
comptent pas comme une seconde instruction.

Un `SELECT` passé à `exec` est exécuté jusqu'au bout, mais ses lignes sont
ignorées. Une chaîne SQL vide ou composée uniquement de séparateurs et de
commentaires est un no-op réussi avec `exec(sql)` ou `exec(sql, {})`.

#### `db:query`

`query` prépare immédiatement une instruction et renvoie un **itérateur
appelable à usage unique**. L'instruction n'est exécutée qu'au premier appel :

```lua
for row in db:query("SELECT id, name FROM users ORDER BY id") do
    print(row.id, row.name)
end
```

Chaque ligne est une table indexée par nom de colonne. L'itérateur renvoie
`nil` une fois épuisé puis finalise automatiquement son statement.
`stmt:close()` permet de le libérer plus tôt. Le ramasse-miettes finalise aussi
un itérateur abandonné après un `break`.

`query` n'est pas limité aux `SELECT`. Une instruction DDL ou DML est exécutée
au premier appel, puis l'itérateur se termine sans produire de ligne.

Un SQL multi-instructions est refusé. Un SQL vide ou composé seulement de
commentaires produit un itérateur déjà épuisé.

<a id="sqlite-prepared"></a>
### Statements préparés réutilisables

| Fonction | Renvoie |
| --- | --- |
| `db:prepare(sql)` | `prepared` \| `(nil, err)` |
| `prepared:exec(params?)` | `(true, nil)` \| `(nil, err)` |
| `prepared:query(params?)` | le même userdata `prepared` \| `(nil, err)` |
| `prepared:reset()` | `(true, nil)` \| `(nil, err)` |
| `prepared:close()` | `(true, nil)` — idempotent |
| `prepared:finalize()` | alias de `close()` |

`db:prepare()` accepte exactement **une instruction SQL non vide**. La
préparation est immédiate : une table ou une colonne inconnue est donc signalée
avant la première exécution.

Le statement peut ensuite être réutilisé autant de fois que nécessaire :

```lua
local insert = assert(db:prepare(
    "INSERT INTO files(path, digest) VALUES(?, ?)"
))

for _, file in ipairs(files) do
    assert(insert:exec({ file.path, file.digest }))
end

assert(insert:finalize())
```

`prepared:exec()` réinitialise automatiquement le statement avant le bind,
l'exécute jusqu'à `SQLITE_DONE`, puis efface les bindings. Un `SELECT` est
entièrement parcouru mais ses lignes sont ignorées.

`prepared:query()` réinitialise et bind le statement, puis renvoie **le même
userdata**, rendu appelable par sa métatable :

```lua
local select_by_age = assert(db:prepare([[
    SELECT id, name FROM users
    WHERE age >= ?
    ORDER BY id
]]))

for row in select_by_age:query({ 18 }) do
    print(row.id, row.name)
end

for row in select_by_age:query({ 65 }) do
    print("senior", row.name)
end
```

À l'épuisement naturel, le statement est automatiquement réinitialisé et ses
bindings sont effacés. Après un `break`, trois choix sont possibles :

- appeler `prepared:reset()` ;
- démarrer un nouveau `prepared:query(...)` ;
- appeler `prepared:exec(...)`.

Les deux dernières opérations réinitialisent aussi automatiquement l'itération
précédente et abandonnent ses lignes restantes. Un statement préparé ne peut
avoir qu'une seule itération active à la fois : réutiliser le même userdata
dans une boucle imbriquée réinitialise donc la boucle extérieure.

Un appel direct `prepared()` sans `prepared:query()` actif renvoie simplement
`nil` et n'exécute jamais le SQL avec des bindings effacés.

`prepared:reset()` interrompt l'exécution courante et efface les bindings.
`close()` et `finalize()` finalisent définitivement le statement. Une fois
fermé, son appel direct renvoie `nil`, tandis que ses méthodes d'exécution
renvoient `(nil, "sqlite: statement closed")`.

<a id="sqlite-transactions"></a>
### Transactions assistées

```lua
local ok, result = db:transaction(function(tx)
    assert(tx:exec(
        "INSERT INTO accounts(name, balance) VALUES(?, ?)",
        { "alice", 100 }
    ))

    assert(tx:exec(
        "INSERT INTO audit(message) VALUES(?)",
        { "account created" }
    ))

    return "created"
end, "immediate")

assert(ok, result)
print(result) -- "created"
```

Signature :

```lua
ok, ...callback_results = db:transaction(callback [, mode])
-- ou
nil, err = db:transaction(callback [, mode])
```

Le callback reçoit la connexion `db` comme unique argument. `mode` vaut :

- `"deferred"` — défaut ;
- `"immediate"` ;
- `"exclusive"`.

Si le callback se termine normalement, Babet exécute `COMMIT` et renvoie
`true`, suivi de toutes les valeurs du callback. Un retour normal `nil` ou
`false` **ne demande pas un rollback** : seule une erreur Lua déclenche le
rollback automatique.

Les opérations SQLite renvoyant habituellement `(nil, err)`, utilise `assert`
dans le callback pour transformer une erreur opérationnelle en erreur Lua :

```lua
local ok, err = db:transaction(function(tx)
    assert(tx:exec("INSERT INTO unique_names VALUES(?)", { "alice" }))
    assert(tx:exec("INSERT INTO unique_names VALUES(?)", { "alice" }))
end)

-- Le second INSERT échoue, assert lève, et les deux INSERT sont annulés.
```

Une erreur du callback est interceptée : Babet tente `ROLLBACK` puis renvoie
`(nil, "sqlite: transaction callback failed: ...")`. Elle n'est pas relancée.
Un échec de `COMMIT` renvoie également `(nil, err)` après une tentative de
rollback. Les valeurs éventuellement renvoyées par le callback sont alors
abandonnées.

Après un `BEGIN` réussi, Babet possède explicitement la transaction jusqu'au
`COMMIT` ou au `ROLLBACK`. La pile Lua nécessaire à l'appel du callback est
réservée avant `BEGIN` ; une exception C++ interne déclenche également une
tentative immédiate de rollback. Le diagnostic du callback n'est formaté
qu'après cette tentative, afin qu'un objet d'erreur Lua inhabituel ne puisse
laisser la connexion dans un état intermédiaire.

Si le rollback normal échoue, le message contient à la fois l'erreur initiale
et l'erreur de rollback, puis Babet effectue une dernière tentative d'urgence.
Après une erreur, `db:in_transaction()` permet de vérifier explicitement que la
connexion est revenue en mode autocommit avant de poursuivre.

#### Exemple : échec au moment du commit

Une contrainte différée peut n'être vérifiée qu'au `COMMIT` :

```lua
local db = assert(babet.sqlite.open(
    ":memory:", { foreign_keys = true }))
assert(db:exec([[
    CREATE TABLE parent(id INTEGER PRIMARY KEY);
    CREATE TABLE child(
        id INTEGER PRIMARY KEY,
        parent_id INTEGER NOT NULL,
        FOREIGN KEY(parent_id) REFERENCES parent(id)
            DEFERRABLE INITIALLY DEFERRED
    )
]]))

local ok, err = db:transaction(function(tx)
    assert(tx:exec(
        "INSERT INTO child(id, parent_id) VALUES(?, ?)",
        { 1, 999 }))
    return "ce résultat ne sera pas renvoyé"
end)

assert(ok == nil)
assert(type(err) == "string")
assert(db:in_transaction() == false)
```

L'`INSERT` est annulé et la connexion reste réutilisable si le rollback a
réussi.

#### Exemple : réutiliser un statement préparé après rollback

```lua
local insert = assert(db:prepare(
    "INSERT INTO journal(id, valeur) VALUES(?, ?)"))

local ok, err = db:transaction(function()
    assert(insert:exec({ 1, "annulé" }))
    error("échec volontaire")
end)

assert(ok == nil and type(err) == "string")
assert(insert:exec({ 2, "conservé" }))
insert:finalize()
```

Le rollback réinitialise l'état transactionnel de SQLite ; le statement
préparé peut ensuite être réutilisé normalement.

Limitations volontaires :

- les appels imbriqués à `db:transaction()` sont refusés ;
- la fonction est refusée si une transaction SQL manuelle est déjà active ;
- `db:close()` est refusé pendant le callback ;
- le callback ne doit pas exécuter lui-même `BEGIN`, `COMMIT` ou `ROLLBACK`.

Utilise `db:savepoint()` pour des portées imbriquées assistées. Les savepoints
SQL bruts restent accessibles lorsqu'un identifiant explicite ou un contrôle
manuel est nécessaire.

<!-- pdf-page-break -->

<a id="sqlite-savepoints"></a>
### Savepoints imbriqués

Signature :

```lua
true, ...résultats_callback = db:savepoint(callback)
-- ou
nil, err = db:savepoint(callback)
```

Le callback reçoit la même connexion ouverte comme unique argument. Babet
génère l'identifiant SQL en interne ; l'API n'accepte aucun nom et ne peut donc
pas injecter de texte fourni par l'appelant dans `SAVEPOINT`, `ROLLBACK TO` ou
`RELEASE`.

Si le callback se termine normalement, Babet exécute `RELEASE` et renvoie
`true`, suivi de toutes les valeurs du callback. `nil` et `false` explicites
sont des résultats normaux et ne demandent pas de rollback. Sur erreur Lua,
Babet exécute `ROLLBACK TO` puis `RELEASE`, intercepte l'erreur et renvoie
`(nil, "sqlite: savepoint callback failed: ...")`.

#### Exemple : savepoint autonome

Hors transaction, le savepoint le plus externe démarre une transaction. Son
`RELEASE` valide le travail isolé et rétablit le mode autocommit :

```lua
local ok, id = db:savepoint(function(tx)
    assert(tx:exec(
        "INSERT INTO jobs(name) VALUES(?)",
        { "index" }))
    return assert(tx:last_insert_rowid())
end)

assert(ok, id)
assert(db:in_transaction() == false)
```

#### Exemple : rollback sur erreur du callback

Utilise `assert` sur les opérations SQLite dont l'échec doit annuler la portée :

```lua
local ok, err = db:savepoint(function(tx)
    assert(tx:exec(
        "INSERT INTO unique_names(name) VALUES(?)",
        { "alice" }))
    assert(tx:exec(
        "INSERT INTO unique_names(name) VALUES(?)",
        { "alice" }))
end)

assert(ok == nil)
assert(type(err) == "string")
-- Aucun INSERT ne reste et la connexion peut être réutilisée.
```

<!-- pdf-page-break -->

#### Exemple : récupérer l'échec d'une portée interne

Les helpers peuvent être imbriqués. Une portée interne en échec revient à son
propre marqueur ; le callback externe peut examiner l'erreur et continuer :

```lua
local ok, inner_err = db:savepoint(function(tx)
    assert(tx:exec("INSERT INTO audit(message) VALUES('avant')"))

    local inner_ok, err = tx:savepoint(function(inner)
        assert(inner:exec("INSERT INTO audit(message) VALUES('facultatif')"))
        error("annuler le travail facultatif")
    end)
    assert(inner_ok == nil)

    assert(tx:exec("INSERT INTO audit(message) VALUES('après')"))
    return err
end)

assert(ok, inner_err)
-- « avant » et « après » restent ; « facultatif » a été annulé.
```

Une erreur ultérieure du callback externe annule également tout savepoint
interne déjà libéré. `RELEASE` fusionne le travail interne avec la portée
englobante ; il ne rend jamais ce travail indépendant de la transaction
externe.

#### Exemple : dans une transaction assistée

`db:savepoint()` est autorisé dans `db:transaction()`, contrairement à un
second helper de transaction :

```lua
local ok, err = db:transaction(function(tx)
    assert(tx:exec("INSERT INTO audit(message) VALUES('obligatoire')"))

    local optional_ok = tx:savepoint(function(inner)
        assert(inner:exec("INSERT INTO audit(message) VALUES('facultatif')"))
    end)
    if not optional_ok then
        assert(tx:exec("INSERT INTO audit(message) VALUES('échec facultatif')"))
    end

    assert(tx:in_transaction() == true)
end, "immediate")

assert(ok, err)
```

Le `RELEASE` interne ne valide **pas** la transaction assistée. Si le callback
externe échoue ensuite, `db:transaction()` annule l'écriture obligatoire et
toutes les écritures internes déjà libérées.

#### Exemple : dans une transaction manuelle

```lua
assert(db:exec("BEGIN"))

local ok, err = db:savepoint(function(tx)
    assert(tx:exec("UPDATE accounts SET balance = balance - 10 WHERE id = 1"))
end)
assert(ok, err)
assert(db:in_transaction() == true)

assert(db:exec("ROLLBACK")) -- annule aussi le travail du savepoint libéré
```

<!-- pdf-page-break -->

#### Exemple : échec du `RELEASE` du savepoint externe

Une contrainte différée peut n'être contrôlée que lorsque le `RELEASE` externe
tente de valider. Les résultats du callback sont abandonnés, Babet revient au
savepoint, le retire et renvoie l'erreur du `RELEASE` :

```lua
local db = assert(babet.sqlite.open(
    ":memory:", { foreign_keys = true }))
assert(db:exec([[
    CREATE TABLE parent(id INTEGER PRIMARY KEY);
    CREATE TABLE child(
        id INTEGER PRIMARY KEY,
        parent_id INTEGER REFERENCES parent(id)
            DEFERRABLE INITIALLY DEFERRED
    )
]]))

local ok, err, leaked = db:savepoint(function(tx)
    assert(tx:exec("INSERT INTO child VALUES(1, 999)"))
    return "ne doit pas être renvoyé"
end)

assert(ok == nil and type(err) == "string")
assert(leaked == nil)
assert(db:in_transaction() == false)
```

Dans une transaction existante, libérer un savepoint interne n'exécute pas le
commit externe : l'éventuelle erreur différée reste donc du ressort du futur
`COMMIT` de cette transaction.

Le helper suit la profondeur sur chaque connexion et fonctionne dans les
workers. `db:close()` est refusé pendant tout callback de savepoint. La pile Lua
est réservée avant l'ouverture ; une garde C++ sans allocation tente un
`ROLLBACK TO` puis un `RELEASE` d'urgence si une exception interne survient.

Ne mélange pas de commandes manuelles de transaction ou de savepoint dans le
callback. En particulier, un `ROLLBACK` ou `COMMIT` complet détruit le
savepoint assisté. Babet détecte le retour en autocommit, abandonne les
résultats du callback, évite les commandes de nettoyage redondantes et renvoie
une seule erreur stable sans exposer l'identifiant généré. Un `ROLLBACK` laisse
la connexion réutilisable après avoir annulé les écritures du callback ; un
`COMMIT` peut déjà les avoir validées avant que Babet ne diagnostique la
violation du contrat. Utilise des appels `db:savepoint()` imbriqués pour les
portées internes récupérables.

<a id="sqlite-parameters"></a>
### Paramètres SQL

Les formes suivantes sont prises en charge par `exec`, `query` et les
statements préparés :

| Placeholder | Valeur Lua |
| --- | --- |
| `?` | `params[1]`, `params[2]`, etc., selon l'ordre des `?` |
| `:name`, `@name`, `$name` | `params.name` — le préfixe est retiré |

Les paramètres positionnels et nommés peuvent être mélangés :

```lua
assert(db:exec(
    "INSERT INTO events VALUES (?, :kind, ?)",
    { 42, 1700000000, kind = "start" }
))
```

La table doit correspondre exactement aux placeholders. Un paramètre manquant,
en trop, un index numérique sparse, un index numérique non entier, un type de
clé non supporté ou une valeur non supportée lève une erreur Lua. Passer
explicitement `nil` comme table équivaut à ne pas fournir de paramètres ; ce
n'est pas une valeur de bind.

Les paramètres nommés sont lus directement dans la table. Une valeur fournie
par `__index` ne compte pas et une erreur de cette métaméthode ne sera jamais
déclenchée par le bind. Les placeholders numérotés `?NNN` sont explicitement
refusés ; utilise des `?` anonymes dans leur ordre naturel.

Types acceptés au bind :

| Type Lua | Valeur SQLite |
| --- | --- |
| boolean | INTEGER `0` ou `1` |
| integer | INTEGER, sur toute la plage signée 64 bits |
| number non entier fini | REAL |
| string | TEXT, y compris avec des octets NUL |
| `babet.sqlite.blob(data)` | BLOB binary-safe |
| `babet.sqlite.NULL` | SQL `NULL` |

NaN et les infinis positif ou négatif sont refusés au lieu d'être transmis à
SQLite avec un résultat dépendant de la plateforme.

<a id="sqlite-nulls"></a>
### Valeurs NULL explicites

Lua ne peut pas conserver `nil` dans une table de paramètres : lui affecter
`nil` supprime la clé. Utilise l'unique sentinelle `babet.sqlite.NULL` lorsqu'un
placeholder doit être bindé à SQL `NULL`.

Valeur optionnelle nommée :

```lua
local NULL = babet.sqlite.NULL

assert(db:exec([[
    INSERT INTO users(name, nickname)
    VALUES(:name, :nickname)
]], {
    name = "Ada",
    nickname = NULL,
}))
```

`NULL` positionnel au milieu d'une liste de paramètres :

```lua
assert(db:exec(
    "INSERT INTO events(id, payload, created_at) VALUES(?, ?, ?)",
    { 17, babet.sqlite.NULL, 1700000000 }
))
```

La sentinelle fonctionne de la même manière avec les statements réutilisables
et peut alterner entre des valeurs ordinaires et `NULL` :

```lua
local update = assert(db:prepare(
    "UPDATE users SET nickname = ? WHERE name = ?"
))

assert(update:exec({ "Comtesse", "Ada" }))
assert(update:exec({ babet.sqlite.NULL, "Ada" }))
assert(update:finalize())
```

Le bind et la lecture sont volontairement asymétriques :

| Valeur Lua au bind | Stockage SQLite | Valeur Lua lue |
| --- | --- | --- |
| `true` | INTEGER `1` | integer `1` |
| `false` | INTEGER `0` | integer `0` |
| `babet.sqlite.NULL` | `NULL` | `nil` / clé absente |

SQLite ne possède pas de classe de stockage booléenne : les entiers sont donc
relus comme des entiers et Babet ne déduit pas un boolean de `0` ou `1`. Un
résultat `NULL` ne crée aucune clé dans la table ligne : `row.colonne == nil`
et la clé est également absente de `pairs(row)`.

`babet.sqlite.NULL` est accepté uniquement comme valeur de bind SQLite. Les
autres lightuserdata sont refusés. L'encodage JSON et le transfert vers les
workers ou les channels refusent aussi cette sentinelle avec un diagnostic
explicite, afin qu'une valeur opaque ressemblant à un pointeur ne franchisse
jamais silencieusement les frontières entre sous-systèmes.

<a id="sqlite-blobs"></a>
### BLOB explicites

Une chaîne Lua ordinaire reste **toujours** bindée avec
`sqlite3_bind_text`, même si la colonne possède une affinité `BLOB`.
`babet.sqlite.blob(data)` marque explicitement les mêmes octets comme BLOB :

```lua
local insert = assert(db:prepare(
    "INSERT INTO assets(name, payload) VALUES(?, ?)"
))

assert(insert:exec({
    "icon",
    babet.sqlite.blob("\x89PNG\r\n\x1a\n...")
}))
```

Le constructeur exige exactement une chaîne Lua et renvoie un userdata opaque.
Les octets NUL sont conservés. `babet.sqlite.blob("")` produit bien un BLOB de
zéro octet, et non `NULL`.

Le wrapper ne sert qu'au bind ; la lecture d'une colonne BLOB renvoie toujours
une chaîne Lua binary-safe.

<a id="sqlite-sql-text"></a>
### Texte SQL et octets NUL

Le texte SQL doit être une chaîne sans octet NUL. SQLite considérerait ce NUL
comme une fin de chaîne et pourrait n'exécuter qu'un préfixe ; Babet refuse donc
la requête avant toute préparation. La taille du SQL est également limitée à
`INT_MAX` octets, conformément à `sqlite3_prepare_v2`.

Cette restriction concerne seulement le **texte SQL**. Les chaînes et BLOB
bindés sont binary-safe.

<a id="sqlite-rows"></a>
## Lecture des lignes et mapping de types

| Type SQLite lu | Type Lua |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | string binary-safe, y compris pour un BLOB vide |
| NULL | clé absente de la table (`row.col == nil` et absente de `pairs`) |

Si plusieurs colonnes portent le même nom, la dernière colonne gagne. Utilise
des alias pour conserver toutes les valeurs.

La fonction SQL `length()` compte les caractères d'un TEXT et peut s'arrêter à
un octet NUL. Pour compter ses octets lors d'un diagnostic, utilise par exemple
`length(CAST(col AS BLOB))`.

<a id="sqlite-lifetime"></a>
## Cycle de vie

`db:close()` est idempotent. Après fermeture, toute nouvelle opération comme
`exec`, `query`, `prepare`, `transaction`, `savepoint` et `in_transaction` renvoient
`(nil, "sqlite: connection closed")`.

Un itérateur ou un statement préparé créé **avant** `db:close()` reste
cependant utilisable. Babet emploie `sqlite3_close_v2` : SQLite conserve une
connexion « zombie » jusqu'à la finalisation du dernier statement actif.

```lua
local stmt = assert(db:prepare("SELECT id FROM users ORDER BY id"))
assert(db:close())

for row in stmt:query() do
    print(row.id)
end

stmt:finalize()
```

Les itérateurs temporaires de `db:query` et les statements préparés possèdent
un `__gc` qui finalise leur handle. Une fermeture explicite reste préférable
pour libérer immédiatement verrous et ressources.

Les statements ne conservent volontairement ni référence Lua ni pointeur
`Db*` brut vers le userdata parent. SQLite maintient lui-même la connexion
native zombie en vie ; cela évite un pointeur C++ devenu invalide et permet au
userdata `db` d'être collecté indépendamment.

<a id="sqlite-errors"></a>
## Contrat d'erreur

Les erreurs se répartissent en deux catégories :

- les erreurs opérationnelles (`open`, préparation, `step`, transaction,
  connexion fermée) renvoient généralement `(nil, "sqlite: <description>")` ;
- les mauvais types, les arités invalides et les tables `params` incorrectes
  lèvent une erreur Lua.

Toutes les fonctions publiques vérifient leur arité exacte. Les erreurs de
contrat des paramètres couvrent aussi `?NNN`, les REAL non finis, les
lightuserdata étrangers et les tables d'options ou de paramètres contenant
des clés non supportées.

`opts.readonly`, `opts.foreign_keys` et `opts.wal` exigent des booleans Lua
stricts. La combinaison `readonly = true, wal = true` lève une erreur de
contrat. Une base absente ouverte en lecture seule, une écriture via une
connexion en lecture seule ou une violation de clé étrangère sont des erreurs
opérationnelles et renvoient `(nil, err)`.

Les erreurs survenant pendant l'appel d'un itérateur (`db:query` ou
`prepared:query`) lèvent une erreur Lua, car le protocole d'itération ne permet
pas de renvoyer proprement `(nil, err)` en plus de la fin de séquence.

Sans table `params`, la présence d'un placeholder est détectée avant
l'exécution. Babet refuse de laisser SQLite binder silencieusement `NULL`.

`db:transaction()` et `db:savepoint()` constituent des exceptions contrôlées :
ils interceptent les erreurs Lua du callback, annulent la portée qu'ils
possèdent et convertissent l'erreur en `(nil, err)`.

<a id="sqlite-examples"></a>
## Exemples complets

### Inserts préparés, NULL optionnel et BLOB

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
}))

assert(db:exec([[
    CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        digest BLOB NOT NULL,
        media_type TEXT
    )
]]))

local insert = assert(db:prepare([[
    INSERT INTO files(path, digest, media_type)
    VALUES(?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
        digest = excluded.digest,
        media_type = excluded.media_type
]]))

for _, file in ipairs(files) do
    assert(insert:exec({
        file.path,
        babet.sqlite.blob(file.digest),
        file.media_type or babet.sqlite.NULL,
    }))
end

insert:finalize()
```

### Requête réutilisable et transaction

```lua
local by_prefix = assert(db:prepare([[
    SELECT path, digest
    FROM files
    WHERE path LIKE ?
    ORDER BY path
]]))

local ok, count = db:transaction(function(tx)
    local n = 0
    for row in by_prefix:query({ "images/%" }) do
        assert(tx:exec(
            "INSERT INTO audit(path) VALUES(?)",
            { row.path }
        ))
        n = n + 1
    end
    return n
end, "immediate")

assert(ok, count)
print(count, "rows audited")

by_prefix:finalize()
assert(db:close())
```

<a id="sqlite-not-exposed"></a>
## Fonctions non exposées

Les éléments suivants ne sont volontairement pas implémentés :

- le mode URI et les autres flags avancés de `sqlite3_open_v2` ;
- les APIs de progress handler et d'interruption ;
- l'API de streaming BLOB `sqlite3_blob_open` ;
- l'API de sauvegarde `sqlite3_backup_init`.

Les savepoints SQL bruts et `VACUUM INTO` restent accessibles. FTS5 et R-Tree
ne sont pas activés dans la compilation embarquée actuelle.
