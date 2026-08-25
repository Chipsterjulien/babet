# Plugins natifs — API expérimentale du Lot 11

Babet peut charger une classe volontairement réduite d'extensions Linux `.so`
de confiance dans les modes CLI normaux (dossier ou fichier). Cette API reste
expérimentale et ne constitue pas un écosystème de paquets.

Le Lot 11 a été validé par la campagne mainteneur Linux le 25/08/2026, puis
rouvert pour durcissement post-audit avant publication. L’ABI durcie reste
expérimentale jusqu’à une nouvelle campagne mainteneur et un second audit externe.

## Démarrage rapide

Compile le plugin uniquement avec les headers publics :

```sh
cc -std=c11 -fPIC -shared -I/chemin/vers/babet/include plugin.c -o plugin.so
```

Le plugin ne se lie pas à un `libbabet.so`.

Chargement explicite côté Lua :

```lua
local plugin, err = babet.plugin.load("./plugin.so")
assert(plugin, err)

print(plugin.name, plugin.version)
print(plugin.functions.echo("bonjour"))
```

Des exemples C et C++ complets sont fournis dans `examples/native_plugin/`.

## Frontière C

Le point d'entrée v1 est `babet_plugin_query_v1()`. Il renvoie un descripteur C
statique avec des vues nom/version à longueur explicite, une taille de structure
de fonction et sa liste de `babet_plugin_callback_v1`. Aucun `lua_State`, objet
STL/RTTI, exception C++ ou propriété d'allocation C++ ne traverse cette frontière.

Un plugin peut être implémenté en C++. Il peut utiliser `std::string`, un SDK
constructeur ou d'autres bibliothèques en interne, mais il convertit vers les
types C avant la frontière. En C++, le point de requête et le type de callback
sont `noexcept` : oublier `noexcept` provoque une erreur de compilation. Babet ne
promet pas de rattraper une exception qui s'échappe d'un `.so`, car le binaire
officiel et le plugin peuvent utiliser des runtimes C++ différents. Le plugin
doit donc intercepter ses exceptions, poser un diagnostic avec
`babet_host_call_set_error()` et renvoyer un statut non-OK.

## Valeurs

On réutilise exactement le contrat scalaire du Lot 10 : nil, booléen, entier
signé 64 bits, double et chaîne binaire avec longueur explicite.
`babet_host_call_set_result()` copie immédiatement les octets d'une chaîne de
résultat ; une chaîne C++ temporaire peut donc être détruite après l'appel.

## Durée de vie

Un `.so` chargé avec succès reste volontairement chargé jusqu'à la fin du
processus. Il n'existe pas d'unload/reload dans le Lot 11. Le `userdata` d'un
callback appartient au plugin et doit rester valide pendant toute cette durée.
Les doublons sont refusés même via un hardlink/autre chemin vers le même DSO.
Une sonde refusée peut être `dlclose()` : un constructeur statique ne doit donc
pas laisser un thread ou une ressource supposant que le DSO restera mappé.

## Sécurité

Un plugin natif est du code **totalement de confiance dans le processus**. Il
n'y a ni sandbox, ni isolation mémoire, ni confinement des privilèges. Un plugin
malveillant ou bogué peut faire planter/corrompre Babet et possède les mêmes
droits que le processus.

## Limites volontaires

Le chargement natif est activé uniquement dans le CLI Babet normal. Il est
refusé dans les workers, les hôtes externes `libbabet` et les applications
générées par `--create-exe` afin de conserver leur contrat « un fichier à
copier, un fichier à lancer ».

Il n'y a ni gestionnaire de paquets, ni téléchargement Internet, ni résolution
de dépendances, ni découverte automatique via `require()`, ni extraction dans
`/tmp`, ni empaquetage automatique des `.so`. Les noms `.so` et `.so.<version>` numérique (par exemple `.so.1` ou `.so.1.2.3`)
sont acceptés, et le chargement/appel fonctionne depuis les coroutines Lua du
même état global.

Voir `NATIVE_PLUGIN_DESIGN.md` pour le contrat d'architecture complet.
