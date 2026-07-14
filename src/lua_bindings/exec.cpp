// _GNU_SOURCE rend visibles les extensions GNU/Linux dans les
// headers POSIX : execvpe() (depuis glibc 2.11) et pipe2() (depuis
// glibc 2.9). pipe2() est formellement async-signal-safe et nous
// évite la fenêtre de race entre pipe() et fcntl(FD_CLOEXEC).
// execvpe() n'est PAS formellement async-signal-safe (résolution
// $PATH), mais permet d'éviter setenv() dans l'enfant après fork
// (un cas avéré de deadlock multi-thread) — gain pratique net. Le
// détail est dans le commentaire avant l'execvpe() lui-même + dans
// notes.md (dette technique : résoudre PATH côté parent un jour).
// DOIT être défini AVANT tous les includes système.
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "exec.hpp"
#include "lua_utils.hpp"

#include <string>
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

// `environ` est défini par la libc système (POSIX). Il pointe vers
// le tableau d'environnement du processus courant, terminé par NULL.
// On le lit dans le parent pour construire un envp custom avant fork,
// ce qui évite d'appeler setenv() dans l'enfant (non async-signal-safe,
// risque de deadlock heap en contexte multi-thread — cf. revue Gemini).
extern char **environ;

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

    // Construit argv depuis cmd + la table Lua à l'index `idx`.
    // argv[0] = cmd. Renvoie false et remplit `err` en cas d'argument invalide.
    bool collect_args(lua_State *L, int idx, const std::string &cmd,
                      std::vector<std::string> &out, std::string &err)
    {
        out.push_back(cmd); // argv[0] = nom du programme

        if (lua_isnoneornil(L, idx))
        {
            return true; // pas d'arguments, valide
        }
        if (!lua_istable(L, idx))
        {
            err = "args must be a table";
            return false;
        }

        lua_Integer n = luaL_len(L, idx);
        for (lua_Integer i = 1; i <= n; ++i)
        {
            lua_geti(L, idx, i);
            if (lua_type(L, -1) != LUA_TSTRING)
            {
                lua_pop(L, 1);
                err = "args must contain only strings";
                return false;
            }
            std::string arg;
            std::string label = "args[" + std::to_string(i) + "]";
            if (!lua_string_without_nul(L, -1, arg, label, err))
            {
                lua_pop(L, 1);
                return false;
            }
            out.push_back(std::move(arg));
            lua_pop(L, 1);
        }
        return true;
    }

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
        if (lua_isnoneornil(L, idx))
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
            if (lua_type(L, -1) != LUA_TSTRING)
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
            if (lua_type(L, -1) != LUA_TSTRING)
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
            if (lua_type(L, -1) != LUA_TNUMBER)
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
            if (lua_type(L, -1) != LUA_TNUMBER)
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
                if (lua_type(L, -2) != LUA_TSTRING ||
                    lua_type(L, -1) != LUA_TSTRING)
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

    bool set_nonblocking(int fd, const char *label, std::string &err)
    {
        int flags = ::fcntl(fd, F_GETFL, 0);
        if (flags < 0 || ::fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0)
        {
            err = std::string("exec: cannot make ") + label +
                  " non-blocking: " + std::strerror(errno);
            return false;
        }
        return true;
    }

    int push_exec_result(lua_State *L, const std::string &out_buf,
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

        lua_newtable(L);
        lua_pushlstring(L, out_buf.data(), out_buf.size());
        lua_setfield(L, -2, "stdout");
        lua_pushlstring(L, err_buf.data(), err_buf.size());
        lua_setfield(L, -2, "stderr");
        lua_pushinteger(L, exit_code);
        lua_setfield(L, -2, "code");
        lua_pushboolean(L, timed_out ? 1 : 0);
        lua_setfield(L, -2, "timed_out");
        lua_pushboolean(L, out_truncated ? 1 : 0);
        lua_setfield(L, -2, "stdout_truncated");
        lua_pushboolean(L, err_truncated ? 1 : 0);
        lua_setfield(L, -2, "stderr_truncated");
        lua_pushnil(L);
        return 2;
    }

} // namespace

int lua_exec(lua_State *L)
{
    // --- validation des arguments Lua -------------------------------
    if (lua_gettop(L) < 1 || lua_type(L, 1) != LUA_TSTRING)
    {
        return luaL_error(L, "Expected a string as first argument (command)");
    }
    std::string err;
    std::string cmd;
    if (!lua_string_without_nul(L, 1, cmd, "command", err))
    {
        return push_fail(L, err);
    }

    std::vector<std::string> args;
    if (!collect_args(L, 2, cmd, args, err))
    {
        return push_fail(L, err);
    }

    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env;
    std::string stdin_data;
    bool has_stdin = false;
    double timeout_sec = 0.0;
    bool has_timeout = false;
    size_t max_output = DEFAULT_MAX_OUTPUT;
    if (!collect_opts(L, 3, cwd, has_cwd, env, stdin_data, has_stdin,
                      timeout_sec, has_timeout, max_output, err))
    {
        return push_fail(L, err);
    }

    // La deadline commence avant toute préparation/fork : elle couvre donc
    // aussi la phase de lancement (chdir + exec), pas seulement les I/O
    // après exec.
    const long long deadline = has_timeout
                                   ? now_ms() + static_cast<long long>(
                                                    timeout_sec * 1000.0)
                                   : 0;

    // Tableau argv terminé par NULL pour exec.
    std::vector<char *> argv;
    argv.reserve(args.size() + 1);
    for (auto &a : args)
    {
        argv.push_back(const_cast<char *>(a.c_str()));
    }
    argv.push_back(nullptr);

    // CORRECTIF (post-revue Gemini, chantier 10-B) : préparer envp
    // ENTIÈREMENT CÔTÉ PARENT avant fork().
    //
    // Pourquoi : faire setenv() dans l'enfant après fork() est
    // dangereux en multi-thread. fork() ne copie qu'un seul thread,
    // mais hérite des locks tenus par les autres threads au moment
    // du fork — typiquement le lock global du tas (malloc). Si on
    // appelle setenv() dans l'enfant et qu'il tente malloc() pour
    // étendre `environ`, il bloque à jamais sur ce lock orphelin
    // -> deadlock infini, zombie permanent.
    //
    // Solution : construire le tableau envp dans le parent (où
    // malloc fonctionne normalement) et le passer à execvpe() dans
    // l'enfant. execvpe() n'est PAS formellement async-signal-safe
    // selon POSIX (résolution $PATH), mais en pratique sur glibc le
    // risque concret est très faible (cf. notes.md).
    //
    // Construction :
    //   1. Recopier l'environnement actuel (variable globale
    //      `environ`), en sautant les clés qui seront override.
    //   2. Ajouter les overrides depuis env (KEY=VALUE).
    //   3. Construire le char *[] terminé par NULL.
    //
    // env_strings garde le storage durable des std::string ;
    // envp_ptrs pointe dedans. Les deux restent vivants jusqu'après
    // l'exec : le fork copie tout, l'enfant lit envp_ptrs en
    // copy-on-write, c'est valide.
    std::vector<std::string> env_strings;
    std::vector<char *> envp_ptrs;

    // Set des clés à override pour skipper rapidement.
    std::unordered_set<std::string> override_keys;
    for (auto &kv : env)
    {
        override_keys.insert(kv.first);
    }

    // 1. Copier l'environnement courant, sauf clés override.
    if (environ != nullptr)
    {
        for (char **e = environ; *e != nullptr; ++e)
        {
            std::string entry(*e);
            // Chaque entrée est "KEY=VALUE" ; on extrait la clé pour
            // tester l'override. Si pas de '=' (cas pathologique),
            // on garde tel quel (un setenv normal ne produirait pas
            // ça).
            auto eq = entry.find('=');
            if (eq != std::string::npos)
            {
                std::string key = entry.substr(0, eq);
                if (override_keys.count(key) > 0)
                {
                    continue; // sera réécrite plus bas
                }
            }
            env_strings.push_back(std::move(entry));
        }
    }

    // 2. Ajouter les overrides (KEY=VALUE).
    for (auto &kv : env)
    {
        std::string entry = kv.first;
        entry.push_back('=');
        entry.append(kv.second);
        env_strings.push_back(std::move(entry));
    }

    // 3. Construire le tableau de pointeurs terminé par NULL.
    // Important : on remplit envp_ptrs APRÈS avoir terminé tous les
    // push_back sur env_strings, pour éviter qu'un realloc invalide
    // les pointeurs (data() devient invalide après realloc).
    envp_ptrs.reserve(env_strings.size() + 1);
    for (auto &s : env_strings)
    {
        envp_ptrs.push_back(s.data());
    }
    envp_ptrs.push_back(nullptr);

    // --- création des pipes -----------------------------------------
    int pipe_in[2], pipe_out[2], pipe_err[2], pipe_exec[2];

    auto close_pair = [](int p[2])
    { close(p[0]); close(p[1]); };

    // CORRECTIF (post-revue Gemini) : créer les pipes en O_CLOEXEC
    // ATOMIQUEMENT. Avec l'arrivée des workers (Chantier 8), une
    // séquence pipe() puis fcntl(FD_CLOEXEC) laisse une fenêtre
    // microscopique pendant laquelle un autre worker qui fait
    // fork+exec hérite des fd. Avec pipe2() la création + le flag
    // sont une seule opération atomique du noyau.
    //
    // Note : les pipes seront re-affectés à stdin/stdout/stderr du
    // child via dup2(). dup2() crée systématiquement un fd SANS
    // FD_CLOEXEC, donc nos fd 0/1/2 dans le child seront bien
    // hérités par l'exec final, comme avant. Seul le fd "source"
    // (par exemple pipe_in[0] avant dup2 dans le child, ou
    // pipe_in[1] dans le parent) bénéficie de la protection.
    auto make_pipe = [](int p[2]) -> int
    {
#ifdef O_CLOEXEC
        return pipe2(p, O_CLOEXEC);
#else
        // Fallback portable : pipe() + fcntl(F_SETFD). Non atomique
        // (fenêtre de race), mais maintient le comportement sur des
        // systèmes sans pipe2. Babet vise Linux où pipe2 est
        // toujours disponible (glibc 2.9+, Linux 2.6.27+).
        if (pipe(p) != 0)
            return -1;
        fcntl(p[0], F_SETFD, fcntl(p[0], F_GETFD) | FD_CLOEXEC);
        fcntl(p[1], F_SETFD, fcntl(p[1], F_GETFD) | FD_CLOEXEC);
        return 0;
#endif
    };

    if (make_pipe(pipe_in) != 0)
    {
        return push_fail(L, std::string("pipe2() failed: ") + std::strerror(errno));
    }
    if (make_pipe(pipe_out) != 0)
    {
        close_pair(pipe_in);
        return push_fail(L, std::string("pipe2() failed: ") + std::strerror(errno));
    }
    if (make_pipe(pipe_err) != 0)
    {
        close_pair(pipe_in);
        close_pair(pipe_out);
        return push_fail(L, std::string("pipe2() failed: ") + std::strerror(errno));
    }
    if (make_pipe(pipe_exec) != 0)
    {
        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        return push_fail(L, std::string("pipe2() failed: ") + std::strerror(errno));
    }
    // pipe_exec a déjà FD_CLOEXEC posé via pipe2 ci-dessus, donc
    // l'ancien fcntl explicite n'est plus nécessaire (idempotent
    // de toute façon, mais inutile).

    // --- fork -------------------------------------------------------
    pid_t pid = fork();
    if (pid < 0)
    {
        std::string msg = std::string("fork() failed: ") + std::strerror(errno);
        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        close_pair(pipe_exec);
        return push_fail(L, msg);
    }

    if (pid == 0)
    {
        // ===== processus enfant =====
        // Propre groupe de processus (pgid == pid) : permettra de tuer
        // tout l'arbre (enfant + descendants) via kill(-pid) au timeout.
        // Échec non fatal — on exécute quand même.
        setpgid(0, 0);

        dup2(pipe_in[0], STDIN_FILENO);
        dup2(pipe_out[1], STDOUT_FILENO);
        dup2(pipe_err[1], STDERR_FILENO);

        close_pair(pipe_in);
        close_pair(pipe_out);
        close_pair(pipe_err);
        close(pipe_exec[0]);

        if (has_cwd)
        {
            if (chdir(cwd.c_str()) != 0)
            {
                int e = errno;
                ssize_t wr = write(pipe_exec[1], &e, sizeof(e));
                (void)wr;
                _exit(127);
            }
        }

        // CORRECTIF Gemini : on N'APPELLE PAS setenv() dans
        // l'enfant. L'envp a été préparé dans le parent (voir
        // ci-dessus, avant fork). execvpe utilise notre envp
        // custom sans toucher à `environ`.
        //
        // Note de rigueur (post-revue ChatGPT) : execvpe() N'EST PAS
        // formellement async-signal-safe selon POSIX, car il fait
        // une résolution via $PATH (impliquant getenv("PATH"), non
        // listé en async-signal-safe). En pratique sur glibc, cette
        // résolution n'utilise que strchr/strncmp/access/stat (tous
        // async-signal-safe) et une lecture passive de `environ`
        // sans allocation, donc le risque concret est très faible.
        // Le fix "propre" serait de résoudre PATH côté parent et
        // d'appeler execve() avec un chemin absolu. C'est dans
        // notes.md comme dette technique reportée — pas bloquant
        // pour l'usage normal.
        //
        // execvpe est une extension GNU (Linux/glibc), comme pipe2.
        // Babet vise Linux ; sur un système qui ne fournit pas
        // execvpe, on retombe sur execvp en remplaçant `environ`
        // dans le child (sûr car mono-thread post-fork).
#ifdef __GLIBC__
        execvpe(cmd.c_str(), argv.data(), envp_ptrs.data());
#else
        // Fallback : pour les systèmes sans execvpe, on remplace
        // temporairement `environ` puis on appelle execvp. Sûr car
        // un seul thread après fork. Mêmes caveats async-signal
        // qu'execvpe (résolution PATH).
        environ = envp_ptrs.data();
        execvp(cmd.c_str(), argv.data());
#endif

        int e = errno;
        ssize_t wr = write(pipe_exec[1], &e, sizeof(e));
        (void)wr;
        _exit(127);
    }

    // ===== processus parent =====
    // Refait setpgid côté parent : idempotent avec celui de l'enfant,
    // ferme la course (selon l'ordonnancement, l'un des deux l'établit
    // en premier). Erreurs (ESRCH si l'enfant a déjà exec/terminé,
    // EACCES) volontairement ignorées.
    setpgid(pid, pid);

    close(pipe_in[0]);
    close(pipe_out[1]);
    close(pipe_err[1]);
    close(pipe_exec[1]);

    // --- détection d'un échec de lancement --------------------------
    // pipe_exec se ferme automatiquement au succès d'exec (CLOEXEC), ou
    // reçoit errno si chdir/exec échoue. L'attente est non bloquante et
    // utilise la même deadline absolue que le reste de l'appel.
    std::string nonblock_error;
    if (!set_nonblocking(pipe_exec[0], "launch pipe", nonblock_error))
    {
        close(pipe_in[1]);
        close(pipe_out[0]);
        close(pipe_err[0]);
        close(pipe_exec[0]);
        int ignored_status = 0;
        terminate_and_reap(pid, ignored_status);
        return push_fail(L, nonblock_error);
    }

    int launch_errno = 0;
    ssize_t launch_bytes = 0;
    bool launch_timed_out = false;
    std::string launch_internal_error;

    for (;;)
    {
        int timeout_ms = -1;
        if (has_timeout)
        {
            long long remaining = deadline - now_ms();
            timeout_ms = remaining <= 0
                             ? 0
                             : (remaining > INT_MAX
                                    ? INT_MAX
                                    : static_cast<int>(remaining));
        }

        struct pollfd launch_poll{};
        launch_poll.fd = pipe_exec[0];
        launch_poll.events = POLLIN;
        int pr = ::poll(&launch_poll, 1, timeout_ms);
        if (pr < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            launch_internal_error =
                std::string("exec: launch poll failed: ") +
                std::strerror(errno);
            break;
        }
        if (pr == 0)
        {
            launch_timed_out = true;
            break;
        }

        launch_bytes =
            ::read(pipe_exec[0], &launch_errno, sizeof(launch_errno));
        if (launch_bytes > 0)
        {
            if (launch_bytes != static_cast<ssize_t>(sizeof(launch_errno)))
            {
                launch_internal_error =
                    "exec: incomplete launch error received from child";
            }
            break;
        }
        if (launch_bytes == 0)
        {
            break; // CLOEXEC : lancement réussi
        }
        if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)
        {
            continue;
        }
        launch_internal_error =
            std::string("exec: cannot read launch status: ") +
            std::strerror(errno);
        break;
    }
    close(pipe_exec[0]);

    if (launch_timed_out || !launch_internal_error.empty())
    {
        close(pipe_in[1]);
        close(pipe_out[0]);
        close(pipe_err[0]);
        int status = 0;
        bool reaped = terminate_and_reap(pid, status);
        if (!launch_internal_error.empty())
        {
            if (!reaped)
            {
                launch_internal_error +=
                    " (child could not be reaped within cleanup deadline)";
            }
            return push_fail(L, launch_internal_error);
        }
        return push_exec_result(L, "", "", status, reaped, true, false,
                                false);
    }

    if (launch_bytes > 0)
    {
        close(pipe_in[1]);
        close(pipe_out[0]);
        close(pipe_err[0]);
        int status = 0;
        if (wait_child_until(pid, status, now_ms() + 2000) !=
            ChildWaitResult::reaped)
        {
            terminate_and_reap(pid, status);
        }
        return push_fail(L, std::string("cannot launch '") + cmd + "': " +
                                std::strerror(launch_errno));
    }

    // --- I/O concurrente, avec deadline éventuelle ------------------
    std::string out_buf, err_buf;
    bool out_truncated = false, err_truncated = false;

    if (!set_nonblocking(pipe_out[0], "stdout pipe", nonblock_error) ||
        !set_nonblocking(pipe_err[0], "stderr pipe", nonblock_error) ||
        !set_nonblocking(pipe_in[1], "stdin pipe", nonblock_error))
    {
        close(pipe_in[1]);
        close(pipe_out[0]);
        close(pipe_err[0]);
        int ignored_status = 0;
        terminate_and_reap(pid, ignored_status);
        return push_fail(L, nonblock_error);
    }

    size_t stdin_off = 0;
    bool in_open = has_stdin;
    if (!has_stdin)
    {
        close(pipe_in[1]);
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
                close(pipe_in[1]);
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
                        close(pipe_in[1]);
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
                        close(pipe_in[1]);
                        in_open = false;
                    }
                }
            }
        }
    }

    close(pipe_out[0]);
    close(pipe_err[0]);
    if (in_open)
    {
        close(pipe_in[1]);
        in_open = false;
    }

    if (!io_internal_error.empty())
    {
        int status = 0;
        bool reaped = terminate_and_reap(pid, status);
        if (!reaped)
        {
            io_internal_error +=
                " (child could not be reaped within cleanup deadline)";
        }
        return push_fail(L, io_internal_error);
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
        }
        else if (wait_result == ChildWaitResult::error)
        {
            return push_fail(L, std::string("exec: waitpid failed: ") +
                                    std::strerror(errno));
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
            return push_fail(L, std::string("exec: waitpid failed: ") +
                                    std::strerror(errno));
        }
    }

    return push_exec_result(L, out_buf, err_buf, status, status_valid,
                            timed_out, out_truncated, err_truncated);
}
