#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static FILE *image;
static int injected;
static const char *fault(void) { return getenv("BABET_TEST_IMAGE_FAULT"); }
static void observe_image(FILE *stream, const char *path)
{
    const char *mode = fault();
    if (!mode || strcmp(path, "/proc/self/exe")) return;
    image = stream;
    // fseeko may prefill a stdio buffer. Disable buffering before any I/O
    // so the injected descriptor fault really reaches the next fread.
    if (stream && (!strcmp(mode, "read") || !strcmp(mode, "eof")) &&
        setvbuf(stream, NULL, _IONBF, 0) != 0) _Exit(93);
}
static int opening(const char *path)
{
    const char *mode = fault();
    if (!mode || strcmp(path, "/proc/self/exe")) return 0;
    if (!strncmp(mode, "open-", 5))
    {
        fprintf(stderr, "IMAGE_IO_INJECTED:%s\n", mode);
        errno = atoi(mode + 5);
        return 1;
    }
    return 0;
}
FILE *fopen(const char *path, const char *mode)
{
    if (opening(path)) return NULL;
    FILE *(*next)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");
    FILE *result = next(path, mode);
    observe_image(result, path);
    return result;
}
FILE *fopen64(const char *path, const char *mode)
{
    if (opening(path)) return NULL;
    FILE *(*next)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen64");
    FILE *result = next(path, mode);
    observe_image(result, path);
    return result;
}
int fclose(FILE *stream)
{
    int (*next)(FILE *) = dlsym(RTLD_NEXT, "fclose");
    if (stream == image) image = NULL;
    return next(stream);
}
static void inject_read(FILE *stream)
{
    const char *mode = fault();
    if (!injected && image && stream == image && mode &&
        (!strcmp(mode, "read") || !strcmp(mode, "eof")))
    {
        injected = 1;
        // Change only this private image descriptor. A real stdio read then
        // sets ferror (write-only descriptor) or feof (empty /dev/null).
        int fd = open("/dev/null", (!strcmp(mode, "read") ? O_WRONLY : O_RDONLY) | O_CLOEXEC);
        if (fd < 0 || dup2(fd, fileno(stream)) < 0) _Exit(92);
        close(fd);
        fprintf(stderr, "IMAGE_IO_INJECTED:%s\n", mode);
    }
}
size_t fread(void *buffer, size_t size, size_t count, FILE *stream)
{
    size_t (*next)(void *, size_t, size_t, FILE *) = dlsym(RTLD_NEXT, "fread");
    inject_read(stream);
    return next(buffer, size, count, stream);
}
// Fortified builds can use this entry point for the fixed-size ZIP trailer.
size_t __fread_chk(void *buffer, size_t buffer_size, size_t size, size_t count, FILE *stream)
{
    size_t (*next)(void *, size_t, size_t, size_t, FILE *) = dlsym(RTLD_NEXT, "__fread_chk");
    inject_read(stream);
    return next(buffer, buffer_size, size, count, stream);
}
static int failing_seek(FILE *stream)
{
    const char *mode = fault();
    if (!injected && image && stream == image && mode && !strcmp(mode, "seek"))
    {
        injected = 1;
        fprintf(stderr, "IMAGE_IO_INJECTED:seek\n");
        errno = EIO;
        return 1;
    }
    return 0;
}
int fseeko(FILE *stream, off_t offset, int whence)
{
    if (failing_seek(stream)) return -1;
    int (*next)(FILE *, off_t, int) = dlsym(RTLD_NEXT, "fseeko");
    return next(stream, offset, whence);
}
int fseeko64(FILE *stream, off64_t offset, int whence)
{
    if (failing_seek(stream)) return -1;
    int (*next)(FILE *, off64_t, int) = dlsym(RTLD_NEXT, "fseeko64");
    return next(stream, offset, whence);
}
int fseek(FILE *stream, long offset, int whence)
{
    if (failing_seek(stream)) return -1;
    int (*next)(FILE *, long, int) = dlsym(RTLD_NEXT, "fseek");
    return next(stream, offset, whence);
}
