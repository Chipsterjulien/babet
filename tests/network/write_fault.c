/* Deterministic transport faults after Lua arms a marker. No production hooks.
 * libc write also intercepts socket BIO writes from statically linked OpenSSL. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef ssize_t (*write_fn)(int, const void *, size_t);
typedef ssize_t (*send_fn)(int, const void *, size_t, int);
typedef int (*poll_fn)(struct pollfd *, nfds_t, int);
static write_fn real_write;
static send_fn real_send;
static poll_fn real_poll;
static int stalled, interrupted;
static unsigned int completed_writes;

static const char *armed_mode(int fd)
{
    const char *arm = getenv("BABET_TEST_WRITE_ARM");
    const char *mode = getenv("BABET_TEST_WRITE_MODE");
    int kind;
    socklen_t size = sizeof(kind);
    if (arm && mode && access(arm, F_OK) == 0 &&
        getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &size) == 0 &&
        kind == SOCK_STREAM) return mode;
    return NULL;
}

static void mark_fault(void)
{
    if (stalled) return;
    const char *path = getenv("BABET_TEST_WRITE_MARKER");
    int fd = path ? open(path, O_WRONLY | O_CREAT | O_EXCL, 0600) : -1;
    if (fd < 0) _exit(91);
    close(fd);
    stalled = 1;
}

static ssize_t fault_write(int fd, const void *buf, size_t size, int flags,
                           int use_send)
{
    const int saved_errno = errno;
    const char *mode = armed_mode(fd);
    errno = saved_errno;
    if (!mode)
        return use_send ? real_send(fd, buf, size, flags) : real_write(fd, buf, size);
    if (stalled) { errno = EAGAIN; return -1; }
    if (strcmp(mode, "no-progress") == 0 || strcmp(mode, "fatal") == 0)
    {
        mark_fault();
        errno = strcmp(mode, "fatal") == 0 ? EIO : EAGAIN;
        return -1;
    }
    if (strcmp(mode, "after-fragment") == 0)
    {
        ssize_t rc = use_send ? real_send(fd, buf, size, flags) : real_write(fd, buf, size);
        /* One 64 KiB frame: header, then sixteen 4096-byte payload chunks. */
        if (rc == (ssize_t)size && ++completed_writes == 17) mark_fault();
        return rc;
    }
    if (size > 1) size = 1;
    ssize_t rc = use_send ? real_send(fd, buf, size, flags) : real_write(fd, buf, size);
    if (rc > 0) mark_fault();
    return rc;
}

ssize_t write(int fd, const void *buf, size_t size)
{
    if (!real_write) real_write = (write_fn)dlsym(RTLD_NEXT, "write");
    if (!real_write) _exit(92);
    return fault_write(fd, buf, size, 0, 0);
}
ssize_t send(int fd, const void *buf, size_t size, int flags)
{
    if (!real_send) real_send = (send_fn)dlsym(RTLD_NEXT, "send");
    if (!real_send) _exit(93);
    return fault_write(fd, buf, size, flags, 1);
}
static int fault_poll(struct pollfd *fds, nfds_t count, int timeout)
{
    if (!real_poll) real_poll = (poll_fn)dlsym(RTLD_NEXT, "poll");
    if (!real_poll) _exit(94);
    const int saved_errno = errno;
    for (nfds_t i = 0; i < count; ++i)
    {
        const char *mode = armed_mode(fds[i].fd);
        if (!mode || !(fds[i].events & POLLOUT)) continue;
        if (strcmp(mode, "before-write") == 0) mark_fault();
        if (!stalled) continue;
        for (nfds_t j = 0; j < count; ++j) fds[j].revents = 0;
        if (strcmp(mode, "partial-interrupt") == 0 && !interrupted)
        {
            interrupted = 1;
            if (raise(SIGUSR1) != 0) _exit(95);
            errno = EINTR;
            return -1;
        }
        errno = saved_errno;
        return 0;
    }
    errno = saved_errno;
    return real_poll(fds, count, timeout);
}

int poll(struct pollfd *fds, nfds_t count, int timeout)
{
    return fault_poll(fds, count, timeout);
}

/* Fortified/instrumented builds can call __poll_chk instead of poll. Without
 * this entry point the synthetic EAGAIN sees a genuinely writable socket and
 * the simulated timeout never fires. Preserve libc's bounds check on invalid
 * inputs rather than weakening FORTIFY in this test library. */
int __poll_chk(struct pollfd *fds, nfds_t count, int timeout, size_t bytes)
{
    if (count > bytes / sizeof(*fds))
    {
        typedef int (*checked_poll_fn)(struct pollfd *, nfds_t, int, size_t);
        checked_poll_fn checked = (checked_poll_fn)dlsym(RTLD_NEXT, "__poll_chk");
        if (!checked) _exit(96);
        return checked(fds, count, timeout, bytes);
    }
    return fault_poll(fds, count, timeout);
}
