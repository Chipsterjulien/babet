#ifndef BABET_GUI_GTK_LOADER_HPP
#define BABET_GUI_GTK_LOADER_HPP

#include <string>

namespace babet_gui::detail
{

using GtkCallback = void (*)();
using GtkClosureNotify = void (*)(void *, void *);
using GtkSourceCallback = int (*)(void *);

// Charge libgtk-4.so.1 et résout uniquement la surface GTK/GLib nécessaire au
// binding courant. N'initialise pas GTK et ne modifie pas la locale.
bool gtk4_load(std::string &error);

// Initialise GTK avec la politique Babet : disable_setlocale avant init_check.
bool gtk4_initialize(std::string &error);
bool gtk4_loaded() noexcept;

// Surface GTK 4 volontairement étroite. Les types toolkit restent opaques dans
// Babet : aucune structure ou classe GTK ne traverse ce pont interne.
void *gtk4_window_new() noexcept;
void gtk4_window_set_title(void *window, const char *title) noexcept;
void gtk4_window_set_default_size(void *window, int width, int height) noexcept;
void gtk4_window_set_child(void *window, void *child) noexcept;
void gtk4_window_present(void *window) noexcept;
void gtk4_window_destroy(void *window) noexcept;

void *gtk4_box_new(int orientation, int spacing) noexcept;
void gtk4_box_append(void *box, void *child) noexcept;
void *gtk4_label_new(const char *text) noexcept;
void gtk4_label_set_text(void *label, const char *text) noexcept;
void *gtk4_button_new_with_label(const char *text) noexcept;
void gtk4_button_set_label(void *button, const char *text) noexcept;
void *gtk4_entry_new() noexcept;
void gtk4_entry_set_placeholder(void *entry, const char *text) noexcept;
void gtk4_editable_set_text(void *entry, const char *text) noexcept;
const char *gtk4_editable_get_text(void *entry) noexcept;
void gtk4_editable_set_editable(void *entry, bool editable) noexcept;
void *gtk4_widget_get_parent(void *widget) noexcept;

void *gtk4_object_ref_sink(void *object) noexcept;
void gtk4_object_unref(void *object) noexcept;
unsigned long gtk4_signal_connect(void *instance, const char *signal,
                                  GtkCallback callback, void *data,
                                  GtkClosureNotify destroy_data) noexcept;

int gtk4_main_context_iteration(bool may_block) noexcept;
unsigned int gtk4_timeout_add(unsigned int milliseconds,
                              GtkSourceCallback callback, void *data) noexcept;
bool gtk4_source_remove(unsigned int source_id) noexcept;

} // namespace babet_gui::detail

#endif // BABET_GUI_GTK_LOADER_HPP
