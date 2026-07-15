#ifndef BABET_PROCESS_COMMON_HPP
#define BABET_PROCESS_COMMON_HPP

#include <lua.hpp>

#include <string>
#include <utility>
#include <vector>

#include <sys/types.h>

namespace babet_process
{

struct LaunchSpec
{
    std::string command;
    std::vector<std::string> argv_strings; // argv[0] inclus
    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env_overrides;
    bool has_deadline = false;
    long long deadline_ms = 0;
    const char *error_prefix = "process";
};

struct LaunchedProcess
{
    pid_t pid = -1;
    int stdin_fd = -1;
    int stdout_fd = -1;
    int stderr_fd = -1;
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

void close_fd(int &fd);
void close_process_fds(LaunchedProcess &process);

// Crée les pipes, fork, configure le groupe de processus et attend le résultat
// de chdir/exec via un pipe CLOEXEC. En succès, les trois fds parent sont
// non-bloquants et appartiennent à l'appelant.
LaunchResult launch(const LaunchSpec &spec);

// Variante multi-processus : stdout d'une étape est relié directement au stdin
// de la suivante. Le parent ne conserve que stdin de la première étape,
// stdout de la dernière et un stderr par étape. En cas d'échec partiel, tous
// les groupes déjà lancés sont terminés et les enfants directs sont réapés.
PipelineLaunchResult launch_pipeline(const PipelineLaunchSpec &spec);
void close_pipeline_fds(LaunchedPipeline &pipeline);

int exit_code_from_status(int status, bool status_valid);

} // namespace babet_process

#endif // BABET_PROCESS_COMMON_HPP
