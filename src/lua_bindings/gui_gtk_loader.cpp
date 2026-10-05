#include "gui_gtk_loader.hpp"
#include "process_state.hpp"

#include <cstring>
#include <dlfcn.h>
#include <string>
#include <string_view>

namespace babet_gui::detail
{
namespace
{

constexpr const char *GTK4_SONAME = "libgtk-4.so.1";

using GtkDisableSetlocale = void (*)();
using GtkInitCheck = int (*)();
using GtkWindowNew = void *(*)();
using GtkWindowSetTitle = void (*)(void *, const char *);
using GtkWindowSetDefaultSize = void (*)(void *, int, int);
using GtkWindowSetChild = void (*)(void *, void *);
using GtkWindowPresent = void (*)(void *);
using GtkWindowDestroy = void (*)(void *);
using GtkBoxNew = void *(*)(int, int);
using GtkBoxAppend = void (*)(void *, void *);
using GtkLabelNew = void *(*)(const char *);
using GtkLabelSetText = void (*)(void *, const char *);
using GtkButtonNewWithLabel = void *(*)(const char *);
using GtkButtonSetLabel = void (*)(void *, const char *);
using GtkWidgetGetParent = void *(*)(void *);
using GObjectRefSink = void *(*)(void *);
using GObjectUnref = void (*)(void *);
using GSignalConnectData = unsigned long (*)(void *, const char *, GtkCallback,
                                             void *, GtkClosureNotify,
                                             unsigned int);
using GMainContextIteration = int (*)(void *, int);
using GTimeoutAdd = unsigned int (*)(unsigned int, GtkSourceCallback, void *);
using GSourceRemove = int (*)(unsigned int);

struct GtkApi
{
    void *handle = nullptr;
    GtkDisableSetlocale disable_setlocale = nullptr;
    GtkInitCheck init_check = nullptr;
    GtkWindowNew window_new = nullptr;
    GtkWindowSetTitle window_set_title = nullptr;
    GtkWindowSetDefaultSize window_set_default_size = nullptr;
    GtkWindowSetChild window_set_child = nullptr;
    GtkWindowPresent window_present = nullptr;
    GtkWindowDestroy window_destroy = nullptr;
    GtkBoxNew box_new = nullptr;
    GtkBoxAppend box_append = nullptr;
    GtkLabelNew label_new = nullptr;
    GtkLabelSetText label_set_text = nullptr;
    GtkButtonNewWithLabel button_new_with_label = nullptr;
    GtkButtonSetLabel button_set_label = nullptr;
    GtkWidgetGetParent widget_get_parent = nullptr;
    GObjectRefSink object_ref_sink = nullptr;
    GObjectUnref object_unref = nullptr;
    GSignalConnectData signal_connect_data = nullptr;
    GMainContextIteration main_context_iteration = nullptr;
    GTimeoutAdd timeout_add = nullptr;
    GSourceRemove source_remove = nullptr;
};

GtkApi g_gtk;

enum class GtkLoadState
{
    not_attempted,
    loaded,
    failed,
};

GtkLoadState g_load_state = GtkLoadState::not_attempted;
void *g_resident_handle = nullptr;
std::string g_load_error;

std::string install_diagnostic(std::string_view detail)
{
    std::string message =
        "babet.gui: GTK 4 is required by this application but was not found or "
        "is unusable. Install the GTK 4 runtime, for example:\n"
        "  Debian/Ubuntu : sudo apt install libgtk-4-1\n"
        "  Arch Linux    : sudo pacman -S gtk4\n"
        "  Fedora        : sudo dnf install gtk4";
    if (!detail.empty())
    {
        message += "\nLoader detail: ";
        message.append(detail.data(), detail.size());
    }
    return message;
}

template <typename Function>
bool resolve(void *handle, const char *name, Function &function,
             std::string &error)
{
    static_assert(sizeof(Function) == sizeof(void *),
                  "GTK loader requires POSIX-sized function pointers");
    (void)::dlerror();
    void *symbol = ::dlsym(handle, name);
    const char *detail = ::dlerror();
    if (detail != nullptr || symbol == nullptr)
    {
        error = "missing GTK 4 dependency symbol '";
        error += name;
        error += "'";
        if (detail && *detail)
        {
            error += ": ";
            error += detail;
        }
        return false;
    }
    std::memcpy(&function, &symbol, sizeof(symbol));
    return true;
}

#define BABET_GTK_RESOLVE(member, symbol)                                      \
    if (!resolve(handle, symbol, candidate.member, symbol_error))              \
        goto symbol_failure

} // namespace

bool gtk4_load(std::string &error)
{
    error.clear();
    if (g_load_state == GtkLoadState::loaded)
        return true;
    if (g_load_state == GtkLoadState::failed)
    {
        error = g_load_error;
        return false;
    }

    // dlopen can run constructors, and GTK initialization can start native
    // threads independently of workers.spawn. Freeze before either runs,
    // without holding the guard across dlopen or GTK callbacks. Keep the
    // freeze on every failure: partial native initialization is not rolled back.
    babet_runtime::freeze_process_state();
    (void)::dlerror();
    void *handle = ::dlopen(GTK4_SONAME, RTLD_NOW | RTLD_LOCAL);
    if (!handle)
    {
        const char *detail = ::dlerror();
        g_load_error = install_diagnostic(detail ? detail : "dlopen failed");
        g_load_state = GtkLoadState::failed;
        error = g_load_error;
        return false;
    }

    // A successfully opened GTK DSO is deliberately kept resident for the
    // lifetime of the process, even if symbol validation subsequently fails.
    // GTK/GLib may install process-wide state while the DSO is being loaded;
    // unloading a partially validated runtime is therefore not a supported
    // recovery strategy. Remembering the failed state also prevents repeated
    // dlopen() calls from incrementing the loader reference count.
    g_resident_handle = handle;

    GtkApi candidate;
    candidate.handle = handle;
    std::string symbol_error;

    BABET_GTK_RESOLVE(disable_setlocale, "gtk_disable_setlocale");
    BABET_GTK_RESOLVE(init_check, "gtk_init_check");
    BABET_GTK_RESOLVE(window_new, "gtk_window_new");
    BABET_GTK_RESOLVE(window_set_title, "gtk_window_set_title");
    BABET_GTK_RESOLVE(window_set_default_size, "gtk_window_set_default_size");
    BABET_GTK_RESOLVE(window_set_child, "gtk_window_set_child");
    BABET_GTK_RESOLVE(window_present, "gtk_window_present");
    BABET_GTK_RESOLVE(window_destroy, "gtk_window_destroy");
    BABET_GTK_RESOLVE(box_new, "gtk_box_new");
    BABET_GTK_RESOLVE(box_append, "gtk_box_append");
    BABET_GTK_RESOLVE(label_new, "gtk_label_new");
    BABET_GTK_RESOLVE(label_set_text, "gtk_label_set_text");
    BABET_GTK_RESOLVE(button_new_with_label, "gtk_button_new_with_label");
    BABET_GTK_RESOLVE(button_set_label, "gtk_button_set_label");
    BABET_GTK_RESOLVE(widget_get_parent, "gtk_widget_get_parent");
    BABET_GTK_RESOLVE(object_ref_sink, "g_object_ref_sink");
    BABET_GTK_RESOLVE(object_unref, "g_object_unref");
    BABET_GTK_RESOLVE(signal_connect_data, "g_signal_connect_data");
    BABET_GTK_RESOLVE(main_context_iteration, "g_main_context_iteration");
    BABET_GTK_RESOLVE(timeout_add, "g_timeout_add");
    BABET_GTK_RESOLVE(source_remove, "g_source_remove");

    g_gtk = candidate;
    g_load_state = GtkLoadState::loaded;
    return true;

symbol_failure:
    g_load_error = install_diagnostic(symbol_error);
    g_load_state = GtkLoadState::failed;
    error = g_load_error;
    return false;
}

#undef BABET_GTK_RESOLVE

bool gtk4_initialize(std::string &error)
{
    if (!gtk4_load(error))
        return false;
    g_gtk.disable_setlocale();
    if (g_gtk.init_check() == 0)
    {
        error =
            "babet.gui: GTK 4 is installed but no usable graphical display "
            "could be initialized (check DISPLAY/WAYLAND_DISPLAY and the "
            "desktop session)";
        return false;
    }
    error.clear();
    return true;
}

bool gtk4_loaded() noexcept { return g_gtk.handle != nullptr; }

void *gtk4_window_new() noexcept { return g_gtk.window_new(); }
void gtk4_window_set_title(void *w, const char *t) noexcept { g_gtk.window_set_title(w, t); }
void gtk4_window_set_default_size(void *w, int x, int y) noexcept { g_gtk.window_set_default_size(w, x, y); }
void gtk4_window_set_child(void *w, void *c) noexcept { g_gtk.window_set_child(w, c); }
void gtk4_window_present(void *w) noexcept { g_gtk.window_present(w); }
void gtk4_window_destroy(void *w) noexcept { g_gtk.window_destroy(w); }
void *gtk4_box_new(int o, int s) noexcept { return g_gtk.box_new(o, s); }
void gtk4_box_append(void *b, void *c) noexcept { g_gtk.box_append(b, c); }
void *gtk4_label_new(const char *t) noexcept { return g_gtk.label_new(t); }
void gtk4_label_set_text(void *l, const char *t) noexcept { g_gtk.label_set_text(l, t); }
void *gtk4_button_new_with_label(const char *t) noexcept { return g_gtk.button_new_with_label(t); }
void gtk4_button_set_label(void *b, const char *t) noexcept { g_gtk.button_set_label(b, t); }
void *gtk4_widget_get_parent(void *w) noexcept { return g_gtk.widget_get_parent(w); }
void *gtk4_object_ref_sink(void *o) noexcept { return g_gtk.object_ref_sink(o); }
void gtk4_object_unref(void *o) noexcept { g_gtk.object_unref(o); }
unsigned long gtk4_signal_connect(void *i, const char *s, GtkCallback c, void *d,
                                  GtkClosureNotify n) noexcept
{
    return g_gtk.signal_connect_data(i, s, c, d, n, 0U);
}
int gtk4_main_context_iteration(bool block) noexcept
{
    return g_gtk.main_context_iteration(nullptr, block ? 1 : 0);
}
unsigned int gtk4_timeout_add(unsigned int ms, GtkSourceCallback cb, void *d) noexcept
{
    return g_gtk.timeout_add(ms, cb, d);
}
bool gtk4_source_remove(unsigned int id) noexcept { return g_gtk.source_remove(id) != 0; }

} // namespace babet_gui::detail
