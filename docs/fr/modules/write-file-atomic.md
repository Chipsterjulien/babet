> [English](../../en/modules/write-file-atomic.md) | **Français**

# `writeFileAtomic` — écriture atomique et durable d’un fichier

`babet.writeFileAtomic()` publie une chaîne Lua binaire dans un fichier régulier
sans exposer de contenu partiellement écrit sous le nom final. Les données sont
écrites dans un temporaire privé du même dossier, les permissions finales sont
appliquées, puis le temporaire est publié atomiquement.

Cette fonction est adaptée aux configurations, jetons, états JSON, petits
fichiers binaires et captures déjà présentes en mémoire. Elle ne remplace pas
les API de streaming comme `babet.http.download()` pour les très gros contenus.

## Sommaire

- [API](#write-atomic-api)
- [Valeurs par défaut](#write-atomic-defaults)
- [Écriture simple](#write-atomic-basic)
- [Remplacement explicite](#write-atomic-overwrite)
- [Permissions](#write-atomic-permissions)
- [Durabilité](#write-atomic-durable)
- [Données binaires](#write-atomic-binary)
- [Chemins et liens symboliques](#write-atomic-paths)
- [Atomicité et concurrence](#write-atomic-concurrency)
- [Utilisation dans un worker](#write-atomic-worker)
- [Exemple combiné Selenium](#write-atomic-selenium)
- [Contrat d’erreur](#write-atomic-errors)
- [Limites](#write-atomic-limits)

<a id="write-atomic-api"></a>
## API

```lua
local ok, err = babet.writeFileAtomic(path, data, opts?)
```

| Argument | Type | Rôle |
| --- | --- | --- |
| `path` | chaîne | destination relative ou absolue, sans octet NUL |
| `data` | chaîne | contenu binaire complet, octets NUL autorisés |
| `opts` | table ou `nil` | options strictes |

Résultats :

- succès : `true, nil` ;
- erreur de système de fichiers ou de publication : `nil, err` ;
- mauvaise arité, mauvais type ou option inconnue : erreur Lua levée.

<a id="write-atomic-defaults"></a>
## Valeurs par défaut

```lua
{
    overwrite = false,
    permissions = tonumber("644", 8),
    durable = true,
}
```

| Option | Défaut | Effet |
| --- | --- | --- |
| `overwrite` | `false` | refuse une destination existante |
| `permissions` | `0644` | permissions exactes du nouveau fichier final |
| `durable` | `true` | synchronise le fichier temporaire puis le dossier parent |

Les clés inconnues et les clés non textuelles sont refusées. Les booléens ne
sont pas convertis depuis `0`, `1` ou une chaîne. `permissions` doit être un
entier compris entre `0` et `0777`.

<a id="write-atomic-basic"></a>
## Écriture simple

```lua
local ok, err = babet.writeFileAtomic("state.json", [[{"ready":true}]])
assert(ok, err)
```

La destination ne devient visible qu’après l’écriture complète du temporaire.
Si `state.json` existe déjà, l’appel échoue et conserve son contenu.

La fonction ne crée pas les dossiers parents :

```lua
assert(babet.mkdir("runtime"))
assert(babet.writeFileAtomic("runtime/state.json", "{}"))
```

<a id="write-atomic-overwrite"></a>
## Remplacement explicite

```lua
local ok, err = babet.writeFileAtomic("state.json", new_state, {
    overwrite = true,
})
assert(ok, err)
```

Avec `overwrite = true` :

- une destination absente est créée ;
- un fichier régulier existant est remplacé par renommage dans le même dossier ;
- un lien symbolique, dossier, FIFO, socket ou périphérique est refusé ;
- l’ancien fichier reste intact après toute erreur antérieure à la publication.

Sans écrasement, Babet utilise une publication qui échoue atomiquement si une
autre tâche gagne la course et crée la destination en premier.

<a id="write-atomic-permissions"></a>
## Permissions

```lua
local ok, err = babet.writeFileAtomic("token.bin", token, {
    permissions = tonumber("600", 8),
})
assert(ok, err)
```

Le temporaire est toujours créé avec un mode privé `0600` ou plus restrictif à
cause de l’`umask`. Avant publication, Babet applique ensuite exactement les
permissions demandées avec `fchmod()`. Les bits setuid, setgid et sticky ne
peuvent pas être demandés : la plage autorisée est `0000..0777`.

Lors d’un remplacement, les permissions du nouveau fichier proviennent de
l’option et non de l’ancien fichier.

<a id="write-atomic-durable"></a>
## Durabilité

Avec le défaut `durable = true`, la séquence est :

1. création d’un temporaire unique dans le dossier destination ;
2. écriture complète en gérant `EINTR` et les écritures partielles ;
3. application des permissions ;
4. `fsync()` du temporaire ;
5. publication atomique ;
6. `fsync()` du dossier parent.

Cette séquence vise la conservation après une panne brutale, selon les garanties
du système de fichiers et du matériel.

Pour un cache reconstructible où la performance prime :

```lua
local ok, err = babet.writeFileAtomic("cache/index.bin", cache, {
    overwrite = true,
    durable = false,
})
assert(ok, err)
```

`durable = false` conserve la publication atomique, mais ne confirme pas la
persistance après une panne ou une coupure d’alimentation.

Si la publication réussit puis que la synchronisation du dossier échoue,
l’appel renvoie une erreur explicite indiquant que la destination est déjà
publiée atomiquement mais que sa persistance n’a pas pu être confirmée.

<a id="write-atomic-binary"></a>
## Données binaires

`data` est une chaîne Lua binaire. Aucun contrôle UTF-8 n’est effectué :

```lua
local payload = "\0\1\2PNG\255\254"
assert(babet.writeFileAtomic("capture.bin", payload))
```

Une chaîne vide crée un fichier régulier de taille nulle.

La totalité des données doit déjà être en mémoire. Pour un téléchargement ou
une transformation de plusieurs gigaoctets, préfère une API qui écrit en
streaming.

<a id="write-atomic-paths"></a>
## Chemins et liens symboliques

Les chemins peuvent être relatifs ou absolus. Ils sont interprétés littéralement :
aucune expansion de `~`, de `$HOME`, du shell ou des globs n’est effectuée.

Pour confiner l’écriture :

- chaque composant parent est ouvert avec `openat()` et `O_NOFOLLOW` ;
- un composant parent symbolique est refusé ;
- `..` est refusé ;
- le dernier composant symbolique est refusé ;
- les dossiers parents absents ne sont pas créés ;
- la destination doit être absente ou être un fichier régulier lorsque
  `overwrite = true`.

```lua
local ok, err = babet.writeFileAtomic("link/config.json", "{}", {
    overwrite = true,
})
assert(not ok)
print(err)
```

Un processus disposant lui-même du droit d’écriture sur le dossier parent reste
dans le même périmètre de confiance : POSIX ne fournit pas de renommage
conditionnel portable lié à un inode précis. Babet ne suit aucun lien final et
réinspecte la destination immédiatement avant publication, mais les permissions
du dossier restent la frontière de sécurité contre un acteur hostile concurrent.

<a id="write-atomic-concurrency"></a>
## Atomicité et concurrence

Deux lecteurs n’observent jamais un mélange de l’ancien et du nouveau contenu :
ils voient l’un ou l’autre fichier complet.

Avec `overwrite = false`, plusieurs producteurs peuvent tenter la même création :

```lua
local ok, err = babet.writeFileAtomic("once.dat", value)
if not ok and err:find("already exists", 1, true) then
    -- Un autre producteur a gagné.
end
```

Un seul appel publie la destination. Les autres échouent sans la remplacer.

Avec `overwrite = true`, le dernier renommage réussi détermine le contenu final.
L’ordre entre deux writers concurrents n’est pas défini.

<a id="write-atomic-worker"></a>
## Utilisation dans un worker

La fonction est disponible dans chaque état Lua worker :

```lua
local job = assert(babet.workers.spawn([[
    local ok, err = babet.writeFileAtomic(worker.args.path, worker.args.data, {
        overwrite = true,
        permissions = tonumber("600", 8),
    })
    assert(ok, err)
    return true
]], {
    path = "runtime/result.bin",
    data = "worker-result",
}))

assert(job:join())
```

Le contenu transmis dans `worker.args` reste soumis au sérialiseur JSON des
workers. Une chaîne binaire avec NUL ne peut donc pas être passée directement
par `worker.args`; elle peut être produite dans le worker, conservée en Base64
ou lue depuis une autre source.

<a id="write-atomic-selenium"></a>
## Exemple combiné Selenium

Décoder une capture WebDriver puis la publier sans fichier partiel :

```lua
local png, err = babet.base64.decode(response.value, {
    max_output = 32 * 1024 * 1024,
})
assert(png, err)

assert(babet.mkdir("captures"))
local ok
ok, err = babet.writeFileAtomic("captures/latest.png", png, {
    overwrite = true,
    permissions = tonumber("640", 8),
    durable = true,
})
assert(ok, err)
```

Les lecteurs de `latest.png` voient soit l’ancienne capture complète, soit la
nouvelle, jamais une image partiellement décodée ou écrite.

<a id="write-atomic-errors"></a>
## Contrat d’erreur

Erreurs Lua levées :

```lua
babet.writeFileAtomic()                       -- arité
babet.writeFileAtomic(42, "data")             -- path non chaîne
babet.writeFileAtomic("x", {})                -- data non chaîne
babet.writeFileAtomic("x", "data", 42)        -- opts non table
babet.writeFileAtomic("x", "data", {
    permissions = "600",
})
babet.writeFileAtomic("x", "data", {
    unknown = true,
})
```

Erreurs renvoyées sous forme `nil, err` :

- parent absent, inaccessible, symbolique ou non dossier ;
- destination existante sans `overwrite` ;
- destination finale symbolique ou non régulière ;
- échec de création, écriture, `fchmod`, `fsync`, fermeture ou publication ;
- nom temporaire unique impossible à allouer.

Après une erreur antérieure à la publication, l’ancienne destination reste
intacte et le temporaire est supprimé au mieux.

<a id="write-atomic-limits"></a>
## Limites

La première version ne fournit pas :

- création automatique des dossiers parents ;
- ajout à un fichier ;
- écriture depuis un objet `io.file` ou un descripteur ;
- API de streaming ;
- verrouillage applicatif entre plusieurs writers ;
- rotation ou plafond automatique de taille ;
- publication atomique de plusieurs fichiers comme une transaction unique.

Pour plusieurs fichiers liés, publie un nouveau dossier/version puis change un
pointeur applicatif, ou utilise SQLite lorsqu’une transaction est nécessaire.
