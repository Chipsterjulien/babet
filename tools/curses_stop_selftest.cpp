#ifndef _XOPEN_SOURCE_EXTENDED
#define _XOPEN_SOURCE_EXTENDED 1
#endif
#include <lua.hpp>
#include <curses.h>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include "lua_bindings/curses.hpp"
#include "lua_bindings/main_thread.hpp"
#include "lua_bindings/signal.hpp"

// This isolated curses test never starts GUI. Terminal, signal and curses
// implementations are real; only their unrelated GUI-active query is stubbed.
namespace babet_gui { bool session_active() noexcept { return false; } }
namespace
{
int inject_after = 0;
int injections = 0;
int reads_after_stop = 0;
int arm(lua_State *L)
{
    inject_after = static_cast<int>(luaL_checkinteger(L, 1));
    return 0;
}
int queue_key(lua_State *L)
{
    if (::unget_wch(L'x') != OK) return luaL_error(L, "cannot queue test key");
    return 0;
}
}

extern "C" bool __real__Z26signal_any_handled_pendingv();
extern "C" bool __wrap__Z26signal_any_handled_pendingv()
{
    const bool pending = __real__Z26signal_any_handled_pendingv();
    if (inject_after > 0 && --inject_after == 0)
    {
        if (pending || std::raise(SIGUSR1) != 0) std::abort();
        ++injections;
    }
    return pending;
}
extern "C" int __real_wget_wch(WINDOW *, wint_t *);
extern "C" int __wrap_wget_wch(WINDOW *window, wint_t *key)
{
    if (!babet_curses::session_active())
    {
        ++reads_after_stop;
        std::fprintf(stderr, "[FAIL] read attempted after curses.stop\n");
        std::_Exit(90);
    }
    return __real_wget_wch(window, key);
}

int main(int argc, char **argv)
{
    if (argc != 2) return 2;
    ::alarm(10);
    babet_runtime::register_main_thread();
    lua_State *L = luaL_newstate();
    if (!L) return 2;
    luaL_openlibs(L);
    lua_newtable(L);
    register_signal(L);
    babet_curses::register_curses(L);
    lua_setglobal(L, "babet");
    lua_register(L, "arm_race", arm);
    lua_register(L, "queue_key", queue_key);
    const int status = luaL_dofile(L, argv[1]);
    if (status != LUA_OK) std::fprintf(stderr, "%s\n", lua_tostring(L, -1));
    const bool stopped = !babet_curses::session_active();
    babet_curses::cleanup_on_main_thread();
    lua_close(L);
    ::signal(SIGUSR1, SIG_DFL);
    if (status != LUA_OK || !stopped || injections != 1 || reads_after_stop != 0)
        return 1;
    std::puts("CURSES_STOP_RACE_OK");
    return 0;
}
