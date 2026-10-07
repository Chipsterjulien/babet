#ifndef BABET_GUI_GTK_LOADER_HPP
#define BABET_GUI_GTK_LOADER_HPP

#include <string>

namespace babet_gui::detail
{

using GtkCallback = void (*)();
using GtkClosureNotify = void (*)(void *, void *);
using GtkSourceCallback = int (*)(void *);
using GtkDrawCallback = void (*)(void *, void *, int, int, void *);
using GtkDestroyNotify = void (*)(void *);

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
void gtk4_box_remove(void *box, void *child) noexcept;
void *gtk4_scrolled_window_new() noexcept;
void gtk4_scrolled_window_set_child(void *scrolled, void *child) noexcept;
void *gtk4_label_new(const char *text) noexcept;
void gtk4_label_set_text(void *label, const char *text) noexcept;
void *gtk4_button_new_with_label(const char *text) noexcept;
void gtk4_button_set_label(void *button, const char *text) noexcept;
void *gtk4_entry_new() noexcept;
void gtk4_entry_set_placeholder(void *entry, const char *text) noexcept;
void gtk4_editable_set_text(void *entry, const char *text) noexcept;
const char *gtk4_editable_get_text(void *entry) noexcept;
void gtk4_editable_set_editable(void *entry, bool editable) noexcept;
void *gtk4_spin_button_new_with_range(double minimum, double maximum, double step) noexcept;
double gtk4_spin_button_get_value(void *spin) noexcept;
void gtk4_spin_button_set_value(void *spin, double value) noexcept;
void gtk4_spin_button_set_digits(void *spin, unsigned int digits) noexcept;
void gtk4_spin_button_set_numeric(void *spin, bool numeric) noexcept;
void *gtk4_calendar_new() noexcept;
void *gtk4_calendar_get_date(void *calendar) noexcept;
void gtk4_calendar_select_day(void *calendar, void *date_time) noexcept;
void *glib_date_time_new_local(int year, int month, int day, int hour, int minute, double seconds) noexcept;
int glib_date_time_get_year(void *date_time) noexcept;
int glib_date_time_get_month(void *date_time) noexcept;
int glib_date_time_get_day_of_month(void *date_time) noexcept;
void glib_date_time_unref(void *date_time) noexcept;
void * gtk4_drawing_area_new() noexcept;
void gtk4_drawing_area_set_content_width(void *w, int width) noexcept;
void gtk4_drawing_area_set_content_height(void *w, int height) noexcept;
void gtk4_drawing_area_set_draw_func(void *w, GtkDrawCallback cb, void *data, GtkDestroyNotify notify) noexcept;
void gtk4_widget_queue_draw(void *w) noexcept;
void gtk4_widget_set_margin_top(void *w, int margin) noexcept;
void gtk4_widget_set_margin_bottom(void *w, int margin) noexcept;
void gtk4_widget_set_margin_start(void *w, int margin) noexcept;
void gtk4_widget_set_margin_end(void *w, int margin) noexcept;
void gtk4_widget_set_hexpand(void *w, bool expand) noexcept;
void gtk4_widget_set_vexpand(void *w, bool expand) noexcept;
void gtk4_widget_set_visible(void *w, bool visible) noexcept;
void gtk4_widget_set_sensitive(void *w, bool sensitive) noexcept;
int cairo_status(void *cr) noexcept;
const char * cairo_status_to_string(int status) noexcept;
void cairo_save(void *cr) noexcept;
void cairo_restore(void *cr) noexcept;
void cairo_new_path(void *cr) noexcept;
void cairo_close_path(void *cr) noexcept;
void cairo_stroke(void *cr) noexcept;
void cairo_fill(void *cr) noexcept;
void cairo_move_to(void *cr, double x, double y) noexcept;
void cairo_line_to(void *cr, double x, double y) noexcept;
void cairo_rectangle(void *cr, double x, double y, double width, double height) noexcept;
void cairo_arc(void *cr, double x, double y, double radius, double start, double end) noexcept;
void cairo_set_line_width(void *cr, double width) noexcept;
void cairo_set_source_rgb(void *cr, double r, double g, double b) noexcept;
void cairo_set_source_rgba(void *cr, double r, double g, double b, double a) noexcept;
void cairo_set_font_size(void *cr, double size) noexcept;
void cairo_show_text(void *cr, const char *text) noexcept;

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
