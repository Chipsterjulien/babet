#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Stop precisely after the builder's initial size check, before miniz opens
 * the selected source. The parent changes the file/inode, then releases us.
 * Both libc entry points are needed for native and large-file builds. */
static void pause_source(const char *path, const char *mode)
{
    static int fired;
    const char *target = getenv("BABET_TEST_PAUSE_OPEN");
    if (!fired && target && strcmp(path, target) == 0 && mode[0] == 'r')
    {
        fired = 1;
        const char ready[] = "BABET_OPEN_READY\n";
        if (write(STDOUT_FILENO, ready, sizeof ready - 1) != sizeof ready - 1)
            _exit(91);
        char go;
        ssize_t n;
        do { n = read(STDIN_FILENO, &go, 1); } while (n < 0 && errno == EINTR);
        if (n != 1 || go != 'G') _exit(92);
    }
}

FILE *fopen(const char *path, const char *mode)
{
    FILE *(*real_open)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
    if (!real_open) _exit(93);
    pause_source(path, mode);
    return real_open(path, mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    FILE *(*real_open)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen64");
    if (!real_open) _exit(94);
    pause_source(path, mode);
    return real_open(path, mode);
}
