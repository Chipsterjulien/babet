> [English](../en/runtime-exit.md) | **Français**

# Sortie du programme

Dans le CLI Babet et les exécutables générés, `os.exit([code [, close]])`
termine le processus, y compris depuis une coroutine ou sous `pcall`.
Les codes suivent Lua : absent, `nil` ou `true` signifie succès ; `false`
signifie échec ; un entier fournit le code de sortie. Un argument invalide
lève une erreur Lua avant tout nettoyage.

Babet neutralise ses callbacks GUI et restaure sa session curses avant de
sortir. Si un enfant interactif détient encore le terminal, Babet respecte
cette propriété : il ne lui reprend pas le TTY. Il faut attendre ou terminer
explicitement cet enfant avant de quitter pour obtenir un retour ordonné.

- `close` absent ou faux : pas de fermeture de l'état Lua, pas de finaliseurs
  Lua et pas d'attente ajoutée des workers. Les autres threads se terminent
  avec le processus.
- `close` vrai au sens Lua : fermeture de l'état Lua par le nettoyage commun
  de Babet, avec ses finaliseurs et l'attente habituelle des workers. Cette
  fermeture peut attendre un worker bloqué dans un appel natif non coopératif ;
  ce n'est pas une annulation forcée ni une garantie de délai.

Les buffers des fichiers C/Lua ouverts sont vidés avant la sortie. Cette
opération peut elle-même attendre une E/S ; ce n'est pas une synchronisation
sur disque équivalente à `fsync`. Les destructeurs automatiques C++ des piles
abandonnées ne sont pas exécutés.

**Différence avec le `os.exit` de Lua standard :** après ce nettoyage explicite,
Babet arrête le processus sans lancer les callbacks natifs `atexit` ni les
destructeurs statiques C++. Cela évite de démonter des bibliothèques globales
alors que des workers ou des threads natifs peuvent encore les utiliser.
Les plugins doivent effectuer leur nettoyage métier explicitement avant
`os.exit`. Un retour normal du script conserve le chemin de fermeture normal
et les callbacks natifs de fin de processus.

Un `os.exit` déclenché par un finaliseur pendant la fermeture de Babet ne lance
pas une seconde fermeture de la même VM ; il termine avec le nouveau code.
Les finaliseurs restants ne sont alors pas garantis.

Dans les workers, `os.exit` reste interdit et lève une erreur Lua : utiliser
`return`. L'API d'embedding ne remplace pas le `os.exit` standard de l'état
principal de l'hôte ; cette politique du CLI n'y est pas installée.
