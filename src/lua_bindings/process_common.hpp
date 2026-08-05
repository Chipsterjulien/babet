#ifndef BABET_PROCESS_COMMON_HPP
#define BABET_PROCESS_COMMON_HPP

#include <lua.hpp>

#include <cstddef>
#include <string>
#include <utility>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>

namespace babet_process
{

inline constexpr std::size_t MAX_PIPELINE_STAGES = 32;

enum class StreamRedirectionKind
{
    pipe,
    inherit,
    null_device,
    file,
    stdout_stream,
};

struct FileRedirection
{
    std::string path;
    bool append = false;
    mode_t permissions = 0600;
};

struct StreamRedirection
{
    StreamRedirectionKind kind = StreamRedirectionKind::pipe;
    FileRedirection file;
};

struct LaunchSpec
{
    std::string command;
    std::vector<std::string> argv_strings; // argv[0] inclus
    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env_overrides;
    bool has_deadline = false;
    long long deadline_ms = 0;
    StreamRedirection stdin_redirection;
    StreamRedirection stdout_redirection;
    StreamRedirection stderr_redirection;
    const char *error_prefix = "process";
};

// État conservé par un spawn interactif dont stdin hérite du terminal de
// contrôle. Le handle processus conserve ce descripteur pour les transitions
// arrêt/reprise ; un moniteur natif en possède une duplication indépendante
// afin de restaurer le parent dès la fin définitive de l'enfant.
struct TerminalHandoff
{
    int fd = -1;
    // Groupe enfant exact auquel ce handle a transféré le premier plan. Il
    // permet aux nettoyages et moniteurs anciens de ne jamais voler le terminal
    // à un transfert interactif plus récent.
    pid_t owner_pgid = -1;
    pid_t restore_pgid = -1;
    struct termios restore_attributes{};
    bool attributes_valid = false;
    struct termios child_attributes{};
    bool child_attributes_valid = false;
    bool active = false;
};

struct LaunchedProcess
{
    pid_t pid = -1;
    int stdin_fd = -1;
    int stdout_fd = -1;
    int stderr_fd = -1;
    bool stdin_piped = false;
    bool stdout_piped = false;
    bool stderr_piped = false;
    TerminalHandoff terminal;
};

struct LaunchResult
{
    bool success = false;
    bool timed_out = false;
    std::string error;
    LaunchedProcess process;
    int status = 0;
    bool status_valid = false;
};

struct PipelineStageSpec
{
    std::string command;
    std::vector<std::string> argv_strings; // argv[0] inclus
    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env_overrides;
};

struct LaunchedPipelineChild
{
    pid_t pid = -1;
    int stderr_fd = -1;
};

struct LaunchedPipeline
{
    int stdin_fd = -1;
    int stdout_fd = -1;
    std::vector<LaunchedPipelineChild> children;
};

struct PipelineLaunchSpec
{
    std::vector<PipelineStageSpec> stages;
    bool has_deadline = false;
    long long deadline_ms = 0;
    const char *error_prefix = "pipeline";
};

struct PipelineLaunchResult
{
    bool success = false;
    bool timed_out = false;
    std::string error;
    LaunchedPipeline pipeline;
};

// Validation commune de cmd + args. `out` reçoit argv[0] == cmd.
bool collect_args(lua_State *L, int idx, const std::string &cmd,
                  std::vector<std::string> &out, std::string &err);

// Validation commune de opts.cwd et opts.env. Les autres champs sont laissés
// au binding appelant, qui peut avoir son propre contrat (exec/spawn).
bool collect_cwd_env(lua_State *L, int idx,
                     std::string &cwd, bool &has_cwd,
                     std::vector<std::pair<std::string, std::string>> &env,
                     std::string &err);

long long now_ms();
void kill_group(pid_t pid, int sig);

ssize_t write_without_sigpipe(int fd, const void *buf, size_t count);

enum class ChildWaitResult
{
    reaped,
    timed_out,
    error,
};

ChildWaitResult wait_child_until(pid_t pid, int &status,
                                 long long deadline_ms);
bool terminate_and_reap(pid_t pid, int &status);

bool set_nonblocking(int fd, const char *prefix, const char *label,
                     std::string &err);

void close_fd(int &fd) noexcept;
void close_process_fds(LaunchedProcess &process) noexcept;
// Rend le premier plan et les attributs sauvegardés au parent sans fermer le
// descripteur. Lorsqu'un enfant est suspendu, ses attributs courants sont
// mémorisés afin de pouvoir les restaurer avant une reprise au premier plan.
bool reclaim_terminal(TerminalHandoff &terminal) noexcept;
// Redonne le terminal au groupe enfant. Les attributs capturés lors du dernier
// arrêt sont restaurés avant le transfert du premier plan.
bool foreground_terminal(TerminalHandoff &terminal, pid_t child_pgid) noexcept;
void restore_terminal(TerminalHandoff &terminal) noexcept;

// Nettoyage d'urgence sans allocation C++ : ferme les flux, envoie SIGKILL
// au groupe puis tente de récolter l'enfant pendant une fenêtre courte.
// Destiné aux destructeurs RAII et aux catch(...) pendant un déroulement de
// pile ; aucun arrêt gracieux ne doit être tenté dans ce contexte.
bool emergency_kill_and_reap(LaunchedProcess &process,
                             long long reap_timeout_ms = 500) noexcept;

// Prépare les redirections, fork, configure le groupe de processus et attend
// le résultat de chdir/exec via un pipe CLOEXEC. Si stdin hérite d'un terminal
// dont Babet possède le premier plan, le groupe enfant reçoit ce terminal de
// manière synchronisée ; LaunchedProcess conserve de quoi gérer arrêt/reprise
// et un moniteur natif restaure aussi le parent après la fin définitive. En
// succès, seuls les flux configurés avec `pipe` possèdent un fd
// parent non bloquant.
LaunchResult launch(const LaunchSpec &spec);

// Variante multi-processus : stdout d'une étape est relié directement au stdin
// de la suivante. Le parent ne conserve que stdin de la première étape,
// stdout de la dernière et un stderr par étape. En cas d'échec partiel, tous
// les groupes déjà lancés sont terminés et les enfants directs sont réapés.
PipelineLaunchResult launch_pipeline(const PipelineLaunchSpec &spec);
void close_pipeline_fds(LaunchedPipeline &pipeline) noexcept;

// Variante pipeline du nettoyage d'urgence. Le vecteur d'enfants est déjà
// alloué par le lanceur ; la fonction n'alloue rien et marque les PID récoltés
// à -1 afin de ne jamais signaler ultérieurement un identifiant recyclé.
bool emergency_kill_and_reap(LaunchedPipeline &pipeline,
                             long long reap_timeout_ms = 500) noexcept;

int exit_code_from_status(int status, bool status_valid);

} // namespace babet_process

#endif // BABET_PROCESS_COMMON_HPP
