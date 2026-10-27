# Correctif du lot verrou — 26 octobre 2026

Ce correctif s'applique après `babet-lockfile-lot1-2026-10-25.zip`.
Il contient uniquement trois fichiers de code/tests modifiés et cette note.
L'API et la version du projet ne changent pas.

## Cause de l'arrêt

Le journal `babet-tests(20261025-144030).txt` s'arrête deux fois sur le même
contrôle, en mode ASan puis en mode normal :

```text
[FAIL] a Lua binding still contains a direct push_fail() result builder
```

Le nouveau `lockFile.cpp` utilisait encore les constructeurs de résultats
directs `push_fail` et `push_ok`. Les tests isolés du premier lot ne couvraient
pas ce préflight global. La compilation et les tests runtime du verrou n'ont
donc pas été atteints dans ce journal ; les tests réseau ont été ignorés.

## Correction

- Remplacement par `push_fail_protected` et `push_ok_protected`.
- Frontière C++/Lua propre à chacune des méthodes `write` et `close` : les
  constructeurs protégés peuvent convertir une erreur d'allocation Lua en
  marqueur C++, qui doit être intercepté avant de revenir dans les frames C
  de Lua. Le constructeur `lockFile` avait déjà sa frontière.
- Trois scénarios supplémentaires d'OOM pendant les retours des méthodes :
  écriture sur poignée fermée, échec d'écriture et échec de fermeture. Le test
  contrôle l'état du verrou, l'absence de fuite de descripteur et la reprise.
- Injection d'erreur de `close` dans le seul harnais de test, avec libération
  réelle du descripteur avant l'erreur, comme sous Linux.

Le contrôle structurel existant n'a pas été assoupli ni modifié.

## Validation locale

| Contrôle | Résultat |
| --- | --- |
| Reproduction sur le lot livré le 25 octobre | même échec de préflight |
| Préflight des frontières C++/Lua après correction | 230/230 |
| Tous les préflights de `run_tests.sh`, arrêt volontaire avant le build | PASS |
| Harnais natif normal, UBSan et ASan + UBSan | 5 groupes PASS dans chaque mode |
| Contrats interprocessus Python/Lua sur runner isolé normal et ASan + UBSan | 8 groupes PASS dans chaque mode |
| Mutation de contrôle supprimant les frontières des méthodes | échec détecté, `LuaProtectedCallFailure` non interceptée |

Les 60 essais d'allocation déclenchent maintenant 10 échecs effectifs, auxquels
s'ajoutent les trois nouveaux scénarios ciblés des méthodes. Les autres tests
de concurrence, `fork`, `O_CLOEXEC`, SIGKILL et erreurs d'I/O sont conservés.

Les préflights ont été exécutés depuis une copie privée du début du script,
avec la même racine de projet, sans lancer la compilation complète. Le script
livré `run_tests.sh` reste identique à celui du premier lot.

LeakSanitizer reste indisponible ici : même un programme vide instrumenté
échoue à lire `/proc/.../task`. Les essais ASan ont utilisé `detect_leaks=0`.
Le script livré ne désactive pas LSan. Le binding et le harnais sont
instrumentés, l'archive Lua 5.5.1 réutilisée ne l'est pas.

La validation complète du runtime et des workers reste à effectuer chez
l'utilisateur. Extraire ce ZIP à la racine du projet, en conservant les
chemins et en remplaçant les fichiers correspondants, puis lancer :

```bash
./run_tests.sh --release
```

Transmettre ensuite le nouveau `babet-tests.txt`.
