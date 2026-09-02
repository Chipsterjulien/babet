#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_WIDGETS 64

typedef void (*FakeCallback)(void);
typedef void (*FakeClosureNotify)(void *, void *);
typedef int (*FakeSourceCallback)(void *);
typedef void (*WidgetSignal)(void *, void *);

typedef struct FakeWidget {
    int kind; /* 1 window, 2 box, 3 label, 4 button */
    int refs;
    int alive;
    int clicked;
    struct FakeWidget *parent;
    FakeCallback destroy_cb;
    void *destroy_data;
    FakeCallback clicked_cb;
    void *clicked_data;
    FakeClosureNotify clicked_destroy_notify;
    char text[256];
} FakeWidget;

static FakeWidget *widgets[MAX_WIDGETS];
static size_t widget_count;
static unsigned int next_source_id = 1;

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
    if (widget_count >= MAX_WIDGETS) return NULL;
    FakeWidget *w = (FakeWidget *)calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->kind = kind;
    w->refs = 1;
    w->alive = 1;
    if (text) {
        strncpy(w->text, text, sizeof(w->text) - 1);
        w->text[sizeof(w->text) - 1] = '\0';
    }
    widgets[widget_count++] = w;
    return w;
}

static WidgetSignal as_widget_signal(FakeCallback cb)
{
    WidgetSignal typed = NULL;
    memcpy(&typed, &cb, sizeof(typed));
    return typed;
}

static void destroy_widget(FakeWidget *w)
{
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
    for (size_t i = 0; i < widget_count; ++i) {
        if (widgets[i] == w) { widgets[i] = NULL; break; }
    }
    free(w);
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
void *gtk_label_new(const char *text) { return make_widget(3, text); }
void gtk_label_set_text(void *p, const char *text)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) return;
    strncpy(w->text, text, sizeof(w->text) - 1);
    w->text[sizeof(w->text) - 1] = '\0';
    log_line("label:", text);
}
void *gtk_button_new_with_label(const char *text) { return make_widget(4, text); }
void gtk_button_set_label(void *p, const char *text)
{
    FakeWidget *w = (FakeWidget *)p;
    if (!w || !w->alive) return;
    strncpy(w->text, text, sizeof(w->text) - 1);
    w->text[sizeof(w->text) - 1] = '\0';
}
void *gtk_widget_get_parent(void *p)
{
    FakeWidget *w = (FakeWidget *)p;
    return w ? w->parent : NULL;
}

void *g_object_ref_sink(void *p) { return p; }
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
    if (strcmp(signal, "destroy") == 0) {
        w->destroy_cb = cb; w->destroy_data = data; return 1;
    }
    if (strcmp(signal, "clicked") == 0) {
        w->clicked_cb = cb;
        w->clicked_data = data;
        w->clicked_destroy_notify = destroy_notify;
        return 2;
    }
    return 0;
}

int g_main_context_iteration(void *context, int may_block)
{
    (void)context; (void)may_block;
    for (size_t i = 0; i < widget_count; ++i) {
        FakeWidget *w = widgets[i];
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
