> [English](../../en/modules/signal.md) | **Français**

# `babet.signal` — signaux POSIX

Enregistre des callbacks Lua pour les signaux POSIX (`SIGTERM`,
`SIGINT`, `SIGHUP`, …) pour que les scripts long-running puissent
s'arrêter proprement ou recharger leur configuration à la demande.

## Pourquoi

Les scripts Babet long-running (bots, daemons, watchers) doivent
gérer les signaux correctement :

- `SIGTERM` de `systemctl stop` devrait déclencher un arrêt propre.
- `SIGINT` de Ctrl-C devrait faire la même chose.
- `SIGHUP` est le signal conventionnel "reload config".

Sans handlers explicites, ces signaux tuent juste le process,
laissant des fichiers ouverts, des bases de données mi-écrites,
et des enfants orphelins.

## API

| Fonction | Renvoie |
| --- | --- |
| `babet.signal.handle(name, fn)` | `(true, nil)` \| `(nil, err)` — installe le callback Lua |
| `babet.signal.ignore(name)` | `(true, nil)` \| `(nil, err)` — met à `SIG_IGN` |
| `babet.signal.default(name)` | `(true, nil)` \| `(nil, err)` — retour au défaut OS |
| `babet.signal.kill(pid, name)` | `(true, nil)` \| `(nil, err)` — envoie le signal au PID |
| `babet.signal.list()` | `table` de tous les noms de signaux supportés |
| `babet.signal.is_pending()` | `boolean` — y a-t-il un signal géré en file ? |

Noms de signaux acceptés (string, casse sensible) :

`"HUP"`, `"INT"`, `"QUIT"`, `"USR1"`, `"USR2"`, `"PIPE"`,
`"ALRM"`, `"TERM"`, `"CHLD"`, `"CONT"`, `"TSTP"`, `"TTIN"`,
`"TTOU"`, `"WINCH"`. Les autres signaux (`KILL`, `STOP`) ne
peuvent pas être attrapés — POSIX l'interdit.

## Exemple rapide

```lua
local sig = babet.signal
local running = true

sig.handle("TERM", function()
    print("SIGTERM reçu, arrêt en cours")
    running = false
end)
sig.handle("INT", function()
    print("SIGINT reçu, arrêt en cours")
    running = false
end)
sig.handle("HUP", function()
    print("SIGHUP reçu, rechargement config")
    cfg = load_config()
end)

while running do
    local line, err = sock:recv_line(1.0)
    if not line then
        if err == "interrupted" then
            -- Un signal géré est arrivé pendant le recv ; le
            -- callback s'est déjà exécuté. Re-vérifier la condition.
        else
            break
        end
    else
        process(line)
    end
end

print("sortie propre")
```

## Comment les callbacks s'exécutent

Quand un signal arrive :

1. Le kernel positionne un flag pending (aucun code Lua ne tourne
   depuis le signal handler — restrictions async-signal-safe).
2. Si le script est dans un appel bloquant (`recv`, `sleep`,
   `inotify.read`, `accept`, …), l'appel renvoie
   `(nil, "interrupted")`.
3. Avant de renvoyer, Babet dispatche tous les callbacks en
   attente dans l'ordre d'enregistrement, dans le thread Lua
   principal.
4. Le script continue normalement — le callback a pu modifier
   des globales (`running = false` est le pattern typique).

Ça veut dire que les callbacks s'exécutent toujours en contexte
Lua, jamais depuis l'intérieur d'un signal handler. Ils peuvent
utiliser n'importe quelle fonctionnalité Lua (pas de restrictions
async-signal-safe).

**Interaction avec `debug.sethook`** (audit v21) : hors des appels
bloquants, le dispatch s'appuie sur un debug hook Lua
(`lua_sethook`, déclenché périodiquement par compteur
d'instructions). Conséquences : un `debug.sethook(...)` posé par
le script **écrase** ce mécanisme — les callbacks ne seront plus
dispatchés que lorsque le script entre dans un appel bloquant
babet — et réciproquement, le premier `signal.handle(...)`
remplace un hook utilisateur déjà installé. Évite de mélanger
`babet.signal` et `debug.sethook` dans le même script.

## Contrat d'erreur

- **Nom de signal inconnu** → `(nil, "signal: unknown name 'XYZ'")`.
- **Appels interdits depuis un worker thread** → `(nil, "signal:
  not available in worker threads")`. Les signaux sont globaux au
  process ; seul le thread principal les gère.
- **Mauvais types d'argument** → lève via `luaL_error`.
- **`kill(pid, name)`** pour un PID qui n'existe pas ou ne t'appartient
  pas → `(nil, "kill: …")`.

## Décisions de design

- **Callbacks tournent dans le thread Lua principal, pas depuis le
  signal handler**. Les règles async-signal-safety de POSIX
  interdisent la plupart des opérations utiles depuis un vrai
  handler. En marquant le signal comme pending et en dispatchant
  depuis le prochain point sûr, les callbacks peuvent faire tout
  ce que Lua sait faire.
- **Les appels bloquants renvoient `"interrupted"` sur un signal
  géré**. Sans ça, un `recv_line` attendant sur le réseau
  bloquerait jusqu'au timeout malgré l'arrivée de `SIGTERM`. Avec
  ça, l'arrêt peut se faire en millisecondes.
- **Pas de ré-entrance**. Pendant qu'un callback tourne, les
  signaux additionnels sont mis en file et dispatchés ensuite.
- **Interdit dans les worker threads**. Les signaux sont
  process-wide ; seul un thread peut sensément les gérer. Les
  workers doivent utiliser des channels pour la communication
  inter-thread.

## Hors v1

- `sigprocmask` / masquage fin de signaux. Pas souvent nécessaire
  au niveau script.
- Intégration avec `signalfd` pour le polling. Le modèle de
  dispatch actuel est plus simple et couvre les cas typiques.
