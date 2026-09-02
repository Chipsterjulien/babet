# GUI — interface graphique GTK 4 optionnelle

`babet.gui` est l'API graphique de bureau optionnelle de Babet. Elle se distingue
volontairement de `babet.curses` : le toolkit graphique **n'est pas lié** dans
Babet. Sous Linux, le premier et seul backend supporté est GTK 4, chargé
paresseusement depuis le système cible lorsqu'un script demande la GUI.

Un script qui n'utilise jamais `babet.gui` conserve le contrat de déploiement
habituel de Babet. Une application GUI générée reste exactement un fichier, mais
GTK 4 doit déjà être installé sur la machine cible.

## Disponibilité et initialisation

```lua
local gui = babet.gui

local disponible, pourquoi = gui.available()
if not disponible then
    print(pourquoi)
    return
end

local ok, err = gui.init()
assert(ok, err)
```

`available()` charge et valide l'étroite surface de symboles GTK/GLib sans
initialiser l'affichage. `init()` empêche GTK de modifier la locale globale du
processus puis utilise son chemin d'initialisation récupérable. Ces deux appels
sont réservés au thread OS principal de Babet.

Si GTK 4 manque, le diagnostic nomme le runtime absent et donne des exemples
d'installation Debian/Ubuntu, Arch Linux et Fedora. Si GTK est installé mais
qu'aucun affichage graphique n'est initialisable, `init()` renvoie un diagnostic
spécifique au lieu de terminer le processus.

## API minimale des widgets

```lua
local gui = babet.gui
assert(gui.init())

local fenetre = gui.window {
    title = "Babet GUI",
    width = 480,
    height = 240,
}

local colonne = gui.box {
    orientation = "vertical", -- ou "horizontal"
    spacing = 8,
}

local texte = gui.label("Prêt")
local bouton = gui.button("Lancer")

assert(fenetre:add(colonne))
assert(colonne:add(texte))
assert(colonne:add(bouton))

assert(bouton:onClick(function()
    assert(texte:setText("Cliqué"))
    assert(gui.quit())
end))

assert(fenetre:show())
assert(gui.run())
assert(fenetre:close())
```

La première surface reste volontairement petite :

- `babet.gui.available()`
- `babet.gui.init()`
- `babet.gui.window([options])`
- `babet.gui.box([options])`
- `babet.gui.label(texte)`
- `babet.gui.button(texte)`
- `conteneur:add(enfant)` pour fenêtres et boxes
- `label:setText(texte)` / `button:setText(texte)`
- `button:onClick(fonction)`
- `window:show()` / `window:close()`
- `babet.gui.run()` / `babet.gui.quit()`

Les options de `window` acceptent actuellement `title`, `width` entier positif
et `height` entier positif. Les options de `box` acceptent
`orientation = "vertical"|"horizontal"` et `spacing` entier positif ou nul.
Les chaînes transmises à GTK refusent les NUL embarqués, car le toolkit attend
des chaînes C.

## Boucle événementielle et callbacks

Les opérations GTK sont réservées au thread principal. Une session GUI vivante
et une session `babet.curses` active sont mutuellement exclusives. `gui.run()`
possède la boucle interactive principale jusqu'à la destruction de toutes les
fenêtres ou l'appel à `gui.quit()`.

Babet installe une petite source de réveil GLib bornée afin de continuer à
servir ses callbacks de signaux Unix différés pendant que GTK possède la boucle.
Les workers peuvent poursuivre des calculs non graphiques, mais ne doivent
jamais appeler directement les méthodes GUI.

Les callbacks Lua des boutons sont exécutés sous `lua_pcall`. Une erreur est
signalée sur stderr avec le préfixe `babet.gui callback error:` et ne traverse
jamais la pile C de GTK ; la boucle événementielle reste utilisable.

## Durée de vie

Chaque méthode valide le handle Lua. Les parents Lua gardent leurs enfants Lua
vivants, tandis que GTK devient propriétaire du widget natif après `add()`. Le
signal GTK `destroy` invalide le handle Babet correspondant. Toute utilisation
ultérieure produit une erreur Lua contrôlée plutôt qu'un déréférencement de
pointeur natif périmé.

La collecte d'un widget non parenté libère sa référence de construction. La
collecte d'une fenêtre top-level détruit cette fenêtre. À la fermeture de l'état
Lua, les callbacks GUI sont neutralisés avant `lua_close()`.

## `--create-exe`

Aucune commande spéciale n'est nécessaire :

```sh
babet --create-exe ./mon-projet-gui mon-appli-gui
```

Le résultat est un seul fichier applicatif. Contrairement à une application
Babet sans GUI, ce fichier dépend volontairement du runtime GTK 4 installé sur
le Linux cible. Aucun `babet-gtk.so`, DSO temporaire extrait, compilateur ou
linker n'est nécessaire au lancement ni au moment du `--create-exe`.

Cette exception limitée à la GUI ne modifie pas l'autonomie des scripts et
applications générées qui n'utilisent pas `babet.gui`.
