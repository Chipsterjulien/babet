#ifndef BABET_MAIN_THREAD_HPP
#define BABET_MAIN_THREAD_HPP

struct lua_State;

namespace babet_runtime
{

// Capture une fois le pthread du main() avant l'enregistrement des modules et
// avant tout worker. Avant l'enregistrement, le thread courant est considéré
// comme principal pour ne pas rendre le bootstrap fragile.
void register_main_thread() noexcept;

// Test allocation-free partagé par signal/process/curses.
bool is_main_thread() noexcept;

// Garde Lua commune. Lève une erreur Lua avec un diagnostic cohérent si un
// binding réservé au thread principal est appelé depuis un worker.
void require_main_thread(lua_State *L, const char *api_name);

} // namespace babet_runtime

#endif // BABET_MAIN_THREAD_HPP
