#ifndef LUA_BINDINGS_SIGNAL_HPP
#define LUA_BINDINGS_SIGNAL_HPP

struct lua_State;

/**
 * @brief Enregistre la sous-table babet.signal.
 *
 * API Lua, réservée au thread principal :
 *
 *   babet.signal.handle(name, fn_or_nil) -> true | (nil, err)
 *   babet.signal.ignore(name)            -> true | (nil, err)
 *   babet.signal.default(name)           -> true | (nil, err)
 *
 * Les succès renvoient une seule valeur (`true`). Les noms sont des chaînes
 * strictes parmi TERM, INT, HUP, USR1, USR2 et PIPE. handle(name, nil) retire
 * le callback et restaure SIG_DFL ; handle(name) sans second argument est
 * refusé. Les mauvais arguments et les appels depuis un worker lèvent une
 * erreur Lua ; seule une panne de sigaction renvoie (nil, err).
 *
 * Le vrai handler POSIX est async-signal-safe et ne fait que poser un flag
 * sig_atomic_t. Les callbacks Lua, sans argument, sont dispatchés plus tard
 * dans la coroutine active du thread principal depuis un hook count ou un appel Babet
 * interrompu. Les occurrences identiques sont coalescées ; plusieurs types
 * pending sont traités dans l'ordre fixe TERM, INT, HUP, USR1, USR2, PIPE.
 * Une erreur du callback est volontairement avalée après lua_pcall.
 */
void register_signal(lua_State *L);

/**
 * @brief Dispatche les signaux supportés actuellement pending.
 *
 * No-op hors du thread principal. Pour chaque flag posé, le flag est remis à
 * zéro avant l'appel du callback afin qu'une nouvelle occurrence pendant le
 * callback puisse être traitée lors d'un dispatch ultérieur.
 */
void signal_dispatch_pending(lua_State *L);

/**
 * @brief Installe le hook main-thread partagé signal/terminal.
 *
 * Vérifie le hook réel du thread Lua principal et de la coroutine appelante.
 * Installé à la demande par handle(fn) ou curses.start(), il est hérité par les
 * coroutines créées ensuite depuis un thread équipé. Les autres coroutines
 * déjà existantes ne sont pas modifiées. curses l'utilise sans callback afin
 * que SIGWINCH/SIGTSTP et les terminaisons différées soient servis pendant une
 * boucle Lua pure.
 */
void signal_ensure_dispatch_hook(lua_State *L);

/**
 * @brief Indique si le thread principal possède un signal géré pending.
 *
 * No-op logique hors du thread principal (renvoie false). Utilisé par les
 * boucles bloquantes pour distinguer un EINTR étranger d'une interruption
 * Babet qui doit déclencher les callbacks puis renvoyer "interrupted".
 */
bool signal_any_handled_pending();

#endif // LUA_BINDINGS_SIGNAL_HPP
