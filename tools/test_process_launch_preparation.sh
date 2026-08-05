#!/bin/bash
# Préflight autonome du préparateur de lancement parent : environnement final,
# résolution PATH, cwd effectif et priorité ENOENT/EACCES.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/babet-process-launch.XXXXXX") || exit 1
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

cat > "${TMP_ROOT}/test.cpp" <<'CPP'
#include "lua_bindings/process_launch_internal.hpp"

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <optional>
#include <string>
#include <type_traits>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
using babet_process::detail::PreparedCommand;
using babet_process::detail::exec_prepared_command;
using babet_process::detail::prepare_command;

static_assert(!std::is_copy_constructible_v<PreparedCommand>);
static_assert(!std::is_copy_assignable_v<PreparedCommand>);
static_assert(!std::is_move_constructible_v<PreparedCommand>);
static_assert(!std::is_move_assignable_v<PreparedCommand>);

namespace
{
int passes = 0;
int failures = 0;

void check(bool condition, const std::string &label,
           const std::string &detail = {})
{
    if (condition)
    {
        ++passes;
        std::cout << "[PASS] " << label << '\n';
    }
    else
    {
        ++failures;
        std::cerr << "[FAIL] " << label;
        if (!detail.empty())
        {
            std::cerr << " — " << detail;
        }
        std::cerr << '\n';
    }
}

std::string absolute_string(const fs::path &path)
{
    return fs::absolute(path).lexically_normal().string();
}

void write_executable(const fs::path &path, const char *body = "#!/bin/sh\nexit 0\n")
{
    fs::create_directories(path.parent_path());
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output << body;
    output.close();
    if (::chmod(path.c_str(), 0755) != 0)
    {
        throw std::runtime_error(std::string("chmod: ") + std::strerror(errno));
    }
}

void write_non_executable(const fs::path &path)
{
    fs::create_directories(path.parent_path());
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output << "not executable\n";
    output.close();
    if (::chmod(path.c_str(), 0644) != 0)
    {
        throw std::runtime_error(std::string("chmod: ") + std::strerror(errno));
    }
}

int exec_errno(const PreparedCommand &prepared)
{
    int status_pipe[2] = {-1, -1};
    if (::pipe(status_pipe) != 0)
    {
        throw std::runtime_error(std::string("pipe: ") + std::strerror(errno));
    }

    const pid_t pid = ::fork();
    if (pid < 0)
    {
        const int saved = errno;
        ::close(status_pipe[0]);
        ::close(status_pipe[1]);
        throw std::runtime_error(std::string("fork: ") + std::strerror(saved));
    }
    if (pid == 0)
    {
        ::close(status_pipe[0]);
        const int saved = exec_prepared_command(prepared);
        const ssize_t ignored = ::write(status_pipe[1], &saved, sizeof(saved));
        (void)ignored;
        _exit(127);
    }

    ::close(status_pipe[1]);
    int launch_errno = 0;
    size_t offset = 0;
    while (offset < sizeof(launch_errno))
    {
        const ssize_t read_count = ::read(
            status_pipe[0], reinterpret_cast<char *>(&launch_errno) + offset,
            sizeof(launch_errno) - offset);
        if (read_count > 0)
        {
            offset += static_cast<size_t>(read_count);
            continue;
        }
        if (read_count < 0 && errno == EINTR)
        {
            continue;
        }
        break;
    }
    ::close(status_pipe[0]);

    int status = 0;
    while (::waitpid(pid, &status, 0) < 0 && errno == EINTR)
    {
    }
    return offset == sizeof(launch_errno) ? launch_errno : 0;
}

std::optional<std::string> env_value(const PreparedCommand &prepared,
                                     const std::string &name)
{
    const std::string prefix = name + "=";
    for (const std::string &entry : prepared.env_strings)
    {
        if (entry.starts_with(prefix))
        {
            return entry.substr(prefix.size());
        }
    }
    return std::nullopt;
}

bool prepare(const std::string &command, const fs::path &cwd,
             const std::vector<std::pair<std::string, std::string>> &env,
             PreparedCommand &prepared, int &error_number)
{
    const std::vector<std::string> argv{command, "arg-one"};
    return prepare_command(command, argv, cwd.string(), true, env,
                           prepared, error_number);
}

class ScopedEnv
{
public:
    explicit ScopedEnv(const char *name) : name_(name)
    {
        const char *value = std::getenv(name);
        if (value)
        {
            previous_ = value;
        }
    }

    ~ScopedEnv()
    {
        if (previous_)
        {
            ::setenv(name_.c_str(), previous_->c_str(), 1);
        }
        else
        {
            ::unsetenv(name_.c_str());
        }
    }

private:
    std::string name_;
    std::optional<std::string> previous_;
};
} // namespace

int main(int argc, char **argv)
{
    if (argc != 2)
    {
        std::cerr << "temporary root required\n";
        return 2;
    }

    try
    {
        const fs::path root = fs::path(argv[1]);
        const fs::path cwd = root / "work";
        const fs::path good = root / "good";
        const fs::path denied = root / "denied";
        fs::create_directories(cwd);
        fs::create_directories(good);
        fs::create_directories(denied);

        write_executable(good / "private-tool");
        write_non_executable(denied / "private-tool");
        write_executable(cwd / "cwd-tool");
        write_executable(cwd / "relative-bin" / "relative-tool");
        write_executable(cwd / "direct-tool");

        PreparedCommand prepared;
        int error_number = 0;

        check(prepare("private-tool", cwd,
                      {{"PATH", good.string()}, {"BABET_MERGED", "yes"}},
                      prepared, error_number) &&
                  prepared.executable_paths.size() == 1 &&
                  prepared.executable_paths[0] ==
                      absolute_string(good / "private-tool"),
              "opts.env.PATH controls command lookup",
              std::strerror(error_number));
        check(env_value(prepared, "PATH") == good.string(),
              "effective PATH is transmitted in envp");
        check(env_value(prepared, "BABET_MERGED") == "yes",
              "environment overrides are merged");
        check(prepared.argv.size() == 3 && prepared.argv[0] != nullptr &&
                  std::string(prepared.argv[0]) == "private-tool" &&
                  std::string(prepared.argv[1]) == "arg-one" &&
                  prepared.argv[2] == nullptr,
              "argv is complete before fork");
        check(!prepared.envp.empty() && prepared.envp.back() == nullptr,
              "envp is null-terminated before fork");

        prepared.reset();
        error_number = 0;
        check(prepare("cwd-tool", cwd, {{"PATH", ":/usr/bin"}},
                      prepared, error_number) &&
                  prepared.executable_paths.size() == 2 &&
                  prepared.executable_paths[0] ==
                      absolute_string(cwd / "cwd-tool"),
              "empty PATH component denotes child cwd",
              std::strerror(error_number));

        prepared.reset();
        error_number = 0;
        check(prepare("relative-tool", cwd,
                      {{"PATH", "relative-bin:/usr/bin"}}, prepared,
                      error_number) &&
                  prepared.executable_paths.size() == 2 &&
                  prepared.executable_paths[0] ==
                      absolute_string(cwd / "relative-bin" / "relative-tool"),
              "relative PATH component is resolved from child cwd",
              std::strerror(error_number));

        prepared.reset();
        error_number = 0;
        check(prepare("./direct-tool", cwd, {}, prepared, error_number) &&
                  prepared.executable_paths.size() == 1 &&
                  prepared.executable_paths[0] ==
                      absolute_string(cwd) + "/./direct-tool",
              "command containing slash bypasses PATH and follows child cwd",
              std::strerror(error_number));

        prepared.reset();
        error_number = 0;
        const std::string eacces_then_good =
            denied.string() + ":" + good.string();
        check(prepare("private-tool", cwd, {{"PATH", eacces_then_good}},
                      prepared, error_number) &&
                  prepared.executable_paths.size() == 2 &&
                  prepared.executable_paths[0] ==
                      absolute_string(denied / "private-tool") &&
                  prepared.executable_paths[1] ==
                      absolute_string(good / "private-tool") &&
                  exec_errno(prepared) == 0,
              "EACCES candidate does not hide a later executable",
              std::strerror(error_number));

        prepared.reset();
        error_number = 0;
        check(prepare("private-tool", cwd, {{"PATH", denied.string()}},
                      prepared, error_number) &&
                  exec_errno(prepared) == EACCES,
              "only EACCES candidates report EACCES",
              std::string("errno=") + std::to_string(error_number));

        prepared.reset();
        error_number = 0;
        const fs::path not_directory = root / "not-a-directory";
        write_non_executable(not_directory);
        check(prepare("missing-tool", cwd,
                      {{"PATH", not_directory.string() + ":" +
                                    (root / "missing").string()}},
                      prepared, error_number) &&
                  exec_errno(prepared) == ENOENT,
              "ENOENT and ENOTDIR candidates end as ENOENT",
              std::string("errno=") + std::to_string(error_number));

        prepared.reset();
        error_number = 0;
        check(prepare("does-not-exist/command", cwd, {}, prepared,
                      error_number) &&
                  prepared.executable_paths.size() == 1 &&
                  prepared.executable_paths[0] ==
                      absolute_string(cwd / "does-not-exist" / "command"),
              "slash command is left for execve even when absent");

        {
            ScopedEnv path_guard("PATH");
            ::unsetenv("PATH");
            prepared.reset();
            error_number = 0;
            const std::vector<std::string> shell_argv{"sh", "-c", "true"};
            const bool found = prepare_command("sh", shell_argv, cwd.string(),
                                               true, {}, prepared,
                                               error_number);
            check(found && !prepared.executable_paths.empty(),
                  "missing PATH uses the POSIX default search path",
                  std::strerror(error_number));
            check(!env_value(prepared, "PATH").has_value(),
                  "default lookup does not invent PATH in child env");
        }

        write_executable(good / "vanishing-tool");
        prepared.reset();
        error_number = 0;
        check(prepare("vanishing-tool", cwd, {{"PATH", good.string()}},
                      prepared, error_number),
              "executable is resolved before the fork race",
              std::strerror(error_number));
        fs::remove(good / "vanishing-tool");
        errno = 0;
        check(!prepared.executable_paths.empty() &&
                  ::access(prepared.executable_paths[0].c_str(), F_OK) != 0 &&
                  errno == ENOENT,
              "resolved executable may disappear before execve");
        check(exec_errno(prepared) == ENOENT,
              "execve reports ENOENT after a resolved file disappears");

        const fs::path race_first = root / "race-first";
        const fs::path race_second = root / "race-second";
        write_executable(race_first / "race-fallback-tool");
        write_executable(race_second / "race-fallback-tool");
        prepared.reset();
        error_number = 0;
        check(prepare("race-fallback-tool", cwd,
                      {{"PATH", race_first.string() + ":" +
                                    race_second.string()}},
                      prepared, error_number),
              "all PATH candidates are frozen before the fork race",
              std::strerror(error_number));
        fs::remove(race_first / "race-fallback-tool");
        check(exec_errno(prepared) == 0,
              "ENOENT race on the first candidate falls through to the next");

        const fs::path invalid_format = good / "invalid-format-tool";
        write_executable(invalid_format, "not an executable format\n");
        prepared.reset();
        error_number = 0;
        if (prepare("invalid-format-tool", cwd, {{"PATH", good.string()}},
                    prepared, error_number))
        {
            check(exec_errno(prepared) == ENOEXEC,
                  "execve reports ENOEXEC without an implicit shell");
        }
        else
        {
            check(false, "invalid executable format is resolved before execve",
                  std::strerror(error_number));
        }

        fs::create_directories(good / "directory-tool");
        prepared.reset();
        error_number = 0;
        check(prepare("directory-tool", cwd, {{"PATH", good.string()}},
                      prepared, error_number) &&
                  exec_errno(prepared) == EACCES,
              "directory candidate is reported as EACCES",
              std::string("errno=") + std::to_string(error_number));
    }
    catch (const std::exception &exception)
    {
        std::cerr << "[FAIL] unexpected exception: " << exception.what()
                  << '\n';
        ++failures;
    }

    std::cout << "process launch preparation: " << passes << " PASS / "
              << failures << " FAIL\n";
    return failures == 0 ? 0 : 1;
}
CPP

CXX=${CXX:-g++}
"${CXX}" -std=c++23 -O2 -Wall -Wextra -Wpedantic -Werror \
    -I"${ROOT_DIR}/src" \
    "${TMP_ROOT}/test.cpp" \
    "${ROOT_DIR}/src/lua_bindings/process_launch_internal.cpp" \
    -o "${TMP_ROOT}/test-process-launch"

"${TMP_ROOT}/test-process-launch" "${TMP_ROOT}/runtime"
