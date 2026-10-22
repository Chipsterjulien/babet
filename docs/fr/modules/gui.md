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
- `calendar:markDay(jour)` / `calendar:unmarkDay(jour)` / `calendar:clearMarks()` / `calendar:onViewChanged(fonction_ou_nil)`
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

local joursParMois = { ["2026-10"] = {7, 18}, ["2025-12"] = {31} }
local function actualiserMarqueurs()
    local annee, mois = date:getDate() -- seulement l'année et le mois affichés
    assert(date:clearMarks())
    local cle = string.format("%04d-%02d", annee, mois)
    for _, jour in ipairs(joursParMois[cle] or {}) do
        assert(date:markDay(jour))
    end
end
assert(date:onViewChanged(actualiserMarqueurs))
actualiserMarqueurs() -- affichage initial
assert(date:setDate(2025, 12, 31)) -- les dates passées sont autorisées
actualiserMarqueurs() -- setDate() n'appelle pas onViewChanged()
```

`calendar()` et `calendar(nil)` utilisent la date sélectionnée par défaut par
GTK. Pour fixer une date à la construction, `year`, `month` et `day` doivent être
fournis ensemble et être des entiers formant une date grégorienne valide, avec
une année comprise entre 1 et 9999. `getDate()` renvoie exactement trois valeurs
`année, mois, jour`. `setDate(année, mois, jour)` accepte aussi les dates passées.
`onChanged(fonction_ou_nil)` suit le même contrat protégé et remplaçable que le
SpinButton et Entry.

Depuis Babet **2.30.0**, Calendar expose aussi `markDay`, `unmarkDay`,
`clearMarks` et `onViewChanged`.

`markDay(jour)` place le marqueur visuel GTK natif sur un numéro de jour ;
`unmarkDay(jour)` le retire et `clearMarks()` efface tous les marqueurs. `jour`
doit être un entier de 1 à 31. Les marqueurs restent attachés aux **numéros de
jour** quand le mois affiché change : marquer le 5 marque aussi le 5 des mois
suivants. Pour des données datées, effacer et reconstruire les marqueurs pour
chaque mois affiché.

`onViewChanged(fonction_ou_nil)` est appelé lors d'une navigation native de
l'utilisateur vers le mois ou l'année précédent(e)/suivant(e) : flèches de
l'en-tête, molette, clavier ou sélection d'un jour grisé d'un mois voisin.
**`setDate()` ne le déclenche pas**, même s'il change de mois ou d'année. Après
un `setDate()` réussi, appeler explicitement la même fonction de rafraîchissement,
comme ci-dessus ; sinon les anciens marqueurs restent sur le nouveau mois.

La navigation GTK peut aussi ajuster le jour sélectionné **sans `onChanged()`**.
Par exemple, avec GTK 4.14, passer au mois suivant depuis le 31 janvier 2024
sélectionne le 29 février et déclenche seulement `onViewChanged`. Sélectionner
un jour grisé peut produire deux étapes : `onViewChanged` voit d'abord le nouveau
mois avec un jour intermédiaire (29 février dans cet exemple), puis `onChanged`
voit le jour sélectionné (par exemple le 1er février).

Pour reconstruire les marqueurs dans `onViewChanged`, n'utiliser que **l'année
et le mois** de `getDate()` : son jour n'est pas nécessairement la sélection
finale de l'utilisateur. Si l'application suit la date complète, relire
`getDate()` dans les deux callbacks et au moment de valider une opération.
Ne pas supposer que `onChanged` signale à lui seul tous les changements de date,
ni qu'il suit chaque navigation. Babet transmet ces signaux natifs GTK sans
ajouter de notification de sélection.

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


## Compléments GTK4 — canevas de notes libres (2.29.0)

Ces composants restent **génériques** et ne définissent ni projet, ni objectif,
ni base de données. Les positions et contenus sont sauvegardés par l'application.

| Construction | Méthodes supplémentaires | Usage |
|---|---|---|
| `gui.fixed()` | `canvas:put(child, x, y)`, `canvas:move(child, x, y)`, `canvas:remove(child)`, `canvas:clear()` | Widgets placés librement (coordonnées GTK en pixels logiques). |
| `gui.textView {text = "...", editable = true}` | `getText()`, `setText()`, `setEditable(bool)`, `onChanged(fn ou nil)` | Éditeur multiligne GTK. |
| `gui.checkButton {label = "...", active = false}` | `getActive()`, `setActive(bool)`, `setText(label)`, `onChanged(fn ou nil)` | Cases à cocher. |
| `gui.progressBar()` | `setFraction(0..1)`, `getFraction()`, `setShowText(bool)`, `setText(label)`, `onClick(fn ou nil)` | Progression calculée ou manuelle, contrôlée par l'application. |
| `gui.box()` | `reorder(child, previousChild ou nil)` | Changement d’ordre natif, sans démonter les enfants. |
| `gui.expander {label = "...", expanded = false}` | `add(child)`, `remove(child)`, `clear()`, `setExpanded(bool)`, `getExpanded()`, `setText(label)` | Bloc repliable, **un seul enfant** GTK (utiliser `gui.box()` pour plusieurs éléments). |
| Widget non interactif : label, box, drawingArea, fixed, progressBar | `onDrag(function(phase, x, y) ... end ou nil)` | Geste de déplacement, déclenché sur un **élément-poignée**. |
| Tous les widgets | `setSizeRequest(width, height)` | Taille minimale demandée (dimension `-1` : automatique). |

`onDrag` déclenche les phases `"begin"` (coordonnées locales du début), puis
`"update"` et `"end"` (**déplacements relatifs au début, mesurés dans le
repère stable de la surface GTK même si la poignée bouge**). Le déplacement
n'est **pas automatique** : appeler `canvas:move(bloc, x, y)` depuis le
callback. Il faut accrocher `onDrag` à un élément non interactif dédié (par
exemple un label-titre) : boutons, éditeurs de texte, cases à cocher et expanders
possèdent leurs propres gestes GTK et ne sont pas acceptés. Les callbacks sont exécutés de façon protégée ;
ils ne doivent pas lever ou céder la main à GTK.

Les coordonnées de `put` et `move` doivent être finies, entre -10 000 000 et
10 000 000. Le canevas `gui.fixed()` doit être dimensionné ou avoir assez de
contenu pour produire une zone défilable ; `GtkFixed` n'effectue pas de
placement automatique. Un enfant retiré reste réutilisable.

Exemple exécutable : [`examples/gui_free_notes/main.lua`](../../../examples/gui_free_notes/main.lua).

```lua
local gui = babet.gui
assert(gui.init())
local window = gui.window {title="Notes", width=700, height=500}
local canvas = gui.fixed()
local content = gui.box {orientation="vertical"}
local handle = gui.label("Déplacer")
local editor = gui.textView {text="Mon idée"}
content:add(handle)
content:add(editor)
window:add(canvas)
canvas:put(content, 50, 40)
local ox, oy = 50, 40
handle:onDrag(function(phase, x, y)
    if phase == "begin" then ox, oy = 50, 40 end
    if phase == "update" then canvas:move(content, ox + x, oy + y) end
end)
window:show()
gui.run()
```

Le mini-exemple ci-dessus est illustratif (il faudrait mémoriser les dernières
coordonnées si plusieurs déplacements sont réalisés). La démonstration complète
le fait correctement.


## Interaction native sur les progressions et réorganisation d'une liste

Babet expose **le véritable `GtkProgressBar`** et le réordonnancement natif
**`gtk_box_reorder_child_after()`** ; une application n'a pas à redessiner une
progression ni à détruire/recréer ses lignes.

### `progressBar:onClick(fonction_ou_nil)`

- Fonction facultative, ou `nil` pour désactiver le callback ; renvoie `true, nil`.
- Appel sur un **appui du bouton principal**, avec quatre arguments :
  `(x, y, button, n_press)` ; les coordonnées sont locales au widget.
- `n_press` est le compteur de clics successifs propre à GTK, **pas** le
  nombre total de validations de l'application. Conserver son propre compteur.
- La progression n'augmente **jamais automatiquement** : `setFraction(0..1)`
  reste sous le contrôle du programme, pour les modes manuel et automatique.
- Le callback, protégé par Babet, peut être remplacé ou supprimer la fenêtre.
- `progressBar:setText()` concerne le texte **dans la barre** ; un intitulé à
  droite est un `gui.label()` distinct, dans une `gui.box{orientation="horizontal"}`.
- Une barre de progression n'est pas un bouton activable au clavier. Si elle
  sert d'action d'avancement et pas seulement d'indicateur, prévoir aussi un
  vrai bouton (ou un contrôle équivalent accessible au clavier).

```lua
local bar = assert(gui.progressBar())
local title = assert(gui.label("The graphics"))
local row = assert(gui.box {orientation = "horizontal", spacing = 8})
assert(row:add(bar))
assert(row:add(title))
assert(bar:setHExpand(true))
assert(bar:setShowText(true))
local steps, total = 0, 4
assert(bar:onClick(function(x, y, button, n_press)
    steps = math.min(total, steps + 1)
    assert(bar:setFraction(steps / total))
    assert(bar:setText(tostring(steps * 25) .. " %"))
    if steps == total then assert(title:addClass("completed")) end
end))
```

Pour barrer les libellés avec le rendu typographique GTK, utiliser le CSS :

```css
label.completed, checkbutton.completed label {
    text-decoration-line: line-through;
    opacity: 0.6;
}
```

Dans une checklist : `check:onChanged(function() ... check:getActive()`
permet d'ajouter ou retirer `check:addClass("completed")` /
`check:removeClass("completed")`. À la fin d'une progression manuelle,
appliquer la même classe sur le libellé voisin. Aucune API spécialisée de
« checklist » n'est inscrite dans le moteur Babet.

### `box:reorder(child, previousChild_or_nil)`

`box` doit être un `gui.box`, `child` doit déjà lui appartenir et
`previousChild` doit appartenir à **la même boîte**. Le deuxième argument est
obligatoire : pour placer `child` au début, il faut passer `nil` explicitement.
`nil` place `child` au
début ; une autre ligne le place juste après elle. La modification est native
**sans `remove()`, `add()` ni reparentage** : les callbacks et l'état des
widgets restent intacts, et la table des enfants Lua conserve le même ordre.
Une demande invalide est rejetée sans modifier la liste ; une demande qui ne
change rien est acceptée. Par exemple :

```lua
-- [first, middle, last] : déplacer la dernière ligne au deuxième rang.
assert(list:reorder(last, first))
-- Placer une ligne tout en haut.
assert(list:reorder(last, nil))
```

### Drag-and-drop GTK4 natif pour les listes

Depuis Babet **2.31.0**, le DND natif est disponible en complément de `onDrag()` :

- `poignee:setDragData(identifiant_ou_nil)` installe un **`GtkDragSource`** sur
  un widget non interactif (`label`, `box`, `drawingArea`, `fixed` ou
  `progressBar`). La chaîne UTF-8 est la donnée applicative ; `nil` désactive
  la source sans reconstruire le widget. Les octets NUL internes et l’UTF-8
  invalide sont refusés. MOVE reste l’action par défaut et l’aperçu par défaut
  montre la poignée elle-même, jamais l’identifiant transporté.
- `cible:onDrop(fonction_ou_nil)` installe un **`GtkDropTarget`** natif sur tout
  widget non-fenêtre. Le callback protégé reçoit
  `(phase, payload, x, y, action)` pour `"enter"`, `"motion"`, `"drop"` et
  `"leave"`. `action` vaut la préférence courante `"copy"`, `"move"` ou
  `"link"` ; `leave` reçoit nil pour payload/coordonnées/action. Pendant le
  survol, le backend peut ne pas avoir encore préchargé la chaîne : `payload`
  peut donc être nil sur `enter`/`motion`, mais il est présent sur `drop`.
- Le callback accepte par défaut (`nil` ou `true`). `false`, ou une erreur du
  callback, refuse la notification courante. Renvoyer `"copy"`, `"move"` ou
  `"link"` accepte et préfère cette action activée **pendant `enter`/`motion`**.
  Dans `drop`, l’action ne peut plus être changée : renvoyer `nil`, `true` ou
  l’action reçue par le callback pour accepter, et `false` pour refuser. Une
  autre action produit une erreur de callback contenue et refuse le transfert.
  Entre widgets Babet, le callback `end` de la source reçoit alors un booléen de
  suppression égal à `false`. Valider l’action reçue
  **avant de modifier le modèle** : le refus ne défait pas les changements Lua.
  Un refus pendant `enter`/`motion` **n’annule pas définitivement le geste** :
  d’autres mouvements, `leave`, et éventuellement `drop` peuvent suivre.
  Revalider l’identifiant et la position dans `drop`.
- `onDrop(nil)` désactive **la cible native** et son callback Lua, et annule le
  survol/préchargement en cours. Un enfant désactivé n’intercepte plus les dépôts
  destinés à une cible parente ou au traitement de texte natif du widget.
  `onDrop(fonction)` réactive ensuite le même contrôleur.
- Une désactivation depuis un callback refuse le transfert courant pour cette
  cible. Une réactivation immédiate ne prend effet qu’au geste suivant. Les
  modifications du modèle déjà effectuées ne sont pas annulées.
- Le transfert possède sa propre donnée : modifier ou effacer `setDragData()`
  pendant un geste concerne les gestes suivants, pas l’identifiant déjà transféré.
- MOVE est le comportement compatible par défaut. `setDragActions(action_ou_table)`
  et `setDropActions(action_ou_table)` activent toute combinaison de `copy`,
  `move` et `link`. Ctrl préfère COPY, Maj préfère MOVE, et Ctrl+Maj préfère LINK
  lorsque la cible l’autorise ; le callback peut remplacer cette préférence en
  renvoyant une action activée pendant `enter`/`motion`. Babet ne fait aucune copie/déplacement du modèle :
  l’application conserve la responsabilité de l’opération réelle.
- `setDragIcon(widget_ou_nil)` choisit un widget vivant comme aperçu natif du
  glisser. Au début de chaque glisser, un aperçu non affiché par GTK, masqué,
  détaché ou détruit est remplacé par la poignée source. Un simple
  `gui.label("Aperçu")` créé hors fenêtre n’est donc pas dessiné hors écran :
  utiliser un widget affiché dans une fenêtre pour un aperçu personnalisé.
  `nil` rétablit la poignée. Babet conserve le handle choisi sans le reparenter.
  `onDragState(fonction_ou_nil)` signale `begin`, `end` et `cancel` via
  `(phase, détail, action)` ; pour `end`, `détail` est le booléen indiquant si la
  source doit supprimer ses données, et pour `cancel` c’est la raison native.
  Après un refus local, GTK peut conserver le nom d’action précédemment choisi
  et ne pas émettre `cancel` : se fier au booléen de `end` pour supprimer les
  données, pas au nom d’action seul. Babet force ce booléen à `false` lorsque sa
  cible locale a refusé le dépôt, y compris après une erreur de callback.

Utiliser une poignée non interactive dédiée. Éviter de combiner `onDrag()` et
`setDragData()` sur le même widget : `onDrag` peut démarrer puis perdre la
séquence lorsque le glisser-déposer natif prend la main au seuil de déplacement.

Avec des cibles imbriquées, le parent reçoit aussi `enter`/`motion` pendant le
survol de l’enfant. Si le parent accepte le survol, l’enfant peut recevoir `drop`
même après avoir renvoyé `false` pendant le survol. **Toujours revalider le dépôt
final.** Un `false` dans le `drop` de l’enfant ne transmet pas le dépôt au parent ;
seule la désactivation de l’enfant par `onDrop(nil)` le rend transparent.

**Ne pas attendre `leave` après un dépôt.** GTK peut terminer un dépôt accepté
ou refusé sans émettre `leave`, y compris sur le parent. Dans chaque callback
`drop`, nettoyer les indicateurs de toutes les cibles concernées avant de valider
ou de modifier le modèle. Garder le nettoyage dans `leave` pour la sortie du
pointeur ou un geste annulé :

```lua
local rows = { ["task-42"] = rowA }
local function clearDropIndicators()
    for _, widget in ipairs({list, rowA, rowB}) do
        assert(widget:removeClass("drop-target"))
    end
end
assert(handleA:setDragData("task-42"))
assert(rowB:onDrop(function(phase, payload, x, y)
    if phase == "enter" or phase == "motion" then
        assert(rowB:addClass("drop-target"))
    elseif phase == "leave" then
        assert(rowB:removeClass("drop-target"))
    elseif phase == "drop" then
        clearDropIndicators() -- nettoyage commun à tous les callbacks drop
        local moved = rows[payload]
        if not moved or moved == rowB then return false end
        assert(list:reorder(moved, rowB)) -- place moved juste après rowB
    end
end))
```

Si le parent `list` possède aussi un callback `onDrop`, appeler cette même
fonction dans sa branche `drop`, y compris lorsque le dépôt est refusé.

Pour placer avant une cible, l'application passe à `reorder()` la ligne qui
précède cette cible dans son propre modèle (ou `nil` pour la première place).
Le repère d'insertion et la persistance restent donc des décisions de l'UI,
mais le geste et le dépôt eux-mêmes utilisent bien `GtkDragSource` et
`GtkDropTarget`, sans simulation avec `onDrag()`.


## Primitives pour applications de bureau

Disponibles depuis Babet **2.32.0**.

Cette couche reste volontairement générique : elle fournit les mécanismes GTK4
nécessaires à une application riche, sans introduire dans Babet de modèle de
note, tâche, arbre ou persistance.

### Volets, menus et menus contextuels

- `gui.paned{orientation="horizontal"|"vertical", position=..., resizeStart=...,
  resizeEnd=..., shrinkStart=..., shrinkEnd=..., wideHandle=...}` encapsule
  `GtkPaned` et accepte exactement deux enfants. `getPosition()`,
  `setPosition(px)` et `onPositionChanged(fonction_ou_nil)` permettent notamment
  de mémoriser la largeur d’une barre latérale.
  Valeurs par défaut : `orientation="horizontal"`, `resizeStart=false`,
  `resizeEnd=true`, `shrinkStart=true`, `shrinkEnd=true`, `wideHandle=false`.
  Sans `position`, GTK choisit la position initiale du séparateur. En particulier,
  Babet utilise `resizeStart=false`, alors que GTK utilise `true` par défaut.
- `gui.separator([orientation])` expose un vrai `GtkSeparator`.
- `gui.menuButton{label="..."}` ou `gui.menuButton{icon="..."}`, associé à
  `gui.popover{hasArrow=..., autohide=..., position="left|right|top|bottom"}`,
  permet de composer une barre de menus ou un menu de marques avec les widgets
  Babet ordinaires. Un popover accepte un seul enfant. Utiliser
  `menuButton:setPopover(popover_ou_nil)`, `popup()` et `popdown()`.
  Éviter `popup()` suivi immédiatement de `popdown()` dans le même callback
  avec `autohide=true` : GTK peut alors absorber la touche suivante. Ouvrir
  le menu puis le fermer lors d'un événement ultérieur.
- Pour un menu contextuel placé au pointeur : `popover:attachTo(widget)`,
  `setPointingTo(x,y[,largeur,hauteur])`, puis `popup()`. `attachTo(nil)` le
  détache pour pouvoir le réutiliser ailleurs. Cet attachement est limité aux
  popovers : il ne constitue pas un mécanisme générique permettant de contourner
  les règles de parenté GTK. La destruction du parent détache ses popovers
  contextuels ; une poignée conservée peut être rattachée à un autre widget
  vivant. Les cycles de parenté sont refusés avant modification, y compris à
  travers les menus et les popovers contextuels.

Une barre haute peut donc être une `gui.box()` horizontale contenant des
`menuButton`, `button`, `image` et `separator`. `gui.image(nomIcone)` et
`setIconName(nomIcone)` utilisent le thème d’icônes du bureau cible.

### Pointeur, clavier, focus et géométrie

`widget:onPointer(fonction_ou_nil)` installe les contrôleurs natifs de clic et de
mouvement. Le callback reçoit `(phase, x, y, bouton, nb_pressions, modificateurs)`
avec `phase` égal à `press`, `release`, `enter`, `motion` ou `leave`; `leave`
reçoit des coordonnées nil. Contrairement à `onClick`, tous les boutons sont
remontés, donc le bouton 3 peut ouvrir un menu contextuel.

`widget:onKey(fonction_ou_nil)` reçoit
`(phase, nom_touche_ou_nil, keyval, keycode, modificateurs)` pour `press` et
`release`. Une valeur vraie renvoyée par `press` consomme l’événement. Sur une
fenêtre, ce contrôleur est installé en phase **capture** : les raccourcis globaux
comme `Ctrl+1` ou `Échap` sont donc vus avant qu’un `TextView`/`Entry` focalisé ne
puisse les consommer. Les masques `gui.MOD_SHIFT`, `gui.MOD_CONTROL`,
`gui.MOD_ALT` et `gui.MOD_SUPER` sont exposés ; avec Lua 5.5, tester par exemple
`(mods & gui.MOD_CONTROL) ~= 0`.

Sur une `Entry` ou un `TextView`, GTK peut consommer les caractères saisis avant
que `onKey` ne les reçoive. Utiliser `onChanged` pour suivre le texte et l’`onKey`
de la fenêtre pour les raccourcis de l’application.

Les aides communes sont `setCursor(nom_ou_nil)`, `setTooltipText(texte_ou_nil)`,
`grabFocus()` / `hasFocus()`, `getSize()`, `translatePoint(cible,x,y)` et
`pick(x,y)`. `pick()` effectue le hit-test GTK natif et remonte jusqu’au handle
Babet le plus proche ; il permet notamment de distinguer un clic sur le fond
libre d’un clic sur une note enfant. S’ajoutent `setHAlign(...)` / `setVAlign(...)`
avec `fill`, `start`, `end`, `center` ou `baseline`. `TextView` accepte
`wrap="none|char|word|word-char"` à la création et `setWrapMode(...)` ensuite.

Ces primitives suffisent pour des poignées visibles au survol, du
redimensionnement horizontal et des liserés d’insertion précis. Les zones de
contact et l’apparence CSS restent entièrement décidées par l’application.

`getSize`, `translatePoint` et `pick` reflètent la dernière mise en page terminée
par GTK. Juste après un `add`, un `remove` ou une autre modification dans le même
callback, leurs résultats peuvent encore décrire l’ancienne disposition. Les
relire une fois la mise en page suivante effectuée ; le simple retour du callback
ne force pas son exécution.

### Fenêtres de bureau

`window:setTitle(texte)`, `window:setIconName(nomIcone)`,
`window:setTransientFor(parent_ou_nil)` et `window:setModal(booléen)` couvrent les
fenêtres de propriétés/dialogues. `window:onCloseRequest(fonction_ou_nil)` appelle
un callback protégé avant une fermeture demandée par l’utilisateur ; renvoyer
`true` bloque cette fermeture. `window:close()` reste la fermeture programmée
explicite.
Si le callback de demande de fermeture lève une erreur, Babet la signale et
laisse la fermeture se poursuivre.
