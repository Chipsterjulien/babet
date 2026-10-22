# Correction du contrôle des journaux de tests — 21 octobre 2026

## Diagnostic

Les deux journaux reçus correspondent à la même exécution. Ils s'arrêtent au
contrôle des exclusions Git, avec 136 contrats GUI réussis et un échec :
`Git ignores all babet-tests*.txt release logs`.

La compilation et les tests du runtime ne commencent pas. Les statuts d'échec
ASan et normal résultent de ce préflight ; ils ne démontrent donc pas un défaut
GUI ni une erreur mémoire.

L'archive précédente contenait bien le `.gitignore` modifié. Les journaux ne
permettent cependant pas de déterminer si ce fichier caché a été extrait, si
une règle locale prend le dessus ou si la configuration Git personnelle
perturbe le contrôle.

Un défaut du contrôle précédent a été reproduit : avec la bonne règle
`babet-tests*.txt`, un modèle Git personnel ajoutant `*.lua` dans `info/exclude`
provoque le même diagnostic générique. Cette reproduction confirme la
fragilité du test, sans établir que c'est la cause rencontrée sur la machine
de Julien.

## Correction

- Le contrôle utilise un dépôt temporaire sans configuration Git système ou
  personnelle, sans modèle hérité et sans exclusions globales.
- Les diagnostics distinguent les journaux non exclus, une exclusion trop
  large qui masque le fichier source témoin et une erreur d'exécution de Git.
- Le préflight reste en lecture seule.
- L'option explicite `--repair` ajoute la règle à la fin du `.gitignore`
  seulement si nécessaire. Elle conserve les octets existants et les droits
  du fichier, gère les fins de ligne CRLF et peut être relancée sans doublon.
  Si `.gitignore` est absent, elle demande de le restaurer et ne crée pas un
  remplacement incomplet.
- Dix régressions ciblées sont intégrées au contrôle structurel GUI, dont le
  cas du modèle Git personnel, les chemins avec espaces et apostrophe, la
  conservation des règles et les erreurs Git.

L'archive de correction contient uniquement les trois scripts concernés et
cette note. Elle ne remplace pas `.gitignore`, afin de conserver les règles
personnelles présentes dans le projet destinataire.

## Application et vérification

Appliquer ce correctif après les précédents correctifs desktop, en extrayant
son contenu à la racine du projet. Depuis cette racine, lancer dans Bash :

```bash
set -o pipefail
(
  python3 tools/test_log_ignore.py --repair &&
  ./run_tests.sh --release
) 2>&1 | tee babet-tests-desktop-validation.txt
```

Transmettre ensuite `babet-tests-desktop-validation.txt`, y compris en cas
d'échec : ce fichier contient aussi le diagnostic de la réparation.

## Validation du correctif

- Régressions du contrôle et de la réparation : **10 PASS / 0 FAIL**.
- Contrats structurels GUI : **137 PASS / 0 FAIL**.
- Contrôle négatif : l'ancien test échoue avec une règle de projet correcte
  et un modèle Git personnel contenant une exclusion `*.lua`.
- Syntaxe Python et Bash vérifiée.

Aucun fichier du runtime n'est modifié. La compilation et la suite complète
`--release` n'ont pas été relancées pour ce correctif de préflight : leur
résultat reste à confirmer sur la machine de Julien. La version et les
manuels PDF restent inchangés.
