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

| Champ | Type | Défaut |
| --- | --- | --- |
| `readonly` | boolean | `false` |
| `wal` | boolean — active le journal WAL | `false` |
| `busy_timeout` | number ms (bloque pendant cette durée sur une db verrouillée) | `5000` |
| `foreign_keys` | boolean | `true` |

Chemin spécial `":memory:"` ouvre une base en mémoire (perdue à
la fermeture). À utiliser pour les tests ou le traitement
transitoire.

### Exec direct (pas de paramètres / instruction one-shot)

| Fonction | Renvoie |
| --- | --- |
| `db:exec(sql)` | `(true, nil)` \| `(nil, err)` |
| `db:exec(sql, params)` | idem, avec paramètres bindés `?` |
| `db:query(sql, params?)` | `table` de tables-de-row \| `(nil, err)` |

### Instructions préparées (réutilisation, performance)

| Fonction | Renvoie |
| --- | --- |
| `db:prepare(sql)` | `stmt` (userdata) \| `(nil, err)` |
| `stmt(params?)` | iterator sur les rows |
| `stmt:exec(params?)` | `(true, nil)` \| `(nil, err)` |
| `stmt:finalize()` | `(true, nil)` — idempotent |

### Transactions

| Fonction | Renvoie |
| --- | --- |
| `db:transaction(fn)` | `(true, result)` si `fn` retourne truthy ; rollback + `(false, err)` sinon |

### Utilitaires

| Fonction | Renvoie |
| --- | --- |
| `db:last_insert_rowid()` | `integer` |
| `db:changes()` | `integer` — rows affectés par la dernière écriture |
| `db:in_transaction()` | `boolean` |

## Mapping de types

| Type SQLite | Type Lua |
| --- | --- |
| INTEGER | integer |
| REAL | number (float) |
| TEXT | string |
| BLOB | string (binary-safe) |
| NULL | `nil` (lecture), `nil` ou sentinelle `db.NULL` (écriture) |

## Exemples rapides

```lua
local db = assert(babet.sqlite.open("state.db", { wal = true }))

-- Schéma
db:exec([[
    CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        active INTEGER DEFAULT 1
    );
]])

-- Insert avec paramètres
assert(db:exec("INSERT INTO users (name) VALUES (?)", { "alice" }))
print("inséré avec id", db:last_insert_rowid())

-- Requête de rows
local rows = assert(db:query("SELECT id, name FROM users WHERE active = ?", { 1 }))
for _, r in ipairs(rows) do
    print(r.id, r.name)
end

-- Instruction préparée réutilisée dans une boucle (chemin rapide)
local stmt = assert(db:prepare("INSERT INTO users (name) VALUES (?)"))
for _, name in ipairs({ "bob", "carol", "dave" }) do
    assert(stmt:exec({ name }))
end
stmt:finalize()

-- Transaction
local ok, err = db:transaction(function()
    db:exec("UPDATE users SET active = 0 WHERE name = ?", { "alice" })
    db:exec("UPDATE users SET active = 1 WHERE name = ?", { "bob" })
    return true   -- commit
end)
if not ok then print("rollback :", err) end

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
- **Méthodes après `close`** → `(nil, "sqlite: db closed")`.
- **Mauvais types d'argument** → lève via `luaL_error`.

## Décisions de design

- **WAL opt-in, pas par défaut**. WAL est strictement meilleur
  pour la plupart des cas d'usage, mais crée des fichiers
  sidecar `*-wal` et `*-shm` que certains utilisateurs trouvent
  surprenants. L'opt-in garde le défaut sans surprise, mais tout
  daemon long-running devrait passer `wal=true`.
- **Clés étrangères ON par défaut**, contrairement au défaut
  SQLite. La plupart des schémas modernes s'appuient sur des
  contraintes FK ; les laisser off par défaut est un footgun.
- **`transaction(fn)` commit si `fn` retourne truthy**.
  Convention Lua : retourner une valeur pour signaler le succès,
  ne rien retourner / `nil` / `false` (ou lever) pour rollback.
  La valeur de retour de la fonction est propagée.
- **Placeholders sans `params` est une erreur**, pas un bind NULL
  silencieux. Attrape une classe de bugs proches de l'injection
  tôt.
- **Erreurs renvoyées, pas levées**. Même un SQL malformé renvoie
  `(nil, err)`. Les scripts qui ne vérifient pas sont bruyants
  mais pas catastrophiques.

## Hors v1

- I/O streaming `BLOB` (`sqlite3_blob_open`). Utilise la
  sérialisation en string si tu rentres en mémoire.
- Virtual tables / FTS5 / R-Tree. Disponibles via SQL brut si le
  SQLite embarqué est compilé avec ; pas encore d'API niveau Lua.
- API de backup (`sqlite3_backup_init`). Pour l'instant,
  `VACUUM INTO 'backup.db'` marche en one-liner.

Pour une couche de plus haut niveau type ORM, construis-la en Lua
au-dessus de cette API.
