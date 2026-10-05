/* Inject one real thread-directed SIGPIPE at an armed TLS socket BIO write.
 * This interposes libc write, so it also covers statically linked OpenSSL. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

typedef ssize_t (*write_fn)(int, const void *, size_t);
static write_fn real_write;
static int injected;

ssize_t write(int fd, const void *buf, size_t count)
{
    if (!real_write)
    {
        real_write = (write_fn)dlsym(RTLD_NEXT, "write");
        if (!real_write) _exit(90);
    }
    const int saved_errno = errno;
    const char *arm = getenv("BABET_TEST_SIGPIPE_ARM");
    int kind = 0;
    socklen_t length = sizeof(kind);
    if (!injected && arm && access(arm, F_OK) == 0 &&
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0 &&
        kind == SOCK_STREAM)
    {
        injected = 1;
        const char *marker = getenv("BABET_TEST_SIGPIPE_MARKER");
        int mark = marker ? open(marker, O_WRONLY | O_CREAT | O_EXCL, 0600) : -1;
        if (mark < 0) _exit(91);
        close(mark);
        if (raise(SIGPIPE) != 0) _exit(92);
        errno = EPIPE;
        return -1;
    }
    errno = saved_errno;
    return real_write(fd, buf, count);
}
