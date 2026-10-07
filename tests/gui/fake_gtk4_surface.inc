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

void *gtk_window_new(void) { return (void *)0x1; }
void gtk_window_set_title(void *w, const char *t) { (void)w; (void)t; }
void gtk_window_set_default_size(void *w, int x, int y) { (void)w; (void)x; (void)y; }
void gtk_window_set_child(void *w, void *c) { (void)w; (void)c; }
void gtk_window_present(void *w) { (void)w; }
void gtk_window_destroy(void *w) { (void)w; }
void *gtk_box_new(int o, int s) { (void)o; (void)s; return (void *)0x2; }
void gtk_box_append(void *b, void *c) { (void)b; (void)c; }
void gtk_box_remove(void *b, void *c) { (void)b; (void)c; }
void *gtk_scrolled_window_new(void) { return (void *)0x7; }
void gtk_scrolled_window_set_child(void *s, void *c) { (void)s; (void)c; }
void *gtk_label_new(const char *t) { (void)t; return (void *)0x3; }
void gtk_label_set_text(void *l, const char *t) { (void)l; (void)t; }
void *gtk_button_new_with_label(const char *t) { (void)t; return (void *)0x4; }
void gtk_button_set_label(void *b, const char *t) { (void)b; (void)t; }
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
typedef void (*DrawCallback)(void *, void *, int, int, void *);
typedef void (*DrawNotify)(void *);
#ifndef BABET_FAKE_GTK_MISSING_DRAWING
void *gtk_drawing_area_new(void) { return (void *)0x6; }
#endif
void gtk_drawing_area_set_content_width(void *w, int s) { (void)w; (void)s; }
void gtk_drawing_area_set_content_height(void *w, int s) { (void)w; (void)s; }
void gtk_drawing_area_set_draw_func(void *w, DrawCallback cb, void *d, DrawNotify n)
{ (void)w; (void)cb; (void)d; (void)n; }
void gtk_widget_queue_draw(void *w) { (void)w; }
void gtk_widget_set_margin_top(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_margin_bottom(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_margin_start(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_margin_end(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_hexpand(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_vexpand(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_visible(void *w, int v) { (void)w; (void)v; }
void gtk_widget_set_sensitive(void *w, int v) { (void)w; (void)v; }
void *gtk_widget_get_parent(void *w) { (void)w; return NULL; }
void *g_object_ref_sink(void *o) { return o; }
void g_object_unref(void *o) { (void)o; }
unsigned long g_signal_connect_data(void *i, const char *s, FakeCallback c,
                                    void *d, FakeClosureNotify n, unsigned int f)
{ (void)i; (void)s; (void)c; (void)d; (void)n; (void)f; return 1; }
int g_main_context_iteration(void *c, int b) { (void)c; (void)b; return 1; }
unsigned int g_timeout_add(unsigned int ms, FakeSourceCallback cb, void *d)
{ (void)ms; (void)cb; (void)d; return 1; }
int g_source_remove(unsigned int id) { (void)id; return 1; }
