/* No shell: inspect the mask and exercise SIGTERM after Babet's execve. */
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    sigset_t mask;
    if (sigprocmask(SIG_SETMASK, NULL, &mask) != 0) return 80;
    for (int signal = 1; signal < NSIG; ++signal)
        if (sigismember(&mask, signal) == 1) return 81;
    if (argc == 2 && strcmp(argv[1], "--term") == 0)
    {
        raise(SIGTERM);
        return 82; /* A blocked/ignored SIGTERM must fail the test. */
    }
    puts("unblocked");
    return 0;
}
