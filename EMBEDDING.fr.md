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

## 8. Règles de thread et effets processus

La première API autorise volontairement **un seul contexte vivant par
processus**. Un second `babet_context_create()` simultané renvoie
`BABET_STATUS_BUSY`.

Un appel réalisé depuis un autre thread que celui ayant créé le contexte renvoie
`BABET_STATUS_WRONG_THREAD` lorsque l'API peut associer l'appel à ce contexte.
Voir [`examples/embedding/06_lifecycle_threads.c`](examples/embedding/06_lifecycle_threads.c).

L'embedding n'est pas une sandbox. Les API Babet qui changent le répertoire
courant, l'environnement, les signaux, les processus enfants ou le terminal
interactif modifient réellement le processus hôte.

## 9. Hôtes C++

Le même header public s'utilise depuis C++ :

```cpp
#include <babet/babet.h>
```

Il active automatiquement `extern "C"`. Conserver les objets C++ et les
exceptions côté hôte. La frontière publique Babet est faite de types C et de
codes de statut ; aucune exception n'est définie comme traversant cette
frontière.

## 10. Compatibilité Linux/glibc

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

## 11. Ce qui reste volontairement différé

La première API n'expose pas encore :

- des fonctions hôte appelables depuis Lua ;
- le marshalling de tables/conteneurs structurés ;
- des handles/callbacks de fonctions Lua arbitraires ;
- la résolution de méthodes pointées ;
- plusieurs résultats ;
- plusieurs contextes simultanés ;
- une ABI partagée `libbabet.so` ;
- une ABI générique de plugins natifs.

Ces sujets restent différés jusqu'à ce qu'un consommateur réel démontre le
besoin. Le prochain consommateur prévu est le prototype FLTK séparé : il
utilisera d'abord l'appel hôte -> Lua existant et consignera précisément ce qui
manque dans l'autre direction.

## 12. Exemples exécutables

Le SDK fournit volontairement plusieurs petits programmes :

| Exemple | But |
| --- | --- |
| `01_hello.c` | minimum create/run/destroy |
| `02_search_root.c` | `require()` depuis une racine de modules hôte |
| `03_values.c` | globals scalaires et chaînes binaires |
| `04_call.c` | appel direct d'une fonction Lua scalaire |
| `05_errors.c` | diagnostics Lua et reprise |
| `06_lifecycle_threads.c` | règles BUSY et WRONG_THREAD |

Ils servent à la fois de documentation **et** de régression : le harnais Babet
les compile et les exécute contre un SDK autonome déplacé.
