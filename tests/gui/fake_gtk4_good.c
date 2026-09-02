#include <stdio.h>
#include <stdlib.h>

static void log_line(const char *line)
{
    const char *path = getenv("BABET_FAKE_GTK_LOG");
    if (!path || !*path) return;
    FILE *stream = fopen(path, "a");
    if (!stream) return;
    fputs(line, stream); fputc('\n', stream); fclose(stream);
}

void gtk_disable_setlocale(void) { log_line("disable_setlocale"); }
int gtk_init_check(void) { log_line("init_check"); return 1; }
#include <stddef.h>

typedef void (*FakeCallback)(void);
typedef void (*FakeClosureNotify)(void *, void *);
typedef int (*FakeSourceCallback)(void *);

void *gtk_window_new(void) { return (void *)0x1; }
void gtk_window_set_title(void *w, const char *t) { (void)w; (void)t; }
void gtk_window_set_default_size(void *w, int x, int y) { (void)w; (void)x; (void)y; }
void gtk_window_set_child(void *w, void *c) { (void)w; (void)c; }
void gtk_window_present(void *w) { (void)w; }
void gtk_window_destroy(void *w) { (void)w; }
void *gtk_box_new(int o, int s) { (void)o; (void)s; return (void *)0x2; }
void gtk_box_append(void *b, void *c) { (void)b; (void)c; }
void *gtk_label_new(const char *t) { (void)t; return (void *)0x3; }
void gtk_label_set_text(void *l, const char *t) { (void)l; (void)t; }
void *gtk_button_new_with_label(const char *t) { (void)t; return (void *)0x4; }
void gtk_button_set_label(void *b, const char *t) { (void)b; (void)t; }
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
