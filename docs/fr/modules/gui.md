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

`available()` charge et valide l'étroite surface de symboles GTK/GLib/Cairo sans
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
- `babet.gui.setCss(css_ou_nil)`
- `babet.gui.window([options])`
- `babet.gui.box([options])`
- `babet.gui.label(texte)`
- `babet.gui.button(texte)`
- `babet.gui.entry([options])`
- `babet.gui.drawingArea([options])`
- `babet.gui.scrolledWindow()`
- `babet.gui.spinButton([options])`
- `babet.gui.calendar([options])`
- `conteneur:add(enfant)` pour fenêtres, boxes et ScrolledWindow
- `box:remove(enfant)` / `box:clear()`
- `scrolledWindow:remove(enfant)` / `scrolledWindow:clear()`
- `label:setText(texte)` / `button:setText(texte)` / `entry:setText(texte)`
- `button:onClick(fonction)`
- `drawingArea:onClick(fonction_ou_nil)`
- `spinButton:getValue()` / `spinButton:setValue(nombre)` / `spinButton:onChanged(fonction_ou_nil)`
- `calendar:getDate()` / `calendar:setDate(année, mois, jour)` / `calendar:onChanged(fonction_ou_nil)`
- propriétés communes : `setMargins`, `setHExpand`, `setVExpand`, `setVisible`, `setSensitive`, `addClass`, `removeClass`
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
| `entry:setText(texte)` | Remplace le texte. Si la valeur finale diffère, appelle `onChanged` exactement une fois et synchroniquement avec le texte final ; un texte identique ne déclenche aucun callback. |
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
enregistrement ne les déclenche pas. Pour un `setText()` programmatique, Babet
masque volontairement la rafale interne suppression/insertion de GTK puis émet
au plus un `onChanged` après le retour du setter natif : exactement un si le
texte final diffère de la copie initiale, aucun si le texte est identique. Le
callback voit donc la valeur finale et jamais une chaîne vide intermédiaire due
à l'implémentation de GTK. Cette notification synthétique s'exécute néanmoins
avant le retour de `setText()`, sur son thread Lua appelant, y compris une
coroutine reprise sur le thread OS principal. Les modifications effectuées par
l'utilisateur continuent de suivre les événements `changed` ordinaires de GTK.
Cela inclut leurs états intermédiaires : par exemple, remplacer une sélection en
tapant peut produire brièvement un texte vide. Seul `entry:setText()` applique la
coalescence décrite ci-dessus.
Les événements traités par `gui.run()` utilisent le thread Lua principal. Un
callback ne peut pas faire de `yield` à travers GTK. Les erreurs, y compris une
tentative de yield, sont signalées et contenues. Un callback peut se remplacer,
se retirer ou fermer sa fenêtre ; les états natif et Lua restent valides jusqu'au
retour d'un setter en cours. Modifier le texte depuis `onChanged` peut déclencher
une nouvelle notification : éviter une mise à jour récursive inconditionnelle,
ou retirer temporairement le callback.

Voir [`examples/gui_entry/main.lua`](../../../examples/gui_entry/main.lua) pour
un exemple complet : texte en direct, validation par Entrée et bascule en
lecture seule.

```sh
babet examples/gui_entry
babet --create-exe examples/gui_entry ./gui-entry-app
./gui-entry-app
```

## DrawingArea : courbes natives et sélection au clic

`DrawingArea` permet de dessiner avec Cairo et de recevoir un clic utilisateur
sans dépendre d'une bibliothèque de graphiques externe.

```lua
local zone = assert(gui.drawingArea {width = 640, height = 300})
assert(colonne:add(zone))
assert(zone:onDraw(function(ctx, largeur, hauteur)
    assert(ctx:setSourceRGB(1, 1, 1))
    assert(ctx:rectangle(0, 0, largeur, hauteur))
    assert(ctx:fill())
    assert(ctx:setSourceRGB(0.1, 0.4, 0.8))
    assert(ctx:setLineWidth(2))
    assert(ctx:moveTo(20, hauteur - 20))
    assert(ctx:lineTo(largeur - 20, 20))
    assert(ctx:stroke())
    assert(ctx:setFontSize(14))
    assert(ctx:text(20, 22, "Courbe native"))
end))
-- Depuis le callback d'un bouton/Entry, après modification des données :
assert(zone:queueDraw())

assert(zone:onClick(function(x, y, bouton, nb_pressions)
    print("clic", x, y, bouton, nb_pressions)
end))
-- nil retire seulement le callback de clic :
assert(zone:onClick(nil))
```

`drawingArea()` et `drawingArea(nil)` utilisent 320 x 200 pixels logiques.
Les options `width` et `height` sont des entiers strictement positifs au plus
égaux à `INT_MAX`. Elles demandent une taille de contenu, sans fixer une taille
maximale ni une allocation constante. Les options sont lues sans `__index`.
GTK transmet la taille réellement allouée à `onDraw(ctx, largeur, hauteur)`.

`zone:onDraw(fonction_ou_nil)` remplace le callback ; `nil` explicite le retire.
L'inscription et le retrait demandent un redessin. `zone:queueDraw()` demande un
redessin ultérieur, sans appeler immédiatement le callback. GTK peut regrouper
plusieurs demandes. Ces méthodes sont réservées aux DrawingArea et renvoient
`true, nil`.

`zone:onClick(fonction_ou_nil)` remplace ou retire le callback de clic. Le callback
reçoit exactement `x`, `y`, `bouton`, `nb_pressions` : les deux premières valeurs
sont des nombres Lua exprimés dans les coordonnées d'allocation du widget,
`bouton` est un entier (`1` pour le bouton principal) et `nb_pressions` est le
compteur de pressions consécutives de GTK (`1` pour un clic simple, `2` pour la
seconde pression d'un double-clic, etc.). Une fonction Lua qui ne déclare que
trois paramètres reste compatible, Lua ignorant les arguments supplémentaires. Contrairement à `onDraw`, ce callback est un
callback d'événement ordinaire : il peut modifier des widgets et appeler
`queueDraw()`. Les erreurs sont protégées et signalées sur stderr comme pour les
autres callbacks GUI.

Le contexte est emprunté et valide **uniquement pendant cet appel à `onDraw`**.
Un contexte conservé provoque une erreur Lua après le retour, une erreur ou une
tentative de suspension du callback. Le dessin s'exécute sur le thread Lua
principal. Une coroutine reprise synchroniquement sur le même thread OS peut
utiliser le contexte tant que le callback est actif. Les workers ne le peuvent
pas. La création des arguments et l'appel utilisateur sont protégés contre les
erreurs Lua, y compris le manque de mémoire. Les erreurs sont signalées sur
stderr ; la boucle reste utilisable.

Dans `onDraw`, dessiner à partir de données déjà prêtes. Créer ou modifier un
widget, inscrire un callback ou appeler `queueDraw()` est refusé, même sur un
autre widget. Préparer les données et demander le redessin depuis un callback
de saisie. `entry:getText()` et `gui.quit()` restent autorisés ; `quit()` demande
seulement l'arrêt de la boucle après le retour de GTK. Les finalizers déclenchés
pendant le dessin attendent le retour de GTK avant de détruire les widgets.
Ces règles suivent les [restrictions de GTK pendant le dessin](https://docs.gtk.org/gtk4/method.DrawingArea.set_draw_func.html).

Toutes les méthodes ci-dessous renvoient `true, nil`. Les mauvais arguments,
les contextes expirés et les erreurs Cairo lèvent une erreur Lua. Les paramètres
numériques doivent être de vrais nombres Lua finis ; les chaînes numériques,
NaN et les infinis sont refusés.

| Méthode du contexte | Effet |
| --- | --- |
| `ctx:newPath()` | Efface le chemin courant. |
| `ctx:moveTo(x, y)` | Commence un sous-chemin au point indiqué. |
| `ctx:lineTo(x, y)` | Ajoute un segment. |
| `ctx:closePath()` | Referme le sous-chemin vers son début. |
| `ctx:rectangle(x, y, width, height)` | Ajoute un rectangle ; dimensions signées acceptées. |
| `ctx:arc(x, y, radius, start, finish)` | Ajoute un arc ; rayon positif ou nul, angles en radians, sens des angles croissants. |
| `ctx:stroke()` | Trace puis efface le chemin avec la couleur et l'épaisseur courantes. |
| `ctx:fill()` | Remplit puis efface le chemin avec la couleur courante. |
| `ctx:setLineWidth(width)` | Épaisseur strictement positive. |
| `ctx:setSourceRGB(r, g, b)` | Couleur opaque ; composantes entre 0 et 1 inclus. |
| `ctx:setSourceRGBA(r, g, b, a)` | Couleur avec alpha ; toutes les composantes entre 0 et 1 inclus. |
| `ctx:setFontSize(size)` | Taille de police strictement positive. |
| `ctx:text(x, y, text)` | Texte positionné par sa ligne de base ; UTF-8 valide, sans NUL. |

Les coordonnées sont des pixels logiques GTK, origine en haut à gauche et Y
croissant vers le bas. Le contexte conserve le découpage et l'échelle de GTK.
Babet sauvegarde et restaure l'état graphique Cairo autour du callback et
efface le chemin de dessin. `arc` peut rejoindre le point courant ; appeler
`newPath()` pour un arc indépendant. `text` utilise l'API texte minimale de
Cairo et déplace le point courant : terminer un chemin avant de l'annoter.
Cela convient aux légendes d'un graphique, pas au texte riche, à la mise en
page multiligne ni aux écritures nécessitant une composition complexe.
Aucun pointeur natif, surface persistante, exporteur d'image ou binding Cairo
général n'est exposé.

Voir [`examples/gui_drawing/main.lua`](../../../examples/gui_drawing/main.lua) :
courbe illustrative de poids avec intervalles de dates inégaux, bornes Y
automatiques et bouton de changement des données. Cette démonstration de
dessin ne sauvegarde pas de mesures.

```sh
babet examples/gui_drawing
babet --create-exe examples/gui_drawing ./gui-drawing-app
./gui-drawing-app
```

## Conteneurs actualisables : Box et ScrolledWindow

Une `Box` peut maintenant retirer un enfant précis ou vider tous ses enfants :

```lua
assert(colonne:remove(ancien_widget))
assert(colonne:clear())
```

`remove(enfant)` exige que l'enfant appartienne réellement au conteneur.
`clear()` retire tous les enfants. Dans les deux cas, un enfant dont le handle
Lua est encore conservé reste valide et peut être ajouté de nouveau à une autre
`Box` ou à un `ScrolledWindow`. Le parent cesse de le garder vivant côté Lua.
Cela permet de reconstruire une liste ou un historique sans remplacer toute la
fenêtre. `Window` ne propose volontairement pas `remove()`/`clear()` dans cette
surface.

`gui.scrolledWindow()` crée une zone défilante GTK native. Elle accepte un seul
enfant logique avec `add(enfant)` ; ajouter un second enfant avant d'avoir retiré
ou vidé le premier est une erreur. Le widget enfant peut lui-même être une Box
contenant autant de lignes que nécessaire :

```lua
local defilement = assert(gui.scrolledWindow())
local historique = assert(gui.box {orientation = "vertical", spacing = 4})
assert(defilement:add(historique))
assert(colonne:add(defilement))

-- Après une modification de la base :
assert(historique:clear())
for _, ligne in ipairs(nouvelles_lignes) do
    assert(historique:add(gui.label(ligne)))
end
```

## SpinButton : saisie numérique

```lua
local poids = assert(gui.spinButton {
    min = 30,
    max = 250,
    step = 0.1,
    value = 91.4,
    digits = 1,
})

assert(poids:onChanged(function()
    print("Poids :", poids:getValue())
end))
assert(poids:setValue(90.8))
```

Sans options, les valeurs sont `min = 0`, `max = 100`, `step = 1`, `value = 0`
et `digits = 0`. Si une plage personnalisée est fournie sans `value`, la valeur
initiale est `min`, comme avec le constructeur GTK natif. `min`, `max`, `step`
et `value` doivent être des nombres Lua finis ; `step` doit être strictement
positif et une valeur initiale explicitement fournie doit être comprise entre
les bornes. `digits` est un entier de 0 à 20. Les options sont lues directement,
sans `__index`. Le SpinButton est configuré en saisie numérique.

`getValue()` renvoie un nombre Lua. `setValue(nombre)` délègue la valeur à GTK,
qui la contraint à la plage du SpinButton. `onChanged(fonction_ou_nil)` remplace
ou retire le callback. Un changement programmatique peut déclencher le callback
synchroniquement avant le retour de `setValue()`. Comme pour Entry, le widget
et son état logique sont épinglés jusqu'au retour de GTK ; une fermeture de la
fenêtre depuis le callback ne crée donc pas de pointeur pendant.

## Calendar : choix et modification des dates

```lua
local date = assert(gui.calendar {year = 2026, month = 10, day = 7})

assert(date:onChanged(function()
    local annee, mois, jour = date:getDate()
    print(annee, mois, jour)
end))

assert(date:setDate(2025, 12, 31)) -- les dates passées sont autorisées
```

`calendar()` et `calendar(nil)` utilisent la date sélectionnée par défaut par
GTK. Pour fixer une date à la construction, `year`, `month` et `day` doivent être
fournis ensemble et être des entiers formant une date grégorienne valide, avec
une année comprise entre 1 et 9999. `getDate()` renvoie exactement trois valeurs
`année, mois, jour`. `setDate(année, mois, jour)` accepte aussi les dates passées.
`onChanged(fonction_ou_nil)` suit le même contrat protégé et remplaçable que le
SpinButton et Entry.

L'implémentation utilise l'API Calendar disponible depuis les premières versions
de GTK 4 plutôt que d'exiger les setters apparus beaucoup plus tard ; le runtime
reste donc compatible avec les distributions GTK 4 antérieures à 4.20.

## Style CSS

Babet peut installer une feuille CSS GTK au niveau de l'application et associer des classes CSS aux widgets :

```lua
assert(gui.setCss([[
.card { background: #ffffff; border-radius: 12px; padding: 12px; }
.primary { background: #2563eb; color: white; }
]]))

local panneau = assert(gui.box())
assert(panneau:addClass("card"))
local bouton = assert(gui.button("Enregistrer"))
assert(bouton:addClass("primary"))
assert(bouton:removeClass("primary"))
assert(gui.setCss(nil))
```

`gui.setCss(css_ou_nil)` remplace la feuille de style de l'application pour l'état Lua propriétaire de la GUI. `nil` la retire. `widget:addClass(nom)` et `widget:removeClass(nom)` fonctionnent sur tous les widgets vivants ; le nom est fourni sans point initial. Les diagnostics de parsing CSS restent ceux de GTK. À partir de GTK 4.12, Babet utilise `gtk_css_provider_load_from_string()` ; avec GTK 4.0 à 4.10, il se replie sur l'ancienne API `gtk_css_provider_load_from_data()`. Aucun de ces symboles n'est une dépendance directe à l'édition de liens.

## Propriétés communes des widgets

Tous les widgets vivants exposent les méthodes suivantes :

| Méthode | Effet |
| --- | --- |
| `widget:setMargins(marge)` | Applique la même marge entière positive ou nulle sur les quatre côtés. |
| `widget:setMargins(top, end_, bottom, start_)` | Définit séparément les quatre marges GTK, dans cet ordre. |
| `widget:setHExpand(booléen)` | Autorise/désactive l'expansion horizontale. |
| `widget:setVExpand(booléen)` | Autorise/désactive l'expansion verticale. |
| `widget:setVisible(booléen)` | Affiche ou masque le widget. |
| `widget:setSensitive(booléen)` | Active ou désactive les interactions utilisateur avec le widget. |
| `widget:addClass(nom)` | Ajoute une classe CSS GTK au widget. |
| `widget:removeClass(nom)` | Retire une classe CSS GTK du widget. |

Les marges sont des entiers compris entre 0 et `INT_MAX` et les quatre autres
méthodes exigent de vrais booléens Lua. Elles renvoient `true, nil`. Comme les
autres mutations GTK, ces appels sont refusés pendant `onDraw`. Les lectures
`entry:getText()`, `spinButton:getValue()` et `calendar:getDate()` restent des
opérations non mutantes.

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

Les callbacks Lua des boutons, Entry, SpinButton et Calendar sont exécutés sous
`lua_pcall`. Une erreur est signalée sur stderr avec le préfixe
`babet.gui callback error:` et ne traverse
jamais la pile C de GTK ; la boucle événementielle reste utilisable.

## Durée de vie

Chaque méthode valide le handle Lua. Les parents Lua gardent leurs enfants Lua
vivants, tandis que GTK devient propriétaire du widget natif après `add()`.
`remove()` et `clear()` reprennent une référence native avant le détachement GTK,
puis retirent la racine Lua du parent : un handle enfant encore détenu par le
script reste valide et réutilisable. Le signal GTK `destroy` invalide le handle
Babet correspondant. Toute utilisation
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
