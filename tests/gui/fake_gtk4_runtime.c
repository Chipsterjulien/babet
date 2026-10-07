#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fake_cairo.inc"

#define MAX_WIDGETS 64

typedef void (*FakeCallback)(void);
typedef void (*FakeClosureNotify)(void *, void *);
typedef int (*FakeSourceCallback)(void *);
typedef void (*WidgetSignal)(void *, void *);
typedef void (*DrawCallback)(void *, void *, int, int, void *);
typedef void (*DrawNotify)(void *);
typedef void (*PressedSignal)(void *, int, double, double, void *);

typedef struct FakeDateTime {
    int year, month, day;
} FakeDateTime;

typedef struct FakeWidget {
    int kind; /* 1 window, 2 box, 3 label, 4 button, 5 entry, 6 drawingArea, 7 scrolled, 8 spin, 9 calendar */
    int refs;
    int floating;
    int alive;
    int clicked;
    struct FakeWidget *parent;
    FakeCallback destroy_cb;
    void *destroy_data;
    FakeCallback clicked_cb;
    void *clicked_data;
    FakeClosureNotify clicked_destroy_notify;
    FakeCallback changed_cb;
    void *changed_data;
    FakeClosureNotify changed_destroy_notify;
    FakeCallback activate_cb;
    void *activate_data;
    FakeClosureNotify activate_destroy_notify;
    int activated;
    int editable;
    char *text;
    DrawCallback draw_cb;
    void *draw_data;
    DrawNotify draw_notify;
    int width, height, dirty;
    double minimum, maximum, step, value;
    unsigned int digits;
    int numeric;
    int year, month, day;
    int margin_top, margin_bottom, margin_start, margin_end;
    int hexpand, vexpand, visible, sensitive;
    unsigned int gesture_button, current_button;
    FakeCallback pressed_cb;
    void *pressed_data;
    FakeClosureNotify pressed_destroy_notify;
    int pressed;
} FakeWidget;

static FakeWidget *widgets[MAX_WIDGETS];
static size_t widget_count;
static unsigned int next_source_id = 1;
static int in_draw;

static void log_line(const char *prefix, const char *value)
{
    const char *path = getenv("BABET_FAKE_GTK_LOG");
    if (!path || !*path) return;
    FILE *stream = fopen(path, "a");
    if (!stream) return;
    fputs(prefix, stream);
    if (value) fputs(value, stream);
    fputc('\n', stream);
    fclose(stream);
}

static FakeWidget *make_widget(int kind, const char *text)
{
    size_t slot = 0;
    while (slot < widget_count && widgets[slot]) ++slot;
    if (slot == MAX_WIDGETS) return NULL;
    FakeWidget *w = (FakeWidget *)calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->kind = kind;
    w->refs = 1;
    w->floating = kind != 1;
    w->alive = 1;
    w->editable = 1;
    w->visible = 1;
    w->sensitive = 1;
    if (kind == 9) { w->year = 2026; w->month = 10; w->day = 7; }
    if (!text) text = "";
    w->text = (char *)malloc(strlen(text) + 1);
    if (!w->text) { free(w); return NULL; }
    strcpy(w->text, text);
    widgets[slot] = w;
    if (slot == widget_count) ++widget_count;
    return w;
}

static WidgetSignal as_widget_signal(FakeCallback cb)
{
    WidgetSignal typed = NULL;
    memcpy(&typed, &cb, sizeof(typed));
    return typed;
}

static PressedSignal as_pressed_signal(FakeCallback cb)
{
    PressedSignal typed = NULL;
    memcpy(&typed, &cb, sizeof(typed));
    return typed;
}

static void destroy_widget(FakeWidget *w)
{
    if (in_draw) { fputs("native destruction during drawing\n", stderr); abort(); }
    if (!w || !w->alive) return;
    for (size_t i = 0; i < widget_count; ++i) {
        FakeWidget *child = widgets[i];
        if (child && child->alive && child->parent == w) {
            child->parent = NULL;
            if (--child->refs == 0) destroy_widget(child);
        }
    }
    w->alive = 0;
    if (w->destroy_cb) {
        WidgetSignal cb = as_widget_signal(w->destroy_cb);
        cb(w, w->destroy_data);
    }
    if (w->clicked_destroy_notify) {
        FakeClosureNotify notify = w->clicked_destroy_notify;
        w->clicked_destroy_notify = NULL;
        log_line("closure-notify:clicked", NULL);
        notify(w->clicked_data, NULL);
    }
    if (w->changed_destroy_notify) {
        log_line("closure-notify:changed", NULL);
        w->changed_destroy_notify(w->changed_data, NULL);
    }
    if (w->activate_destroy_notify) {
        log_line("closure-notify:activate", NULL);
        w->activate_destroy_notify(w->activate_data, NULL);
    }
    if (w->pressed_destroy_notify) {
        log_line("closure-notify:pressed", NULL);
        w->pressed_destroy_notify(w->pressed_data, NULL);
    }
    if (w->kind == 5) log_line("destroy:entry", NULL);
    if (w->kind == 7) log_line("destroy:scrolledWindow", NULL);
    if (w->kind == 8) log_line("destroy:spinButton", NULL);
    if (w->kind == 9) log_line("destroy:calendar", NULL);
    if (w->draw_notify) w->draw_notify(w->draw_data);
    if (w->kind == 6) log_line("destroy:drawingArea", NULL);
    for (size_t i = 0; i < widget_count; ++i) {
        if (widgets[i] == w) { widgets[i] = NULL; break; }
    }
    free(w->text);
    free(w);
}

static void set_text(FakeWidget *w, const char *text)
{
    char *copy = (char *)malloc(strlen(text) + 1);
    if (!copy) abort();
    strcpy(copy, text);
    free(w->text);
    w->text = copy;
}

void gtk_disable_setlocale(void) { log_line("disable_setlocale", NULL); }
int gtk_init_check(void) { log_line("init_check", NULL); return 1; }

void *gtk_window_new(void) { return make_widget(1, NULL); }
void gtk_window_set_title(void *p, const char *t) { (void)p; log_line("title:", t); }
void gtk_window_set_default_size(void *p, int x, int y) { (void)p; (void)x; (void)y; }
void gtk_window_set_child(void *parent_p, void *child_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    if (!parent || !child) return;
    child->parent = parent;
    ++child->refs;
}
void gtk_window_present(void *p) { (void)p; log_line("present", NULL); }
void gtk_window_destroy(void *p) { destroy_widget((FakeWidget *)p); }

void *gtk_box_new(int orientation, int spacing)
{ (void)orientation; (void)spacing; return make_widget(2, NULL); }
void gtk_box_append(void *parent_p, void *child_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    if (!parent || !child) return;
    child->parent = parent;
    ++child->refs;
}
void gtk_box_remove(void *parent_p, void *child_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    if (!parent || !child || child->parent != parent) return;
    child->parent = NULL;
    log_line("box-remove", NULL);
    if (--child->refs == 0) destroy_widget(child);
}
void *gtk_scrolled_window_new(void) { return make_widget(7, NULL); }
void gtk_scrolled_window_set_child(void *parent_p, void *child_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    if (!parent) return;
    for (size_t i = 0; i < widget_count; ++i) {
        FakeWidget *old = widgets[i];
        if (old && old->alive && old->parent == parent) {
            old->parent = NULL;
            if (--old->refs == 0) destroy_widget(old);
        }
    }
    if (child) {
        child->parent = parent;
        ++child->refs;
        log_line("scrolled-child:set", NULL);
    } else {
        log_line("scrolled-child:clear", NULL);
    }
}
void *gtk_label_new(const char *text) { return make_widget(3, text); }
void gtk_label_set_text(void *p, const char *text)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) return;
    set_text(w, text);
    log_line("label:", text);
}
void *gtk_button_new_with_label(const char *text) { return make_widget(4, text); }
void gtk_button_set_label(void *p, const char *text)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) return;
    set_text(w, text);
}
void *gtk_entry_new(void) { return make_widget(5, ""); }
void gtk_entry_set_placeholder_text(void *p, const char *text)
{ (void)p; log_line("placeholder:", text); }
void gtk_editable_set_text(void *p, const char *text)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) abort();
    if (strcmp(w->text, text) == 0) return;
    set_text(w, text);
    if (w->changed_cb) as_widget_signal(w->changed_cb)(w, w->changed_data);
    // A setter still uses the object after synchronous notification. The
    // binding must pin it if a callback closes its parent or finalizes Lua.
    if (!w->alive) abort();
    log_line("entry-after-change:", w->text);
}
const char *gtk_editable_get_text(void *p)
{ return ((FakeWidget *)p)->text; }
void gtk_editable_set_editable(void *p, int editable)
{
    ((FakeWidget *)p)->editable = editable;
    log_line("editable:", editable ? "true" : "false");
}
void *gtk_spin_button_new_with_range(double minimum, double maximum, double step)
{
    FakeWidget *w = make_widget(8, NULL);
    if (!w) return NULL;
    w->minimum = minimum; w->maximum = maximum; w->step = step; w->value = minimum;
    return w;
}
double gtk_spin_button_get_value(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    return w ? w->value : 0.0;
}
void gtk_spin_button_set_value(void *p, double value)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) abort();
    if (value < w->minimum) value = w->minimum;
    if (value > w->maximum) value = w->maximum;
    if (w->value == value) return;
    w->value = value;
    if (w->changed_cb) as_widget_signal(w->changed_cb)(w, w->changed_data);
    if (!w->alive) abort();
    log_line("spin-after-change", NULL);
}
void gtk_spin_button_set_digits(void *p, unsigned int digits)
{
    ((FakeWidget *)p)->digits = digits;
}
void gtk_spin_button_set_numeric(void *p, int numeric)
{
    ((FakeWidget *)p)->numeric = numeric;
}

void *g_date_time_new_local(int year, int month, int day, int hour, int minute, double seconds)
{
    (void)hour; (void)minute; (void)seconds;
    FakeDateTime *date = (FakeDateTime *)malloc(sizeof(*date));
    if (!date) return NULL;
    date->year = year; date->month = month; date->day = day;
    return date;
}
int g_date_time_get_year(void *p) { return ((FakeDateTime *)p)->year; }
int g_date_time_get_month(void *p) { return ((FakeDateTime *)p)->month; }
int g_date_time_get_day_of_month(void *p) { return ((FakeDateTime *)p)->day; }
void g_date_time_unref(void *p) { free(p); }

void *gtk_calendar_new(void) { return make_widget(9, NULL); }
void *gtk_calendar_get_date(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    return g_date_time_new_local(w->year, w->month, w->day, 12, 0, 0.0);
}
void gtk_calendar_select_day(void *p, void *date_p)
{
    FakeWidget *w = (FakeWidget *)p;
    FakeDateTime *date = (FakeDateTime *)date_p;
    if (!w || !w->alive || !date) abort();
    int changed = w->year != date->year || w->month != date->month || w->day != date->day;
    w->year = date->year; w->month = date->month; w->day = date->day;
    if (changed && w->changed_cb) as_widget_signal(w->changed_cb)(w, w->changed_data);
    if (!w->alive) abort();
    log_line("calendar-after-change", NULL);
}
void *gtk_drawing_area_new(void) { return make_widget(6, NULL); }
void gtk_drawing_area_set_content_width(void *p, int width)
{ ((FakeWidget *)p)->width = width; }
void gtk_drawing_area_set_content_height(void *p, int height)
{ ((FakeWidget *)p)->height = height; }
void gtk_widget_queue_draw(void *p)
{
    if (in_draw) abort();
    ((FakeWidget *)p)->dirty = 1;
    log_line("queue-draw", NULL);
}
void gtk_widget_set_margin_top(void *p, int value)
{ ((FakeWidget *)p)->margin_top = value; log_line("margin-top", NULL); }
void gtk_widget_set_margin_bottom(void *p, int value)
{ ((FakeWidget *)p)->margin_bottom = value; log_line("margin-bottom", NULL); }
void gtk_widget_set_margin_start(void *p, int value)
{ ((FakeWidget *)p)->margin_start = value; log_line("margin-start", NULL); }
void gtk_widget_set_margin_end(void *p, int value)
{ ((FakeWidget *)p)->margin_end = value; log_line("margin-end", NULL); }
void gtk_widget_set_hexpand(void *p, int value)
{ ((FakeWidget *)p)->hexpand = value; log_line("hexpand:", value ? "true" : "false"); }
void gtk_widget_set_vexpand(void *p, int value)
{ ((FakeWidget *)p)->vexpand = value; log_line("vexpand:", value ? "true" : "false"); }
void gtk_widget_set_visible(void *p, int value)
{ ((FakeWidget *)p)->visible = value; log_line("visible:", value ? "true" : "false"); }
void gtk_widget_set_sensitive(void *p, int value)
{ ((FakeWidget *)p)->sensitive = value; log_line("sensitive:", value ? "true" : "false"); }
void gtk_drawing_area_set_draw_func(void *p, DrawCallback cb, void *data, DrawNotify notify)
{
    FakeWidget *w = (FakeWidget *)p;
    if (w->draw_notify) w->draw_notify(w->draw_data);
    w->draw_cb = cb; w->draw_data = data; w->draw_notify = notify; w->dirty = 1;
}
void *gtk_gesture_click_new(void)
{
    FakeWidget *gesture = make_widget(10, NULL);
    if (gesture) gesture->gesture_button = 1U;
    return gesture;
}
void gtk_gesture_single_set_button(void *p, unsigned int button)
{
    FakeWidget *gesture = (FakeWidget *)p;
    if (!gesture || !gesture->alive || gesture->kind != 10) abort();
    gesture->gesture_button = button;
}
unsigned int gtk_gesture_single_get_current_button(void *p)
{
    FakeWidget *gesture = (FakeWidget *)p;
    if (!gesture || !gesture->alive || gesture->kind != 10) abort();
    return gesture->current_button;
}
void gtk_widget_add_controller(void *widget_p, void *controller_p)
{
    FakeWidget *widget = (FakeWidget *)widget_p;
    FakeWidget *controller = (FakeWidget *)controller_p;
    if (!widget || !controller || !widget->alive || !controller->alive || controller->parent) abort();
    controller->parent = widget;
    if (controller->floating) controller->floating = 0;
    else ++controller->refs;
}

static void draw_widget(FakeWidget *w)
{
    w->dirty = 0;
    in_draw = 1;
    log_line("draw-begin", NULL);
#ifdef BABET_TEST_REAL_CAIRO
    if (!FcInit()) abort();
    void *surface = cairo_image_surface_create(0, w->width, w->height); /* ARGB32 */
    void *cr = cairo_create(surface);
    double initial_width = cairo_get_line_width(cr);
    if (cairo_status(cr)) abort();
    w->draw_cb(w, cr, w->width, w->height, w->draw_data);
    if (cairo_status(cr) || cairo_get_line_width(cr) != initial_width) abort();
    const char *path = getenv("BABET_CAIRO_PIXELS");
    if (path) {
        cairo_surface_flush(surface);
        FILE *f = fopen(path, "wb");
        if (!f) abort();
        size_t size = (size_t)cairo_image_surface_get_stride(surface) * (size_t)w->height;
        if (fwrite(cairo_image_surface_get_data(surface), 1, size, f) != size) abort();
        fclose(f);
    }
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    /* This isolated fixture owns every Cairo object in its process; GTK is
     * fake and no font/context/surface is retained across draw_widget calls.
     * Release Cairo's font references BEFORE finalizing Fontconfig. Otherwise
     * the real-Cairo pixel test leaves font caches visible to LeakSanitizer.
     * Never move this global teardown into Babet's real GTK/runtime binding. */
    cairo_debug_reset_static_data();
    FcFini();
    log_line("cairo-font-caches-released", NULL);
#else
    FakeCairo cr = {0, 0};
    w->draw_cb(w, &cr, w->width, w->height, w->draw_data);
    if (cr.depth != 0) abort();
#endif
    log_line("draw-end", NULL);
    in_draw = 0;
}
void *gtk_widget_get_parent(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    return w ? w->parent : NULL;
}

void *g_object_ref_sink(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    if (w->floating) w->floating = 0;
    else ++w->refs;
    return p;
}
void g_object_unref(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) return;
    if (--w->refs == 0) destroy_widget(w);
}
unsigned long g_signal_connect_data(void *instance, const char *signal,
                                    FakeCallback cb, void *data,
                                    FakeClosureNotify destroy_notify,
                                    unsigned int flags)
{
    (void)flags;
    FakeWidget *w = (FakeWidget *)instance;
    if (!w || !signal || !cb) return 0;
    const char *fail_signal = getenv("BABET_FAKE_GTK_FAIL_SIGNAL");
    if (fail_signal && strcmp(fail_signal, signal) == 0) return 0;
    if (strcmp(signal, "destroy") == 0) {
        w->destroy_cb = cb; w->destroy_data = data; return 1;
    }
    if (strcmp(signal, "clicked") == 0) {
        w->clicked_cb = cb;
        w->clicked_data = data;
        w->clicked_destroy_notify = destroy_notify;
        return 2;
    }
    if (strcmp(signal, "changed") == 0 || strcmp(signal, "value-changed") == 0 ||
        strcmp(signal, "day-selected") == 0) {
        w->changed_cb = cb; w->changed_data = data;
        w->changed_destroy_notify = destroy_notify; return 3;
    }
    if (strcmp(signal, "activate") == 0) {
        w->activate_cb = cb; w->activate_data = data;
        w->activate_destroy_notify = destroy_notify; return 4;
    }
    if (strcmp(signal, "pressed") == 0 && w->kind == 10) {
        w->pressed_cb = cb; w->pressed_data = data;
        w->pressed_destroy_notify = destroy_notify; return 5;
    }
    return 0;
}

int g_main_context_iteration(void *context, int may_block)
{
    (void)context; (void)may_block;
    /* Render dirty areas before simulating a button event. */
    for (size_t i = 0; i < widget_count; ++i) {
        FakeWidget *w = widgets[i];
        if (w && w->alive && w->kind == 6 && w->parent && w->dirty && w->draw_cb) {
            draw_widget(w);
            return 1;
        }
    }
    for (size_t i = 0; i < widget_count; ++i) {
        FakeWidget *w = widgets[i];
        if (w && w->alive && w->kind == 10 && w->parent && !w->pressed && w->pressed_cb) {
            w->pressed = 1;
            w->current_button = 1U;
            PressedSignal cb = as_pressed_signal(w->pressed_cb);
            cb(w, 1, 42.5, 73.25, w->pressed_data);
            if (w->alive) w->current_button = 0U;
            return 1;
        }
        if (w && w->alive && w->kind == 5 && !w->activated && w->activate_cb) {
            w->activated = 1;
            WidgetSignal cb = as_widget_signal(w->activate_cb);
            cb(w, w->activate_data);
            return 1;
        }
        if (w && w->alive && w->kind == 4 && !w->clicked && w->clicked_cb) {
            w->clicked = 1;
            WidgetSignal cb = as_widget_signal(w->clicked_cb);
            cb(w, w->clicked_data);
            return 1;
        }
    }
    return 1;
}
unsigned int g_timeout_add(unsigned int milliseconds, FakeSourceCallback cb, void *data)
{ (void)milliseconds; (void)cb; (void)data; return next_source_id++; }
int g_source_remove(unsigned int source_id) { return source_id != 0; }
