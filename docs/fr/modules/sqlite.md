> [English](../../en/modules/sqlite.md) | **Français**

# `babet.sqlite` — base de données SQL embarquée

Wrappe SQLite 3.53.1 (embarquée), le moteur de base de données le
plus déployé au monde. Persistance zero-config pour tout script
qui a besoin de plus qu'un fichier JSON mais moins qu'un serveur
de base de données.

## Pourquoi

Un script qui doit garder un état entre les runs (la seen-list
d'un bot, la progression d'un scraper, des métriques accumulées)
ne devrait pas avoir à tirer PostgreSQL ou inventer son propre
format de fichier. SQLite est exactement ce qu'il faut à cette
échelle : fichier unique, transactionnel, rapide, pas de daemon.

L'API Lua reflète l'API C de SQLite de près (open / exec /
prepare / step / finalize) avec des défauts plus sûrs et un
retour d'erreurs Lua-friendly.

## API

### Ouverture et fermeture

| Fonction | Renvoie |
| --- | --- |
| `babet.sqlite.open(path, opts?)` | `db` (userdata) \| `(nil, err)` |
| `db:close()` | `(true, nil)` — idempotent |

`opts` :

| Champ          | Type                                                                      | Défaut                                 |
| -------------- | ------------------------------------------------------------------------- | -------------------------------------- |
| `wal`          | boolean — active le journal WAL                                           | `false`                                |
| `busy_timeout` | integer ms — retry automatique pendant cette durée sur une db verrouillée | `0` = **aucun** (SQLITE_BUSY immédiat) |

> Une ancienne version de cette page documentait aussi
> `opts.readonly` et `opts.foreign_keys` : ils n'existent pas —
> voir « Hors v1 ».

Chemin spécial `":memory:"` ouvre une base en mémoire (perdue à
la fermeture). À utiliser pour les tests ou le traitement
transitoire.

### Exécution et requêtes

| Fonction                 | Renvoie                                                            |
| ------------------------ | ------------------------------------------------------------------ |
| `db:exec(sql)`           | `(true, nil)` \| `(nil, err)` — multi-statements acceptés         |
| `db:exec(sql, params)`   | idem, avec paramètres bindés                                       |
| `db:query(sql, params?)` | `stmt` (itérateur) \| `(nil, err)` — **un seul** statement        |

`db:query` renvoie un **itérateur appelable**, pas une table :
chaque appel rend la row suivante (table dont les clés sont les
noms de colonnes), puis `nil` une fois épuisé — l'usage idiomatique
est `for row in db:query(...) do`. Les ressources sont libérées à
l'épuisement ou au ramasse-miettes ; `stmt:close()` permet de
libérer plus tôt (itération abandonnée en cours de route).

Un SQL multi-instructions passé à `query` rend
`(nil, "sqlite: query supports only one statement; …")` — pour du
multi-statement, c'est `exec`.

## Mapping de types

| Type SQLite | Type Lua |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | string (binary-safe) |
| NULL | lecture : **clé absente** de la row (`row.col == nil`, mais `pairs()` ne la voit pas) ; écriture : utilise le littéral SQL `NULL` (pas de sentinelle en v1) |

## Exemples rapides

```lua
local db = assert(babet.sqlite.open("state.db", { wal = true }))

-- Schéma (multi-statements : exec)
db:exec([[
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        active INTEGER DEFAULT 1
    );
]])

-- Insert avec paramètres
assert(db:exec("INSERT INTO users (name) VALUES (?)", { "alice" }))

-- Dernier rowid : via SQL (pas de méthode dédiée en v1)
for row in db:query("SELECT last_insert_rowid() AS id") do
    print("inséré avec id", row.id)
end

-- Requête : query rend un ITÉRATEUR
for row in db:query("SELECT id, name FROM users WHERE active = ?",
                    { 1 }) do
    print(row.id, row.name)
end

-- Transaction : via SQL (pas de wrapper en v1)
db:exec("BEGIN")
local ok1 = db:exec("UPDATE users SET active = 0 WHERE name = ?",
                    { "alice" })
local ok2 = db:exec("UPDATE users SET active = 1 WHERE name = ?",
                    { "bob" })
if ok1 and ok2 then
    db:exec("COMMIT")
else
    db:exec("ROLLBACK")
end

db:close()
```

## Contrat d'erreur

- Toutes les erreurs runtime → `(nil, "sqlite: <description>")`
  avec le code d'erreur SQLite dans le message.
- **`exec(sql)` avec des placeholders mais sans argument
  `params`** → `(nil, "sqlite: SQL contains placeholders but no
  params table provided; …")` — erreur explicite plutôt que
  binding NULL silencieux. Le garde s'applique à **chaque**
  statement d'un SQL multi-instructions (audit v21).
- **Placeholders supportés** : `?` (positionnels, bindés par
  `params[1]`, `params[2]`, …) et `:name` / `@name` / `$name`
  (nommés, bindés par `params.name` — le préfixe est ignoré).
  Les placeholders **numérotés `?NNN` ne sont pas supportés** :
  le binder les traiterait comme un paramètre « nommé » dont le
  nom est `"NNN"` (clé string), un piège plus qu'une
  fonctionnalité. Utilise `?` ou `:name`.
- **Clés sparses dans `params`** (ex : `{[1] = "a", [3] = "c"}`)
  → `(nil, err)`.
- **String BLOB vide** → stockée correctement en tant que BLOB
  vide (anciennement buggé en pré-1.5).
- **Méthodes après `close`** → `(nil, "sqlite: connection closed")`.
- **Mauvais types d'argument** → lève via `luaL_error`.

## Décisions de design

- **WAL opt-in, pas par défaut**. WAL est strictement meilleur
  pour la plupart des cas d'usage, mais crée des fichiers
  sidecar `*-wal` et `*-shm` que certains utilisateurs trouvent
  surprenants. L'opt-in garde le défaut sans surprise, mais tout
  daemon long-running devrait passer `wal=true`.
- **Placeholders sans `params` est une erreur**, pas un bind NULL
  silencieux. Attrape une classe de bugs proches de l'injection
  tôt.
- **Erreurs renvoyées, pas levées**. Même un SQL malformé renvoie
  `(nil, err)`. Les scripts qui ne vérifient pas sont bruyants
  mais pas catastrophiques.

## Hors v1

> Les éléments suivants figuraient à tort comme disponibles dans une
> ancienne version de cette page — ils relèvent du design initial et
> ne sont **pas implémentés** :
> `db:prepare` / `stmt:exec` / `stmt:finalize` (statements
> préparés réutilisables — `query` re-prépare à chaque appel),
> `db:transaction(fn)` / `db:in_transaction()` (contournement :
> `exec("BEGIN"/"COMMIT"/"ROLLBACK")`, cf. exemple),
> `db:last_insert_rowid()` / `db:changes()` (contournement :
> `SELECT last_insert_rowid()` / `SELECT changes()`),
> `opts.readonly` / `opts.foreign_keys` (contournement :
> `PRAGMA foreign_keys = ON` via `exec`), et la sentinelle
> `db.NULL` en écriture.

- I/O streaming `BLOB` (`sqlite3_blob_open`). Utilise la
  sérialisation en string si tu rentres en mémoire.
- Virtual tables / FTS5 / R-Tree. Disponibles via SQL brut si le
  SQLite embarqué est compilé avec ; pas encore d'API niveau Lua.
- API de backup (`sqlite3_backup_init`). Pour l'instant,
  `VACUUM INTO 'backup.db'` marche en one-liner.

Pour une couche de plus haut niveau type ORM, construis-la en Lua
au-dessus de cette API.
