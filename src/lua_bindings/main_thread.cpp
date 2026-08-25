#include "main_thread.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include <pthread.h>

namespace babet_runtime
{
namespace
{
pthread_t g_main_thread{};
bool g_main_thread_set = false;
}

void register_main_thread() noexcept
{
    g_main_thread = ::pthread_self();
    g_main_thread_set = true;
}

bool is_main_thread() noexcept
{
    if (!g_main_thread_set)
        return true;
    return ::pthread_equal(::pthread_self(), g_main_thread) != 0;
}

void require_main_thread(lua_State *L, const char *api_name)
{
    if (!is_main_thread())
    {
        luaL_error(L, "%s: this operation is only available from the main thread, not from a worker",
                   api_name);
    }
}

} // namespace babet_runtime
