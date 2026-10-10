> **Archive historique.** Ce document décrit un lot de développement avant publication. Les consignes d’extraction, de patch et de validation ci-dessous ne doivent plus être suivies sur une version actuelle de Babet.

# Babet 2.27.0 — DrawingArea:onClick

Ajout ciblé de l'interaction souris au `DrawingArea` GTK4.

API Lua :

```lua
assert(zone:onClick(function(x, y, button)
    print(x, y, button)
end))

assert(zone:onClick(nil))
```

Contrat :
- `x` et `y` sont les coordonnées en pixels logiques dans l'allocation du widget ;
- `button` est un entier GTK/GDK (`1` = bouton principal) ;
- le callback est protégé par `lua_pcall` ;
- `onClick(nil)` retire le callback ;
- le callback peut modifier des widgets et appeler `queueDraw()` ;
- `onDraw` reste indépendant du callback de clic ;
- l'implémentation utilise `GtkGestureClick` et conserve le chargement GTK dynamique.

Tests ajoutés :
- coordonnées et bouton transmis au Lua ;
- retrait du callback depuis lui-même ;
- `queueDraw()` depuis le clic ;
- durée de vie du callback/contrôleur ;
- symbole GTK manquant diagnostiqué proprement.

Validations exécutées dans l'environnement de génération :
- `tools/test_gui_runtime_contracts.sh` : 35 PASS / 0 FAIL ;
- `tools/test_gui_design_contract.sh` : 33 PASS / 0 FAIL ;
- `tools/test_gui_gtk_loader.sh` : 15 PASS / 0 FAIL ;
- `tools/test_gui_widget_contracts.sh` : 50 PASS / 0 FAIL ;
- `tools/test_exception_boundaries.sh` : 230/230 contrats protégés ;
- compilation C des deux faux runtimes GTK : OK ;
- syntaxe Python/Bash des tests concernés : OK.

Le build complet de Babet n'a pas été exécuté dans l'environnement de génération,
car les dépendances de compilation du projet ne sont pas présentes localement.
Lancer donc chez toi la validation habituelle :

```bash
./run_tests.sh --release
```
