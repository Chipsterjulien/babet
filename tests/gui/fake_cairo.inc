/* Narrow Cairo ABI for tests: no development headers are required. The real
 * Cairo variant links libcairo.so.2 and checks actual image pixels. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef BABET_TEST_REAL_CAIRO
typedef struct FakeCairo { int status; int depth; } FakeCairo;
static void fake_cairo_log(const char *name)
{
    const char *path = getenv("BABET_FAKE_CAIRO_LOG");
    if (path) {
        FILE *f = fopen(path, "a");
        if (f) { fprintf(f, "%s\n", name); fclose(f); }
    }
}
static void fake_cairo_op(void *cr, const char *name)
{
    const char *fail = getenv("BABET_FAKE_CAIRO_FAIL");
    if (fail && strcmp(fail, name) == 0) ((FakeCairo *)cr)->status = 1;
    fake_cairo_log(name);
}
int cairo_status(void *cr) { return ((FakeCairo *)cr)->status; }
const char *cairo_status_to_string(int status)
{ (void)status; return "injected Cairo failure"; }
void cairo_save(void *cr) { ++((FakeCairo *)cr)->depth; fake_cairo_op(cr, "save"); }
void cairo_restore(void *cr) { --((FakeCairo *)cr)->depth; fake_cairo_op(cr, "restore"); }
void cairo_new_path(void *cr) { fake_cairo_op(cr, "new_path"); }
void cairo_close_path(void *cr) { fake_cairo_op(cr, "close_path"); }
void cairo_stroke(void *cr) { fake_cairo_op(cr, "stroke"); }
void cairo_fill(void *cr) { fake_cairo_op(cr, "fill"); }
void cairo_move_to(void *cr, double x, double y)
{ (void)x; (void)y; fake_cairo_op(cr, "move_to"); }
void cairo_line_to(void *cr, double x, double y)
{ (void)x; (void)y; fake_cairo_op(cr, "line_to"); }
void cairo_rectangle(void *cr, double x, double y, double w, double h)
{ (void)x; (void)y; (void)w; (void)h; fake_cairo_op(cr, "rectangle"); }
void cairo_arc(void *cr, double x, double y, double r, double a, double b)
{ (void)x; (void)y; (void)r; (void)a; (void)b; fake_cairo_op(cr, "arc"); }
void cairo_set_line_width(void *cr, double w)
{ (void)w; fake_cairo_op(cr, "set_line_width"); }
void cairo_set_font_size(void *cr, double s)
{ (void)s; fake_cairo_op(cr, "set_font_size"); }
void cairo_set_source_rgb(void *cr, double r, double g, double b)
{ (void)r; (void)g; (void)b; fake_cairo_op(cr, "set_source_rgb"); }
void cairo_set_source_rgba(void *cr, double r, double g, double b, double a)
{ (void)r; (void)g; (void)b; (void)a; fake_cairo_op(cr, "set_source_rgba"); }
#ifndef BABET_FAKE_GTK_MISSING_CAIRO
void cairo_show_text(void *cr, const char *text)
{ (void)text; fake_cairo_op(cr, "show_text"); }
#endif
#else
extern void *cairo_image_surface_create(int format, int width, int height);
extern void *cairo_create(void *surface);
extern int cairo_status(void *cr);
extern void cairo_destroy(void *cr);
extern void cairo_surface_destroy(void *surface);
extern void cairo_surface_flush(void *surface);
extern unsigned char *cairo_image_surface_get_data(void *surface);
extern int cairo_image_surface_get_stride(void *surface);
extern double cairo_get_line_width(void *cr);
extern void cairo_debug_reset_static_data(void);
extern int FcInit(void);
extern void FcFini(void);
#endif
