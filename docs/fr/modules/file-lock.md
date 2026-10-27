> **Français** | [English](../../en/modules/file-lock.md)

# lockFile — verrou exclusif de fichier

**Disponible depuis Babet 2.34.0.**
Cette API n’est pas disponible dans Babet 2.33.0 ni les versions précédentes.

`babet.lockFile(path)` permet à des processus coopérants de réserver une
ressource, par exemple un dossier de données avec un seul processus écrivain.
Cette primitive Linux est indépendante de GTK, disponible dans le runtime,
les workers et l'embedding. Elle utilise `flock(LOCK_EX | LOCK_NB)` ; elle
n'utilise pas les verrous POSIX `fcntl(F_SETLK)`.

## API

| Appel | Résultat |
| --- | --- |
| `babet.lockFile(path)` | `handle, nil`, ou `nil, "locked"` si déjà verrouillé, ou `nil, message` pour une erreur système |
| `handle:write(text)` | `true, nil`, ou `nil, message` ; remplace le contenu sur le même inode |
| `handle:close()` | `true, nil`, ou `nil, message` ; fermer à nouveau est sans effet et réussit |

Chaque appel renvoie exactement deux valeurs. Une arité ou un type incorrect,
un chemin vide ou contenant NUL provoque une erreur Lua. `write` accepte une
chaîne binaire, y compris vide et contenant NUL. Écrire après fermeture échoue.

Le chemin désigne un fichier régulier. S'il n'existe pas, Babet le crée avec
le mode `0600`, réduit éventuellement par l'umask. S'il existe, son contenu et
ses permissions sont conservés à l'acquisition, même quand celle-ci échoue.
Les liens symboliques vers un fichier existant et les liens physiques
désignent le même verrou. Un lien symbolique pendant est refusé : Babet ne
crée pas sa cible. Les dossiers, FIFO et périphériques sont refusés avant
ouverture pour lecture/écriture.

`lockFile` n'attend pas qu'un verrou occupé se libère. Les opérations de
fichiers peuvent toutefois attendre le système de fichiers. Une poignée
reste valable jusqu'à `close()`, la sortie de sa portée `<close>`, sa collecte
Lua ou la fermeture de son état Lua. Garder une référence ou, de préférence,
une variable `<close>` pour toute la durée d'utilisation du dossier. Sortir
de `gui.run()` ne ferme pas automatiquement ce verrou.

## Un écrivain par dossier

```lua
local directory = "/chemin/vers/mes-donnees"
local path = directory .. "/.basket.lock"
local lock, err = babet.lockFile(path)
if not lock then
    if err == "locked" then
        -- Une lecture du PID est facultative : le fichier peut être vide,
        -- illisible ou en cours de mise à jour. Le verrou reste l'autorité.
        io.stderr:write("Ce dossier est déjà ouvert.\n")
    else
        io.stderr:write(tostring(err), "\n")
    end
    return
end
local guard <close> = lock
assert(lock:write(tostring(babet.pid()) .. "\n"))

-- Ouvrir la base et lancer l'application seulement après l'acquisition.
-- Garder guard en portée pendant les écritures, sauvegardes/restaurations
-- et la fermeture de la base. Plusieurs fenêtres peuvent partager ce verrou.
```

Babet n'écrit aucun PID automatiquement. `write` permet à l'application
d'ajouter ses métadonnées sans réouverture du fichier. Une ouverture séparée
du même inode, suivie de sa fermeture, ne libère pas ce verrou `flock`.
Le PID éventuellement lu est une indication : il peut être ancien, absent,
partiel ou réutilisé. Ne pas décider qu'un verrou est libre à partir de lui,
ni tuer automatiquement le processus indiqué.

**Le fichier de verrou doit rester permanent.** Ne jamais le supprimer,
renommer ou remplacer, même après fermeture. Exclure ce fichier des opérations
de restauration, nettoyage et remplacement atomique. Sinon deux processus
pourraient verrouiller deux inodes différents sous le même nom. Des chemins
différents ne désignant pas le même inode ont des verrous indépendants.

## Processus, workers et erreurs

- Les descripteurs sont ouverts avec `O_CLOEXEC` : un programme exécuté après
  lancement ne garde pas le verrou. Après un `fork()` libc, un gestionnaire
  enfant ferme les descripteurs hérités avec `close()`, sans `LOCK_UN`, et
  invalide les poignées copiées. Le verrou du parent reste actif. Le parent
  peut reprendre avant ce gestionnaire ; une contention transitoire reste
  possible jusqu'à son exécution. Les forks par appel système brut et
  l'utilisation de Lua après `vfork()` ne sont pas couverts.
- Les workers Babet sont des threads avec des états Lua distincts. Leurs
  acquisitions séparées entrent en concurrence avec celle du thread principal.
  Fermer un worker libère ses poignées sans libérer celles d'un autre état.
- La fin du processus, y compris `kill -9`, libère ses descripteurs. Le fichier
  et ses métadonnées restent sur disque. L'embedding ferme les poignées lors
  de la destruction de l'état Lua.
- Une erreur de `write`, même après une écriture partielle, **conserve le
  verrou**. L'écriture reprend les appels interrompus et traite les écritures
  courtes. La troncature à la nouvelle longueur intervient après l'écriture.
  Les lecteurs non verrouillés peuvent voir des données partielles ; il n'y
  a ni publication atomique, ni garantie de durabilité (`fsync`). Cette méthode
  sert aux métadonnées du verrou, pas à sauvegarder les données de l'application.

`write` est synchrone dans son état Lua, sans garder le verrou interne du
registre commun au processus : les autres états peuvent acquérir des verrous
et les autres threads peuvent appeler `fork()` pendant une écriture lente.
L’acquisition et la fermeture gardent ce verrou interne pour synchroniser les
descripteurs avec le nettoyage après `fork()` ; des appels système lents à ces
endroits peuvent retarder les autres acquisitions, fermetures et `fork()`.

## Limites

Le verrou est consultatif : tous les écrivains doivent utiliser le même fichier.
Le contrat vise les systèmes de fichiers Linux locaux ; les garanties NFS/SMB
dépendent du serveur et du montage. `locked` signifie seulement que `flock`
a signalé une contention ; les permissions insuffisantes et autres erreurs
ont un autre diagnostic.

Pour vérifier un fichier existant sans ouvrir un périphérique par erreur,
Babet épingle son inode avec `O_PATH`, puis le rouvre via `/proc/self/fd`.
Il faut donc procfs accessible, y compris dans un hôte d'embedding. Le dossier
de données doit être contrôlé par l'application et ne pas être remplacé par
un autre processus pendant son utilisation.
