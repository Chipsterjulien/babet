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
#include <cstring>
#include <dlfcn.h>
#include <new>

// Exercise the actual binding/loader; only unrelated terminal services are
// stubbed. Faults are injected in Lua allocation and C++ new independently.
namespace babet_curses { bool session_active() noexcept { return false; } }
void signal_dispatch_pending(lua_State *) {}

static int cpp_budget = -1;
static int cpp_failures = 0;
void *operator new(std::size_t size)
{
    if (cpp_budget == 0) {
        cpp_budget = -1;
        ++cpp_failures;
        throw std::bad_alloc();
    }
    if (cpp_budget > 0) --cpp_budget;
    if (void *p = std::malloc(size ? size : 1)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
// WidgetState uses nothrow new. Route that overload through the same allocator
// so ASan sees matching malloc/free pairs in this injection harness too.
void *operator new(std::size_t size, const std::nothrow_t &) noexcept
{
    try { return ::operator new(size); }
    catch (...) { return nullptr; }
}
void operator delete(void *p, const std::nothrow_t &) noexcept { std::free(p); }

struct Allocator { int budget = -1; int failures = 0; };
static void *allocate(void *ud, void *ptr, size_t old_size, size_t size)
{
    auto *a = static_cast<Allocator *>(ud);
    if (!size) { std::free(ptr); return nullptr; }
    if (a->budget >= 0 && (!ptr || size > old_size)) {
        if (a->budget == 0) { ++a->failures; return nullptr; }
        --a->budget;
    }
    return std::realloc(ptr, size);
}
static void check(bool ok, const char *message)
{
    if (!ok) { std::fprintf(stderr, "[FAIL] GUI callback OOM: %s\n", message); std::exit(1); }
}
static void execute(lua_State *L, const char *code)
{
    if (luaL_loadstring(L, code) != LUA_OK || lua_pcall(L, 0, 0, 0) != LUA_OK) {
        std::fprintf(stderr, "[FAIL] probe Lua: %s\n", lua_tostring(L, -1));
        std::exit(1);
    }
}
static lua_State *create_state(Allocator &allocator)
{
    lua_State *L = lua_newstate(allocate, &allocator, 0);
    check(L != nullptr, "create Lua state");
    lua_atpanic(L, [](lua_State *s) -> int {
        std::fprintf(stderr, "[FAIL] Lua error crossed GTK: %s\n", lua_tostring(s, -1));
        std::_Exit(86);
    });
    luaL_openlibs(L);
    lua_newtable(L);
    babet_gui::register_gui(L);
    lua_setglobal(L, "babet");
    execute(L, "gui = babet.gui; assert(gui.init())");
    return L;
}

using Counter = size_t (*)();
using Emit = void (*)();
static Counter text_copies;
static Counter live_widgets;
static Emit emit_text_changed;
template <typename Function>
static Function symbol(void *handle, const char *name)
{
    void *raw = dlsym(handle, name);
    check(raw != nullptr, name);
    Function fn;
    static_assert(sizeof(fn) == sizeof(raw));
    std::memcpy(&fn, &raw, sizeof(fn));
    return fn;
}
static void load_counters()
{
    void *handle = dlopen("libgtk-4.so.1", RTLD_NOW | RTLD_NOLOAD);
    check(handle != nullptr, "fake GTK must already be loaded");
    text_copies = symbol<Counter>(handle, "babet_fake_gtk_text_copies");
    live_widgets = symbol<Counter>(handle, "babet_fake_gtk_live_widgets");
    emit_text_changed = symbol<Emit>(handle, "babet_fake_gtk_emit_text_changed");
    dlclose(handle); // the production loader keeps its own resident reference
}
static void close_state(lua_State *L)
{
    babet_gui::cleanup_on_main_thread(L);
    lua_close(L);
    check(text_copies() == 0, "GLib text copy leaked");
    check(live_widgets() == 0, "native widget/reference leaked");
    check(!babet_gui::session_active(), "GUI still active after closing its Lua state");
}

static void drag_faults()
{
    int failed = 0, successful = 0;
    for (int budget = 0; budget < 32; ++budget) {
        Allocator a;
        lua_State *L = create_state(a);
        load_counters();
        execute(L, R"lua(
            window = assert(gui.window())
            handle = assert(gui.label('move'))
            seen = 0
            assert(window:add(handle))
            -- Do not intern the phase strings in Lua before arming the fault.
            assert(handle:onDrag(function() seen = seen + 1 end))
            assert(window:show())
            collectgarbage('collect')
        )lua");
        check(lua_checkstack(L, 128) != 0, "reserve drag stack");
        const int top = lua_gettop(L);
        a.budget = budget;
        // No outer lua_pcall: every signal must return through GTK normally.
        (void)babet_gui::detail::gtk4_main_context_iteration(false);
        a.budget = -1;
        check(lua_gettop(L) == top, "drag changed the caller's Lua stack");
        if (a.failures) ++failed;
        else { ++successful; execute(L, "assert(seen == 4)"); }
        // A fresh gesture works after the failures, including self-removal.
        execute(L, R"lua(
            recovery = assert(gui.label('recover'))
            recovered = false
            assert(window:add(recovery))
            assert(recovery:onDrag(function()
                assert(recovery:onDrag(nil))
                recovered = true
            end))
        )lua");
        (void)babet_gui::detail::gtk4_main_context_iteration(false);
        execute(L, "assert(recovered); assert(window:close())");
        close_state(L);
    }
    check(failed > 0 && successful > 0, "drag sweep needs failures and successful controls");
    std::printf("[PASS] onDrag Lua allocator: %d fault cases / %d controls; recovery and 32 states closed\n",
                failed, successful);
}

static void text_faults()
{
    int failed = 0, successful = 0;
    for (int setter = 0; setter <= 1; ++setter) {
        // getText: one C++ copy. setText: before and after copies. Include
        // successful controls and fault each copy independently.
        for (int budget = 0; budget <= setter + 1; ++budget) {
            Allocator a;
            lua_State *L = create_state(a);
            load_counters();
            execute(L, R"lua(
                window = assert(gui.window())
                original = string.rep('a', 1024)
                payload = string.rep('b', 1024)
                view = assert(gui.textView {text = original})
                assert(window:add(view))
                notified, callback_on_main = 0, false
                assert(view:onChanged(function()
                    callback_on_main = select(2, coroutine.running())
                    notified = notified + 1
                end))
                function resume_operation() return coroutine.resume(co) end
            )lua");
            execute(L, setter
                ? "co = coroutine.create(function() return view:setText(payload) end)"
                : "co = coroutine.create(function() return view:getText() end)");
            lua_getglobal(L, "resume_operation");
            const int old_failures = cpp_failures;
            cpp_budget = budget;
            const int status = lua_pcall(L, 0, 3, 0);
            cpp_budget = -1;
            check(status == LUA_OK && lua_toboolean(L, -3), "exception escaped coroutine boundary");
            const bool fault = cpp_failures != old_failures;
            check(fault == (budget <= setter), "expected C++ allocation was not exercised");
            if (fault) {
                ++failed;
                const char *message = lua_tostring(L, -1);
                check(lua_isnil(L, -2) && message && std::strstr(message, "out of memory"),
                      "allocation error must return nil, error");
            }
            else ++successful;
            lua_settop(L, 0);
            check(text_copies() == 0, "text copy leaked on getText/setText failure");
            // The post-write failure may leave GTK's new text in place; it
            // must not leave the callback thread/depth or references stuck.
            execute(L, setter && budget > 0
                ? "assert(view:getText() == payload)"
                : "assert(view:getText() == original)");
            execute(L, "notified, callback_on_main = 0, false");
            emit_text_changed(); // native event, outside any Lua invocation
            execute(L, R"lua(
                assert(notified == 1 and callback_on_main,
                       'callback thread/depth was not restored after setter')
                co = nil
                collectgarbage('collect')
                assert(view:setText('recovered'))
                assert(notified == 2 and callback_on_main)
                -- Re-entrant setter, explicit finalization and closing the
                -- window must all remain safe while the outer call is pinned.
                assert(view:onChanged(function()
                    assert(view:onChanged(nil))
                    assert(view:setText('nested'))
                    getmetatable(view).__gc(view)
                    assert(window:close())
                end))
                assert(view:setText('close from callback'))
                window, view = nil, nil
                collectgarbage('collect')
            )lua");
            close_state(L);
        }
    }
    check(failed == 3 && successful == 2, "incomplete text fault coverage");
    std::printf("[PASS] TextView C++ allocator: %d fault cases / %d controls; text buffers, references and coroutine recovery\n",
                failed, successful);
}

static void drop_faults()
{
    int failed = 0, successful = 0;
    for (int budget = 0; budget < 32; ++budget) {
        Allocator a;
        lua_State *L = create_state(a);
        load_counters();
        execute(L, R"lua(
            window = assert(gui.window())
            root = assert(gui.box())
            source = assert(gui.label('source'))
            target = assert(gui.label('target'))
            assert(root:add(source)); assert(root:add(target)); assert(window:add(root))
            assert(source:setDragData(string.rep('data-', 40)))
            seen = 0
            assert(target:onDrop(function() seen = seen + 1 end))
            assert(window:show())
            collectgarbage('collect')
        )lua");
        check(lua_checkstack(L, 128) != 0, "reserve drop stack");
        const int top = lua_gettop(L);
        a.budget = budget;
        (void)babet_gui::detail::gtk4_main_context_iteration(false);
        a.budget = -1;
        check(lua_gettop(L) == top, "drop changed Lua stack");
        if (a.failures) ++failed;
        else { ++successful; execute(L, "assert(seen == 3)"); }
        execute(L, R"lua(
            recovery_source = assert(gui.label('recovery'))
            assert(root:add(recovery_source))
            assert(recovery_source:setDragData('recovery-id'))
            recovered = false
            assert(target:onDrop(function(phase, payload)
                if phase == 'drop' then
                    assert(payload == 'recovery-id')
                    recovered = true
                    assert(target:onDrop(nil))
                end
            end))
        )lua");
        (void)babet_gui::detail::gtk4_main_context_iteration(false);
        execute(L, "assert(recovered); assert(window:close())");
        close_state(L);
    }
    check(failed > 0 && successful > 0, "drop sweep controls");
    std::printf("[PASS] onDrop allocator: %d fault cases / %d controls\n", failed, successful);
}

static void drop_setter_faults()
{
    int failed = 0, successful = 0;
    for (int budget = 0; budget < 8; ++budget) {
        Allocator a;
        lua_State *L = create_state(a);
        load_counters();
        execute(L, R"lua(
            window = assert(gui.window())
            root = assert(gui.box())
            source = assert(gui.label('source'))
            outer = assert(gui.box())
            target = assert(gui.label('target'))
            assert(root:add(source)); assert(root:add(outer))
            assert(outer:add(target)); assert(window:add(root))
            assert(source:setDragData('setter-id'))
            child_drops, parent_drops = 0, 0
            handler = function(phase)
                if phase == 'drop' then child_drops = child_drops + 1 end
            end
            install = function() assert(target:onDrop(handler)) end
            assert(outer:onDrop(function(phase)
                if phase == 'drop' then parent_drops = parent_drops + 1 end
            end))
            assert(window:show()); collectgarbage('collect')
        )lua");
        check(lua_checkstack(L, 128) != 0, "reserve drop setter stack");
        lua_getglobal(L, "install");
        a.budget = budget;
        const int status = lua_pcall(L, 0, 0, 0);
        a.budget = -1;
        const bool fault = a.failures != 0;
        check(status == (fault ? LUA_ERRMEM : LUA_OK), "drop setter fault status");
        lua_settop(L, 0);
        if (fault) ++failed; else ++successful;
        (void)babet_gui::detail::gtk4_main_context_iteration(false);
        execute(L, fault ? "assert(parent_drops == 1 and child_drops == 0)"
                         : "assert(child_drops == 1 and parent_drops == 0)");
        execute(L, "install(); assert(window:close())");
        close_state(L);
    }
    check(failed > 0 && successful > 0, "drop setter sweep controls");
    std::printf("[PASS] onDrop installation allocator: %d fault cases / %d controls; parent fallback and cleanup\n",
                failed, successful);
}


static void drag_source_setter_faults()
{
    int failed = 0, successful = 0;
    for (int budget = 0; budget < 16; ++budget) {
        Allocator a;
        lua_State *L = create_state(a);
        load_counters();
        execute(L, R"lua(
            window = assert(gui.window())
            handle = assert(gui.label('handle'))
            assert(window:add(handle))
            install = function() assert(handle:setDragData('source-id')) end
            collectgarbage('collect')
        )lua");
        check(lua_checkstack(L, 128) != 0, "reserve source setter stack");
        lua_getglobal(L, "install");
        a.budget = budget;
        const int status = lua_pcall(L, 0, 0, 0);
        a.budget = -1;
        if (a.failures) {
            ++failed;
            check(status == LUA_ERRMEM, "source setter must propagate Lua OOM");
        } else {
            ++successful;
            check(status == LUA_OK, "source setter successful control");
        }
        lua_settop(L, 0);
        execute(L, "install(); assert(handle:setDragData(nil)); assert(window:close())");
        close_state(L); // Includes unattached controllers, not just widgets.
    }
    check(failed > 0 && successful > 0, "source setter sweep controls");
    std::printf("[PASS] setDragData allocator: %d fault cases / %d controls; retry and native cleanup\n",
                failed, successful);
}


int main(int argc, char **argv)
{
    babet_runtime::register_main_thread();
    check(argc == 2, "expected drag, text, drop, drop-setter or source-setter");
    if (std::strcmp(argv[1], "drag") == 0) drag_faults();
    else if (std::strcmp(argv[1], "text") == 0) text_faults();
    else if (std::strcmp(argv[1], "drop") == 0) drop_faults();
    else if (std::strcmp(argv[1], "drop-setter") == 0) drop_setter_faults();
    else if (std::strcmp(argv[1], "source-setter") == 0) drag_source_setter_faults();
    else check(false, "unknown test mode");
}
