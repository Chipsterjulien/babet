// Le moteur commun prépare désormais argv, envp et la résolution PATH dans
// le parent. Après fork(), l'enfant n'effectue que les opérations POSIX
// nécessaires aux redirections, au cwd et à execve().

#include "exec.hpp"
#include "lua_utils.hpp"
#include "process_common.hpp"

#include <string>
#include <new>
#include <unordered_set>
#include <vector>
#include <utility>
#include <cmath>
#include <cstring>
#include <cerrno>
#include <climits>
#include <csignal>
#include <ctime>

#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <sys/wait.h>

namespace
{

    // Plafond par défaut, PAR FLUX (stdout et stderr séparément), de la
    // sortie capturée. Protège la RAM contre une commande intarissable.
    // Surchargable via opts.max_output.
    constexpr size_t DEFAULT_MAX_OUTPUT = 10 * 1024 * 1024; // 10 Mio

    // Borne haute FONCTIONNELLE de max_output : 2 Gio. Au-delà, capturer
    // en RAM n'a plus de sens (mieux vaut un fichier / du streaming).
    // 2 Gio == 2^31, exactement représentable en double : la comparaison
    // double évite à la fois l'UB du cast d'une valeur délirante et le
    // piège de SIZE_MAX (non représentable exactement en double, qui
    // arrondit au-dessus et laisserait passer un dépassement).
    constexpr size_t MAX_MAX_OUTPUT = 2ull * 1024 * 1024 * 1024; // 2 Gio

    // Lit opts.cwd, opts.env, opts.stdin et opts.timeout depuis la table `idx`.
    bool collect_opts(lua_State *L, int idx,
                      std::string &cwd, bool &has_cwd,
                      std::vector<std::pair<std::string, std::string>> &env,
                      std::string &stdin_data, bool &has_stdin,
                      double &timeout, bool &has_timeout,
                      size_t &max_output,
                      std::string &err)
    {
        has_cwd = false;
        has_stdin = false;
        has_timeout = false;
        if (lua_is_none_or_nil(L, idx))
        {
            return true; // pas d'options
        }
        if (!lua_istable(L, idx))
        {
            err = "opts must be a table";
            return false;
        }

        // opts.cwd
        lua_getfield(L, idx, "cwd");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_string(L, -1))
            {
                lua_pop(L, 1);
                err = "opts.cwd must be a string";
                return false;
            }
            if (!lua_string_without_nul(L, -1, cwd, "opts.cwd", err))
            {
                lua_pop(L, 1);
                return false;
            }
            has_cwd = true;
        }
        lua_pop(L, 1);

        // opts.stdin
        lua_getfield(L, idx, "stdin");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_string(L, -1))
            {
                lua_pop(L, 1);
                err = "opts.stdin must be a string";
                return false;
            }
            size_t len;
            const char *data = lua_tolstring(L, -1, &len);
            stdin_data.assign(data, len);
            has_stdin = true;
        }
        lua_pop(L, 1);

        // opts.timeout (en secondes, > 0)
        lua_getfield(L, idx, "timeout");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_number(L, -1))
            {
                lua_pop(L, 1);
                err = "opts.timeout must be a number";
                return false;
            }
            timeout = lua_tonumber(L, -1);
            // CORRECTIF (post-revue ChatGPT 10-D) : refuser NaN et Inf.
            // L'ancien test "timeout <= 0" laissait passer NaN (toute
            // comparaison contre NaN est false) et +Inf. Cohérent avec
            // workers::parse_timeout_arg et socket::set_timeout.
            if (std::isnan(timeout) || std::isinf(timeout))
            {
                lua_pop(L, 1);
                err = "opts.timeout must be a finite number";
                return false;
            }
            if (timeout <= 0)
            {
                lua_pop(L, 1);
                err = "opts.timeout must be greater than 0";
                return false;
            }
            // Borne commune aux API réseau : INT_MAX millisecondes
            // (~24,8 jours). Elle empêche tout dépassement lors de la
            // conversion en entier et lors du calcul de la deadline.
            if (timeout * 1000.0 > static_cast<double>(INT_MAX))
            {
                lua_pop(L, 1);
                err = "opts.timeout too large";
                return false;
            }
            has_timeout = true;
        }
        lua_pop(L, 1);

        // opts.max_output (octets, > 0). Plafond PAR FLUX de la sortie
        // capturée. Absent -> défaut appliqué par l'appelant.
        lua_getfield(L, idx, "max_output");
        if (!lua_isnil(L, -1))
        {
            if (!lua_is_strict_number(L, -1))
            {
                lua_pop(L, 1);
                err = "opts.max_output must be a number";
                return false;
            }
            double mo = lua_tonumber(L, -1);
            if (mo <= 0)
            {
                lua_pop(L, 1);
                err = "opts.max_output must be greater than 0";
                return false;
            }
            if (std::floor(mo) != mo)
            {
                lua_pop(L, 1);
                err = "opts.max_output must be an integer number of bytes";
                return false;
            }
            if (mo > static_cast<double>(MAX_MAX_OUTPUT))
            {
                lua_pop(L, 1);
                err = "opts.max_output too large (max 2 GiB; redirect to "
                      "a file or stream beyond that)";
                return false;
            }
            max_output = static_cast<size_t>(mo);
        }
        lua_pop(L, 1);

        // opts.env
        lua_getfield(L, idx, "env");
        if (!lua_isnil(L, -1))
        {
            if (!lua_istable(L, -1))
            {
                lua_pop(L, 1);
                err = "opts.env must be a table";
                return false;
            }
            int env_idx = lua_gettop(L); // index ABSOLU de la table env
            lua_pushnil(L);
            while (lua_next(L, env_idx) != 0)
            {
                if (!lua_is_strict_string(L, -2) ||
                    !lua_is_strict_string(L, -1))
                {
                    lua_pop(L, 3); // value, key, env_table
                    err = "opts.env must map strings to strings";
                    return false;
                }
                // CORRECTIF (post-revue ChatGPT 10-D) : valider la clé.
                // Avant le refactor 10-B, setenv() rejetait silencieusement
                // les clés invalides. Notre refactor construit envp en
                // concaténant "KEY=VALUE" : une clé contenant '=' ou '\0',
                // ou une clé vide, casse la sémantique POSIX (l'enfant
                // verrait getenv("A") == "B=x" pour env={["A=B"]="x"}).
                std::string key;
                std::string value;
                if (!lua_string_without_nul(L, -2, key,
                                            "opts.env: key", err))
                {
                    lua_pop(L, 3);
                    return false;
                }
                if (key.empty())
                {
                    lua_pop(L, 3);
                    err = "opts.env: key must not be empty";
                    return false;
                }
                if (key.find('=') != std::string::npos)
                {
                    lua_pop(L, 3);
                    err = "opts.env: key must not contain '='";
                    return false;
                }
                if (!lua_string_without_nul(L, -1, value,
                                            "opts.env: value", err))
                {
                    lua_pop(L, 3);
                    return false;
                }
                env.emplace_back(std::move(key), std::move(value));
                lua_pop(L, 1); // pop value, keep key pour lua_next
            }
        }
        lua_pop(L, 1); // pop env table (ou le nil)

        return true;
    }

    // Lit tout ce qui est disponible sur un fd non-bloquant.
    // Renvoie false si EOF ou erreur (le fd est terminé), true s'il reste ouvert.
    //
    // `buffer` ne dépasse jamais `max_bytes` : on garde les PREMIERS
    // octets, on jette le surplus et on positionne `truncated`. Crucial :
    // même une fois la limite atteinte, on CONTINUE à lire le pipe pour
    // le vider — sinon le process bloquerait sur write() (pipe plein) et
    // on réintroduirait le deadlock que le test "grosse sortie sans
    // deadlock" couvre justement. On jette, mais on draine.
    bool drain_fd(int fd, std::string &buffer, size_t max_bytes, bool &truncated)
    {
        char tmp[4096];
        while (true)
        {
            ssize_t n = read(fd, tmp, sizeof(tmp));
            if (n > 0)
            {
                size_t got = static_cast<size_t>(n);
                if (buffer.size() < max_bytes)
                {
                    size_t room = max_bytes - buffer.size();
                    if (got <= room)
                    {
                        buffer.append(tmp, got);
                    }
                    else
                    {
                        buffer.append(tmp, room);
                        truncated = true; // surplus jeté
                    }
                }
                else
                {
                    truncated = true; // budget déjà atteint : on draine et jette
                }
                // on NE s'arrête PAS : il faut continuer à lire pour
                // vider le pipe (anti-deadlock).
            }
            else if (n == 0)
            {
                return false; // EOF
            }
            else
            {
                if (errno == EINTR)
                {
                    continue;
                }
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                {
                    return true; // plus rien pour l'instant, fd encore ouvert
                }
                return false; // vraie erreur de lecture
            }
        }
    }

    // Renvoie un instant monotone en millisecondes.
    long long now_ms()
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        return static_cast<long long>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
    }

    // Tue tout le groupe de processus de l'enfant (l'enfant ET ses
    // descendants) : sans ça, une commande qui lance des sous-processus
    // laisserait des petits-enfants vivants après un timeout, et ceux-ci
    // gardant le pipe stdout ouvert, exec resterait bloqué.
    //
    // L'enfant a fait setpgid(0,0) -> son pgid == son pid, donc
    // kill(-pid) vise le groupe entier. Repli sur l'enfant seul si le
    // groupe n'existe pas (les DEUX setpgid ayant échoué, cas très rare).
    void kill_group(pid_t pid, int sig)
    {
        if (kill(-pid, sig) != 0 && errno == ESRCH)
        {
            kill(pid, sig);
        }
    }

    // Écrit dans un fd sans modifier la disposition process-wide de
    // SIGPIPE. Le signal est bloqué uniquement dans le thread appelant,
    // le temps de ce write(), puis consommé s'il a été généré par un EPIPE.
    // Un SIGPIPE déjà pending avant l'appel est préservé.
    ssize_t write_without_sigpipe(int fd, const void *buf, size_t count)
    {
        sigset_t block_set;
        sigemptyset(&block_set);
        sigaddset(&block_set, SIGPIPE);

        sigset_t old_mask;
        const int mask_rc = pthread_sigmask(SIG_BLOCK, &block_set, &old_mask);
        if (mask_rc != 0)
        {
            errno = mask_rc;
            return -1;
        }

        sigset_t pending_before_set;
        bool pending_before = false;
        if (sigpending(&pending_before_set) == 0)
        {
            pending_before = sigismember(&pending_before_set, SIGPIPE) == 1;
        }

        const ssize_t result = write(fd, buf, count);
        const int saved_errno = errno;

        if (result < 0 && saved_errno == EPIPE && !pending_before)
        {
            struct timespec zero_timeout{};
            while (sigtimedwait(&block_set, nullptr, &zero_timeout) < 0 &&
                   errno == EINTR)
            {
            }
        }

        pthread_sigmask(SIG_SETMASK, &old_mask, nullptr);
        errno = saved_errno;
        return result;
    }

    enum class ChildWaitResult
    {
        reaped,
        timed_out,
        error,
    };

    ChildWaitResult wait_child_until(pid_t pid, int &status,
                                     long long deadline_ms)
    {
        for (;;)
        {
            pid_t r = ::waitpid(pid, &status, WNOHANG);
            if (r == pid)
            {
                return ChildWaitResult::reaped;
            }
            if (r < 0)
            {
                if (errno == EINTR)
                {
                    continue;
                }
                return ChildWaitResult::error;
            }
            if (now_ms() >= deadline_ms)
            {
                return ChildWaitResult::timed_out;
            }
            struct timespec pause{0, 10 * 1000 * 1000};
            while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
            {
            }
        }
    }

    // Termine le groupe enfant sans waitpid bloquant non borné. Le cas
    // pathologique d'un processus figé en sommeil noyau non interruptible
    // ne peut pas être résolu par SIGKILL ; on préfère alors rendre la main
    // plutôt que bloquer Babet pour toujours.
    bool terminate_and_reap(pid_t pid, int &status)
    {
        kill_group(pid, SIGTERM);
        if (wait_child_until(pid, status, now_ms() + 500) ==
            ChildWaitResult::reaped)
        {
            return true;
        }
        kill_group(pid, SIGKILL);
        return wait_child_until(pid, status, now_ms() + 2000) ==
               ChildWaitResult::reaped;
    }

    class EmergencyExecGuard
    {
    public:
        EmergencyExecGuard(pid_t &pid, int &stdin_fd, int &stdout_fd,
                           int &stderr_fd) noexcept
            : pid_(pid), stdin_fd_(stdin_fd), stdout_fd_(stdout_fd),
              stderr_fd_(stderr_fd)
        {
        }

        EmergencyExecGuard(const EmergencyExecGuard &) = delete;
        EmergencyExecGuard &operator=(const EmergencyExecGuard &) = delete;

        ~EmergencyExecGuard() noexcept
        {
            cleanup_now();
        }

        void cleanup_now() noexcept
        {
            if (!armed_)
            {
                return;
            }
            babet_process::LaunchedProcess process;
            process.pid = pid_;
            process.stdin_fd = stdin_fd_;
            process.stdout_fd = stdout_fd_;
            process.stderr_fd = stderr_fd_;
            babet_process::emergency_kill_and_reap(process);
            pid_ = process.pid;
            stdin_fd_ = process.stdin_fd;
            stdout_fd_ = process.stdout_fd;
            stderr_fd_ = process.stderr_fd;
            armed_ = false;
        }

        void release() noexcept
        {
            armed_ = false;
        }

    private:
        pid_t &pid_;
        int &stdin_fd_;
        int &stdout_fd_;
        int &stderr_fd_;
        bool armed_ = true;
    };

    int push_exec_result_protected(lua_State *L,
                                   const std::string &out_buf,
                                   const std::string &err_buf, int status,
                                   bool status_valid, bool timed_out,
                                   bool out_truncated, bool err_truncated)
    {
        int exit_code = -1;
        if (status_valid)
        {
            if (WIFEXITED(status))
            {
                exit_code = WEXITSTATUS(status);
            }
            else if (WIFSIGNALED(status))
            {
                exit_code = 128 + WTERMSIG(status);
            }
        }

        auto builder = [&](lua_State *Ls) noexcept -> int
        {
            lua_newtable(Ls);
            lua_pushlstring(Ls, out_buf.data(), out_buf.size());
            lua_setfield(Ls, -2, "stdout");
            lua_pushlstring(Ls, err_buf.data(), err_buf.size());
            lua_setfield(Ls, -2, "stderr");
            lua_pushinteger(Ls, exit_code);
            lua_setfield(Ls, -2, "code");
            lua_pushboolean(Ls, timed_out ? 1 : 0);
            lua_setfield(Ls, -2, "timed_out");
            lua_pushboolean(Ls, out_truncated ? 1 : 0);
            lua_setfield(Ls, -2, "stdout_truncated");
            lua_pushboolean(Ls, err_truncated ? 1 : 0);
            lua_setfield(Ls, -2, "stderr_truncated");
            lua_pushnil(Ls);
            return 2;
        };
        return lua_build_results_protected(L, builder, 2);
    }

} // namespace

static int lua_exec_impl(lua_State *L)
{
    // --- validation des arguments Lua -------------------------------
    if (!lua_arity_between(L, 1, 3) ||
        !lua_is_strict_string(L, 1))
    {
        return luaL_error(L, "Expected a string as first argument (command)");
    }
    std::string err;
    std::string cmd;
    if (!lua_string_without_nul(L, 1, cmd, "command", err))
    {
        return push_fail_protected(L, err);
    }

    std::vector<std::string> args;
    bool args_ok = false;
    auto args_parser = [&](lua_State *Ls)
    {
        args_ok = babet_process::collect_args(Ls, 2, cmd, args, err);
    };
    lua_run_protected(L, args_parser);
    if (!args_ok)
    {
        return push_fail_protected(L, err);
    }

    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env;
    std::string stdin_data;
    bool has_stdin = false;
    double timeout_sec = 0.0;
    bool has_timeout = false;
    size_t max_output = DEFAULT_MAX_OUTPUT;
    bool opts_ok = false;
    auto opts_parser = [&](lua_State *Ls)
    {
        opts_ok = collect_opts(Ls, 3, cwd, has_cwd, env, stdin_data,
                               has_stdin, timeout_sec, has_timeout,
                               max_output, err);
    };
    lua_run_protected(L, opts_parser);
    if (!opts_ok)
    {
        return push_fail_protected(L, err);
    }

    // La deadline commence avant toute préparation/fork : elle couvre donc
    // aussi la phase de lancement (chdir + exec), pas seulement les I/O
    // après exec.
    const long long deadline = has_timeout
                                   ? now_ms() + static_cast<long long>(
                                                    timeout_sec * 1000.0)
                                   : 0;

    // Le lancement (pipes CLOEXEC, fork, groupe de processus, chdir,
    // environnement et détection d'échec exec) est partagé avec
    // babet.spawn(). L'API historique exec conserve toutefois sa propre
    // boucle d'I/O et son contrat de résultat capturé.
    babet_process::LaunchSpec launch_spec;
    launch_spec.command = cmd;
    launch_spec.argv_strings = args;
    launch_spec.cwd = cwd;
    launch_spec.has_cwd = has_cwd;
    launch_spec.env_overrides = env;
    launch_spec.has_deadline = has_timeout;
    launch_spec.deadline_ms = deadline;
    launch_spec.error_prefix = "exec";

    babet_process::LaunchResult launch_result =
        babet_process::launch(launch_spec);
    if (!launch_result.success)
    {
        if (launch_result.timed_out)
        {
            return push_exec_result_protected(
                L, "", "", launch_result.status,
                launch_result.status_valid, true, false, false);
        }
        return push_fail_protected(L, launch_result.error);
    }

    pid_t pid = launch_result.process.pid;
    int pipe_in[2] = {-1, launch_result.process.stdin_fd};
    int pipe_out[2] = {launch_result.process.stdout_fd, -1};
    int pipe_err[2] = {launch_result.process.stderr_fd, -1};
    launch_result.process.pid = -1;
    launch_result.process.stdin_fd = -1;
    launch_result.process.stdout_fd = -1;
    launch_result.process.stderr_fd = -1;

    EmergencyExecGuard emergency_guard(
        pid, pipe_in[1], pipe_out[0], pipe_err[0]);

    // IMPORTANT : aucun appel lua_* n'est autorisé tant que cette garde est
    // armée. Une erreur Lua utilise longjmp et contournerait son destructeur.

    // --- I/O concurrente, avec deadline éventuelle ------------------
    std::string out_buf, err_buf;
    bool out_truncated = false, err_truncated = false;

    size_t stdin_off = 0;
    bool in_open = has_stdin;
    if (!has_stdin)
    {
        babet_process::close_fd(pipe_in[1]);
    }

    bool out_open = true, err_open = true;
    std::string io_internal_error;

    // Gestion du timeout : on calcule un instant limite monotone.
    // `timed_out` retient si on a déclenché l'arrêt forcé.
    // `phase_kill` : false = on attend encore SIGTERM, true = SIGTERM déjà
    //   envoyé, on laisse un court délai de grâce avant SIGKILL.
    const long long grace_ms = 2000; // délai de grâce après SIGTERM
    long long kill_deadline = 0;
    bool timed_out = false;
    bool phase_kill = false;
    bool sigkill_sent = false;        // SIGKILL déjà envoyé : ne plus re-signaler
                                      // ni jamais bloquer le poll.
    long long post_kill_deadline = 0; // borne dure : on abandonne le
                                      // drainage passé ce délai.

    while (out_open || err_open || in_open)
    {
        int poll_timeout = -1; // -1 = bloquant (cas sans timeout)

        if (has_timeout)
        {
            if (sigkill_sent)
            {
                // SIGKILL déjà envoyé. On draine encore un peu (un
                // process en train de mourir peut produire de la sortie
                // utile), poll borné donc jamais bloquant. MAIS la
                // boucle ne se termine que sur EOF des pipes : si un
                // descendant a échappé au groupe (les DEUX setpgid
                // ratés, cas quasi impossible) et garde un fd ouvert,
                // l'EOF n'arrive jamais. Borne DURE post-SIGKILL : passé
                // ce délai, on sort de la boucle.
                //
                // On ne ferme PAS les pipes ici : les close() en aval
                // s'en chargent une seule fois. Les fermer maintenant
                // exposerait à un double-close (et à fermer le mauvais
                // fd si le numéro a été réattribué entre-temps).
                //
                // HONNÊTETÉ : dans ce cas extrême, la sortie capturée
                // peut être INCOMPLÈTE sans que stdout_truncated /
                // stderr_truncated soit positionné. Ces flags signifient
                // "limite max_output atteinte", PAS "abandon post-kill"
                // — causes distinctes, on ne les mélange pas. Pas de
                // champ d'API dédié : ce scénario suppose un double
                // échec de setpgid, trop marginal pour alourdir l'API.
                if (now_ms() >= post_kill_deadline)
                {
                    break;
                }
                poll_timeout = 100;
            }
            else
            {
                long long limit = phase_kill ? kill_deadline : deadline;
                long long remaining = limit - now_ms();
                if (remaining <= 0)
                {
                    if (!phase_kill)
                    {
                        // Délai dépassé : on demande poliment au process
                        // de s'arrêter, puis on laisse un court sursis.
                        kill_group(pid, SIGTERM);
                        timed_out = true;
                        phase_kill = true;
                        kill_deadline = now_ms() + grace_ms;
                        continue; // recalcule pour le prochain poll
                    }
                    else
                    {
                        // S'accroche malgré SIGTERM : on force, UNE fois.
                        kill_group(pid, SIGKILL);
                        sigkill_sent = true;
                        // Borne dure : au-delà, on abandonne le drainage
                        // (cf. branche sigkill_sent ci-dessus). Même 2 s
                        // que la grâce SIGTERM, par cohérence.
                        post_kill_deadline = now_ms() + grace_ms;
                        // On ne sort PAS tout de suite : on continue à
                        // drainer jusqu'à EOF ou jusqu'à cette deadline.
                        poll_timeout = 100;
                    }
                }
                else
                {
                    poll_timeout = (remaining > 1000000)
                                       ? 1000000
                                       : static_cast<int>(remaining);
                }
            }
        }

        struct pollfd fds[3];
        fds[0].fd = out_open ? pipe_out[0] : -1;
        fds[0].events = POLLIN;
        fds[0].revents = 0;

        fds[1].fd = err_open ? pipe_err[0] : -1;
        fds[1].events = POLLIN;
        fds[1].revents = 0;

        fds[2].fd = in_open ? pipe_in[1] : -1;
        fds[2].events = POLLOUT;
        fds[2].revents = 0;

        int pr = poll(fds, 3, poll_timeout);
        if (pr < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            io_internal_error =
                std::string("exec: poll failed: ") + std::strerror(errno);
            break;
        }
        if (pr == 0)
        {
            // poll a expiré sans événement : on reboucle, le bloc
            // de gestion du timeout en haut décidera quoi faire.
            continue;
        }

        // --- stdout ---
        if (out_open && (fds[0].revents & (POLLIN | POLLHUP | POLLERR)))
        {
            if (!drain_fd(pipe_out[0], out_buf, max_output, out_truncated))
            {
                out_open = false;
            }
        }

        // --- stderr ---
        if (err_open && (fds[1].revents & (POLLIN | POLLHUP | POLLERR)))
        {
            if (!drain_fd(pipe_err[0], err_buf, max_output, err_truncated))
            {
                err_open = false;
            }
        }

        // --- stdin ---
        if (in_open && (fds[2].revents & (POLLOUT | POLLERR | POLLHUP)))
        {
            size_t remaining = stdin_data.size() - stdin_off;
            if (remaining == 0)
            {
                babet_process::close_fd(pipe_in[1]);
                in_open = false;
            }
            else
            {
                ssize_t wn = write_without_sigpipe(
                    pipe_in[1], stdin_data.data() + stdin_off, remaining);
                if (wn > 0)
                {
                    stdin_off += static_cast<size_t>(wn);
                    if (stdin_off == stdin_data.size())
                    {
                        babet_process::close_fd(pipe_in[1]);
                        in_open = false;
                    }
                }
                else if (wn < 0)
                {
                    if (errno == EINTR ||
                        errno == EAGAIN || errno == EWOULDBLOCK)
                    {
                        // réessaiera au prochain tour de poll
                    }
                    else
                    {
                        babet_process::close_fd(pipe_in[1]);
                        in_open = false;
                    }
                }
            }
        }
    }

    babet_process::close_fd(pipe_out[0]);
    babet_process::close_fd(pipe_err[0]);
    if (in_open)
    {
        babet_process::close_fd(pipe_in[1]);
        in_open = false;
    }

    if (!io_internal_error.empty())
    {
        int status = 0;
        const bool reaped = terminate_and_reap(pid, status);
        if (reaped)
        {
            pid = -1;
        }
        else
        {
            io_internal_error +=
                " (child could not be reaped within cleanup deadline)";
        }
        emergency_guard.cleanup_now();
        return push_fail_protected(L, io_internal_error);
    }

    // --- code de sortie ---------------------------------------------
    int status = 0;
    bool status_valid = false;

    if (has_timeout && !timed_out)
    {
        // Les trois pipes peuvent être fermés par le child alors qu'il
        // continue à tourner. Le timeout doit donc aussi borner le waitpid
        // final, pas seulement la boucle d'I/O.
        ChildWaitResult wait_result = wait_child_until(pid, status, deadline);
        if (wait_result == ChildWaitResult::reaped)
        {
            status_valid = true;
            pid = -1;
        }
        else if (wait_result == ChildWaitResult::error)
        {
            emergency_guard.cleanup_now();
            return push_fail_protected(L, "exec: waitpid failed");
        }
        else
        {
            timed_out = true;
            kill_group(pid, SIGTERM);
            wait_result = wait_child_until(pid, status, now_ms() + grace_ms);
            if (wait_result != ChildWaitResult::reaped)
            {
                kill_group(pid, SIGKILL);
                wait_result = wait_child_until(pid, status,
                                               now_ms() + grace_ms);
            }
            status_valid = (wait_result == ChildWaitResult::reaped);
            if (status_valid)
            {
                pid = -1;
            }
        }
    }
    else if (timed_out)
    {
        // Ne jamais transformer un timeout demandé en waitpid bloquant
        // illimité. Le processus a déjà reçu TERM/KILL dans la boucle ;
        // on lui laisse une dernière fenêtre bornée pour être réapable.
        ChildWaitResult wait_result =
            wait_child_until(pid, status, now_ms() + 2000);
        if (wait_result != ChildWaitResult::reaped)
        {
            kill_group(pid, SIGKILL);
            wait_result = wait_child_until(pid, status, now_ms() + 500);
        }
        status_valid = (wait_result == ChildWaitResult::reaped);
        if (status_valid)
        {
            pid = -1;
        }
    }
    else
    {
        pid_t waited;
        do
        {
            waited = waitpid(pid, &status, 0);
        } while (waited < 0 && errno == EINTR);
        status_valid = (waited == pid);
        if (!status_valid)
        {
            emergency_guard.cleanup_now();
            return push_fail_protected(L, "exec: waitpid failed");
        }
        pid = -1;
    }

    if (pid > 0)
    {
        emergency_guard.cleanup_now();
    }
    else
    {
        emergency_guard.release();
    }
    return push_exec_result_protected(L, out_buf, err_buf, status,
                                      status_valid, timed_out, out_truncated,
                                      err_truncated);
}

int lua_exec(lua_State *L)
{
    return lua_cfunction_exception_boundary<lua_exec_impl>(
        L, "exec: out of memory during execution",
        "exec: internal execution failure",
        "exec: unknown internal execution failure");
}
