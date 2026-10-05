#include <babet/babet.h>

#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int babet_test_lifecycle(void);

typedef struct thread_probe
{
    babet_context *context;
    const char *search_root;
    babet_status run_status;
    babet_status search_root_status;
    babet_status set_global_status;
    babet_status get_global_status;
    babet_status call_global_status;
    babet_status register_host_status;
    babet_status destroy_status;
} thread_probe;

typedef struct host_function_probe
{
    babet_context *context;
    unsigned echo_calls;
    unsigned failure_calls;
    unsigned reentrant_calls;
    babet_status reentrant_run_status;
    babet_status reentrant_destroy_status;
} host_function_probe;

static char g_search_root[PATH_MAX];

static babet_status noop_host_function(babet_host_call *call, void *userdata)
{
    (void)call;
    (void)userdata;
    return BABET_STATUS_OK;
}

static babet_status scalar_echo_host_function(babet_host_call *call,
                                              void *userdata)
{
    host_function_probe *probe = (host_function_probe *)userdata;
    const size_t count = babet_host_call_argument_count(call);
    const babet_value *arguments = babet_host_call_arguments(call);
    if (probe == NULL || count != 5 || arguments == NULL)
    {
        (void)babet_host_call_set_error(call,
                                        "echo expects exactly five scalar arguments");
        return BABET_STATUS_INVALID_ARGUMENT;
    }
    if (arguments[0].type != BABET_VALUE_NIL ||
        arguments[1].type != BABET_VALUE_BOOLEAN ||
        arguments[1].as.boolean != 1 ||
        arguments[2].type != BABET_VALUE_INTEGER ||
        arguments[2].as.integer != INT64_C(1234567890123) ||
        arguments[3].type != BABET_VALUE_NUMBER ||
        arguments[3].as.number != 2.5 ||
        arguments[4].type != BABET_VALUE_STRING ||
        arguments[4].as.string.length != 3 ||
        memcmp(arguments[4].as.string.data, "H\0I", 3) != 0)
    {
        (void)babet_host_call_set_error(call,
                                        "echo received unexpected scalar values");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    ++probe->echo_calls;
    /* set_result copies the borrowed Lua string before this callback returns. */
    return babet_host_call_set_result(call, &arguments[4]);
}

static babet_status failing_host_function(babet_host_call *call,
                                          void *userdata)
{
    host_function_probe *probe = (host_function_probe *)userdata;
    if (probe != NULL)
        ++probe->failure_calls;
    (void)babet_host_call_set_error(call, "host callback sentinel");
    return BABET_STATUS_INVALID_ARGUMENT;
}

static babet_status reentrant_host_function(babet_host_call *call,
                                            void *userdata)
{
    host_function_probe *probe = (host_function_probe *)userdata;
    if (probe == NULL || probe->context == NULL)
    {
        (void)babet_host_call_set_error(call, "missing reentrancy probe context");
        return BABET_STATUS_INTERNAL_ERROR;
    }

    ++probe->reentrant_calls;
    static const char chunk[] = "return 1";
    probe->reentrant_run_status = babet_context_run(
        probe->context, chunk, sizeof(chunk) - 1, "host-reentrant-run");
    probe->reentrant_destroy_status = babet_context_destroy(probe->context);

    babet_value result = {0};
    result.type = BABET_VALUE_BOOLEAN;
    result.as.boolean =
        probe->reentrant_run_status == BABET_STATUS_REENTRANT_CALL &&
        probe->reentrant_destroy_status == BABET_STATUS_REENTRANT_CALL;
    return babet_host_call_set_result(call, &result);
}

static babet_status late_host_function(babet_host_call *call, void *userdata)
{
    (void)userdata;
    babet_value result = {0};
    result.type = BABET_VALUE_INTEGER;
    result.as.integer = 77;
    return babet_host_call_set_result(call, &result);
}

static babet_status invalid_status_host_function(babet_host_call *call,
                                                 void *userdata)
{
    (void)call;
    (void)userdata;
    return (babet_status)UINT32_C(999);
}

static void cleanup_search_root(void)
{
    if (g_search_root[0] == '\0')
        return;

    char module_path[PATH_MAX];
    const int written = snprintf(module_path, sizeof(module_path),
                                 "%s/host_module.lua", g_search_root);
    if (written > 0 && (size_t)written < sizeof(module_path))
        (void)unlink(module_path);

    char package_init[PATH_MAX];
    const int init_written = snprintf(package_init, sizeof(package_init),
                                      "%s/host_pkg/init.lua", g_search_root);
    if (init_written > 0 && (size_t)init_written < sizeof(package_init))
        (void)unlink(package_init);

    char package_dir[PATH_MAX];
    const int dir_written = snprintf(package_dir, sizeof(package_dir),
                                     "%s/host_pkg", g_search_root);
    if (dir_written > 0 && (size_t)dir_written < sizeof(package_dir))
        (void)rmdir(package_dir);
    (void)rmdir(g_search_root);
}

static int prepare_search_root(void)
{
    static const char module_source[] =
        "return { value = 'host-root-ok' }\n";
    static const char package_source[] =
        "return { value = 'host-init-ok' }\n";

    if (snprintf(g_search_root, sizeof(g_search_root),
                 "/tmp/babet-embedding-root.XXXXXX") <= 0 ||
        mkdtemp(g_search_root) == NULL)
    {
        perror("mkdtemp");
        g_search_root[0] = '\0';
        return 0;
    }

    char module_path[PATH_MAX];
    const int written = snprintf(module_path, sizeof(module_path),
                                 "%s/host_module.lua", g_search_root);
    if (written <= 0 || (size_t)written >= sizeof(module_path))
    {
        fprintf(stderr, "embedding module path is too long\n");
        return 0;
    }

    FILE *module = fopen(module_path, "wb");
    if (module == NULL)
    {
        perror("fopen host_module.lua");
        return 0;
    }
    const size_t source_size = sizeof(module_source) - 1;
    const int write_ok =
        fwrite(module_source, 1, source_size, module) == source_size;
    const int close_ok = fclose(module) == 0;
    if (!write_ok || !close_ok)
    {
        fprintf(stderr, "unable to write embedding host module\n");
        return 0;
    }

    char package_dir[PATH_MAX];
    const int dir_written = snprintf(package_dir, sizeof(package_dir),
                                     "%s/host_pkg", g_search_root);
    if (dir_written <= 0 || (size_t)dir_written >= sizeof(package_dir) ||
        mkdir(package_dir, 0700) != 0)
    {
        perror("mkdir host_pkg");
        return 0;
    }

    char package_init[PATH_MAX];
    const int init_written = snprintf(package_init, sizeof(package_init),
                                      "%s/init.lua", package_dir);
    if (init_written <= 0 || (size_t)init_written >= sizeof(package_init))
    {
        fprintf(stderr, "embedding package init path is too long\n");
        return 0;
    }
    FILE *init = fopen(package_init, "wb");
    if (init == NULL)
    {
        perror("fopen host_pkg/init.lua");
        return 0;
    }
    const size_t package_size = sizeof(package_source) - 1;
    const int package_write_ok =
        fwrite(package_source, 1, package_size, init) == package_size;
    const int package_close_ok = fclose(init) == 0;
    if (!package_write_ok || !package_close_ok)
    {
        fprintf(stderr, "unable to write embedding package init\n");
        return 0;
    }
    return 1;
}

static void *run_from_wrong_thread(void *opaque)
{
    thread_probe *probe = (thread_probe *)opaque;
    static const char chunk[] = "return 1";
    probe->run_status = babet_context_run(probe->context, chunk,
                                          sizeof(chunk) - 1, "wrong-thread");
    probe->search_root_status =
        babet_context_set_search_root(probe->context, probe->search_root);
    babet_value input = {0};
    input.type = BABET_VALUE_INTEGER;
    input.as.integer = 1;
    probe->set_global_status =
        babet_context_set_global(probe->context, "wrong_thread_value", &input);
    babet_value output = {0};
    probe->get_global_status =
        babet_context_get_global(probe->context, "wrong_thread_value", &output);
    probe->call_global_status = babet_context_call_global(
        probe->context, "wrong_thread_function", NULL, 0, &output);
    probe->register_host_status = babet_context_register_host_function(
        probe->context, "wrong_thread_host", noop_host_function, NULL);
    probe->destroy_status = babet_context_destroy(probe->context);
    return NULL;
}

static int expect_status(const char *label, babet_status got,
                         babet_status expected)
{
    if (got == expected)
        return 1;
    fprintf(stderr, "%s: expected %s, got %s\n", label,
            babet_status_name(expected), babet_status_name(got));
    return 0;
}

int main(void)
{
    _Static_assert(sizeof(babet_status) == sizeof(uint32_t),
                   "babet_status must stay a 32-bit ABI tag");
    _Static_assert(sizeof(babet_value_type) == sizeof(uint32_t),
                   "babet_value_type must stay a 32-bit ABI tag");

    babet_context *context = NULL;
    babet_context *second = NULL;

    if (atexit(cleanup_search_root) != 0 || !prepare_search_root())
        return 1;

    if (!expect_status("create invalid out", babet_context_create(NULL),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("destroy NULL", babet_context_destroy(NULL),
                       BABET_STATUS_OK))
        return 1;
    if (babet_context_last_error(NULL)[0] != '\0')
    {
        fprintf(stderr, "NULL context exposed a non-empty diagnostic\n");
        return 1;
    }
    if (strcmp(babet_status_name((babet_status)999), "unknown") != 0)
    {
        fprintf(stderr, "unknown status name is not stable\n");
        return 1;
    }

    if (babet_version() == NULL || babet_version()[0] == '\0')
    {
        fprintf(stderr, "empty Babet version\n");
        return 1;
    }

    if (!expect_status("create", babet_context_create(&context),
                       BABET_STATUS_OK) || context == NULL)
        return 1;

    if (!expect_status("second context", babet_context_create(&second),
                       BABET_STATUS_BUSY) || second != NULL)
        return 1;

    if (!expect_status("NULL search root",
                       babet_context_set_search_root(context, NULL),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("missing search root",
                       babet_context_set_search_root(
                           context, "/definitely/missing/babet-embedding-root"),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (strstr(babet_context_last_error(context), "not a directory") == NULL)
    {
        fprintf(stderr, "missing search-root diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }

    char non_directory_root[PATH_MAX];
    const int non_directory_written =
        snprintf(non_directory_root, sizeof(non_directory_root),
                 "%s/host_module.lua", g_search_root);
    if (non_directory_written <= 0 ||
        (size_t)non_directory_written >= sizeof(non_directory_root))
    {
        fprintf(stderr, "non-directory search-root path is too long\n");
        return 1;
    }
    if (!expect_status("file search root",
                       babet_context_set_search_root(context, non_directory_root),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (strstr(babet_context_last_error(context), "not a directory") == NULL)
    {
        fprintf(stderr, "file search-root diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (!expect_status("configure search root",
                       babet_context_set_search_root(context, g_search_root),
                       BABET_STATUS_OK))
    {
        fprintf(stderr, "search-root detail: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (babet_context_last_error(context)[0] != '\0')
    {
        fprintf(stderr, "search-root success did not clear prior diagnostic\n");
        return 1;
    }
    if (!expect_status("duplicate search root",
                       babet_context_set_search_root(context, g_search_root),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;

    babet_value value = {0};
    babet_value output = {0};
    if (!expect_status("NULL scalar input",
                       babet_context_set_global(context, "host_invalid", NULL),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("empty scalar name",
                       babet_context_set_global(context, "", &value),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("NULL scalar output",
                       babet_context_get_global(context, "host_invalid", NULL),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    value.type = (babet_value_type)999;
    if (!expect_status("unknown scalar type",
                       babet_context_set_global(context, "host_invalid", &value),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    value.type = BABET_VALUE_STRING;
    value.as.string.data = NULL;
    value.as.string.length = 1;
    if (!expect_status("NULL nonempty scalar string",
                       babet_context_set_global(context, "host_invalid", &value),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;

    value.type = BABET_VALUE_NIL;
    if (!expect_status("set host nil",
                       babet_context_set_global(context, "host_nil", &value),
                       BABET_STATUS_OK))
        return 1;
    value.type = BABET_VALUE_BOOLEAN;
    value.as.boolean = 7;
    if (!expect_status("set host boolean",
                       babet_context_set_global(context, "host_bool", &value),
                       BABET_STATUS_OK))
        return 1;
    value.type = BABET_VALUE_INTEGER;
    value.as.integer = INT64_C(1234567890123);
    if (!expect_status("set host integer",
                       babet_context_set_global(context, "host_int", &value),
                       BABET_STATUS_OK))
        return 1;
    value.type = BABET_VALUE_NUMBER;
    value.as.number = 3.25;
    if (!expect_status("set host number",
                       babet_context_set_global(context, "host_num", &value),
                       BABET_STATUS_OK))
        return 1;
    static const char host_bytes[] = {'A', '\0', 'B'};
    value.type = BABET_VALUE_STRING;
    value.as.string.data = host_bytes;
    value.as.string.length = sizeof(host_bytes);
    if (!expect_status("set host byte string",
                       babet_context_set_global(context, "host_bytes", &value),
                       BABET_STATUS_OK))
        return 1;

    host_function_probe host_probe = {context, 0, 0, 0,
                                      BABET_STATUS_OK, BABET_STATUS_OK};
    if (babet_host_call_argument_count(NULL) != 0 ||
        babet_host_call_arguments(NULL) != NULL)
    {
        fprintf(stderr, "NULL host call accessors are not neutral\n");
        return 1;
    }
    if (!expect_status("NULL host result call",
                       babet_host_call_set_result(NULL, &value),
                       BABET_STATUS_INVALID_ARGUMENT) ||
        !expect_status("NULL host error call",
                       babet_host_call_set_error(NULL, "ignored"),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("NULL host callback",
                       babet_context_register_host_function(context, "echo",
                                                            NULL, &host_probe),
                       BABET_STATUS_INVALID_ARGUMENT) ||
        !expect_status("empty host callback name",
                       babet_context_register_host_function(
                           context, "", scalar_echo_host_function, &host_probe),
                       BABET_STATUS_INVALID_ARGUMENT) ||
        !expect_status("dotted host callback name",
                       babet_context_register_host_function(
                           context, "bad.name", scalar_echo_host_function,
                           &host_probe),
                       BABET_STATUS_INVALID_ARGUMENT) ||
        !expect_status("Lua-keyword host callback name",
                       babet_context_register_host_function(
                           context, "end", scalar_echo_host_function,
                           &host_probe),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;

    char copied_host_name[] = "echo";
    if (!expect_status("register scalar host callback",
                       babet_context_register_host_function(
                           context, copied_host_name, scalar_echo_host_function,
                           &host_probe),
                       BABET_STATUS_OK))
        return 1;
    copied_host_name[0] = 'X';
    if (!expect_status("duplicate scalar host callback",
                       babet_context_register_host_function(
                           context, "echo", scalar_echo_host_function,
                           &host_probe),
                       BABET_STATUS_INVALID_ARGUMENT) ||
        !expect_status("register failing host callback",
                       babet_context_register_host_function(
                           context, "fail", failing_host_function, &host_probe),
                       BABET_STATUS_OK) ||
        !expect_status("register reentrant host callback",
                       babet_context_register_host_function(
                           context, "reentrant", reentrant_host_function,
                           &host_probe),
                       BABET_STATUS_OK) ||
        !expect_status("register invalid-status host callback",
                       babet_context_register_host_function(
                           context, "invalid_status", invalid_status_host_function,
                           NULL),
                       BABET_STATUS_OK))
        return 1;

    if (!expect_status("empty chunk",
                       babet_context_run(context, NULL, 0, NULL),
                       BABET_STATUS_OK))
        return 1;
    if (!expect_status("invalid NULL chunk",
                       babet_context_run(context, NULL, 1, NULL),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;

    static const char good_chunk[] =
        "assert(type(babet) == 'table')\n"
        "assert(type(babet.VERSION) == 'string')\n"
        "assert(type(babet.host) == 'table')\n"
        "local host_echo = babet.host.echo(nil, true, 1234567890123, 2.5, 'H\\0I')\n"
        "assert(#host_echo == 3 and host_echo:byte(1) == 72 and host_echo:byte(2) == 0 and host_echo:byte(3) == 73)\n"
        "assert(babet.host.reentrant() == true)\n"
        "local host_ok, host_err = pcall(babet.host.fail)\n"
        "assert(host_ok == false and tostring(host_err):find('host callback sentinel', 1, true))\n"
        "local status_ok, status_err = pcall(babet.host.invalid_status)\n"
        "assert(status_ok == false and tostring(status_err):find('unknown babet_status', 1, true))\n"
        "local arg_ok, arg_err = pcall(babet.host.echo, {})\n"
        "assert(arg_ok == false and tostring(arg_err):find('unsupported type table', 1, true))\n"
        "local host_echo_after_error = babet.host.echo(nil, true, 1234567890123, 2.5, 'H\\0I')\n"
        "assert(#host_echo_after_error == 3)\n"
        "local wrapped_echo = coroutine.wrap(function() return babet.host.echo(nil, true, 1234567890123, 2.5, 'H\\0I') end)()\n"
        "assert(#wrapped_echo == 3 and wrapped_echo:byte(2) == 0)\n"
        "local host_co = coroutine.create(function() return babet.host.echo(nil, true, 1234567890123, 2.5, 'H\\0I') end)\n"
        "local host_resumed, resumed_echo = coroutine.resume(host_co)\n"
        "assert(host_resumed == true and #resumed_echo == 3 and resumed_echo:byte(2) == 0)\n"
        "assert(babet.base64.encode('abc') == 'YWJj')\n"
        "assert(babet.json.decode('{\\\"answer\\\":42}').answer == 42)\n"
        "local inspect = require('inspect')\n"
        "local rendered = inspect({answer=42})\n"
        "assert(type(rendered) == 'string' and rendered:find('answer = 42', 1, true))\n"
        "local host_module = require('host_module')\n"
        "assert(host_module.value == 'host-root-ok')\n"
        "assert(require('host_pkg').value == 'host-init-ok')\n"
        "local w = babet.workers.spawn(\"local m = require('host_module'); return m.value\")\n"
        "local joined, value = w:join(5)\n"
        "assert(joined == true and value == 'host-root-ok', tostring(value))\n"
        "local hw = babet.workers.spawn(\"return babet.host == nil\")\n"
        "local hw_joined, host_absent = hw:join(5)\n"
        "assert(hw_joined == true and host_absent == true, tostring(host_absent))\n"
        "assert(host_nil == nil)\n"
        "assert(host_bool == true)\n"
        "assert(host_int == 1234567890123)\n"
        "assert(host_num == 3.25)\n"
        "assert(#host_bytes == 3 and host_bytes:byte(1) == 65 and host_bytes:byte(2) == 0 and host_bytes:byte(3) == 66)\n"
        "lua_nil = nil\n"
        "lua_bool = false\n"
        "lua_int = -9876543210\n"
        "lua_num = 6.5\n"
        "lua_bytes = 'X\\0Y'\n"
        "lua_table = {}\n"
        "function host_scalar_call(a, b, c, d, e)\n"
        "  assert(a == nil)\n"
        "  assert(b == true)\n"
        "  assert(c == 1234567890123)\n"
        "  assert(d == 2.5)\n"
        "  assert(#e == 3 and e:byte(1) == 88 and e:byte(2) == 0 and e:byte(3) == 89)\n"
        "  return e .. '\\0R'\n"
        "end\n"
        "function host_no_result() end\n"
        "function host_structured_result() return {} end\n"
        "not_callable = 42\n"
        "function host_call_error() error('embedding call sentinel') end\n"
        "function lua_calls_host() return babet.host.echo(nil, true, 1234567890123, 2.5, 'H\\0I') end\n";

    if (!expect_status("run valid chunk",
                       babet_context_run(context, good_chunk,
                                         sizeof(good_chunk) - 1,
                                         "embedding-smoke"),
                       BABET_STATUS_OK))
    {
        fprintf(stderr, "detail: %s\n", babet_context_last_error(context));
        return 1;
    }

    if (host_probe.echo_calls != 4 || host_probe.failure_calls != 1 ||
        host_probe.reentrant_calls != 1 ||
        host_probe.reentrant_run_status != BABET_STATUS_REENTRANT_CALL ||
        host_probe.reentrant_destroy_status != BABET_STATUS_REENTRANT_CALL)
    {
        fprintf(stderr,
                "host callback counters/reentrancy mismatch: echo=%u fail=%u "
                "reentrant=%u run=%s destroy=%s\n",
                host_probe.echo_calls, host_probe.failure_calls,
                host_probe.reentrant_calls,
                babet_status_name(host_probe.reentrant_run_status),
                babet_status_name(host_probe.reentrant_destroy_status));
        return 1;
    }
    if (strcmp(babet_status_name(BABET_STATUS_REENTRANT_CALL),
               "reentrant_call") != 0)
    {
        fprintf(stderr, "reentrant status name mismatch\n");
        return 1;
    }

    static const char uncaught_host_failure[] = "babet.host.fail()";
    if (!expect_status("uncaught host callback failure",
                       babet_context_run(context, uncaught_host_failure,
                                         sizeof(uncaught_host_failure) - 1,
                                         "embedding-host-failure"),
                       BABET_STATUS_LUA_ERROR))
        return 1;
    if (strstr(babet_context_last_error(context), "host callback sentinel") == NULL ||
        strstr(babet_context_last_error(context), "invalid_argument") == NULL)
    {
        fprintf(stderr, "missing host callback diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    static const char host_recovery_chunk[] =
        "local s=babet.host.echo(nil,true,1234567890123,2.5,'H\0I'); assert(#s==3)";
    if (!expect_status("host callback recovery after uncaught failure",
                       babet_context_run(context, host_recovery_chunk,
                                         sizeof(host_recovery_chunk) - 1,
                                         "embedding-host-recovery"),
                       BABET_STATUS_OK))
        return 1;
    if (host_probe.failure_calls != 2 || host_probe.echo_calls != 5)
    {
        fprintf(stderr, "host recovery counters mismatch: echo=%u fail=%u\n",
                host_probe.echo_calls, host_probe.failure_calls);
        return 1;
    }

    if (!expect_status("get Lua nil",
                       babet_context_get_global(context, "lua_nil", &output),
                       BABET_STATUS_OK) || output.type != BABET_VALUE_NIL)
    {
        fprintf(stderr, "Lua nil marshalling mismatch\n");
        return 1;
    }
    if (!expect_status("get Lua boolean",
                       babet_context_get_global(context, "lua_bool", &output),
                       BABET_STATUS_OK) || output.type != BABET_VALUE_BOOLEAN ||
        output.as.boolean != 0)
    {
        fprintf(stderr, "Lua boolean marshalling mismatch\n");
        return 1;
    }
    if (!expect_status("get Lua integer",
                       babet_context_get_global(context, "lua_int", &output),
                       BABET_STATUS_OK) || output.type != BABET_VALUE_INTEGER ||
        output.as.integer != INT64_C(-9876543210))
    {
        fprintf(stderr, "Lua integer marshalling mismatch\n");
        return 1;
    }
    if (!expect_status("get Lua number",
                       babet_context_get_global(context, "lua_num", &output),
                       BABET_STATUS_OK) || output.type != BABET_VALUE_NUMBER ||
        output.as.number != 6.5)
    {
        fprintf(stderr, "Lua number marshalling mismatch\n");
        return 1;
    }
    if (!expect_status("get Lua byte string",
                       babet_context_get_global(context, "lua_bytes", &output),
                       BABET_STATUS_OK) || output.type != BABET_VALUE_STRING ||
        output.as.string.length != 3 ||
        memcmp(output.as.string.data, "X\0Y", 3) != 0)
    {
        fprintf(stderr, "Lua byte-string marshalling mismatch\n");
        return 1;
    }
    babet_value borrowed_string = output;
    if (!expect_status("round-trip borrowed string",
                       babet_context_set_global(context, "roundtrip_bytes",
                                                &borrowed_string),
                       BABET_STATUS_OK))
        return 1;
    static const char roundtrip_chunk[] =
        "assert(#roundtrip_bytes == 3 and roundtrip_bytes:byte(1) == 88 and "
        "roundtrip_bytes:byte(2) == 0 and roundtrip_bytes:byte(3) == 89)";
    if (!expect_status("verify borrowed string round-trip",
                       babet_context_run(context, roundtrip_chunk,
                                         sizeof(roundtrip_chunk) - 1,
                                         "embedding-value-roundtrip"),
                       BABET_STATUS_OK))
        return 1;


    if (!expect_status("NULL call result",
                       babet_context_call_global(context, "host_scalar_call",
                                                 NULL, 0, NULL),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("NULL call arguments",
                       babet_context_call_global(context, "host_scalar_call",
                                                 NULL, 1, &output),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("empty call name",
                       babet_context_call_global(context, "", NULL, 0, &output),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;

    babet_value borrowed_call_string = {0};
    if (!expect_status("get borrowed call string",
                       babet_context_get_global(context, "lua_bytes",
                                                &borrowed_call_string),
                       BABET_STATUS_OK) ||
        borrowed_call_string.type != BABET_VALUE_STRING)
        return 1;

    babet_value call_arguments[5] = {{0}};
    call_arguments[0].type = BABET_VALUE_NIL;
    call_arguments[1].type = BABET_VALUE_BOOLEAN;
    call_arguments[1].as.boolean = 1;
    call_arguments[2].type = BABET_VALUE_INTEGER;
    call_arguments[2].as.integer = INT64_C(1234567890123);
    call_arguments[3].type = BABET_VALUE_NUMBER;
    call_arguments[3].as.number = 2.5;
    call_arguments[4] = borrowed_call_string;
    if (!expect_status("call Lua scalar function",
                       babet_context_call_global(context, "host_scalar_call",
                                                 call_arguments, 5, &output),
                       BABET_STATUS_OK) ||
        output.type != BABET_VALUE_STRING || output.as.string.length != 5 ||
        memcmp(output.as.string.data, "X\0Y\0R", 5) != 0)
    {
        fprintf(stderr, "Lua scalar call result mismatch: %s\n",
                babet_context_last_error(context));
        return 1;
    }

    const unsigned echo_calls_before_call_global = host_probe.echo_calls;
    if (!expect_status("call Lua function that invokes host callback",
                       babet_context_call_global(context, "lua_calls_host",
                                                 NULL, 0, &output),
                       BABET_STATUS_OK) ||
        output.type != BABET_VALUE_STRING || output.as.string.length != 3 ||
        memcmp(output.as.string.data, "H\0I", 3) != 0)
    {
        fprintf(stderr, "Lua -> host -> Lua scalar result mismatch: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (host_probe.echo_calls != echo_calls_before_call_global + 1)
    {
        fprintf(stderr,
                "call_global host callback count mismatch: before=%u after=%u\n",
                echo_calls_before_call_global, host_probe.echo_calls);
        return 1;
    }

    if (!expect_status("call Lua no-result function",
                       babet_context_call_global(context, "host_no_result",
                                                 NULL, 0, &output),
                       BABET_STATUS_OK) || output.type != BABET_VALUE_NIL)
    {
        fprintf(stderr, "Lua no-result call did not yield nil\n");
        return 1;
    }
    if (!expect_status("reject structured call result",
                       babet_context_call_global(context,
                                                 "host_structured_result",
                                                 NULL, 0, &output),
                       BABET_STATUS_UNSUPPORTED_VALUE))
        return 1;
    if (strstr(babet_context_last_error(context), "table") == NULL)
    {
        fprintf(stderr, "structured call diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (!expect_status("call missing function",
                       babet_context_call_global(context,
                                                 "definitely_missing_function",
                                                 NULL, 0, &output),
                       BABET_STATUS_LUA_ERROR))
        return 1;
    if (strstr(babet_context_last_error(context), "not a function") == NULL)
    {
        fprintf(stderr, "missing-function call diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (!expect_status("call non-function global",
                       babet_context_call_global(context, "not_callable",
                                                 NULL, 0, &output),
                       BABET_STATUS_LUA_ERROR))
        return 1;
    if (!expect_status("call Lua error function",
                       babet_context_call_global(context, "host_call_error",
                                                 NULL, 0, &output),
                       BABET_STATUS_LUA_ERROR))
        return 1;
    if (strstr(babet_context_last_error(context), "embedding call sentinel") == NULL)
    {
        fprintf(stderr, "call-error diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (!expect_status("call recovery after Lua error",
                       babet_context_call_global(context, "host_no_result",
                                                 NULL, 0, &output),
                       BABET_STATUS_OK))
        return 1;
    if (!expect_status("reject Lua table value",
                       babet_context_get_global(context, "lua_table", &output),
                       BABET_STATUS_UNSUPPORTED_VALUE))
        return 1;
    if (strstr(babet_context_last_error(context), "table") == NULL)
    {
        fprintf(stderr, "unsupported-value diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (strcmp(babet_status_name(BABET_STATUS_UNSUPPORTED_VALUE),
               "unsupported_value") != 0)
    {
        fprintf(stderr, "unsupported-value status name mismatch\n");
        return 1;
    }

    static const char bad_chunk[] = "error('embedding sentinel')";
    if (!expect_status("run failing chunk",
                       babet_context_run(context, bad_chunk,
                                         sizeof(bad_chunk) - 1,
                                         "embedding-error"),
                       BABET_STATUS_LUA_ERROR))
        return 1;
    if (strstr(babet_context_last_error(context), "embedding sentinel") == NULL)
    {
        fprintf(stderr, "missing Lua diagnostic: %s\n",
                babet_context_last_error(context));
        return 1;
    }

    static const char recovery_chunk[] = "assert(babet.VERSION ~= nil)";
    if (!expect_status("reuse after Lua error",
                       babet_context_run(context, recovery_chunk,
                                         sizeof(recovery_chunk) - 1,
                                         "embedding-recovery"),
                       BABET_STATUS_OK))
        return 1;
    if (babet_context_last_error(context)[0] != '\0')
    {
        fprintf(stderr, "last error was not cleared after recovery\n");
        return 1;
    }

    static const char hostile_host_metatable_chunk[] =
        "host_newindex_calls = 0; "
        "setmetatable(babet.host, {__newindex=function() "
        "host_newindex_calls = host_newindex_calls + 1; "
        "error('host __newindex sentinel') end})";
    if (!expect_status("install hostile babet.host metatable",
                       babet_context_run(context, hostile_host_metatable_chunk,
                                         sizeof(hostile_host_metatable_chunk) - 1,
                                         "embedding-host-metatable"),
                       BABET_STATUS_OK))
        return 1;

    if (!expect_status("late host callback registration bypasses metamethods",
                       babet_context_register_host_function(
                           context, "late_value", late_host_function, NULL),
                       BABET_STATUS_OK))
        return 1;
    static const char late_host_chunk[] =
        "assert(host_newindex_calls == 0); "
        "assert(babet.host.late_value() == 77)";
    if (!expect_status("late host callback invocation",
                       babet_context_run(context, late_host_chunk,
                                         sizeof(late_host_chunk) - 1,
                                         "embedding-late-host"),
                       BABET_STATUS_OK))
        return 1;

    if (!expect_status("search root after run",
                       babet_context_set_search_root(context, g_search_root),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;

    pthread_t thread;
    thread_probe probe = {context, g_search_root, BABET_STATUS_OK,
                          BABET_STATUS_OK, BABET_STATUS_OK,
                          BABET_STATUS_OK, BABET_STATUS_OK,
                          BABET_STATUS_OK, BABET_STATUS_OK};
    if (pthread_create(&thread, NULL, run_from_wrong_thread, &probe) != 0)
    {
        fprintf(stderr, "pthread_create failed\n");
        return 1;
    }
    if (pthread_join(thread, NULL) != 0)
    {
        fprintf(stderr, "pthread_join failed\n");
        return 1;
    }
    if (!expect_status("wrong-thread run", probe.run_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;
    if (!expect_status("wrong-thread search root", probe.search_root_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;
    if (!expect_status("wrong-thread set global", probe.set_global_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;
    if (!expect_status("wrong-thread get global", probe.get_global_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;
    if (!expect_status("wrong-thread call global", probe.call_global_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;
    if (!expect_status("wrong-thread register host", probe.register_host_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;
    if (!expect_status("wrong-thread destroy", probe.destroy_status,
                       BABET_STATUS_WRONG_THREAD))
        return 1;

    if (!expect_status("destroy", babet_context_destroy(context),
                       BABET_STATUS_OK))
        return 1;
    context = NULL;

    if (!expect_status("recreate", babet_context_create(&context),
                       BABET_STATUS_OK) || context == NULL)
        return 1;
    if (!expect_status("reconfigure search root",
                       babet_context_set_search_root(context, g_search_root),
                       BABET_STATUS_OK))
        return 1;
    static const char recreated_chunk[] =
        "assert(require('host_module').value == 'host-root-ok')";
    if (!expect_status("recreated root require",
                       babet_context_run(context, recreated_chunk,
                                         sizeof(recreated_chunk) - 1,
                                         "embedding-recreated-root"),
                       BABET_STATUS_OK))
        return 1;
    if (!expect_status("destroy recreated", babet_context_destroy(context),
                       BABET_STATUS_OK))
        return 1;
    context = NULL;

    if (!expect_status("create call-first context",
                       babet_context_create(&context), BABET_STATUS_OK) ||
        context == NULL)
        return 1;
    babet_value type_argument = {0};
    type_argument.type = BABET_VALUE_INTEGER;
    type_argument.as.integer = 7;
    if (!expect_status("call before search root",
                       babet_context_call_global(context, "type",
                                                 &type_argument, 1, &output),
                       BABET_STATUS_OK) ||
        output.type != BABET_VALUE_STRING || output.as.string.length != 6 ||
        memcmp(output.as.string.data, "number", 6) != 0)
    {
        fprintf(stderr, "call-first context result mismatch: %s\n",
                babet_context_last_error(context));
        return 1;
    }
    if (!expect_status("search root after call",
                       babet_context_set_search_root(context, g_search_root),
                       BABET_STATUS_INVALID_ARGUMENT))
        return 1;
    if (!expect_status("destroy call-first context",
                       babet_context_destroy(context), BABET_STATUS_OK))
        return 1;

    if (!babet_test_lifecycle())
        return 1;

    puts("embedding C API smoke: PASS");
    return 0;
}
