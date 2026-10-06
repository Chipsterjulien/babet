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
initialiser l'affichage. Dès qu'un DSO GTK a été ouvert avec succès, il reste
résident jusqu'à la fin du processus, y compris si la validation d'un symbole
requis échoue. Le résultat du chargement est mémorisé : les appels suivants ne
rouvrent pas GTK. `init()` empêche GTK de modifier la locale globale du processus
puis utilise son chemin d'initialisation récupérable. Ces deux appels sont
réservés au thread OS principal de Babet.

La première tentative de chargement GTK, via `available()` ou `init()`,
verrouille définitivement les mutations de l'état partagé : `babet.setenv` et
`babet.chdir` renvoient `nil, err`, et `os.setlocale(locale, catégorie)` lève
une erreur si `locale` n'est pas `nil`. Configure donc l'environnement, le
répertoire courant et la locale **avant** ces appels. `babet.env`,
`babet.currentDir` et `os.setlocale(nil, catégorie)` restent consultables.

Le verrouillage précède `dlopen`, car le chargement et l'initialisation de GTK
peuvent exécuter du code natif et créer des threads indépendants des workers
Babet. Il reste actif même si GTK est absent, si un symbole manque ou si
l'affichage ne peut pas être initialisé, ainsi qu'après fermeture des fenêtres
ou recréation d'un contexte d'embedding. Un appel refusé avant le chargement
(arguments invalides, mauvais thread) ne déclenche pas ce verrouillage.

La protection couvre les points d'entrée Lua de Babet. Un hôte ou un plugin
natif doit aussi coordonner ses propres mutations et threads ; Babet
n'intercepte pas les appels directs à la libc. Voir les précautions de
[GLib sur les threads et l'état global](https://docs.gtk.org/glib/threads.html).

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
- `babet.gui.entry([options])`
- `conteneur:add(enfant)` pour fenêtres et boxes
- `label:setText(texte)` / `button:setText(texte)` / `entry:setText(texte)`
- `button:onClick(fonction)`
- `window:show()` / `window:close()`
- `babet.gui.run()` / `babet.gui.quit()`

Les options de `window` acceptent actuellement `title`, `width` entier positif
et `height` entier positif. Les options de `box` acceptent
`orientation = "vertical"|"horizontal"` et `spacing` entier positif ou nul.
Les chaînes transmises à GTK refusent les NUL embarqués, car le toolkit attend
des chaînes C.

## Entry : saisie de texte sur une ligne

```lua
local saisie = assert(gui.entry {
    text = "",             -- par défaut : vide
    placeholder = "Nom",  -- par défaut : vide
    editable = true,        -- par défaut : true
})
assert(colonne:add(saisie))

assert(saisie:onChanged(function()
    print("Texte courant :", saisie:getText())
end))
assert(saisie:onActivate(function()
    print("Texte validé :", saisie:getText())
end))
```

Créer le champ après `gui.init()` et conserver sa fenêtre pendant la boucle
événementielle. `entry()` et `entry(nil)` utilisent les valeurs par défaut.
Les options sont lues directement dans la table, sans appeler `__index`.

| Méthode | Contrat |
| --- | --- |
| `entry:getText()` | Renvoie une seule chaîne Lua : une copie du texte courant. |
| `entry:setText(texte)` | Remplace le texte ; peut appeler `onChanged` immédiatement. |
| `entry:setPlaceholder(texte)` | Définit l'indication du champ vide et sans focus ; `""` la supprime. |
| `entry:setEditable(booléen)` | Autorise/interdit la saisie utilisateur ; `setText` reste utilisable par le programme. |
| `entry:onChanged(fonction_ou_nil)` | Remplace le callback de changement de texte ; `nil` explicite le retire. |
| `entry:onActivate(fonction_ou_nil)` | Remplace le callback de validation, normalement déclenché par Entrée ; `nil` explicite le retire. |

Les setters et les enregistrements de callbacks renvoient `true, nil`. La
création renvoie un widget, ou `nil, diagnostic` en cas d'échec runtime contrôlé.
Un argument incorrect ou un widget détruit/de mauvais type lève une erreur Lua.
Le texte et l'indication doivent être des chaînes UTF-8 adaptées à GTK, sans
NUL embarqué ; les nombres ne sont pas convertis en chaînes. `editable` exige
un véritable booléen. Ces opérations ne convertissent pas les nombres et ne
valident pas les données métier.

Les callbacks ne reçoivent aucun argument : capturer le champ et utiliser
`getText()` pour lire sa valeur. Les deux callbacks sont indépendants et leur
enregistrement ne les déclenche pas. Une notification de `setText()` s'exécute
avant le retour du setter, sur son thread Lua appelant, y compris une coroutine
reprise sur le thread OS principal. Les événements traités par `gui.run()`
utilisent le thread Lua principal. Un callback ne peut pas faire de `yield`
à travers GTK. Les erreurs, y compris une tentative de yield, sont signalées
et contenues. Un callback peut se remplacer, se retirer ou fermer sa fenêtre ;
les états natif et Lua restent valides jusqu'au retour d'un setter en cours.
Modifier le texte depuis `onChanged` peut déclencher une nouvelle notification :
éviter une mise à jour récursive inconditionnelle, ou retirer temporairement
le callback.

Voir [`examples/gui_entry/main.lua`](../../../examples/gui_entry/main.lua) pour
un exemple complet : texte en direct, validation par Entrée et bascule en
lecture seule.

```sh
babet examples/gui_entry
babet --create-exe examples/gui_entry ./gui-entry-app
./gui-entry-app
```

## Boucle événementielle et callbacks

Les opérations GTK sont réservées au thread principal. Une session GUI vivante
et une session `babet.curses` active sont mutuellement exclusives. `gui.run()`
possède la boucle interactive principale jusqu'à la destruction de toutes les
fenêtres ou l'appel à `gui.quit()`. `gui.run()` doit être lancé depuis le thread
Lua principal lui-même ; un appel depuis une coroutine Lua est refusé même si
cette coroutine est reprise sur le thread OS principal de Babet.

Babet installe une petite source de réveil GLib bornée afin de continuer à
servir ses callbacks de signaux Unix différés pendant que GTK possède la boucle.
Les workers peuvent poursuivre des calculs non graphiques, mais ne doivent
jamais appeler directement les méthodes GUI.

Les callbacks Lua des boutons et des champs Entry sont exécutés sous `lua_pcall`. Une erreur est
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

Les callbacks appartiennent au handle Lua du widget. Capturer ce même widget
dans son callback ne le conserve pas indéfiniment : un cycle widget/callback
devenu inaccessible peut être collecté. Un parent vivant conserve bien ses
handles enfants et leurs callbacks.

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
