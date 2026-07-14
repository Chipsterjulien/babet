> [English](../../en/modules/logging.md) | **Français**

# `logging` — journalisation à niveaux

`logging` est un module Lua pur embarqué dans Babet. Il se charge avec
`require("logging")` et ne fait pas partie de la table `babet`.

```lua
local log = require("logging")
```

Il expose cinq niveaux :

| Niveau | Valeur |
| --- | ---: |
| `log.TRACE` | `10` |
| `log.DEBUG` | `20` |
| `log.INFO` | `30` |
| `log.WARN` | `40` |
| `log.ERROR` | `50` |

Il n’existe pas de niveau `fatal`.

## Table des matières du module

- [Émettre un message](#logging-emit)
  - [Garantie de non-propagation](#logging-no-propagation)
- [Format de sortie](#logging-format)
- [Seuil](#logging-threshold)
- [Destination](#logging-output)
- [Couleurs ANSI](#logging-colors)
- [État du module](#logging-state)
- [Contrat d’erreur](#logging-errors)
- [Limites](#logging-limits)

<a id="logging-emit"></a>
## Émettre un message

```lua
log.trace(...)
log.debug(...)
log.info(...)
log.warn(...)
log.error(...)
```

Chaque fonction accepte zéro ou plusieurs valeurs et ne renvoie aucune
valeur. Un message est émis lorsque le niveau de la fonction est supérieur
ou égal au seuil courant.

Le seuil initial est `log.INFO` : `trace` et `debug` sont donc filtrés par
défaut.

Les arguments sont convertis avec `tostring` puis joints par un espace :

```lua
log.info("user=", 42, "active=", true)
-- ... [INFO ] user= 42 active= true
```

Un appel sans argument produit une ligne avec un message vide. Les octets
NUL et les retours à la ligne contenus dans le message ne sont ni supprimés
ni échappés. Un message multiligne produit donc plusieurs lignes physiques,
mais seul le début de l’appel porte le préfixe du logger.

<a id="logging-no-propagation"></a>
### Garantie de non-propagation

Les cinq fonctions d’émission ne lèvent jamais d’erreur. Toute la chaîne est
protégée :

- conversion des arguments par `tostring` ;
- création de l’horodatage par `os.date` ;
- appel de la méthode `write` du sink.

Si une de ces opérations échoue, le message est perdu silencieusement et
l’exécution du script continue. Les arguments d’un message filtré ne sont
pas convertis par `tostring`.

<a id="logging-format"></a>
## Format de sortie

Sans couleur, une ligne suit ce format :

```text
YYYY-MM-DD HH:MM:SS [LEVEL] message\n
```

Exemple :

```text
2026-07-13 21:45:02 [WARN ] tentative 3 sur 5
```

L’horodatage utilise **l’heure locale** de la machine. Il n’inclut ni fuseau,
ni millisecondes. Les labels occupent cinq caractères : `[TRACE]`, `[DEBUG]`,
`[INFO ]`, `[WARN ]`, `[ERROR]`.

<a id="logging-threshold"></a>
## Seuil

```lua
log.set_level(level)
local level = log.get_level()
```

`set_level` exige exactement un argument et ne renvoie aucune valeur.
`get_level` n’accepte aucun argument et renvoie le seuil courant.

Le niveau peut être :

- un nom parmi `"trace"`, `"debug"`, `"info"`, `"warn"`, `"error"`, sans
  distinction de casse ;
- un nombre fini, ce qui permet un seuil intermédiaire comme `25.5`.

```lua
log.set_level("DEBUG")
log.set_level(log.WARN)
log.set_level(25.5)
```

Les chaînes numériques ne sont pas converties et les espaces ne sont pas
retirés : `"30"` et `" info "` sont refusés. `NaN`, `+inf` et `-inf` sont
également refusés.

<a id="logging-output"></a>
## Destination

```lua
log.set_output(out)
local out = log.get_output()
```

La destination initiale est `io.stderr`.

`set_output` exige exactement une table ou un userdata exposant une méthode
`write` appelable. Une méthode fournie par `__index` est acceptée. La méthode
est ensuite appelée avec la syntaxe `out:write(line)`.

```lua
local file, err = io.open("app.log", "a")
if not file then
    log.error("ouverture impossible :", err)
else
    log.set_output(file)
end
```

Le module :

- n’écrit rien pendant `set_output` ;
- ne ferme jamais la destination ;
- ne la vide jamais avec `flush` ;
- ignore la valeur renvoyée par `write` ;
- avale les erreurs d’écriture pendant l’émission.

Un fichier fermé possède encore une méthode `write` et peut donc être
installé ; les écritures suivantes échoueront silencieusement. La gestion de
la durée de vie du sink appartient au script.

`get_output` n’accepte aucun argument et renvoie exactement l’objet installé.

<a id="logging-colors"></a>
## Couleurs ANSI

```lua
log.set_color(true)
local enabled = log.get_color()
```

Les couleurs sont désactivées par défaut. `set_color` exige exactement un
booléen et ne renvoie aucune valeur. `get_color` n’accepte aucun argument et
renvoie un booléen.

Quand les couleurs sont actives :

- `trace` : ANSI dim ;
- `debug` : cyan ;
- `info` : aucune couleur ;
- `warn` : jaune ;
- `error` : rouge.

Le reset ANSI est écrit avant le `\n`. Le module ne détecte pas si la sortie
est un terminal : l’activation est toujours explicite.

<a id="logging-state"></a>
## État du module

`require("logging")` renvoie la même table tant que `package.loaded.logging`
n’est pas supprimé. Le seuil, le sink et le réglage de couleur sont donc
partagés par tous les utilisateurs du module dans **un même état Lua**.

Chaque worker Babet possède son propre état Lua : ses réglages de logging
sont indépendants de ceux du thread principal et des autres workers.

Les valeurs initiales sont :

```lua
log.set_level(log.INFO)
log.set_output(io.stderr)
log.set_color(false)
```

Le module expose également :

```lua
log._VERSION      -- "babet logging 1.1.0"
log._DESCRIPTION  -- description textuelle
```

<a id="logging-errors"></a>
## Contrat d’erreur

Les setters et getters lèvent une erreur Lua en cas de mauvaise arité ou de
valeur invalide. Ils ne renvoient pas `(nil, err)`.

Les fonctions `trace`, `debug`, `info`, `warn` et `error`, elles, ne lèvent
jamais et ne renvoient aucune valeur.

<a id="logging-limits"></a>
## Limites

Le module ne fournit pas :

- de logger nommé ou hiérarchique ;
- de seuil par module ;
- de destinations multiples ;
- de format personnalisé ou JSON ;
- de fuseau UTC ou de précision sub-seconde ;
- de rotation de fichiers ;
- de buffering ou d’écriture asynchrone ;
- de garde contre un sink récursif qui rappelle lui-même le logger ;
- de détection automatique de terminal.

Pour la rotation, utilisez un outil externe comme `logrotate`. Pour des
besoins plus avancés, enveloppez le module ou remplacez ses fonctions dans le
script.
