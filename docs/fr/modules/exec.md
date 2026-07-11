> [English](../../en/modules/exec.md) | **Français**

# `babet.exec` — exécuter un programme externe

Lance un sous-processus, capture son stdout / stderr, et récupère
son code de sortie sous forme de données structurées. Là où
`os.execute` te donne juste un entier, `babet.exec` te donne
une table de résultat avec tout ce dont tu as réellement besoin.

## Pourquoi

Presque chaque script non trivial finit par shell-out — vers
`git`, `useradd`, `convert`, `ffmpeg`, peu importe. `os.execute`
est trop rudimentaire (pas de sortie capturée, dangers de quoting
shell), et `io.popen` ne te laisse pas à la fois écrire dans
stdin et lire stdout proprement, n'expose pas le code de sortie
sans parsing, et n'a pas de timeout.

`babet.exec` est l'alternative structurée : argv passé en
liste (pas de shell, pas de bugs de quoting), sortie capturée en
mémoire avec cap borné, timeout optionnel, stdout/stderr séparés.

## API

```lua
result, err = babet.exec(cmd, args?, opts?)
```

| Argument | Type              | Notes                                                                                    |
| -------- | ----------------- | ---------------------------------------------------------------------------------------- |
| `cmd`    | string            | Programme à exécuter. PATH est cherché.                                                  |
| `args`   | table (optionnel) | Array d'arguments strings — chacun devient un élément argv séparé, pas de parsing shell. |
| `opts`   | table (optionnel) | Voir ci-dessous.                                                                         |

Champs de `opts` :

| Champ        | Type                       | Défaut     | Notes                                                                                                                                                                                       |
| ------------ | -------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `cwd`        | string                     | hérité     | Dossier de travail pour le child.                                                                                                                                                           |
| `env`        | table `{KEY = value, ...}` | hérité     | **Fusionné** avec l'environnement parent, jamais remplacé. Override : passe la clé. Vider : passe `""` (le child la voit vide). Omettre une clé = **hériter** ; il n'y a pas d'unset en v1. |
| `stdin`      | string                     | `""`       | Données envoyées au stdin du child.                                                                                                                                                         |
| `timeout`    | number (s)                 | aucun      | Au dépassement : **SIGTERM au groupe de processus entier** (arrêt propre possible), 2 s de grâce, puis **SIGKILL**.                                                                         |
| `max_output` | integer (octets)           | **10 Mio** | Cap dur **par flux** sur la sortie capturée (plafond : 2 Gio). L'excès est silencieusement perdu et signalé via `*_truncated`.                                                              |

Table de résultat en cas de lancement réussi :

```lua
{
    stdout = "...",           -- stdout capturé, jusqu'à max_output octets
    stderr = "...",           -- stderr capturé, jusqu'à max_output octets
    code = 0,                 -- code de sortie (0..255)
    timed_out = false,        -- true si tué par le timeout
    stdout_truncated = false, -- true si plus de max_output a été produit
    stderr_truncated = false,
}
```

## Exemples rapides

```lua
-- Capture basique
local r = assert(babet.exec("git", { "rev-parse", "HEAD" }))
if r.code == 0 then
    print("HEAD :", r.stdout:gsub("\n$", ""))
end

-- Code non-zéro n'est PAS une erreur
local r = assert(babet.exec("grep", { "needle", "/etc/passwd" }))
if r.code == 0 then
    print("trouvé :", r.stdout)
elseif r.code == 1 then
    print("pas trouvé")
else
    print("grep a échoué :", r.stderr)
end

-- Pipe des données dans stdin
local r = assert(babet.exec("sha256sum", { "-" }, {
    stdin = "hello world\n",
}))
print(r.stdout)
-- a948904f2f0f479b8f8197694b30184b0d2ed1c1cd2a1ec0fb85d299a192a447  -

-- Augmenter env (sans remplacer)
local r = assert(babet.exec("env", nil, {
    env = { MY_FLAG = "yes" },
}))
-- Le child voit MY_FLAG=yes plus tout ce que le parent avait déjà.

-- Timeout + troncature
local r = assert(babet.exec("yes", nil, {
    timeout = 0.5,
    max_output = 1024,
}))
print(r.timed_out, r.stdout_truncated)  -- true   true

-- cwd différent
local r = assert(babet.exec("ls", nil, { cwd = "/var/log" }))
```

## Contrat d'erreur

- **`(nil, err)`** seulement si le lancement lui-même échoue :
  programme introuvable, `cwd` n'existe pas, fork raté, OOM, etc.
- **`(result, nil)`** pour tous les autres cas, y compris :
  - Le programme a tourné et sorti non-zéro → `result.code > 0`.
  - Le programme a été tué par le timeout → `result.timed_out`
    vaut `true`, `result.code` reflète la sortie par signal.
  - Le programme a produit plus de sortie que `max_output` →
    le flag `*_truncated` concerné vaut `true`, les données
    capturées s'arrêtent au cap.
- **Validation de `opts`** : types invalides (`opts.cwd` pas une
  string, `opts.env` pas une table, clés de `opts.env` avec `=`
  ou NUL, `opts.timeout` ≤ 0 ou NaN/Inf, `opts.max_output` non
  entier ou > 2 GiB) → lève via `luaL_error`. Ce sont des bugs
  côté appelant.

## Décisions de design

- **Code de sortie ≠ erreur**. Le bug le plus courant avec
  `os.execute` / les wrappers `exec` est de traiter une sortie
  non-zéro comme une exception. Beaucoup de programmes utilisent
  les codes de sortie pour des états significatifs (`grep` renvoie
  1 quand pas de match, `diff` renvoie 1 quand les fichiers
  diffèrent, etc.). L'appelant décide de ce qui compte comme
  échec.
- **Pas de shell**. `args` est un array, chaque élément est un
  slot argv, pas besoin de quoting et pas de surprises
  `$(rm -rf $HOME)`. Si tu veux vraiment un shell, passe `"sh"`
  + `{ "-c", "ta commande" }`.
- **`env` fusionne avec le parent**. Remplacer l'environnement
  complet est rarement ce qu'on veut et casse généralement les
  programmes qui s'attendent à `PATH` ou `LANG`. Pour override
  une variable, passe-la. Pour la vider, passe-la en string vide
  et le child la verra vide (POSIX n'a pas de sémantique "unset"
  au moment du exec sans effort supplémentaire).
- **SIGTERM d'abord, SIGKILL ensuite**. Au timeout, le groupe de
  processus entier (le child crée le sien via `setpgid`) reçoit
  SIGTERM — les programmes propres peuvent flusher et sortir —
  puis SIGKILL après 2 s de grâce. `kill(-pid)` couvre aussi les
  descendants (un `sh -c` qui a forké, par exemple).
- **`max_output` est par flux, pas total**. 10 Mio stdout + 10
  Mio stderr est le cap. Assez grand pour capturer la plupart
  des logs de build, assez petit pour qu'un sous-process emballé
  ne puisse pas OOM le process Babet.
- **Cap dur de 2 GiB sur `max_output`**. À peu près tout ce qui
  a besoin de plus de 2 GiB de stdout capturé devrait rediriger
  vers un fichier via un wrapper shell, p. ex.
  `exec("sh", { "-c", "ta-cmd > /tmp/log" })`.
- **`stdin` est une string, pas un callback**. Streamer des
  gigaoctets dans un child est rare et hors scope ; le cas
  courant est "envoie cette petite entrée et lis la réponse".

## Hors v1

- **Interruption par `babet.signal` pendant l'exécution**. `exec`
  n'est pas signal-aware : un signal géré reçu pendant qu'un child
  tourne ne rend pas `(nil, "interrupted")` — le callback est
  dispatché après le retour d'`exec`. Utilise `opts.timeout` pour
  borner les exécutions longues.
- Streaming stdout / stderr (callback ligne-par-ligne pendant
  l'exécution). Actuellement toute la capture est renvoyée d'un
  coup.
- Streaming stdin (callback qui produit des chunks d'input).
- Redirection directe par fd (`stdout = "/tmp/log"`). Facile à
  ajouter plus tard si besoin ; le workaround par wrapper shell
  ci-dessus couvre la plupart des cas.
- Gestion de groupe de process au-delà du child. L'implémentation
  actuelle teardown correctement le groupe de process du child
  sur timeout / interrupt — voir [`security`](../security.md).
