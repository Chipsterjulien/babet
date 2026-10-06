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
#include "fake_gtk4_surface.inc"
