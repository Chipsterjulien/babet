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
 * opts : cwd, env, launch_timeout.
 *
 * Le processus possède des pipes non bloquants et un groupe de processus
 * dédié. Les méthodes read_stdout/read_stderr/write permettent un pilotage
 * progressif sans accumulation automatique en mémoire. close()/__gc
 * terminent et réapent un processus encore actif de manière bornée.
 */
void register_process(lua_State *L);

#endif // LUA_BINDINGS_PROCESS_HPP
