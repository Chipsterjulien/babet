#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include "fake_cairo.inc"

#define MAX_WIDGETS 64

typedef void (*FakeCallback)(void);
typedef void (*FakeClosureNotify)(void *, void *);
typedef int (*FakeSourceCallback)(void *);
typedef void (*WidgetSignal)(void *, void *);
typedef void (*DrawCallback)(void *, void *, int, int, void *);
typedef void (*DrawNotify)(void *);
typedef void (*PressedSignal)(void *, int, double, double, void *);
typedef void (*DragSignal)(void *, double, double, void *);

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
    struct FakeWidget *box_children[MAX_WIDGETS];
    size_t box_child_count;
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
    int expanded;
    struct FakeWidget *expander_child; /* owned; parented only while expanded */
    FakeCallback drag_cb[3];
    void *drag_data[3];
    FakeClosureNotify drag_destroy[3];
    int year, month, day;
    int margin_top, margin_bottom, margin_start, margin_end;
    int hexpand, vexpand, visible, sensitive;
    unsigned int gesture_button, current_button;
    FakeCallback pressed_cb;
    void *pressed_data;
    FakeClosureNotify pressed_destroy_notify;
    int pressed;
    double drag_event_x, drag_event_y; /* surface coords of most recent drag event */
} FakeWidget;

static FakeWidget *widgets[MAX_WIDGETS];
static size_t widget_count;
static unsigned int next_source_id = 1;
static int in_draw;

#ifdef BABET_FAKE_GTK_OOM_PROBE
static size_t owned_text_copies;
size_t babet_fake_gtk_text_copies(void) { return owned_text_copies; }
size_t babet_fake_gtk_live_widgets(void)
{
    size_t alive = 0;
    for (size_t i = 0; i < widget_count; ++i)
        if (widgets[i] && widgets[i]->alive) ++alive;
    return alive;
}
#endif

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

static DragSignal as_drag_signal(FakeCallback cb)
{
    DragSignal typed = NULL;
    memcpy(&typed, &cb, sizeof(typed));
    return typed;
}

static void destroy_widget(FakeWidget *w)
{
    if (in_draw) { fputs("native destruction during drawing\n", stderr); abort(); }
    if (!w || !w->alive) return;
    if (w->expander_child) {
        FakeWidget *held = w->expander_child;
        w->expander_child = NULL;
        if (held->alive) {
            if (held->parent == w) held->parent = NULL;
            if (--held->refs == 0) destroy_widget(held);
        }
    }
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
    for (int i = 0; i < 3; ++i) if (w->drag_destroy[i])
        w->drag_destroy[i](w->drag_data[i], NULL);
    if (w->kind == 5) log_line("destroy:entry", NULL);
    if (w->kind == 7) log_line("destroy:scrolledWindow", NULL);
    if (w->kind == 8) log_line("destroy:spinButton", NULL);
    if (w->kind == 9) log_line("destroy:calendar", NULL);
    if (w->draw_notify) w->draw_notify(w->draw_data);
    if (w->kind == 6) log_line("destroy:drawingArea", NULL);
    if (w->kind == 15) log_line("destroy:progressBar", NULL);
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
static void log_box_order(FakeWidget *parent)
{
    const char *path = getenv("BABET_FAKE_GTK_LOG");
    if (!path || !*path || !parent || parent->kind != 2) return;
    FILE *stream = fopen(path, "a");
    if (!stream) return;
    fputs("box-order:", stream);
    for (size_t i = 0; i < parent->box_child_count; ++i) {
        if (i) fputc(',', stream);
        FakeWidget *child = parent->box_children[i];
        if (child && child->text) fputs(child->text, stream);
    }
    fputc('\n', stream);
    fclose(stream);
}

void gtk_box_append(void *parent_p, void *child_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    if (!parent || !child) return;
    child->parent = parent;
    ++child->refs;
    if (parent->kind == 2) {
        if (parent->box_child_count >= MAX_WIDGETS) abort();
        parent->box_children[parent->box_child_count++] = child;
    }
}
void gtk_box_remove(void *parent_p, void *child_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    if (!parent || !child || child->parent != parent) return;
    if (parent->kind == 2) {
        size_t index = parent->box_child_count;
        for (size_t i = 0; i < parent->box_child_count; ++i)
            if (parent->box_children[i] == child) { index = i; break; }
        if (index == parent->box_child_count) abort();
        for (size_t i = index + 1; i < parent->box_child_count; ++i)
            parent->box_children[i - 1] = parent->box_children[i];
        parent->box_children[--parent->box_child_count] = NULL;
    }
    child->parent = NULL;
    log_line("box-remove:", child->text);
    if (--child->refs == 0) destroy_widget(child);
}
void gtk_box_reorder_child_after(void *parent_p, void *child_p, void *sibling_p)
{
    FakeWidget *parent = (FakeWidget *)parent_p;
    FakeWidget *child = (FakeWidget *)child_p;
    FakeWidget *sibling = (FakeWidget *)sibling_p;
    if (!parent || parent->kind != 2 || !child || child->parent != parent ||
        (sibling && sibling->parent != parent) || child == sibling) abort();

    size_t from = parent->box_child_count;
    size_t sibling_index = parent->box_child_count;
    for (size_t i = 0; i < parent->box_child_count; ++i) {
        if (parent->box_children[i] == child) from = i;
        if (sibling && parent->box_children[i] == sibling) sibling_index = i;
    }
    if (from == parent->box_child_count || (sibling && sibling_index == parent->box_child_count))
        abort();

    FakeWidget *moving = parent->box_children[from];
    for (size_t i = from + 1; i < parent->box_child_count; ++i)
        parent->box_children[i - 1] = parent->box_children[i];
    --parent->box_child_count;

    size_t insert = 0;
    if (sibling) {
        /* sibling_index was measured before removing child. Adjust it if the
           removed child was before the sibling, then insert immediately after. */
        if (from < sibling_index) --sibling_index;
        insert = sibling_index + 1;
    }
    for (size_t i = parent->box_child_count; i > insert; --i)
        parent->box_children[i] = parent->box_children[i - 1];
    parent->box_children[insert] = moving;
    ++parent->box_child_count;

    log_line("box-reorder:", child->text);
    log_box_order(parent);
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

void *gtk_fixed_new(void) { return make_widget(11, NULL); }
void gtk_fixed_put(void *p, void *c, double x, double y)
{ (void)x; (void)y; gtk_box_append(p, c); }
void gtk_fixed_move(void *p, void *c, double x, double y)
{ (void)p; (void)c; (void)x; (void)y; log_line("fixed-move", NULL); }
void gtk_fixed_remove(void *p, void *c) { gtk_box_remove(p, c); }
void *gtk_text_view_new(void) { return make_widget(12, NULL); }
void *gtk_text_view_get_buffer(void *p)
{
    FakeWidget *view = (FakeWidget *)p;
    for (size_t i = 0; i < widget_count; ++i)
        if (widgets[i] && widgets[i]->kind == 13 && widgets[i]->parent == view)
            return widgets[i];
    FakeWidget *buffer = make_widget(13, "");
    if (!buffer) return NULL;
    buffer->parent = view;
    buffer->floating = 0;
    return buffer;
}
void gtk_text_buffer_set_text(void *p, const char *t, int n)
{
    (void)n;
    FakeWidget *w = (FakeWidget *)p;
    set_text(w, t);
    if (w->changed_cb) {
        WidgetSignal cb = as_widget_signal(w->changed_cb);
        cb(w, w->changed_data);
    }
}
void g_object_get(void *p, const char *property, ...)
{
    FakeWidget *w = (FakeWidget *)p;
    if (strcmp(property, "text") != 0) abort();
    va_list args;
    va_start(args, property);
    char **result = va_arg(args, char **);
    *result = (char *)malloc(strlen(w->text) + 1);
    if (!*result) abort();
    strcpy(*result, w->text);
#ifdef BABET_FAKE_GTK_OOM_PROBE
    ++owned_text_copies;
#endif
    va_end(args);
}
void g_free(void *p)
{
#ifdef BABET_FAKE_GTK_OOM_PROBE
    if (p) {
        if (!owned_text_copies) abort();
        --owned_text_copies;
    }
#endif
    free(p);
}
#ifdef BABET_FAKE_GTK_OOM_PROBE
/* Simulate an asynchronous edit after a coroutine's setter has returned. */
void babet_fake_gtk_emit_text_changed(void)
{
    for (size_t i = 0; i < widget_count; ++i) {
        FakeWidget *w = widgets[i];
        if (w && w->kind == 13 && w->changed_cb) {
            as_widget_signal(w->changed_cb)(w, w->changed_data);
            return;
        }
    }
    abort();
}
#endif
void gtk_text_view_set_editable(void *p, int e) { ((FakeWidget *)p)->editable = e; }
void *gtk_check_button_new_with_label(const char *label) { return make_widget(14, label); }
void gtk_check_button_set_label(void *p, const char *s) { set_text((FakeWidget *)p, s); }
void gtk_check_button_set_active(void *p, int active)
{
    FakeWidget *w = (FakeWidget *)p;
    if (w->expanded == !!active) return;
    w->expanded = !!active;
    if (w->changed_cb) {
        WidgetSignal cb = as_widget_signal(w->changed_cb);
        cb(w, w->changed_data);
    }
}
int gtk_check_button_get_active(void *p) { return ((FakeWidget *)p)->expanded; }
void *gtk_progress_bar_new(void) { return make_widget(15, NULL); }
void gtk_progress_bar_set_fraction(void *p, double fraction) { ((FakeWidget *)p)->value = fraction; }
double gtk_progress_bar_get_fraction(void *p) { return ((FakeWidget *)p)->value; }
void gtk_progress_bar_set_text(void *p, const char *s) { set_text((FakeWidget *)p, s); }
void gtk_progress_bar_set_show_text(void *p, int show) { (void)p; (void)show; }
void *gtk_expander_new(const char *s) { return make_widget(16, s); }
void gtk_expander_set_label(void *p, const char *s) { set_text((FakeWidget *)p, s); }
/* Real GTK4: a collapsed expander only owns a reference to its child, which
   stays unparented (gtk_widget_get_parent() == NULL) until the expander is
   expanded. Expanding while that child got another parent is a Gtk-CRITICAL
   (gtk_box_append assertion), modelled here as an abort. */
void gtk_expander_set_child(void *p, void *c)
{
    FakeWidget *e = (FakeWidget *)p;
    FakeWidget *child = (FakeWidget *)c;
    if (!e || e->expander_child == child) return;
    FakeWidget *old = e->expander_child;
    if (old) {
        e->expander_child = NULL;
        if (old->parent == e) old->parent = NULL;
        if (--old->refs == 0) destroy_widget(old);
    }
    if (child) {
        if (child->parent) {
            fputs("gtk_expander_set_child: child already has a parent\n", stderr);
            abort();
        }
        e->expander_child = child;
        ++child->refs;
        if (e->expanded) child->parent = e;
    }
}
void gtk_expander_set_expanded(void *p, int v)
{
    FakeWidget *e = (FakeWidget *)p;
    v = !!v;
    if (e->expanded == v) return;
    e->expanded = v;
    FakeWidget *child = e->expander_child;
    if (!child || !child->alive) return;
    if (v) {
        if (child->parent) {
            fputs("gtk_expander_set_expanded: child already has a parent\n", stderr);
            abort();
        }
        child->parent = e;
    } else if (child->parent == e) {
        child->parent = NULL;
    }
}
int gtk_expander_get_expanded(void *p) { return ((FakeWidget *)p)->expanded; }
void *gtk_gesture_drag_new(void) { return make_widget(21, NULL); }
void *gtk_gesture_single_get_current_sequence(void *gesture)
{ (void)gesture; return NULL; } /* mouse events have no touch sequence */
void *gtk_gesture_get_last_event(void *gesture, void *sequence)
{ (void)sequence; return gesture; } /* synthetic event token */
int gdk_event_get_position(void *event, double *x, double *y)
{
    FakeWidget *gesture = (FakeWidget *)event;
    if (!gesture || !gesture->alive || gesture->kind != 21) abort();
    *x = gesture->drag_event_x;
    *y = gesture->drag_event_y;
    return 1;
}
void gtk_widget_set_size_request(void *p, int width, int height)
{ FakeWidget *w = (FakeWidget *)p; w->width = width; w->height = height; }

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

    /* Match the observable GtkEntry/GtkEditable behavior exercised against
     * real GTK 4.14: replacing text is implemented as deletion followed by
     * insertion, so "changed" may expose an intermediate empty value. Even a
     * same-text replacement can therefore emit both notifications. Babet must
     * coalesce this native burst in its public setText() contract. */
    if (w->text[0] != '\0') {
        set_text(w, "");
        log_line("entry-native-changed:", w->text);
        if (w->changed_cb) as_widget_signal(w->changed_cb)(w, w->changed_data);
        if (!w->alive) abort();
    }
    if (text[0] != '\0') {
        set_text(w, text);
        log_line("entry-native-changed:", w->text);
        if (w->changed_cb) as_widget_signal(w->changed_cb)(w, w->changed_data);
        if (!w->alive) abort();
    }
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
void *gtk_css_provider_new(void)
{ return make_widget(11, NULL); }
#ifndef BABET_FAKE_GTK_MISSING_CSS_STRING
void gtk_css_provider_load_from_string(void *p, const char *css)
{
    FakeWidget *provider = (FakeWidget *)p;
    if (!provider || !provider->alive || provider->kind != 11) abort();
    log_line("css-load-string:", css ? css : "");
}
#endif
#ifndef BABET_FAKE_GTK_MISSING_CSS_DATA
void gtk_css_provider_load_from_data(void *p, const char *css, long length)
{
    FakeWidget *provider = (FakeWidget *)p;
    if (!provider || !provider->alive || provider->kind != 11) abort();
    (void)length;
    log_line("css-load-data:", css ? css : "");
}
#endif
void *gdk_display_get_default(void)
{ static int display; return &display; }
void gtk_style_context_add_provider_for_display(void *display, void *provider, unsigned int priority)
{
    if (!display || !provider || priority != 600U) abort();
    log_line("css-provider:add", NULL);
}
void gtk_style_context_remove_provider_for_display(void *display, void *provider)
{
    if (!display || !provider) abort();
    log_line("css-provider:remove", NULL);
}
void gtk_widget_add_css_class(void *p, const char *name)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive || !name) abort();
    log_line("css-class:add:", name);
}
void gtk_widget_remove_css_class(void *p, const char *name)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive || !name) abort();
    log_line("css-class:remove:", name);
}
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
        strcmp(signal, "day-selected") == 0 || strcmp(signal, "toggled") == 0) {
        w->changed_cb = cb; w->changed_data = data;
        w->changed_destroy_notify = destroy_notify; return 3;
    }
    if (strcmp(signal, "activate") == 0) {
        w->activate_cb = cb; w->activate_data = data;
        w->activate_destroy_notify = destroy_notify; return 4;
    }
    if (w->kind == 21) {
        const char *names[] = {"drag-begin", "drag-update", "drag-end"};
        for (int i = 0; i < 3; ++i) if (strcmp(signal, names[i]) == 0) {
            w->drag_cb[i] = cb; w->drag_data[i] = data;
            w->drag_destroy[i] = destroy_notify;
            return (unsigned long)(20 + i);
        }
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
        if (w && w->alive && w->kind == 21 && w->parent && !w->pressed && w->drag_cb[0]) {
            w->pressed = 1;
            /* GTK's native offsets change when the gesture's widget moves.
               Synthetic local offsets are deliberately wrong after the first
               update, while last-event surface positions remain correct. */
            const double local_x[] = {4.0, 25.5, 0.0, 0.0};
            const double local_y[] = {9.0, -12.0, 0.0, 0.0};
            const double surface_x[] = {100.0, 125.5, 150.5, 150.5};
            const double surface_y[] = {100.0, 88.0, 80.0, 80.0};
            const int phase_idx[] = {0, 1, 1, 2};
            for (int phase = 0; phase < 4; ++phase) {
                if (widgets[i] != w || !w->alive) break;
                w->drag_event_x = surface_x[phase];
                w->drag_event_y = surface_y[phase];
                const int signal = phase_idx[phase];
                if (w->drag_cb[signal]) {
                    DragSignal cb = as_drag_signal(w->drag_cb[signal]);
                    cb(w, local_x[phase], local_y[phase], w->drag_data[signal]);
                }
            }
            return 1;
        }
        if (w && w->alive && w->kind == 10 && w->parent && w->pressed < (w->parent->kind == 15 ? 4 : 2) && w->pressed_cb) {
            ++w->pressed;
            w->current_button = 1U;
            PressedSignal cb = as_pressed_signal(w->pressed_cb);
            cb(w, w->pressed, 42.5, 73.25, w->pressed_data);
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
