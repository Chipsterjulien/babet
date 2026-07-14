> [English](../../en/modules/sqlite.md) | **Français**

# `babet.sqlite` — base de données SQL embarquée

`babet.sqlite` embarque SQLite 3.53.1 et expose une API Lua complète mais
volontairement compacte : connexions, exécution SQL directe, itérateurs
paresseux, statements préparés réutilisables, transactions assistées et bind
BLOB explicite.

## Table des matières du module

- [API](#sqlite-api)
  - [Ouverture et fermeture](#sqlite-open-close)
  - [Exécution directe](#sqlite-direct)
  - [Statements préparés réutilisables](#sqlite-prepared)
  - [Transactions assistées](#sqlite-transactions)
  - [Paramètres SQL](#sqlite-parameters)
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
| `db:close()` | `(true, nil)` — idempotent |
| `db:in_transaction()` | boolean \| `(nil, err)` |

`open` ouvre ou crée une base en lecture/écriture. Le chemin spécial
`":memory:"` crée une base uniquement en mémoire, perdue à la fermeture.
Le chemin doit être une chaîne sans octet NUL.

`opts` est une table facultative :

| Champ | Type | Défaut |
| --- | --- | --- |
| `wal` | boolean — demande `PRAGMA journal_mode=WAL` | `false` |
| `busy_timeout` | entier de `0` à `3600000` ms | `0` — aucun délai d'attente |

`wal = true` demande le mode WAL, mais SQLite peut conserver un autre mode
lorsque WAL n'est pas applicable. C'est notamment le cas de `":memory:"`.

`busy_timeout` demande à SQLite de réessayer pendant la durée indiquée lorsque
la base est verrouillée. La valeur `0` laisse remonter immédiatement
`SQLITE_BUSY`.

`db:in_transaction()` renvoie `true` dès que la connexion se trouve dans une
transaction, qu'elle ait été ouverte par `db:transaction()` ou par un
`BEGIN` SQL manuel.

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
rollback.

Limitations volontaires :

- les appels imbriqués à `db:transaction()` sont refusés ;
- la fonction est refusée si une transaction SQL manuelle est déjà active ;
- `db:close()` est refusé pendant le callback ;
- le callback ne doit pas exécuter lui-même `BEGIN`, `COMMIT` ou `ROLLBACK`.

Les savepoints restent accessibles par SQL brut.

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
en trop, un index numérique sparse, un index numérique non entier ou une
valeur non supportée lève une erreur Lua. Passer explicitement `nil` comme
table équivaut à ne pas fournir de paramètres.

Les placeholders numérotés `?NNN` ne font pas partie du contrat public.

Types acceptés au bind :

| Type Lua | Valeur SQLite |
| --- | --- |
| boolean | INTEGER `0` ou `1` |
| integer | INTEGER |
| number non entier | REAL |
| string | TEXT, y compris avec des octets NUL |
| `babet.sqlite.blob(data)` | BLOB binary-safe |

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

Il n'existe pas encore de sentinelle pour binder explicitement `NULL`. Utilise
le littéral SQL `NULL` lorsque nécessaire.

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

`db:close()` est idempotent. Après fermeture, toute nouvelle opération sur la
connexion renvoie `(nil, "sqlite: connection closed")`.

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

<a id="sqlite-errors"></a>
## Contrat d'erreur

Les erreurs se répartissent en deux catégories :

- les erreurs opérationnelles (`open`, préparation, `step`, transaction,
  connexion fermée) renvoient généralement `(nil, "sqlite: <description>")` ;
- les mauvais types, les arités invalides et les tables `params` incorrectes
  lèvent une erreur Lua.

Les erreurs survenant pendant l'appel d'un itérateur (`db:query` ou
`prepared:query`) lèvent une erreur Lua, car le protocole d'itération ne permet
pas de renvoyer proprement `(nil, err)` en plus de la fin de séquence.

Sans table `params`, la présence d'un placeholder est détectée avant
l'exécution. Babet refuse de laisser SQLite binder silencieusement `NULL`.

`db:transaction()` constitue une exception contrôlée : il intercepte les
erreurs Lua du callback, effectue le rollback et les convertit en `(nil, err)`.

<a id="sqlite-examples"></a>
## Exemples complets

### Inserts préparés et BLOB

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
}))

assert(db:exec([[
    CREATE TABLE IF NOT EXISTS files (
        path TEXT PRIMARY KEY,
        digest BLOB NOT NULL
    )
]]))

local insert = assert(db:prepare([[
    INSERT INTO files(path, digest)
    VALUES(?, ?)
    ON CONFLICT(path) DO UPDATE SET digest = excluded.digest
]]))

for _, file in ipairs(files) do
    assert(insert:exec({
        file.path,
        babet.sqlite.blob(file.digest),
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

Les éléments suivants ne sont pas implémentés :

- une sentinelle `sqlite.NULL` pour binder explicitement `NULL` ;
- `db:last_insert_rowid()` et `db:changes()` ;
- `opts.readonly` et `opts.foreign_keys` ;
- un helper de savepoint imbriqué ;
- l'API de streaming BLOB `sqlite3_blob_open` ;
- l'API de sauvegarde `sqlite3_backup_init`.

`last_insert_rowid`, `changes`, les clés étrangères, les savepoints et
`VACUUM INTO` restent accessibles par SQL brut. FTS5 et R-Tree ne sont pas
activés dans la compilation embarquée actuelle.
