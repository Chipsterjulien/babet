#ifndef BABET_GUI_GTK_LOADER_HPP
#define BABET_GUI_GTK_LOADER_HPP

#include <cstddef>
#include <string>

namespace babet_gui::detail
{

// Public ABI layouts from GtkTextIter, GValue and GSList (GTK/GLib 4.0).
// Fields are storage only: native APIs initialize and interpret them.
struct TextIter {
    void *dummy1; void *dummy2;
    int dummy3, dummy4, dummy5, dummy6, dummy7, dummy8;
    void *dummy9; void *dummy10;
    int dummy11, dummy12, dummy13; void *dummy14;
};
struct NativeValue {
    std::size_t type;
    union Data { int i; unsigned int u; long l; unsigned long ul;
                 long long i64; unsigned long long u64; float f; double d; void *p; } data[2];
};
struct NativeSList { void *data; NativeSList *next; };

void * rich_gtk_text_tag_new(const char *a) noexcept;
void * rich_gtk_text_buffer_get_tag_table(void *a) noexcept;
int rich_gtk_text_tag_table_add(void *a, void *b) noexcept;
void * rich_gtk_text_tag_table_lookup(void *a, const char *b) noexcept;
void rich_gtk_text_buffer_get_bounds(void *a, TextIter *b, TextIter *c) noexcept;
char * rich_gtk_text_buffer_get_text(void *a, const TextIter *b, const TextIter *c, int d) noexcept;
void rich_gtk_text_buffer_get_iter_at_offset(void *a, TextIter *b, int c) noexcept;
void rich_gtk_text_buffer_apply_tag(void *a, void *b, const TextIter *c, const TextIter *d) noexcept;
void rich_gtk_text_buffer_remove_tag(void *a, void *b, const TextIter *c, const TextIter *d) noexcept;
void rich_gtk_text_buffer_remove_all_tags(void *a, const TextIter *b, const TextIter *c) noexcept;
int rich_gtk_text_iter_get_offset(const TextIter *a) noexcept;
int rich_gtk_text_iter_has_tag(const TextIter *a, void *b) noexcept;
int rich_gtk_text_iter_starts_tag(const TextIter *a, void *b) noexcept;
int rich_gtk_text_iter_backward_to_tag_toggle(TextIter *a, void *b) noexcept;
int rich_gtk_text_iter_forward_to_tag_toggle(TextIter *a, void *b) noexcept;
void rich_gtk_text_view_window_to_buffer_coords(void *a, int b, int c, int d, int *e, int *f) noexcept;
int rich_gtk_text_view_get_iter_at_location(void *a, TextIter *b, int c, int d) noexcept;
void * rich_g_value_init(NativeValue *a, std::size_t b) noexcept;
void rich_g_value_unset(NativeValue *a) noexcept;
void rich_g_value_set_string(NativeValue *a, const char *b) noexcept;
void rich_g_value_set_int(NativeValue *a, int b) noexcept;
void rich_g_value_set_boolean(NativeValue *a, int b) noexcept;
void rich_g_value_set_double(NativeValue *a, double b) noexcept;
void rich_g_value_set_enum(NativeValue *a, int b) noexcept;
void rich_g_object_set_property(void *a, const char *b, const NativeValue *c) noexcept;
std::ptrdiff_t rich_g_utf8_pointer_to_offset(const char *a, const char *b) noexcept;
void rich_gtk_drop_target_set_gtypes(void *a, const std::size_t *b, std::size_t c) noexcept;
std::size_t rich_gdk_file_list_get_type() noexcept;
const NativeSList * rich_gdk_file_list_get_files(void *a) noexcept;
void * rich_g_value_get_boxed(const void *a) noexcept;
int rich_g_type_check_value_holds(const void *a, std::size_t b) noexcept;
bool gtk4_text_tags_available() noexcept;
bool gtk4_drop_files_available() noexcept;
std::size_t rich_type_from_name(const char *) noexcept;
const void *rich_drop_value(void *) noexcept;

bool rich_value_holds(const void *, std::size_t) noexcept;
void rich_set_drop_types(void *, bool, bool) noexcept;

using GtkCallback = void (*)();
using GtkClosureNotify = void (*)(void *, void *);
using GtkSourceCallback = int (*)(void *);
using GtkDrawCallback = void (*)(void *, void *, int, int, void *);
using GtkDestroyNotify = void (*)(void *);

using GtkAsyncReadyCallback = void (*)(void *, void *, void *);
void * files_gtk_picture_new() noexcept;
void files_gtk_picture_set_paintable(void *a, void *b) noexcept;
void * files_gtk_picture_get_paintable(void *a) noexcept;
void files_gtk_picture_set_can_shrink(void *a, int b) noexcept;
void files_gtk_picture_set_content_fit(void *a, int b) noexcept;
void files_gtk_picture_set_alternative_text(void *a, const char *b) noexcept;
int files_gdk_paintable_get_intrinsic_width(void *a) noexcept;
int files_gdk_paintable_get_intrinsic_height(void *a) noexcept;
void * files_gdk_texture_new_from_filename(const char *a, void **b) noexcept;
void files_g_error_free(void *a) noexcept;
void * files_gtk_file_dialog_new() noexcept;
void files_gtk_file_dialog_set_title(void *a, const char *b) noexcept;
void files_gtk_file_dialog_set_modal(void *a, int b) noexcept;
void files_gtk_file_dialog_set_initial_folder(void *a, void *b) noexcept;
void files_gtk_file_dialog_set_initial_name(void *a, const char *b) noexcept;
void files_gtk_file_dialog_set_filters(void *a, void *b) noexcept;
unsigned int files_gtk_dialog_error_quark() noexcept;
void * files_g_cancellable_new() noexcept;
void files_g_cancellable_cancel(void *a) noexcept;
void * files_g_file_new_for_path(const char *a) noexcept;
char * files_g_file_get_path(void *a) noexcept;
char * files_g_file_get_uri(void *a) noexcept;
void * files_gtk_file_filter_new() noexcept;
std::size_t files_gtk_file_filter_get_type() noexcept;
void files_gtk_file_filter_set_name(void *a, const char *b) noexcept;
void files_gtk_file_filter_add_pattern(void *a, const char *b) noexcept;
void files_gtk_file_filter_add_mime_type(void *a, const char *b) noexcept;
void * files_g_list_store_new(std::size_t a) noexcept;
void files_g_list_store_append(void *a, void *b) noexcept;
unsigned int files_g_list_model_get_n_items(void *a) noexcept;
void * files_g_list_model_get_item(void *a, unsigned int b) noexcept;
void files_gtk_file_dialog_open(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) noexcept;
void * files_gtk_file_dialog_open_finish(void *a, void *b, void **c) noexcept;
void files_gtk_file_dialog_open_multiple(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) noexcept;
void * files_gtk_file_dialog_open_multiple_finish(void *a, void *b, void **c) noexcept;
void files_gtk_file_dialog_save(void *a, void *b, void *c, GtkAsyncReadyCallback cb, void *d) noexcept;
void * files_gtk_file_dialog_save_finish(void *a, void *b, void **c) noexcept;
bool gtk4_picture_available() noexcept;
bool gtk4_texture_file_available() noexcept;
bool gtk4_content_fit_available() noexcept;
bool gtk4_file_dialog_available() noexcept;
const char *gtk4_error_message(void *) noexcept;
bool gtk4_dialog_dismissed(void *) noexcept;

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
void gtk4_window_set_transient_for(void *window, void *parent) noexcept;
void gtk4_window_set_modal(void *window, bool modal) noexcept;
void gtk4_window_set_icon_name(void *window, const char *name) noexcept;

// Additional GTK4 building blocks for freely positioned note boards.
void *gtk4_fixed_new() noexcept;
void gtk4_fixed_put(void *fixed, void *child, double x, double y) noexcept;
void gtk4_fixed_move(void *fixed, void *child, double x, double y) noexcept;
void gtk4_fixed_remove(void *fixed, void *child) noexcept;
void *gtk4_text_view_new() noexcept;
void *gtk4_text_view_get_buffer(void *view) noexcept;
void gtk4_text_buffer_set_text(void *buffer, const char *text) noexcept;
// Allocates a GLib-owned UTF-8 snapshot; free with gtk4_free().
char *gtk4_text_buffer_dup_text(void *buffer) noexcept;
void gtk4_free(void *pointer) noexcept;
void gtk4_text_view_set_editable(void *view, bool editable) noexcept;
void gtk4_text_view_set_wrap_mode(void *view, int mode) noexcept;
void *gtk4_check_button_new_with_label(const char *label) noexcept;
void gtk4_check_button_set_label(void *check, const char *label) noexcept;
void gtk4_check_button_set_active(void *check, bool active) noexcept;
bool gtk4_check_button_get_active(void *check) noexcept;
void *gtk4_progress_bar_new() noexcept;
void gtk4_progress_bar_set_fraction(void *bar, double fraction) noexcept;
double gtk4_progress_bar_get_fraction(void *bar) noexcept;
void gtk4_progress_bar_set_text(void *bar, const char *text) noexcept;
void gtk4_progress_bar_set_show_text(void *bar, bool enabled) noexcept;
void *gtk4_expander_new(const char *label) noexcept;
void gtk4_expander_set_label(void *expander, const char *label) noexcept;
void gtk4_expander_set_child(void *expander, void *child) noexcept;
void gtk4_expander_set_expanded(void *expander, bool expanded) noexcept;
bool gtk4_expander_get_expanded(void *expander) noexcept;
void *gtk4_gesture_drag_new() noexcept;
// Native GTK4 drag-and-drop controllers. Babet intentionally exchanges only
// UTF-8 string payloads here; applications can use stable IDs and keep their
// model/data outside GTK.
void *gtk4_drag_source_new() noexcept;
void gtk4_drag_source_set_move_action(void *source) noexcept;
void gtk4_drag_source_set_actions(void *source, unsigned int actions) noexcept;
bool gtk4_drag_source_set_widget_icon(void *source, void *widget) noexcept;
bool gtk4_drag_source_set_text(void *source, const char *text) noexcept;
void *gtk4_drop_target_new_text_move() noexcept;
void *gtk4_drop_target_new_text(unsigned int actions) noexcept;
void gtk4_drop_target_set_actions(void *target, unsigned int actions) noexcept;
void gtk4_drop_target_set_preload(void *target, bool preload) noexcept;
void gtk4_drop_target_set_enabled(void *target, bool enabled) noexcept;
void gtk4_drop_target_reject(void *target) noexcept;
const char *gtk4_drop_target_text(void *target) noexcept;
const char *gtk4_value_text(const void *value) noexcept;
unsigned int gtk4_drag_action_copy() noexcept;
unsigned int gtk4_drag_action_move() noexcept;
unsigned int gtk4_drag_action_link() noexcept;
unsigned int gtk4_drop_target_selected_action(void *target) noexcept;
unsigned int gtk4_drop_target_offered_actions(void *target) noexcept;
void *gtk4_drop_target_current_drop(void *target) noexcept;
void *gtk4_drop_target_drag(void *target) noexcept;
unsigned int gdk4_drag_selected_action(void *drag) noexcept;
bool gtk4_utf8_valid(const char *text, std::size_t length) noexcept;
// GdkEvent positions are surface-relative, unlike GtkGestureDrag offsets.
// The stable event surface makes moving a gesture's own widget safe.
bool gtk4_gesture_surface_position(void *gesture, double &x, double &y) noexcept;
void gtk4_widget_set_size_request(void *widget, int width, int height) noexcept;
void gtk4_widget_set_cursor_name(void *widget, const char *name) noexcept;
void gtk4_widget_set_tooltip_text(void *widget, const char *text) noexcept;
bool gtk4_widget_grab_focus(void *widget) noexcept;
bool gtk4_widget_has_focus(void *widget) noexcept;
bool gtk4_widget_get_mapped(void *widget) noexcept;
int gtk4_widget_get_width(void *widget) noexcept;
int gtk4_widget_get_height(void *widget) noexcept;
bool gtk4_widget_compute_point(void *widget, void *target, double x, double y,
                               double &out_x, double &out_y) noexcept;
void *gtk4_widget_pick(void *widget, double x, double y) noexcept;
void gtk4_widget_set_halign(void *widget, int align) noexcept;
void gtk4_widget_set_valign(void *widget, int align) noexcept;

void *gtk4_event_controller_motion_new() noexcept;
void *gtk4_event_controller_key_new() noexcept;
unsigned int gtk4_event_controller_current_state(void *controller) noexcept;
void gtk4_event_controller_set_propagation_phase(void *controller, int phase) noexcept;
const char *gdk4_keyval_name(unsigned int keyval) noexcept;

void *gtk4_box_new(int orientation, int spacing) noexcept;
void *gtk4_separator_new(int orientation) noexcept;
void *gtk4_paned_new(int orientation) noexcept;
void gtk4_paned_set_start_child(void *paned, void *child) noexcept;
void gtk4_paned_set_end_child(void *paned, void *child) noexcept;
void gtk4_paned_set_position(void *paned, int position) noexcept;
int gtk4_paned_get_position(void *paned) noexcept;
void gtk4_paned_set_resize_start(void *paned, bool enabled) noexcept;
void gtk4_paned_set_resize_end(void *paned, bool enabled) noexcept;
void gtk4_paned_set_shrink_start(void *paned, bool enabled) noexcept;
void gtk4_paned_set_shrink_end(void *paned, bool enabled) noexcept;
void gtk4_paned_set_wide_handle(void *paned, bool enabled) noexcept;
void gtk4_box_append(void *box, void *child) noexcept;
void gtk4_box_remove(void *box, void *child) noexcept;
// Native in-place GtkBox reordering (no unparenting or refcount churn).
void gtk4_box_reorder_child_after(void *box, void *child, void *sibling) noexcept;
void *gtk4_scrolled_window_new() noexcept;
void gtk4_scrolled_window_set_child(void *scrolled, void *child) noexcept;
void *gtk4_label_new(const char *text) noexcept;
void *gtk4_image_new_from_icon_name(const char *icon_name) noexcept;
void gtk4_image_set_from_icon_name(void *image, const char *icon_name) noexcept;
void gtk4_label_set_text(void *label, const char *text) noexcept;
void gtk4_label_set_wrap(void *label, bool wrap) noexcept;
void gtk4_label_set_wrap_mode(void *label, int mode) noexcept;
void gtk4_label_set_xalign(void *label, float alignment) noexcept;
void *gtk4_button_new_with_label(const char *text) noexcept;
void gtk4_button_set_label(void *button, const char *text) noexcept;
void gtk4_button_set_icon_name(void *button, const char *icon_name) noexcept;
void *gtk4_menu_button_new() noexcept;
void gtk4_menu_button_set_label(void *button, const char *label) noexcept;
void gtk4_menu_button_set_icon_name(void *button, const char *icon_name) noexcept;
void gtk4_menu_button_set_popover(void *button, void *popover) noexcept;
void gtk4_menu_button_popup(void *button) noexcept;
void gtk4_menu_button_popdown(void *button) noexcept;
void *gtk4_popover_new() noexcept;
void gtk4_popover_set_child(void *popover, void *child) noexcept;
void gtk4_popover_set_has_arrow(void *popover, bool enabled) noexcept;
void gtk4_popover_set_autohide(void *popover, bool enabled) noexcept;
void gtk4_popover_set_position(void *popover, int position) noexcept;
void gtk4_popover_set_pointing_to(void *popover, int x, int y, int width, int height) noexcept;
void gtk4_popover_popup(void *popover) noexcept;
void gtk4_popover_popdown(void *popover) noexcept;
void gtk4_popover_present(void *popover) noexcept;
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
void gtk4_calendar_mark_day(void *calendar, unsigned int day) noexcept;
void gtk4_calendar_unmark_day(void *calendar, unsigned int day) noexcept;
void gtk4_calendar_clear_marks(void *calendar) noexcept;
void *glib_date_time_new_local(int year, int month, int day, int hour, int minute, double seconds) noexcept;
int glib_date_time_get_year(void *date_time) noexcept;
int glib_date_time_get_month(void *date_time) noexcept;
int glib_date_time_get_day_of_month(void *date_time) noexcept;
void glib_date_time_unref(void *date_time) noexcept;
void * gtk4_drawing_area_new() noexcept;
void gtk4_drawing_area_set_content_width(void *w, int width) noexcept;
void gtk4_drawing_area_set_content_height(void *w, int height) noexcept;
void gtk4_drawing_area_set_draw_func(void *w, GtkDrawCallback cb, void *data, GtkDestroyNotify notify) noexcept;
void *gtk4_gesture_click_new() noexcept;
void gtk4_gesture_single_set_button(void *gesture, unsigned int button) noexcept;
unsigned int gtk4_gesture_single_get_current_button(void *gesture) noexcept;
void gtk4_widget_add_controller(void *widget, void *controller) noexcept;
void gtk4_widget_queue_draw(void *w) noexcept;
void gtk4_widget_set_margin_top(void *w, int margin) noexcept;
void gtk4_widget_set_margin_bottom(void *w, int margin) noexcept;
void gtk4_widget_set_margin_start(void *w, int margin) noexcept;
void gtk4_widget_set_margin_end(void *w, int margin) noexcept;
void gtk4_widget_set_hexpand(void *w, bool expand) noexcept;
void gtk4_widget_set_vexpand(void *w, bool expand) noexcept;
void gtk4_widget_set_visible(void *w, bool visible) noexcept;
void gtk4_widget_set_sensitive(void *w, bool sensitive) noexcept;
void *gtk4_css_provider_new() noexcept;
void gtk4_css_provider_load(void *provider, const char *css) noexcept;
void *gdk4_display_get_default() noexcept;
void gtk4_style_context_add_provider_for_display(void *display, void *provider,
                                                 unsigned int priority) noexcept;
void gtk4_style_context_remove_provider_for_display(void *display, void *provider) noexcept;
void gtk4_widget_add_css_class(void *w, const char *css_class) noexcept;
void gtk4_widget_remove_css_class(void *w, const char *css_class) noexcept;
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
void gtk4_widget_set_parent(void *widget, void *parent) noexcept;
void gtk4_widget_unparent(void *widget) noexcept;

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
