/* Deterministic runtime regression injection. Never linked into Babet. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*renameat_function)(int, const char *, int, const char *);
static renameat_function real_renameat;
static int injected;

static void put_file(const char *path)
{
    const char payload[] = "LATE-DATA";
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0 || write(fd, payload, sizeof(payload) - 1) != sizeof(payload) - 1)
    {
        perror("tree safety injection");
        _exit(90);
    }
    if (close(fd) != 0) _exit(91);
}

int renameat(int olddir, const char *oldpath, int newdir, const char *newpath)
{
    if (!real_renameat)
    {
        real_renameat = (renameat_function)dlsym(RTLD_NEXT, "renameat");
        if (!real_renameat) _exit(92);
    }
    const char *trigger = getenv("BABET_TEST_TREE_TRIGGER");
    const char *mode = getenv("BABET_TEST_TREE_MODE");
    const int match = !injected && olddir == AT_FDCWD && trigger && mode &&
                      strcmp(oldpath, trigger) == 0;
    if (match && strcmp(mode, "exdev") == 0)
    {
        injected = 1;
        put_file(getenv("BABET_TEST_TREE_MARKER"));
        errno = EXDEV;
        return -1;
    }
    const int rc = real_renameat(olddir, oldpath, newdir, newpath);
    const int saved_errno = errno;
    if (match && rc == 0)
    {
        injected = 1;
        const char *late = getenv("BABET_TEST_TREE_LATE");
        if (strcmp(mode, "replace_link") == 0 && unlink(late) != 0)
            _exit(93);
        put_file(late);
        put_file(getenv("BABET_TEST_TREE_MARKER"));
    }
    errno = saved_errno;
    return rc;
}
