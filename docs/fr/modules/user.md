> [English](../../en/modules/user.md) | **Français**

# USER - rechercher des comptes système par nom ou UID

Le module `babet.user` interroge la base des utilisateurs du système via NSS.
Il permet de :

- rechercher un compte par nom ;
- rechercher un compte par UID ;
- tester rapidement l'existence d'un compte ;
- récupérer le nom, l'UID, le GID principal, le champ GECOS, le home et le shell.

Il ne lit jamais `/etc/passwd` directement. Il utilise les mêmes mécanismes de
résolution que `id` ou `getent passwd`, et peut donc voir les comptes fournis
par LDAP, SSSD, NIS, FreeIPA ou d'autres sources configurées dans
`/etc/nsswitch.conf`.

## Table des matières du module

- [Conventions générales](#user-conventions)
- [Vue d'ensemble de l'API](#user-api-summary)
- [Table utilisateur renvoyée](#user-result-table)
- [Rechercher un compte avec `get`](#user-get)
  - [Recherche par nom](#user-get-name)
  - [Recherche par UID](#user-get-uid)
  - [Compte absent](#user-get-missing)
- [Tester l'existence avec `exists`](#user-exists)
  - [Par nom](#user-exists-name)
  - [Par UID](#user-exists-uid)
  - [Quand préférer `get`](#user-exists-errors)
- [Validation des arguments](#user-validation)
- [NSS, workers et sécurité](#user-nss)
- [Contrat d'erreur](#user-errors)
- [Décisions et limites](#user-design)

<a id="user-conventions"></a>
## Conventions générales

### Sous-table dédiée

Contrairement aux fonctions historiques de SYS ou FS, les fonctions utilisateur
sont regroupées dans `babet.user` :

```lua
local user = babet.user.get("root")
local exists = babet.user.exists("root")
```

### Nom ou UID, sans conversion implicite

L'argument accepte exactement :

- une chaîne Lua : recherche par **nom** ;
- un integer Lua non négatif dans la plage de `uid_t` : recherche par **UID**.

Une chaîne numérique reste un nom :

```lua
-- Recherche un compte dont le nom est littéralement "1000"
local by_name = babet.user.get("1000")

-- Recherche l'UID numérique 1000
local by_uid = babet.user.get(1000)
```

Les floats, booléens, tables, `nil`, UID négatifs et UID trop grands lèvent une
erreur Lua. Aucune troncature ni conversion silencieuse n'est effectuée.

### Champs toujours présents

Lorsqu'un utilisateur est trouvé, la table contient toujours les six champs
documentés. Les champs texte peuvent être la chaîne vide, mais jamais `nil`.

<a id="user-api-summary"></a>
## Vue d'ensemble de l'API

| Fonction | Résultat |
| --- | --- |
| `babet.user.get(name_or_uid)` | table, `(nil, "user not found")` ou `(nil, "user: ...")` |
| `babet.user.exists(name_or_uid)` | booléen strict pour les résultats NSS ; `(nil, err)` uniquement sur échec inattendu de la frontière C++ |

<a id="user-result-table"></a>
## Table utilisateur renvoyée

Exemple typique :

```lua
{
    name  = "www-data",
    uid   = 33,
    gid   = 33,
    gecos = "www-data",
    home  = "/var/www",
    shell = "/usr/sbin/nologin",
}
```

| Champ | Type | Signification |
| --- | --- | --- |
| `name` | string | nom canonique renvoyé par NSS |
| `uid` | integer | identifiant numérique de l'utilisateur |
| `gid` | integer | GID **principal** du compte |
| `gecos` | string | champ descriptif brut, souvent le nom complet |
| `home` | string | répertoire personnel déclaré |
| `shell` | string | shell déclaré pour le compte |

`gid` n'est pas la liste des groupes secondaires. Le module ne réalise pas de
lookup de groupes et n'expose pas encore les appartenances supplémentaires.

Le champ `gecos` est renvoyé tel quel. Son format historique peut contenir
plusieurs valeurs séparées par des virgules, mais de nombreux systèmes y
placent simplement un nom libre.

```lua
local u = assert(babet.user.get("root"))
print("Nom   :", u.name)
print("UID   :", u.uid)
print("GID   :", u.gid)
print("GECOS :", u.gecos)
print("Home  :", u.home)
print("Shell :", u.shell)
```

<a id="user-get"></a>
## Rechercher un compte avec `get`

Signature :

```lua
local info, err = babet.user.get(name_or_uid)
```

Utilise `get` lorsque tu as besoin des informations du compte ou lorsque tu
dois distinguer un utilisateur absent d'une panne NSS.

<a id="user-get-name"></a>
### Recherche par nom

```lua
local root, err = babet.user.get("root")
assert(root, err)
assert(root.name == "root")
assert(root.uid == 0)
```

Exemple pour préparer un répertoire appartenant à un compte de service :

```lua
local account, err = babet.user.get("mon-service")
assert(account, err)

assert(babet.mkdir("/var/lib/mon-service"))
assert(babet.setAttributes(
    "/var/lib/mon-service",
    account.uid,
    account.gid,
    tonumber("750", 8)
))
```

Le nom est transmis à NSS tel quel. Il doit être une chaîne sans octet NUL.
Une chaîne vide est une recherche valide au niveau de l'API, mais elle ne
correspond normalement à aucun compte et renvoie `user not found`.

<a id="user-get-uid"></a>
### Recherche par UID

```lua
local root, err = babet.user.get(0)
assert(root, err)
assert(root.name == "root")
```

Exemple pour afficher le compte associé à un propriétaire de fichier :

```lua
local attrs, err = babet.getAttributes("rapport.txt")
assert(attrs, err)

local owner, user_err = babet.user.get(attrs.owner)
if owner then
    print("Propriétaire :", owner.name)
else
    print("UID sans compte résolu :", attrs.owner, user_err)
end
```

L'UID doit être un integer non négatif compatible avec le type système
`uid_t`. Sur Linux, la limite est généralement `2^32 - 1`, mais le code utilise
la limite réelle de la plateforme au moment de la compilation.

<a id="user-get-missing"></a>
### Compte absent

Un compte absent n'est pas une erreur Lua. La fonction renvoie :

```lua
local info, err = babet.user.get("compte-inexistant")
-- info == nil
-- err  == "user not found"
```

Traitement classique :

```lua
local account, err = babet.user.get("mon-service")
if not account then
    if err == "user not found" then
        print("Le compte doit être créé")
    else
        print("La résolution NSS a échoué :", err)
    end
end
```

Ne fais pas :

```lua
-- Mauvais si l'absence est un cas normal : assert lève immédiatement
-- local account = assert(babet.user.get("compte-optionnel"))
```

<a id="user-exists"></a>
## Tester l'existence avec `exists`

Signature :

```lua
local present = babet.user.exists(name_or_uid)
```

La fonction renvoie toujours un booléen pour un argument valide.

<a id="user-exists-name"></a>
### Par nom

```lua
if babet.user.exists("www-data") then
    print("Le compte www-data existe")
end
```

Exemple de précondition simple :

```lua
if not babet.user.exists("mon-service") then
    error("Le compte mon-service doit être créé avant le démarrage")
end
```

<a id="user-exists-uid"></a>
### Par UID

```lua
assert(babet.user.exists(0)) -- root sur un système Unix normal
```

Un UID absent renvoie `false` :

```lua
local present = babet.user.exists(2000000000)
print(present)
```

<a id="user-exists-errors"></a>
### Quand préférer `get`

`exists` assimile volontairement une erreur NSS à `false`.

Cela rend la fonction pratique pour une branche simple, mais elle ne permet pas
de distinguer :

- un compte réellement absent ;
- un annuaire LDAP temporairement indisponible ;
- une erreur d'E/S ;
- un manque de mémoire dans le résolveur.

Pour une décision importante, notamment en administration ou en sécurité,
utilise `get` :

```lua
local account, err = babet.user.get("mon-service")
if account then
    print("Compte disponible")
elseif err == "user not found" then
    print("Compte absent")
else
    error("Impossible d'interroger NSS : " .. err)
end
```

<a id="user-validation"></a>
## Validation des arguments

Les cas suivants lèvent une erreur Lua, récupérable avec `pcall` :

```lua
local invalid_calls = {
    function() return babet.user.get() end,
    function() return babet.user.get(nil) end,
    function() return babet.user.get(true) end,
    function() return babet.user.get({}) end,
    function() return babet.user.get(1.5) end,
    function() return babet.user.get(-1) end,
    function() return babet.user.get(8589934592) end,
    function() return babet.user.get("root\0autre") end,
}

for _, call in ipairs(invalid_calls) do
    local ok, err = pcall(call)
    assert(not ok)
    print(err)
end
```

`exists` applique exactement les mêmes validations :

```lua
local ok = pcall(function()
    return babet.user.exists(-1)
end)
assert(not ok)
```

Le rejet des NUL évite que `"root\0autre"` soit vu comme `"root"` par
`getpwnam_r`.

<a id="user-nss"></a>
## NSS, workers et sécurité

### Sources de comptes

Le résultat dépend de la configuration NSS de la machine. Selon
`/etc/nsswitch.conf`, un compte peut provenir de :

- `/etc/passwd` ;
- LDAP ;
- SSSD ;
- NIS ;
- FreeIPA ;
- systemd-userdb ;
- un autre module NSS.

Un script exécuté sur deux machines peut donc obtenir des résultats différents
sans que Babet ait changé.

### Appels depuis des workers

Le module utilise `getpwnam_r` et `getpwuid_r`, les variantes réentrantes. Il
peut être utilisé dans les workers :

```lua
local worker = assert(babet.workers.spawn([[
    local root, err = babet.user.get("root")
    if not root then
        error(err)
    end
    return root.uid
]]))

local joined, uid = worker:join()
assert(joined and uid == 0)
```

Chaque appel interroge NSS. Babet ne maintient pas de cache applicatif des
utilisateurs.

### Attention aux décisions de sécurité

Les champs `home` et `shell` sont des données de configuration, pas une preuve
que le chemin existe ni que le programme est exécutable.

```lua
local u = assert(babet.user.get("mon-service"))
local home_is_dir = assert(babet.isDir(u.home))
local shell_path = babet.which(u.shell)
```

De même, la présence d'un compte ne prouve pas qu'il est autorisé à se
connecter, qu'un mot de passe est valide ou qu'il possède un groupe secondaire
particulier.

<!-- pdf-page-break -->

<a id="user-errors"></a>
## Contrat d'erreur

| Situation | `get` | `exists` |
| --- | --- | --- |
| compte trouvé | table utilisateur | `true` |
| compte absent | `(nil, "user not found")` | `false` |
| erreur NSS | `(nil, "user: ...")` | `false` |
| argument invalide | erreur Lua | erreur Lua |
| exception C++ inattendue | `(nil, "user: out of memory")`, `(nil, "user: internal failure")` ou `(nil, "user: unknown internal failure")` | même retour de frontière `(nil, err)` |

La dernière ligne est distincte d’une erreur NSS. Elle sert uniquement à
empêcher une exception C++ inattendue de traverser les frames C de Lua. Pour
tous les résultats NSS ordinaires, `exists` renvoie toujours exactement un
booléen strict comme indiqué plus haut.

Exemple générique :

```lua
local ok, info, err = pcall(function()
    return babet.user.get("mon-service")
end)

if not ok then
    print("Mauvais appel :", info)
elseif not info then
    print("Lookup impossible :", err)
else
    print("UID :", info.uid)
end
```

<a id="user-design"></a>
## Décisions et limites

- NSS est utilisé au lieu de parser `/etc/passwd`.
- Les variantes réentrantes `_r` sont utilisées pour rester compatibles avec
  les workers.
- Les champs texte sont toujours présents et remplacés par `""` si NSS fournit
  un pointeur nul.
- Le buffer NSS est agrandi dynamiquement jusqu'à une limite interne de 64 Kio ;
  au-delà, `get` renvoie une erreur NSS.
- `exists` privilégie une interface booléenne simple et masque les erreurs NSS ;
  utilise `get` lorsqu'un diagnostic est nécessaire. Seule la frontière de
  sûreté C++ interne peut produire son diagnostic exceptionnel `(nil, err)`.
- Le module n'expose pas les groupes secondaires.
- Il n'expose ni `/etc/shadow`, ni mots de passe, ni expiration de compte.
- Il ne crée, ne supprime et ne modifie aucun utilisateur.
- Pour créer un compte, un script peut appeler un outil système via
  [`babet.exec`](exec.md), avec les privilèges appropriés.
