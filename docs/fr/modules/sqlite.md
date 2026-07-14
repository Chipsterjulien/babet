> [English](../../en/modules/sqlite.md) | **Français**

# `babet.sqlite` — base de données SQL embarquée

`babet.sqlite` embarque SQLite 3.53.1 et expose une API Lua volontairement
réduite : ouverture d'une connexion, exécution SQL et parcours paresseux des
résultats. Les statements préparés restent internes ; `prepare`, `step` et
`finalize` ne sont pas exposés.

## Table des matières du module

- [API](#sqlite-api)
  - [Ouverture et fermeture](#sqlite-open-close)
  - [Exécution](#sqlite-exec)
  - [Paramètres SQL](#sqlite-parameters)
  - [Texte SQL et octets NUL](#sqlite-sql-text)
- [Lecture des lignes et mapping de types](#sqlite-rows)
- [Cycle de vie](#sqlite-lifetime)
- [Contrat d'erreur](#sqlite-errors)
- [Exemple complet](#sqlite-example)
- [Non exposé en v1](#sqlite-not-exposed)

<a id="sqlite-api"></a>
## API

<a id="sqlite-open-close"></a>
### Ouverture et fermeture

| Fonction | Renvoie |
| --- | --- |
| `babet.sqlite.open(path, opts?)` | `db` (userdata) \| `(nil, err)` |
| `db:close()` | `(true, nil)` — idempotent |

`open` ouvre ou crée une base en lecture/écriture. Le chemin spécial
`":memory:"` crée une base uniquement en mémoire, perdue à la fermeture.
Le chemin doit être une chaîne sans octet NUL.

`opts` est une table facultative :

| Champ | Type | Défaut |
| --- | --- | --- |
| `wal` | boolean — demande `PRAGMA journal_mode=WAL` | `false` |
| `busy_timeout` | entier de `0` à `3600000` ms | `0` — aucun délai d'attente |

`wal = true` demande le mode WAL, mais SQLite peut conserver un autre mode
lorsque WAL n'est pas applicable. C'est notamment le cas de `":memory:"`, qui
utilise son mode de journalisation en mémoire sans que l'ouverture échoue.

`busy_timeout` demande à SQLite de réessayer pendant la durée indiquée lorsque
la base est verrouillée. La valeur `0` laisse remonter immédiatement
`SQLITE_BUSY`.

<a id="sqlite-exec"></a>
### Exécution

| Fonction | Renvoie |
| --- | --- |
| `db:exec(sql)` | `(true, nil)` \| `(nil, err)` — plusieurs instructions acceptées |
| `db:exec(sql, params)` | `(true, nil)` \| `(nil, err)` — **une seule** instruction |
| `db:query(sql, params?)` | `stmt` (itérateur appelable) \| `(nil, err)` — **une seule** instruction |
| `stmt:close()` | `(true, nil)` — idempotent |

#### `db:exec`

Sans table `params`, `exec` accepte plusieurs instructions séparées par des
points-virgules. Elles sont préparées et exécutées dans l'ordre. L'exécution
s'arrête à la première erreur ; les instructions précédentes restent acquises
si elles ne se trouvaient pas dans une transaction explicite.

Avec une table `params`, une seule instruction est acceptée. Une seconde
instruction produit `(nil, err)`. Les espaces, points-virgules et commentaires
SQL finaux (`-- ...` ou `/* ... */`) ne comptent pas comme une seconde
instruction.

Un `SELECT` passé à `exec` est exécuté jusqu'au bout, mais ses lignes sont
ignorées. Utilise `query` pour les lire.

Une chaîne SQL vide ou composée uniquement de séparateurs/commentaires est un
no-op réussi avec `exec(sql)` ou `exec(sql, {})`. Une table `params` non vide
sans instruction SQL lève une erreur Lua.

#### `db:query`

`query` prépare immédiatement une instruction et renvoie un **itérateur
appelable**. L'instruction n'est exécutée qu'au premier appel de l'itérateur :

```lua
local stmt = assert(db:query("SELECT id, name FROM users ORDER BY id"))

local first = stmt() -- première exécution de sqlite3_step()
while first do
    print(first.id, first.name)
    first = stmt()
end
```

L'usage idiomatique reste :

```lua
for row in db:query("SELECT id, name FROM users ORDER BY id") do
    print(row.id, row.name)
end
```

Chaque ligne est une table indexée par nom de colonne. L'itérateur renvoie
`nil` une fois épuisé et finalise alors automatiquement le statement.
`stmt:close()` permet de le libérer plus tôt ; un appel ultérieur de `stmt()`
renvoie simplement `nil`. Le ramasse-miettes finalise aussi un itérateur
abandonné, par exemple après un `break`.

`query` n'est pas limité aux `SELECT`. Une instruction DDL ou DML est exécutée
au premier appel de l'itérateur, puis celui-ci se termine sans produire de
ligne.

Une requête sans résultat produit un itérateur qui renvoie immédiatement
`nil`. Un SQL vide ou composé uniquement de commentaires produit également un
itérateur déjà épuisé.

Un SQL multi-instructions est refusé. Les espaces, points-virgules et
commentaires SQL finaux restent autorisés :

```lua
local stmt = assert(db:query("SELECT 1 AS value; -- commentaire final"))
print(stmt().value)
```

<a id="sqlite-parameters"></a>
### Paramètres SQL

Les formes suivantes sont prises en charge :

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
valeur non supportée lève une erreur Lua. Passer `nil` comme troisième argument
équivaut à ne pas fournir de table.

Les placeholders numérotés `?NNN` ne font pas partie du contrat public. Utilise
`?` ou un placeholder nommé.

Types acceptés au bind :

| Type Lua | Valeur SQLite |
| --- | --- |
| boolean | INTEGER `0` ou `1` |
| integer | INTEGER |
| number non entier | REAL |
| string | TEXT, y compris avec des octets NUL |

Une chaîne Lua est **toujours** bindée avec `sqlite3_bind_text`, même dans une
colonne déclarée `BLOB`. La v1 ne fournit ni constructeur BLOB ni sentinelle
pour binder explicitement `NULL`. Pour `NULL`, utilise le littéral SQL
`NULL`.

<a id="sqlite-sql-text"></a>
### Texte SQL et octets NUL

Le texte SQL doit être une chaîne sans octet NUL. SQLite considérerait ce NUL
comme une fin de chaîne et pourrait n'exécuter qu'un préfixe ; Babet refuse donc
la requête avant toute préparation. La taille du SQL est également limitée à
`INT_MAX` octets, conformément à l'API `sqlite3_prepare_v2`.

Cette restriction concerne seulement le **texte SQL**. Les chaînes bindées sont
binary-safe et peuvent contenir des NUL.

<a id="sqlite-rows"></a>
## Lecture des lignes et mapping de types

| Type SQLite lu | Type Lua |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | string binary-safe, y compris pour un BLOB vide |
| NULL | clé absente de la table (`row.col == nil` et absente de `pairs`) |

Si plusieurs colonnes portent le même nom, chaque affectation remplace la
précédente : la dernière colonne gagne. Utilise des alias pour conserver toutes
les valeurs :

```sql
SELECT users.id AS user_id, orders.id AS order_id
FROM users
JOIN orders ON orders.user_id = users.id;
```

<a id="sqlite-lifetime"></a>
## Cycle de vie

`db:close()` est idempotent. Après fermeture, tout nouvel appel à `db:exec` ou
`db:query` renvoie `(nil, "sqlite: connection closed")`.

Un itérateur créé **avant** `db:close()` reste cependant utilisable. Babet
emploie `sqlite3_close_v2` : SQLite conserve temporairement une connexion
« zombie » jusqu'à la finalisation du dernier statement actif.

```lua
local stmt = assert(db:query("SELECT id FROM users ORDER BY id"))
assert(db:close())

for row in stmt do
    print(row.id) -- reste valide
end
```

<a id="sqlite-errors"></a>
## Contrat d'erreur

Les erreurs se répartissent en deux catégories :

- Les erreurs opérationnelles détectées par `open`, `close`, `exec` ou pendant
  la préparation de `query` renvoient `(nil, "sqlite: <description>")`.
  Le message contient une description, mais ne garantit pas la présence d'un
  code SQLite numérique.
- Les mauvais types d'argument, les tables `params` invalides et les erreurs
  survenant pendant l'appel d'un itérateur lèvent une erreur Lua. Une boucle
  peut les intercepter avec `pcall` autour de l'itération.

Sans table `params`, la présence d'un placeholder est détectée dans **chaque**
instruction de `exec`. Babet renvoie alors une erreur explicite au lieu de
laisser SQLite binder silencieusement `NULL`.

<a id="sqlite-example"></a>
## Exemple complet

```lua
local db = assert(babet.sqlite.open("state.db", {
    wal = true,
    busy_timeout = 2000,
}))

assert(db:exec([[
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        active INTEGER NOT NULL DEFAULT 1
    );
    CREATE INDEX IF NOT EXISTS users_active_idx ON users(active);
]]))

assert(db:exec(
    "INSERT INTO users (name) VALUES (?)",
    { "alice" }
))

for row in db:query(
    "SELECT id, name FROM users WHERE active = ? ORDER BY id",
    { 1 }
) do
    print(row.id, row.name)
end

assert(db:exec("BEGIN"))
local ok, err = db:exec(
    "UPDATE users SET active = 0 WHERE name = :name",
    { name = "alice" }
)
if ok then
    assert(db:exec("COMMIT"))
else
    db:exec("ROLLBACK")
    error(err)
end

assert(db:close())
```

<a id="sqlite-not-exposed"></a>
## Non exposé en v1

Les éléments suivants ne sont pas implémentés :

- `db:prepare`, `stmt:exec`, `stmt:finalize` ;
- `db:transaction(fn)` et `db:in_transaction()` ;
- `db:last_insert_rowid()` et `db:changes()` ;
- `opts.readonly` et `opts.foreign_keys` ;
- une sentinelle `db.NULL` ou un constructeur `sqlite.blob(data)` ;
- l'API de streaming BLOB `sqlite3_blob_open` ;
- l'API de sauvegarde `sqlite3_backup_init`.

Les transactions, `last_insert_rowid`, `changes`, les clés étrangères et
`VACUUM INTO` restent accessibles par SQL brut. FTS5 et R-Tree ne sont pas
activés dans la compilation embarquée actuelle.
