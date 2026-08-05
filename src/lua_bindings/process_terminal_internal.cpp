#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "process_terminal_internal.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>

#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

namespace babet_process
{
namespace
{

bool set_terminal_foreground_group(int fd, pid_t pgid) noexcept
{
    sigset_t block_set;
    ::sigemptyset(&block_set);
    ::sigaddset(&block_set, SIGTTOU);

    sigset_t old_mask;
    const int mask_rc = ::pthread_sigmask(SIG_BLOCK, &block_set, &old_mask);
    if (mask_rc != 0)
    {
        errno = mask_rc;
        return false;
    }

    int rc = -1;
    do
    {
        rc = ::tcsetpgrp(fd, pgid);
    } while (rc != 0 && errno == EINTR);
    const int saved_errno = errno;

    const int restore_rc =
        ::pthread_sigmask(SIG_SETMASK, &old_mask, nullptr);
    if (rc == 0 && restore_rc != 0)
    {
        errno = restore_rc;
        return false;
    }

    errno = saved_errno;
    return rc == 0;
}

struct TerminalIdentity
{
    dev_t device = 0;
    ino_t inode = 0;
    bool valid = false;
};

struct TerminalHandoffRegistry
{
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    clockid_t condition_clock = CLOCK_REALTIME;
    bool reservation_active = false;
    unsigned long reservation_token = 0;
    unsigned long next_token = 0;
    pid_t owner_pgid = -1;
    pid_t restore_pgid = -1;
    struct termios restore_attributes{};
    bool attributes_valid = false;
    TerminalIdentity terminal;
};

TerminalHandoffRegistry terminal_handoff_registry{
    PTHREAD_MUTEX_INITIALIZER,
    {},
    CLOCK_REALTIME,
    false,
    0,
    0,
    -1,
    -1,
    {},
    false,
    {},
};

pthread_once_t terminal_registry_once = PTHREAD_ONCE_INIT;
int terminal_registry_init_error = 0;

void initialize_terminal_registry_condition() noexcept
{
    pthread_condattr_t attributes;
    const int attr_rc = ::pthread_condattr_init(&attributes);
    if (attr_rc != 0)
    {
        terminal_registry_init_error = ::pthread_cond_init(
            &terminal_handoff_registry.condition, nullptr);
        return;
    }

    if (::pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) == 0)
    {
        terminal_handoff_registry.condition_clock = CLOCK_MONOTONIC;
    }
    terminal_registry_init_error = ::pthread_cond_init(
        &terminal_handoff_registry.condition, &attributes);
    ::pthread_condattr_destroy(&attributes);
}

bool terminal_identity(int fd, TerminalIdentity &identity) noexcept
{
    struct stat st{};
    if (::fstat(fd, &st) != 0)
    {
        return false;
    }
    identity.device = st.st_dev;
    identity.inode = st.st_ino;
    identity.valid = true;
    return true;
}

bool same_terminal(const TerminalIdentity &left,
                   const TerminalIdentity &right) noexcept
{
    return left.valid && right.valid && left.device == right.device &&
           left.inode == right.inode;
}

bool lock_terminal_registry() noexcept
{
    const int once_rc = ::pthread_once(
        &terminal_registry_once, initialize_terminal_registry_condition);
    if (once_rc != 0 || terminal_registry_init_error != 0)
    {
        errno = once_rc != 0 ? once_rc : terminal_registry_init_error;
        return false;
    }

    const int rc = ::pthread_mutex_lock(&terminal_handoff_registry.mutex);
    if (rc != 0)
    {
        errno = rc;
        return false;
    }
    return true;
}

void unlock_terminal_registry() noexcept
{
    ::pthread_mutex_unlock(&terminal_handoff_registry.mutex);
}

void notify_terminal_registry() noexcept
{
    ::pthread_cond_broadcast(&terminal_handoff_registry.condition);
}

void clear_terminal_owner_locked() noexcept
{
    terminal_handoff_registry.owner_pgid = -1;
    terminal_handoff_registry.restore_pgid = -1;
    terminal_handoff_registry.attributes_valid = false;
    terminal_handoff_registry.terminal = {};
    notify_terminal_registry();
}

pid_t get_terminal_foreground_group(int fd) noexcept
{
    pid_t foreground_pgid = -1;
    do
    {
        foreground_pgid = ::tcgetpgrp(fd);
    } while (foreground_pgid < 0 && errno == EINTR);
    return foreground_pgid;
}

bool set_terminal_attributes(int fd,
                             const struct termios &attributes) noexcept
{
    int rc = -1;
    do
    {
        rc = ::tcsetattr(fd, TCSANOW, &attributes);
    } while (rc != 0 && errno == EINTR);
    return rc == 0;
}

bool direct_child_has_exited(pid_t pid) noexcept
{
    siginfo_t info{};
    int rc = -1;
    do
    {
        rc = ::waitid(P_PID, static_cast<id_t>(pid), &info,
                      WEXITED | WNOHANG | WNOWAIT);
    } while (rc != 0 && errno == EINTR);

    if (rc == 0)
    {
        return info.si_pid == pid;
    }
    // ECHILD signifie qu'un autre chemin a déjà récolté l'enfant direct.
    // Le registre contient encore toutes les données nécessaires pour rendre
    // le terminal sans toucher à un groupe vivant arbitraire.
    return errno == ECHILD;
}

bool restore_registered_terminal_locked(int fd, pid_t expected_owner,
                                        bool clear_if_reassigned) noexcept
{
    TerminalIdentity identity;
    if (!terminal_identity(fd, identity) ||
        !same_terminal(identity, terminal_handoff_registry.terminal) ||
        terminal_handoff_registry.owner_pgid != expected_owner)
    {
        return false;
    }

    const pid_t foreground_pgid = get_terminal_foreground_group(fd);
    if (foreground_pgid < 0)
    {
        return false;
    }

    if (foreground_pgid != expected_owner &&
        foreground_pgid != terminal_handoff_registry.restore_pgid)
    {
        // Un autre groupe a légitimement reçu le premier plan. Le moniteur
        // ancien ne doit jamais le lui reprendre.
        if (clear_if_reassigned)
        {
            clear_terminal_owner_locked();
        }
        return false;
    }

    bool foreground_restored = true;
    if (foreground_pgid == expected_owner &&
        terminal_handoff_registry.restore_pgid > 0)
    {
        foreground_restored = set_terminal_foreground_group(
            fd, terminal_handoff_registry.restore_pgid);
    }
    if (foreground_restored && terminal_handoff_registry.attributes_valid)
    {
        set_terminal_attributes(
            fd, terminal_handoff_registry.restore_attributes);
    }
    if (foreground_restored)
    {
        clear_terminal_owner_locked();
    }
    return foreground_restored;
}

detail::TerminalReservationResult reserve_terminal_handoff_impl(
    int fd, pid_t parent_pgid, unsigned long &token,
    struct termios &restore_attributes, bool has_launch_deadline,
    long long launch_deadline_ms) noexcept
{
    if (!lock_terminal_registry())
    {
        return detail::TerminalReservationResult::error;
    }

    constexpr long long default_busy_timeout_ms = 2000;
    long long wait_deadline_ms = now_ms() + default_busy_timeout_ms;
    if (has_launch_deadline && launch_deadline_ms < wait_deadline_ms)
    {
        wait_deadline_ms = launch_deadline_ms;
    }

    while (terminal_handoff_registry.reservation_active)
    {
        const long long remaining_ms = wait_deadline_ms - now_ms();
        if (remaining_ms <= 0)
        {
            unlock_terminal_registry();
            errno = ETIMEDOUT;
            return detail::TerminalReservationResult::busy;
        }

        struct timespec absolute{};
        if (::clock_gettime(terminal_handoff_registry.condition_clock,
                            &absolute) != 0)
        {
            unlock_terminal_registry();
            return detail::TerminalReservationResult::error;
        }
        absolute.tv_sec += static_cast<time_t>(remaining_ms / 1000);
        absolute.tv_nsec += static_cast<long>(
            (remaining_ms % 1000) * 1000000LL);
        if (absolute.tv_nsec >= 1000000000L)
        {
            ++absolute.tv_sec;
            absolute.tv_nsec -= 1000000000L;
        }

        const int wait_rc = ::pthread_cond_timedwait(
            &terminal_handoff_registry.condition,
            &terminal_handoff_registry.mutex, &absolute);
        if (wait_rc == ETIMEDOUT)
        {
            continue;
        }
        if (wait_rc != 0)
        {
            unlock_terminal_registry();
            errno = wait_rc;
            return detail::TerminalReservationResult::error;
        }
    }

    TerminalIdentity identity;
    if (!terminal_identity(fd, identity))
    {
        unlock_terminal_registry();
        return detail::TerminalReservationResult::error;
    }

    pid_t foreground_pgid = get_terminal_foreground_group(fd);
    if (foreground_pgid < 0)
    {
        unlock_terminal_registry();
        return detail::TerminalReservationResult::error;
    }

    if (foreground_pgid != parent_pgid &&
        terminal_handoff_registry.owner_pgid == foreground_pgid &&
        same_terminal(identity, terminal_handoff_registry.terminal) &&
        direct_child_has_exited(foreground_pgid))
    {
        // Le groupe de premier plan appartient à un enfant direct déjà
        // terminé dont le moniteur n'a pas encore été ordonnancé. La
        // restauration est effectuée ici, sous le même verrou que le prochain
        // transfert, afin qu'un spawn interactif immédiatement suivant ne
        // perde jamais silencieusement son terminal.
        if (!restore_registered_terminal_locked(fd, foreground_pgid, false))
        {
            unlock_terminal_registry();
            return detail::TerminalReservationResult::error;
        }
        foreground_pgid = get_terminal_foreground_group(fd);
        if (foreground_pgid < 0)
        {
            unlock_terminal_registry();
            return detail::TerminalReservationResult::error;
        }
    }

    if (foreground_pgid != parent_pgid)
    {
        unlock_terminal_registry();
        return detail::TerminalReservationResult::unavailable;
    }

    int attr_rc = -1;
    do
    {
        attr_rc = ::tcgetattr(fd, &restore_attributes);
    } while (attr_rc != 0 && errno == EINTR);
    if (attr_rc != 0)
    {
        unlock_terminal_registry();
        return detail::TerminalReservationResult::error;
    }

    terminal_handoff_registry.reservation_active = true;
    terminal_handoff_registry.reservation_token =
        ++terminal_handoff_registry.next_token;
    if (terminal_handoff_registry.reservation_token == 0)
    {
        terminal_handoff_registry.reservation_token =
            ++terminal_handoff_registry.next_token;
    }
    terminal_handoff_registry.terminal = identity;
    token = terminal_handoff_registry.reservation_token;
    unlock_terminal_registry();
    return detail::TerminalReservationResult::acquired;
}

void cancel_terminal_reservation_impl(unsigned long token) noexcept
{
    if (token == 0 || !lock_terminal_registry())
    {
        return;
    }
    if (terminal_handoff_registry.reservation_active &&
        terminal_handoff_registry.reservation_token == token)
    {
        terminal_handoff_registry.reservation_active = false;
        terminal_handoff_registry.reservation_token = 0;
        terminal_handoff_registry.terminal = {};
        notify_terminal_registry();
    }
    unlock_terminal_registry();
}

bool commit_terminal_handoff_impl(
    int fd, unsigned long token, pid_t child_pgid, pid_t restore_pgid,
    const struct termios &restore_attributes) noexcept
{
    if (token == 0 || child_pgid <= 0 || !lock_terminal_registry())
    {
        return false;
    }

    const bool reservation_matches =
        terminal_handoff_registry.reservation_active &&
        terminal_handoff_registry.reservation_token == token;
    if (!reservation_matches)
    {
        unlock_terminal_registry();
        errno = EBUSY;
        return false;
    }

    const bool foreground_set =
        set_terminal_foreground_group(fd, child_pgid);
    if (foreground_set)
    {
        terminal_handoff_registry.owner_pgid = child_pgid;
        terminal_handoff_registry.restore_pgid = restore_pgid;
        terminal_handoff_registry.restore_attributes = restore_attributes;
        terminal_handoff_registry.attributes_valid = true;
    }
    terminal_handoff_registry.reservation_active = false;
    terminal_handoff_registry.reservation_token = 0;
    if (!foreground_set)
    {
        terminal_handoff_registry.terminal = {};
    }
    notify_terminal_registry();
    unlock_terminal_registry();
    return foreground_set;
}

struct TerminalExitMonitorContext
{
    pid_t pid = -1;
    int pidfd = -1;
    int fd = -1;
    unsigned int test_delay_ms = 0;
};

void *terminal_exit_monitor_main(void *raw) noexcept
{
    std::unique_ptr<TerminalExitMonitorContext> context(
        static_cast<TerminalExitMonitorContext *>(raw));

    bool exited = false;
    if (context->pidfd >= 0)
    {
        struct pollfd pfd{};
        pfd.fd = context->pidfd;
        pfd.events = POLLIN;
        int rc = -1;
        // Le thread hérite du masque de signaux du thread créateur. Un
        // gestionnaire installé par le processus peut donc interrompre poll;
        // la reprise sur EINTR est nécessaire et ne doit pas être supprimée.
        do
        {
            rc = ::poll(&pfd, 1, -1);
        } while (rc < 0 && errno == EINTR);
        exited = rc > 0;
    }
    else
    {
        siginfo_t info{};
        int rc = -1;
        do
        {
            rc = ::waitid(P_PID, static_cast<id_t>(context->pid), &info,
                          WEXITED | WNOWAIT);
        } while (rc != 0 && errno == EINTR);
        exited = rc == 0;
    }

    if (exited)
    {
        if (context->test_delay_ms > 0)
        {
            struct timespec delay{};
            delay.tv_sec = context->test_delay_ms / 1000U;
            delay.tv_nsec = static_cast<long>(
                (context->test_delay_ms % 1000U) * 1000000U);
            while (::nanosleep(&delay, &delay) != 0 && errno == EINTR)
            {
            }
        }

        if (lock_terminal_registry())
        {
            TerminalIdentity identity;
            const bool registry_matches =
                terminal_identity(context->fd, identity) &&
                same_terminal(identity, terminal_handoff_registry.terminal) &&
                terminal_handoff_registry.owner_pgid == context->pid;
            if (registry_matches)
            {
                // Ne restaure que si cet enfant possède encore le terminal.
                // Si un transfert ultérieur a déjà eu lieu, l'ancien moniteur
                // n'a jamais le droit de reprendre le premier plan.
                restore_registered_terminal_locked(context->fd,
                                                    context->pid, true);
            }
            unlock_terminal_registry();
        }
    }

    close_fd(context->pidfd);
    close_fd(context->fd);
    return nullptr;
}

int open_pidfd(pid_t pid) noexcept
{
#ifdef SYS_pidfd_open
    return static_cast<int>(::syscall(SYS_pidfd_open, pid, 0));
#else
    (void)pid;
    errno = ENOSYS;
    return -1;
#endif
}

bool duplicate_fd_cloexec(int source, int &destination) noexcept
{
#ifdef F_DUPFD_CLOEXEC
    destination = ::fcntl(source, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
#else
    destination = ::fcntl(source, F_DUPFD, STDERR_FILENO + 1);
    if (destination >= 0)
    {
        const int flags = ::fcntl(destination, F_GETFD);
        if (flags < 0 ||
            ::fcntl(destination, F_SETFD, flags | FD_CLOEXEC) < 0)
        {
            const int saved = errno;
            ::close(destination);
            destination = -1;
            errno = saved;
        }
    }
#endif
    return destination >= 0;
}

bool start_terminal_exit_monitor_impl(pid_t pid,
                                      const TerminalHandoff &terminal,
                                      std::string &err)
{
    if (pid <= 0 || terminal.fd < 0 || terminal.restore_pgid <= 0)
    {
        return true;
    }

    int monitor_fd = -1;
    if (!duplicate_fd_cloexec(terminal.fd, monitor_fd))
    {
        err = std::string("cannot duplicate terminal monitor fd: ") +
              std::strerror(errno);
        return false;
    }

    auto *context = new (std::nothrow) TerminalExitMonitorContext;
    if (!context)
    {
        close_fd(monitor_fd);
        err = "cannot allocate terminal monitor state";
        return false;
    }
    context->pid = pid;
    context->pidfd = open_pidfd(pid);
    context->fd = monitor_fd;
    // Hook interne réservé à la régression PTY : il élargit de manière
    // déterministe la fenêtre entre la sortie et la restauration. La valeur
    // est lue avant la création du thread, bornée, et n'est documentée dans
    // aucune API publique.
    const char *delay_text =
        std::getenv("BABET_TEST_TERMINAL_MONITOR_DELAY_MS");
    if (delay_text && *delay_text)
    {
        char *end = nullptr;
        errno = 0;
        const unsigned long parsed = std::strtoul(delay_text, &end, 10);
        if (errno == 0 && end && *end == '\0')
        {
            context->test_delay_ms = static_cast<unsigned int>(
                std::min<unsigned long>(parsed, 5000UL));
        }
    }

    pthread_attr_t attributes;
    const int init_rc = ::pthread_attr_init(&attributes);
    if (init_rc != 0)
    {
        close_fd(context->fd);
        close_fd(context->pidfd);
        delete context;
        err = std::string("cannot configure terminal monitor: ") +
              std::strerror(init_rc);
        return false;
    }
    const int detach_state_rc = ::pthread_attr_setdetachstate(
        &attributes, PTHREAD_CREATE_DETACHED);
    if (detach_state_rc != 0)
    {
        ::pthread_attr_destroy(&attributes);
        close_fd(context->fd);
        close_fd(context->pidfd);
        delete context;
        err = std::string("cannot configure terminal monitor: ") +
              std::strerror(detach_state_rc);
        return false;
    }

    pthread_t thread{};
    const int create_rc = ::pthread_create(
        &thread, &attributes, terminal_exit_monitor_main, context);
    ::pthread_attr_destroy(&attributes);
    if (create_rc != 0)
    {
        close_fd(context->fd);
        close_fd(context->pidfd);
        delete context;
        err = std::string("cannot start terminal monitor: ") +
              std::strerror(create_rc);
        return false;
    }
    return true;
}
bool duplicate_terminal_fd_impl(int &fd) noexcept
{
#ifdef F_DUPFD_CLOEXEC
    fd = ::fcntl(STDIN_FILENO, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
#else
    fd = ::fcntl(STDIN_FILENO, F_DUPFD, STDERR_FILENO + 1);
    if (fd >= 0)
    {
        const int flags = ::fcntl(fd, F_GETFD);
        if (flags < 0 || ::fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0)
        {
            const int saved = errno;
            ::close(fd);
            fd = -1;
            errno = saved;
        }
    }
#endif
    return fd >= 0;
}

unsigned int reservation_test_delay_ms() noexcept
{
    const char *text = std::getenv(
        "BABET_TEST_TERMINAL_RESERVATION_DELAY_MS");
    if (!text || !*text)
    {
        return 0;
    }
    char *end = nullptr;
    errno = 0;
    const unsigned long parsed = std::strtoul(text, &end, 10);
    if (errno != 0 || !end || *end != '\0')
    {
        return 0;
    }
    return static_cast<unsigned int>(
        std::min<unsigned long>(parsed, 5000UL));
}

bool claim_reservation_test_marker() noexcept
{
    const char *path = std::getenv(
        "BABET_TEST_TERMINAL_RESERVATION_MARKER");
    if (!path || !*path)
    {
        return true;
    }
    const int fd = ::open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                          0600);
    if (fd < 0)
    {
        return false;
    }
    static constexpr char marker[] = "reserved\n";
    const ssize_t ignored = ::write(fd, marker, sizeof(marker) - 1);
    (void)ignored;
    ::close(fd);
    return true;
}

bool reclaim_terminal_impl(TerminalHandoff &terminal) noexcept
{
    if (terminal.fd < 0 || !terminal.active)
    {
        return true;
    }

    if (!lock_terminal_registry())
    {
        return false;
    }

    const pid_t foreground_pgid = get_terminal_foreground_group(terminal.fd);
    if (foreground_pgid < 0)
    {
        unlock_terminal_registry();
        return false;
    }

    if (foreground_pgid == terminal.owner_pgid)
    {
        struct termios child_attributes{};
        int attr_rc = -1;
        do
        {
            attr_rc = ::tcgetattr(terminal.fd, &child_attributes);
        } while (attr_rc != 0 && errno == EINTR);
        if (attr_rc == 0)
        {
            terminal.child_attributes = child_attributes;
            terminal.child_attributes_valid = true;
        }
    }

    bool restored = true;
    TerminalIdentity identity;
    const bool registry_matches =
        terminal_identity(terminal.fd, identity) &&
        same_terminal(identity, terminal_handoff_registry.terminal) &&
        terminal_handoff_registry.owner_pgid == terminal.owner_pgid;

    if (registry_matches)
    {
        if (foreground_pgid == terminal.owner_pgid ||
            foreground_pgid == terminal.restore_pgid)
        {
            restored = restore_registered_terminal_locked(
                terminal.fd, terminal.owner_pgid, false);
        }
        else
        {
            // Un transfert ultérieur a déjà placé un autre groupe au premier
            // plan. Cet ancien handle ne doit jamais lui voler le terminal.
            clear_terminal_owner_locked();
        }
    }
    else if (foreground_pgid == terminal.owner_pgid)
    {
        restored = terminal.restore_pgid <= 0 ||
                   set_terminal_foreground_group(terminal.fd,
                                                 terminal.restore_pgid);
        if (restored && terminal.attributes_valid)
        {
            set_terminal_attributes(terminal.fd,
                                    terminal.restore_attributes);
        }
    }
    else if (foreground_pgid == terminal.restore_pgid &&
             terminal.attributes_valid)
    {
        set_terminal_attributes(terminal.fd, terminal.restore_attributes);
    }
    // Si le premier plan appartient déjà à un autre groupe, rien n'est
    // modifié : le terminal a été transféré légitimement ailleurs.

    if (restored)
    {
        terminal.active = false;
    }
    unlock_terminal_registry();
    return restored;
}

bool foreground_terminal_impl(TerminalHandoff &terminal,
                         pid_t child_pgid) noexcept
{
    if (terminal.fd < 0 || child_pgid <= 0)
    {
        errno = ENOTTY;
        return false;
    }
    if (!lock_terminal_registry())
    {
        return false;
    }

    const pid_t foreground_pgid = get_terminal_foreground_group(terminal.fd);
    if (foreground_pgid < 0)
    {
        unlock_terminal_registry();
        return false;
    }
    if (foreground_pgid != terminal.restore_pgid &&
        foreground_pgid != child_pgid)
    {
        unlock_terminal_registry();
        errno = EBUSY;
        return false;
    }

    if (terminal.child_attributes_valid &&
        !set_terminal_attributes(terminal.fd, terminal.child_attributes))
    {
        unlock_terminal_registry();
        return false;
    }

    if (foreground_pgid != child_pgid &&
        !set_terminal_foreground_group(terminal.fd, child_pgid))
    {
        if (terminal.attributes_valid)
        {
            set_terminal_attributes(terminal.fd,
                                    terminal.restore_attributes);
        }
        unlock_terminal_registry();
        return false;
    }

    TerminalIdentity identity;
    if (!terminal_identity(terminal.fd, identity))
    {
        const int saved = errno;
        if (foreground_pgid != child_pgid && terminal.restore_pgid > 0)
        {
            set_terminal_foreground_group(terminal.fd,
                                          terminal.restore_pgid);
        }
        if (terminal.attributes_valid)
        {
            set_terminal_attributes(terminal.fd,
                                    terminal.restore_attributes);
        }
        unlock_terminal_registry();
        errno = saved;
        return false;
    }

    if (terminal_handoff_registry.owner_pgid > 0 &&
        terminal_handoff_registry.owner_pgid != child_pgid)
    {
        clear_terminal_owner_locked();
    }
    terminal_handoff_registry.owner_pgid = child_pgid;
    terminal_handoff_registry.restore_pgid = terminal.restore_pgid;
    terminal_handoff_registry.restore_attributes =
        terminal.restore_attributes;
    terminal_handoff_registry.attributes_valid = terminal.attributes_valid;
    terminal_handoff_registry.terminal = identity;
    notify_terminal_registry();

    terminal.owner_pgid = child_pgid;
    terminal.active = true;
    unlock_terminal_registry();
    return true;
}

void restore_terminal_impl(TerminalHandoff &terminal) noexcept
{
    if (terminal.fd >= 0)
    {
        reclaim_terminal_impl(terminal);
        close_fd(terminal.fd);
    }
    terminal.owner_pgid = -1;
    terminal.restore_pgid = -1;
    terminal.attributes_valid = false;
    terminal.child_attributes_valid = false;
    terminal.active = false;
}


} // namespace

namespace detail
{

TerminalReservationResult reserve_terminal_handoff(
    int fd, pid_t parent_pgid, unsigned long &token,
    struct termios &restore_attributes, bool has_launch_deadline,
    long long launch_deadline_ms) noexcept
{
    return reserve_terminal_handoff_impl(
        fd, parent_pgid, token, restore_attributes, has_launch_deadline,
        launch_deadline_ms);
}

void cancel_terminal_reservation(unsigned long token) noexcept
{
    cancel_terminal_reservation_impl(token);
}

bool commit_terminal_handoff(
    int fd, unsigned long token, pid_t child_pgid, pid_t restore_pgid,
    const struct termios &restore_attributes) noexcept
{
    return commit_terminal_handoff_impl(fd, token, child_pgid, restore_pgid,
                                        restore_attributes);
}

bool start_terminal_exit_monitor(pid_t pid, const TerminalHandoff &terminal,
                                 std::string &err)
{
    return start_terminal_exit_monitor_impl(pid, terminal, err);
}

bool duplicate_terminal_fd(int &fd) noexcept
{
    return duplicate_terminal_fd_impl(fd);
}

void delay_terminal_reservation_for_test() noexcept
{
    const unsigned int delay = reservation_test_delay_ms();
    if (delay == 0 || !claim_reservation_test_marker())
    {
        return;
    }
    struct timespec pause{};
    pause.tv_sec = static_cast<time_t>(delay / 1000U);
    pause.tv_nsec = static_cast<long>((delay % 1000U) * 1000000U);
    while (::nanosleep(&pause, &pause) != 0 && errno == EINTR)
    {
    }
}

} // namespace detail

bool reclaim_terminal(TerminalHandoff &terminal) noexcept
{
    return reclaim_terminal_impl(terminal);
}

bool foreground_terminal(TerminalHandoff &terminal, pid_t child_pgid) noexcept
{
    return foreground_terminal_impl(terminal, child_pgid);
}

void restore_terminal(TerminalHandoff &terminal) noexcept
{
    restore_terminal_impl(terminal);
}

} // namespace babet_process
