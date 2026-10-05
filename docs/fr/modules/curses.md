> [English](../../en/modules/curses.md) | **Français**

# CURSES — interfaces utilisateur en terminal

`babet.curses` fournit une petite API d'interface terminal UTF-8 basée sur
**ncursesw** lié statiquement. Elle vise les applications interactives plein
écran tout en conservant le principe de déploiement de Babet : un seul fichier.

La première API reste volontairement petite : un seul écran pour le processus,
pas de fenêtres, panels, menus, forms, pointeurs ncurses ou constantes numériques
exposés à Lua.

## Vue d'ensemble de l'API

```lua
babet.curses.start()                 -- true
babet.curses.stop()                  -- true (sûr même si inactif)
babet.curses.clear()                 -- true
babet.curses.refresh()               -- true
local lignes, colonnes = babet.curses.size()
babet.curses.move(ligne, colonne)    -- true ; coordonnées à partir de 1
babet.curses.write(texte)            -- true ; UTF-8 valide obligatoire
local touche, err = babet.curses.readKey([timeout_secondes])
```

Les appels lèvent une erreur Lua si les arguments sont invalides ou si le
terminal/ncurses échoue. Pour `readKey(timeout)`, un délai expiré normal renvoie
`nil, "timeout"`. Une lecture bloquante interrompue sans touche livrée peut
renvoyer `nil, "interrupted"`.

## Démarrer et arrêter

```lua
assert(babet.curses.start())
assert(babet.curses.clear())
assert(babet.curses.move(1, 1))
assert(babet.curses.write("Bonjour é Ω"))
assert(babet.curses.refresh())
local touche = babet.curses.readKey()
assert(babet.curses.stop())
```

`start()` exige que `stdin` et `stdout` soient **le même TTY**, que `TERM` soit
non vide et qu'une locale `LC_CTYPE` UTF-8 soit disponible. Il doit être appelé
sur le thread principal de Babet. Une seconde session simultanée est refusée.

Un `start()` réussi active à la demande le hook Lua partagé des signaux et du
terminal sur le thread Lua principal et la coroutine appelante. Les nouvelles
coroutines héritent du hook de leur créatrice ; les autres coroutines déjà
existantes ne sont pas modifiées. Démarre curses avant de créer les coroutines
qui doivent servir les événements pendant des boucles Lua pures. Le hook reste
installé après `stop()` ; voir son [contrat et son coût](signal.md#signal-debug-hook).

`stop()` est idempotent. Si un enfant interactif possède alors le terminal,
`stop()` termine la session curses logique **sans reprendre le TTY à l'enfant**.
Le gestionnaire de processus normal restaurera ensuite le terminal parent quand
l'enfant se terminera ou s'arrêtera.

La fin normale, une erreur Lua non interceptée, une exception C++ maîtrisée et
les terminaisons par défaut `SIGINT`/`SIGTERM`/`SIGHUP` restaurent le terminal
avant la sortie de Babet. Un crash fatal ou `SIGKILL` ne peut offrir cette
garantie ; la commande `reset` reste le recours manuel classique après un
terminal endommagé.

Dans le CLI et les exécutables générés, `os.exit(...)` restaure aussi curses,
même sans demander la fermeture Lua. Les codes de sortie sont conservés.
Voir le [contrat de sortie](../runtime-exit.md) pour les finaliseurs, les
workers actifs et les callbacks natifs.

## Opérations d'écran

`size()` renvoie `(lignes, colonnes)` sous forme d'entiers positifs.

`move(ligne, colonne)` utilise des coordonnées **à partir de 1**. Une position
hors écran lève une erreur.

`write(texte)` écrit de l'UTF-8 valide à la position courante. Les NUL intégrés
et l'UTF-8 invalide sont refusés. L'affichage n'est pas automatiquement poussé :
utiliser `refresh()` lorsque la mise à jour doit devenir visible.

`clear()` efface l'écran standard et `refresh()` publie les changements en
attente.

## Lecture clavier

```lua
local touche, err = babet.curses.readKey(0.5)
if not touche and err == "timeout" then
    -- aucune entrée pendant 500 ms
elseif touche == "up" then
    -- flèche haut
elseif touche == "resize" then
    local lignes, colonnes = babet.curses.size()
end
```

Les caractères ordinaires sont renvoyés comme chaînes Lua UTF-8. Les touches
spéciales utilisent des noms symboliques stables plutôt que les nombres ncurses :

`up`, `down`, `left`, `right`, `home`, `end`, `page_up`, `page_down`,
`backspace`, `delete`, `insert`, `enter`, `resize` et `f1` à `f63`.
Une autre touche spéciale reconnue par ncurses renvoie `"special"`.

`SIGWINCH` est coalescé puis traité sur le thread principal. Une fois la nouvelle
taille appliquée, `readKey()` renvoie l'événement symbolique `"resize"`.

Si un callback de signal appelle `curses.stop()` pendant `readKey`, la lecture
renvoie `nil, "interrupted"`, même sans timeout. Elle n'accède plus à l'écran
libéré, y compris si une touche avait été lue juste avant le callback.

## Processus enfants interactifs

Babet conserve **un seul propriétaire du terminal interactif à la fois**. Depuis
le thread principal, un enfant interactif fonctionne naturellement pendant une
session curses :

```lua
assert(babet.curses.start())

local p = assert(babet.spawn("sh", {}, {
    stdin = "inherit",
    stdout = "inherit",
    stderr = "inherit",
}))
local resultat = assert(p:wait())
p:close()

-- curses est à nouveau restauré sur le thread principal
assert(babet.curses.write("enfant terminé"))
assert(babet.curses.refresh())
assert(babet.curses.stop())
```

Avant de céder le TTY, Babet sauvegarde le mode programme curses et quitte
curses. Le gestionnaire terminal existant donne alors le premier plan au groupe
de processus de l'enfant. À sa fin ou à son arrêt, le thread moniteur n'effectue
que la récupération POSIX ; la restauration ncurses elle-même est différée sur
le thread principal.

Un processus interactif arrêté peut être repris au premier plan avec
`process:resume(true)` par le même mécanisme.

## Workers

Les appels ncurses sont réservés au thread principal. Dans un worker :

- toute opération `babet.curses.*` est refusée ;
- un `babet.spawn()` interactif héritant du terminal est refusé tant que la
  session curses principale est active ;
- les processus non interactifs utilisant pipes/fichiers/null restent permis.

Cela évite tout accès ncurses multithread et toute ambiguïté de propriétaire du
TTY.

## Signaux

Babet reste propriétaire de la politique des signaux pendant curses :

- `SIGWINCH` devient un événement `"resize"` différé ;
- Ctrl-Z (`SIGTSTP`) restaure le terminal avant la suspension, puis curses est
  réactivé après `SIGCONT` ;
- les handlers `babet.signal` de `INT`, `TERM` et `HUP` restent prioritaires ;
- si ces signaux gardent leur action système par défaut, Babet restaure curses
  sur le thread principal avant de relancer le signal avec son action par défaut.

Aucune fonction ncurses n'est appelée depuis un handler de signal fatal.

## TERM et terminfo

Babet préfère la base terminfo du système. Son ncursesw statique embarque aussi
les fallbacks suivants :

```text
linux, vt100, xterm, xterm-256color,
screen, screen-256color, tmux, tmux-256color
```

Les terminaux courants restent ainsi utilisables même sans arborescence terminfo
système, y compris dans un exécutable généré autonome. Babet ne remplace jamais
silencieusement un `TERM` inconnu. Un `TERM` absent/inconnu ou un terminfo
inutilisable devient une erreur Lua normale au lieu de laisser ncurses quitter
le processus.

## Déploiement

ncursesw est lié statiquement au runtime Babet normal. `--create-exe` n'a donc
besoin ni de compilateur, ni de linker, ni de `libncursesw.so`, ni de dossier
terminfo externe lors de la création ou à l'exécution. Une application générée
embarque le même runtime curses que le vrai binaire Babet.
