#include <stddef.h>
#include <stdlib.h>
#include "fake_cairo.inc"

typedef void (*FakeCallback)(void);
typedef void (*FakeClosureNotify)(void *, void *);
typedef int (*FakeSourceCallback)(void *);

typedef struct FakeDateTime {
    int year, month, day;
} FakeDateTime;

void *g_date_time_new_local(int y, int m, int d, int h, int min, double sec)
{
    (void)h; (void)min; (void)sec;
    FakeDateTime *date = (FakeDateTime *)malloc(sizeof(*date));
    if (!date) return NULL;
    date->year = y; date->month = m; date->day = d;
    return date;
}
int g_date_time_get_year(void *p) { return ((FakeDateTime *)p)->year; }
int g_date_time_get_month(void *p) { return ((FakeDateTime *)p)->month; }
int g_date_time_get_day_of_month(void *p) { return ((FakeDateTime *)p)->day; }
void g_date_time_unref(void *p) { free(p); }


void *gtk_fixed_new(void) { return (void *)0x11; }
void gtk_fixed_put(void *f, void *c, double x, double y) { (void)f; (void)c; (void)x; (void)y; }
void gtk_fixed_move(void *f, void *c, double x, double y) { (void)f; (void)c; (void)x; (void)y; }
void gtk_fixed_remove(void *f, void *c) { (void)f; (void)c; }
void *gtk_text_view_new(void) { return (void *)0x12; }
void *gtk_text_view_get_buffer(void *v) { (void)v; return (void *)0x13; }
void gtk_text_buffer_set_text(void *b, const char *s, int n) { (void)b; (void)s; (void)n; }
void g_object_get(void *b, const char *name, ...) { (void)b; (void)name; }
void g_free(void *p) { (void)p; }
void gtk_text_view_set_editable(void *v, int e) { (void)v; (void)e; }
void gtk_text_view_set_wrap_mode(void *v, int mode) { (void)v; (void)mode; }
void *gtk_check_button_new_with_label(const char *l) { (void)l; return (void *)0x14; }
void gtk_check_button_set_label(void *c, const char *l) { (void)c; (void)l; }
void gtk_check_button_set_active(void *c, int active) { (void)c; (void)active; }
int gtk_check_button_get_active(void *c) { (void)c; return 0; }
void *gtk_progress_bar_new(void) { return (void *)0x15; }
void gtk_progress_bar_set_fraction(void *p, double n) { (void)p; (void)n; }
double gtk_progress_bar_get_fraction(void *p) { (void)p; return 0; }
void gtk_progress_bar_set_text(void *p, const char *s) { (void)p; (void)s; }
void gtk_progress_bar_set_show_text(void *p, int b) { (void)p; (void)b; }
void *gtk_expander_new(const char *s) { (void)s; return (void *)0x16; }
void gtk_expander_set_label(void *p, const char *s) { (void)p; (void)s; }
void gtk_expander_set_child(void *p, void *c) { (void)p; (void)c; }
void gtk_expander_set_expanded(void *p, int b) { (void)p; (void)b; }
int gtk_expander_get_expanded(void *p) { (void)p; return 0; }
void *gtk_gesture_drag_new(void) { return (void *)0x17; }
size_t g_type_from_name(const char *name) { (void)name; return (size_t)64; }
int g_utf8_validate(const char *s, long n, const char **end) { (void)s; (void)n; (void)end; return 1; }
const char *g_value_get_string(const void *value) { (void)value; return "fake-dnd"; }
void *gdk_content_provider_new_typed(size_t type, ...) { (void)type; return (void *)0x18; }
void *gtk_widget_paintable_new(void *w) { (void)w; return (void *)0x1b; }
void gtk_drag_source_set_icon(void *s, void *p, int x, int y) { (void)s; (void)p; (void)x; (void)y; }
void *gtk_drag_source_new(void) { return (void *)0x19; }
void gtk_drag_source_set_actions(void *s, unsigned int a) { (void)s; (void)a; }
void gtk_drag_source_set_content(void *s, void *c) { (void)s; (void)c; }
void *gtk_drop_target_new(size_t type, unsigned int a) { (void)type; (void)a; return (void *)0x1a; }
void gtk_drop_target_set_preload(void *t, int p) { (void)t; (void)p; }
void gtk_drop_target_set_actions(void *t, unsigned int a) { (void)t; (void)a; }
void gtk_drop_target_reject(void *t) { (void)t; }
const void *gtk_drop_target_get_value(void *t) { (void)t; return NULL; }
void *gtk_drop_target_get_drop(void *t) { return t; }
void *gdk_drop_get_drag(void *d) { return d; }
unsigned int gdk_drop_get_actions(void *d) { (void)d; return 7U; }
unsigned int gdk_drag_get_selected_action(void *d) { (void)d; return 2U; }
void *gtk_gesture_single_get_current_sequence(void *g) { (void)g; return NULL; }
void *gtk_gesture_get_last_event(void *g, void *seq) { (void)seq; return g; }
int gdk_event_get_position(void *event, double *x, double *y)
{ (void)event; *x = 0; *y = 0; return 1; }
void gtk_widget_set_size_request(void *p, int w, int h) { (void)p; (void)w; (void)h; }
void gtk_widget_set_cursor_from_name(void *p, const char *name) { (void)p; (void)name; }
void gtk_widget_set_tooltip_text(void *p, const char *text) { (void)p; (void)text; }
int gtk_widget_grab_focus(void *p) { (void)p; return 1; }
int gtk_widget_has_focus(void *p) { (void)p; return 1; }
int gtk_widget_get_mapped(void *p) { return p != NULL; }
int gtk_widget_get_width(void *p) { (void)p; return 100; }
int gtk_widget_get_height(void *p) { (void)p; return 30; }
typedef struct FakeGraphenePoint { float x, y; } FakeGraphenePoint;
int gtk_widget_compute_point(void *p, void *target, const FakeGraphenePoint *in, FakeGraphenePoint *out)
{ (void)p; (void)target; if (!in || !out) return 0; *out = *in; return 1; }
void *gtk_widget_pick(void *p, double x, double y, unsigned int flags)
{ (void)x; (void)y; (void)flags; return p; }
void gtk_widget_set_halign(void *p, int a) { (void)p; (void)a; }
void gtk_widget_set_valign(void *p, int a) { (void)p; (void)a; }
void *gtk_event_controller_motion_new(void) { return (void *)0x1c; }
void *gtk_event_controller_key_new(void) { return (void *)0x1d; }
unsigned int gtk_event_controller_get_current_event_state(void *p) { (void)p; return 0U; }
void gtk_event_controller_set_propagation_phase(void *p, int phase) { (void)p; (void)phase; }
const char *gdk_keyval_name(unsigned int keyval) { (void)keyval; return "Escape"; }

void *gtk_window_new(void) { return (void *)0x1; }
void gtk_window_set_title(void *w, const char *t) { (void)w; (void)t; }
void gtk_window_set_default_size(void *w, int x, int y) { (void)w; (void)x; (void)y; }
void gtk_window_set_child(void *w, void *c) { (void)w; (void)c; }
void gtk_window_present(void *w) { (void)w; }
void gtk_window_destroy(void *w) { (void)w; }
void gtk_window_set_transient_for(void *w, void *p) { (void)w; (void)p; }
void gtk_window_set_modal(void *w, int modal) { (void)w; (void)modal; }
void gtk_window_set_icon_name(void *w, const char *name) { (void)w; (void)name; }
void *gtk_box_new(int o, int s) { (void)o; (void)s; return (void *)0x2; }
void *gtk_separator_new(int o) { (void)o; return (void *)0x20; }
void *gtk_paned_new(int o) { (void)o; return (void *)0x21; }
void gtk_paned_set_start_child(void *p, void *c) { (void)p; (void)c; }
void gtk_paned_set_end_child(void *p, void *c) { (void)p; (void)c; }
void gtk_paned_set_position(void *p, int pos) { (void)p; (void)pos; }
int gtk_paned_get_position(void *p) { (void)p; return 180; }
void gtk_paned_set_resize_start_child(void *p, int v) { (void)p; (void)v; }
void gtk_paned_set_resize_end_child(void *p, int v) { (void)p; (void)v; }
void gtk_paned_set_shrink_start_child(void *p, int v) { (void)p; (void)v; }
void gtk_paned_set_shrink_end_child(void *p, int v) { (void)p; (void)v; }
void gtk_paned_set_wide_handle(void *p, int v) { (void)p; (void)v; }
void gtk_box_append(void *b, void *c) { (void)b; (void)c; }
void gtk_box_remove(void *b, void *c) { (void)b; (void)c; }
void gtk_box_reorder_child_after(void *b, void *c, void *s)
{ (void)b; (void)c; (void)s; }
void *gtk_scrolled_window_new(void) { return (void *)0x7; }
void gtk_scrolled_window_set_child(void *s, void *c) { (void)s; (void)c; }
void *gtk_label_new(const char *t) { (void)t; return (void *)0x3; }
void gtk_label_set_text(void *l, const char *t) { (void)l; (void)t; }
void gtk_label_set_wrap(void *l, int v) { (void)l; (void)v; }
void gtk_label_set_wrap_mode(void *l, int m) { (void)l; (void)m; }
void gtk_label_set_xalign(void *l, float a) { (void)l; (void)a; }
void *gtk_image_new_from_icon_name(const char *name) { (void)name; return (void *)0x22; }
void gtk_image_set_from_icon_name(void *image, const char *name) { (void)image; (void)name; }
void *gtk_button_new_with_label(const char *t) { (void)t; return (void *)0x4; }
void gtk_button_set_label(void *b, const char *t) { (void)b; (void)t; }
void gtk_button_set_icon_name(void *b, const char *name) { (void)b; (void)name; }
void *gtk_menu_button_new(void) { return (void *)0x23; }
void gtk_menu_button_set_label(void *b, const char *text) { (void)b; (void)text; }
void gtk_menu_button_set_icon_name(void *b, const char *name) { (void)b; (void)name; }
void gtk_menu_button_set_popover(void *b, void *p) { (void)b; (void)p; }
void gtk_menu_button_popup(void *b) { (void)b; }
void gtk_menu_button_popdown(void *b) { (void)b; }
void *gtk_popover_new(void) { return (void *)0x24; }
void gtk_popover_set_child(void *p, void *c) { (void)p; (void)c; }
void gtk_popover_set_has_arrow(void *p, int v) { (void)p; (void)v; }
void gtk_popover_set_autohide(void *p, int v) { (void)p; (void)v; }
void gtk_popover_set_position(void *p, int v) { (void)p; (void)v; }
typedef struct FakeRectangle { int x, y, width, height; } FakeRectangle;
void gtk_popover_set_pointing_to(void *p, const FakeRectangle *r) { (void)p; (void)r; }
void gtk_popover_popup(void *p) { (void)p; }
void gtk_popover_popdown(void *p) { (void)p; }
void gtk_popover_present(void *p) { (void)p; }
void *gtk_entry_new(void) { return (void *)0x5; }
void gtk_entry_set_placeholder_text(void *e, const char *t) { (void)e; (void)t; }
void gtk_editable_set_text(void *e, const char *t) { (void)e; (void)t; }
#ifndef BABET_FAKE_GTK_MISSING_ENTRY
const char *gtk_editable_get_text(void *e) { (void)e; return ""; }
#endif
void gtk_editable_set_editable(void *e, int v) { (void)e; (void)v; }
void *gtk_spin_button_new_with_range(double min, double max, double step)
{ (void)min; (void)max; (void)step; return (void *)0x8; }
double gtk_spin_button_get_value(void *s) { (void)s; return 0.0; }
void gtk_spin_button_set_value(void *s, double v) { (void)s; (void)v; }
void gtk_spin_button_set_digits(void *s, unsigned int d) { (void)s; (void)d; }
void gtk_spin_button_set_numeric(void *s, int v) { (void)s; (void)v; }
void *gtk_calendar_new(void) { return (void *)0x9; }
void *gtk_calendar_get_date(void *c)
{ (void)c; return g_date_time_new_local(2026, 10, 7, 12, 0, 0.0); }
void gtk_calendar_select_day(void *c, void *date) { (void)c; (void)date; }
void gtk_calendar_mark_day(void *c, unsigned int day) { (void)c; (void)day; }
void gtk_calendar_unmark_day(void *c, unsigned int day) { (void)c; (void)day; }
void gtk_calendar_clear_marks(void *c) { (void)c; }
typedef void (*DrawCallback)(void *, void *, int, int, void *);
typedef void (*DrawNotify)(void *);
#ifndef BABET_FAKE_GTK_MISSING_DRAWING
void *gtk_drawing_area_new(void) { return (void *)0x6; }
#endif
void gtk_drawing_area_set_content_width(void *w, int s) { (void)w; (void)s; }
void gtk_drawing_area_set_content_height(void *w, int s) { (void)w; (void)s; }
void gtk_drawing_area_set_draw_func(void *w, DrawCallback cb, void *d, DrawNotify n)
{ (void)w; (void)cb; (void)d; (void)n; }
#ifndef BABET_FAKE_GTK_MISSING_GESTURE_CLICK
void *gtk_gesture_click_new(void) { return (void *)0xa; }
#endif
void gtk_gesture_single_set_button(void *g, unsigned int b) { (void)g; (void)b; }
unsigned int gtk_gesture_single_get_current_button(void *g) { (void)g; return 1U; }
void gtk_widget_add_controller(void *w, void *c) { (void)w; (void)c; }
void gtk_widget_queue_draw(void *w) { (void)w; }
void gtk_widget_set_margin_top(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_margin_bottom(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_margin_start(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_margin_end(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_hexpand(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_vexpand(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_visible(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_sensitive(void *w, int v) { (void)w; (void)v; }
void *gtk_css_provider_new(void) { return (void *)0xb; }
#ifndef BABET_FAKE_GTK_MISSING_CSS_STRING
void gtk_css_provider_load_from_string(void *p, const char *css)
{ (void)p; (void)css; }
#endif
#ifndef BABET_FAKE_GTK_MISSING_CSS_DATA
void gtk_css_provider_load_from_data(void *p, const char *css, long n)
{ (void)p; (void)css; (void)n; }
#endif
void *gdk_display_get_default(void) { return (void *)0xc; }
void gtk_style_context_add_provider_for_display(void *d, void *p, unsigned int priority)
{ (void)d; (void)p; (void)priority; }
void gtk_style_context_remove_provider_for_display(void *d, void *p)
{ (void)d; (void)p; }
void gtk_widget_add_css_class(void *w, const char *name) { (void)w; (void)name; }
void gtk_widget_remove_css_class(void *w, const char *name) { (void)w; (void)name; }
void *gtk_widget_get_parent(void *w) { (void)w; return NULL; }
void gtk_widget_set_parent(void *w, void *p) { (void)w; (void)p; }
void gtk_widget_unparent(void *w) { (void)w; }
void *g_object_ref_sink(void *o) { return o; }
void g_object_unref(void *o) { (void)o; }
unsigned long g_signal_connect_data(void *i, const char *s, FakeCallback c,
                                    void *d, FakeClosureNotify n, unsigned int f)
{ (void)i; (void)s; (void)c; (void)d; (void)n; (void)f; return 1; }
int g_main_context_iteration(void *c, int b) { (void)c; (void)b; return 1; }
unsigned int g_timeout_add(unsigned int ms, FakeSourceCallback cb, void *d)
{ (void)ms; (void)cb; (void)d; return 1; }
int g_source_remove(unsigned int id) { (void)id; return 1; }
