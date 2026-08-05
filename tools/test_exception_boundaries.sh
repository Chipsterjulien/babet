#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0
CHECKS=0

fail() {
    echo "[FAIL] $1"
    FAILURES=$((FAILURES + 1))
}

require_pattern() {
    local file="$1"
    local pattern="$2"
    local label="$3"
    CHECKS=$((CHECKS + 1))
    if ! grep -Eq "${pattern}" "${ROOT_DIR}/${file}"; then
        fail "${label}"
    fi
}

forbid_pattern() {
    local pattern="$1"
    local label="$2"
    shift 2
    CHECKS=$((CHECKS + 1))
    if grep -Eq "${pattern}" "$@"; then
        fail "${label}"
    fi
}

for specification in \
    "src/lua_bindings/compression.cpp|compression_lua_boundary<lua_compress>|compression.compress" \
    "src/lua_bindings/compression.cpp|compression_lua_boundary<lua_decompress>|compression.decompress" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_which>|sys.which" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_env>|sys.env" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_setenv>|sys.setenv" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_hostname>|sys.hostname" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_uname>|sys.uname" \
    "src/lua_bindings/sys.cpp|sys_lua_boundary<lua_sys_pid>|sys.pid" \
    "src/lua_bindings/user.cpp|user_lua_boundary<lua_user_get>|user.get" \
    "src/lua_bindings/user.cpp|user_lua_boundary<lua_user_exists>|user.exists" \
    "src/lua_bindings/inotify.cpp|inotify_gc_boundary|inotify.__gc" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_tostring>|inotify.__tostring" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_add>|inotify.add" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_read>|inotify.read" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_remove>|inotify.remove" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<inot_close>|inotify.close" \
    "src/lua_bindings/inotify.cpp|inotify_lua_boundary<lua_inotify_new>|inotify.new"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" \
        "lua_pushcfunction\\(L, ${pattern}\\);" \
        "${label} is not registered through its C++ exception boundary"
done

for specification in \
    "src/lua_bindings/process.cpp|process_gc_boundary|process.__gc/__close" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_tostring>|process.__tostring" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_read_stdout>|process.read_stdout" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_read_stderr>|process.read_stderr" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_write>|process.write" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_close_stdin>|process.close_stdin" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_is_running>|process.is_running" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_state>|process.state" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_pid>|process.pid" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_wait>|process.wait" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_resume>|process.resume" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_terminate>|process.terminate" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_kill>|process.kill" \
    "src/lua_bindings/process.cpp|process_lua_boundary<process_close>|process.close" \
    "src/lua_bindings/process.cpp|process_lua_boundary<lua_spawn_impl>|babet.spawn" \
    "src/lua_bindings/process.cpp|lua_build_results_protected|process protected userdata/results" \
    "src/lua_bindings/pipeline.cpp|pipeline_process_gc_boundary|pipeline.__gc/__close" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_tostring>|pipeline.__tostring" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_read_stdout>|pipeline.read_stdout" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_read_stderr>|pipeline.read_stderr" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_write>|pipeline.write" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_close_stdin>|pipeline.close_stdin" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_is_running>|pipeline.is_running" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_pids>|pipeline.pids" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_wait>|pipeline.wait" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_terminate>|pipeline.terminate" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_kill>|pipeline.kill" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<pipeline_process_close>|pipeline.close" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<lua_pipeline_impl>|babet.pipeline" \
    "src/lua_bindings/pipeline.cpp|pipeline_lua_boundary<lua_spawn_pipeline_impl>|babet.spawnPipeline" \
    "src/lua_bindings/pipeline.cpp|lua_build_results_protected|pipeline protected userdata/results" \
    "src/lua_bindings/workers.cpp|channel_gc_boundary|channel.__gc" \
    "src/lua_bindings/workers.cpp|worker_gc_boundary|worker.__gc" \
    "src/lua_bindings/http.cpp|http_request_state_gc_boundary|http request state __gc" \
    "src/lua_bindings/fileIterator.cpp|lua_gcFileIterator_boundary|FileIterator.__gc" \
    "src/lua_bindings/fileIterator.cpp|lua_closeFileIterator_boundary|FileIterator.close/__close"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" "${pattern}" \
        "${label} does not use the audited boundary"
done

forbid_pattern \
    'lua_pushcfunction\(L, (lua_compress|lua_decompress|lua_sys_(which|env|setenv|hostname|uname|pid)|lua_user_(get|exists)|inot_(gc|tostring|add|read|remove|close)|lua_inotify_new)\);' \
    "at least one audited Lua C function is still registered directly" \
    "${ROOT_DIR}/src/lua_bindings/"{compression,sys,user,inotify}.cpp

require_pattern "src/lua_bindings/lua_utils.hpp" \
    'lua_cfunction_exception_boundary' \
    "common Lua C++ exception boundary helper is missing"

for specification in \
    "src/lua_bindings/base64.cpp|base64_boundary<lua_base64_encode_impl>|base64.encode" \
    "src/lua_bindings/base64.cpp|base64_boundary<lua_base64_decode_impl>|base64.decode" \
    "src/lua_bindings/fileIterator.cpp|file_iterator_boundary<lua_createFileIterator_impl>|createFileIterator" \
    "src/lua_bindings/fileIterator.cpp|file_iterator_boundary<lua_nextFile_impl>|FileIterator.next" \
    "src/lua_bindings/json.cpp|json_boundary<lua_json_encode_impl>|json.encode" \
    "src/lua_bindings/json.cpp|json_boundary<lua_json_decode_impl>|json.decode" \
    "src/lua_bindings/toml.cpp|toml_boundary<lua_toml_decode_impl>|toml.decode" \
    "src/lua_bindings/http.cpp|http_boundary<lua_http_request_impl>|http.request" \
    "src/lua_bindings/http.cpp|http_boundary<lua_http_get_impl>|http.get" \
    "src/lua_bindings/http.cpp|http_boundary<lua_http_post_impl>|http.post" \
    "src/lua_bindings/http.cpp|http_boundary<lua_http_download_impl>|http.download" \
    "src/lua_bindings/workers.cpp|workers_lua_boundary<lua_workers_spawn>|workers.spawn" \
    "src/lua_bindings/workers.cpp|workers_lua_boundary<lua_workers_channel>|workers.channel" \
    "src/lua_bindings/workers.cpp|workers_lua_boundary<worker_send>|Worker.send" \
    "src/lua_bindings/workers.cpp|workers_lua_boundary<worker_recv>|Worker.recv" \
    "src/lua_bindings/workers.cpp|workers_lua_boundary<channel_send>|WorkerChannel.send" \
    "src/lua_bindings/workers.cpp|workers_lua_boundary<channel_recv>|WorkerChannel.recv" \
    "src/lua_bindings/workers.cpp|worker_side_lua_boundary<worker_side_send>|worker.send" \
    "src/lua_bindings/workers.cpp|worker_side_lua_boundary<worker_side_recv>|worker.recv"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" "${pattern}" \
        "${label} does not enter through the audited boundary"
done

require_pattern "src/lua_bindings/lua_utils.hpp" \
    'lua_build_results_protected' \
    "protected Lua result builder is missing"

for specification in \
    "src/lua_bindings/archive.cpp|return lua_cfunction_exception_boundary<Fn>|archive common exception boundary" \
    "src/lua_bindings/socket.cpp|return lua_cfunction_exception_boundary<Fn>|socket common exception boundary" \
    "src/lua_bindings/sqlite.cpp|return lua_cfunction_exception_boundary<Fn>|sqlite common exception boundary" \
    "src/lua_bindings/archive.cpp|lua_build_results_protected|archive protected Lua results" \
    "src/lua_bindings/socket.cpp|push_string_protected|socket protected string results" \
    "src/lua_bindings/sqlite.cpp|push_fail_protected|sqlite protected diagnostics" \
    "src/lua_bindings/workers.cpp|PushCancellationPolicy::only_if_waiting|worker outbox cancellation policy" \
    "src/lua_bindings/workers.cpp|outbox.notify_waiters|worker outbox cancellation wakeup" \
    "src/lua_bindings/fileIterator.hpp|recursive_directory_iterator|lazy FileIterator native iterator"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" "${pattern}" "${label} is missing"
done

for specification in \
    "src/lua_bindings/socket.cpp|struct SockUserdata|socket constructed-state userdata" \
    "src/lua_bindings/socket.cpp|bool constructed;|socket raw userdata flag requires explicit initialization" \
    "src/lua_bindings/socket.cpp|is_nothrow_default_constructible_v<Sock>|socket nothrow construction contract" \
    "src/lua_bindings/socket.cpp|push_empty_sock_protected|socket protected userdata allocation" \
    "src/lua_bindings/workers.cpp|struct WorkerUserdata|worker constructed-state userdata" \
    "src/lua_bindings/workers.cpp|bool constructed;|worker raw userdata flag requires explicit initialization" \
    "src/lua_bindings/workers.cpp|is_nothrow_destructible_v<Worker>|worker nothrow destruction contract" \
    "src/lua_bindings/workers.cpp|worker_userdata->constructed = true|worker constructor completion marker" \
    "src/lua_bindings/workers.cpp|struct ChannelHandleUserdata|worker channel constructed-state userdata" \
    "src/lua_bindings/workers.cpp|is_nothrow_destructible_v<ChannelHandle>|worker channel nothrow destruction contract" \
    "src/lua_bindings/workers.cpp|channel_userdata->constructed = false|worker channel explicit inert state" \
    "src/lua_bindings/workers.cpp|userdata->constructed = true|worker channel constructor completion marker" \
    "src/lua_bindings/json.cpp|Intentionally registered directly: this function creates no C\+\+ owner|json.as_array direct-boundary rationale" \
    "src/lua_bindings/process.cpp|cleanup_process\(Process \*process\) noexcept|process allocation-free finalizer cleanup" \
    "src/lua_bindings/pipeline.cpp|cleanup_pipeline_process\(PipelineProcess \*pipeline\) noexcept|pipeline allocation-free finalizer cleanup"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" "${pattern}" "${label} is missing"
done


forbid_pattern 'push_fail[[:space:]]*\(' \
    "a Lua binding still contains a direct push_fail() result builder" \
    "${ROOT_DIR}/src/lua_bindings/"*.cpp

forbid_pattern 'push_action_result[[:space:]]*\(' \
    "a Lua binding still contains a direct push_action_result() builder" \
    "${ROOT_DIR}/src/lua_bindings/"*.cpp

forbid_pattern 'bool constructed[[:space:]]*=' \
    "raw userdata constructed flags must not rely on C++ default member initializers" \
    "${ROOT_DIR}/src/lua_bindings/socket.cpp" \
    "${ROOT_DIR}/src/lua_bindings/workers.cpp"

forbid_pattern 'lua_newuserdata\(L,[[:space:]]*sizeof\(ChannelHandle\)\)' \
    "worker channels still allocate a raw ChannelHandle without constructed-state tracking" \
    "${ROOT_DIR}/src/lua_bindings/workers.cpp"

forbid_pattern 'std::string newpath' \
    "worker package.path still owns a local string across allocating Lua calls" \
    "${ROOT_DIR}/src/lua_bindings/workers.cpp"

forbid_pattern 'lua_pushcfunction\(L,[[:space:]]*lua_' \
    "main.cpp still registers a historical binding without babet_lua_boundary" \
    "${ROOT_DIR}/src/main.cpp"

for specification in \
    "src/main.cpp|babet_lua_boundary|generic boundary for historical main registrations" \
    "src/lua_bindings/lua_utils.hpp|lua_run_protected|protected Lua parser runner" \
    "src/lua_bindings/lua_utils.hpp|lua_rotate\(Ls, 1, -1\)|protected parser moves internal context out of the argument range" \
    "src/lua_bindings/lua_utils.hpp|lua_pop\(Ls, 1\)|protected parser removes internal context" \
    "src/lua_bindings/lua_utils.hpp|lua_pcall\(L, argument_count \+ 1, 0, 0\)|protected parser forwards every caller argument" \
    "src/lua_bindings/lua_utils.hpp|lua_run_setup_protected|protected Lua runtime setup runner" \
    "src/lua_bindings/lua_utils.hpp|push_action_result_protected|protected action result helper" \
    "src/main.cpp|lua_run_setup_protected|main Lua runtime initialization under pcall" \
    "src/main.cpp|prepend_package_path\(state, package_prefix\)|main package.path emission inside protected setup" \
    "src/lua_bindings/exec.cpp|lua_cfunction_exception_boundary<lua_exec_impl>|exec public exception boundary" \
    "src/lua_bindings/exec.cpp|push_exec_result_protected|exec protected result table" \
    "src/lua_bindings/exec.cpp|lua_run_protected\(L, args_parser\)|exec protected argument parser" \
    "src/lua_bindings/exec.cpp|lua_run_protected\(L, opts_parser\)|exec protected option parser" \
    "src/lua_bindings/find.cpp|lua_cfunction_exception_boundary<lua_find_impl>|find public exception boundary" \
    "src/lua_bindings/find.cpp|std::vector<std::string> results|find native result collection" \
    "src/lua_bindings/find.cpp|lua_run_protected\(L, parser\)|find protected option parser" \
    "src/lua_bindings/find.cpp|lua_build_results_protected|find protected Lua result table" \
    "src/lua_bindings/listFiles.cpp|lua_cfunction_exception_boundary<lua_listFiles_impl>|listFiles public exception boundary" \
    "src/lua_bindings/listFiles.cpp|std::vector<std::string> results|listFiles native result collection" \
    "src/lua_bindings/listFiles.cpp|lua_build_results_protected|listFiles protected Lua result table" \
    "src/lua_bindings/deepCopyTable.cpp|visited.emplace\(srcPointer, LUA_NOREF\)|deepCopyTable pre-reserved registry slot" \
    "src/lua_bindings/deepCopyTable.cpp|release_visited_references|deepCopyTable registry cleanup" \
    "src/lua_bindings/deepCopyTable.cpp|lua_build_results_protected_with_stack_value|deepCopyTable protected recursive copy with forwarded source" \
    "src/lua_bindings/deepCopyTable.cpp|deepCopyTable\(Ls, 2, 0, MAX_DEPTH, visited\)|deepCopyTable uses the forwarded source argument" \
    "src/lua_bindings/lua_utils.hpp|lua_build_results_protected_with_stack_value|protected builder stack-value forwarding helper" \
    "src/lua_bindings/deepCopyTable.cpp|lua_cfunction_exception_boundary<lua_deepCopyTable_impl>|deepCopyTable public exception boundary" \
    "src/lua_bindings/sys.cpp|push_string_protected\(L, found\)|sys.which protected string result" \
    "src/lua_bindings/sys.cpp|push_string_protected\(L, val\)|sys.env protected string result" \
    "src/lua_bindings/sys.cpp|lua_build_results_protected|sys.uname protected result table" \
    "src/lua_bindings/compression.cpp|lua_run_protected\(L, parser\)|compression protected option parser" \
    "src/lua_bindings/archive.cpp|lua_run_protected\(L, source_parser\)|archive protected explicit-source parser" \
    "src/lua_bindings/archive.cpp|lua_run_protected\(L, create_options_parser\)|archive protected create options parser" \
    "src/lua_bindings/archive.cpp|lua_run_protected\(L, options_parser\)|archive protected read/extract options parsers" \
    "src/lua_bindings/user.cpp|lua_build_results_protected\(L, builder, 1\)|user.get protected passwd table" \
    "src/lua_bindings/inotify.cpp|class OwnedFd|inotify.new descriptor owner" \
    "src/lua_bindings/inotify.cpp|w->fd = -1|inotify userdata inert state before metatable" \
    "src/lua_bindings/inotify.cpp|w->fd = fd; // transfert après|inotify descriptor transfer after Lua allocations" \
    "src/lua_bindings/inotify.cpp|lua_build_results_protected\(L, builder, 1\)|inotify.new protected userdata construction" \
    "src/lua_bindings/inotify.cpp|owned_fd.release\(\)|inotify.new descriptor ownership transfer" \
    "src/lua_bindings/workers.cpp|lua_run_setup_protected\(|worker Lua-state initialization under pcall" \
    "src/lua_bindings/workers.cpp|setup_worker_namespace|worker namespace protected setup" \
    "src/lua_bindings/workers.cpp|new \(userdata->storage\) ChannelHandle\{\}|worker channel construction after metatable" \
    "src/lua_bindings/workers.cpp|userdata->get\(\)->shared = shared|worker channel ownership transfer after construction" \
    "src/lua_bindings/attributes.cpp|lua_build_results_protected|attributes protected table result" \
    "src/lua_bindings/currentDir.cpp|push_string_result_protected|currentDir protected string result" \
    "src/lua_bindings/fileUtils.cpp|push_string_result_protected|fileUtils protected string result" \
    "src/lua_bindings/joinPath.cpp|lua_run_protected\(L, parser\)|joinPath protected table parser" \
    "src/lua_bindings/joinPath.cpp|push_string_protected|joinPath protected string result" \
    "src/lua_bindings/time_format.cpp|push_string_protected|time formatting protected string result" \
    "tools/test_lua_longjmp_oom.sh|src/lua_bindings/deepCopyTable.cpp|OOM test compiles real deepCopyTable binding" \
    "tools/test_lua_longjmp_oom.sh|src/lua_bindings/listFiles.cpp|OOM test compiles real listFiles binding" \
    "tools/test_lua_longjmp_oom.sh|src/lua_bindings/exec.cpp|OOM test compiles real exec binding" \
    "tools/lua_longjmp_oom_selftest.cpp|run_exec_oom|OOM test exercises exec buffers" \
    "tools/lua_longjmp_oom_selftest.cpp|run_argument_forwarding|protected parser test preserves caller argument indices" \
    "tools/lua_longjmp_oom_selftest.cpp|run_setup_oom|OOM test exercises protected runtime setup" \
    "tools/lua_longjmp_oom_selftest.cpp|run_list_files_oom|OOM test exercises listFiles descriptor cleanup" \
    "tools/lua_longjmp_oom_selftest.cpp|run_deepcopy_oom|OOM test exercises deepCopyTable registry cleanup"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" "${pattern}" "${label} is missing"
done

for specification in \
    "src/lua_bindings/process_common.cpp|WEXITED.*WNOWAIT|terminal exit monitor observes completion without reaping" \
    "src/lua_bindings/process_common.cpp|SYS_pidfd_open|terminal exit monitor pins the child identity when pidfd is available" \
    "src/lua_bindings/process_common.hpp|pid_t owner_pgid = -1|terminal handoff tracks its exact foreground owner" \
    "src/lua_bindings/process_common.cpp|reserve_terminal_handoff\(|terminal handoffs are serialized before fork" \
    "src/lua_bindings/process_common.cpp|WEXITED.*WNOHANG.*WNOWAIT|successive spawn recovery detects a finished direct child without reaping" \
    "src/lua_bindings/process_common.cpp|commit_terminal_handoff\(|foreground transfer and registry ownership commit together" \
    "src/lua_bindings/process_common.cpp|terminal_handoff_registry.owner_pgid == context->pid|old terminal monitor restores only its own child" \
    "src/lua_bindings/process_common.cpp|BABET_TEST_TERMINAL_MONITOR_DELAY_MS|PTY race delay hook remains available" \
    "src/lua_bindings/process_common.cpp|reclaim_terminal\(TerminalHandoff &terminal\)|stopped-child terminal reclamation helper" \
    "src/lua_bindings/process_common.cpp|foreground_terminal\(TerminalHandoff &terminal|foreground resume helper" \
    "src/lua_bindings/process.cpp|WNOHANG.*WUNTRACED.*WCONTINUED|non-blocking process state refresh observes stop/continue" \
    "src/lua_bindings/process.cpp|wait_options = WUNTRACED.*WCONTINUED|blocking process wait observes stop/continue" \
    "src/lua_bindings/process.cpp|push_fail_protected\(L, \"stopped\"\)|wait reports stopped state without hanging" \
    "src/lua_bindings/process.cpp|return push_string_protected\(L, state\)|process.state emits its allocating result under pcall" \
    "src/lua_bindings/process.cpp|foreground_terminal\(process->terminal, process->pid\)|resume restores foreground ownership" \
    "tools/test_spawn_pty.sh|STOP_RESUME_OK|PTY regression covers stopped-child resume" \
    "tools/test_spawn_pty.sh|ASYNC_RECLAIM_OK|PTY regression covers asynchronous terminal reclamation" \
    "tools/test_spawn_pty.sh|BABET_TEST_TERMINAL_MONITOR_DELAY_MS.*1500|PTY race widens the stale-monitor window deterministically" \
    "tools/test_spawn_pty.sh|SUCCESSIVE_SPAWN_OK|PTY regression covers two immediate interactive spawns"
do
    IFS='|' read -r file pattern label <<< "${specification}"
    require_pattern "${file}" "${pattern}" "${label} is missing"
done

if [ "${FAILURES}" -ne 0 ]; then
    echo "Exception boundary structural checks: ${FAILURES} failure(s)"
    exit 1
fi

CXX_BIN="${CXX:-c++}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/babet-boundary-test.XXXXXX")" || exit 1
trap 'rm -rf -- "${TMP_ROOT}"' EXIT

CHECKS=$((CHECKS + 1))
if ! "${CXX_BIN}" -std=c++23 -Wall -Wextra -Wpedantic -Werror \
    -I"${ROOT_DIR}/src/lua_bindings" \
    "${SCRIPT_DIR}/exception_boundary_selftest.cpp" \
    -o "${TMP_ROOT}/exception_boundary_selftest"; then
    fail "exception boundary self-test compilation"
    exit 1
fi

if ! "${TMP_ROOT}/exception_boundary_selftest"; then
    fail "exception boundary self-test execution"
    exit 1
fi

echo "Exception boundary and RAII checks: ${CHECKS}/${CHECKS} audited contracts protected"
