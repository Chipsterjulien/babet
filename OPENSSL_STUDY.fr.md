# Étude de taille OpenSSL de Babet — Candidate 9

Candidate 9 est un lot **d'observation et de protection**. Il n'ajoute aucune
option OpenSSL `Configure no-*` et ne crée aucune édition publique
`minimal`, `standard` ou `full`.

## Baseline de sécurité d'abord

Candidate 8 utilisait OpenSSL 3.5.6 vendored. Avant toute nouvelle mesure de
composition, Candidate 9 met la dépendance épinglée à jour vers OpenSSL
**3.5.8**.

SHA-256 de l'archive source :

```text
a8f84a39918ec6415ce765d9b429d313ba97b8143169c172e734b9514464f5b2
```

Le cache de build vérifie désormais le répertoire de la version OpenSSL exacte.
Un ancien `build/openssl/openssl-3.5.x/libssl.a` ne peut plus faire croire au
builder que la version courante est déjà compilée.

Les huit mesures Candidate 8 / OpenSSL 3.5.6 restent historiques et ne sont pas
recalculées silencieusement.

## Map exacte, aucun second build de comparaison

`./build_local.sh --size-audit` produit déjà la map GNU ld du lien exact qui
génère `build/size-audit-babet`.

Candidate 9 analyse donc directement cette map. Il ne crée **pas** un second
build CMake avec des flags linker injectés. Cela :

- garantit des flags identiques à la baseline par construction ;
- évite les problèmes `try_compile` lorsque le chemin du projet contient des
  espaces ;
- supprime une source inutile de dérive de mesure.

`tools/measure_openssl_map.sh` copie la map exacte dans
`build/openssl-study/babet.map` et enregistre SHA-256/taille de la baseline,
commit Git quand disponible, architecture, compilateur, ld, strip et provenance
OpenSSL.

## Questions

1. Quels membres de `libcrypto.a` / `libssl.a` entrent dans le lien x86_64 ?
2. Combien d'octets de sections d'entrée leur sont attribuables ?
3. Pourquoi GNU ld les a-t-il extraits lorsque la map expose cette relation ?
4. Quel plafond de revue représentent PQC, provider legacy et algorithmes
   historiques ?
5. Les tests TLS locaux protègent-ils une vraie chaîne de certificats,
   TLS 1.2/1.3, RSA/ECDSA, RSA-PSS, X25519/P-256/P-384,
   AES-GCM/ChaCha20-Poly1305 et `X25519MLKEM768` lorsqu'il est disponible ?
6. Le contrat actuel de recherche du trust store reste-t-il visible et
   fonctionnel sur la machine mainteneur ?

## Matrice de protection TLS

La fixture locale crée :

```text
CA racine -> CA intermédiaire -> certificat serveur
```

Le client ne fait confiance qu'à la racine et le serveur envoie
l'intermédiaire : la construction de chaîne et la validation de l'intermédiaire
sont donc réellement exercées.

Les handshakes ciblés forcent :

- TLS 1.2 + RSA + PKCS#1 + X25519 + AES-GCM ;
- TLS 1.2 + ECDSA + P-256 + AES-GCM ;
- TLS 1.3 + RSA-PSS + X25519 + AES-GCM ;
- TLS 1.3 + RSA-PSS + P-384 + AES-GCM ;
- TLS 1.3 + ECDSA + P-256 + ChaCha20-Poly1305 ;
- TLS 1.3 + RSA-PSS + X25519MLKEM768 + AES-GCM lorsque l'OpenSSL vendored
  expose ce groupe hybride.

Ces tests sont locaux et déterministes. Les sondes HTTPS publiques existantes
restent utiles comme contrôle réel, sans devenir des dépendances tierces
bloquantes.

## Trust store

Le build OpenSSL vendored conserve :

```text
./Configure no-shared --openssldir=/etc/ssl
```

Le runtime TLS de Babet appelle aussi `SSL_CTX_set_default_verify_paths()` et
sonde plusieurs emplacements Linux, dont Debian/Ubuntu/Arch, Fedora/RHEL et
openSUSE. Candidate 9 audite ce contrat existant et exécute une requête HTTPS
publique vérifiée sur la machine mainteneur.

Un test en conteneur sur plusieurs distributions reste un contrôle de
portabilité distinct ; Candidate 9 ne prétend pas que la seule lecture du code
prouve toutes les distributions.

## Garde-fous

- Aucun `no-*` OpenSSL n'est introduit en Candidate 9.
- `no-err` est refusé comme optimisation de release s'il dégrade les diagnostics
  TLS visibles, quel que soit le gain.
- Le classement par famille de nom de fichier est heuristique et ne signifie
  jamais « supprimable sans risque ».
- Le total PQC + legacy + historique n'est qu'un **plafond de revue**, pas une
  économie Configure prédite.
- Une expérience Configure n'est envisagée que si au moins **512 Kio d'octets
  plausiblement supprimables** survivent à la revue des capacités.
- Une acceptation finale demanderait encore **512 Kio réellement gagnés**, tous
  les tests TLS déterministes au vert, aucune perte de capacité publique et
  aucune dégradation de diagnostic utile.
- Les chiffres de taille de cette campagne sont spécifiques à x86_64. ARM devra
  être mesuré séparément avant toute généralisation.

## Exécution

Candidate 9 tient volontairement en une commande :

```sh
./tools/run_candidate9_openssl_study.sh
```

Le runner vérifie ses contrats, construit une baseline `--size-audit` fraîche
avec OpenSSL 3.5.8, analyse exactement cette map, exécute la matrice TLS puis
l'audit du trust store.

## Conclusion mesurée de Candidate 9

La baseline x86_64 OpenSSL 3.5.8 mesure 15 563 592 octets strippés. La map exacte
attribue 5 079 501 octets de sections d'entrée mappées à `libcrypto.a` et 834 788
à `libssl.a`. La matrice TLS protégée termine à 7 PASS / 0 FAIL / 0 SKIP, dont
`X25519MLKEM768` ; le PQC fait donc partie des capacités actuelles protégées et
n'est pas une cible de réduction gratuite.

Après revue de QUIC/DTLS/SRP/CMP/CMS/CT/OCSP/compression et des autres familles
plausiblement optionnelles, le plafond sûr reste sous le seuil d'entrée de
512 KiB, avant même toute conversion entre octets mappés et octets fichier.
Candidate 9 se clôt donc par **STOP : aucune expérience de taille avec des
`Configure no-*` OpenSSL**. OpenSSL 3.5.8 et les protections TLS déterministes
sont conservés.

Candidate 10 explore une autre piste : le garbage collection de sections sans
retirer de capacité cryptographique publique.
