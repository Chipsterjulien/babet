# Embarquer Babet depuis du C/C++

Ce guide est le compagnon orienté développeur de
[`EMBEDDING_DESIGN.md`](EMBEDDING_DESIGN.md). Le document de conception explique
*pourquoi* la frontière d'embedding a cette forme ; celui-ci explique comment
l'utiliser.

L'API d'embedding reste **expérimentale**. Le Lot 8 l'exerce volontairement avec
de petits programmes autonomes avant toute promesse de stabilité ABI.

## 1. Contenu du SDK

Un build normal de Babet produit :

```text
build/embedding-sdk/
├── include/babet/babet.h
├── lib/libbabet.a
├── EMBEDDING.md
├── EMBEDDING.fr.md
├── HOST_FUNCTIONS_DESIGN.md
└── examples/embedding/
```

`libbabet.a` est une archive statique aplatie contenant le runtime Babet et les
archives statiques tierces épinglées dont il a besoin. Le CLI officiel `babet`
reste autonome et ne dépend pas d'un `libbabet.so`.

La frontière publique est en C, même pour un hôte C++. Aucun type interne Lua ou
C++ n'est exposé par `babet.h`.

## 2. Compilation minimale

Pour un hôte C :

```sh
cc -std=c99 -Wall -Wextra -Werror \
  -I/chemin/vers/sdk/include -c host.c -o host.o
c++ host.o /chemin/vers/sdk/lib/libbabet.a \
  -ldl -pthread -lm -o host
```

Le lien final doit utiliser un **driver C++**, car Babet est lui-même implémenté
en C++. Sur une cible Linux 32 bits, ajouter `-latomic`.

Le SDK fournit aussi un petit projet CMake dans `examples/embedding/` :

```sh
cmake -S /chemin/vers/sdk/examples/embedding -B build \
  -DBABET_SDK_DIR=/chemin/vers/sdk
cmake --build build
ctest --test-dir build --output-on-failure
```

## 3. Programme minimal

[`examples/embedding/01_hello.c`](examples/embedding/01_hello.c) montre le cycle
minimal complet :

1. `babet_context_create()` ;
2. `babet_context_run()` ;
3. `babet_context_destroy()`.

Un contexte est un handle opaque. Un seul contexte peut vivre à la fois dans le
processus et il doit être utilisé puis détruit par le thread qui l'a créé.

## 4. Statuts et diagnostics

Chaque opération renvoie un `babet_status`. `babet_status_name()` fournit son
nom symbolique stable. Lorsqu'une opération associée à un contexte vivant
produit un diagnostic détaillé, `babet_context_last_error()` permet de le lire.

Exemple :

```c
babet_status status = babet_context_run(ctx, code, code_len, "mon-chunk");
if (status != BABET_STATUS_OK) {
    fprintf(stderr, "%s: %s\n",
            babet_status_name(status),
            babet_context_last_error(ctx));
}
```

Ne pas supposer que chaque rejet d'argument ou de cycle de vie possède un texte
détaillé. Le code de statut fait foi ; `last_error()` apporte un contexte
supplémentaire lorsqu'il existe. Un appel mutateur suivant peut remplacer ce
diagnostic.

[`examples/embedding/05_errors.c`](examples/embedding/05_errors.c) provoque une
erreur Lua, affiche son diagnostic, puis prouve que le même contexte peut
continuer avec une exécution valide.

## 5. Racine de recherche des modules

L'embedding démarre sans racine de modules Lua sur disque. Elle se configure
explicitement avec `babet_context_set_search_root()` **avant le premier appel
d'exécution**.

Le répertoire est résolu en chemin absolu puis ajouté devant `package.path` avec
les mêmes formes que le mode dossier de Babet :

```text
<racine>/?.lua
<racine>/?/init.lua
```

La même racine est transmise aux workers Babet créés depuis ce contexte.

L'API actuelle n'accepte qu'une seule configuration. Un chemin absent, un
fichier régulier, une seconde configuration ou une modification après le début
de l'exécution sont refusés.

Voir [`examples/embedding/02_search_root.c`](examples/embedding/02_search_root.c)
et le module fourni dans `examples/embedding/modules/`.

## 6. Valeurs scalaires C -> Lua et Lua -> C

`babet_value` prend exactement cinq formes :

| Type API C | Valeur Lua |
| --- | --- |
| `BABET_VALUE_NIL` | `nil` |
| `BABET_VALUE_BOOLEAN` | booléen |
| `BABET_VALUE_INTEGER` | entier signé 64 bits |
| `BABET_VALUE_NUMBER` | nombre (`double`) |
| `BABET_VALUE_STRING` | chaîne d'octets |

`babet_context_set_global()` publie un global scalaire vers Lua et
`babet_context_get_global()` en relit un.

Les chaînes ont une longueur explicite et peuvent contenir des octets NUL. Pour
une chaîne en entrée, `data == NULL` n'est valide que si `length == 0`.

Pour une chaîne renvoyée par `get_global()` ou `call_global()`, le pointeur est
**emprunté au contexte**. Il reste valide seulement jusqu'au prochain appel
mutateur sur ce contexte ou jusqu'à sa destruction. Le copier si l'hôte doit le
conserver davantage.

Tables, fonctions, userdata et threads ne sont volontairement pas marshallés et
renvoient `BABET_STATUS_UNSUPPORTED_VALUE`.

Voir [`examples/embedding/03_values.c`](examples/embedding/03_values.c), qui
inclut une chaîne binaire contenant des NUL.

## 7. Appeler une fonction globale Lua

`babet_context_call_global()` recherche une fonction directement dans la table
globale principale, lui passe zéro ou plusieurs arguments scalaires et demande
exactement un résultat.

Sémantique actuelle :

- aucun résultat Lua -> `nil` ;
- plusieurs résultats -> les résultats supplémentaires sont ignorés ;
- résultat structuré -> `BABET_STATUS_UNSUPPORTED_VALUE` ;
- cible absente/non fonction ou erreur Lua -> `BABET_STATUS_LUA_ERROR` ;
- une résolution pointée comme `objet.methode` n'appartient pas à cette première API.

Voir [`examples/embedding/04_call.c`](examples/embedding/04_call.c).

## 8. Enregistrer des fonctions hôte appelables depuis Lua

Le Lot 10 ajoute le sens inverse sans exposer `lua_State *` :

```c
static babet_status host_greet(babet_host_call *call, void *userdata)
{
    const size_t count = babet_host_call_argument_count(call);
    const babet_value *args = babet_host_call_arguments(call);
    if (count != 1 || args == NULL || args[0].type != BABET_VALUE_STRING) {
        (void)babet_host_call_set_error(call, "greet attend une chaîne");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    babet_value result = {0};
    result.type = BABET_VALUE_STRING;
    result.as.string.data = "bonjour depuis C";
    result.as.string.length = 15;
    return babet_host_call_set_result(call, &result);
}

babet_context_register_host_function(ctx, "greet", host_greet, userdata);
```

Lua appelle ensuite :

```lua
local message = babet.host.greet("Lua")
```

Le nom d'enregistrement est copié et doit être un identifiant Lua ASCII simple ; les mots-clés réservés Lua sont refusés afin que le nom reste toujours appelable sous la forme `babet.host.<nom>`.
Le `userdata` reste propriété de l'hôte et doit rester valide jusqu'à la
destruction du contexte ; le Lot 10 n'ajoute volontairement aucun unregister.

Les arguments utilisent les mêmes cinq formes scalaires `babet_value`. Le tableau
d'arguments et les chaînes qu'il contient sont empruntés seulement pendant le
callback. `babet_host_call_set_result()` copie immédiatement une chaîne de
résultat : le callback peut donc fournir un buffer local/temporaire. Sans setter
de résultat, Lua reçoit `nil`.

Pour signaler un échec, le callback peut copier un diagnostic avec
`babet_host_call_set_error()` puis renvoyer un `babet_status` non OK. Lua reçoit
une erreur normale, rattrapable avec `pcall`. Si elle s'échappe, l'appel externe
`babet_context_run()` / `call_global()` renvoie `BABET_STATUS_LUA_ERROR` et le
diagnostic du contexte contient le nom/statut/message du callback hôte.

Les callbacks sont synchrones sur le thread propriétaire du contexte et ne sont
installés que dans l'état Lua principal, jamais automatiquement dans les
workers. Réentrer dans l'API publique `babet_context_*` depuis un callback est
volontairement refusé avec `BABET_STATUS_REENTRANT_CALL`. Un callback C++ peut
utiliser C++ en interne, mais Babet contient toute exception avant le retour à
Lua.

Voir [`examples/embedding/07_host_functions.c`](examples/embedding/07_host_functions.c)
et [`HOST_FUNCTIONS_DESIGN.md`](HOST_FUNCTIONS_DESIGN.md).

## 9. Règles de thread et effets processus

La première API autorise volontairement **un seul contexte vivant par
processus**. Un second `babet_context_create()` simultané renvoie
`BABET_STATUS_BUSY`.

Un appel réalisé depuis un autre thread que celui ayant créé le contexte renvoie
`BABET_STATUS_WRONG_THREAD` lorsque l'API peut associer l'appel à ce contexte.
Voir [`examples/embedding/06_lifecycle_threads.c`](examples/embedding/06_lifecycle_threads.c).

L'embedding n'est pas une sandbox. Les API Babet qui changent le répertoire
courant, l'environnement, les signaux, les processus enfants ou le terminal
interactif modifient réellement le processus hôte.

## 10. Hôtes C++

Le même header public s'utilise depuis C++ :

```cpp
#include <babet/babet.h>
```

Il active automatiquement `extern "C"`. Conserver les objets C++ et les
exceptions côté hôte. La frontière publique Babet est faite de types C et de
codes de statut ; aucune exception n'est définie comme traversant cette
frontière.

## 11. Compatibilité Linux/glibc

`file` peut afficher une mention comme `for GNU/Linux 3.2.0`. Ce n'est **pas**
une promesse de version minimale de glibc ; cela décrit des métadonnées ABI
ELF/kernel.

Pour relever le plus haut symbole glibc versionné requis par un exécutable final :

```sh
objdump -T ./hote \
  | grep 'GLIBC_' \
  | sed -n 's/.*GLIBC_\([0-9][0-9.]*\).*/\1/p' \
  | sort -uV \
  | tail -1
```

Lancer cette commande à la fois sur le binaire officiel `babet` et sur
l'exécutable hôte lié avec le SDK. Les deux valeurs peuvent différer.

Le SDK est une **archive statique** : la compatibilité finale dépend donc aussi
du compilateur, du linker, de la libc et de l'environnement de build de l'hôte.
Babet ne promet actuellement aucun seuil fixe `glibc >= X` pour tous les
programmes créés avec le SDK. Pour viser de vieilles distributions, construire
et tester dans un environnement/sysroot ancien maîtrisé plutôt que supposer
qu'un binaire lié sur une distribution rolling récente fonctionnera sur une
ancienne stable.

La régression runtime d'embedding affiche, lorsque `objdump` est disponible, la
version `GLIBC_*` la plus haute mesurée pour le Babet maintenu et pour son hôte
SDK externe fraîchement lié. Ces valeurs décrivent ce build ; elles ne
constituent pas une garantie ABI universelle.

## 12. Ce qui reste volontairement différé

La première API n'expose pas encore :

- le marshalling de tables/conteneurs structurés pour les callbacks hôte ou les appels directs ;
- le désenregistrement/remplacement de callbacks hôte pendant la vie du contexte ;
- les appels `babet_context_*` réentrants depuis un callback hôte ;
- des handles/callbacks de fonctions Lua arbitraires ;
- la résolution de méthodes pointées ;
- plusieurs résultats ;
- plusieurs contextes simultanés ;
- une ABI partagée `libbabet.so` ;
- le chargement de plugins natifs depuis un contexte d'embedding externe.

Ces capacités d'embedding restent différées jusqu'à ce qu'un consommateur réel
démontre le besoin. Le Lot 11 définit séparément une ABI étroite de plugins
natifs pour le CLI Babet original ; il n'élargit pas la frontière de chargement
de l'embedding. Le prototype FLTK séparé est maintenant le premier consommateur réel de
l'API publique de fonctions hôte : Lua change le libellé du bouton via
`babet.host.set_button_label()` sans pont privé.

## 13. Exemples exécutables

Le SDK fournit volontairement plusieurs petits programmes :

| Exemple | But |
| --- | --- |
| `01_hello.c` | minimum create/run/destroy |
| `02_search_root.c` | `require()` depuis une racine de modules hôte |
| `03_values.c` | globals scalaires et chaînes binaires |
| `04_call.c` | appel direct d'une fonction Lua scalaire |
| `05_errors.c` | diagnostics Lua et reprise |
| `06_lifecycle_threads.c` | règles BUSY et WRONG_THREAD |
| `07_host_functions.c` | enregistrer un callback C appelable via `babet.host.*` |

Ils servent à la fois de documentation **et** de régression : le harnais Babet
les compile et les exécute contre un SDK autonome déplacé.

### Frontière plugins natifs (Lot 11)

Le SDK développeur fournit aussi `include/babet/plugin.h` et les exemples de
plugins natifs, car ils réutilisent la surface scalaire publique
`babet_host_call_*`. Cela ne signifie pas qu'un hôte d'embedding arbitraire peut
charger ces plugins au Lot 11 : dans un contexte Lua embarqué,
`babet.plugin.load()` renvoie une erreur contrôlée indiquant que le chargement
natif est indisponible pour les hôtes d'embedding. Le premier loader reste
volontairement limité au binaire CLI Babet original, dont Babet maîtrise les
symboles ELF exportés.
