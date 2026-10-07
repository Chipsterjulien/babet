#include "lua_bindings/gui.hpp"
#include "lua_bindings/gui_gtk_loader.hpp"
#include "lua_bindings/main_thread.hpp"
extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}
#include <cstdio>
#include <cstdlib>

// Only unrelated terminal services are stubbed. The real GUI binding, loader,
// Lua allocator and foreign GTK callback boundary are exercised below.
namespace babet_curses { bool session_active() noexcept { return false; } }
void signal_dispatch_pending(lua_State *) {}

struct Allocator {
    bool armed = false;
    int remaining = 0;
    int failures = 0;
};
static void *allocate(void *ud, void *ptr, size_t old_size, size_t size)
{
    auto *a = static_cast<Allocator *>(ud);
    if (size == 0) { std::free(ptr); return nullptr; }
    if (a->armed && (!ptr || size > old_size)) {
        if (a->remaining == 0) { ++a->failures; return nullptr; }
        --a->remaining;
    }
    return std::realloc(ptr, size);
}
static void execute(lua_State *L, const char *code)
{
    if (luaL_loadstring(L, code) != LUA_OK || lua_pcall(L, 0, 0, 0) != LUA_OK) {
        std::fprintf(stderr, "probe Lua failure: %s\n", lua_tostring(L, -1));
        std::exit(1);
    }
}
int main()
{
    babet_runtime::register_main_thread();
    int failing_cases = 0, successful_cases = 0;
    for (int fail_after = 0; fail_after < 32; ++fail_after) {
        Allocator allocator;
        lua_State *L = lua_newstate(allocate, &allocator, 0);
        if (!L) return 1;
        luaL_openlibs(L);
        lua_newtable(L);
        babet_gui::register_gui(L);
        lua_setglobal(L, "babet");
        execute(L, R"lua(
            gui = babet.gui
            assert(gui.init())
            window = assert(gui.window())
            area = assert(gui.drawingArea())
            assert(window:add(area))
            assert(area:onDraw(function(ctx)
                retained = ctx
                local allocation = string.rep('allocation inside draw', 1000)
                assert(#allocation > 1000)
                assert(ctx:moveTo(1, 2))
                assert(ctx:lineTo(10, 20))
                assert(ctx:stroke())
                finished = true
            end))
            assert(window:show())
        )lua");
        if (!lua_checkstack(L, 128)) return 1;
        allocator.armed = true;
        allocator.remaining = fail_after;
        // No surrounding lua_pcall: any Lua longjmp across GTK is a panic.
        (void)babet_gui::detail::gtk4_main_context_iteration(false);
        allocator.armed = false;
        if (allocator.failures) ++failing_cases;
        else ++successful_cases;
        execute(L, R"lua(
            if retained then
                local ok, err = pcall(function() retained:stroke() end)
                assert(not ok and tostring(err):find('only valid during', 1, true))
            end
            assert(window:close())
            window, area, retained = nil, nil, nil
            collectgarbage('collect')
        )lua");
        babet_gui::cleanup_on_main_thread(L);
        lua_close(L);
        if (babet_gui::session_active()) return 1;
    }
    if (!failing_cases || !successful_cases) return 1;
    std::printf("[PASS] DrawingArea allocator faults: %d rejected / %d successful; 32 states closed\n",
                failing_cases, successful_cases);
}
