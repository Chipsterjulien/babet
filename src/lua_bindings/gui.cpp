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
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <vector>
#include <stdexcept>

namespace babet_gui
{
namespace
{

constexpr const char *WIDGET_META = "BabetGuiWidget";
constexpr const char *DRAW_META = "BabetGuiDrawContext";
constexpr unsigned int GUI_WAKE_INTERVAL_MS = 25;
char widget_handles_key;
constexpr lua_Integer PRIMARY_CALLBACK = -1;
constexpr lua_Integer ACTIVATE_CALLBACK = -2;
constexpr lua_Integer CLICK_CALLBACK = -3;
constexpr lua_Integer DRAG_CALLBACK = -4;
constexpr lua_Integer CALENDAR_VIEW_CALLBACK = -5;
constexpr lua_Integer DROP_CALLBACK = -6;
constexpr lua_Integer POINTER_CALLBACK = -7;
constexpr lua_Integer KEY_CALLBACK = -8;
constexpr lua_Integer PANED_POSITION_CALLBACK = -9;
constexpr lua_Integer CLOSE_REQUEST_CALLBACK = -10;
constexpr lua_Integer DRAG_STATE_CALLBACK = -11;

enum class WidgetKind : unsigned char
{
    window,
    box,
    separator,
    label,
    button,
    entry,
    scrolled_window,
    spin_button,
    calendar,
    drawing_area,
    fixed,
    text_view,
    check_button,
    progress_bar,
    expander,
    paned,
    image,
    picture,
    menu_button,
    popover,
};

struct WidgetState
{
    void *native = nullptr;
    lua_State *owner = nullptr; // main Lua thread of the owning Lua state
    WidgetKind kind = WidgetKind::label;
    void *handle_key = nullptr; // weak Lua handle lookup; never dereferenced
    lua_State *callback_thread = nullptr; // synchronous setters use their caller
    bool drag_controller_attached = false;
    bool click_controller_attached = false;
    bool drag_source_controller_attached = false;
    bool drop_target_controller_attached = false;
    bool pointer_controllers_attached = false;
    bool key_controller_attached = false;
    bool paned_position_signal_attached = false;
    bool close_request_signal_attached = false;
    bool drag_state_signals_attached = false;
    void *drag_source_controller = nullptr; // borrowed; owned by GTK widget
    void *active_drag = nullptr; // borrowed between drag-begin and drag-end
    bool local_drop_observed = false;
    unsigned int local_drop_action = 0U; // zero means refused/pending
    void *drop_target_controller = nullptr; // borrowed; owned by GTK widget
    unsigned long long drop_revision = 0; // invalidates an in-flight hover callback
    unsigned int drop_received_depth = 0;
    bool drop_enabled = false;
    unsigned int drop_types = 1U; // text=1, files=2
    std::vector<std::string> text_tags; // creation order; native definitions live in the buffer
    unsigned int drag_actions = 2U; // GDK_ACTION_MOVE
    unsigned int drop_actions = 2U; // GDK_ACTION_MOVE
    unsigned long long drop_hover_window = 0; // last GTK hover status window that called this target
    WidgetState *popover_parent_state = nullptr; // retained while a context popover is attached
    void *content = nullptr; // expander: internal box, always parents user children
    bool drag_origin_valid = false;
    double drag_origin_x = 0.0;
    double drag_origin_y = 0.0;
    double drag_last_dx = 0.0;
    double drag_last_dy = 0.0;
    unsigned int entry_set_text_depth = 0; // coalesce GTK's internal changed bursts
    int references = 1; // Lua userdata; native signal handlers retain as needed
    bool owns_reference = false; // construction ref for non-toplevel widgets
    WidgetState *previous = nullptr;
    WidgetState *next = nullptr;
    WidgetState *deferred_next = nullptr; // finalization after GTK's draw stage
};

struct DrawContext
{
    void *native = nullptr; // borrowed only for the duration of onDraw
    lua_State *owner = nullptr;
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
unsigned int g_draw_depth = 0;
WidgetState *g_deferred_widgets = nullptr;
void *g_css_provider = nullptr;
void *g_css_display = nullptr;
lua_State *g_css_owner = nullptr;
constexpr unsigned int CSS_PRIORITY_APPLICATION = 600U;

void drain_deferred_widgets() noexcept;
bool has_file_dialogs() noexcept;
void cancel_file_dialogs(lua_State *owner = nullptr, WidgetState *parent = nullptr) noexcept;

void clear_css_provider(lua_State *owner = nullptr) noexcept
{
    if (!g_css_provider)
        return;
    if (owner && g_css_owner != owner)
        return;
    if (g_css_display)
        detail::gtk4_style_context_remove_provider_for_display(
            g_css_display, g_css_provider);
    detail::gtk4_object_unref(g_css_provider);
    g_css_provider = nullptr;
    g_css_display = nullptr;
    g_css_owner = nullptr;
}

void require_not_drawing(lua_State *L, const char *api)
{
    if (g_draw_depth != 0)
        luaL_error(L, "%s: widget changes are forbidden during onDraw", api);
}

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

// Hold logical state across protected Lua allocations: a finalizer may
// explicitly finalize another handle, including the current receiver.
class ScopedStateReference
{
public:
    explicit ScopedStateReference(WidgetState *state) noexcept : state_(state) { retain_state(state_); }
    ~ScopedStateReference() { release_state(state_); }
    ScopedStateReference(const ScopedStateReference &) = delete;
    ScopedStateReference &operator=(const ScopedStateReference &) = delete;
private:
    WidgetState *state_;
};

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
    require_not_drawing(L, api);
    if (!g_initialized)
        luaL_error(L, "%s: call babet.gui.init() first", api);
    if (babet_curses::session_active())
        luaL_error(L, "%s: unavailable while a curses session is active", api);

    lua_State *owner = main_lua_state(L);
    if ((g_gui_owner && g_gui_owner != owner) ||
        (g_css_owner && g_css_owner != owner))
        luaL_error(L, "%s: another Lua state currently owns the GUI", api);
}

const char *kind_name(WidgetKind kind) noexcept
{
    switch (kind)
    {
    case WidgetKind::window: return "window";
    case WidgetKind::box: return "box";
    case WidgetKind::separator: return "separator";
    case WidgetKind::label: return "label";
    case WidgetKind::button: return "button";
    case WidgetKind::entry: return "entry";
    case WidgetKind::scrolled_window: return "scrolledWindow";
    case WidgetKind::spin_button: return "spinButton";
    case WidgetKind::calendar: return "calendar";
    case WidgetKind::drawing_area: return "drawingArea";
    case WidgetKind::fixed: return "fixed";
    case WidgetKind::text_view: return "textView";
    case WidgetKind::check_button: return "checkButton";
    case WidgetKind::progress_bar: return "progressBar";
    case WidgetKind::expander: return "expander";
    case WidgetKind::paned: return "paned";
    case WidgetKind::image: return "image";
    case WidgetKind::picture: return "picture";
    case WidgetKind::menu_button: return "menuButton";
    case WidgetKind::popover: return "popover";
    }
    return "widget";
}

WidgetState *check_widget(lua_State *L, int index, const char *api,
                          bool mutation = true)
{
    babet_runtime::require_main_thread(L, api);
    if (mutation)
        require_not_drawing(L, api);
    auto *userdata = static_cast<WidgetUserdata *>(
        luaL_checkudata(L, index, WIDGET_META));
    if (!userdata || !userdata->state || !userdata->state->native)
        luaL_error(L, "%s: widget has already been destroyed", api);
    if (userdata->state->owner != main_lua_state(L))
        luaL_error(L, "%s: widget belongs to another Lua state", api);
    return userdata->state;
}

WidgetState *check_kind(lua_State *L, int index, WidgetKind kind,
                        const char *api, bool mutation = true)
{
    WidgetState *state = check_widget(L, index, api, mutation);
    if (state->kind != kind)
        luaL_error(L, "%s: expected %s %s handle", api,
                   kind == WidgetKind::entry ? "an" : "a", kind_name(kind));
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

    // Invalidate before unparenting context popovers: GTK can re-enter signals
    // while tearing down native children.
    void *destroyed_native = state->native;
    state->native = nullptr;
    cancel_file_dialogs(nullptr, state);

    if (state->popover_parent_state)
    {
        release_state(state->popover_parent_state);
        state->popover_parent_state = nullptr;
    }

    // Context popovers can be attached directly to any widget with
    // gtk_widget_set_parent(). Drop their retained logical parent when that
    // parent is destroyed; the popover keeps its own construction reference
    // and therefore remains a reusable, now-unparented handle.
    for (;;)
    {
        WidgetState *candidate = g_states;
        while (candidate && candidate->popover_parent_state != state)
            candidate = candidate->next;
        if (!candidate) break;
        retain_state(candidate);
        candidate->popover_parent_state = nullptr;
        if (candidate->native &&
            detail::gtk4_widget_get_parent(candidate->native) == destroyed_native)
            detail::gtk4_widget_unparent(candidate->native);
        release_state(state);
        release_state(candidate);
        // Unparenting may destroy other widgets; restart from the live list.
    }

    state->drag_source_controller = nullptr;
    state->drop_target_controller = nullptr;
    state->owns_reference = false;
    g_live_widgets.fetch_sub(1, std::memory_order_acq_rel);
    if (state->kind == WidgetKind::window)
        g_live_windows.fetch_sub(1, std::memory_order_acq_rel);

    if (g_live_widgets.load(std::memory_order_acquire) == 0 && !has_file_dialogs())
        g_gui_owner = nullptr;

    // Relâche la référence logique détenue par le signal native "destroy".
    release_state(state);
}

void button_signal_released(void *data, void *) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (state)
        release_state(state);
}

void dispatch_widget_callback(WidgetState *state, lua_Integer slot) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;

    lua_State *L = state->callback_thread ? state->callback_thread : state->owner;
    const int base = lua_gettop(L);
    if (!lua_checkstack(L, 4))
    {
        static constexpr char message[] =
            "babet.gui callback error: cannot grow Lua stack\n";
        std::fwrite(message, 1, sizeof(message) - 1, stderr);
        return;
    }

    // A callback belongs to its Lua userdata, not to a permanent registry root.
    // Self-capturing callbacks must not keep unparented widgets alive forever.
    // Resolve through weak values, then keep the handle/function on this stack
    // until the protected call finishes (including a close or a GC in it).
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
    {
        lua_settop(L, base);
        return;
    }
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, slot);
    if (lua_type(L, -1) != LUA_TFUNCTION)
    {
        lua_settop(L, base);
        return;
    }
    if (lua_pcall(L, 0, 0, 0) != LUA_OK)
    {
        report_callback_error(L);
        lua_settop(L, base);
        return;
    }
    lua_settop(L, base);
}

void button_clicked(void *, void *data) noexcept
{
    dispatch_widget_callback(static_cast<WidgetState *>(data), PRIMARY_CALLBACK);
}

void entry_changed(void *, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (state && state->entry_set_text_depth != 0)
        return;
    dispatch_widget_callback(state, PRIMARY_CALLBACK);
}

void entry_activated(void *, void *data) noexcept
{
    dispatch_widget_callback(static_cast<WidgetState *>(data), ACTIVATE_CALLBACK);
}

void spin_button_changed(void *, void *data) noexcept
{
    dispatch_widget_callback(static_cast<WidgetState *>(data), PRIMARY_CALLBACK);
}

void calendar_day_selected(void *, void *data) noexcept
{
    dispatch_widget_callback(static_cast<WidgetState *>(data), PRIMARY_CALLBACK);
}

void calendar_view_changed(void *, void *data) noexcept
{
    dispatch_widget_callback(static_cast<WidgetState *>(data), CALENDAR_VIEW_CALLBACK);
}

void check_button_toggled(void *, void *data) noexcept
{
    dispatch_widget_callback(static_cast<WidgetState *>(data), PRIMARY_CALLBACK);
}

void text_buffer_changed(void *, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (state && state->entry_set_text_depth == 0)
        dispatch_widget_callback(state, PRIMARY_CALLBACK);
}

struct DragInvocation
{
    WidgetState *state;
    const char *phase;
    double x;
    double y;
};

// Protect argument construction as well as the user callback. In particular,
// interning the phase string can fail before the user function is entered.
// No Lua error may jump out through GTK's native signal dispatch.
int invoke_drag_callback(lua_State *L)
{
    const auto *call = static_cast<const DragInvocation *>(lua_touserdata(L, 1));
    // Preparing pcall's frame may run GC before this thunk roots the handle.
    // The bridge pins WidgetState; a finalizer may still destroy its widget.
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) == LUA_TUSERDATA)
    {
        lua_getiuservalue(L, -1, 1);
        lua_rawgeti(L, -1, DRAG_CALLBACK);
        if (lua_type(L, -1) == LUA_TFUNCTION)
        {
            lua_pushstring(L, call->phase);
            lua_pushnumber(L, call->x);
            lua_pushnumber(L, call->y);
            lua_call(L, 3, 0);
        }
    }
    return 0;
}

void dispatch_drag(WidgetState *state, const char *phase, double x, double y) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow drag stack\n", stderr);
        release_state(state);
        return;
    }
    DragInvocation call{state, phase, x, y};
    lua_pushcfunction(L, invoke_drag_callback);
    lua_pushlightuserdata(L, &call);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        report_callback_error(L);
    lua_settop(L, base);
    release_state(state);
}

void drag_begin(void *gesture, double x, double y, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (!state || !state->native) return;
    state->drag_origin_valid = detail::gtk4_gesture_surface_position(
        gesture, state->drag_origin_x, state->drag_origin_y);
    state->drag_last_dx = 0.0;
    state->drag_last_dy = 0.0;
    // Preserve the existing contract: begin returns widget-local coordinates.
    dispatch_drag(state, "begin", x, y);
}
void drag_motion(void *gesture, double x, double y, void *data,
                 const char *phase) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (!state || !state->native) return;
    double current_x = 0.0, current_y = 0.0;
    if (state->drag_origin_valid)
    {
        if (detail::gtk4_gesture_surface_position(gesture, current_x, current_y))
        {
            x = current_x - state->drag_origin_x;
            y = current_y - state->drag_origin_y;
            state->drag_last_dx = x;
            state->drag_last_dy = y;
        }
        else
        {
            // Some backends have no last event by drag-end. Preserve the
            // most recent stable displacement, not a widget-local fallback.
            x = state->drag_last_dx;
            y = state->drag_last_dy;
        }
    }
    if (phase[0] == 'e') state->drag_origin_valid = false;
    dispatch_drag(state, phase, x, y);
}
void drag_update(void *gesture, double x, double y, void *data) noexcept
{
    drag_motion(gesture, x, y, data, "update");
}
void drag_end(void *gesture, double x, double y, void *data) noexcept
{
    drag_motion(gesture, x, y, data, "end");
}

bool strict_c_string(lua_State *L, int index, const char *api, const char *&value);
unsigned int drag_action_from_name(lua_State *L, const char *name, const char *api);

const char *drag_action_name(unsigned int action) noexcept
{
    if (action == detail::gtk4_drag_action_copy()) return "copy";
    if (action == detail::gtk4_drag_action_move()) return "move";
    if (action == detail::gtk4_drag_action_link()) return "link";
    return nullptr;
}

// A drop from another process has no GdkDrag from which Babet could read the
// negotiated action. GTK sends one status per hover window: the action of the
// first target that accepts it. Enter windows run from the outermost target
// inward; motion windows from the deepest target outward. Each target is
// called at most once per window, so a repeated target or a phase change
// starts the next window. On X11, a drop right after entering a toplevel
// follows an enter window only.
struct DropNegotiation
{
    void *drop = nullptr;
    unsigned long long window = 0;
    char phase = 0;
    unsigned int action = 0U; // first accepted action of the current window
};
DropNegotiation g_drop_negotiation;

unsigned long long begin_hover_window(WidgetState *state, void *drop, char phase) noexcept
{
    auto &n = g_drop_negotiation;
    if (n.drop != drop || n.phase != phase || state->drop_hover_window == n.window)
    {
        n.drop = drop;
        n.phase = phase;
        ++n.window;
        n.action = 0U;
    }
    state->drop_hover_window = n.window;
    return n.window;
}

void end_hover_window(unsigned long long window, unsigned int action) noexcept
{
    auto &n = g_drop_negotiation;
    if (n.window == window && n.action == 0U) n.action = action;
}

unsigned int negotiated_drop_action(void *target) noexcept
{
    const auto &n = g_drop_negotiation;
    void *drop = detail::gtk4_drop_target_current_drop(target);
    return drop && n.drop == drop ? n.action : 0U;
}

unsigned int preferred_drop_action(WidgetState *state, void *target, bool dropping = false) noexcept
{
    if (!state) return 0U;
    // Only offer Lua an action that the source also allows. Otherwise GTK
    // silently negotiates another action (e.g. COPY) while Lua sees MOVE.
    const unsigned int allowed = state->drop_actions &
                                 detail::gtk4_drop_target_offered_actions(target);
    const unsigned int selected = detail::gtk4_drop_target_selected_action(target);
    if (drag_action_name(selected) && (allowed & selected) != 0U)
        return selected;
    // A drag from another process has no GdkDrag here. GTK has already sent
    // the last hover status to the source: report that action, or refuse the
    // drop when this target does not allow it. Never invent another action.
    if (dropping) {
        const unsigned int negotiated = negotiated_drop_action(target);
        if (negotiated != 0U)
            return drag_action_name(negotiated) && (allowed & negotiated) != 0U ? negotiated : 0U;
    }

    const unsigned int modifiers = detail::gtk4_event_controller_current_state(target);
    constexpr unsigned int SHIFT = 1U;
    constexpr unsigned int CONTROL = 4U;
    if ((modifiers & (SHIFT | CONTROL)) == (SHIFT | CONTROL) &&
        (allowed & detail::gtk4_drag_action_link()) != 0U)
        return detail::gtk4_drag_action_link();
    if ((modifiers & CONTROL) != 0U &&
        (allowed & detail::gtk4_drag_action_copy()) != 0U)
        return detail::gtk4_drag_action_copy();
    if ((modifiers & SHIFT) != 0U &&
        (allowed & detail::gtk4_drag_action_move()) != 0U)
        return detail::gtk4_drag_action_move();
    if ((allowed & detail::gtk4_drag_action_move()) != 0U)
        return detail::gtk4_drag_action_move();
    if ((allowed & detail::gtk4_drag_action_copy()) != 0U)
        return detail::gtk4_drag_action_copy();
    if ((allowed & detail::gtk4_drag_action_link()) != 0U)
        return detail::gtk4_drag_action_link();
    return 0U;
}

struct DropPayload {
    int kind = 0; // 0 unknown, 1 text, 2 files
    bool available = false;
    std::string text;
    std::vector<std::string> files;
};

bool snapshot_drop_payload(const void *value, unsigned int types, DropPayload &out)
{
    if (!value) {
        out.kind = types == 1U ? 1 : (types == 2U ? 2 : 0);
        return true; // preloading has not completed, including mixed types
    }
    const bool file_support = detail::gtk4_drop_files_available();
    if (file_support && detail::rich_value_holds(value, detail::rich_gdk_file_list_get_type())) {
        if (!(types & 2U)) return false;
        void *list = detail::rich_g_value_get_boxed(value);
        if (!list) return false;
        for (auto *item = detail::rich_gdk_file_list_get_files(list); item; item = item->next) {
            const std::unique_ptr<char, decltype(&detail::gtk4_free)> path(
                detail::files_g_file_get_path(item->data), &detail::gtk4_free);
            if (path && path.get()[0] == '/') out.files.emplace_back(path.get());
        }
        if (!out.files.empty()) { out.kind = 2; out.available = true; return true; }
        // A mixed target asks GTK for files first, but a browser link is also
        // offered as a URI list. Without any local path, keep it as text.
        if (!(types & 1U)) return false;
        std::string uris;
        for (auto *item = detail::rich_gdk_file_list_get_files(list); item; item = item->next) {
            const std::unique_ptr<char, decltype(&detail::gtk4_free)> uri(
                detail::files_g_file_get_uri(item->data), &detail::gtk4_free);
            if (!uri) return false;
            if (!uris.empty()) uris += '\n';
            uris += uri.get();
        }
        if (uris.empty()) return false;
        out.kind = 1; out.available = true; out.text = std::move(uris);
        return true;
    }
    if (!(types & 1U)) return false;
    if (file_support && !detail::rich_value_holds(value, detail::rich_type_from_name("gchararray")))
        return false;
    const char *text = detail::gtk4_value_text(value);
    if (!text) return false;
    out.kind = 1; out.available = true; out.text = text;
    return true;
}

struct DropInvocation
{
    WidgetState *state;
    const char *phase;
    const DropPayload *payload;
    double x;
    double y;
    bool has_coords;
    unsigned int preferred_action;
    bool invoked;
    bool accepted;
};

int invoke_drop_callback(lua_State *L)
{
    auto *call = static_cast<DropInvocation *>(lua_touserdata(L, 1));
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, DROP_CALLBACK);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;

    call->invoked = true;
    lua_pushstring(L, call->phase);
    if (!call->payload->available)
        lua_pushnil(L);
    else if (call->payload->kind == 1)
        lua_pushlstring(L, call->payload->text.data(), call->payload->text.size());
    else {
        lua_newtable(L);
        lua_Integer i=1;
        for (const auto &path : call->payload->files) {
            lua_pushlstring(L, path.data(), path.size());
            lua_rawseti(L, -2, i++);
        }
    }
    if (call->has_coords)
    {
        lua_pushnumber(L, call->x);
        lua_pushnumber(L, call->y);
    }
    else
    {
        lua_pushnil(L);
        lua_pushnil(L);
    }
    if (const char *action = drag_action_name(call->preferred_action))
        lua_pushstring(L, action);
    else
        lua_pushnil(L);
    if (call->payload->kind == 1) lua_pushliteral(L, "text");
    else if (call->payload->kind == 2) lua_pushliteral(L, "files");
    else lua_pushnil(L);
    lua_call(L, 6, 1);
    if (lua_isnil(L, -1))
        call->accepted = true;
    else if (lua_is_strict_boolean(L, -1))
        call->accepted = lua_toboolean(L, -1) != 0;
    else if (lua_is_strict_string(L, -1))
    {
        const char *name = nullptr;
        strict_c_string(L, -1, "gui widget:onDrop return value", name);
        const unsigned int action = drag_action_from_name(
            L, name, "gui widget:onDrop return value");
        if ((call->state->drop_actions & action) == 0U)
            return luaL_error(L, "gui widget:onDrop: returned action is not enabled on the drop target");
        // GtkDropTarget::drop returns only acceptance. The action is already
        // negotiated; silently replacing it here would still let GTK request
        // deletion at the source for a MOVE that Lua intended as a COPY.
        if (call->phase[0] == 'd' && action != call->preferred_action)
            return luaL_error(L, "gui widget:onDrop: cannot change the negotiated action during drop; choose it during enter/motion");
        call->preferred_action = action;
        call->accepted = true;
    }
    else
        return luaL_error(L, "gui widget:onDrop must return nil, a boolean, or an action string");
    lua_pop(L, 1);
    return 0;
}

unsigned int dispatch_drop(WidgetState *state, const char *phase, const void *value,
                           double x, double y, bool has_coords,
                           unsigned int preferred_action) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return false;
    // Copy before entering Lua: allocations/finalizers and the callback may
    // destroy or reconfigure the source, target, GValue or GdkFileList.
    DropPayload payload;
    try {
        if (!snapshot_drop_payload(value, state->drop_types, payload)) return 0U;
    } catch (...) {
        std::fputs("babet.gui callback error: cannot copy drop payload\n", stderr);
        return 0U;
    }
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow drop stack\n", stderr);
        release_state(state);
        return false;
    }
    DropInvocation call{state, phase, &payload, x, y, has_coords, preferred_action, false, true};
    const auto revision = state->drop_revision;
    const bool receiving = phase[0] == 'd';
    if (receiving)
        ++state->drop_received_depth;
    lua_pushcfunction(L, invoke_drop_callback);
    lua_pushlightuserdata(L, &call);
    const bool ok = lua_pcall(L, 1, 0, 0) == LUA_OK;
    if (!ok)
        report_callback_error(L);
    lua_settop(L, base);
    if (receiving)
        --state->drop_received_depth;
    // Disabling then re-enabling in the callback must not advertise MOVE for
    // a hover operation that onDrop(nil) has already rejected in GTK.
    const bool accepted = ok && call.invoked && call.accepted &&
                          revision == state->drop_revision;
    const unsigned int action = accepted ? call.preferred_action : 0U;
    release_state(state);
    return action;
}

unsigned int drop_enter(void *target, double x, double y, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    const void *payload = detail::rich_drop_value(target);
    const auto window = begin_hover_window(state, detail::gtk4_drop_target_current_drop(target), 'e');
    const unsigned int action = dispatch_drop(state, "enter", payload, x, y, true,
                                              preferred_drop_action(state, target));
    end_hover_window(window, action);
    return action;
}

unsigned int drop_motion(void *target, double x, double y, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    const void *payload = detail::rich_drop_value(target);
    const auto window = begin_hover_window(state, detail::gtk4_drop_target_current_drop(target), 'm');
    const unsigned int action = dispatch_drop(state, "motion", payload, x, y, true,
                                              preferred_drop_action(state, target));
    end_hover_window(window, action);
    return action;
}

void drop_leave(void *, void *data) noexcept
{
    (void)dispatch_drop(static_cast<WidgetState *>(data), "leave", nullptr,
                        0.0, 0.0, false, 0U);
}

int drop_received(void *target, const void *value, double x, double y, void *data) noexcept
{
    // Some GTK/X11 versions emit successful drag-end even after ::drop
    // returns FALSE. Keep our own local result so a refused Babet transfer
    // cannot instruct another Babet widget to delete the source model.
    void *drag = detail::gtk4_drop_target_drag(target);
    WidgetState *source = nullptr;
    if (drag)
        for (WidgetState *candidate = g_states; candidate; candidate = candidate->next)
            if (candidate->active_drag == drag) { source = candidate; break; }
    if (source)
    {
        retain_state(source);
        source->local_drop_observed = true;
        source->local_drop_action = 0U; // safe even if Lua closes the source
    }
    auto *state = static_cast<WidgetState *>(data);
    const unsigned int action = value ? dispatch_drop(state, "drop", value, x, y, true,
                         preferred_drop_action(state, target, true)) : 0U;
    g_drop_negotiation = DropNegotiation{}; // the next transfer starts a new window
    if (source)
    {
        if (source->active_drag == drag) source->local_drop_action = action;
        release_state(source);
    }
    return action != 0U ? 1 : 0;
}


struct PointerInvocation
{
    WidgetState *state;
    const char *phase;
    double x;
    double y;
    bool has_coords;
    unsigned int button;
    int n_press;
    unsigned int modifiers;
};

int invoke_pointer_callback(lua_State *L)
{
    const auto *call = static_cast<const PointerInvocation *>(lua_touserdata(L, 1));
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, POINTER_CALLBACK);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;
    lua_pushstring(L, call->phase);
    if (call->has_coords)
    {
        lua_pushnumber(L, call->x);
        lua_pushnumber(L, call->y);
    }
    else
    {
        lua_pushnil(L);
        lua_pushnil(L);
    }
    lua_pushinteger(L, static_cast<lua_Integer>(call->button));
    lua_pushinteger(L, static_cast<lua_Integer>(call->n_press));
    lua_pushinteger(L, static_cast<lua_Integer>(call->modifiers));
    lua_call(L, 6, 0);
    return 0;
}

void dispatch_pointer(WidgetState *state, const char *phase, double x, double y,
                      bool has_coords, unsigned int button, int n_press,
                      unsigned int modifiers) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow pointer stack\n", stderr);
        release_state(state);
        return;
    }
    PointerInvocation call{state, phase, x, y, has_coords, button, n_press, modifiers};
    lua_pushcfunction(L, invoke_pointer_callback);
    lua_pushlightuserdata(L, &call);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        report_callback_error(L);
    lua_settop(L, base);
    release_state(state);
}

void pointer_pressed(void *gesture, int n_press, double x, double y, void *data) noexcept
{
    dispatch_pointer(static_cast<WidgetState *>(data), "press", x, y, true,
                     detail::gtk4_gesture_single_get_current_button(gesture), n_press,
                     detail::gtk4_event_controller_current_state(gesture));
}

void pointer_released(void *gesture, int n_press, double x, double y, void *data) noexcept
{
    dispatch_pointer(static_cast<WidgetState *>(data), "release", x, y, true,
                     detail::gtk4_gesture_single_get_current_button(gesture), n_press,
                     detail::gtk4_event_controller_current_state(gesture));
}

void pointer_enter(void *controller, double x, double y, void *data) noexcept
{
    dispatch_pointer(static_cast<WidgetState *>(data), "enter", x, y, true, 0U, 0,
                     detail::gtk4_event_controller_current_state(controller));
}

void pointer_motion(void *controller, double x, double y, void *data) noexcept
{
    dispatch_pointer(static_cast<WidgetState *>(data), "motion", x, y, true, 0U, 0,
                     detail::gtk4_event_controller_current_state(controller));
}

void pointer_leave(void *controller, void *data) noexcept
{
    dispatch_pointer(static_cast<WidgetState *>(data), "leave", 0.0, 0.0, false, 0U, 0,
                     detail::gtk4_event_controller_current_state(controller));
}

struct KeyInvocation
{
    WidgetState *state;
    const char *phase;
    unsigned int keyval;
    unsigned int keycode;
    unsigned int modifiers;
    bool consumed;
};

int invoke_key_callback(lua_State *L)
{
    auto *call = static_cast<KeyInvocation *>(lua_touserdata(L, 1));
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, KEY_CALLBACK);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;
    lua_pushstring(L, call->phase);
    const char *name = detail::gdk4_keyval_name(call->keyval);
    if (name) lua_pushstring(L, name); else lua_pushnil(L);
    lua_pushinteger(L, static_cast<lua_Integer>(call->keyval));
    lua_pushinteger(L, static_cast<lua_Integer>(call->keycode));
    lua_pushinteger(L, static_cast<lua_Integer>(call->modifiers));
    lua_call(L, 5, 1);
    call->consumed = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    return 0;
}

bool dispatch_key(WidgetState *state, const char *phase, unsigned int keyval,
                  unsigned int keycode, unsigned int modifiers) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return false;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow key stack\n", stderr);
        release_state(state);
        return false;
    }
    KeyInvocation call{state, phase, keyval, keycode, modifiers, false};
    lua_pushcfunction(L, invoke_key_callback);
    lua_pushlightuserdata(L, &call);
    const bool ok = lua_pcall(L, 1, 0, 0) == LUA_OK;
    if (!ok) report_callback_error(L);
    lua_settop(L, base);
    release_state(state);
    return ok && call.consumed;
}

int key_pressed(void *, unsigned int keyval, unsigned int keycode,
                unsigned int modifiers, void *data) noexcept
{
    return dispatch_key(static_cast<WidgetState *>(data), "press", keyval, keycode,
                        modifiers) ? 1 : 0;
}

void key_released(void *, unsigned int keyval, unsigned int keycode,
                  unsigned int modifiers, void *data) noexcept
{
    (void)dispatch_key(static_cast<WidgetState *>(data), "release", keyval, keycode,
                       modifiers);
}

struct IntegerInvocation
{
    WidgetState *state;
    lua_Integer slot;
    lua_Integer value;
};

int invoke_integer_callback(lua_State *L)
{
    const auto *call = static_cast<const IntegerInvocation *>(lua_touserdata(L, 1));
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, call->slot);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;
    lua_pushinteger(L, call->value);
    lua_call(L, 1, 0);
    return 0;
}

void dispatch_integer_callback(WidgetState *state, lua_Integer slot,
                               lua_Integer value) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow callback stack\n", stderr);
        release_state(state);
        return;
    }
    IntegerInvocation call{state, slot, value};
    lua_pushcfunction(L, invoke_integer_callback);
    lua_pushlightuserdata(L, &call);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        report_callback_error(L);
    lua_settop(L, base);
    release_state(state);
}

void paned_position_changed(void *, void *, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (state && state->native)
        dispatch_integer_callback(state, PANED_POSITION_CALLBACK,
            static_cast<lua_Integer>(detail::gtk4_paned_get_position(state->native)));
}

struct BooleanInvocation
{
    WidgetState *state;
    lua_Integer slot;
    bool value;
};

int invoke_boolean_callback(lua_State *L)
{
    auto *call = static_cast<BooleanInvocation *>(lua_touserdata(L, 1));
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, call->slot);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;
    lua_call(L, 0, 1);
    call->value = lua_toboolean(L, -1) != 0;
    lua_pop(L, 1);
    return 0;
}

bool dispatch_boolean_callback(WidgetState *state, lua_Integer slot) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return false;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow callback stack\n", stderr);
        release_state(state);
        return false;
    }
    BooleanInvocation call{state, slot, false};
    lua_pushcfunction(L, invoke_boolean_callback);
    lua_pushlightuserdata(L, &call);
    const bool ok = lua_pcall(L, 1, 0, 0) == LUA_OK;
    if (!ok) report_callback_error(L);
    lua_settop(L, base);
    release_state(state);
    return ok && call.value;
}

int window_close_requested(void *, void *data) noexcept
{
    return dispatch_boolean_callback(static_cast<WidgetState *>(data),
                                     CLOSE_REQUEST_CALLBACK) ? 1 : 0;
}

struct DragStateInvocation
{
    WidgetState *state;
    const char *phase;
    bool delete_data;
    int reason;
    unsigned int action;
};

int invoke_drag_state_callback(lua_State *L)
{
    const auto *call = static_cast<const DragStateInvocation *>(lua_touserdata(L, 1));
    if (!call->state->native || !call->state->owner || !call->state->handle_key)
        return 0;
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, call->state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    if (std::strcmp(call->phase, "begin") == 0)
    {
        // Mapping can change after setDragIcon/setDragData (often called
        // before show()). Resolve the Lua-owned preview inside this protected
        // invocation, even when the application has no onDragState callback.
        lua_pushliteral(L, "__drag_icon");
        lua_rawget(L, -2);
        auto *icon = static_cast<WidgetUserdata *>(luaL_testudata(L, -1, WIDGET_META));
        if (icon && call->state->native && call->state->drag_source_controller)
        {
            void *native_icon = icon->state ? icon->state->native : nullptr;
            if (!detail::gtk4_widget_get_mapped(native_icon))
                native_icon = call->state->native;
            if (!detail::gtk4_drag_source_set_widget_icon(
                    call->state->drag_source_controller, native_icon))
                return luaL_error(L, "babet.gui: cannot update GTK drag icon");
        }
        lua_pop(L, 1);
    }
    lua_rawgeti(L, -1, DRAG_STATE_CALLBACK);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;
    lua_pushstring(L, call->phase);
    if (std::strcmp(call->phase, "end") == 0)
        lua_pushboolean(L, call->delete_data);
    else if (std::strcmp(call->phase, "cancel") == 0)
        lua_pushinteger(L, call->reason);
    else
        lua_pushnil(L);
    if (const char *action = drag_action_name(call->action))
        lua_pushstring(L, action);
    else
        lua_pushnil(L);
    lua_call(L, 3, 0);
    return 0;
}

void dispatch_drag_state(WidgetState *state, const char *phase,
                         bool delete_data, int reason, unsigned int action) noexcept
{
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    retain_state(state);
    if (!lua_checkstack(L, 2))
    {
        std::fputs("babet.gui callback error: cannot grow drag-state stack\n", stderr);
        release_state(state);
        return;
    }
    DragStateInvocation call{state, phase, delete_data, reason, action};
    lua_pushcfunction(L, invoke_drag_state_callback);
    lua_pushlightuserdata(L, &call);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK)
        report_callback_error(L);
    lua_settop(L, base);
    release_state(state);
}

void drag_source_begin(void *, void *drag, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    state->active_drag = drag;
    state->local_drop_observed = false;
    state->local_drop_action = 0U;
    dispatch_drag_state(state, "begin", false, 0,
                        detail::gdk4_drag_selected_action(drag));
}

void drag_source_end(void *, void *drag, int delete_data, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    const bool may_delete = delete_data != 0 &&
        (state->active_drag != drag || !state->local_drop_observed ||
         state->local_drop_action == detail::gtk4_drag_action_move());
    state->active_drag = nullptr;
    state->local_drop_observed = false;
    state->local_drop_action = 0U;
    dispatch_drag_state(state, "end", may_delete, 0,
                        detail::gdk4_drag_selected_action(drag));
}

int drag_source_cancel(void *, void *drag, int reason, void *data) noexcept
{
    dispatch_drag_state(static_cast<WidgetState *>(data), "cancel", false, reason,
                        detail::gdk4_drag_selected_action(drag));
    return 0;
}

void widget_pressed(void *gesture, int n_press, double x, double y,
                          void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;

    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    if (!lua_checkstack(L, 8))
    {
        static constexpr char message[] =
            "babet.gui callback error: cannot grow click callback stack\n";
        std::fwrite(message, 1, sizeof(message) - 1, stderr);
        return;
    }

    // Resolve the callback through the weak userdata handle, exactly like the
    // other widget callbacks. Keeping the userdata and function rooted on the
    // stack also makes self-removal/window destruction safe until pcall returns.
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
    {
        lua_settop(L, base);
        return;
    }
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, CLICK_CALLBACK);
    if (lua_type(L, -1) != LUA_TFUNCTION)
    {
        lua_settop(L, base);
        return;
    }

    const unsigned int button =
        detail::gtk4_gesture_single_get_current_button(gesture);
    lua_pushnumber(L, x);
    lua_pushnumber(L, y);
    lua_pushinteger(L, static_cast<lua_Integer>(button));
    lua_pushinteger(L, static_cast<lua_Integer>(n_press));
    if (lua_pcall(L, 4, 0, 0) != LUA_OK)
        report_callback_error(L);
    lua_settop(L, base);
}

// All allocating Lua work for the native draw callback is protected, including
// argument construction. Return a root for both widget and context to the
// native bridge; the context stays inactive until this preparation succeeds.
int prepare_draw_callback(lua_State *L)
{
    auto *state = static_cast<WidgetState *>(lua_touserdata(L, 1));
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_rawgetp(L, -1, state->handle_key);
    if (lua_type(L, -1) != LUA_TUSERDATA)
        return 0;
    lua_getiuservalue(L, -1, 1);
    lua_rawgeti(L, -1, PRIMARY_CALLBACK);
    if (lua_type(L, -1) != LUA_TFUNCTION)
        return 0;
    lua_remove(L, -2); // handle, function
    auto *context = static_cast<DrawContext *>(lua_newuserdatauv(L, sizeof(DrawContext), 0));
    context->native = nullptr;
    context->owner = nullptr;
    luaL_getmetatable(L, DRAW_META);
    lua_setmetatable(L, -2);
    return 3;
}

void drawing_area_draw(void *, void *cr, int width, int height, void *data) noexcept
{
    auto *state = static_cast<WidgetState *>(data);
    if (!state || !state->native || !state->owner || !state->handle_key)
        return;
    lua_State *L = state->owner;
    const int base = lua_gettop(L);
    if (!lua_checkstack(L, 9))
    {
        std::fputs("babet.gui callback error: cannot grow drawing stack\n", stderr);
        return;
    }
    ++g_draw_depth;
    lua_pushcfunction(L, prepare_draw_callback);
    lua_pushlightuserdata(L, state);
    if (lua_pcall(L, 1, 3, 0) != LUA_OK)
        report_callback_error(L);
    else if (lua_type(L, base + 2) == LUA_TFUNCTION)
    {
        auto *context = static_cast<DrawContext *>(lua_touserdata(L, base + 3));
        context->native = cr;
        context->owner = L;
        detail::cairo_save(cr);
        detail::cairo_new_path(cr);
        lua_pushvalue(L, base + 2);
        lua_pushvalue(L, base + 3);
        lua_pushinteger(L, width);
        lua_pushinteger(L, height);
        if (lua_pcall(L, 3, 0, 0) != LUA_OK)
            report_callback_error(L);
        // The original userdata is still rooted below pcall's arguments,
        // including on error/yield/OOM. Never leave a saved context usable.
        context->native = nullptr;
        context->owner = nullptr;
        detail::cairo_new_path(cr);
        detail::cairo_restore(cr);
        const int cairo_error = detail::cairo_status(cr);
        if (cairo_error != 0)
            std::fprintf(stderr, "babet.gui callback error: Cairo error: %s\n",
                         detail::cairo_status_to_string(cairo_error));
    }
    lua_settop(L, base);
    --g_draw_depth;
    // GTK is still rendering here. Finalizers are drained only after returning
    // from main_context_iteration (or at the next outer GUI API boundary).
}

void drawing_area_released(void *data) noexcept
{
    release_state(static_cast<WidgetState *>(data));
}

bool attach_destroy_signal(WidgetState *state) noexcept
{
    retain_state(state);
    const unsigned long id = detail::gtk4_signal_connect(
        state->native, "destroy", gtk_callback(&widget_destroyed), state, nullptr);
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

    // All Lua allocations for the weak lookup happen before acquiring GTK.
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    lua_pushvalue(L, -2);
    lua_rawsetp(L, -2, userdata);
    lua_pop(L, 1);
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

    WidgetState *state = new (std::nothrow) WidgetState();
    if (!state)
    {
        if (kind == WidgetKind::window)
            detail::gtk4_window_destroy(native);
        else
            detail::gtk4_object_unref(detail::gtk4_object_ref_sink(native));
        return push_fail_protected(L, "babet.gui: out of memory");
    }
    state->native = native;
    state->handle_key = userdata;
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
        if (g_live_widgets.load(std::memory_order_acquire) == 0 && !has_file_dialogs())
            g_gui_owner = nullptr;
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

void acquire_construction_reference(WidgetState *state) noexcept
{
    if (state && state->native && !state->owns_reference)
    {
        (void)detail::gtk4_object_ref_sink(state->native);
        state->owns_reference = true;
    }
}

lua_Integer find_child_handle(lua_State *L, int parent_index, int child_index)
{
    parent_index = lua_absindex(L, parent_index);
    child_index = lua_absindex(L, child_index);
    lua_getiuservalue(L, parent_index, 1);
    const lua_Unsigned count = lua_rawlen(L, -1);
    for (lua_Unsigned i = 1; i <= count; ++i)
    {
        lua_rawgeti(L, -1, static_cast<lua_Integer>(i));
        const bool same = lua_rawequal(L, -1, child_index) != 0;
        lua_pop(L, 1);
        if (same)
        {
            lua_pop(L, 1);
            return static_cast<lua_Integer>(i);
        }
    }
    lua_pop(L, 1);
    return 0;
}

void erase_child_handle(lua_State *L, int parent_index, lua_Integer index) noexcept
{
    parent_index = lua_absindex(L, parent_index);
    lua_getiuservalue(L, parent_index, 1);
    const lua_Integer count = static_cast<lua_Integer>(lua_rawlen(L, -1));
    for (lua_Integer i = index; i < count; ++i)
    {
        lua_rawgeti(L, -1, i + 1);
        lua_rawseti(L, -2, i);
    }
    lua_pushnil(L);
    lua_rawseti(L, -2, count);
    lua_pop(L, 1);
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

#include "gui_picture.inc"
#include "gui_file_dialog.inc"

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



int parse_orientation_name(lua_State *L, int index, const char *api)
{
    const char *text = nullptr;
    strict_c_string(L, index, api, text);
    if (std::strcmp(text, "horizontal") == 0) return 0;
    if (std::strcmp(text, "vertical") == 0) return 1;
    luaL_error(L, "%s must be 'horizontal' or 'vertical'", api);
    return 0;
}

int parse_wrap_mode(lua_State *L, int index, const char *api)
{
    const char *text = nullptr;
    strict_c_string(L, index, api, text);
    if (std::strcmp(text, "none") == 0) return 0;
    if (std::strcmp(text, "char") == 0) return 1;
    if (std::strcmp(text, "word") == 0) return 2;
    if (std::strcmp(text, "word-char") == 0) return 3;
    luaL_error(L, "%s must be 'none', 'char', 'word' or 'word-char'", api);
    return 0;
}

int parse_label_wrap_mode(lua_State *L, int index, const char *api)
{
    // GtkLabel uses PangoWrapMode, not GtkWrapMode.  Keep this conversion
    // separate: the enum values differ (WORD=0, CHAR=1, WORD_CHAR=2).
    const char *text = nullptr;
    strict_c_string(L, index, api, text);
    if (std::strcmp(text, "word") == 0) return 0;
    if (std::strcmp(text, "char") == 0) return 1;
    if (std::strcmp(text, "word-char") == 0) return 2;
    luaL_error(L, "%s must be 'word', 'char' or 'word-char'", api);
    return 0;
}

int parse_align(lua_State *L, int index, const char *api)
{
    const char *text = nullptr;
    strict_c_string(L, index, api, text);
    if (std::strcmp(text, "fill") == 0) return 0;
    if (std::strcmp(text, "start") == 0) return 1;
    if (std::strcmp(text, "end") == 0) return 2;
    if (std::strcmp(text, "center") == 0) return 3;
    if (std::strcmp(text, "baseline") == 0) return 4;
    luaL_error(L, "%s must be 'fill', 'start', 'end', 'center' or 'baseline'", api);
    return 0;
}

int parse_popover_position(lua_State *L, int index, const char *api)
{
    const char *text = nullptr;
    strict_c_string(L, index, api, text);
    if (std::strcmp(text, "left") == 0) return 0;
    if (std::strcmp(text, "right") == 0) return 1;
    if (std::strcmp(text, "top") == 0) return 2;
    if (std::strcmp(text, "bottom") == 0) return 3;
    luaL_error(L, "%s must be 'left', 'right', 'top' or 'bottom'", api);
    return 3;
}

unsigned int drag_action_from_name(lua_State *L, const char *name, const char *api)
{
    if (std::strcmp(name, "copy") == 0) return detail::gtk4_drag_action_copy();
    if (std::strcmp(name, "move") == 0) return detail::gtk4_drag_action_move();
    if (std::strcmp(name, "link") == 0) return detail::gtk4_drag_action_link();
    luaL_error(L, "%s: action must be 'copy', 'move' or 'link'", api);
    return 0U;
}

unsigned int parse_drag_actions(lua_State *L, int index, const char *api)
{
    index = lua_absindex(L, index);
    unsigned int actions = 0U;
    if (lua_is_strict_string(L, index))
    {
        const char *name = nullptr;
        strict_c_string(L, index, api, name);
        actions = drag_action_from_name(L, name, api);
    }
    else if (lua_type(L, index) == LUA_TTABLE)
    {
        const lua_Unsigned count = lua_rawlen(L, index);
        if (count == 0)
            luaL_error(L, "%s: actions table cannot be empty", api);
        for (lua_Unsigned i = 1; i <= count; ++i)
        {
            lua_rawgeti(L, index, static_cast<lua_Integer>(i));
            const char *name = nullptr;
            strict_c_string(L, -1, api, name);
            actions |= drag_action_from_name(L, name, api);
            lua_pop(L, 1);
        }
    }
    else
        luaL_error(L, "%s expects an action string or an array of actions", api);
    if (actions == 0U)
        luaL_error(L, "%s: at least one action is required", api);
    return actions;
}

void parse_paned_options(lua_State *L, int &orientation, int &position,
                         bool &resize_start, bool &resize_end,
                         bool &shrink_start, bool &shrink_end, bool &wide_handle)
{
    orientation = 0;
    position = -1;
    resize_start = false;
    resize_end = true;
    shrink_start = true;
    shrink_end = true;
    wide_handle = false;
    if (lua_gettop(L) == 0 || lua_isnil(L, 1)) return;
    if (lua_type(L, 1) != LUA_TTABLE)
        luaL_error(L, "gui.paned expects an optional options table");

    lua_pushliteral(L, "orientation"); lua_rawget(L, 1);
    if (!lua_isnil(L, -1)) orientation = parse_orientation_name(L, -1, "gui.paned orientation");
    lua_pop(L, 1);

    lua_pushliteral(L, "position"); lua_rawget(L, 1);
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1)) luaL_error(L, "gui.paned position must be an integer");
        const lua_Integer value = lua_tointeger(L, -1);
        if (value < 0 || value > INT_MAX) luaL_error(L, "gui.paned position is out of range");
        position = static_cast<int>(value);
    }
    lua_pop(L, 1);

    struct BoolOption { const char *name; bool *value; } options[] = {
        {"resizeStart", &resize_start}, {"resizeEnd", &resize_end},
        {"shrinkStart", &shrink_start}, {"shrinkEnd", &shrink_end},
        {"wideHandle", &wide_handle},
    };
    for (auto &option : options)
    {
        lua_pushstring(L, option.name); lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
                luaL_error(L, "gui.paned %s must be a boolean", option.name);
            *option.value = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);
    }
}

double finite_number(lua_State *L, int index, const char *api)
{
    if (!lua_is_strict_number(L, index))
        luaL_error(L, "%s: expected a finite number", api);
    const double value = static_cast<double>(lua_tonumber(L, index));
    if (!std::isfinite(value))
        luaL_error(L, "%s: expected a finite number", api);
    return value;
}

bool valid_gregorian_date(int year, int month, int day) noexcept
{
    if (year < 1 || year > 9999 || month < 1 || month > 12 || day < 1)
        return false;
    static constexpr int days[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    int maximum = days[month - 1];
    if (month == 2 && ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0))
        maximum = 29;
    return day <= maximum;
}

void parse_spin_button_options(lua_State *L, double &minimum, double &maximum,
                               double &step, double &value, unsigned int &digits)
{
    minimum = 0.0;
    maximum = 100.0;
    step = 1.0;
    value = 0.0;
    digits = 0;
    if (lua_gettop(L) == 0 || lua_isnil(L, 1))
        return;
    if (lua_type(L, 1) != LUA_TTABLE)
        luaL_error(L, "gui.spinButton expects an optional options table");

    auto read_number = [L](const char *name, double &target)
    {
        lua_pushstring(L, name);
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            char api[64];
            std::snprintf(api, sizeof(api), "gui.spinButton %s", name);
            target = finite_number(L, -1, api);
        }
        lua_pop(L, 1);
    };
    read_number("min", minimum);
    read_number("max", maximum);
    read_number("step", step);
    // gtk_spin_button_new_with_range() starts at the lower bound. Preserve
    // that useful GTK default when a custom range is supplied without an
    // explicit value, while the no-options case still starts at 0.
    value = minimum;
    read_number("value", value);

    lua_pushliteral(L, "digits");
    lua_rawget(L, 1);
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1))
            luaL_error(L, "gui.spinButton digits must be an integer");
        const lua_Integer candidate = lua_tointeger(L, -1);
        if (candidate < 0 || candidate > 20)
            luaL_error(L, "gui.spinButton digits is out of range");
        digits = static_cast<unsigned int>(candidate);
    }
    lua_pop(L, 1);

    if (minimum > maximum)
        luaL_error(L, "gui.spinButton min must be less than or equal to max");
    if (!(step > 0.0))
        luaL_error(L, "gui.spinButton step must be positive");
    if (value < minimum || value > maximum)
        luaL_error(L, "gui.spinButton value must be within min and max");
}

bool parse_calendar_options(lua_State *L, int &year, int &month, int &day)
{
    year = month = day = 0;
    if (lua_gettop(L) == 0 || lua_isnil(L, 1))
        return false;
    if (lua_type(L, 1) != LUA_TTABLE)
        luaL_error(L, "gui.calendar expects an optional options table");

    bool present[3] = {false, false, false};
    int *values[] = {&year, &month, &day};
    const char *names[] = {"year", "month", "day"};
    for (unsigned int i = 0; i < 3; ++i)
    {
        lua_pushstring(L, names[i]);
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_integer(L, -1))
                luaL_error(L, "gui.calendar %s must be an integer", names[i]);
            const lua_Integer candidate = lua_tointeger(L, -1);
            if (candidate < INT_MIN || candidate > INT_MAX)
                luaL_error(L, "gui.calendar %s is out of range", names[i]);
            *values[i] = static_cast<int>(candidate);
            present[i] = true;
        }
        lua_pop(L, 1);
    }
    if (present[0] != present[1] || present[0] != present[2])
        luaL_error(L, "gui.calendar year, month and day must be provided together");
    if (!present[0])
        return false;
    if (!valid_gregorian_date(year, month, day))
        luaL_error(L, "gui.calendar: invalid Gregorian date");
    return true;
}

int l_available(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.available expects no arguments");
    babet_runtime::require_main_thread(L, "gui.available");
    require_not_drawing(L, "gui.available");
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
    require_not_drawing(L, "gui.init");
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


int l_separator(lua_State *L)
{
    if (!lua_arity_is(L, 0) && !lua_arity_is(L, 1))
        return luaL_error(L, "gui.separator expects an optional orientation string");
    require_gui_initialized(L, "gui.separator");
    int orientation = 0; // horizontal separator by default
    if (lua_arity_is(L, 1))
        orientation = parse_orientation_name(L, 1, "gui.separator");
    push_empty_widget_userdata(L);
    return push_native_widget(L, WidgetKind::separator,
                              detail::gtk4_separator_new(orientation), true);
}

int l_paned(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1))
        return luaL_error(L, "gui.paned expects an optional options table");
    require_gui_initialized(L, "gui.paned");
    int orientation = 0, position = -1;
    bool resize_start = false, resize_end = true;
    bool shrink_start = true, shrink_end = true, wide_handle = false;
    parse_paned_options(L, orientation, position, resize_start, resize_end,
                        shrink_start, shrink_end, wide_handle);

    push_empty_widget_userdata(L);
    void *paned = detail::gtk4_paned_new(orientation);
    const int result = push_native_widget(L, WidgetKind::paned, paned, true);
    if (result != 1) return result;
    detail::gtk4_paned_set_resize_start(paned, resize_start);
    detail::gtk4_paned_set_resize_end(paned, resize_end);
    detail::gtk4_paned_set_shrink_start(paned, shrink_start);
    detail::gtk4_paned_set_shrink_end(paned, shrink_end);
    detail::gtk4_paned_set_wide_handle(paned, wide_handle);
    if (position >= 0) detail::gtk4_paned_set_position(paned, position);
    return 1;
}

int l_image(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui.image expects one icon name string");
    require_gui_initialized(L, "gui.image");
    const char *name = nullptr;
    strict_c_string(L, 1, "gui.image", name);
    if (!name[0]) return luaL_error(L, "gui.image: icon name cannot be empty");
    push_empty_widget_userdata(L);
    return push_native_widget(L, WidgetKind::image,
                              detail::gtk4_image_new_from_icon_name(name), true);
}

int l_menu_button(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.menuButton expects an optional options table");
    require_gui_initialized(L, "gui.menuButton");
    const char *label = nullptr;
    const char *icon = nullptr;
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        lua_pushliteral(L, "label"); lua_rawget(L, 1);
        if (!lua_isnil(L, -1)) strict_c_string(L, -1, "gui.menuButton label", label);
        lua_pushliteral(L, "icon"); lua_rawget(L, 1);
        if (!lua_isnil(L, -1)) strict_c_string(L, -1, "gui.menuButton icon", icon);
        if (label && icon)
            return luaL_error(L, "gui.menuButton: choose label or icon, not both");
    }
    push_empty_widget_userdata(L);
    void *button = detail::gtk4_menu_button_new();
    const int result = push_native_widget(L, WidgetKind::menu_button, button, true);
    if (result != 1) return result;
    if (label) detail::gtk4_menu_button_set_label(button, label);
    if (icon) detail::gtk4_menu_button_set_icon_name(button, icon);
    return 1;
}

int l_popover(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.popover expects an optional options table");
    require_gui_initialized(L, "gui.popover");
    bool has_arrow = true;
    bool autohide = true;
    int position = 3;
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        lua_pushliteral(L, "hasArrow"); lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1)) return luaL_error(L, "gui.popover hasArrow must be a boolean");
            has_arrow = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);
        lua_pushliteral(L, "autohide"); lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1)) return luaL_error(L, "gui.popover autohide must be a boolean");
            autohide = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);
        lua_pushliteral(L, "position"); lua_rawget(L, 1);
        if (!lua_isnil(L, -1)) position = parse_popover_position(L, -1, "gui.popover position");
    }
    push_empty_widget_userdata(L);
    void *popover = detail::gtk4_popover_new();
    const int result = push_native_widget(L, WidgetKind::popover, popover, true);
    if (result != 1) return result;
    detail::gtk4_popover_set_has_arrow(popover, has_arrow);
    detail::gtk4_popover_set_autohide(popover, autohide);
    detail::gtk4_popover_set_position(popover, position);
    return 1;
}


// A GtkFixed acts as a canvas of real GTK widgets, not a Cairo bitmap.
int l_fixed(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.fixed expects no arguments");
    require_gui_initialized(L, "gui.fixed");
    push_empty_widget_userdata(L);
    return push_native_widget(L, WidgetKind::fixed, detail::gtk4_fixed_new(), true);
}

int l_text_view(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.textView expects an optional options table");
    require_gui_initialized(L, "gui.textView");
    const char *text = "";
    bool editable = true;
    int wrap_mode = 0;
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        lua_pushliteral(L, "text");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1)) strict_c_string(L, -1, "gui.textView text", text);
        lua_pushliteral(L, "editable");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
                return luaL_error(L, "gui.textView editable must be a boolean");
            editable = lua_toboolean(L, -1) != 0;
        }
        lua_pop(L, 1);
        lua_pushliteral(L, "wrap");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
            wrap_mode = parse_wrap_mode(L, -1, "gui.textView wrap");
    }
    push_empty_widget_userdata(L);
    void *view = detail::gtk4_text_view_new();
    const int result = push_native_widget(L, WidgetKind::text_view, view, true);
    if (result != 1) return result;
    detail::gtk4_text_view_set_editable(view, editable);
    detail::gtk4_text_view_set_wrap_mode(view, wrap_mode);
    void *buffer = detail::gtk4_text_view_get_buffer(view);
    detail::gtk4_text_buffer_set_text(buffer, text);
    auto *state = static_cast<WidgetUserdata *>(lua_touserdata(L, -1))->state;
    retain_state(state);
    if (detail::gtk4_signal_connect(buffer, "changed", gtk_callback(&text_buffer_changed),
                                    state, &button_signal_released) == 0)
    {
        release_state(state);
        release_construction_reference(state);
        return push_fail_protected(L, "babet.gui: cannot attach textView changed signal");
    }
    return 1;
}

int l_check_button(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.checkButton expects an optional options table");
    require_gui_initialized(L, "gui.checkButton");
    const char *label = "";
    bool active = false;
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        lua_pushliteral(L, "label");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1)) strict_c_string(L, -1, "gui.checkButton label", label);
        lua_pushliteral(L, "active");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
                return luaL_error(L, "gui.checkButton active must be a boolean");
            active = lua_toboolean(L, -1) != 0;
        }
    }
    push_empty_widget_userdata(L);
    void *check = detail::gtk4_check_button_new_with_label(label);
    const int result = push_native_widget(L, WidgetKind::check_button, check, true);
    if (result != 1) return result;
    detail::gtk4_check_button_set_active(check, active);
    auto *state = static_cast<WidgetUserdata *>(lua_touserdata(L, -1))->state;
    retain_state(state);
    if (detail::gtk4_signal_connect(check, "toggled", gtk_callback(&check_button_toggled),
                                    state, &button_signal_released) == 0)
    {
        release_state(state);
        release_construction_reference(state);
        return push_fail_protected(L, "babet.gui: cannot attach checkButton toggled signal");
    }
    return 1;
}

int l_progress_bar(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.progressBar expects no arguments");
    require_gui_initialized(L, "gui.progressBar");
    push_empty_widget_userdata(L);
    return push_native_widget(L, WidgetKind::progress_bar, detail::gtk4_progress_bar_new(), true);
}

int l_expander(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.expander expects an optional options table");
    require_gui_initialized(L, "gui.expander");
    const char *label = "";
    bool expanded = false;
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        lua_pushliteral(L, "label");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1)) strict_c_string(L, -1, "gui.expander label", label);
        lua_pushliteral(L, "expanded");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
                return luaL_error(L, "gui.expander expanded must be a boolean");
            expanded = lua_toboolean(L, -1) != 0;
        }
    }
    push_empty_widget_userdata(L);
    void *expander = detail::gtk4_expander_new(label);
    const int result = push_native_widget(L, WidgetKind::expander, expander, true);
    if (result != 1) return result;
    detail::gtk4_expander_set_expanded(expander, expanded);
    // GtkExpander leaves its child unparented while collapsed. Keep a private
    // vertical box as that permanent child: user widgets always have a real GTK
    // parent, so the "already has a GTK parent" check stays reliable. The
    // expander owns the box; add/remove/clear only touch the box's children.
    void *content = detail::gtk4_box_new(1, 0);
    detail::gtk4_expander_set_child(expander, content);
    static_cast<WidgetUserdata *>(lua_touserdata(L, -1))->state->content = content;
    return 1;
}

int l_scrolled_window(lua_State *L)
{
    if (!lua_arity_is(L, 0))
        return luaL_error(L, "gui.scrolledWindow expects no arguments");
    require_gui_initialized(L, "gui.scrolledWindow");

    push_empty_widget_userdata(L);
    void *scrolled = detail::gtk4_scrolled_window_new();
    return push_native_widget(L, WidgetKind::scrolled_window, scrolled, true);
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
    retain_state(userdata->state);
    const unsigned long id = detail::gtk4_signal_connect(
        button, "clicked", gtk_callback(&button_clicked), userdata->state,
        &button_signal_released);
    if (id == 0)
    {
        release_state(userdata->state);
        return push_fail_protected(L, "babet.gui: cannot attach button click signal");
    }
    return 1;
}

int l_entry(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.entry expects an optional options table");
    require_gui_initialized(L, "gui.entry");
    const char *text = "";
    const char *placeholder = "";
    bool editable = true;
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        // Keep option strings on the stack until GTK has copied them, even
        // when a finalizer mutates the caller's options table.
        lua_pushliteral(L, "text");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
            strict_c_string(L, -1, "gui.entry text", text);
        lua_pushliteral(L, "placeholder");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
            strict_c_string(L, -1, "gui.entry placeholder", placeholder);
        lua_pushliteral(L, "editable");
        lua_rawget(L, 1);
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_boolean(L, -1))
                return luaL_error(L, "gui.entry editable must be a boolean");
            editable = lua_toboolean(L, -1) != 0;
        }
    }

    push_empty_widget_userdata(L);
    void *entry = detail::gtk4_entry_new();
    const int result = push_native_widget(L, WidgetKind::entry, entry, true);
    if (result != 1)
        return result;
    detail::gtk4_editable_set_text(entry, text);
    detail::gtk4_entry_set_placeholder(entry, placeholder);
    detail::gtk4_editable_set_editable(entry, editable);

    auto *userdata = static_cast<WidgetUserdata *>(lua_touserdata(L, -1));
    const detail::GtkCallback callbacks[] = {
        gtk_callback(&entry_changed), gtk_callback(&entry_activated)};
    const char *signals[] = {"changed", "activate"};
    for (unsigned int i = 0; i < 2; ++i)
    {
        retain_state(userdata->state);
        if (detail::gtk4_signal_connect(entry, signals[i], callbacks[i],
                userdata->state, &button_signal_released) == 0)
        {
            release_state(userdata->state);
            release_construction_reference(userdata->state);
            return push_fail_protected(L, "babet.gui: cannot attach entry signal");
        }
    }
    return 1;
}


int l_spin_button(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1))
        return luaL_error(L, "gui.spinButton expects an optional options table");
    require_gui_initialized(L, "gui.spinButton");

    double minimum = 0.0, maximum = 100.0, step = 1.0, value = 0.0;
    unsigned int digits = 0;
    parse_spin_button_options(L, minimum, maximum, step, value, digits);

    push_empty_widget_userdata(L);
    void *spin = detail::gtk4_spin_button_new_with_range(minimum, maximum, step);
    const int result = push_native_widget(L, WidgetKind::spin_button, spin, true);
    if (result != 1)
        return result;
    detail::gtk4_spin_button_set_digits(spin, digits);
    detail::gtk4_spin_button_set_numeric(spin, true);
    detail::gtk4_spin_button_set_value(spin, value);

    auto *userdata = static_cast<WidgetUserdata *>(lua_touserdata(L, -1));
    retain_state(userdata->state);
    if (detail::gtk4_signal_connect(
            spin, "value-changed", gtk_callback(&spin_button_changed),
            userdata->state, &button_signal_released) == 0)
    {
        release_state(userdata->state);
        release_construction_reference(userdata->state);
        return push_fail_protected(L, "babet.gui: cannot attach SpinButton signal");
    }
    return 1;
}

int l_calendar(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1))
        return luaL_error(L, "gui.calendar expects an optional options table");
    require_gui_initialized(L, "gui.calendar");

    int year = 0, month = 0, day = 0;
    const bool has_date = parse_calendar_options(L, year, month, day);

    push_empty_widget_userdata(L);
    void *calendar = detail::gtk4_calendar_new();
    const int result = push_native_widget(L, WidgetKind::calendar, calendar, true);
    if (result != 1)
        return result;

    if (has_date)
    {
        void *date = detail::glib_date_time_new_local(year, month, day, 12, 0, 0.0);
        if (!date)
        {
            release_construction_reference(
                static_cast<WidgetUserdata *>(lua_touserdata(L, -1))->state);
            return push_fail_protected(L, "babet.gui: cannot create calendar date");
        }
        detail::gtk4_calendar_select_day(calendar, date);
        detail::glib_date_time_unref(date);
    }

    auto *userdata = static_cast<WidgetUserdata *>(lua_touserdata(L, -1));
    retain_state(userdata->state);
    if (detail::gtk4_signal_connect(
            calendar, "day-selected", gtk_callback(&calendar_day_selected),
            userdata->state, &button_signal_released) == 0)
    {
        release_state(userdata->state);
        release_construction_reference(userdata->state);
        return push_fail_protected(L, "babet.gui: cannot attach Calendar signal");
    }

    const char *view_signals[] = {"next-month", "prev-month", "next-year", "prev-year"};
    for (const char *signal : view_signals)
    {
        retain_state(userdata->state);
        if (detail::gtk4_signal_connect(
                calendar, signal, gtk_callback(&calendar_view_changed),
                userdata->state, &button_signal_released) == 0)
        {
            release_state(userdata->state);
            release_construction_reference(userdata->state);
            return push_fail_protected(L, "babet.gui: cannot attach Calendar view signal");
        }
    }
    return 1;
}

int l_drawing_area(lua_State *L)
{
    if (!lua_arity_between(L, 0, 1) ||
        (lua_gettop(L) == 1 && !lua_isnil(L, 1) && lua_type(L, 1) != LUA_TTABLE))
        return luaL_error(L, "gui.drawingArea expects an optional options table");
    require_gui_initialized(L, "gui.drawingArea");
    int sizes[] = {320, 200};
    const char *names[] = {"width", "height"};
    if (lua_type(L, 1) == LUA_TTABLE)
    {
        for (unsigned int i = 0; i < 2; ++i)
        {
            lua_pushstring(L, names[i]);
            lua_rawget(L, 1);
            if (!lua_isnil(L, -1))
            {
                if (!lua_is_strict_integer(L, -1))
                    return luaL_error(L, "gui.drawingArea %s must be an integer", names[i]);
                lua_Integer value = lua_tointeger(L, -1);
                if (value <= 0 || value > INT_MAX)
                    return luaL_error(L, "gui.drawingArea %s is out of range", names[i]);
                sizes[i] = static_cast<int>(value);
            }
            lua_pop(L, 1);
        }
    }
    push_empty_widget_userdata(L);
    void *area = detail::gtk4_drawing_area_new();
    const int result = push_native_widget(L, WidgetKind::drawing_area, area, true);
    if (result != 1)
        return result;
    auto *userdata = static_cast<WidgetUserdata *>(lua_touserdata(L, -1));
    detail::gtk4_drawing_area_set_content_width(area, sizes[0]);
    detail::gtk4_drawing_area_set_content_height(area, sizes[1]);
    retain_state(userdata->state);
    detail::gtk4_drawing_area_set_draw_func(area, &drawing_area_draw,
                                           userdata->state, &drawing_area_released);

    // GTK4 input is controller-based. One GtkGestureClick lives with the
    // DrawingArea for its whole native lifetime; onClick() only replaces the
    // Lua callback stored in the userdata. Button 0 means "any mouse button".
    void *gesture = detail::gtk4_gesture_click_new();
    if (!gesture)
    {
        release_construction_reference(userdata->state);
        return push_fail_protected(L, "babet.gui: GTK 4 failed to create click gesture");
    }
    detail::gtk4_gesture_single_set_button(gesture, 0U);
    retain_state(userdata->state);
    if (detail::gtk4_signal_connect(
            gesture, "pressed", gtk_callback(&widget_pressed),
            userdata->state, &button_signal_released) == 0)
    {
        release_state(userdata->state);
        detail::gtk4_object_unref(gesture);
        release_construction_reference(userdata->state);
        return push_fail_protected(L, "babet.gui: cannot attach DrawingArea click signal");
    }
    detail::gtk4_widget_add_controller(area, gesture);
    return 1;
}

int drawing_area_on_draw(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui drawingArea:onDraw expects one function or nil");
    WidgetState *state = check_kind(L, 1, WidgetKind::drawing_area, "gui drawingArea:onDraw");
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, PRIMARY_CALLBACK);
    detail::gtk4_widget_queue_draw(state->native);
    return push_ok_protected(L);
}

int drawing_area_queue_draw(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui drawingArea:queueDraw expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::drawing_area, "gui drawingArea:queueDraw");
    detail::gtk4_widget_queue_draw(state->native);
    return push_ok_protected(L);
}

void *check_draw_context(lua_State *L, int arity)
{
    babet_runtime::require_main_thread(L, "gui drawing context");
    if (lua_gettop(L) != arity)
        luaL_error(L, "gui drawing context: wrong number of arguments");
    auto *context = static_cast<DrawContext *>(luaL_checkudata(L, 1, DRAW_META));
    if (!context->native || context->owner != main_lua_state(L))
        luaL_error(L, "gui drawing context: only valid during its onDraw callback");
    return context->native;
}

double draw_number(lua_State *L, int index)
{
    if (!lua_is_strict_number(L, index))
        luaL_error(L, "gui drawing context: expected a finite number");
    double value = static_cast<double>(lua_tonumber(L, index));
    if (!std::isfinite(value))
        luaL_error(L, "gui drawing context: expected a finite number");
    return value;
}

double draw_color(lua_State *L, int index)
{
    double value = draw_number(L, index);
    if (value < 0 || value > 1)
        luaL_error(L, "gui drawing context: color components must be in [0, 1]");
    return value;
}

int draw_result(lua_State *L, void *cr)
{
    int status = detail::cairo_status(cr);
    if (status != 0)
        return luaL_error(L, "gui drawing context: Cairo error: %s",
                         detail::cairo_status_to_string(status));
    return push_ok_protected(L);
}

int draw_new_path(lua_State *L)
{
    void *cr = check_draw_context(L, 1);
    detail::cairo_new_path(cr);
    return draw_result(L, cr);
}

int draw_close_path(lua_State *L)
{
    void *cr = check_draw_context(L, 1);
    detail::cairo_close_path(cr);
    return draw_result(L, cr);
}

int draw_stroke(lua_State *L)
{
    void *cr = check_draw_context(L, 1);
    detail::cairo_stroke(cr);
    return draw_result(L, cr);
}

int draw_fill(lua_State *L)
{
    void *cr = check_draw_context(L, 1);
    detail::cairo_fill(cr);
    return draw_result(L, cr);
}

int draw_move_to(lua_State *L)
{
    void *cr = check_draw_context(L, 3);
    double x = draw_number(L, 2), y = draw_number(L, 3);
    detail::cairo_move_to(cr, x, y);
    return draw_result(L, cr);
}

int draw_line_to(lua_State *L)
{
    void *cr = check_draw_context(L, 3);
    double x = draw_number(L, 2), y = draw_number(L, 3);
    detail::cairo_line_to(cr, x, y);
    return draw_result(L, cr);
}

int draw_set_line_width(lua_State *L)
{
    void *cr = check_draw_context(L, 2);
    double value = draw_number(L, 2);
    if (value <= 0)
        return luaL_error(L, "gui drawing context:setLineWidth expects a positive number");
    detail::cairo_set_line_width(cr, value);
    return draw_result(L, cr);
}

int draw_set_font_size(lua_State *L)
{
    void *cr = check_draw_context(L, 2);
    double value = draw_number(L, 2);
    if (value <= 0)
        return luaL_error(L, "gui drawing context:setFontSize expects a positive number");
    detail::cairo_set_font_size(cr, value);
    return draw_result(L, cr);
}

int draw_set_source_rgb(lua_State *L)
{
    void *cr = check_draw_context(L, 4);
    double r = draw_color(L, 2);
    double g = draw_color(L, 3);
    double b = draw_color(L, 4);
    detail::cairo_set_source_rgb(cr, r, g, b);
    return draw_result(L, cr);
}

int draw_set_source_rgba(lua_State *L)
{
    void *cr = check_draw_context(L, 5);
    double r = draw_color(L, 2);
    double g = draw_color(L, 3);
    double b = draw_color(L, 4);
    double a = draw_color(L, 5);
    detail::cairo_set_source_rgba(cr, r, g, b, a);
    return draw_result(L, cr);
}

int draw_rectangle(lua_State *L)
{
    void *cr = check_draw_context(L, 5);
    double x = draw_number(L, 2), y = draw_number(L, 3);
    double width = draw_number(L, 4), height = draw_number(L, 5);
    detail::cairo_rectangle(cr, x, y, width, height);
    return draw_result(L, cr);
}

int draw_arc(lua_State *L)
{
    void *cr = check_draw_context(L, 6);
    double x = draw_number(L, 2), y = draw_number(L, 3);
    double radius = draw_number(L, 4);
    double start = draw_number(L, 5), end = draw_number(L, 6);
    if (radius < 0)
        return luaL_error(L, "gui drawing context: radius must be non-negative");
    detail::cairo_arc(cr, x, y, radius, start, end);
    return draw_result(L, cr);
}

// Cairo's toy text API marks its context permanently erroneous for invalid
// UTF-8. Validate before touching it, so a caught Lua argument error is benign.
bool draw_valid_utf8(const unsigned char *p, size_t length) noexcept
{
    size_t i = 0;
    while (i < length)
    {
        unsigned int c = p[i++];
        if (c < 0x80) continue;
        unsigned int count = 0, value = 0, minimum = 0;
        if (c >= 0xC2 && c <= 0xDF) { count = 1; value = c & 0x1F; minimum = 0x80; }
        else if (c >= 0xE0 && c <= 0xEF) { count = 2; value = c & 0x0F; minimum = 0x800; }
        else if (c >= 0xF0 && c <= 0xF4) { count = 3; value = c & 0x07; minimum = 0x10000; }
        else return false;
        if (length - i < count) return false;
        for (unsigned int j = 0; j < count; ++j)
        {
            c = p[i++];
            if ((c & 0xC0) != 0x80) return false;
            value = (value << 6) | (c & 0x3F);
        }
        if (value < minimum || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF))
            return false;
    }
    return true;
}

int draw_text(lua_State *L)
{
    void *cr = check_draw_context(L, 4);
    double x = draw_number(L, 2), y = draw_number(L, 3);
    const char *text = nullptr;
    strict_c_string(L, 4, "gui drawing context:text", text);
    if (!draw_valid_utf8(reinterpret_cast<const unsigned char *>(text), lua_rawlen(L, 4)))
        return luaL_error(L, "gui drawing context:text expects valid UTF-8");
    detail::cairo_move_to(cr, x, y);
    detail::cairo_show_text(cr, text);
    return draw_result(L, cr);
}

// Co-ordinates are in GtkFixed canvas units (pixels at scale factor 1).
void check_canvas_coord(lua_State *L, int index, const char *api)
{
    const double value = finite_number(L, index, api);
    if (value < -10000000.0 || value > 10000000.0)
        luaL_error(L, "%s: coordinate is out of range", api);
}

// Walk every logical parenting edge, including MenuButton popovers and
// directly attached context popovers. Icon/transient-window references are
// lifetime roots, not child edges. A Lua-owned work list and visited set keep
// the traversal iterative and safe on shared paths; all allocation precedes
// native mutation (including collapsed GtkExpander children).
bool lua_tree_contains(lua_State *L, int root_index, WidgetState *target)
{
    luaL_checkstack(L, 10, "gui: cannot check widget parent cycle");
    root_index = lua_absindex(L, root_index);
    lua_createtable(L, 16, 0);
    const int work = lua_gettop(L);
    lua_newtable(L);
    const int visited = lua_gettop(L);
    lua_Integer pending = 0;
    lua_pushvalue(L, root_index);
    lua_rawseti(L, work, ++pending);
    bool found = false;
    while (pending > 0 && !found)
    {
        lua_rawgeti(L, work, pending);
        lua_pushnil(L);
        lua_rawseti(L, work, pending--);
        auto *node = static_cast<WidgetUserdata *>(luaL_testudata(L, -1, WIDGET_META));
        WidgetState *state = node ? node->state : nullptr;
        if (!state) { lua_pop(L, 1); continue; }
        if (state == target) { found = true; lua_pop(L, 1); break; }
        lua_rawgetp(L, visited, state);
        const bool seen = lua_toboolean(L, -1) != 0;
        lua_pop(L, 1);
        if (seen) { lua_pop(L, 1); continue; }
        lua_pushboolean(L, 1);
        lua_rawsetp(L, visited, state);
        lua_getiuservalue(L, -1, 1);
        lua_pushnil(L);
        while (lua_next(L, -2) != 0)
        {
            auto *child = static_cast<WidgetUserdata *>(luaL_testudata(L, -1, WIDGET_META));
            const int key_type = lua_type(L, -2);
            const bool child_edge =
                (lua_isinteger(L, -2) && lua_tointeger(L, -2) > 0) ||
                (key_type == LUA_TSTRING &&
                 std::strcmp(lua_tostring(L, -2), "__menu_popover") == 0) ||
                (key_type == LUA_TLIGHTUSERDATA && child && child->state &&
                 child->state->popover_parent_state == state);
            if (child_edge && child && child->state)
                lua_rawseti(L, work, ++pending); // pop value; retain key for next
            else
                lua_pop(L, 1);
        }
        lua_pop(L, 2); // children, node
    }
    lua_settop(L, work - 1);
    return found;
}

// The child is at stack index 2: refuse if the parent is inside its subtree.
bool creates_widget_cycle(lua_State *L, WidgetState *parent, WidgetState *child)
{
    return parent == child || lua_tree_contains(L, 2, parent);
}

int fixed_put(lua_State *L)
{
    if (!lua_arity_is(L, 4))
        return luaL_error(L, "gui fixed:put expects child, x, y");
    WidgetState *fixed = check_kind(L, 1, WidgetKind::fixed, "gui fixed:put");
    WidgetState *child = check_widget(L, 2, "gui fixed:put");
    if (child == fixed || child->kind == WidgetKind::window)
        return luaL_error(L, "gui fixed:put: invalid child widget");
    if (creates_widget_cycle(L, fixed, child))
        return luaL_error(L, "gui fixed:put: parent cycle is forbidden");
    check_canvas_coord(L, 3, "gui fixed:put x");
    check_canvas_coord(L, 4, "gui fixed:put y");
    if (detail::gtk4_widget_get_parent(child->native))
        return luaL_error(L, "gui fixed:put: child already has a GTK parent");
    lua_getiuservalue(L, 1, 1);
    const lua_Unsigned count = lua_rawlen(L, -1);
    if (count >= static_cast<lua_Unsigned>(LUA_MAXINTEGER))
        return luaL_error(L, "gui fixed:put: too many child handles");
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, static_cast<lua_Integer>(count + 1));
    lua_pop(L, 1);
    detail::gtk4_fixed_put(fixed->native, child->native,
                           lua_tonumber(L, 3), lua_tonumber(L, 4));
    release_construction_reference(child);
    return push_ok_protected(L);
}

int fixed_move(lua_State *L)
{
    if (!lua_arity_is(L, 4))
        return luaL_error(L, "gui fixed:move expects child, x, y");
    WidgetState *fixed = check_kind(L, 1, WidgetKind::fixed, "gui fixed:move");
    WidgetState *child = check_widget(L, 2, "gui fixed:move");
    check_canvas_coord(L, 3, "gui fixed:move x");
    check_canvas_coord(L, 4, "gui fixed:move y");
    if (find_child_handle(L, 1, 2) == 0 ||
        detail::gtk4_widget_get_parent(child->native) != fixed->native)
        return luaL_error(L, "gui fixed:move: child does not belong to this canvas");
    detail::gtk4_fixed_move(fixed->native, child->native,
                            lua_tonumber(L, 3), lua_tonumber(L, 4));
    return push_ok_protected(L);
}

int widget_on_drag(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui widget:onDrag expects a function or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:onDrag");
    if (state->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:onDrag: windows cannot receive drag gestures");
    // Interactive widgets own pointer gestures; their click/select/expand
    // handling can win over our GtkGestureDrag, making callbacks unreliable.
    if (state->kind != WidgetKind::picture &&
        state->kind != WidgetKind::label && state->kind != WidgetKind::box &&
        state->kind != WidgetKind::drawing_area && state->kind != WidgetKind::fixed &&
        state->kind != WidgetKind::progress_bar)
        return luaL_error(L, "gui widget:onDrag: use a non-interactive widget (label, box, drawingArea, fixed, progressBar, picture)");
    if (!state->drag_controller_attached && lua_type(L, 2) == LUA_TFUNCTION)
    {
        void *gesture = detail::gtk4_gesture_drag_new();
        if (!gesture) return push_fail_protected(L, "babet.gui: cannot create drag gesture");
        // GTK takes ownership of the controller. The signal closures each retain
        // a logical reference until GTK releases that controller.
        state->drag_controller_attached = true;
        const char *signals[] = {"drag-begin", "drag-update", "drag-end"};
        const detail::GtkCallback callbacks[] = {
            gtk_callback(&drag_begin), gtk_callback(&drag_update), gtk_callback(&drag_end)};
        for (unsigned i = 0; i < 3; ++i)
        {
            retain_state(state);
            if (detail::gtk4_signal_connect(gesture, signals[i], callbacks[i],
                                            state, &button_signal_released) == 0)
            {
                release_state(state);
                state->drag_controller_attached = false;
                detail::gtk4_object_unref(gesture);
                return push_fail_protected(L, "babet.gui: cannot attach drag gesture");
            }
        }
        detail::gtk4_widget_add_controller(state->native, gesture);
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, DRAG_CALLBACK);
    return push_ok_protected(L);
}

int widget_set_drag_data(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:setDragData expects one string or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:setDragData");
    if (state->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:setDragData: windows cannot be drag sources");
    if (state->kind != WidgetKind::picture &&
        state->kind != WidgetKind::label && state->kind != WidgetKind::box &&
        state->kind != WidgetKind::drawing_area && state->kind != WidgetKind::fixed &&
        state->kind != WidgetKind::progress_bar)
        return luaL_error(L, "gui widget:setDragData: use a non-interactive drag handle (label, box, drawingArea, fixed, progressBar, picture)");

    if (lua_isnil(L, 2))
    {
        if (state->drag_source_controller_attached && state->drag_source_controller)
            (void)detail::gtk4_drag_source_set_text(state->drag_source_controller, nullptr);
        return push_ok_protected(L);
    }
    if (lua_type(L, 2) != LUA_TSTRING)
        return luaL_error(L, "gui widget:setDragData expects one string or nil");
    size_t length = 0;
    const char *payload = lua_tolstring(L, 2, &length);
    if (std::memchr(payload, '\0', length) != nullptr)
        return luaL_error(L, "gui widget:setDragData: payload cannot contain NUL bytes");
    if (!detail::gtk4_utf8_valid(payload, length))
        return luaL_error(L, "gui widget:setDragData: payload must be valid UTF-8");

    // Resolve Lua-owned icon data before acquiring an unattached GTK object.
    // Interning the key may fail or run finalizers: recheck the source, and keep
    // the icon userdata rooted until all native construction is complete.
    lua_getiuservalue(L, 1, 1);
    lua_pushliteral(L, "__drag_icon");
    lua_rawget(L, -2);
    state = check_widget(L, 1, "gui widget:setDragData");
    void *icon_widget = state->native;
    if (auto *icon_ud = static_cast<WidgetUserdata *>(luaL_testudata(L, -1, WIDGET_META));
        icon_ud && icon_ud->state && detail::gtk4_widget_get_mapped(icon_ud->state->native))
        icon_widget = icon_ud->state->native;

    if (!state->drag_source_controller_attached)
    {
        void *source = detail::gtk4_drag_source_new();
        if (!source)
            return push_fail_protected(L, "babet.gui: cannot create GTK drag source");
        detail::gtk4_drag_source_set_actions(source, state->drag_actions);
        detail::gtk4_gesture_single_set_button(source, 1U);
        // GTK otherwise shows the internal payload ID instead of a widget icon.
        if (!detail::gtk4_drag_source_set_widget_icon(source, icon_widget))
        {
            detail::gtk4_object_unref(source);
            return push_fail_protected(L, "babet.gui: cannot create GTK drag icon");
        }
        const char *state_signals[] = {"drag-begin", "drag-end", "drag-cancel"};
        const detail::GtkCallback state_callbacks[] = {
            gtk_callback(&drag_source_begin), gtk_callback(&drag_source_end),
            gtk_callback(&drag_source_cancel)};
        for (unsigned int i = 0; i < 3; ++i)
        {
            retain_state(state);
            if (detail::gtk4_signal_connect(source, state_signals[i], state_callbacks[i],
                                            state, &button_signal_released) == 0)
            {
                release_state(state);
                detail::gtk4_object_unref(source);
                return push_fail_protected(L, "babet.gui: cannot attach GTK drag-source signal");
            }
        }
        if (!detail::gtk4_drag_source_set_text(source, payload))
        {
            detail::gtk4_object_unref(source);
            return push_fail_protected(L, "babet.gui: cannot create GTK drag payload");
        }
        detail::gtk4_widget_add_controller(state->native, source);
        state->drag_source_controller = source;
        state->drag_source_controller_attached = true;
        state->drag_state_signals_attached = true;
    }
    else if (!detail::gtk4_drag_source_set_text(state->drag_source_controller, payload))
        return push_fail_protected(L, "babet.gui: cannot create GTK drag payload");
    return push_ok_protected(L);
}

int widget_on_drop(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui widget:onDrop expects a function or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:onDrop");
    if (state->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:onDrop: windows cannot be drop targets");

    if (!state->drop_target_controller_attached && lua_type(L, 2) == LUA_TFUNCTION)
    {
        void *target = detail::gtk4_drop_target_new_text(state->drop_actions);
        if (!target)
            return push_fail_protected(L, "babet.gui: cannot create GTK drop target");
        detail::rich_set_drop_types(target, (state->drop_types & 1U) != 0U,
                                    (state->drop_types & 2U) != 0U);
        // Stay inert until the allocating Lua callback-table update succeeds.
        // A caught allocation failure must not leave a target swallowing drops.
        detail::gtk4_drop_target_set_actions(target, 0U);
        const char *signals[] = {"enter", "motion", "leave", "drop"};
        const detail::GtkCallback callbacks[] = {
            gtk_callback(&drop_enter), gtk_callback(&drop_motion),
            gtk_callback(&drop_leave), gtk_callback(&drop_received)};
        for (unsigned int i = 0; i < 4; ++i)
        {
            retain_state(state);
            if (detail::gtk4_signal_connect(target, signals[i], callbacks[i], state,
                                            &button_signal_released) == 0)
            {
                release_state(state);
                detail::gtk4_object_unref(target);
                return push_fail_protected(L, "babet.gui: cannot attach GTK drop target signal");
            }
        }
        detail::gtk4_widget_add_controller(state->native, target);
        state->drop_target_controller = target;
        state->drop_target_controller_attached = true;
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, DROP_CALLBACK);
    // The Lua table update can allocate and run finalizers. Recheck the native
    // handle before using the controller borrowed from the GTK widget.
    if (state->native && state->drop_target_controller)
    {
        const bool enabled = !lua_isnil(L, 2);
        state->drop_enabled = enabled;
        detail::gtk4_drop_target_set_preload(state->drop_target_controller, enabled);
        detail::gtk4_drop_target_set_actions(state->drop_target_controller,
                                             enabled ? state->drop_actions : 0U);
        if (!enabled)
        {
            ++state->drop_revision;
            // GTK still accesses its GdkDrop after emitting ::drop. Let it
            // finish that emission normally; actions=0 and the revision above
            // reject the result. Outside ::drop, cancel any hover/preload now.
            if (state->drop_received_depth == 0)
                detail::gtk4_drop_target_reject(state->drop_target_controller);
        }
    }
    return push_ok_protected(L);
}


int widget_set_drop_types(lua_State *L)
{
    if (!lua_arity_is(L,2) || !lua_istable(L,2))
        return luaL_error(L,"gui widget:setDropTypes expects one array of types");
    auto *state=check_widget(L,1,"gui widget:setDropTypes");
    if (state->kind==WidgetKind::window)
        return luaL_error(L,"gui widget:setDropTypes: windows cannot be drop targets");
    const auto n=lua_rawlen(L,2);
    if (n<1 || n>2) return luaL_error(L,"gui widget:setDropTypes expects \"text\" and/or \"files\"");
    unsigned int types=0;std::size_t entries=0;
    lua_pushnil(L);
    while(lua_next(L,2)) {
        if(!lua_isinteger(L,-2) || lua_tointeger(L,-2)<1 ||
           static_cast<unsigned long long>(lua_tointeger(L,-2))>n)
            return luaL_error(L,"gui widget:setDropTypes: expected a dense array");
        const char *name=nullptr;strict_c_string(L,-1,"gui widget:setDropTypes",name);
        unsigned int bit=0;
        if(std::strcmp(name,"text")==0) bit=1U;
        else if(std::strcmp(name,"files")==0) bit=2U;
        else return luaL_error(L,"gui widget:setDropTypes: unknown type '%s'",name);
        if(types & bit) return luaL_error(L,"gui widget:setDropTypes: duplicate type '%s'",name);
        types|=bit;++entries;lua_pop(L,1);
    }
    if(entries!=n) return luaL_error(L,"gui widget:setDropTypes: expected a dense array");
    if((types & 2U) && !detail::gtk4_drop_files_available())
        return push_fail_protected(L,"babet.gui: requires GTK 4.6 (file drops)");
    if(state->drop_received_depth)
        return push_fail_protected(L,"babet.gui: drop types cannot change during drop");
    const ScopedStateReference keep(state);
    const int result=push_ok_protected(L);
    if(!state->native || !state->handle_key) return push_fail_protected(L,"babet.gui: drop target destroyed during the operation");
    state->drop_types=types;++state->drop_revision;
    if(state->drop_target_controller) {
        detail::rich_set_drop_types(state->drop_target_controller,(types&1U)!=0,(types&2U)!=0);
        detail::gtk4_drop_target_reject(state->drop_target_controller);
    }
    return result;
}

int widget_set_drag_actions(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:setDragActions expects one action string or table");
    WidgetState *state = check_widget(L, 1, "gui widget:setDragActions");
    if (state->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:setDragActions: windows cannot be drag sources");
    state->drag_actions = parse_drag_actions(L, 2, "gui widget:setDragActions");
    if (state->drag_source_controller)
        detail::gtk4_drag_source_set_actions(state->drag_source_controller, state->drag_actions);
    return push_ok_protected(L);
}

int widget_set_drop_actions(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:setDropActions expects one action string or table");
    WidgetState *state = check_widget(L, 1, "gui widget:setDropActions");
    if (state->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:setDropActions: windows cannot be drop targets");
    state->drop_actions = parse_drag_actions(L, 2, "gui widget:setDropActions");
    if (state->drop_target_controller)
        detail::gtk4_drop_target_set_actions(state->drop_target_controller,
                                             state->drop_enabled ? state->drop_actions : 0U);
    return push_ok_protected(L);
}

int widget_set_drag_icon(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:setDragIcon expects one widget or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:setDragIcon");
    WidgetState *icon = nullptr;
    if (!lua_isnil(L, 2))
    {
        icon = check_widget(L, 2, "gui widget:setDragIcon icon", false);
        if (icon->kind == WidgetKind::window)
            return luaL_error(L, "gui widget:setDragIcon: a window cannot be a drag icon");
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushliteral(L, "__drag_icon");
    lua_pushvalue(L, 2);
    lua_rawset(L, -3);
    lua_pop(L, 1);
    if (state->native && state->drag_source_controller)
    {
        void *native_icon = icon && detail::gtk4_widget_get_mapped(icon->native)
            ? icon->native : state->native;
        if (!detail::gtk4_drag_source_set_widget_icon(state->drag_source_controller, native_icon))
            return push_fail_protected(L, "babet.gui: cannot update GTK drag icon");
    }
    return push_ok_protected(L);
}

int widget_on_drag_state(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui widget:onDragState expects one function or nil");
    (void)check_widget(L, 1, "gui widget:onDragState");
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, DRAG_STATE_CALLBACK);
    return push_ok_protected(L);
}

int widget_on_pointer(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui widget:onPointer expects one function or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:onPointer");
    if (!state->pointer_controllers_attached && lua_type(L, 2) == LUA_TFUNCTION)
    {
        void *click = detail::gtk4_gesture_click_new();
        void *motion = detail::gtk4_event_controller_motion_new();
        if (!click || !motion)
        {
            if (click) detail::gtk4_object_unref(click);
            if (motion) detail::gtk4_object_unref(motion);
            return push_fail_protected(L, "babet.gui: cannot create pointer controllers");
        }
        detail::gtk4_gesture_single_set_button(click, 0U);
        const char *click_signals[] = {"pressed", "released"};
        const detail::GtkCallback click_callbacks[] = {
            gtk_callback(&pointer_pressed), gtk_callback(&pointer_released)};
        for (unsigned int i = 0; i < 2; ++i)
        {
            retain_state(state);
            if (detail::gtk4_signal_connect(click, click_signals[i], click_callbacks[i],
                                            state, &button_signal_released) == 0)
            {
                release_state(state);
                detail::gtk4_object_unref(click);
                detail::gtk4_object_unref(motion);
                return push_fail_protected(L, "babet.gui: cannot attach pointer click signal");
            }
        }
        const char *motion_signals[] = {"enter", "motion", "leave"};
        const detail::GtkCallback motion_callbacks[] = {
            gtk_callback(&pointer_enter), gtk_callback(&pointer_motion),
            gtk_callback(&pointer_leave)};
        for (unsigned int i = 0; i < 3; ++i)
        {
            retain_state(state);
            if (detail::gtk4_signal_connect(motion, motion_signals[i], motion_callbacks[i],
                                            state, &button_signal_released) == 0)
            {
                release_state(state);
                detail::gtk4_object_unref(click);
                detail::gtk4_object_unref(motion);
                return push_fail_protected(L, "babet.gui: cannot attach pointer motion signal");
            }
        }
        detail::gtk4_widget_add_controller(state->native, click);
        detail::gtk4_widget_add_controller(state->native, motion);
        state->pointer_controllers_attached = true;
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, POINTER_CALLBACK);
    return push_ok_protected(L);
}

int widget_on_key(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui widget:onKey expects one function or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:onKey");
    if (!state->key_controller_attached && lua_type(L, 2) == LUA_TFUNCTION)
    {
        void *controller = detail::gtk4_event_controller_key_new();
        if (!controller) return push_fail_protected(L, "babet.gui: cannot create key controller");
        // Window-level key handlers act as application shortcuts and must see
        // keys before a focused TextView/Entry can consume them. GTK capture
        // phase keeps the API generic while making Ctrl+1/Escape reliable.
        if (state->kind == WidgetKind::window)
            detail::gtk4_event_controller_set_propagation_phase(controller, 1); // GTK_PHASE_CAPTURE
        const char *signals[] = {"key-pressed", "key-released"};
        const detail::GtkCallback callbacks[] = {
            gtk_callback(&key_pressed), gtk_callback(&key_released)};
        for (unsigned int i = 0; i < 2; ++i)
        {
            retain_state(state);
            if (detail::gtk4_signal_connect(controller, signals[i], callbacks[i], state,
                                            &button_signal_released) == 0)
            {
                release_state(state);
                detail::gtk4_object_unref(controller);
                return push_fail_protected(L, "babet.gui: cannot attach key controller signal");
            }
        }
        detail::gtk4_widget_add_controller(state->native, controller);
        state->key_controller_attached = true;
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, KEY_CALLBACK);
    return push_ok_protected(L);
}

int widget_set_cursor(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && !lua_is_strict_string(L, 2)))
        return luaL_error(L, "gui widget:setCursor expects one cursor name string or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:setCursor");
    const char *name = nullptr;
    if (!lua_isnil(L, 2)) strict_c_string(L, 2, "gui widget:setCursor", name);
    detail::gtk4_widget_set_cursor_name(state->native, name);
    return push_ok_protected(L);
}

int widget_set_tooltip_text(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && !lua_is_strict_string(L, 2)))
        return luaL_error(L, "gui widget:setTooltipText expects one string or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:setTooltipText");
    const char *text = nullptr;
    if (!lua_isnil(L, 2)) strict_c_string(L, 2, "gui widget:setTooltipText", text);
    detail::gtk4_widget_set_tooltip_text(state->native, text);
    return push_ok_protected(L);
}

int widget_grab_focus(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui widget:grabFocus expects no arguments");
    WidgetState *state = check_widget(L, 1, "gui widget:grabFocus");
    lua_pushboolean(L, detail::gtk4_widget_grab_focus(state->native));
    return 1;
}

int widget_has_focus(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui widget:hasFocus expects no arguments");
    WidgetState *state = check_widget(L, 1, "gui widget:hasFocus", false);
    lua_pushboolean(L, detail::gtk4_widget_has_focus(state->native));
    return 1;
}

int widget_get_size(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui widget:getSize expects no arguments");
    WidgetState *state = check_widget(L, 1, "gui widget:getSize", false);
    lua_pushinteger(L, detail::gtk4_widget_get_width(state->native));
    lua_pushinteger(L, detail::gtk4_widget_get_height(state->native));
    return 2;
}

int widget_translate_point(lua_State *L)
{
    if (!lua_arity_is(L, 4))
        return luaL_error(L, "gui widget:translatePoint expects target, x, y");
    WidgetState *state = check_widget(L, 1, "gui widget:translatePoint", false);
    WidgetState *target = check_widget(L, 2, "gui widget:translatePoint target", false);
    const double x = finite_number(L, 3, "gui widget:translatePoint x");
    const double y = finite_number(L, 4, "gui widget:translatePoint y");
    double out_x = 0.0, out_y = 0.0;
    if (!detail::gtk4_widget_compute_point(state->native, target->native, x, y, out_x, out_y))
    {
        lua_pushnil(L);
        return 1;
    }
    lua_pushnumber(L, out_x);
    lua_pushnumber(L, out_y);
    return 2;
}

int widget_pick(lua_State *L)
{
    if (!lua_arity_is(L, 3))
        return luaL_error(L, "gui widget:pick expects x, y");
    WidgetState *root = check_widget(L, 1, "gui widget:pick", false);
    const double x = finite_number(L, 2, "gui widget:pick x");
    const double y = finite_number(L, 3, "gui widget:pick y");
    void *native = detail::gtk4_widget_pick(root->native, x, y);
    while (native)
    {
        for (WidgetState *candidate = g_states; candidate; candidate = candidate->next)
        {
            if (candidate->native != native || candidate->owner != root->owner ||
                !candidate->handle_key)
                continue;
            lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
            lua_rawgetp(L, -1, candidate->handle_key);
            if (lua_type(L, -1) == LUA_TUSERDATA)
            {
                lua_remove(L, -2);
                return 1;
            }
            lua_pop(L, 2);
            break;
        }
        if (native == root->native) break;
        native = detail::gtk4_widget_get_parent(native);
    }
    lua_pushnil(L);
    return 1;
}

int widget_set_halign(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui widget:setHAlign expects one alignment string");
    WidgetState *state = check_widget(L, 1, "gui widget:setHAlign");
    detail::gtk4_widget_set_halign(state->native, parse_align(L, 2, "gui widget:setHAlign"));
    return push_ok_protected(L);
}

int widget_set_valign(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui widget:setVAlign expects one alignment string");
    WidgetState *state = check_widget(L, 1, "gui widget:setVAlign");
    detail::gtk4_widget_set_valign(state->native, parse_align(L, 2, "gui widget:setVAlign"));
    return push_ok_protected(L);
}

int widget_set_wrap_mode(lua_State *L)
{
    WidgetState *state = check_widget(L, 1, "gui widget:setWrapMode");
    if (state->kind == WidgetKind::text_view)
    {
        if (!lua_arity_is(L, 2))
            return luaL_error(L, "gui textView:setWrapMode expects one wrap mode string");
        detail::gtk4_text_view_set_wrap_mode(
            state->native, parse_wrap_mode(L, 2, "gui textView:setWrapMode"));
        return push_ok_protected(L);
    }
    if (state->kind == WidgetKind::label)
    {
        if (!lua_arity_is(L, 2))
            return luaL_error(L, "gui label:setWrapMode expects one wrap mode string");
        detail::gtk4_label_set_wrap_mode(
            state->native, parse_label_wrap_mode(L, 2, "gui label:setWrapMode"));
        return push_ok_protected(L);
    }
    return luaL_error(L, "gui widget:setWrapMode: expected a label or textView handle");
}

int label_set_wrap(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui label:setWrap expects one boolean");
    WidgetState *state = check_kind(L, 1, WidgetKind::label, "gui label:setWrap");
    detail::gtk4_label_set_wrap(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int label_set_xalign(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui label:setXAlign expects one number between 0 and 1");
    WidgetState *state = check_kind(L, 1, WidgetKind::label, "gui label:setXAlign");
    const double alignment = finite_number(L, 2, "gui label:setXAlign");
    if (alignment < 0.0 || alignment > 1.0)
        return luaL_error(L, "gui label:setXAlign must be between 0 and 1");
    detail::gtk4_label_set_xalign(state->native, static_cast<float>(alignment));
    return push_ok_protected(L);
}

int paned_get_position(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui paned:getPosition expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::paned, "gui paned:getPosition", false);
    lua_pushinteger(L, detail::gtk4_paned_get_position(state->native));
    return 1;
}

int paned_set_position(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_integer(L, 2))
        return luaL_error(L, "gui paned:setPosition expects one non-negative integer");
    WidgetState *state = check_kind(L, 1, WidgetKind::paned, "gui paned:setPosition");
    const lua_Integer value = lua_tointeger(L, 2);
    if (value < 0 || value > INT_MAX) return luaL_error(L, "gui paned:setPosition is out of range");
    detail::gtk4_paned_set_position(state->native, static_cast<int>(value));
    return push_ok_protected(L);
}

int paned_on_position_changed(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui paned:onPositionChanged expects one function or nil");
    WidgetState *state = check_kind(L, 1, WidgetKind::paned, "gui paned:onPositionChanged");
    if (!state->paned_position_signal_attached && lua_type(L, 2) == LUA_TFUNCTION)
    {
        retain_state(state);
        if (detail::gtk4_signal_connect(state->native, "notify::position",
                gtk_callback(&paned_position_changed), state, &button_signal_released) == 0)
        {
            release_state(state);
            return push_fail_protected(L, "babet.gui: cannot attach paned position signal");
        }
        state->paned_position_signal_attached = true;
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, PANED_POSITION_CALLBACK);
    return push_ok_protected(L);
}

int widget_set_icon_name(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && !lua_is_strict_string(L, 2)))
        return luaL_error(L, "gui widget:setIconName expects one icon name string or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:setIconName");
    const char *name = nullptr;
    if (!lua_isnil(L, 2)) strict_c_string(L, 2, "gui widget:setIconName", name);
    if (state->kind == WidgetKind::image)
        detail::gtk4_image_set_from_icon_name(state->native, name);
    else if (state->kind == WidgetKind::button)
        detail::gtk4_button_set_icon_name(state->native, name);
    else if (state->kind == WidgetKind::menu_button)
        detail::gtk4_menu_button_set_icon_name(state->native, name);
    else if (state->kind == WidgetKind::window)
        detail::gtk4_window_set_icon_name(state->native, name);
    else
        return luaL_error(L, "gui widget:setIconName: expected an image, button, menuButton or window handle");
    return push_ok_protected(L);
}

int menu_button_set_popover(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui menuButton:setPopover expects one popover or nil");
    WidgetState *button = check_kind(L, 1, WidgetKind::menu_button, "gui menuButton:setPopover");
    WidgetState *popover = nullptr;
    if (!lua_isnil(L, 2))
    {
        popover = check_kind(L, 2, WidgetKind::popover, "gui menuButton:setPopover popover");
        if (creates_widget_cycle(L, button, popover))
            return luaL_error(L, "gui menuButton:setPopover: parent cycle is forbidden");
        button = check_kind(L, 1, WidgetKind::menu_button, "gui menuButton:setPopover");
        popover = check_kind(L, 2, WidgetKind::popover, "gui menuButton:setPopover popover");
        void *parent = detail::gtk4_widget_get_parent(popover->native);
        if (parent && parent != button->native)
            return luaL_error(L, "gui menuButton:setPopover: popover already has a GTK parent");
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushliteral(L, "__menu_popover");
    lua_rawget(L, -2);
    auto *old_ud = static_cast<WidgetUserdata *>(luaL_testudata(L, -1, WIDGET_META));
    WidgetState *old = old_ud ? old_ud->state : nullptr;
    if (old == popover)
    {
        lua_pop(L, 2);
        return push_ok_protected(L);
    }
    if (old && old->native) acquire_construction_reference(old);
    lua_pop(L, 1);
    lua_pushliteral(L, "__menu_popover");
    lua_pushvalue(L, 2);
    lua_rawset(L, -3);
    lua_pop(L, 1);
    detail::gtk4_menu_button_set_popover(button->native, popover ? popover->native : nullptr);
    if (popover) release_construction_reference(popover);
    return push_ok_protected(L);
}

int menu_button_popup(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui widget:popup expects no arguments");
    WidgetState *state = check_widget(L, 1, "gui widget:popup");
    if (state->kind == WidgetKind::menu_button)
        detail::gtk4_menu_button_popup(state->native);
    else if (state->kind == WidgetKind::popover)
    {
        if (!detail::gtk4_widget_get_parent(state->native))
            return luaL_error(L, "gui popover:popup: attach the popover to a parent widget or menuButton first");
        detail::gtk4_popover_present(state->native);
        detail::gtk4_popover_popup(state->native);
    }
    else
        return luaL_error(L, "gui widget:popup: expected a menuButton or popover handle");
    return push_ok_protected(L);
}

int menu_button_popdown(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui widget:popdown expects no arguments");
    WidgetState *state = check_widget(L, 1, "gui widget:popdown");
    if (state->kind == WidgetKind::menu_button)
        detail::gtk4_menu_button_popdown(state->native);
    else if (state->kind == WidgetKind::popover)
        detail::gtk4_popover_popdown(state->native);
    else
        return luaL_error(L, "gui widget:popdown: expected a menuButton or popover handle");
    return push_ok_protected(L);
}

int popover_attach_to(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui popover:attachTo expects one widget or nil");
    WidgetState *popover = check_kind(L, 1, WidgetKind::popover, "gui popover:attachTo");
    WidgetState *parent = nullptr;
    if (!lua_isnil(L, 2))
    {
        parent = check_widget(L, 2, "gui popover:attachTo parent", false);
        if (parent == popover)
            return luaL_error(L, "gui popover:attachTo: a popover cannot parent itself");
        if (parent->kind == WidgetKind::window)
            return luaL_error(L, "gui popover:attachTo: attach to a window child, not the top-level window");
        if (lua_tree_contains(L, 1, parent))
            return luaL_error(L, "gui popover:attachTo: parent/child cycle");
        popover = check_kind(L, 1, WidgetKind::popover, "gui popover:attachTo");
        parent = check_widget(L, 2, "gui popover:attachTo parent", false);
    }

    void *native_parent = detail::gtk4_widget_get_parent(popover->native);
    if (native_parent && !popover->popover_parent_state)
        return luaL_error(L, "gui popover:attachTo: popover is owned by another GTK container or menuButton");
    if (popover->popover_parent_state == parent)
        return push_ok_protected(L);

    // Root the popover from its logical parent before changing native
    // ownership. This keeps its Lua child/callback table alive while visible.
    if (parent)
    {
        lua_getiuservalue(L, 2, 1);
        lua_pushvalue(L, 1);
        lua_rawsetp(L, -2, popover->handle_key);
        lua_pop(L, 1);
    }

    WidgetState *old = popover->popover_parent_state;
    if (native_parent)
        detail::gtk4_widget_unparent(popover->native);
    popover->popover_parent_state = nullptr;

    if (old)
    {
        lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
        lua_rawgetp(L, -1, old->handle_key);
        if (lua_type(L, -1) == LUA_TUSERDATA)
        {
            lua_getiuservalue(L, -1, 1);
            lua_pushnil(L);
            lua_rawsetp(L, -2, popover->handle_key);
            lua_pop(L, 1);
        }
        lua_pop(L, 2);
        release_state(old);
    }

    if (parent)
    {
        detail::gtk4_widget_set_parent(popover->native, parent->native);
        popover->popover_parent_state = parent;
        retain_state(parent);
    }
    return push_ok_protected(L);
}

int popover_set_pointing_to(lua_State *L)
{
    if (!lua_arity_is(L, 3) && !lua_arity_is(L, 5))
        return luaL_error(L, "gui popover:setPointingTo expects x, y or x, y, width, height");
    WidgetState *state = check_kind(L, 1, WidgetKind::popover, "gui popover:setPointingTo");
    int values[4] = {0, 0, 1, 1};
    const int count = lua_gettop(L) == 3 ? 2 : 4;
    for (int i = 0; i < count; ++i)
    {
        if (!lua_is_strict_integer(L, i + 2))
            return luaL_error(L, "gui popover:setPointingTo expects integer coordinates and sizes");
        const lua_Integer value = lua_tointeger(L, i + 2);
        if (value < INT_MIN || value > INT_MAX)
            return luaL_error(L, "gui popover:setPointingTo value is out of range");
        values[i] = static_cast<int>(value);
    }
    if (values[2] < 0 || values[3] < 0)
        return luaL_error(L, "gui popover:setPointingTo width and height must be non-negative");
    detail::gtk4_popover_set_pointing_to(state->native, values[0], values[1], values[2], values[3]);
    return push_ok_protected(L);
}

int window_set_title(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui window:setTitle expects one string");
    WidgetState *state = check_kind(L, 1, WidgetKind::window, "gui window:setTitle");
    const char *title = nullptr;
    strict_c_string(L, 2, "gui window:setTitle", title);
    detail::gtk4_window_set_title(state->native, title);
    return push_ok_protected(L);
}

int window_set_transient_for(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui window:setTransientFor expects one window or nil");
    WidgetState *window = check_kind(L, 1, WidgetKind::window, "gui window:setTransientFor");
    WidgetState *parent = nullptr;
    if (!lua_isnil(L, 2))
    {
        parent = check_kind(L, 2, WidgetKind::window, "gui window:setTransientFor parent", false);
        if (parent == window) return luaL_error(L, "gui window:setTransientFor: a window cannot be transient for itself");
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushliteral(L, "__transient_for");
    lua_pushvalue(L, 2);
    lua_rawset(L, -3);
    lua_pop(L, 1);
    detail::gtk4_window_set_transient_for(window->native, parent ? parent->native : nullptr);
    return push_ok_protected(L);
}

int window_set_modal(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui window:setModal expects one boolean");
    WidgetState *state = check_kind(L, 1, WidgetKind::window, "gui window:setModal");
    detail::gtk4_window_set_modal(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int window_on_close_request(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui window:onCloseRequest expects one function or nil");
    WidgetState *state = check_kind(L, 1, WidgetKind::window, "gui window:onCloseRequest");
    if (!state->close_request_signal_attached && lua_type(L, 2) == LUA_TFUNCTION)
    {
        retain_state(state);
        if (detail::gtk4_signal_connect(state->native, "close-request",
                gtk_callback(&window_close_requested), state, &button_signal_released) == 0)
        {
            release_state(state);
            return push_fail_protected(L, "babet.gui: cannot attach window close-request signal");
        }
        state->close_request_signal_attached = true;
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, CLOSE_REQUEST_CALLBACK);
    return push_ok_protected(L);
}

int widget_set_size_request(lua_State *L)
{
    if (!lua_arity_is(L, 3))
        return luaL_error(L, "gui widget:setSizeRequest expects width, height");
    WidgetState *state = check_widget(L, 1, "gui widget:setSizeRequest");
    int sizes[2];
    for (int i = 0; i < 2; ++i)
    {
        if (!lua_is_strict_integer(L, i + 2))
            return luaL_error(L, "gui widget:setSizeRequest: sizes must be integers");
        const lua_Integer value = lua_tointeger(L, i + 2);
        if (value < -1 || value > INT_MAX)
            return luaL_error(L, "gui widget:setSizeRequest: size out of range");
        sizes[i] = static_cast<int>(value);
    }
    detail::gtk4_widget_set_size_request(state->native, sizes[0], sizes[1]);
    return push_ok_protected(L);
}

int check_get_active(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui checkButton:getActive expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::check_button, "gui checkButton:getActive", false);
    lua_pushboolean(L, detail::gtk4_check_button_get_active(state->native));
    return 1;
}

int check_set_active(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui checkButton:setActive expects one boolean");
    WidgetState *state = check_kind(L, 1, WidgetKind::check_button, "gui checkButton:setActive");
    retain_state(state);
    void *native = detail::gtk4_object_ref_sink(state->native);
    lua_State *previous = state->callback_thread;
    state->callback_thread = L;
    detail::gtk4_check_button_set_active(native, lua_toboolean(L, 2) != 0);
    state->callback_thread = previous;
    detail::gtk4_object_unref(native);
    release_state(state);
    return push_ok_protected(L);
}

int progress_get_fraction(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui progressBar:getFraction expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::progress_bar, "gui progressBar:getFraction", false);
    lua_pushnumber(L, detail::gtk4_progress_bar_get_fraction(state->native));
    return 1;
}

int progress_set_fraction(lua_State *L)
{
    if (!lua_arity_is(L, 2)) return luaL_error(L, "gui progressBar:setFraction expects a fraction");
    WidgetState *state = check_kind(L, 1, WidgetKind::progress_bar, "gui progressBar:setFraction");
    const double value = finite_number(L, 2, "gui progressBar:setFraction");
    if (value < 0.0 || value > 1.0)
        return luaL_error(L, "gui progressBar:setFraction expects a number from 0 to 1");
    detail::gtk4_progress_bar_set_fraction(state->native, value);
    return push_ok_protected(L);
}

int progress_show_text(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui progressBar:setShowText expects one boolean");
    WidgetState *state = check_kind(L, 1, WidgetKind::progress_bar, "gui progressBar:setShowText");
    detail::gtk4_progress_bar_set_show_text(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int expander_get_expanded(lua_State *L)
{
    if (!lua_arity_is(L, 1)) return luaL_error(L, "gui expander:getExpanded expects no arguments");
    WidgetState *state = check_kind(L, 1, WidgetKind::expander, "gui expander:getExpanded", false);
    lua_pushboolean(L, detail::gtk4_expander_get_expanded(state->native));
    return 1;
}

int expander_set_expanded(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui expander:setExpanded expects one boolean");
    WidgetState *state = check_kind(L, 1, WidgetKind::expander, "gui expander:setExpanded");
    detail::gtk4_expander_set_expanded(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

// g_object_get transfers an allocated copy to us. Release it even if the
// following C++ string allocation throws, before reporting the error to Lua.
std::string text_view_snapshot(void *view)
{
    const std::unique_ptr<char, decltype(&detail::gtk4_free)> raw(
        detail::gtk4_text_buffer_dup_text(detail::gtk4_text_view_get_buffer(view)),
        &detail::gtk4_free);
    if (!raw) return {};
    return std::string(raw.get());
}

// Only use across native operations and protected Lua callbacks: a raw Lua
// longjmp would bypass C++ destructors. TextView's post-write snapshot can
// throw, so its native/logical pins and callback thread need scoped cleanup.
class ScopedWidgetCallback
{
public:
    ScopedWidgetCallback(WidgetState *state, lua_State *caller) noexcept
        : state_(state), native_(detail::gtk4_object_ref_sink(state->native)),
          previous_(state->callback_thread)
    {
        retain_state(state_);
        state_->callback_thread = caller;
    }
    ~ScopedWidgetCallback()
    {
        state_->callback_thread = previous_;
        detail::gtk4_object_unref(native_);
        release_state(state_);
    }
    ScopedWidgetCallback(const ScopedWidgetCallback &) = delete;
    ScopedWidgetCallback &operator=(const ScopedWidgetCallback &) = delete;
    void *native() const noexcept { return native_; }

private:
    WidgetState *state_;
    void *native_;
    lua_State *previous_;
};

#include "gui_text_tags.inc"

int widget_add(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:add expects one child widget");
    WidgetState *parent = check_widget(L, 1, "gui widget:add");
    WidgetState *child = check_widget(L, 2, "gui widget:add");
    if (parent == child)
        return luaL_error(L, "gui widget:add: a widget cannot contain itself");
    if (parent->kind != WidgetKind::window && parent->kind != WidgetKind::box &&
        parent->kind != WidgetKind::scrolled_window && parent->kind != WidgetKind::expander &&
        parent->kind != WidgetKind::paned && parent->kind != WidgetKind::popover)
        return luaL_error(L, "gui widget:add: parent must be a window, box, scrolledWindow, expander, paned or popover");
    if (child->kind == WidgetKind::window)
        return luaL_error(L, "gui widget:add: a window cannot be a child widget");
    if (detail::gtk4_widget_get_parent(child->native) != nullptr)
        return luaL_error(L, "gui widget:add: child already has a GTK parent");
    if (creates_widget_cycle(L, parent, child))
        return luaL_error(L, "gui widget:add: parent cycle is forbidden");

    // Root the Lua child BEFORE GTK takes ownership. A Lua OOM therefore leaves
    // the native hierarchy unchanged.
    lua_getiuservalue(L, 1, 1);
    const lua_Unsigned count = lua_rawlen(L, -1);
    if ((parent->kind == WidgetKind::scrolled_window || parent->kind == WidgetKind::expander ||
         parent->kind == WidgetKind::popover) && count != 0)
    {
        lua_pop(L, 1);
        return luaL_error(L, "gui widget:add: %s already has a child", kind_name(parent->kind));
    }
    if (parent->kind == WidgetKind::paned && count >= 2)
    {
        lua_pop(L, 1);
        return luaL_error(L, "gui widget:add: paned already has two children");
    }
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
    else if (parent->kind == WidgetKind::box)
        detail::gtk4_box_append(parent->native, child->native);
    else if (parent->kind == WidgetKind::scrolled_window)
        detail::gtk4_scrolled_window_set_child(parent->native, child->native);
    else if (parent->kind == WidgetKind::paned)
    {
        if (count == 0) detail::gtk4_paned_set_start_child(parent->native, child->native);
        else detail::gtk4_paned_set_end_child(parent->native, child->native);
    }
    else if (parent->kind == WidgetKind::popover)
        detail::gtk4_popover_set_child(parent->native, child->native);
    else
        detail::gtk4_box_append(parent->content, child->native);
    release_construction_reference(child);
    return push_ok_protected(L);
}

// Reorder an existing box child in place. No GtkWidget is detached,
// destroyed, recreated, or given a new Lua owner. The Lua child list follows
// the native visual ordering, including after later remove()/clear() calls.
int box_reorder(lua_State *L)
{
    if (!lua_arity_is(L, 3))
        return luaL_error(L, "gui box:reorder expects child, previousChild or nil");
    WidgetState *box = check_kind(L, 1, WidgetKind::box, "gui box:reorder");
    WidgetState *child = check_widget(L, 2, "gui box:reorder child");
    if (child->kind == WidgetKind::window)
        return luaL_error(L, "gui box:reorder: windows cannot be box children");
    WidgetState *previous = nullptr;
    if (!lua_isnil(L, 3))
    {
        previous = check_widget(L, 3, "gui box:reorder previousChild");
    }
    const lua_Integer from = find_child_handle(L, 1, 2);
    if (from == 0 || detail::gtk4_widget_get_parent(child->native) != box->native)
        return luaL_error(L, "gui box:reorder: child does not belong to this box");
    const lua_Integer after = previous ? find_child_handle(L, 1, 3) : 0;
    if (previous && (after == 0 || detail::gtk4_widget_get_parent(previous->native) != box->native))
        return luaL_error(L, "gui box:reorder: previousChild does not belong to this box");
    if (previous == child)
        return push_ok_protected(L); // valid member, no-op
    const lua_Integer to = after == 0 ? 1 : (after < from ? after + 1 : after);
    if (from == to)
        return push_ok_protected(L);

    // Existing integer keys are overwritten in place; no extra ownership and
    // no Lua allocation between the table update and the native GTK call.
    lua_getiuservalue(L, 1, 1);
    if (to < from)
    {
        for (lua_Integer i = from; i > to; --i)
        {
            lua_rawgeti(L, -1, i - 1);
            lua_rawseti(L, -2, i);
        }
    }
    else
    {
        for (lua_Integer i = from; i < to; ++i)
        {
            lua_rawgeti(L, -1, i + 1);
            lua_rawseti(L, -2, i);
        }
    }
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, to);
    lua_pop(L, 1);
    detail::gtk4_box_reorder_child_after(box->native, child->native,
                                         previous ? previous->native : nullptr);
    return push_ok_protected(L);
}

int widget_remove(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui container:remove expects one child widget");
    WidgetState *parent = check_widget(L, 1, "gui container:remove");
    WidgetState *child = check_widget(L, 2, "gui container:remove");
    if (parent->kind != WidgetKind::box && parent->kind != WidgetKind::scrolled_window &&
        parent->kind != WidgetKind::fixed && parent->kind != WidgetKind::expander &&
        parent->kind != WidgetKind::paned && parent->kind != WidgetKind::popover)
        return luaL_error(L, "gui container:remove: parent must be a box, scrolledWindow, fixed, expander, paned or popover");
    const lua_Integer index = find_child_handle(L, 1, 2);
    if (index == 0)
        return luaL_error(L, "gui container:remove: child does not belong to this container");

    // GTK drops the parent's native reference while unparenting. Re-acquire a
    // construction reference first so the Lua handle remains usable and can be
    // reinserted elsewhere after remove().
    acquire_construction_reference(child);
    if (parent->kind == WidgetKind::box)
        detail::gtk4_box_remove(parent->native, child->native);
    else if (parent->kind == WidgetKind::scrolled_window)
        detail::gtk4_scrolled_window_set_child(parent->native, nullptr);
    else if (parent->kind == WidgetKind::fixed)
        detail::gtk4_fixed_remove(parent->native, child->native);
    else if (parent->kind == WidgetKind::paned)
    {
        if (index == 1)
        {
            // The Lua child list is intentionally dense. If the start child is
            // removed while an end child exists, promote that surviving child
            // to the start slot as well. Otherwise a later add() would try to
            // replace the still-occupied end slot even though the Lua list says
            // there is only one child. Pin it while temporarily unparented.
            WidgetState *survivor = nullptr;
            lua_getiuservalue(L, 1, 1);
            if (lua_rawlen(L, -1) >= 2)
            {
                lua_rawgeti(L, -1, 2);
                auto *survivor_ud = static_cast<WidgetUserdata *>(
                    luaL_testudata(L, -1, WIDGET_META));
                survivor = survivor_ud ? survivor_ud->state : nullptr;
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
            if (survivor && survivor->native)
                acquire_construction_reference(survivor);
            detail::gtk4_paned_set_start_child(parent->native, nullptr);
            if (survivor && survivor->native)
            {
                detail::gtk4_paned_set_end_child(parent->native, nullptr);
                detail::gtk4_paned_set_start_child(parent->native, survivor->native);
                release_construction_reference(survivor);
            }
        }
        else
            detail::gtk4_paned_set_end_child(parent->native, nullptr);
    }
    else if (parent->kind == WidgetKind::popover)
        detail::gtk4_popover_set_child(parent->native, nullptr);
    else
        detail::gtk4_box_remove(parent->content, child->native);
    erase_child_handle(L, 1, index);
    return push_ok_protected(L);
}

int widget_clear(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui container:clear expects no arguments");
    WidgetState *parent = check_widget(L, 1, "gui container:clear");
    if (parent->kind != WidgetKind::box && parent->kind != WidgetKind::scrolled_window &&
        parent->kind != WidgetKind::fixed && parent->kind != WidgetKind::expander &&
        parent->kind != WidgetKind::paned && parent->kind != WidgetKind::popover)
        return luaL_error(L, "gui container:clear: parent must be a box, scrolledWindow, fixed, expander, paned or popover");

    lua_getiuservalue(L, 1, 1);
    const lua_Integer count = static_cast<lua_Integer>(lua_rawlen(L, -1));
    for (lua_Integer i = 1; i <= count; ++i)
    {
        lua_rawgeti(L, -1, i);
        auto *userdata = static_cast<WidgetUserdata *>(luaL_testudata(L, -1, WIDGET_META));
        WidgetState *child = userdata ? userdata->state : nullptr;
        lua_pop(L, 1);
        if (!child || !child->native)
            continue;
        acquire_construction_reference(child);
        if (parent->kind == WidgetKind::box)
            detail::gtk4_box_remove(parent->native, child->native);
        else if (parent->kind == WidgetKind::scrolled_window)
            detail::gtk4_scrolled_window_set_child(parent->native, nullptr);
        else if (parent->kind == WidgetKind::fixed)
            detail::gtk4_fixed_remove(parent->native, child->native);
        else if (parent->kind == WidgetKind::paned)
        {
            if (i == 1) detail::gtk4_paned_set_start_child(parent->native, nullptr);
            else detail::gtk4_paned_set_end_child(parent->native, nullptr);
        }
        else if (parent->kind == WidgetKind::popover)
            detail::gtk4_popover_set_child(parent->native, nullptr);
        else
            detail::gtk4_box_remove(parent->content, child->native);
    }
    for (lua_Integer i = count; i >= 1; --i)
    {
        lua_pushnil(L);
        lua_rawseti(L, -2, i);
    }
    lua_pop(L, 1);
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
    else if (state->kind == WidgetKind::entry)
    {
        // GtkEditable may emit more than one synchronous "changed" signal for
        // one gtk_editable_set_text() call (for example delete then insert).
        // Those intermediate states are an implementation detail of GTK and
        // must not leak into Babet's public callback contract. Suppress native
        // notifications while the setter is active, then emit exactly one Lua
        // notification if the final text differs from the initial snapshot.
        //
        // Keep both native and logical state pinned through the synthetic
        // callback: that callback may close the parent window, finalize the
        // userdata, replace itself or re-enter setText().
        const std::string before(detail::gtk4_editable_get_text(state->native));
        retain_state(state);
        void *native = detail::gtk4_object_ref_sink(state->native);
        lua_State *previous = state->callback_thread;
        state->callback_thread = L;
        ++state->entry_set_text_depth;
        detail::gtk4_editable_set_text(native, text);
        --state->entry_set_text_depth;
        const bool changed = before != detail::gtk4_editable_get_text(native);
        if (changed && state->native)
            dispatch_widget_callback(state, PRIMARY_CALLBACK);
        state->callback_thread = previous;
        detail::gtk4_object_unref(native);
        release_state(state);
    }
    else if (state->kind == WidgetKind::text_view)
    {
        const std::string before = text_view_snapshot(state->native);
        const ScopedWidgetCallback callback(state, L);
        void *native = callback.native();
        ++state->entry_set_text_depth;
        detail::gtk4_text_buffer_set_text(detail::gtk4_text_view_get_buffer(native), text);
        --state->entry_set_text_depth;
        const bool changed = before != text_view_snapshot(native);
        if (changed && state->native)
            dispatch_widget_callback(state, PRIMARY_CALLBACK);
    }
    else if (state->kind == WidgetKind::check_button)
        detail::gtk4_check_button_set_label(state->native, text);
    else if (state->kind == WidgetKind::expander)
        detail::gtk4_expander_set_label(state->native, text);
    else if (state->kind == WidgetKind::progress_bar)
        detail::gtk4_progress_bar_set_text(state->native, text);
    else if (state->kind == WidgetKind::menu_button)
        detail::gtk4_menu_button_set_label(state->native, text);
    else
        return luaL_error(L, "gui widget:setText: only label, button, entry, textView, checkButton, progressBar, expander and menuButton support text");
    return push_ok_protected(L);
}

int button_on_click(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:onClick expects one function or nil");

    WidgetState *state = check_widget(L, 1, "gui widget:onClick");
    if (state->kind != WidgetKind::button &&
        state->kind != WidgetKind::drawing_area &&
        state->kind != WidgetKind::progress_bar)
        return luaL_error(L,
            "gui widget:onClick: expected a button, drawingArea or progressBar handle");

    lua_Integer slot = PRIMARY_CALLBACK;
    if (state->kind == WidgetKind::drawing_area ||
        state->kind == WidgetKind::progress_bar)
    {
        if (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION)
            return luaL_error(L,
                "gui drawingArea/progressBar:onClick expects one function or nil");
        slot = CLICK_CALLBACK;
    }
    else if (lua_type(L, 2) != LUA_TFUNCTION)
    {
        return luaL_error(L, "gui button:onClick expects one function");
    }

    // Do not change GtkProgressBar behavior for existing passive/progress
    // displays: install the native controller only when onClick(fn) is asked
    // for. Mirrors the onDrag gesture's lazy initialization.
    if (state->kind == WidgetKind::progress_bar &&
        lua_type(L, 2) == LUA_TFUNCTION && !state->click_controller_attached)
    {
        void *gesture = detail::gtk4_gesture_click_new();
        if (!gesture)
            return push_fail_protected(L, "babet.gui: cannot create progressBar click gesture");
        // Primary mouse button only; no fake activation on right-click.
        detail::gtk4_gesture_single_set_button(gesture, 1U);
        retain_state(state);
        if (detail::gtk4_signal_connect(
                gesture, "pressed", gtk_callback(&widget_pressed),
                state, &button_signal_released) == 0)
        {
            release_state(state);
            detail::gtk4_object_unref(gesture);
            return push_fail_protected(L, "babet.gui: cannot attach progressBar click signal");
        }
        detail::gtk4_widget_add_controller(state->native, gesture);
        state->click_controller_attached = true;
    }
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, slot);
    return push_ok_protected(L);
}

int entry_get_text(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui entry:getText expects no arguments");
    WidgetState *state = check_widget(L, 1, "gui widget:getText", false);
    if (state->kind == WidgetKind::text_view)
        return push_string_protected(L, text_view_snapshot(state->native));
    if (state->kind != WidgetKind::entry)
        (void)check_kind(L, 1, WidgetKind::entry, "gui entry:getText", false);
    // Own a snapshot before any Lua allocation/GC can change the GTK buffer.
    const std::string text(detail::gtk4_editable_get_text(state->native));
    return push_string_protected(L, text);
}

int entry_set_placeholder(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui entry:setPlaceholder expects one string");
    WidgetState *state = check_kind(L, 1, WidgetKind::entry, "gui entry:setPlaceholder");
    const char *text = nullptr;
    strict_c_string(L, 2, "gui entry:setPlaceholder", text);
    detail::gtk4_entry_set_placeholder(state->native, text);
    return push_ok_protected(L);
}

int entry_set_editable(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui entry:setEditable expects one boolean");
    WidgetState *state = check_widget(L, 1, "gui widget:setEditable");
    if (state->kind == WidgetKind::entry)
        detail::gtk4_editable_set_editable(state->native, lua_toboolean(L, 2) != 0);
    else if (state->kind == WidgetKind::text_view)
        detail::gtk4_text_view_set_editable(state->native, lua_toboolean(L, 2) != 0);
    else
        (void)check_kind(L, 1, WidgetKind::entry, "gui entry:setEditable");
    return push_ok_protected(L);
}

int entry_on_signal(lua_State *L, lua_Integer slot, const char *api)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "%s expects one function or nil", api);
    (void)check_kind(L, 1, WidgetKind::entry, api);
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, slot);
    return push_ok_protected(L);
}

int widget_on_changed(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui widget:onChanged expects one function or nil");
    WidgetState *state = check_widget(L, 1, "gui widget:onChanged");
    if (state->kind != WidgetKind::entry && state->kind != WidgetKind::spin_button &&
        state->kind != WidgetKind::calendar && state->kind != WidgetKind::text_view &&
        state->kind != WidgetKind::check_button)
        return luaL_error(
            L,
            "gui widget:onChanged: expected an entry handle, textView, checkButton, spinButton or calendar");
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, PRIMARY_CALLBACK);
    return push_ok_protected(L);
}

int entry_on_activate(lua_State *L)
{
    return entry_on_signal(L, ACTIVATE_CALLBACK, "gui entry:onActivate");
}

int spin_button_get_value(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui spinButton:getValue expects no arguments");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::spin_button, "gui spinButton:getValue", false);
    lua_pushnumber(L, detail::gtk4_spin_button_get_value(state->native));
    return 1;
}

int spin_button_set_value(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui spinButton:setValue expects one number");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::spin_button, "gui spinButton:setValue");
    const double value = finite_number(L, 2, "gui spinButton:setValue");

    // value-changed can run synchronously. Pin both native and logical state
    // until GTK returns, exactly like Entry:setText().
    retain_state(state);
    void *native = detail::gtk4_object_ref_sink(state->native);
    lua_State *previous = state->callback_thread;
    state->callback_thread = L;
    detail::gtk4_spin_button_set_value(native, value);
    state->callback_thread = previous;
    detail::gtk4_object_unref(native);
    release_state(state);
    return push_ok_protected(L);
}

int calendar_get_date(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui calendar:getDate expects no arguments");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::calendar, "gui calendar:getDate", false);
    if (!lua_checkstack(L, 3))
        return luaL_error(L, "gui calendar:getDate: cannot grow Lua stack");
    void *date = detail::gtk4_calendar_get_date(state->native);
    if (!date)
        return luaL_error(L, "gui calendar:getDate: GTK returned no date");
    const int year = detail::glib_date_time_get_year(date);
    const int month = detail::glib_date_time_get_month(date);
    const int day = detail::glib_date_time_get_day_of_month(date);
    detail::glib_date_time_unref(date);
    lua_pushinteger(L, year);
    lua_pushinteger(L, month);
    lua_pushinteger(L, day);
    return 3;
}

int calendar_set_date(lua_State *L)
{
    if (!lua_arity_is(L, 4))
        return luaL_error(L, "gui calendar:setDate expects year, month and day");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::calendar, "gui calendar:setDate");
    int values[3] = {0, 0, 0};
    const char *names[] = {"year", "month", "day"};
    for (int i = 0; i < 3; ++i)
    {
        if (!lua_is_strict_integer(L, i + 2))
            return luaL_error(L, "gui calendar:setDate %s must be an integer", names[i]);
        const lua_Integer candidate = lua_tointeger(L, i + 2);
        if (candidate < INT_MIN || candidate > INT_MAX)
            return luaL_error(L, "gui calendar:setDate %s is out of range", names[i]);
        values[i] = static_cast<int>(candidate);
    }
    if (!valid_gregorian_date(values[0], values[1], values[2]))
        return luaL_error(L, "gui calendar:setDate: invalid Gregorian date");

    void *date = detail::glib_date_time_new_local(
        values[0], values[1], values[2], 12, 0, 0.0);
    if (!date)
        return push_fail_protected(L, "babet.gui: cannot create calendar date");

    retain_state(state);
    void *native = detail::gtk4_object_ref_sink(state->native);
    lua_State *previous = state->callback_thread;
    state->callback_thread = L;
    detail::gtk4_calendar_select_day(native, date);
    state->callback_thread = previous;
    detail::glib_date_time_unref(date);
    detail::gtk4_object_unref(native);
    release_state(state);
    return push_ok_protected(L);
}

int calendar_day_argument(lua_State *L, const char *api)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_integer(L, 2))
        return luaL_error(L, "%s expects one integer day", api);
    const lua_Integer value = lua_tointeger(L, 2);
    if (value < 1 || value > 31)
        return luaL_error(L, "%s day must be between 1 and 31", api);
    return static_cast<int>(value);
}

int calendar_mark_day(lua_State *L)
{
    const int day = calendar_day_argument(L, "gui calendar:markDay");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::calendar, "gui calendar:markDay");
    detail::gtk4_calendar_mark_day(state->native, static_cast<unsigned int>(day));
    return push_ok_protected(L);
}

int calendar_unmark_day(lua_State *L)
{
    const int day = calendar_day_argument(L, "gui calendar:unmarkDay");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::calendar, "gui calendar:unmarkDay");
    detail::gtk4_calendar_unmark_day(state->native, static_cast<unsigned int>(day));
    return push_ok_protected(L);
}

int calendar_clear_marks(lua_State *L)
{
    if (!lua_arity_is(L, 1))
        return luaL_error(L, "gui calendar:clearMarks expects no arguments");
    WidgetState *state = check_kind(
        L, 1, WidgetKind::calendar, "gui calendar:clearMarks");
    detail::gtk4_calendar_clear_marks(state->native);
    return push_ok_protected(L);
}

int calendar_on_view_changed(lua_State *L)
{
    if (!lua_arity_is(L, 2) || (!lua_isnil(L, 2) && lua_type(L, 2) != LUA_TFUNCTION))
        return luaL_error(L, "gui calendar:onViewChanged expects one function or nil");
    (void)check_kind(L, 1, WidgetKind::calendar, "gui calendar:onViewChanged");
    lua_getiuservalue(L, 1, 1);
    lua_pushvalue(L, 2);
    lua_rawseti(L, -2, CALENDAR_VIEW_CALLBACK);
    return push_ok_protected(L);
}

int widget_set_margins(lua_State *L)
{
    if (!lua_arity_is(L, 2) && !lua_arity_is(L, 5))
        return luaL_error(
            L, "gui widget:setMargins expects one margin or top, end, bottom, start");
    WidgetState *state = check_widget(L, 1, "gui widget:setMargins");
    int margins[4] = {0, 0, 0, 0};
    const int count = lua_gettop(L) == 2 ? 1 : 4;
    for (int i = 0; i < count; ++i)
    {
        const int index = i + 2;
        if (!lua_is_strict_integer(L, index))
            return luaL_error(L, "gui widget:setMargins expects non-negative integers");
        const lua_Integer value = lua_tointeger(L, index);
        if (value < 0 || value > INT_MAX)
            return luaL_error(L, "gui widget:setMargins margin is out of range");
        margins[i] = static_cast<int>(value);
    }
    if (count == 1)
        margins[1] = margins[2] = margins[3] = margins[0];
    detail::gtk4_widget_set_margin_top(state->native, margins[0]);
    detail::gtk4_widget_set_margin_end(state->native, margins[1]);
    detail::gtk4_widget_set_margin_bottom(state->native, margins[2]);
    detail::gtk4_widget_set_margin_start(state->native, margins[3]);
    return push_ok_protected(L);
}

int widget_set_h_expand(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui widget:setHExpand expects one boolean");
    WidgetState *state = check_widget(L, 1, "gui widget:setHExpand");
    detail::gtk4_widget_set_hexpand(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int widget_set_v_expand(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui widget:setVExpand expects one boolean");
    WidgetState *state = check_widget(L, 1, "gui widget:setVExpand");
    detail::gtk4_widget_set_vexpand(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int widget_set_visible(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui widget:setVisible expects one boolean");
    WidgetState *state = check_widget(L, 1, "gui widget:setVisible");
    detail::gtk4_widget_set_visible(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int widget_set_sensitive(lua_State *L)
{
    if (!lua_arity_is(L, 2) || !lua_is_strict_boolean(L, 2))
        return luaL_error(L, "gui widget:setSensitive expects one boolean");
    WidgetState *state = check_widget(L, 1, "gui widget:setSensitive");
    detail::gtk4_widget_set_sensitive(state->native, lua_toboolean(L, 2) != 0);
    return push_ok_protected(L);
}

int widget_add_class(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:addClass expects one CSS class name");
    WidgetState *state = check_widget(L, 1, "gui widget:addClass");
    const char *name = nullptr;
    strict_c_string(L, 2, "gui widget:addClass", name);
    if (!name[0])
        return luaL_error(L, "gui widget:addClass: CSS class name cannot be empty");
    detail::gtk4_widget_add_css_class(state->native, name);
    return push_ok_protected(L);
}

int widget_remove_class(lua_State *L)
{
    if (!lua_arity_is(L, 2))
        return luaL_error(L, "gui widget:removeClass expects one CSS class name");
    WidgetState *state = check_widget(L, 1, "gui widget:removeClass");
    const char *name = nullptr;
    strict_c_string(L, 2, "gui widget:removeClass", name);
    if (!name[0])
        return luaL_error(L, "gui widget:removeClass: CSS class name cannot be empty");
    detail::gtk4_widget_remove_css_class(state->native, name);
    return push_ok_protected(L);
}

int l_set_css(lua_State *L)
{
    if (!lua_arity_is(L, 1) || (!lua_isnil(L, 1) && !lua_is_strict_string(L, 1)))
        return luaL_error(L, "gui.setCss expects one CSS string or nil");
    require_gui_initialized(L, "gui.setCss");
    lua_State *owner = main_lua_state(L);

    if (lua_isnil(L, 1))
    {
        clear_css_provider(owner);
        return push_ok_protected(L);
    }

    const char *css = nullptr;
    strict_c_string(L, 1, "gui.setCss", css);
    void *display = detail::gdk4_display_get_default();
    if (!display)
        return push_fail_protected(L, "babet.gui: no default GTK display for CSS");
    void *provider = detail::gtk4_css_provider_new();
    if (!provider)
        return push_fail_protected(L, "babet.gui: cannot create GTK CSS provider");

    detail::gtk4_css_provider_load(provider, css);
    clear_css_provider(owner);
    detail::gtk4_style_context_add_provider_for_display(
        display, provider, CSS_PRIORITY_APPLICATION);
    g_css_provider = provider;
    g_css_display = display;
    g_css_owner = owner;
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
    if (L != main_lua_state(L))
        return luaL_error(
            L,
            "gui.run: must be called from the main Lua thread, not from a coroutine");
    if (g_run_active.load(std::memory_order_acquire))
        return luaL_error(L, "gui.run: GUI event loop is already running");
    if (g_live_windows.load(std::memory_order_acquire) <= 0 && !has_file_dialogs())
        return push_fail_protected(L, "babet.gui: gui.run requires a live window or pending file dialog");
    if (g_gui_owner != main_lua_state(L))
        return push_fail_protected(L, "babet.gui: this Lua state does not own the GUI");
    if (!lua_checkstack(L, 2)) {
        cancel_file_dialogs(main_lua_state(L));
        return push_fail_protected(L, "babet.gui: cannot reserve Lua stack for GUI loop");
    }

    g_quit_requested.store(false, std::memory_order_release);
    g_run_active.store(true, std::memory_order_release);
    const unsigned int wake_source =
        detail::gtk4_timeout_add(GUI_WAKE_INTERVAL_MS, &wake_main_loop, nullptr);
    if (wake_source == 0)
    {
        g_run_active.store(false, std::memory_order_release);
        cancel_file_dialogs(main_lua_state(L));
        return push_fail_protected(L, "babet.gui: cannot install GTK main-loop wake source");
    }

    while (!g_quit_requested.load(std::memory_order_acquire) &&
           (g_live_windows.load(std::memory_order_acquire) > 0 || has_file_dialogs()))
    {
        (void)detail::gtk4_main_context_iteration(true);
        drain_deferred_widgets();

        lua_pushcfunction(L, signal_dispatch_thunk);
        const int status = lua_pcall(L, 0, 0, 0);
        if (status != LUA_OK)
        {
            (void)detail::gtk4_source_remove(wake_source);
            g_run_active.store(false, std::memory_order_release);
            cancel_file_dialogs(main_lua_state(L));
            return lua_error(L);
        }
    }

    (void)detail::gtk4_source_remove(wake_source);
    g_run_active.store(false, std::memory_order_release);
    cancel_file_dialogs(main_lua_state(L));
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

void finalize_widget(WidgetState *state) noexcept
{
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
}

void drain_deferred_widgets() noexcept
{
    if (g_draw_depth != 0)
        return;
    while (g_deferred_widgets)
    {
        WidgetState *state = g_deferred_widgets;
        g_deferred_widgets = state->deferred_next;
        state->deferred_next = nullptr;
        finalize_widget(state);
    }
}

int widget_gc(lua_State *L) noexcept
{
    auto *userdata = static_cast<WidgetUserdata *>(luaL_testudata(L, 1, WIDGET_META));
    if (!userdata || !userdata->state)
        return 0;

    WidgetState *state = userdata->state;
    userdata->state = nullptr;

    state->handle_key = nullptr;

    if (g_draw_depth != 0)
    {
        // Transfer the userdata's logical reference to an allocation-free
        // queue. Destroying even an unrelated widget during GTK snapshot is
        // forbidden; GC may run at any Lua allocation in the draw callback.
        state->deferred_next = g_deferred_widgets;
        g_deferred_widgets = state;
    }
    else
        finalize_widget(state);
    return 0;
}

template <int (*Fn)(lua_State *)>
int gui_lua_boundary(lua_State *L)
{
    if (babet_runtime::is_main_thread())
        drain_deferred_widgets();
    return lua_cfunction_exception_boundary<Fn>(
        L, "babet.gui: out of memory", "babet.gui: internal C++ failure",
        "babet.gui: unknown internal C++ failure");
}

} // namespace

bool session_active() noexcept
{
    return g_run_active.load(std::memory_order_acquire) ||
           g_live_widgets.load(std::memory_order_acquire) > 0 ||
           g_css_provider != nullptr || has_file_dialogs();
}

void cleanup_on_main_thread(lua_State *L) noexcept
{
    if (!L || !babet_runtime::is_main_thread())
        return;

    drain_deferred_widgets();
    lua_State *closing_owner = main_lua_state(L);
    cancel_file_dialogs(closing_owner);
    clear_css_provider(closing_owner);
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
    if (luaL_newmetatable(L, FILE_DIALOG_META)) {
        lua_pushcfunction(L, file_dialog_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushliteral(L, "Babet GUI file selection");
        lua_setfield(L, -2, "__metatable");
    }
    lua_pop(L, 1);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &file_dialog_roots_key);
    if (lua_isnil(L, -1)) {
        lua_pop(L, 1); lua_newtable(L);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &file_dialog_roots_key);
    } else lua_pop(L, 1);
    if (luaL_newmetatable(L, DRAW_META))
    {
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        const luaL_Reg methods[] = {
            {"newPath", gui_lua_boundary<draw_new_path>},
            {"closePath", gui_lua_boundary<draw_close_path>},
            {"stroke", gui_lua_boundary<draw_stroke>},
            {"fill", gui_lua_boundary<draw_fill>},
            {"moveTo", gui_lua_boundary<draw_move_to>},
            {"lineTo", gui_lua_boundary<draw_line_to>},
            {"setLineWidth", gui_lua_boundary<draw_set_line_width>},
            {"setFontSize", gui_lua_boundary<draw_set_font_size>},
            {"setSourceRGB", gui_lua_boundary<draw_set_source_rgb>},
            {"setSourceRGBA", gui_lua_boundary<draw_set_source_rgba>},
            {"rectangle", gui_lua_boundary<draw_rectangle>},
            {"arc", gui_lua_boundary<draw_arc>},
            {"text", gui_lua_boundary<draw_text>},
            {nullptr, nullptr},
        };
        luaL_setfuncs(L, methods, 0);
        lua_pushliteral(L, "Babet GUI drawing context");
        lua_setfield(L, -2, "__metatable");
    }
    lua_pop(L, 1);
    lua_rawgetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    if (lua_isnil(L, -1))
    {
        lua_pop(L, 1);
        lua_newtable(L);
        lua_newtable(L);
        lua_pushliteral(L, "v");
        lua_setfield(L, -2, "__mode");
        lua_setmetatable(L, -2);
        lua_pushvalue(L, -1);
        lua_rawsetp(L, LUA_REGISTRYINDEX, &widget_handles_key);
    }
    lua_pop(L, 1);
    if (luaL_newmetatable(L, WIDGET_META))
    {
        lua_pushvalue(L, -1);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, widget_gc);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, gui_lua_boundary<widget_add>);
        lua_setfield(L, -2, "add");
        lua_pushcfunction(L, gui_lua_boundary<fixed_put>);
        lua_setfield(L, -2, "put");
        lua_pushcfunction(L, gui_lua_boundary<fixed_move>);
        lua_setfield(L, -2, "move");
        lua_pushcfunction(L, gui_lua_boundary<widget_on_drag>);
        lua_setfield(L, -2, "onDrag");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_drag_data>);
        lua_setfield(L, -2, "setDragData");
        lua_pushcfunction(L, gui_lua_boundary<widget_on_drop>);
        lua_setfield(L, -2, "onDrop");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_drag_actions>);
        lua_setfield(L, -2, "setDragActions");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_drop_actions>);
        lua_setfield(L, -2, "setDropActions");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_drop_types>);
        lua_setfield(L, -2, "setDropTypes");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_drag_icon>);
        lua_setfield(L, -2, "setDragIcon");
        lua_pushcfunction(L, gui_lua_boundary<widget_on_drag_state>);
        lua_setfield(L, -2, "onDragState");
        lua_pushcfunction(L, gui_lua_boundary<widget_on_pointer>);
        lua_setfield(L, -2, "onPointer");
        lua_pushcfunction(L, gui_lua_boundary<widget_on_key>);
        lua_setfield(L, -2, "onKey");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_cursor>);
        lua_setfield(L, -2, "setCursor");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_tooltip_text>);
        lua_setfield(L, -2, "setTooltipText");
        lua_pushcfunction(L, gui_lua_boundary<widget_grab_focus>);
        lua_setfield(L, -2, "grabFocus");
        lua_pushcfunction(L, gui_lua_boundary<widget_has_focus>);
        lua_setfield(L, -2, "hasFocus");
        lua_pushcfunction(L, gui_lua_boundary<widget_get_size>);
        lua_setfield(L, -2, "getSize");
        lua_pushcfunction(L, gui_lua_boundary<widget_translate_point>);
        lua_setfield(L, -2, "translatePoint");
        lua_pushcfunction(L, gui_lua_boundary<widget_pick>);
        lua_setfield(L, -2, "pick");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_size_request>);
        lua_setfield(L, -2, "setSizeRequest");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_halign>);
        lua_setfield(L, -2, "setHAlign");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_valign>);
        lua_setfield(L, -2, "setVAlign");
        lua_pushcfunction(L, gui_lua_boundary<picture_set_file>);
        lua_setfield(L, -2, "setFile");
        lua_pushcfunction(L, gui_lua_boundary<picture_set_fit>);
        lua_setfield(L, -2, "setContentFit");
        lua_pushcfunction(L, gui_lua_boundary<picture_set_shrink>);
        lua_setfield(L, -2, "setCanShrink");
        lua_pushcfunction(L, gui_lua_boundary<picture_intrinsic_size>);
        lua_setfield(L, -2, "getIntrinsicSize");
        lua_pushcfunction(L, gui_lua_boundary<picture_set_alt>);
        lua_setfield(L, -2, "setAlternativeText");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_icon_name>);
        lua_setfield(L, -2, "setIconName");
        lua_pushcfunction(L, gui_lua_boundary<widget_remove>);
        lua_setfield(L, -2, "remove");
        lua_pushcfunction(L, gui_lua_boundary<box_reorder>);
        lua_setfield(L, -2, "reorder");
        lua_pushcfunction(L, gui_lua_boundary<widget_clear>);
        lua_setfield(L, -2, "clear");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_text>);
        lua_setfield(L, -2, "setText");
        lua_pushcfunction(L, gui_lua_boundary<entry_get_text>);
        lua_setfield(L, -2, "getText");
        lua_pushcfunction(L, gui_lua_boundary<check_get_active>);
        lua_setfield(L, -2, "getActive");
        lua_pushcfunction(L, gui_lua_boundary<check_set_active>);
        lua_setfield(L, -2, "setActive");
        lua_pushcfunction(L, gui_lua_boundary<progress_get_fraction>);
        lua_setfield(L, -2, "getFraction");
        lua_pushcfunction(L, gui_lua_boundary<progress_set_fraction>);
        lua_setfield(L, -2, "setFraction");
        lua_pushcfunction(L, gui_lua_boundary<progress_show_text>);
        lua_setfield(L, -2, "setShowText");
        lua_pushcfunction(L, gui_lua_boundary<expander_get_expanded>);
        lua_setfield(L, -2, "getExpanded");
        lua_pushcfunction(L, gui_lua_boundary<expander_set_expanded>);
        lua_setfield(L, -2, "setExpanded");
        lua_pushcfunction(L, gui_lua_boundary<entry_set_placeholder>);
        lua_setfield(L, -2, "setPlaceholder");
        lua_pushcfunction(L, gui_lua_boundary<entry_set_editable>);
        lua_setfield(L, -2, "setEditable");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_wrap_mode>);
        lua_setfield(L, -2, "setWrapMode");
        lua_pushcfunction(L, gui_lua_boundary<label_set_wrap>);
        lua_setfield(L, -2, "setWrap");
        lua_pushcfunction(L, gui_lua_boundary<label_set_xalign>);
        lua_setfield(L, -2, "setXAlign");
        lua_pushcfunction(L, gui_lua_boundary<text_create_tag>);
        lua_setfield(L, -2, "createTag");
        lua_pushcfunction(L, gui_lua_boundary<text_apply_tag>);
        lua_setfield(L, -2, "applyTag");
        lua_pushcfunction(L, gui_lua_boundary<text_remove_tag>);
        lua_setfield(L, -2, "removeTag");
        lua_pushcfunction(L, gui_lua_boundary<text_remove_all_tags>);
        lua_setfield(L, -2, "removeAllTags");
        lua_pushcfunction(L, gui_lua_boundary<text_tags_at>);
        lua_setfield(L, -2, "tagsAt");
        lua_pushcfunction(L, gui_lua_boundary<text_tag_range>);
        lua_setfield(L, -2, "tagRange");
        lua_pushcfunction(L, gui_lua_boundary<text_offset_at>);
        lua_setfield(L, -2, "offsetAt");
        lua_pushcfunction(L, gui_lua_boundary<widget_on_changed>);
        lua_setfield(L, -2, "onChanged");
        lua_pushcfunction(L, gui_lua_boundary<entry_on_activate>);
        lua_setfield(L, -2, "onActivate");
        lua_pushcfunction(L, gui_lua_boundary<spin_button_get_value>);
        lua_setfield(L, -2, "getValue");
        lua_pushcfunction(L, gui_lua_boundary<spin_button_set_value>);
        lua_setfield(L, -2, "setValue");
        lua_pushcfunction(L, gui_lua_boundary<calendar_get_date>);
        lua_setfield(L, -2, "getDate");
        lua_pushcfunction(L, gui_lua_boundary<calendar_set_date>);
        lua_setfield(L, -2, "setDate");
        lua_pushcfunction(L, gui_lua_boundary<calendar_mark_day>);
        lua_setfield(L, -2, "markDay");
        lua_pushcfunction(L, gui_lua_boundary<calendar_unmark_day>);
        lua_setfield(L, -2, "unmarkDay");
        lua_pushcfunction(L, gui_lua_boundary<calendar_clear_marks>);
        lua_setfield(L, -2, "clearMarks");
        lua_pushcfunction(L, gui_lua_boundary<calendar_on_view_changed>);
        lua_setfield(L, -2, "onViewChanged");
        lua_pushcfunction(L, gui_lua_boundary<drawing_area_on_draw>);
        lua_setfield(L, -2, "onDraw");
        lua_pushcfunction(L, gui_lua_boundary<drawing_area_queue_draw>);
        lua_setfield(L, -2, "queueDraw");
        lua_pushcfunction(L, gui_lua_boundary<button_on_click>);
        lua_setfield(L, -2, "onClick");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_margins>);
        lua_setfield(L, -2, "setMargins");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_h_expand>);
        lua_setfield(L, -2, "setHExpand");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_v_expand>);
        lua_setfield(L, -2, "setVExpand");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_visible>);
        lua_setfield(L, -2, "setVisible");
        lua_pushcfunction(L, gui_lua_boundary<widget_set_sensitive>);
        lua_setfield(L, -2, "setSensitive");
        lua_pushcfunction(L, gui_lua_boundary<widget_add_class>);
        lua_setfield(L, -2, "addClass");
        lua_pushcfunction(L, gui_lua_boundary<widget_remove_class>);
        lua_setfield(L, -2, "removeClass");
        lua_pushcfunction(L, gui_lua_boundary<paned_get_position>);
        lua_setfield(L, -2, "getPosition");
        lua_pushcfunction(L, gui_lua_boundary<paned_set_position>);
        lua_setfield(L, -2, "setPosition");
        lua_pushcfunction(L, gui_lua_boundary<paned_on_position_changed>);
        lua_setfield(L, -2, "onPositionChanged");
        lua_pushcfunction(L, gui_lua_boundary<menu_button_set_popover>);
        lua_setfield(L, -2, "setPopover");
        lua_pushcfunction(L, gui_lua_boundary<menu_button_popup>);
        lua_setfield(L, -2, "popup");
        lua_pushcfunction(L, gui_lua_boundary<menu_button_popdown>);
        lua_setfield(L, -2, "popdown");
        lua_pushcfunction(L, gui_lua_boundary<popover_attach_to>);
        lua_setfield(L, -2, "attachTo");
        lua_pushcfunction(L, gui_lua_boundary<popover_set_pointing_to>);
        lua_setfield(L, -2, "setPointingTo");
        lua_pushcfunction(L, gui_lua_boundary<window_set_title>);
        lua_setfield(L, -2, "setTitle");
        lua_pushcfunction(L, gui_lua_boundary<window_set_transient_for>);
        lua_setfield(L, -2, "setTransientFor");
        lua_pushcfunction(L, gui_lua_boundary<window_set_modal>);
        lua_setfield(L, -2, "setModal");
        lua_pushcfunction(L, gui_lua_boundary<window_on_close_request>);
        lua_setfield(L, -2, "onCloseRequest");
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
    lua_pushcfunction(L, gui_lua_boundary<l_set_css>);
    lua_setfield(L, -2, "setCss");
    lua_pushcfunction(L, gui_lua_boundary<l_window>);
    lua_setfield(L, -2, "window");
    lua_pushcfunction(L, gui_lua_boundary<l_box>);
    lua_setfield(L, -2, "box");
    lua_pushcfunction(L, gui_lua_boundary<l_separator>);
    lua_setfield(L, -2, "separator");
    lua_pushcfunction(L, gui_lua_boundary<l_paned>);
    lua_setfield(L, -2, "paned");
    lua_pushcfunction(L, gui_lua_boundary<l_picture>);
    lua_setfield(L, -2, "picture");
    lua_pushcfunction(L, gui_lua_boundary<l_open_file>);
    lua_setfield(L, -2, "openFile");
    lua_pushcfunction(L, gui_lua_boundary<l_save_file>);
    lua_setfield(L, -2, "saveFile");
    lua_pushcfunction(L, gui_lua_boundary<l_image>);
    lua_setfield(L, -2, "image");
    lua_pushcfunction(L, gui_lua_boundary<l_menu_button>);
    lua_setfield(L, -2, "menuButton");
    lua_pushcfunction(L, gui_lua_boundary<l_popover>);
    lua_setfield(L, -2, "popover");
    lua_pushcfunction(L, gui_lua_boundary<l_fixed>);
    lua_setfield(L, -2, "fixed");
    lua_pushcfunction(L, gui_lua_boundary<l_text_view>);
    lua_setfield(L, -2, "textView");
    lua_pushcfunction(L, gui_lua_boundary<l_check_button>);
    lua_setfield(L, -2, "checkButton");
    lua_pushcfunction(L, gui_lua_boundary<l_progress_bar>);
    lua_setfield(L, -2, "progressBar");
    lua_pushcfunction(L, gui_lua_boundary<l_expander>);
    lua_setfield(L, -2, "expander");
    lua_pushcfunction(L, gui_lua_boundary<l_scrolled_window>);
    lua_setfield(L, -2, "scrolledWindow");
    lua_pushcfunction(L, gui_lua_boundary<l_label>);
    lua_setfield(L, -2, "label");
    lua_pushcfunction(L, gui_lua_boundary<l_button>);
    lua_setfield(L, -2, "button");
    lua_pushcfunction(L, gui_lua_boundary<l_entry>);
    lua_setfield(L, -2, "entry");
    lua_pushcfunction(L, gui_lua_boundary<l_spin_button>);
    lua_setfield(L, -2, "spinButton");
    lua_pushcfunction(L, gui_lua_boundary<l_calendar>);
    lua_setfield(L, -2, "calendar");
    lua_pushcfunction(L, gui_lua_boundary<l_drawing_area>);
    lua_setfield(L, -2, "drawingArea");
    lua_pushcfunction(L, gui_lua_boundary<l_run>);
    lua_setfield(L, -2, "run");
    lua_pushcfunction(L, gui_lua_boundary<l_quit>);
    lua_setfield(L, -2, "quit");
    lua_pushinteger(L, 1); lua_setfield(L, -2, "MOD_SHIFT");
    lua_pushinteger(L, 4); lua_setfield(L, -2, "MOD_CONTROL");
    lua_pushinteger(L, 8); lua_setfield(L, -2, "MOD_ALT");
    lua_pushinteger(L, static_cast<lua_Integer>(1U << 26)); lua_setfield(L, -2, "MOD_SUPER");
    lua_setfield(L, -2, "gui");
}

} // namespace babet_gui
