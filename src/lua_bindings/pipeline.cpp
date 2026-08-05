#include "pipeline.hpp"
#include "process_common.hpp"
#include "lua_utils.hpp"
#include "signal.hpp"

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cmath>
#include <csignal>
#include <cstring>
#include <ctime>
#include <limits>
#include <new>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <poll.h>
#include <sys/wait.h>
#include <unistd.h>

namespace
{
constexpr const char *PIPELINE_META = "babet.pipeline_process";
constexpr size_t DEFAULT_MAX_OUTPUT = 10u * 1024u * 1024u;
constexpr size_t MAX_MAX_OUTPUT = 2u * 1024u * 1024u * 1024u;
constexpr size_t DEFAULT_READ_SIZE = 64u * 1024u;
constexpr size_t MAX_READ_SIZE = 16u * 1024u * 1024u;
constexpr double DEFAULT_TERMINATE_GRACE = 2.0;
constexpr long long TERM_GRACE_MS = 2000;

struct GlobalOptions
{
    std::string cwd;
    bool has_cwd = false;
    std::vector<std::pair<std::string, std::string>> env;
};

struct PipelineOptions : GlobalOptions
{
    std::string stdin_data;
    bool has_stdin = false;
    bool has_timeout = false;
    double timeout_sec = 0.0;
    size_t max_output = DEFAULT_MAX_OUTPUT;
};

struct SpawnPipelineOptions : GlobalOptions
{
    bool has_launch_timeout = false;
    long long launch_deadline_ms = 0;
};

struct ChildState
{
    pid_t pid = -1;
    int stderr_fd = -1;
    int status = 0;
    bool status_valid = false;
};

struct PipelineProcess
{
    size_t count;
    pid_t pids[babet_process::MAX_PIPELINE_STAGES];
    int stderr_fds[babet_process::MAX_PIPELINE_STAGES];
    int statuses[babet_process::MAX_PIPELINE_STAGES];
    bool status_valid[babet_process::MAX_PIPELINE_STAGES];
    int stdin_fd;
    int stdout_fd;
    bool closed;
};

bool dense_array(lua_State *L, int idx, size_t min_n, size_t max_n,
                 const char *label, size_t &n, std::string &err)
{
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = std::string(label) + " must be a table";
        return false;
    }
    idx = lua_absindex(L, idx);
    n = lua_rawlen(L, idx);
    if (n < min_n || n > max_n)
    {
        err = std::string(label) + " must contain between " +
              std::to_string(min_n) + " and " + std::to_string(max_n) +
              " entries";
        return false;
    }

    size_t seen = 0;
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_integer(L, -2))
        {
            lua_pop(L, 2);
            err = std::string(label) + " must be a dense array";
            return false;
        }
        const lua_Integer key = lua_tointeger(L, -2);
        if (key < 1 || static_cast<size_t>(key) > n)
        {
            lua_pop(L, 2);
            err = std::string(label) + " must be a dense array";
            return false;
        }
        ++seen;
        lua_pop(L, 1);
    }
    if (seen != n)
    {
        err = std::string(label) + " must be a dense array";
        return false;
    }
    return true;
}

bool validate_keys(lua_State *L, int idx,
                   const std::unordered_set<std::string> &allowed,
                   const char *label, std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    if (lua_type(L, idx) != LUA_TTABLE)
    {
        err = std::string(label) + " must be a table";
        return false;
    }

    idx = lua_absindex(L, idx);
    lua_pushnil(L);
    while (lua_next(L, idx) != 0)
    {
        if (!lua_is_strict_string(L, -2))
        {
            lua_pop(L, 2);
            err = std::string(label) + " keys must be strings";
            return false;
        }
        size_t len = 0;
        const char *data = lua_tolstring(L, -2, &len);
        const std::string key(data, len);
        if (allowed.count(key) == 0)
        {
            lua_pop(L, 2);
            err = std::string("unknown ") + label + " option: " + key;
            return false;
        }
        lua_pop(L, 1);
    }
    return true;
}

void raw_getfield(lua_State *L, int idx, const char *name)
{
    idx = lua_absindex(L, idx);
    lua_pushstring(L, name);
    lua_rawget(L, idx);
}

bool parse_timeout_value(lua_State *L, int idx, const char *label,
                         bool allow_absent, double &out, bool &present,
                         std::string &err)
{
    if (lua_is_none_or_nil(L, idx))
    {
        if (!allow_absent && lua_isnil(L, idx))
        {
            err = std::string(label) + " must be a number";
            return false;
        }
        out = 0.0;
        present = false;
        return true;
    }
    if (!lua_is_strict_number(L, idx))
    {
        err = std::string(label) + " must be a number";
        return false;
    }

    out = lua_tonumber(L, idx);
    if (!std::isfinite(out))
    {
        err = std::string(label) + " must be finite";
        return false;
    }
    if (out < 0.0)
    {
        err = std::string(label) + " must be greater than or equal to 0";
        return false;
    }
    if (out * 1000.0 > static_cast<double>(INT_MAX))
    {
        err = std::string(label) + " too large";
        return false;
    }
    present = true;
    return true;
}

void merge_env(const std::vector<std::pair<std::string, std::string>> &base,
               const std::vector<std::pair<std::string, std::string>> &local,
               std::vector<std::pair<std::string, std::string>> &out)
{
    out = base;
    std::unordered_map<std::string, size_t> positions;
    for (size_t i = 0; i < out.size(); ++i)
    {
        positions[out[i].first] = i;
    }
    for (const auto &kv : local)
    {
        const auto it = positions.find(kv.first);
        if (it == positions.end())
        {
            positions[kv.first] = out.size();
            out.push_back(kv);
        }
        else
        {
            out[it->second].second = kv.second;
        }
    }
}

bool collect_pipeline_options(lua_State *L, int idx, PipelineOptions &opts,
                              std::string &err)
{
    static const std::unordered_set<std::string> keys = {
        "cwd", "env", "stdin", "timeout", "max_output"
    };
    if (!validate_keys(L, idx, keys, "pipeline", err) ||
        !babet_process::collect_cwd_env(L, idx, opts.cwd, opts.has_cwd,
                                        opts.env, err))
    {
        return false;
    }
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }
    idx = lua_absindex(L, idx);

    raw_getfield(L, idx, "stdin");
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 1);
            err = "opts.stdin must be a string";
            return false;
        }
        size_t len = 0;
        const char *data = lua_tolstring(L, -1, &len);
        opts.stdin_data.assign(data, len);
        opts.has_stdin = true;
    }
    lua_pop(L, 1);

    raw_getfield(L, idx, "timeout");
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_number(L, -1))
        {
            lua_pop(L, 1);
            err = "opts.timeout must be a number";
            return false;
        }
        const double value = lua_tonumber(L, -1);
        if (!std::isfinite(value) || value <= 0.0 || value > 1e12)
        {
            lua_pop(L, 1);
            err = "opts.timeout must be a finite positive number";
            return false;
        }
        opts.has_timeout = true;
        opts.timeout_sec = value;
    }
    lua_pop(L, 1);

    raw_getfield(L, idx, "max_output");
    if (!lua_isnil(L, -1))
    {
        if (!lua_is_strict_integer(L, -1))
        {
            lua_pop(L, 1);
            err = "opts.max_output must be an integer";
            return false;
        }
        const lua_Integer value = lua_tointeger(L, -1);
        if (value < 1 ||
            static_cast<unsigned long long>(value) > MAX_MAX_OUTPUT)
        {
            lua_pop(L, 1);
            err = "opts.max_output must be between 1 and 2147483648";
            return false;
        }
        opts.max_output = static_cast<size_t>(value);
    }
    lua_pop(L, 1);
    return true;
}

bool collect_spawn_pipeline_options(lua_State *L, int idx,
                                    SpawnPipelineOptions &opts,
                                    std::string &err)
{
    static const std::unordered_set<std::string> keys = {
        "cwd", "env", "launch_timeout"
    };
    if (!validate_keys(L, idx, keys, "spawnPipeline", err) ||
        !babet_process::collect_cwd_env(L, idx, opts.cwd, opts.has_cwd,
                                        opts.env, err))
    {
        return false;
    }
    if (lua_is_none_or_nil(L, idx))
    {
        return true;
    }

    raw_getfield(L, idx, "launch_timeout");
    if (!lua_isnil(L, -1))
    {
        double timeout = 0.0;
        bool present = false;
        if (!parse_timeout_value(L, -1, "opts.launch_timeout", true,
                                 timeout, present, err))
        {
            lua_pop(L, 1);
            return false;
        }
        if (timeout <= 0.0)
        {
            lua_pop(L, 1);
            err = "opts.launch_timeout must be greater than 0";
            return false;
        }
        opts.has_launch_timeout = true;
        opts.launch_deadline_ms =
            babet_process::now_ms() +
            static_cast<long long>(std::ceil(timeout * 1000.0));
    }
    lua_pop(L, 1);
    return true;
}

bool collect_stages(
    lua_State *L, int idx, const GlobalOptions &global,
    std::vector<babet_process::PipelineStageSpec> &stages,
    std::string &err)
{
    size_t count = 0;
    if (!dense_array(L, idx, 2, babet_process::MAX_PIPELINE_STAGES,
                     "commands", count, err))
    {
        return false;
    }
    idx = lua_absindex(L, idx);
    stages.reserve(count);
    static const std::unordered_set<std::string> local_keys = {"cwd", "env"};

    for (size_t i = 1; i <= count; ++i)
    {
        lua_rawgeti(L, idx, static_cast<lua_Integer>(i));
        const int stage_idx = lua_absindex(L, -1);
        size_t stage_size = 0;
        const std::string label = "commands[" + std::to_string(i) + "]";
        if (!dense_array(L, stage_idx, 1, 3, label.c_str(),
                         stage_size, err))
        {
            lua_pop(L, 1);
            return false;
        }

        lua_rawgeti(L, stage_idx, 1);
        if (!lua_is_strict_string(L, -1))
        {
            lua_pop(L, 2);
            err = label + "[1] must be a string";
            return false;
        }

        babet_process::PipelineStageSpec stage;
        if (!lua_string_without_nul(L, -1, stage.command,
                                    label + "[1]", err))
        {
            lua_pop(L, 2);
            return false;
        }
        if (stage.command.empty())
        {
            lua_pop(L, 2);
            err = label + "[1] must not be empty";
            return false;
        }
        lua_pop(L, 1);

        lua_rawgeti(L, stage_idx, 2);
        if (!babet_process::collect_args(L, -1, stage.command,
                                         stage.argv_strings, err))
        {
            lua_pop(L, 2);
            err = label + ": " + err;
            return false;
        }
        lua_pop(L, 1);

        std::string local_cwd;
        bool has_local_cwd = false;
        std::vector<std::pair<std::string, std::string>> local_env;
        lua_rawgeti(L, stage_idx, 3);
        if (!validate_keys(L, -1, local_keys, "stage", err) ||
            !babet_process::collect_cwd_env(L, -1, local_cwd,
                                            has_local_cwd, local_env, err))
        {
            lua_pop(L, 2);
            err = label + ": " + err;
            return false;
        }
        lua_pop(L, 1);

        stage.has_cwd = has_local_cwd || global.has_cwd;
        stage.cwd = has_local_cwd ? local_cwd : global.cwd;
        merge_env(global.env, local_env, stage.env_overrides);
        stages.push_back(std::move(stage));
        lua_pop(L, 1);
    }
    return true;
}

void kill_all(const std::vector<ChildState> &children, int signal)
{
    for (const ChildState &child : children)
    {
        // Un PID réapé peut être recyclé. Ne jamais ressignaler un étage dont
        // le statut a déjà été consommé.
        if (!child.status_valid && child.pid > 0)
        {
            babet_process::kill_group(child.pid, signal);
        }
    }
}

void reap_all(std::vector<ChildState> &children, long long deadline)
{
    for (ChildState &child : children)
    {
        if (child.status_valid || child.pid <= 0)
        {
            continue;
        }
        const auto result = babet_process::wait_child_until(
            child.pid, child.status, deadline);
        child.status_valid =
            result == babet_process::ChildWaitResult::reaped;
    }
}


class LaunchedPipelineGuard
{
public:
    explicit LaunchedPipelineGuard(
        babet_process::LaunchedPipeline &pipeline) noexcept
        : pipeline_(pipeline)
    {
    }

    LaunchedPipelineGuard(const LaunchedPipelineGuard &) = delete;
    LaunchedPipelineGuard &operator=(const LaunchedPipelineGuard &) = delete;

    ~LaunchedPipelineGuard() noexcept
    {
        if (armed_)
        {
            babet_process::emergency_kill_and_reap(pipeline_);
        }
    }

    void release() noexcept
    {
        armed_ = false;
    }

private:
    babet_process::LaunchedPipeline &pipeline_;
    bool armed_ = true;
};

class SyncPipelineGuard
{
public:
    SyncPipelineGuard(int &stdin_fd, int &stdout_fd,
                      std::vector<ChildState> &children) noexcept
        : stdin_fd_(stdin_fd), stdout_fd_(stdout_fd), children_(children)
    {
    }

    SyncPipelineGuard(const SyncPipelineGuard &) = delete;
    SyncPipelineGuard &operator=(const SyncPipelineGuard &) = delete;

    ~SyncPipelineGuard() noexcept
    {
        cleanup_now();
    }

    void cleanup_now() noexcept
    {
        if (!armed_)
        {
            return;
        }
        babet_process::close_fd(stdin_fd_);
        babet_process::close_fd(stdout_fd_);
        for (ChildState &child : children_)
        {
            babet_process::close_fd(child.stderr_fd);
        }
        kill_all(children_, SIGKILL);
        reap_all(children_, babet_process::now_ms() + 500);
        armed_ = false;
    }

    void release() noexcept
    {
        armed_ = false;
    }

private:
    int &stdin_fd_;
    int &stdout_fd_;
    std::vector<ChildState> &children_;
    bool armed_ = true;
};

bool drain_fd(int fd, std::string &buffer, size_t limit, bool &truncated)
{
    char temp[16384];
    for (;;)
    {
        const ssize_t count = ::read(fd, temp, sizeof(temp));
        if (count > 0)
        {
            const size_t available = limit > buffer.size()
                                         ? limit - buffer.size()
                                         : 0;
            const size_t keep = std::min(static_cast<size_t>(count),
                                         available);
            if (keep > 0)
            {
                buffer.append(temp, keep);
            }
            if (keep < static_cast<size_t>(count))
            {
                truncated = true;
            }
            continue;
        }
        if (count == 0)
        {
            return false;
        }
        if (errno == EINTR)
        {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
        {
            return true;
        }
        return false;
    }
}

void push_stage_status(lua_State *L, int status, bool status_valid)
{
    lua_newtable(L);
    lua_pushboolean(L, 1);
    lua_setfield(L, -2, "launched");

    const int code = babet_process::exit_code_from_status(status,
                                                          status_valid);
    lua_pushinteger(L, code);
    lua_setfield(L, -2, "code");

    const bool exited = status_valid && WIFEXITED(status);
    const bool signaled = status_valid && WIFSIGNALED(status);
    lua_pushboolean(L, exited);
    lua_setfield(L, -2, "exited");
    lua_pushboolean(L, signaled);
    lua_setfield(L, -2, "signaled");
    if (signaled)
    {
        lua_pushinteger(L, WTERMSIG(status));
    }
    else
    {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "signal");
}

int push_status_result(lua_State *L, const int *statuses,
                       const bool *status_valid, size_t count)
{
    lua_newtable(L);
    lua_createtable(L, static_cast<int>(count), 0);

    bool all_succeeded = true;
    size_t failed_index = 0;
    for (size_t i = 0; i < count; ++i)
    {
        push_stage_status(L, statuses[i], status_valid[i]);
        lua_seti(L, -2, static_cast<lua_Integer>(i + 1));
        const int code = babet_process::exit_code_from_status(
            statuses[i], status_valid[i]);
        if (code != 0)
        {
            all_succeeded = false;
            if (failed_index == 0)
            {
                failed_index = i + 1;
            }
        }
    }
    lua_setfield(L, -2, "stages");

    const int code = count == 0
                         ? -1
                         : babet_process::exit_code_from_status(
                               statuses[count - 1], status_valid[count - 1]);
    lua_pushinteger(L, code);
    lua_setfield(L, -2, "code");
    lua_pushboolean(L, all_succeeded);
    lua_setfield(L, -2, "all_succeeded");
    if (failed_index != 0)
    {
        lua_pushinteger(L, static_cast<lua_Integer>(failed_index));
    }
    else
    {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "failed_index");
    lua_pushnil(L);
    return 2;
}

int push_status_result_protected(lua_State *L, const int *statuses,
                                 const bool *status_valid, size_t count)
{
    auto builder = [statuses, status_valid, count](lua_State *Ls) noexcept -> int
    {
        return push_status_result(Ls, statuses, status_valid, count);
    };
    return lua_build_results_protected(L, builder, 2);
}

int push_sync_result(lua_State *L, const std::string &stdout_data,
                     const std::vector<std::string> &stderr_data,
                     const std::vector<unsigned char> &stderr_truncated,
                     const std::vector<ChildState> &children,
                     bool timed_out, bool stdout_truncated)
{
    lua_newtable(L);
    lua_pushlstring(L, stdout_data.data(), stdout_data.size());
    lua_setfield(L, -2, "stdout");

    lua_createtable(L, static_cast<int>(stderr_data.size()), 0);
    for (size_t i = 0; i < stderr_data.size(); ++i)
    {
        lua_pushlstring(L, stderr_data[i].data(), stderr_data[i].size());
        lua_seti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    lua_setfield(L, -2, "stderr");

    lua_createtable(L, static_cast<int>(children.size()), 0);
    bool all_succeeded = true;
    size_t failed_index = 0;
    for (size_t i = 0; i < children.size(); ++i)
    {
        push_stage_status(L, children[i].status, children[i].status_valid);
        lua_seti(L, -2, static_cast<lua_Integer>(i + 1));
        const int code = babet_process::exit_code_from_status(
            children[i].status, children[i].status_valid);
        if (code != 0)
        {
            all_succeeded = false;
            if (failed_index == 0)
            {
                failed_index = i + 1;
            }
        }
    }
    lua_setfield(L, -2, "stages");

    const int code = children.empty()
                         ? -1
                         : babet_process::exit_code_from_status(
                               children.back().status,
                               children.back().status_valid);
    lua_pushinteger(L, code);
    lua_setfield(L, -2, "code");
    lua_pushboolean(L, all_succeeded);
    lua_setfield(L, -2, "all_succeeded");
    if (failed_index != 0)
    {
        lua_pushinteger(L, static_cast<lua_Integer>(failed_index));
    }
    else
    {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "failed_index");
    lua_pushboolean(L, timed_out);
    lua_setfield(L, -2, "timed_out");
    lua_pushboolean(L, stdout_truncated);
    lua_setfield(L, -2, "stdout_truncated");

    lua_createtable(L, static_cast<int>(stderr_truncated.size()), 0);
    for (size_t i = 0; i < stderr_truncated.size(); ++i)
    {
        lua_pushboolean(L, stderr_truncated[i] != 0);
        lua_seti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    lua_setfield(L, -2, "stderr_truncated");
    lua_pushnil(L);
    return 2;
}

int push_sync_result_protected(
    lua_State *L, const std::string &stdout_data,
    const std::vector<std::string> &stderr_data,
    const std::vector<unsigned char> &stderr_truncated,
    const std::vector<ChildState> &children,
    bool timed_out, bool stdout_truncated)
{
    auto builder = [&](lua_State *Ls) noexcept -> int
    {
        return push_sync_result(Ls, stdout_data, stderr_data,
                                stderr_truncated, children, timed_out,
                                stdout_truncated);
    };
    return lua_build_results_protected(L, builder, 2);
}

PipelineProcess *check_pipeline_process(lua_State *L, int idx)
{
    return static_cast<PipelineProcess *>(
        luaL_checkudata(L, idx, PIPELINE_META));
}

PipelineProcess *push_empty_pipeline_process(lua_State *L)
{
    void *raw = lua_newuserdatauv(L, sizeof(PipelineProcess), 0);
    auto *pipeline = static_cast<PipelineProcess *>(raw);
    pipeline->count = 0;
    pipeline->stdin_fd = -1;
    pipeline->stdout_fd = -1;
    pipeline->closed = true;
    for (size_t i = 0; i < babet_process::MAX_PIPELINE_STAGES; ++i)
    {
        pipeline->pids[i] = -1;
        pipeline->stderr_fds[i] = -1;
        pipeline->statuses[i] = 0;
        pipeline->status_valid[i] = false;
    }
    luaL_getmetatable(L, PIPELINE_META);
    lua_setmetatable(L, -2);
    return pipeline;
}

bool initialize_pipeline_process(
    PipelineProcess *pipeline,
    babet_process::LaunchedPipeline &launched)
{
    if (launched.children.size() > babet_process::MAX_PIPELINE_STAGES)
    {
        return false;
    }
    pipeline->count = launched.children.size();
    pipeline->stdin_fd = launched.stdin_fd;
    pipeline->stdout_fd = launched.stdout_fd;
    pipeline->closed = false;
    launched.stdin_fd = -1;
    launched.stdout_fd = -1;

    for (size_t i = 0; i < pipeline->count; ++i)
    {
        pipeline->pids[i] = launched.children[i].pid;
        pipeline->stderr_fds[i] = launched.children[i].stderr_fd;
        pipeline->statuses[i] = 0;
        pipeline->status_valid[i] = false;
        launched.children[i].stderr_fd = -1;
    }
    return true;
}

enum class StageRefreshResult
{
    running,
    reaped,
    error,
};

StageRefreshResult reap_exited_stage(pid_t pid, int &status,
                                     const std::string &label,
                                     std::string &err)
{
    siginfo_t info{};
    for (;;)
    {
        info = {};
        if (::waitid(P_PID, static_cast<id_t>(pid), &info,
                     WEXITED | WNOHANG | WNOWAIT) == 0)
        {
            break;
        }
        if (errno == EINTR)
        {
            continue;
        }
        err = label + ": waitid failed: " + std::strerror(errno);
        return StageRefreshResult::error;
    }

    if (info.si_pid == 0)
    {
        return StageRefreshResult::running;
    }

    // L’étape directe est déjà un zombie : son identifiant de groupe ne peut
    // donc pas encore être recyclé. Supprimer les descendants restés dans ce
    // groupe avant que waitpid() libère l’identifiant préserve la propriété du
    // pipeline, même si la commande termine sans attendre un enfant lancé.
    babet_process::kill_group(pid, SIGKILL);

    for (;;)
    {
        const pid_t result = ::waitpid(pid, &status, 0);
        if (result == pid)
        {
            return StageRefreshResult::reaped;
        }
        if (result < 0 && errno == EINTR)
        {
            continue;
        }
        err = label + ": waitpid failed: " + std::strerror(errno);
        return StageRefreshResult::error;
    }
}

bool refresh_pipeline_status(PipelineProcess *pipeline, std::string &err)
{
    for (size_t i = 0; i < pipeline->count; ++i)
    {
        if (pipeline->status_valid[i] || pipeline->pids[i] <= 0)
        {
            continue;
        }

        const std::string label =
            "pipeline process: stage " + std::to_string(i + 1);
        const StageRefreshResult result = reap_exited_stage(
            pipeline->pids[i], pipeline->statuses[i], label, err);
        if (result == StageRefreshResult::error)
        {
            return false;
        }
        if (result == StageRefreshResult::reaped)
        {
            pipeline->status_valid[i] = true;
            if (i == 0)
            {
                babet_process::close_fd(pipeline->stdin_fd);
            }
        }
    }
    return true;
}

bool all_pipeline_stages_reaped(const PipelineProcess *pipeline)
{
    for (size_t i = 0; i < pipeline->count; ++i)
    {
        if (!pipeline->status_valid[i])
        {
            return false;
        }
    }
    return true;
}

enum class ReapResult
{
    complete,
    timed_out,
    error,
    interrupted,
};

ReapResult reap_pipeline_until(lua_State *L, PipelineProcess *pipeline,
                               long long deadline, bool dispatch_signals,
                               std::string &err)
{
    for (;;)
    {
        if (dispatch_signals && signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return ReapResult::interrupted;
        }
        if (!refresh_pipeline_status(pipeline, err))
        {
            return ReapResult::error;
        }
        if (all_pipeline_stages_reaped(pipeline))
        {
            return ReapResult::complete;
        }
        if (babet_process::now_ms() >= deadline)
        {
            return ReapResult::timed_out;
        }

        struct timespec pause{0, 10 * 1000 * 1000};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
            if (dispatch_signals && signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                return ReapResult::interrupted;
            }
        }
    }
}

void signal_pipeline_groups(const PipelineProcess *pipeline, int signal)
{
    for (size_t i = 0; i < pipeline->count; ++i)
    {
        // Après waitpid(), le PID peut finir par être réutilisé. Ne jamais
        // cibler de nouveau un groupe dont le processus direct a déjà été
        // récupéré par wait(), is_running() ou un arrêt précédent.
        if (!pipeline->status_valid[i])
        {
            babet_process::kill_group(pipeline->pids[i], signal);
        }
    }
}

int wait_fd(lua_State *L, int fd, short events, double timeout)
{
    const bool finite_timeout = timeout >= 0.0;
    const long long deadline = finite_timeout
                                   ? babet_process::now_ms() +
                                         static_cast<long long>(
                                             std::ceil(timeout * 1000.0))
                                   : 0;
    struct pollfd pfd{};
    pfd.fd = fd;
    pfd.events = events;

    for (;;)
    {
        if (signal_any_handled_pending())
        {
            signal_dispatch_pending(L);
            return -2;
        }

        int poll_timeout = -1;
        if (finite_timeout)
        {
            const long long remaining = deadline - babet_process::now_ms();
            poll_timeout = remaining <= 0
                               ? 0
                               : (remaining > INT_MAX
                                      ? INT_MAX
                                      : static_cast<int>(remaining));
        }
        pfd.revents = 0;
        const int result = ::poll(&pfd, 1, poll_timeout);
        if (result >= 0)
        {
            if (result > 0 && (pfd.revents & POLLNVAL))
            {
                errno = EBADF;
                return -1;
            }
            return result;
        }
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                return -2;
            }
            continue;
        }
        return -1;
    }
}

int read_pipeline_fd(lua_State *L, int &fd, size_t max_bytes,
                     double timeout, const char *method_name)
{
    if (fd < 0)
    {
        return push_fail_protected(L, "closed");
    }

    const int ready = wait_fd(L, fd, POLLIN, timeout);
    if (ready == -2)
    {
        return push_fail_protected(L, "interrupted");
    }
    if (ready < 0)
    {
        return push_fail_protected(L, std::string("pipeline process: poll failed: ") +
                                std::strerror(errno));
    }
    if (ready == 0)
    {
        return push_fail_protected(L, "timeout");
    }

    void *raw_buffer = lua_newuserdatauv(L, max_bytes, 0);
    auto *buffer = static_cast<char *>(raw_buffer);
    for (;;)
    {
        const ssize_t count = ::read(fd, buffer, max_bytes);
        if (count > 0)
        {
            lua_pushlstring(L, buffer, static_cast<size_t>(count));
            lua_remove(L, -2);
            lua_pushnil(L);
            return 2;
        }
        if (count == 0)
        {
            babet_process::close_fd(fd);
            lua_pop(L, 1);
            return push_fail_protected(L, "closed");
        }
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                lua_pop(L, 1);
                return push_fail_protected(L, "interrupted");
            }
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
        {
            lua_pop(L, 1);
            return push_fail_protected(L, "timeout");
        }
        const std::string error = std::string(method_name) +
                                  ": read failed: " +
                                  std::strerror(errno);
        lua_pop(L, 1);
        return push_fail_protected(L, error);
    }
}

int pipeline_process_read_stdout(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 3))
    {
        return luaL_error(
            L, "pipeline.read_stdout expects optional max_bytes and timeout");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    size_t max_bytes = DEFAULT_READ_SIZE;
    if (argc >= 2 && !lua_isnil(L, 2))
    {
        if (!lua_is_strict_integer(L, 2))
        {
            return luaL_error(
                L, "pipeline.read_stdout: max_bytes must be an integer");
        }
        const lua_Integer value = lua_tointeger(L, 2);
        if (value <= 0 ||
            static_cast<unsigned long long>(value) > MAX_READ_SIZE)
        {
            return luaL_error(
                L,
                "pipeline.read_stdout: max_bytes must be between 1 and %zu",
                MAX_READ_SIZE);
        }
        max_bytes = static_cast<size_t>(value);
    }

    double timeout = 0.0;
    bool present = false;
    {
        std::string error;
        if (argc >= 3 &&
            !parse_timeout_value(L, 3, "timeout", false,
                                 timeout, present, error))
        {
            return push_fail_protected(L, "pipeline.read_stdout: " + error);
        }
    }
    return read_pipeline_fd(L, pipeline->stdout_fd, max_bytes, timeout,
                            "pipeline.read_stdout");
}

int pipeline_process_read_stderr(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 2, 4))
    {
        return luaL_error(
            L, "pipeline.read_stderr expects stage, optional max_bytes and timeout");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    if (!lua_is_strict_integer(L, 2))
    {
        return luaL_error(L, "pipeline.read_stderr: stage must be an integer");
    }
    const lua_Integer stage = lua_tointeger(L, 2);
    if (stage < 1 || static_cast<size_t>(stage) > pipeline->count)
    {
        return luaL_error(L, "pipeline.read_stderr: stage out of range");
    }

    size_t max_bytes = DEFAULT_READ_SIZE;
    if (argc >= 3 && !lua_isnil(L, 3))
    {
        if (!lua_is_strict_integer(L, 3))
        {
            return luaL_error(
                L, "pipeline.read_stderr: max_bytes must be an integer");
        }
        const lua_Integer value = lua_tointeger(L, 3);
        if (value <= 0 ||
            static_cast<unsigned long long>(value) > MAX_READ_SIZE)
        {
            return luaL_error(
                L,
                "pipeline.read_stderr: max_bytes must be between 1 and %zu",
                MAX_READ_SIZE);
        }
        max_bytes = static_cast<size_t>(value);
    }

    double timeout = 0.0;
    bool present = false;
    {
        std::string error;
        if (argc >= 4 &&
            !parse_timeout_value(L, 4, "timeout", false,
                                 timeout, present, error))
        {
            return push_fail_protected(L, "pipeline.read_stderr: " + error);
        }
    }
    return read_pipeline_fd(
        L, pipeline->stderr_fds[static_cast<size_t>(stage - 1)],
        max_bytes, timeout, "pipeline.read_stderr");
}

int pipeline_process_write(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 2, 3))
    {
        return luaL_error(L,
                          "pipeline.write expects data and optional timeout");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    luaL_checktype(L, 2, LUA_TSTRING);

    double timeout = 0.0;
    bool present = false;
    {
        std::string error;
        if (argc == 3 &&
            !parse_timeout_value(L, 3, "timeout", false,
                                 timeout, present, error))
        {
            return push_fail_protected(L, "pipeline.write: " + error);
        }
    }
    if (pipeline->stdin_fd < 0)
    {
        return push_fail_protected(L, "closed");
    }

    size_t length = 0;
    const char *data = lua_tolstring(L, 2, &length);
    if (length == 0)
    {
        lua_pushinteger(L, 0);
        lua_pushnil(L);
        return 2;
    }

    const int ready = wait_fd(L, pipeline->stdin_fd, POLLOUT, timeout);
    if (ready == -2)
    {
        return push_fail_protected(L, "interrupted");
    }
    if (ready < 0)
    {
        return push_fail_protected(L, std::string("pipeline process: poll failed: ") +
                                std::strerror(errno));
    }
    if (ready == 0)
    {
        return push_fail_protected(L, "timeout");
    }

    for (;;)
    {
        const size_t write_size = std::min(
            length,
            static_cast<size_t>(std::numeric_limits<ssize_t>::max()));
        const ssize_t written = babet_process::write_without_sigpipe(
            pipeline->stdin_fd, data, write_size);
        if (written >= 0)
        {
            lua_pushinteger(L, static_cast<lua_Integer>(written));
            lua_pushnil(L);
            return 2;
        }
        if (errno == EINTR)
        {
            if (signal_any_handled_pending())
            {
                signal_dispatch_pending(L);
                return push_fail_protected(L, "interrupted");
            }
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK)
        {
            return push_fail_protected(L, "timeout");
        }
        if (errno == EPIPE || errno == EBADF)
        {
            babet_process::close_fd(pipeline->stdin_fd);
            return push_fail_protected(L, "closed");
        }
        return push_fail_protected(L, std::string("pipeline process: write failed: ") +
                                std::strerror(errno));
    }
}

int pipeline_process_close_stdin(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "pipeline.close_stdin expects no argument");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    babet_process::close_fd(pipeline->stdin_fd);
    return push_ok_protected(L);
}

int pipeline_process_pids(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "pipeline.pids expects no argument");
    }
    const PipelineProcess *pipeline = check_pipeline_process(L, 1);
    lua_createtable(L, static_cast<int>(pipeline->count), 0);
    for (size_t i = 0; i < pipeline->count; ++i)
    {
        lua_pushinteger(L, static_cast<lua_Integer>(pipeline->pids[i]));
        lua_seti(L, -2, static_cast<lua_Integer>(i + 1));
    }
    return 1;
}

int pipeline_process_is_running(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L,
                          "pipeline.is_running expects an optional stage");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    if (pipeline->closed)
    {
        lua_pushboolean(L, 0);
        return 1;
    }

    size_t selected = pipeline->count;
    if (argc == 2)
    {
        if (!lua_is_strict_integer(L, 2))
        {
            return luaL_error(L,
                              "pipeline.is_running: stage must be an integer");
        }
        const lua_Integer stage = lua_tointeger(L, 2);
        if (stage < 1 || static_cast<size_t>(stage) > pipeline->count)
        {
            return luaL_error(L, "pipeline.is_running: stage out of range");
        }
        selected = static_cast<size_t>(stage - 1);
    }

    std::string error;
    if (!refresh_pipeline_status(pipeline, error))
    {
        return push_fail_protected(L, error);
    }
    if (selected < pipeline->count)
    {
        lua_pushboolean(L, !pipeline->status_valid[selected]);
        return 1;
    }
    lua_pushboolean(L, !all_pipeline_stages_reaped(pipeline));
    return 1;
}

int pipeline_process_wait(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(L, "pipeline.wait expects an optional timeout");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);

    double timeout = 0.0;
    bool has_timeout = false;
    std::string error;
    if (argc == 2 &&
        !parse_timeout_value(L, 2, "timeout", false,
                             timeout, has_timeout, error))
    {
        return push_fail_protected(L, "pipeline.wait: " + error);
    }

    if (!refresh_pipeline_status(pipeline, error))
    {
        return push_fail_protected(L, error);
    }
    if (all_pipeline_stages_reaped(pipeline))
    {
        return push_status_result_protected(
            L, pipeline->statuses, pipeline->status_valid, pipeline->count);
    }
    if (pipeline->closed)
    {
        return push_fail_protected(L, "closed");
    }

    const long long deadline = has_timeout
                                   ? babet_process::now_ms() +
                                         static_cast<long long>(
                                             std::ceil(timeout * 1000.0))
                                   : std::numeric_limits<long long>::max();
    const ReapResult result = reap_pipeline_until(
        L, pipeline, deadline, true, error);
    if (result == ReapResult::complete)
    {
        return push_status_result_protected(
            L, pipeline->statuses, pipeline->status_valid, pipeline->count);
    }
    if (result == ReapResult::timed_out)
    {
        return push_fail_protected(L, "timeout");
    }
    if (result == ReapResult::interrupted)
    {
        return push_fail_protected(L, "interrupted");
    }
    return push_fail_protected(L, error);
}

int terminate_pipeline_process(lua_State *L, PipelineProcess *pipeline,
                               int signal, double grace_seconds)
{
    std::string error;
    if (all_pipeline_stages_reaped(pipeline))
    {
        return push_status_result_protected(
            L, pipeline->statuses, pipeline->status_valid, pipeline->count);
    }
    if (pipeline->closed)
    {
        return push_fail_protected(L, "closed");
    }

    // Signaler avant toute récupération : un leader déjà terminé reste zombie
    // et continue ainsi d’ancrer son groupe pendant la période de grâce.
    signal_pipeline_groups(pipeline, signal);

    // Pour SIGTERM, conserver les leaders directs non réapés pendant toute
    // la période de grâce. Leur PID continue ainsi d'ancrer le groupe et ne
    // peut pas être recyclé pendant que des descendants terminent proprement.
    if (signal != SIGKILL)
    {
        const long long grace_deadline =
            babet_process::now_ms() +
            static_cast<long long>(std::ceil(grace_seconds * 1000.0));
        while (babet_process::now_ms() < grace_deadline)
        {
            const long long remaining =
                grace_deadline - babet_process::now_ms();
            struct timespec pause{
                static_cast<time_t>(remaining / 1000),
                static_cast<long>((remaining % 1000) * 1000000LL)};
            while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
            {
            }
        }
        signal_pipeline_groups(pipeline, SIGKILL);
    }

    ReapResult result = reap_pipeline_until(
        L, pipeline, babet_process::now_ms() + TERM_GRACE_MS,
        false, error);
    if (result == ReapResult::error)
    {
        return push_fail_protected(L, error);
    }
    if (result != ReapResult::complete)
    {
        return push_fail_protected(L,
                         "pipeline process: children could not be reaped");
    }

    babet_process::close_fd(pipeline->stdin_fd);
    return push_status_result_protected(
        L, pipeline->statuses, pipeline->status_valid, pipeline->count);
}

int pipeline_process_terminate(lua_State *L)
{
    const int argc = lua_gettop(L);
    if (!lua_arity_between(L, 1, 2))
    {
        return luaL_error(
            L, "pipeline.terminate expects an optional grace period");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);

    double grace = DEFAULT_TERMINATE_GRACE;
    bool present = false;
    std::string error;
    if (argc == 2 &&
        !parse_timeout_value(L, 2, "grace_period", false,
                             grace, present, error))
    {
        return push_fail_protected(L, "pipeline.terminate: " + error);
    }
    return terminate_pipeline_process(L, pipeline, SIGTERM, grace);
}

int pipeline_process_kill(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "pipeline.kill expects no argument");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    return terminate_pipeline_process(L, pipeline, SIGKILL, 2.0);
}

void cleanup_pipeline_process(PipelineProcess *pipeline) noexcept
{
    if (pipeline == nullptr || pipeline->closed)
    {
        return;
    }

    babet_process::close_fd(pipeline->stdin_fd);

    // Signaler avant le premier waitpid() de ce nettoyage : tant que l'enfant
    // direct n'est pas récupéré, son identifiant de groupe ne peut pas être
    // confondu avec un PID réutilisé. Les étapes déjà récupérées sont ignorées.
    signal_pipeline_groups(pipeline, SIGTERM);

    const long long term_deadline = babet_process::now_ms() + 500;
    while (babet_process::now_ms() < term_deadline)
    {
        const long long remaining = term_deadline - babet_process::now_ms();
        struct timespec pause{
            static_cast<time_t>(remaining / 1000),
            static_cast<long>((remaining % 1000) * 1000000LL)};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
        }
    }

    signal_pipeline_groups(pipeline, SIGKILL);
    const long long reap_deadline =
        babet_process::now_ms() + TERM_GRACE_MS;
    for (size_t i = 0; i < pipeline->count; ++i)
    {
        if (pipeline->status_valid[i] || pipeline->pids[i] <= 0)
        {
            continue;
        }
        const auto result = babet_process::wait_child_until(
            pipeline->pids[i], pipeline->statuses[i], reap_deadline);
        pipeline->status_valid[i] =
            result == babet_process::ChildWaitResult::reaped;
    }
    babet_process::close_fd(pipeline->stdout_fd);
    for (size_t i = 0; i < pipeline->count; ++i)
    {
        babet_process::close_fd(pipeline->stderr_fds[i]);
    }
    pipeline->closed = true;
}

int pipeline_process_close(lua_State *L)
{
    if (!lua_arity_is(L, 1))
    {
        return luaL_error(L, "pipeline.close expects no argument");
    }
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    cleanup_pipeline_process(pipeline);
    return push_ok_protected(L);
}

int pipeline_process_gc(lua_State *L)
{
    auto *pipeline = static_cast<PipelineProcess *>(
        luaL_testudata(L, 1, PIPELINE_META));
    cleanup_pipeline_process(pipeline);
    return 0;
}

int pipeline_process_gc_boundary(lua_State *L) noexcept
{
    try
    {
        return pipeline_process_gc(L);
    }
    catch (...)
    {
        return 0;
    }
}

int pipeline_process_tostring(lua_State *L)
{
    PipelineProcess *pipeline = check_pipeline_process(L, 1);
    const char *state = pipeline->closed
                            ? "closed"
                            : (all_pipeline_stages_reaped(pipeline)
                                   ? "exited"
                                   : "running");
    lua_pushfstring(L, "babet.pipeline_process(stages=%d, %s)",
                    static_cast<int>(pipeline->count), state);
    return 1;
}

template <int (*Fn)(lua_State *)>
int pipeline_lua_boundary(lua_State *L)
{
    return lua_cfunction_exception_boundary<Fn>(
        L, "pipeline: out of memory", "pipeline: internal C++ failure",
        "pipeline: unknown internal C++ failure");
}

void register_pipeline_process_metatable(lua_State *L)
{
    if (luaL_newmetatable(L, PIPELINE_META))
    {
        lua_pushcfunction(L, pipeline_process_gc_boundary);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, pipeline_process_gc_boundary);
        lua_setfield(L, -2, "__close");
        lua_pushcfunction(L, pipeline_lua_boundary<pipeline_process_tostring>);
        lua_setfield(L, -2, "__tostring");

        lua_newtable(L);
        lua_pushcfunction(
            L, pipeline_lua_boundary<pipeline_process_read_stdout>);
        lua_setfield(L, -2, "read_stdout");
        lua_pushcfunction(
            L, pipeline_lua_boundary<pipeline_process_read_stderr>);
        lua_setfield(L, -2, "read_stderr");
        lua_pushcfunction(L, pipeline_lua_boundary<pipeline_process_write>);
        lua_setfield(L, -2, "write");
        lua_pushcfunction(
            L, pipeline_lua_boundary<pipeline_process_close_stdin>);
        lua_setfield(L, -2, "close_stdin");
        lua_pushcfunction(
            L, pipeline_lua_boundary<pipeline_process_is_running>);
        lua_setfield(L, -2, "is_running");
        lua_pushcfunction(L, pipeline_lua_boundary<pipeline_process_pids>);
        lua_setfield(L, -2, "pids");
        lua_pushcfunction(L, pipeline_lua_boundary<pipeline_process_wait>);
        lua_setfield(L, -2, "wait");
        lua_pushcfunction(
            L, pipeline_lua_boundary<pipeline_process_terminate>);
        lua_setfield(L, -2, "terminate");
        lua_pushcfunction(L, pipeline_lua_boundary<pipeline_process_kill>);
        lua_setfield(L, -2, "kill");
        lua_pushcfunction(L, pipeline_lua_boundary<pipeline_process_close>);
        lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

babet_process::ChildWaitResult wait_pipeline_stage_until(
    pid_t pid, int &status, long long deadline, const std::string &label,
    std::string &err)
{
    for (;;)
    {
        const StageRefreshResult result =
            reap_exited_stage(pid, status, label, err);
        if (result == StageRefreshResult::reaped)
        {
            return babet_process::ChildWaitResult::reaped;
        }
        if (result == StageRefreshResult::error)
        {
            return babet_process::ChildWaitResult::error;
        }
        if (babet_process::now_ms() >= deadline)
        {
            return babet_process::ChildWaitResult::timed_out;
        }

        struct timespec pause{0, 10 * 1000 * 1000};
        while (::nanosleep(&pause, &pause) < 0 && errno == EINTR)
        {
        }
    }
}

} // namespace

int lua_pipeline_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2) || lua_type(L, 1) != LUA_TTABLE)
    {
        return luaL_error(L,
                          "pipeline expects a commands table and optional opts");
    }

    std::string error;
    PipelineOptions options;
    if (!collect_pipeline_options(L, 2, options, error))
    {
        return push_fail_protected(L, error);
    }

    std::vector<babet_process::PipelineStageSpec> stages;
    if (!collect_stages(L, 1, options, stages, error))
    {
        return push_fail_protected(L, error);
    }

    const long long deadline = options.has_timeout
                                   ? babet_process::now_ms() +
                                         static_cast<long long>(
                                             options.timeout_sec * 1000.0)
                                   : 0;
    babet_process::PipelineLaunchSpec spec;
    spec.stages = std::move(stages);
    spec.has_deadline = options.has_timeout;
    spec.deadline_ms = deadline;
    spec.error_prefix = "pipeline";

    babet_process::PipelineLaunchResult launched =
        babet_process::launch_pipeline(spec);
    if (!launched.success)
    {
        if (launched.timed_out)
        {
            return push_fail_protected(L, "pipeline: launch timed out");
        }
        return push_fail_protected(L, launched.error);
    }

    // La garde est armée immédiatement après le lancement, avant toute
    // allocation supplémentaire du chemin synchrone.
    LaunchedPipelineGuard launch_guard(launched.pipeline);

    // IMPORTANT : aucun appel lua_* n'est autorisé tant que cette première
    // garde est armée. Une erreur Lua utilise longjmp et contournerait son
    // destructeur avant le transfert vers SyncPipelineGuard.

    std::vector<ChildState> children;
    children.reserve(launched.pipeline.children.size());
    for (const auto &child : launched.pipeline.children)
    {
        children.push_back({child.pid, -1, 0, false});
    }

    int stdin_fd = std::exchange(launched.pipeline.stdin_fd, -1);
    int stdout_fd = std::exchange(launched.pipeline.stdout_fd, -1);
    for (size_t i = 0; i < children.size(); ++i)
    {
        children[i].stderr_fd =
            std::exchange(launched.pipeline.children[i].stderr_fd, -1);
    }

    SyncPipelineGuard emergency_guard(stdin_fd, stdout_fd, children);
    launch_guard.release();

    // IMPORTANT : aucun appel lua_* n'est autorisé tant que la garde
    // synchrone est armée. Une erreur Lua ferait un longjmp et contournerait
    // son destructeur.

    if (!options.has_stdin)
    {
        babet_process::close_fd(stdin_fd);
    }
    size_t stdin_offset = 0;
    std::string stdout_buffer;
    std::vector<std::string> stderr_buffers(children.size());
    std::vector<unsigned char> stderr_truncated(children.size(), 0);
    bool stdout_truncated = false;
    bool timed_out = false;
    bool term_sent = false;
    bool kill_sent = false;
    long long term_deadline = 0;
    long long kill_deadline = 0;

    auto streams_open = [&]() {
        if (stdin_fd >= 0 || stdout_fd >= 0)
        {
            return true;
        }
        for (const ChildState &child : children)
        {
            if (child.stderr_fd >= 0)
            {
                return true;
            }
        }
        return false;
    };

    while (streams_open())
    {
        if (options.has_timeout)
        {
            const long long now = babet_process::now_ms();
            if (!term_sent && now >= deadline)
            {
                timed_out = true;
                term_sent = true;
                term_deadline = now + TERM_GRACE_MS;
                kill_all(children, SIGTERM);
                babet_process::close_fd(stdin_fd);
            }
            else if (term_sent && !kill_sent && now >= term_deadline)
            {
                kill_sent = true;
                kill_deadline = now + TERM_GRACE_MS;
                kill_all(children, SIGKILL);
            }
            else if (kill_sent && now >= kill_deadline)
            {
                break;
            }
        }

        std::vector<struct pollfd> pollfds;
        std::vector<int> kinds;
        std::vector<size_t> indices;
        pollfds.reserve(children.size() + 2);
        kinds.reserve(children.size() + 2);
        indices.reserve(children.size() + 2);

        if (stdout_fd >= 0)
        {
            pollfds.push_back({stdout_fd, POLLIN, 0});
            kinds.push_back(0);
            indices.push_back(0);
        }
        for (size_t i = 0; i < children.size(); ++i)
        {
            if (children[i].stderr_fd >= 0)
            {
                pollfds.push_back({children[i].stderr_fd, POLLIN, 0});
                kinds.push_back(1);
                indices.push_back(i);
            }
        }
        if (stdin_fd >= 0)
        {
            pollfds.push_back({stdin_fd, POLLOUT, 0});
            kinds.push_back(2);
            indices.push_back(0);
        }

        int poll_timeout = -1;
        if (options.has_timeout)
        {
            const long long limit = kill_sent
                                        ? kill_deadline
                                        : (term_sent ? term_deadline
                                                     : deadline);
            const long long remaining = limit - babet_process::now_ms();
            poll_timeout = remaining <= 0
                               ? 0
                               : static_cast<int>(
                                     std::min<long long>(remaining, 1000));
        }

        const int poll_result = ::poll(pollfds.data(), pollfds.size(),
                                       poll_timeout);
        if (poll_result < 0 && errno == EINTR)
        {
            continue;
        }
        if (poll_result < 0)
        {
            error = std::string("pipeline: poll failed: ") +
                    std::strerror(errno);
            break;
        }
        if (poll_result == 0)
        {
            continue;
        }

        for (size_t i = 0; i < pollfds.size(); ++i)
        {
            if ((pollfds[i].revents &
                 (POLLIN | POLLOUT | POLLHUP | POLLERR | POLLNVAL)) == 0)
            {
                continue;
            }
            if (kinds[i] == 0)
            {
                if (!drain_fd(stdout_fd, stdout_buffer,
                              options.max_output, stdout_truncated))
                {
                    babet_process::close_fd(stdout_fd);
                }
            }
            else if (kinds[i] == 1)
            {
                const size_t child_index = indices[i];
                bool truncated = stderr_truncated[child_index] != 0;
                if (!drain_fd(children[child_index].stderr_fd,
                              stderr_buffers[child_index],
                              options.max_output, truncated))
                {
                    babet_process::close_fd(
                        children[child_index].stderr_fd);
                }
                stderr_truncated[child_index] = truncated ? 1 : 0;
            }
            else
            {
                const size_t remaining =
                    options.stdin_data.size() - stdin_offset;
                if (remaining == 0)
                {
                    babet_process::close_fd(stdin_fd);
                    continue;
                }
                const ssize_t written =
                    babet_process::write_without_sigpipe(
                        stdin_fd,
                        options.stdin_data.data() + stdin_offset,
                        remaining);
                if (written > 0)
                {
                    stdin_offset += static_cast<size_t>(written);
                }
                else if (written < 0 &&
                         (errno == EPIPE || errno == EBADF))
                {
                    babet_process::close_fd(stdin_fd);
                }
                else if (written < 0 && errno != EAGAIN &&
                         errno != EWOULDBLOCK && errno != EINTR)
                {
                    error = std::string("pipeline: stdin write failed: ") +
                            std::strerror(errno);
                    babet_process::close_fd(stdin_fd);
                }
                if (stdin_offset == options.stdin_data.size())
                {
                    babet_process::close_fd(stdin_fd);
                }
            }
        }
        if (!error.empty())
        {
            break;
        }
    }

    babet_process::close_fd(stdin_fd);
    babet_process::close_fd(stdout_fd);
    for (ChildState &child : children)
    {
        babet_process::close_fd(child.stderr_fd);
    }

    if (!error.empty())
    {
        kill_all(children, SIGKILL);
        reap_all(children, babet_process::now_ms() + TERM_GRACE_MS);
        emergency_guard.cleanup_now();
        return push_fail_protected(L, error);
    }

    if (timed_out)
    {
        kill_all(children, SIGKILL);
        reap_all(children, babet_process::now_ms() + TERM_GRACE_MS);
    }
    else
    {
        for (ChildState &child : children)
        {
            if (options.has_timeout)
            {
                const auto wait_result = wait_pipeline_stage_until(
                    child.pid, child.status, deadline,
                    "pipeline: stage wait", error);
                if (wait_result == babet_process::ChildWaitResult::reaped)
                {
                    child.status_valid = true;
                }
                else if (wait_result ==
                         babet_process::ChildWaitResult::timed_out)
                {
                    timed_out = true;
                    kill_all(children, SIGTERM);
                    reap_all(children, babet_process::now_ms() + 500);
                    kill_all(children, SIGKILL);
                    reap_all(children,
                             babet_process::now_ms() + TERM_GRACE_MS);
                    break;
                }
                else
                {
                    error = std::string("pipeline: waitpid failed: ") +
                            std::strerror(errno);
                    break;
                }
            }
            else
            {
                const auto wait_result = wait_pipeline_stage_until(
                    child.pid, child.status,
                    std::numeric_limits<long long>::max(),
                    "pipeline: stage wait", error);
                if (wait_result == babet_process::ChildWaitResult::reaped)
                {
                    child.status_valid = true;
                }
                else
                {
                    if (error.empty())
                    {
                        error = "pipeline: stage could not be reaped";
                    }
                    break;
                }
            }
        }
    }

    if (!error.empty())
    {
        emergency_guard.cleanup_now();
        return push_fail_protected(L, error);
    }
    emergency_guard.cleanup_now();
    return push_sync_result_protected(
        L, stdout_buffer, stderr_buffers, stderr_truncated, children,
        timed_out, stdout_truncated);

}

int lua_spawn_pipeline_impl(lua_State *L)
{
    if (!lua_arity_between(L, 1, 2) || lua_type(L, 1) != LUA_TTABLE)
    {
        return luaL_error(
            L, "spawnPipeline expects a commands table and optional opts");
    }

    std::string error;
    SpawnPipelineOptions options;
    if (!collect_spawn_pipeline_options(L, 2, options, error))
    {
        return push_fail_protected(L, error);
    }

    std::vector<babet_process::PipelineStageSpec> stages;
    if (!collect_stages(L, 1, options, stages, error))
    {
        return push_fail_protected(L, error);
    }

    auto builder = [](lua_State *Ls) noexcept -> int
    {
        push_empty_pipeline_process(Ls);
        return 1;
    };
    lua_build_results_protected(L, builder, 1);
    PipelineProcess *pipeline = static_cast<PipelineProcess *>(
        lua_touserdata(L, -1));

    babet_process::PipelineLaunchSpec spec;
    spec.stages = std::move(stages);
    spec.has_deadline = options.has_launch_timeout;
    spec.deadline_ms = options.launch_deadline_ms;
    spec.error_prefix = "spawnPipeline";

    babet_process::PipelineLaunchResult launched =
        babet_process::launch_pipeline(spec);
    if (!launched.success)
    {
        lua_pop(L, 1);
        if (launched.timed_out)
        {
            return push_fail_protected(L, "spawnPipeline: launch timed out");
        }
        return push_fail_protected(L, launched.error);
    }

    if (!initialize_pipeline_process(pipeline, launched.pipeline))
    {
        babet_process::emergency_kill_and_reap(launched.pipeline);
        lua_pop(L, 1);
        return push_fail_protected(L, "spawnPipeline: too many launched stages");
    }
    lua_pushnil(L);
    return 2;
}

int lua_pipeline(lua_State *L)
{
    return pipeline_lua_boundary<lua_pipeline_impl>(L);
}

int lua_spawn_pipeline(lua_State *L)
{
    return pipeline_lua_boundary<lua_spawn_pipeline_impl>(L);
}

void register_pipeline(lua_State *L)
{
    register_pipeline_process_metatable(L);
    lua_pushcfunction(L, lua_pipeline);
    lua_setfield(L, -2, "pipeline");
    lua_pushcfunction(L, lua_spawn_pipeline);
    lua_setfield(L, -2, "spawnPipeline");
}
