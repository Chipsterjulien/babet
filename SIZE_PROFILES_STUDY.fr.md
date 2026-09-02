# Étude de taille binaire et des profils de compilation

Statut : la campagne de mesure Candidate 8 est close ; aucune gamme publique de
profils n'est prévue. Candidate 9 étudie maintenant la contribution d'OpenSSL
sans retirer de capacité publique.

## Invariant produit

Babet reste centré sur `--create-exe` : un projet Lua peut devenir un unique
exécutable autonome sans compilateur/linker sur la machine qui exécute
`--create-exe`.

`--create-exe` embarque le runtime Babet utilisé comme builder. Il n'analyse
**pas** l'application Lua pour relinker un runtime natif réduit. Cette
distinction est essentielle pour la décision sur les profils.

## Phase 1 — attribution sans modifier les fonctionnalités

`./build_local.sh --size-audit` compile le Babet normal, produit la map GNU ld
`build/project_build/babet-link.map`, le binaire strippé de mesure
`build/size-audit-babet` et le rapport d'attribution grossier
`build/size-audit.txt`.

L'attribution regroupe les octets de sections d'entrée par grandes familles :
GUI, ncursesw, SQLite, archive/compression, réseau/TLS/WebSocket, RE2/Abseil,
plugins, embedding, workers, process/pipeline et packaging `--create-exe`.

Il ne s'agit **pas** d'une mesure des octets supprimables. Le code partagé, les
dépendances statiques, les alignements, les données produites par le linker et
les références croisées rendent les catégories non additives. La phase 1 sert
uniquement à choisir les candidats à mesurer réellement.

La première attribution x86_64, sur un binaire strippé de 15 559 496 octets, a
retenu SQLite, `find`+RE2, réseau et archive/compression. OpenSSL apparaissait
également très lourd, mais partagé entre le réseau et les hash de fichiers.

## Phase 2 — mesures différentielles réelles

`tools/measure_size_deltas.sh` réalise des builds expérimentaux mainteneur
contre la même baseline strippée. Candidate 8 a mesuré huit variantes :

| Variante | Taille | Gain | Baseline |
|---|---:|---:|---:|
| `without-sqlite` | 14 247 816 | 1 311 680 | 8,43 % |
| `without-find-re2` | 14 719 392 | 840 104 | 5,40 % |
| `without-network` | 13 405 672 | 2 153 824 | 13,84 % |
| `without-archive-compression` | 13 741 704 | 1 817 792 | 11,68 % |
| `without-hashing` | 15 526 728 | 32 768 | 0,21 % |
| `without-network-hashing` | 7 828 840 | 7 730 656 | 49,68 % |
| `without-four-large` | 9 407 392 | 6 152 104 | 39,54 % |
| `without-four-large-hashing` | **3 830 560** | **11 728 936** | **75,38 %** |

Le hashing seul ne coûte que 32 768 octets tant que le réseau nécessite encore
OpenSSL. Lorsque réseau et hashing disparaissent ensemble, l'effet partagé vaut :

```text
7 730 656 - 2 153 824 - 32 768 = 5 544 064 octets
```

Le même effet marginal apparaît après retrait des quatre gros blocs : SQLite,
`find`/RE2 et archive/compression ne participent donc pas à cette interaction
réseau↔hashing/OpenSSL.

La somme des quatre deltas unitaires vaut 6 123 400 octets alors que
`without-four-large` économise 6 152 104 octets, soit seulement 28 704 octets
d'interaction supplémentaire. Ces quatre blocs sont donc très séparables dans
ce build x86_64.

## Décision Candidate 8 — pas de profils publics

Le critère était volontairement asymétrique : un petit gain peut arrêter
immédiatement une idée, tandis qu'un gros gain autorise seulement son étude.
L'adoption exige encore que la complexité permanente reste faible.

Candidate 8 franchit le seuil numérique mais échoue sur le coût produit.

Un utilisateur qui télécharge un Babet réduit obtient un runtime réduit. Les
exécutables construits avec lui héritent du même runtime ; ils ne deviennent
pas petits simplement parce que leur Lua n'utilise pas SQLite, HTTP ou les
archives.

Des profils publics `minimal` / `standard` / `full` imposeraient donc une
matrice permanente de capacités, de tests, de documentation et de dépendances
pour les projets/bibliothèques Lua Babet. Aucune demande utilisateur ne justifie
actuellement cette complexité.

**Aucun profil public `minimal` / `standard` / `full` n'est introduit.**

Les switches CMake expérimentaux restent des outils de mesure mainteneur et
peuvent documenter les possibilités de builds personnalisés. Ils ne constituent
pas des éditions produit supportées.

## Candidate 9 — composition OpenSSL avant optimisation

Candidate 8 a révélé une grosse contribution OpenSSL partagée. Il faut
maintenant savoir si une partie significative peut disparaître **sans** perdre
de capacité TLS, cryptographique ou de diagnostic.

Candidate 9 n'ajoute donc aucune option OpenSSL `Configure no-*`. Il commence par :

1. mettre la baseline de sécurité vendored à jour d'OpenSSL 3.5.6 vers 3.5.8 ;
2. analyser exactement la map produite par le nouveau `--size-audit` ;
3. attribuer `libcrypto.a` / `libssl.a` par membre d'archive et conserver les
   causes d'extraction GNU ld lorsqu'elles sont disponibles ;
4. renforcer les tests TLS locaux avec une chaîne racine → intermédiaire →
   serveur et des cas forcés de protocole/chiffrement/groupe/signature ;
5. auditer le contrat existant de recherche du trust store système.

Les conclusions de taille restent spécifiques à x86_64. La composition ARM peut
différer et devra être mesurée séparément avant toute généralisation.

Voir `OPENSSL_STUDY.fr.md` pour les garde-fous détaillés de Candidate 9.
