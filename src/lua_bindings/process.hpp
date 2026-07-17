#ifndef LUA_BINDINGS_PROCESS_HPP
#define LUA_BINDINGS_PROCESS_HPP

struct lua_State;

/**
 * @brief Enregistre babet.spawn() et la métatable du userdata processus.
 *
 * API Lua :
 *
 *   process, err = babet.spawn(command [, args] [, opts])
 *
 * opts : cwd, env, launch_timeout, stdin, stdout, stderr.
 *
 * Par défaut, le processus possède trois pipes non bloquants. Chaque flux peut
 * aussi être hérité ou raccordé à /dev/null ; stdout/stderr peuvent viser un
 * fichier et stderr peut être fusionné dans stdout. Les méthodes de streaming
 * restent disponibles uniquement pour les flux configurés comme pipes.
 * close()/__gc terminent et réapent un processus encore actif de manière
 * bornée.
 */
void register_process(lua_State *L);

#endif // LUA_BINDINGS_PROCESS_HPP
