> [English](../../en/modules/base64.md) | **Français**

# `babet.base64` — encodage et décodage Base64 binaires

Le module `babet.base64` implémente les alphabets Base64 de la RFC 4648 sans
lancer de programme externe. Les entrées et sorties sont des chaînes Lua
**binaires** : les octets NUL, les données non UTF-8 et toutes les valeurs de
`0` à `255` sont conservés exactement.

Le décodeur est volontairement strict. Il vérifie l'alphabet choisi, la
position du padding, la longueur du dernier groupe et les bits inutilisés de la
dernière valeur. Une représentation non canonique n'est donc pas acceptée
silencieusement.

## Table des matières du module

- [API](#base64-api)
- [Encodage standard](#base64-encode-standard)
- [Alphabet URL-safe](#base64-url-safe)
- [Padding](#base64-padding)
- [Décodage strict](#base64-strict-decode)
- [Espaces ASCII](#base64-whitespace)
- [Limite de sortie](#base64-max-output)
- [Données binaires et fichiers](#base64-binary)
- [Utilisation dans un worker](#base64-worker)
- [Contrat d'erreur](#base64-errors)
- [Limites et choix de conception](#base64-limits)

<a id="base64-api"></a>
## API

| Fonction | Contrat |
| --- | --- |
| `babet.base64.encode(data [, opts])` | Renvoie `texte, nil` ou `nil, err` |
| `babet.base64.decode(text [, opts])` | Renvoie `données, nil` ou `nil, err` |

`data` et `text` doivent être de vraies chaînes Lua. Un nombre n'est jamais
converti implicitement en texte.

Options d'encodage :

```lua
{
    url_safe = false,
    padding = true,
}
```

Options de décodage :

```lua
{
    url_safe = false,
    allow_unpadded = false,
    ignore_whitespace = false,
    max_output = nil,
}
```

Les options inconnues sont refusées. Les booléens doivent être de vrais
booléens Lua ; `max_output` doit être un entier positif ou nul.

<a id="base64-encode-standard"></a>
## Encodage standard

Sans option, `encode()` utilise l'alphabet Base64 standard : lettres, chiffres,
`+` et `/`, avec padding canonique `=` lorsque le dernier groupe contient moins
de trois octets.

```lua
local encoded, err = babet.base64.encode("hello")
assert(encoded, err)
assert(encoded == "aGVsbG8=")
```

Les vecteurs classiques de la RFC 4648 sont respectés :

```lua
assert(babet.base64.encode("")       == "")
assert(babet.base64.encode("f")      == "Zg==")
assert(babet.base64.encode("fo")     == "Zm8=")
assert(babet.base64.encode("foo")    == "Zm9v")
assert(babet.base64.encode("foob")   == "Zm9vYg==")
assert(babet.base64.encode("fooba")  == "Zm9vYmE=")
assert(babet.base64.encode("foobar") == "Zm9vYmFy")
```

`encode()` n'ajoute aucun retour à la ligne et ne produit pas le format MIME à
76 colonnes.

<a id="base64-url-safe"></a>
## Alphabet URL-safe

`url_safe = true` sélectionne l'alphabet Base64 URL/file-name safe de la RFC
4648 : `-` remplace `+` et `_` remplace `/`.

```lua
local binary = string.char(251, 255)
local encoded, err = babet.base64.encode(binary, {
    url_safe = true,
})
assert(encoded, err)
assert(encoded == "-_8=")
```

Le décodage doit utiliser le même alphabet :

```lua
local decoded, err = babet.base64.decode("-_8=", {
    url_safe = true,
})
assert(decoded, err)
assert(decoded == string.char(251, 255))
```

Les alphabets ne sont pas mélangés automatiquement :

```lua
assert(babet.base64.decode("-_8=") == nil)
assert(babet.base64.decode("+/8=", { url_safe = true }) == nil)
```

Ce choix strict évite qu'une entrée soit acceptée sous plusieurs formes alors
qu'un protocole attend un alphabet précis.

<a id="base64-padding"></a>
## Padding

### Produire une sortie sans `=`

`padding = false` retire uniquement les caractères `=` finaux. Le contenu utile
reste identique.

```lua
local encoded, err = babet.base64.encode("hello", {
    padding = false,
})
assert(encoded, err)
assert(encoded == "aGVsbG8")
```

Lorsque la longueur source est un multiple de trois, aucun padding n'est
nécessaire même avec l'option par défaut :

```lua
assert(babet.base64.encode("foo") == "Zm9v")
```

### Accepter une entrée non paddée

Le décodeur refuse par défaut un dernier groupe incomplet sans `=` :

```lua
local decoded, err = babet.base64.decode("aGVsbG8")
assert(decoded == nil)
assert(type(err) == "string")
```

Active explicitement `allow_unpadded` lorsque le protocole utilise ce format :

```lua
local decoded, err = babet.base64.decode("aGVsbG8", {
    allow_unpadded = true,
})
assert(decoded, err)
assert(decoded == "hello")
```

`allow_unpadded` n'assouplit pas les autres règles : un groupe d'un seul symbole
reste tronqué et des bits finaux non nuls restent refusés.

### Exemple combiné URL-safe sans padding

C'est la forme fréquente dans des identifiants de protocole ou certains champs
JSON :

```lua
local source = string.char(0, 1, 2, 251, 255)

local token, err = babet.base64.encode(source, {
    url_safe = true,
    padding = false,
})
assert(token, err)

local restored
restored, err = babet.base64.decode(token, {
    url_safe = true,
    allow_unpadded = true,
})
assert(restored, err)
assert(restored == source)
```

<a id="base64-strict-decode"></a>
## Décodage strict

Le décodeur vérifie notamment :

- chaque caractère appartient exactement à l'alphabet sélectionné ;
- `=` apparaît uniquement à la fin ;
- il existe au maximum deux caractères de padding ;
- la longueur paddée est un multiple de quatre ;
- une fin non paddée contient deux ou trois symboles, jamais un seul ;
- les bits inutilisés du dernier symbole sont nuls.

Ainsi, ces entrées sont refusées :

```lua
local invalid = {
    "%%%",   -- caractères hors alphabet
    "AA=A",  -- padding au milieu
    "A===",  -- trop de padding
    "Zg=",   -- longueur paddée invalide
    "Zh==",  -- bits inutilisés non nuls
    "Zm9=",  -- bits inutilisés non nuls
}

for _, text in ipairs(invalid) do
    local value, err = babet.base64.decode(text)
    assert(value == nil)
    assert(type(err) == "string")
end
```

Les positions signalées par les erreurs `invalid character`, `invalid padding`
ou `non-zero trailing bits` sont comptées à partir de **1**, en octets dans la
chaîne d'entrée originale.

<a id="base64-whitespace"></a>
## Espaces ASCII

Par défaut, tout espace est un caractère invalide :

```lua
local value, err = babet.base64.decode("Zm9v\nYmFy")
assert(value == nil)
```

`ignore_whitespace = true` ignore les six espaces ASCII classiques : espace,
tabulation, saut de ligne, tabulation verticale, saut de page et retour
chariot.

```lua
local value, err = babet.base64.decode(" Zm9v\tYmFy\r\n", {
    ignore_whitespace = true,
})
assert(value, err)
assert(value == "foobar")
```

L'option ne supprime aucun autre octet Unicode ou de contrôle. Elle n'autorise
pas non plus un mauvais padding ou un alphabet incorrect.

Lorsque des espaces sont ignorés, une position d'erreur continue de désigner la
position dans la chaîne originale, espaces compris.

<a id="base64-max-output"></a>
## Limite de sortie

`max_output` borne la taille exacte du résultat décodé. La limite est contrôlée après la validation lexicale et canonique complète
de la valeur Base64, puis avant l'allocation de la chaîne de sortie décodée.

```lua
local value, err = babet.base64.decode("Zm9v", {
    max_output = 2,
})
assert(value == nil)
assert(err == "base64: decoded output exceeds max_output")
```

La limite est inclusive :

```lua
local value, err = babet.base64.decode("Zm9v", {
    max_output = 3,
})
assert(value, err)
assert(value == "foo")
```

`max_output = 0` accepte uniquement une sortie vide :

```lua
assert(babet.base64.decode("", { max_output = 0 }) == "")
assert(babet.base64.decode("Zg==", { max_output = 0 }) == nil)
```

Pour une valeur Base64 non fiable, fixe une limite adaptée au protocole :

```lua
local png, err = babet.base64.decode(response.value, {
    max_output = 32 * 1024 * 1024,
})
assert(png, err)
```

La limite porte sur la sortie décodée, pas sur la longueur du texte Base64.

<a id="base64-binary"></a>
## Données binaires et fichiers

Base64 n'impose aucun UTF-8. Une chaîne Lua contenant des octets arbitraires est
acceptée :

```lua
local original = "\0\1\2abc\255"
local encoded = assert(babet.base64.encode(original))
local decoded = assert(babet.base64.decode(encoded))
assert(decoded == original)
```

Pour encoder un fichier :

```lua
local file = assert(io.open("capture.png", "rb"))
local data = assert(file:read("*a"))
assert(file:close())

local text, err = babet.base64.encode(data)
assert(text, err)
```

Pour écrire une valeur décodée :

```lua
local data, err = babet.base64.decode(text, {
    max_output = 32 * 1024 * 1024,
})
assert(data, err)

local ok
ok, err = babet.writeFileAtomic("capture-restored.png", data, {
    overwrite = true,
    permissions = tonumber("600", 8),
})
assert(ok, err)
```

`babet.writeFileAtomic()` publie les octets décodés depuis un fichier temporaire
privé créé dans le même dossier et n'expose jamais une image partiellement
écrite.

<a id="base64-worker"></a>
## Utilisation dans un worker

Le sous-module est enregistré dans chaque état Lua worker :

```lua
local job = assert(babet.workers.spawn([[
    local encoded = assert(babet.base64.encode("hello"))
    local decoded = assert(babet.base64.decode(encoded))
    return decoded == "hello"
]]))

local ok, result = job:join()
assert(ok and result == true)
```

Le transport actuel de `worker.args`, du résultat et des files worker repose
toujours sur JSON et refuse les chaînes contenant un octet NUL. Base64 peut
transformer une donnée binaire en texte transportable, mais cette représentation
augmente sa taille d'environ un tiers.

```lua
local encoded = assert(babet.base64.encode(binary_data))
local job = assert(babet.workers.spawn([[
    return assert(babet.base64.decode(worker.args.encoded))
]], { encoded = encoded }))
```

Attention : si le résultat décodé contient un NUL, il ne peut pas être renvoyé
directement par le transport JSON actuel du worker. Le worker doit le traiter,
l'écrire dans un fichier, ou le réencoder avant de le renvoyer.

<a id="base64-errors"></a>
## Contrat d'erreur

### Erreurs d'appel : exception Lua

Les erreurs de programmation lèvent une erreur Lua :

- nombre d'arguments incorrect ;
- donnée ou texte non chaîne ;
- options non table ;
- clé d'option non chaîne ;
- option inconnue ;
- booléen d'option mal typé ;
- `max_output` non entier ou négatif.

```lua
local ok, err = pcall(function()
    babet.base64.decode("Zm9v", { max_output = -1 })
end)
assert(ok == false)
```

### Erreurs de données : `nil, err`

Une entrée Base64 invalide ou une limite dépassée renvoie `nil, err` :

```lua
local value, err = babet.base64.decode("%%%")
assert(value == nil)
assert(type(err) == "string")
assert(err:find("base64:", 1, true) == 1)
```

Les principales formes de message sont :

- `base64: invalid character at byte N` ;
- `base64: invalid padding at byte N` ;
- `base64: truncated input` ;
- `base64: non-zero trailing bits at byte N` ;
- `base64: decoded output exceeds max_output` ;
- `base64: out of memory` ;
- `base64: encoded output too large` ou `decoded output too large`.

Les diagnostics `internal ... mismatch` et `unexpected internal error` sont des
garde-fous : ils ne doivent pas apparaître pour une entrée utilisateur valide ou
invalide ordinaire. Signale-les comme un défaut de Babet s’ils surviennent.

Ne dépends que des raisons documentées lorsque ton script doit distinguer une
limite d'une donnée invalide. Le texte exact des erreurs d'allocation ou des
positions peut être enrichi dans une version future.

<a id="base64-limits"></a>
## Limites et choix de conception

Le module traite une chaîne complète en mémoire. Il ne fournit pas encore :

- d'encodeur ou décodeur en streaming ;
- de lecture/écriture directe de fichiers ;
- de retours à la ligne MIME ;
- de détection automatique entre alphabet standard et URL-safe ;
- de mode permissif acceptant un padding ou des bits finaux non canoniques.

Ces absences sont volontaires. L'API reste petite, déterministe et adaptée aux
captures Selenium, jetons, payloads JSON, petites ressources binaires et
échanges avec des outils externes.
