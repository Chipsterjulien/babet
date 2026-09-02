#include "gui.hpp"

#include "curses.hpp"
#include "gui_gtk_loader.hpp"
#include "lua_utils.hpp"
#include "main_thread.hpp"
#include "signal.hpp"

extern "C"
{
#include "lua.h"
#include "lauxlib.h"
}

#include <atomic>
#include <climits>
#include <cstdio>
#include <cstring>
#include <new>
#include <string>

namespace babet_gui
{
namespace
{

constexpr const char *WIDGET_META = "BabetGuiWidget";
constexpr unsigned int GUI_WAKE_INTERVAL_MS = 25;

enum class WidgetKind : unsigned char
{
    window,
    box,
    label,
    button,
};

struct WidgetState
{
    void *native = nullptr;
    lua_State *owner = nullptr; // main Lua thread of the owning Lua state
    WidgetKind kind = WidgetKind::label;
    int callback_ref = LUA_NOREF;
    int references = 1; // Lua userdata; destroy signal adds one native reference
    bool owns_reference = false; // construction ref for non-toplevel widgets
    WidgetState *previous = nullptr;
    WidgetState *next = nullptr;
};

struct WidgetUserdata
{
    WidgetState *state = nullptr;
};

WidgetState *g_states = nullptr;
lua_State *g_gui_owner = nullptr;
std::atomic_int g_live_widgets{0};
std::atomic_int g_live_windows{0};
std::atomic_bool g_run_active{false};
std::atomic_bool g_quit_requested{false};
bool g_initialized = false;

void link_state(WidgetState *state) noexcept
{
    state->previous = nullptr;
    state->next = g_states;
    if (g_states)
        g_states->previous = state;
    g_states = state;
}

void unlink_state(WidgetState *state) noexcept
{
    if (state->previous)
        state->previous->next = state->next;
    else if (g_states == state)
        g_states = state->next;
    if (state->next)
        state->next->previous = state->previous;
    state->previous = nullptr;
    state->next = nullptr;
}

void retain_state(WidgetState *state) noexcept
{
    ++state->references;
}

void release_state(WidgetState *state) noexcept
{
    if (--state->references == 0)
    {
        unlink_state(state);
        delete state;
    }
}

lua_State *main_lua_state(lua_State *L) noexcept
{
    lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_MAINTHREAD);
    lua_State *main = lua_tothread(L, -1);
    lua_pop(L, 1);
    return main ? main : L;
}

void require_gui_initialized(lua_State *L, const char *api)
{
    babet_runtime::require_main_thread(L, api);
    if (!g_initialized)
        luaL_error(L, "%s: call babet.gui.init() first", api);
    if (babet_curses::session_active())
        luaL_error(L, "%s: unavailable while a curses session is active", api);

    lua_State *owner = main_lua_state(L);
    if (g_gui_owner && g_gui_owner != owner)
        luaL_error(L, "%s: another Lua state currently owns the GUI", api);
}

const char *kind_name(WidgetKind kind) noexcept
{
    switch (kind)
    {
    case WidgetKind::window: return "window";
    case WidgetKind::box: return "box";
    case WidgetKind::label: return "label";
    case WidgetKind::button: return "button";
    }
    return "widget";
}

WidgetState *check_widget(lua_State *L, int index, const char *api)
{
    babet_runtime::require_main_thread(L, api);
    auto *userdata = static_cast<WidgetUserdata *>(
        luaL_checkudata(L, index, WIDGET_META));
    if (!userdata || !userdata->state || !userdata->state->native)
        luaL_error(L, "%s: widget has already been destroyed", api);
    if (userdata->state->owner != main_lua_state(L))
        luaL_error(L, "%s: widget belongs to another Lua state", api);
    return userdata->state;
}

WidgetState *check_kind(lua_State *L, int index, WidgetKind kind,
                        const char *api)
{
    WidgetState *state = check_widget(L, index, api);
    if (state->kind != kind)
        luaL_error(L, "%s: expected a %s handle", api, kind_name(kind));
    return state;
}

template <typename Function>
detail::GtkCallback gtk_callback(Function function) noexcept
{
    static_assert(sizeof(Function) == sizeof(detail::GtkCallback),
                  "GTK signal callback pointer size mismatch");
    detail::GtkCallback generic = nullptr;
    std::memcpy(&generic, &function, sizeof(generic));
    return generic;
}

void report_callback_error(lua_State *L) noexcept
{
    static constexpr char prefix[] = "babet.gui callback error: ";
    std::fwrite(prefix, 1, sizeof(prefix) - 1, stderr);
    if (lua_type(L, -1) == LUA_TSTRING)
    {
        size_t length = 0;
        const char *message = lua_tolstring(L, -1, &length);
        if (message && length)
            std::fwrite(message, 1, length, stderr);
    }
    else
    {
        static constexpr char fallback[] = "non-string Lua error";
        std::fwrite(fallback, 1, sizeof(fallback) - 1, stderr);
    }
    std::fputc('\n', stderr);
    std::fflush(stderr);
}

void widget_destroyed(void *, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (!state || !state->native)
        return;

    state->native = nullptr;
    state->owns_reference = false;
    g_live_widgets.fetch_sub(1, std::memory_order_acq_rel);
    if (state->kind == WidgetKind::window)
        g_live_windows.fetch_sub(1, std::memory_order_acq_rel);

    if (g_live_widgets.load(std::memory_order_acquire) == 0)
        g_gui_owner = nullptr;

    // Relâche la référence logique détenue par le signal native "destroy".
    release_state(state);
}

void button_clicked(void *, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (!state || !state->native || !state->owner ||
        state->callback_ref == LUA_NOREF || state->callback_ref == LUA_REFNIL)
        return;

    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    if (!lua_checkstack(L, 1))
    {
        static constexpr char message[] =
            "babet.gui callback error: cannot grow Lua stack\n";
        std::fwrite(message, 1, sizeof(message) - 1, stderr);
        return;
    }

    lua_rawgeti(L, LUA_REGISTRYINDEX, state->callback_ref);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK)
    {
        report_callback_error(L);
        lua_settop(L, base);
        return;
    }
    lua_settop(L, base);
}

bool attach_destroy_signal(WidgetState *state) noexcept
{
    retain_state(state);
    const unsigned long id = detail::gtk4_signal_connect(
        state->native, "destroy", gtk_callback(&widget_destroyed), state);
    if (id == 0)
    {
        release_state(state);
        return false;
    }
    return true;
}

WidgetUserdata *push_empty_widget_userdata(lua_State *L)
{
    auto *userdata = static_cast<WidgetUserdata *>(
        lua_newuserdatauv(L, sizeof(WidgetUserdata), 1));
    userdata->state = nullptr;

    // Le parent Lua garde ses enfants Lua vivants. Cette table est créée avant
    // toute acquisition de ressource GTK afin qu'un OOM ne puisse pas sauter
    // au-dessus d'un widget natif déjà acquis.
    lua_newtable(L);
    lua_setiuservalue(L, -2, 1);

    luaL_getmetatable(L, WIDGET_META);
    lua_setmetatable(L, -2);
    return userdata;
}

void register_live_widget(WidgetState *state, lua_State *owner) noexcept
{
    state->owner = owner;
    link_state(state);
    g_live_widgets.fetch_add(1, std::memory_order_acq_rel);
    if (state->kind == WidgetKind::window)
        g_live_windows.fetch_add(1, std::memory_order_acq_rel);
    if (!g_gui_owner)
        g_gui_owner = owner;
}

int push_native_widget(lua_State *L, WidgetKind kind, void *native,
                       bool take_construction_reference)
{
    // L'userdata et sa table d'enfants doivent déjà être au sommet. Aucune API
    // Lua susceptible d'allouer n'est appelée après que `native` est attaché.
    auto *userdata = static_cast<WidgetUserdata *>(lua_touserdata(L, -1));
    if (!native)
        return push_fail_protected(L, "babet.gui: GTK 4 failed to create widget");

    WidgetState *state = new WidgetState();
    state->native = native;
    state->kind = kind;
    state->owns_reference = take_construction_reference;
    if (take_construction_reference)
        (void)detail::gtk4_object_ref_sink(native);

    userdata->state = state;
    register_live_widget(state, main_lua_state(L));

    if (!attach_destroy_signal(state))
    {
        // Détacher d'abord l'userdata : si la destruction native réentre dans
        // le signal, aucun finalizer Lua ne peut réutiliser cet état.
        userdata->state = nullptr;
        if (kind == WidgetKind::window)
            detail::gtk4_window_destroy(native);
        else if (state->owns_reference)
        {
            state->owns_reference = false;
            detail::gtk4_object_unref(native);
        }
        if (state->native)
        {
            state->native = nullptr;
            g_live_widgets.fetch_sub(1, std::memory_order_acq_rel);
            if (kind == WidgetKind::window)
                g_live_windows.fetch_sub(1, std::memory_order_acq_rel);
        }
        release_state(state);
        return push_fail_protected(L,
            "babet.gui: cannot attach GTK widget lifetime signal");
    }

    return 1;
}

void release_construction_reference(WidgetState *state) noexcept
{
    if (state && state->native && state->owns_reference)
    {
        state->owns_reference = false;
        detail::gtk4_object_unref(state->native);
    }
}

bool strict_c_string(lua_State *L, int index, const char *api,
                     const char *&text)
{
    if (!lua_is_strict_string(L, index))
        luaL_error(L, "%s: expected a string", api);
    size_t length = 0;
    text = lua_tolstring(L, index, &length);
    if (!text || std::strlen(text) != length)
        luaL_error(L, "%s: embedded NUL is not supported by GTK strings", api);
    return true;
}

void parse_window_options(lua_State *L, const char *&title, int &width,
                          int &height)
{
    title = "";
    width = -1;
    height = -1;
    if (lua_gettop(L) == 0 || lua_isnil(L, 1))
        return;
    if (lua_type(L, 1) != LUA_TTABLE)
        luaL_error(L, "gui.window expects an optional options table");

    lua_pushliteral(L, "title");
    lua_rawget(L, 1);
    if (!lua_isnil(L, -1))
        strict_c_string(L, -1, "gui.window title", title);
    lua_pop(L, 1);

    auto read_size = [L](const char *name, int &value)
    {
        lua_pushstring(L, name);
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_integer(L, -1))
                luaL_error(L, "gui.window %s must be an integer", name);
            const lua_Integer candidate = lua_tointeger(L, -1);
            if (candidate <= 0 || candidate > INT_MAX)
                luaL_error(L, "gui.window %s is out of range", name);
            value = static_cast<int>(candidate);
        }
        lua_pop(L, 1);
    };
    read_size("width", width);
    read_size("height", height);
}

void parse_box_options(lua_State *L, int &orientation, int &spacing)
{
    orientation = 1; // GTK_ORIENTATION_VERTICAL
    spacing = 0;
    if (lua_gettop(L) == 0 || lua_isnil(L, 1))
        return;
    if (lua_type(L, 1) != LUA_TTABLE)
        luaL_error(L, "gui.box expects an optional options table");

    lua_pushliteral(L, "orientation");
    lua_rawget(L, 1);
    if (!lua_isnil(L, -1))
    {
        const char *text = nullptr;
        strict_c_string(L, -1, "gui.box orientation", text);
        if (std::strcmp(text, "vertical") == 0)
            orientation = 1;
        else if (std::strcmp(text, "horizontal") == 0)
            orientation = 0;
        else
            luaL_error(L, "gui.box orientation must be 'vertical' or 'horizontal'");
    }
    lua_pop(L, 1);

    lua_pushliteral(L, "spacing");
    lua_rawget(L, 1);
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1))
            luaL_error(L, "gui.box spacing must be an integer");
        const lua_Integer candidate = lua_tointeger(L, -1);
        if (candidate < 0 || candidate > INT_MAX)
            luaL_error(L, "gui.box spacing is out of range");
        spacing = static_cast<int>(candidate);
    }
    lua_pop(L, 1);
}

int l_available(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.available expects no arguments");
    babet_runtime::require_main_thread(L, "gui.available");
    std::string error;
    if (!detail::gtk4_load(error))
        return push_fail_protected(L, error);
    return push_ok_protected(L);
}

int l_init(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.init expects no arguments");
    babet_runtime::require_main_thread(L, "gui.init");
    if (g_initialized)
        return push_ok_protected(L);
    if (babet_curses::session_active())
        return push_fail_protected(
            L, "babet.gui: cannot initialize GTK 4 while a curses session is active");

    std::string error;
    if (!detail::gtk4_initialize(error))
        return push_fail_protected(L, error);
    g_initialized = true;
    return push_ok_protected(L);
}

int l_window(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1))
        return luaL_error(L, "gui.window expects an optional options table");
    require_gui_initialized(L, "gui.window");
    const char *title = "";
    int width = -1;
    int height = -1;
    parse_window_options(L, title, width, height);

    push_empty_widget_userdata(L);
    void *window = detail::gtk4_window_new();
    const int result = push_native_widget(L, WidgetKind::window, window, false);
    if (result != 1)
        return result;
    detail::gtk4_window_set_title(window, title);
    if (width > 0 || height > 0)
        detail::gtk4_window_set_default_size(window, width, height);
    return 1;
}

int l_box(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1))
        return luaL_error(L, "gui.box expects an optional options table");
    require_gui_initialized(L, "gui.box");
    int orientation = 1;
    int spacing = 0;
    parse_box_options(L, orientation, spacing);

    push_empty_widget_userdata(L);
    void *box = detail::gtk4_box_new(orientation, spacing);
    return push_native_widget(L, WidgetKind::box, box, true);
}

int l_label(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui.label expects one string");
    require_gui_initialized(L, "gui.label");
    const char *text = nullptr;
    strict_c_string(L, 1, "gui.label", text);

    push_empty_widget_userdata(L);
    void *label = detail::gtk4_label_new(text);
    return push_native_widget(L, WidgetKind::label, label, true);
}

int l_button(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui.button expects one string");
    require_gui_initialized(L, "gui.button");
    const char *text = nullptr;
    strict_c_string(L, 1, "gui.button", text);

    push_empty_widget_userdata(L);
    void *button = detail::gtk4_button_new_with_label(text);
    const int result = push_native_widget(L, WidgetKind::button, button, true);
    if (result != 1)
        return result;

    auto *userdata = static_cast<WidgetUserdata *>(lua_touserdata(L, -1));
    const unsigned long id = detail::gtk4_signal_connect(
        button, "clicked", gtk_callback(&button_clicked), userdata->state);
    if (id == 0)
        return push_fail_protected(L, "babet.gui: cannot attach button click signal");
    return 1;
}

int widget_add(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:add expects one child widget");
    WidgetState *parent = check_widget(L, 1, "gui widget:add");
    WidgetState *child = check_widget(L, 2, "gui widget:add");
    if (parent == child)
        return luaL_error(L, "gui widget:add: a widget cannot contain itself");
    if (parent->kind != WidgetKind::window && parent->kind != WidgetKind::box)
        return luaL_error(L, "gui widget:add: parent must be a window or box");
    if (child->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:add: a window cannot be a child widget");
    if (detail::gtk4_widget_get_parent(child->native) != nullptr)
        return luaL_error(L, "gui widget:add: child already has a GTK parent");

    // Root the Lua child BEFORE GTK takes ownership. A Lua OOM therefore leaves
    // the native hierarchy unchanged.
    lua_getiuservalue(L, 1, 1);
    const lua_Unsigned count = lua_rawlen(L, -1);
    if (count >= static_cast<lua_Unsigned>(LUA_MAXINTEGER))
    {
        lua_pop(L, 1);
        return luaL_error(L, "gui widget:add: too many child handles");
    }
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, static_cast<lua_Integer>(count + 1));
    lua_pop(L, 1);

    if (parent->kind == WidgetKind::window)
        detail::gtk4_window_set_child(parent->native, child->native);
    else
        detail::gtk4_box_append(parent->native, child->native);
    release_construction_reference(child);
    return push_ok_protected(L);
}

int widget_set_text(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:setText expects one string");
    WidgetState *state = check_widget(L, 1, "gui widget:setText");
    const char *text = nullptr;
    strict_c_string(L, 2, "gui widget:setText", text);
    if (state->kind == WidgetKind::label)
        detail::gtk4_label_set_text(state->native, text);
    else if (state->kind == WidgetKind::button)
        detail::gtk4_button_set_label(state->native, text);
    else
        return luaL_error(L, "gui widget:setText: only label and button support text");
    return push_ok_protected(L);
}

int button_on_click(lua_State *L)
{
    if (!lua_arity_is(L, 2) || lua_type(L, 2) != LUA_TFUNCTION)
        return luaL_error(L, "gui button:onClick expects one function");
    WidgetState *state = check_kind(L, 1, WidgetKind::button, "gui button:onClick");

    lua_pushvalue(L, 2);
    const int new_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    const int old_ref = state->callback_ref;
    state->callback_ref = new_ref;
    if (old_ref != LUA_NOREF && old_ref != LUA_REFNIL)
        luaL_unref(L, LUA_REGISTRYINDEX, old_ref);
    return push_ok_protected(L);
}

int window_show(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui window:show expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::window, "gui window:show");
    detail::gtk4_window_present(state->native);
    return push_ok_protected(L);
}

int window_close(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui window:close expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::window, "gui window:close");
    detail::gtk4_window_destroy(state->native);
    return push_ok_protected(L);
}

int wake_main_loop(void *) noexcept
{
    return 1; // keep the bounded wake source alive until gui.run removes it
}

int signal_dispatch_thunk(lua_State *L) noexcept
{
    // No C++ owner lives here; Lua failures are contained by the lua_pcall in
    // gui.run. signal_dispatch_pending already protects user signal callbacks.
    signal_dispatch_pending(L);
    return 0;
}

int l_run(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.run expects no arguments");
    require_gui_initialized(L, "gui.run");
    if (g_run_active.load(std::memory_order_acquire))
        return luaL_error(L, "gui.run: GUI event loop is already running");
    if (g_live_windows.load(std::memory_order_acquire) <= 0)
        return push_fail_protected(L, "babet.gui: gui.run requires a live window");
    if (g_gui_owner != main_lua_state(L))
        return push_fail_protected(L, "babet.gui: this Lua state does not own the GUI");
    if (!lua_checkstack(L, 2))
        return push_fail_protected(L, "babet.gui: cannot reserve Lua stack for GUI loop");

    g_quit_requested.store(false, std::memory_order_release);
    g_run_active.store(true, std::memory_order_release);
    const unsigned int wake_source =
        detail::gtk4_timeout_add(GUI_WAKE_INTERVAL_MS, &wake_main_loop, nullptr);
    if (wake_source == 0)
    {
        g_run_active.store(false, std::memory_order_release);
        return push_fail_protected(L, "babet.gui: cannot install GTK main-loop wake source");
    }

    while (!g_quit_requested.load(std::memory_order_acquire) &&
           g_live_windows.load(std::memory_order_acquire) > 0)
    {
        (void)detail::gtk4_main_context_iteration(true);

        lua_pushcfunction(L, signal_dispatch_thunk);
        const int status = lua_pcall(L, 0, 0, 0);
        if (status != LUA_OK)
        {
            (void)detail::gtk4_source_remove(wake_source);
            g_run_active.store(false, std::memory_order_release);
            return lua_error(L);
        }
    }

    (void)detail::gtk4_source_remove(wake_source);
    g_run_active.store(false, std::memory_order_release);
    return push_ok_protected(L);
}

int l_quit(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.quit expects no arguments");
    babet_runtime::require_main_thread(L, "gui.quit");
    if (!g_run_active.load(std::memory_order_acquire))
        return push_fail_protected(L, "babet.gui: GUI event loop is not running");
    if (g_gui_owner != main_lua_state(L))
        return push_fail_protected(L, "babet.gui: this Lua state does not own the GUI");
    g_quit_requested.store(true, std::memory_order_release);
    return push_ok_protected(L);
}

int widget_gc(lua_State *L) noexcept
{
    auto *userdata = static_cast<WidgetUserdata *>(luaL_testudata(L, 1, WIDGET_META));
    if (!userdata || !userdata->state)
        return 0;

    WidgetState *state = userdata->state;
    userdata->state = nullptr;

    if (state->callback_ref != LUA_NOREF && state->callback_ref != LUA_REFNIL &&
        state->owner)
    {
        luaL_unref(state->owner, LUA_REGISTRYINDEX, state->callback_ref);
        state->callback_ref = LUA_NOREF;
    }

    if (state->native)
    {
        if (state->kind == WidgetKind::window)
            detail::gtk4_window_destroy(state->native);
        else if (state->owns_reference)
        {
            state->owns_reference = false;
            detail::gtk4_object_unref(state->native);
        }
    }

    release_state(state);
    return 0;
}

template <int (*Fn)(lua_State *)>
int gui_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "babet.gui: out of memory", "babet.gui: internal C++ failure",
        "babet.gui: unknown internal C++ failure");
}

} // namespace

bool session_active() noexcept
{
    return g_run_active.load(std::memory_order_acquire) ||
           g_live_widgets.load(std::memory_order_acquire) > 0;
}

void cleanup_on_main_thread(lua_State *L) noexcept
{
    if (!L || !babet_runtime::is_main_thread())
        return;

    lua_State *closing_owner = main_lua_state(L);
    if (g_gui_owner == closing_owner)
    {
        g_quit_requested.store(true, std::memory_order_release);
        g_run_active.store(false, std::memory_order_release);
        g_gui_owner = nullptr;
    }

    // Neutralise uniquement les callbacks appartenant à l'état en fermeture.
    // Un autre contexte embedding vivant ne doit jamais être affecté.
    for (WidgetState *state = g_states; state; state = state->next)
    {
        if (state->owner == closing_owner)
            state->owner = nullptr;
    }
}

void register_gui(lua_State *L)
{
    if (luaL_newmetatable(L, WIDGET_META))
    {
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, widget_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, gui_lua_boundary<widget_add>);
        lua_setfield(L, -2, "add");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_text>);
        lua_setfield(L, -2, "setText");
        lua_pushcfunction(L, gui_lua_boundary<button_on_click>);
        lua_setfield(L, -2, "onClick");
        lua_pushcfunction(L, gui_lua_boundary<window_show>);
        lua_setfield(L, -2, "show");
        lua_pushcfunction(L, gui_lua_boundary<window_close>);
        lua_setfield(L, -2, "close");
    }
    lua_pop(L, 1);

    lua_newtable(L);
    lua_pushcfunction(L, gui_lua_boundary<l_available>);
    lua_setfield(L, -2, "available");
    lua_pushcfunction(L, gui_lua_boundary<l_init>);
    lua_setfield(L, -2, "init");
    lua_pushcfunction(L, gui_lua_boundary<l_window>);
    lua_setfield(L, -2, "window");
    lua_pushcfunction(L, gui_lua_boundary<l_box>);
    lua_setfield(L, -2, "box");
    lua_pushcfunction(L, gui_lua_boundary<l_label>);
    lua_setfield(L, -2, "label");
    lua_pushcfunction(L, gui_lua_boundary<l_button>);
    lua_setfield(L, -2, "button");
    lua_pushcfunction(L, gui_lua_boundary<l_run>);
    lua_setfield(L, -2, "run");
    lua_pushcfunction(L, gui_lua_boundary<l_quit>);
    lua_setfield(L, -2, "quit");
    lua_setfield(L, -2, "gui");
}

} // namespace babet_gui
