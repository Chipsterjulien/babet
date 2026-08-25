#include "babet/babet.h"

#include "lua_bindings/lua_utils.hpp"
#include "lua_bindings/main_thread.hpp"
#include "lua_bindings/workers.hpp"
#include "project_core/bundled_modules.hpp"
#include "project_core/runtime_registration.hpp"
#include "project_core/host_call_internal.hpp"
#include "version.hpp"

#include <lua.hpp>
#include <pthread.h>

#include <climits>
#include <cstring>
#include <exception>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <utility>
#include <vector>

struct babet_host_registration
{
    std::string name;
    babet_host_function function = nullptr;
    void *userdata = nullptr;
};

struct babet_context
{
    lua_State *lua = nullptr;
    pthread_t owner{};
    std::string last_error;
    std::string value_string_storage;
    std::string host_result_string_storage;
    std::string host_callback_error_storage;
    const char *fallback_error = nullptr;
    const char *host_callback_fallback_error = nullptr;
    std::vector<std::unique_ptr<babet_host_registration>> host_functions;
    std::vector<babet_value> host_arguments;
    babet_host_call *active_host_call = nullptr;
    bool host_callback_active = false;
    bool search_root_configured = false;
    bool execution_started = false;
};


namespace
{
static_assert(BABET_STATUS_OK == 0u &&
                  BABET_STATUS_INVALID_ARGUMENT == 1u &&
                  BABET_STATUS_BUSY == 2u &&
                  BABET_STATUS_WRONG_THREAD == 3u &&
                  BABET_STATUS_LUA_ERROR == 4u &&
                  BABET_STATUS_OUT_OF_MEMORY == 5u &&
                  BABET_STATUS_INTERNAL_ERROR == 6u &&
                  BABET_STATUS_UNSUPPORTED_VALUE == 7u &&
                  BABET_STATUS_REENTRANT_CALL == 8u,
              "changing a babet_status value changes the public ABI v1");
static_assert(BABET_VALUE_NIL == 0u && BABET_VALUE_BOOLEAN == 1u &&
                  BABET_VALUE_INTEGER == 2u && BABET_VALUE_NUMBER == 3u &&
                  BABET_VALUE_STRING == 4u,
              "changing a babet_value_type value changes the public ABI v1");

std::mutex g_context_mutex;
babet_context *g_active_context = nullptr;
char kEmbeddingContextRegistryKey;

bool on_owner_thread(const babet_context *context) noexcept
{
    return context &&
           ::pthread_equal(context->owner, ::pthread_self()) != 0;
}

bool inside_host_callback(const babet_context *context) noexcept
{
    return context && context->host_callback_active;
}

bool same_embedding_context(lua_State *state,
                            const babet_context *context) noexcept
{
    if (!context || !lua_checkstack(state, 1))
        return false;
    lua_rawgetp(state, LUA_REGISTRYINDEX, &kEmbeddingContextRegistryKey);
    const bool same = lua_touserdata(state, -1) == context;
    lua_pop(state, 1);
    return same;
}

void clear_error(babet_context *context) noexcept
{
    if (!context)
        return;
    context->last_error.clear();
    context->fallback_error = nullptr;
}

void begin_mutating_call(babet_context *context) noexcept
{
    if (!context)
        return;
    context->value_string_storage.clear();
    clear_error(context);
}

void set_fallback_error(babet_context *context, const char *message) noexcept
{
    if (!context)
        return;
    context->last_error.clear();
    context->fallback_error = message;
}

void set_error(babet_context *context, const std::string &message) noexcept
{
    if (!context)
        return;
    try
    {
        context->last_error = message;
        context->fallback_error = nullptr;
    }
    catch (...)
    {
        set_fallback_error(context, "babet: unable to store error diagnostic");
    }
}

void set_error(babet_context *context, const char *message) noexcept
{
    if (!context)
        return;
    try
    {
        context->last_error = message ? message : "";
        context->fallback_error = nullptr;
    }
    catch (...)
    {
        set_fallback_error(context, "babet: unable to store error diagnostic");
    }
}

babet_status status_from_lua(int status) noexcept
{
    return status == LUA_ERRMEM ? BABET_STATUS_OUT_OF_MEMORY
                                : BABET_STATUS_LUA_ERROR;
}

void capture_lua_error(babet_context *context, int status) noexcept
{
    if (!context || !context->lua)
        return;

    try
    {
        set_error(context, lua_value_to_display_string(context->lua, -1));
    }
    catch (const std::bad_alloc &)
    {
        set_fallback_error(context, "babet: out of memory while formatting Lua error");
    }
    catch (...)
    {
        set_fallback_error(context, "babet: unable to format Lua error");
    }

    if (lua_gettop(context->lua) > 0)
        lua_pop(context->lua, 1);

    if (status == LUA_ERRMEM && !context->fallback_error &&
        context->last_error.empty())
    {
        set_fallback_error(context, "babet: out of memory");
    }
}

bool search_root_path_is_invalid_argument(const std::error_code &error) noexcept
{
    return error == std::make_error_code(std::errc::no_such_file_or_directory) ||
           error == std::make_error_code(std::errc::not_a_directory);
}

struct SetGlobalOperation
{
    const char *name = nullptr;
    babet_value_type type = BABET_VALUE_NIL;
    int boolean_value = 0;
    int64_t integer_value = 0;
    double number_value = 0.0;
    const char *string_data = nullptr;
    size_t string_length = 0;
};

int set_global_thunk(lua_State *state) noexcept
{
    auto *operation = static_cast<SetGlobalOperation *>(
        lua_touserdata(state, 1));
    switch (operation->type)
    {
    case BABET_VALUE_NIL:
        lua_pushnil(state);
        break;
    case BABET_VALUE_BOOLEAN:
        lua_pushboolean(state, operation->boolean_value != 0);
        break;
    case BABET_VALUE_INTEGER:
        lua_pushinteger(state, static_cast<lua_Integer>(operation->integer_value));
        break;
    case BABET_VALUE_NUMBER:
        lua_pushnumber(state, static_cast<lua_Number>(operation->number_value));
        break;
    case BABET_VALUE_STRING:
        lua_pushlstring(state, operation->string_data, operation->string_length);
        break;
    }
    lua_setglobal(state, operation->name);
    return 0;
}

int get_global_thunk(lua_State *state) noexcept
{
    const char *name = static_cast<const char *>(lua_touserdata(state, 1));
    lua_getglobal(state, name);
    return 1;
}

bool valid_value_type(babet_value_type type) noexcept
{
    switch (type)
    {
    case BABET_VALUE_NIL:
    case BABET_VALUE_BOOLEAN:
    case BABET_VALUE_INTEGER:
    case BABET_VALUE_NUMBER:
    case BABET_VALUE_STRING:
        return true;
    }
    return false;
}

bool valid_status(babet_status status) noexcept
{
    switch (status)
    {
    case BABET_STATUS_OK:
    case BABET_STATUS_INVALID_ARGUMENT:
    case BABET_STATUS_BUSY:
    case BABET_STATUS_WRONG_THREAD:
    case BABET_STATUS_LUA_ERROR:
    case BABET_STATUS_OUT_OF_MEMORY:
    case BABET_STATUS_INTERNAL_ERROR:
    case BABET_STATUS_UNSUPPORTED_VALUE:
    case BABET_STATUS_REENTRANT_CALL:
        return true;
    }
    return false;
}

bool valid_host_name(const char *name) noexcept
{
    if (!name || name[0] == '\0')
        return false;

    const unsigned char first = static_cast<unsigned char>(name[0]);
    if (!((first >= 'A' && first <= 'Z') ||
          (first >= 'a' && first <= 'z') || first == '_'))
        return false;

    for (const unsigned char *cursor =
             reinterpret_cast<const unsigned char *>(name + 1);
         *cursor != 0; ++cursor)
    {
        if (!((*cursor >= 'A' && *cursor <= 'Z') ||
              (*cursor >= 'a' && *cursor <= 'z') ||
              (*cursor >= '0' && *cursor <= '9') || *cursor == '_'))
            return false;
    }

    // The public spelling is babet.host.<name>. Lua keywords satisfy the
    // lexical identifier pattern above but cannot appear after '.', so reject
    // them instead of publishing a function that contradicts the API syntax.
    static constexpr const char *lua_keywords[] = {
        "and", "break", "do", "else", "elseif", "end", "false",
        "for", "function", "goto", "if", "in", "local", "nil",
        "not", "or", "repeat", "return", "then", "true", "until",
        "while"};
    for (const char *keyword : lua_keywords)
    {
        if (std::strcmp(name, keyword) == 0)
            return false;
    }
    return true;
}

void clear_host_callback_storage(babet_context *context) noexcept
{
    context->host_result_string_storage.clear();
    context->host_callback_error_storage.clear();
    context->host_callback_fallback_error = nullptr;
}

void set_host_callback_error(babet_context *context,
                             const char *message) noexcept
{
    try
    {
        context->host_callback_error_storage = message ? message : "";
        context->host_callback_fallback_error = nullptr;
    }
    catch (...)
    {
        context->host_callback_error_storage.clear();
        context->host_callback_fallback_error =
            "babet: unable to store host callback diagnostic";
    }
}

const char *host_callback_error(const babet_context *context) noexcept
{
    if (context->host_callback_fallback_error)
        return context->host_callback_fallback_error;
    return context->host_callback_error_storage.c_str();
}

bool embedding_host_call_is_active(const babet_host_call *call) noexcept
{
    if (!call || !call->owner)
        return false;
    const auto *context = static_cast<const babet_context *>(call->owner);
    return context->host_callback_active && context->active_host_call == call;
}

babet_status embedding_host_call_copy_result(
    babet_host_call *call, const babet_value *value) noexcept
{
    auto *context = static_cast<babet_context *>(call->owner);
    try
    {
        babet_value result{};
        result.type = value->type;
        switch (value->type)
        {
        case BABET_VALUE_NIL:
            result.as.integer = 0;
            break;
        case BABET_VALUE_BOOLEAN:
            result.as.boolean = value->as.boolean ? 1 : 0;
            break;
        case BABET_VALUE_INTEGER:
            result.as.integer = value->as.integer;
            break;
        case BABET_VALUE_NUMBER:
            result.as.number = value->as.number;
            break;
        case BABET_VALUE_STRING:
        {
            const char *data = value->as.string.data ? value->as.string.data : "";
            context->host_result_string_storage.assign(data,
                                                       value->as.string.length);
            result.as.string.data = context->host_result_string_storage.data();
            result.as.string.length = context->host_result_string_storage.size();
            break;
        }
        }
        call->result = result;
        call->setter_status = BABET_STATUS_OK;
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        call->setter_status = BABET_STATUS_OUT_OF_MEMORY;
        set_host_callback_error(context,
                                "out of memory while copying host result");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (...)
    {
        call->setter_status = BABET_STATUS_INTERNAL_ERROR;
        set_host_callback_error(context,
                                "unable to copy host callback result");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

babet_status embedding_host_call_copy_error(
    babet_host_call *call, const char *message) noexcept
{
    auto *context = static_cast<babet_context *>(call->owner);
    try
    {
        context->host_callback_error_storage = message;
        context->host_callback_fallback_error = nullptr;
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        context->host_callback_error_storage.clear();
        context->host_callback_fallback_error =
            "babet: out of memory while storing host callback diagnostic";
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (...)
    {
        context->host_callback_error_storage.clear();
        context->host_callback_fallback_error =
            "babet: unable to store host callback diagnostic";
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

babet_status read_host_argument(lua_State *state, int index,
                                babet_value *out_value) noexcept
{
    switch (lua_type(state, index))
    {
    case LUA_TNIL:
        out_value->type = BABET_VALUE_NIL;
        out_value->as.integer = 0;
        return BABET_STATUS_OK;
    case LUA_TBOOLEAN:
        out_value->type = BABET_VALUE_BOOLEAN;
        out_value->as.boolean = lua_toboolean(state, index) ? 1 : 0;
        return BABET_STATUS_OK;
    case LUA_TNUMBER:
        if (lua_isinteger(state, index))
        {
            out_value->type = BABET_VALUE_INTEGER;
            out_value->as.integer =
                static_cast<int64_t>(lua_tointeger(state, index));
        }
        else
        {
            out_value->type = BABET_VALUE_NUMBER;
            out_value->as.number = static_cast<double>(lua_tonumber(state, index));
        }
        return BABET_STATUS_OK;
    case LUA_TSTRING:
    {
        size_t length = 0;
        const char *data = lua_tolstring(state, index, &length);
        out_value->type = BABET_VALUE_STRING;
        out_value->as.string.data = data;
        out_value->as.string.length = length;
        return BABET_STATUS_OK;
    }
    default:
        return BABET_STATUS_UNSUPPORTED_VALUE;
    }
}

void push_host_result(lua_State *state, const babet_value &value)
{
    switch (value.type)
    {
    case BABET_VALUE_NIL:
        lua_pushnil(state);
        break;
    case BABET_VALUE_BOOLEAN:
        lua_pushboolean(state, value.as.boolean != 0);
        break;
    case BABET_VALUE_INTEGER:
        lua_pushinteger(state, static_cast<lua_Integer>(value.as.integer));
        break;
    case BABET_VALUE_NUMBER:
        lua_pushnumber(state, static_cast<lua_Number>(value.as.number));
        break;
    case BABET_VALUE_STRING:
        lua_pushlstring(state, value.as.string.data, value.as.string.length);
        break;
    }
}

int host_function_thunk(lua_State *state) noexcept
{
    auto *registration = static_cast<babet_host_registration *>(
        lua_touserdata(state, lua_upvalueindex(1)));
    auto *context = static_cast<babet_context *>(
        lua_touserdata(state, lua_upvalueindex(2)));
    if (!registration || !registration->function || !context)
        return luaL_error(state, "babet embedding: invalid host function closure");
    if (!same_embedding_context(state, context))
        return luaL_error(state,
                          "babet embedding: host function belongs to another Lua runtime");

    const int argument_count = lua_gettop(state);
    const char *argument_setup_error = nullptr;
    try
    {
        context->host_arguments.resize(static_cast<size_t>(argument_count));
    }
    catch (const std::bad_alloc &)
    {
        argument_setup_error =
            "babet embedding: out of memory preparing host arguments";
    }
    catch (...)
    {
        argument_setup_error =
            "babet embedding: unable to prepare host arguments";
    }
    if (argument_setup_error)
        return luaL_error(state, "%s", argument_setup_error);

    for (int i = 0; i < argument_count; ++i)
    {
        babet_value *argument = &context->host_arguments[static_cast<size_t>(i)];
        const babet_status status = read_host_argument(state, i + 1, argument);
        if (status != BABET_STATUS_OK)
        {
            const char *type_name = luaL_typename(state, i + 1);
            return luaL_error(
                state,
                "babet embedding: host function '%s' argument #%d has unsupported type %s",
                registration->name.c_str(), i + 1,
                type_name ? type_name : "unknown");
        }
    }

    clear_host_callback_storage(context);
    babet_host_call call{};
    call.arguments = context->host_arguments.data();
    call.argument_count = static_cast<size_t>(argument_count);
    call.result.type = BABET_VALUE_NIL;
    call.result.as.integer = 0;
    call.owner = context;
    call.is_active = embedding_host_call_is_active;
    call.copy_result = embedding_host_call_copy_result;
    call.copy_error = embedding_host_call_copy_error;

    context->active_host_call = &call;
    context->host_callback_active = true;

    babet_status callback_status = BABET_STATUS_INTERNAL_ERROR;
    try
    {
        callback_status = registration->function(&call, registration->userdata);
    }
    catch (const std::bad_alloc &)
    {
        callback_status = BABET_STATUS_OUT_OF_MEMORY;
        set_host_callback_error(context,
                                "C++ host callback threw std::bad_alloc");
    }
    catch (const std::exception &error)
    {
        callback_status = BABET_STATUS_INTERNAL_ERROR;
        set_host_callback_error(context, error.what());
    }
    catch (...)
    {
        callback_status = BABET_STATUS_INTERNAL_ERROR;
        set_host_callback_error(context,
                                "C++ host callback threw an unknown exception");
    }

    context->host_callback_active = false;
    context->active_host_call = nullptr;

    if (!valid_status(callback_status))
    {
        callback_status = BABET_STATUS_INTERNAL_ERROR;
        set_host_callback_error(context,
                                "host callback returned an unknown babet_status");
    }
    if (callback_status == BABET_STATUS_OK &&
        call.setter_status != BABET_STATUS_OK)
        callback_status = call.setter_status;

    if (callback_status != BABET_STATUS_OK)
    {
        const char *detail = host_callback_error(context);
        if (detail && detail[0] != '\0')
            return luaL_error(state,
                              "babet embedding: host function '%s' failed (%s): %s",
                              registration->name.c_str(),
                              babet_status_name(callback_status), detail);
        return luaL_error(state,
                          "babet embedding: host function '%s' failed (%s)",
                          registration->name.c_str(),
                          babet_status_name(callback_status));
    }

    push_host_result(state, call.result);
    return 1;
}

struct InstallHostFunctionOperation
{
    babet_context *context = nullptr;
    babet_host_registration *registration = nullptr;
};

int install_host_function_thunk(lua_State *state) noexcept
{
    auto *operation = static_cast<InstallHostFunctionOperation *>(
        lua_touserdata(state, 1));
    if (!operation || !operation->context || !operation->registration)
        return luaL_error(state, "babet embedding: invalid host registration operation");

    babet_host_registration *registration = operation->registration;

    // Use raw table operations deliberately. A user may install __index or
    // __newindex metamethods on _G, babet, or babet.host between registrations.
    // Those hooks must never observe a half-installed closure or make a failed
    // registration retain a dangling registration pointer.
    lua_pushglobaltable(state); // globals
    lua_pushliteral(state, "babet");
    lua_rawget(state, -2); // globals, babet
    if (!lua_istable(state, -1))
        return luaL_error(state, "babet embedding: global 'babet' is not a table");

    lua_pushliteral(state, "host");
    lua_rawget(state, -2); // globals, babet, host|nil
    if (lua_isnil(state, -1))
    {
        lua_pop(state, 1);
        lua_newtable(state); // globals, babet, host
        lua_pushliteral(state, "host");
        lua_pushvalue(state, -2);
        lua_rawset(state, -4); // babet.host = host, raw
    }
    else if (!lua_istable(state, -1))
    {
        return luaL_error(state, "babet embedding: babet.host is not a table");
    }

    lua_pushlstring(state, registration->name.data(), registration->name.size());
    lua_rawget(state, -2);
    if (!lua_isnil(state, -1))
        return luaL_error(state,
                          "babet embedding: babet.host.%s already exists",
                          registration->name.c_str());
    lua_pop(state, 1);

    lua_pushlstring(state, registration->name.data(), registration->name.size());
    lua_pushlightuserdata(state, registration);
    lua_pushlightuserdata(state, operation->context);
    lua_pushcclosure(state, host_function_thunk, 2);
    lua_rawset(state, -3); // host[name] = closure, raw

    lua_pop(state, 3); // host, babet, globals
    return 0;
}

struct OwnedCallArgument
{
    babet_value_type type = BABET_VALUE_NIL;
    int boolean_value = 0;
    int64_t integer_value = 0;
    double number_value = 0.0;
    std::string string_value;
};

struct CallGlobalOperation
{
    const char *function_name = nullptr;
    const std::vector<OwnedCallArgument> *arguments = nullptr;
};

void push_owned_scalar(lua_State *state, const OwnedCallArgument &argument)
{
    switch (argument.type)
    {
    case BABET_VALUE_NIL:
        lua_pushnil(state);
        break;
    case BABET_VALUE_BOOLEAN:
        lua_pushboolean(state, argument.boolean_value != 0);
        break;
    case BABET_VALUE_INTEGER:
        lua_pushinteger(state, static_cast<lua_Integer>(argument.integer_value));
        break;
    case BABET_VALUE_NUMBER:
        lua_pushnumber(state, static_cast<lua_Number>(argument.number_value));
        break;
    case BABET_VALUE_STRING:
        lua_pushlstring(state, argument.string_value.data(),
                        argument.string_value.size());
        break;
    }
}

int call_global_thunk(lua_State *state) noexcept
{
    auto *operation = static_cast<CallGlobalOperation *>(
        lua_touserdata(state, 1));
    lua_getglobal(state, operation->function_name);
    if (!lua_isfunction(state, -1))
        return luaL_error(state, "babet embedding: global '%s' is not a function",
                          operation->function_name);

    for (const OwnedCallArgument &argument : *operation->arguments)
        push_owned_scalar(state, argument);

    lua_call(state, static_cast<int>(operation->arguments->size()), 1);
    return 1;
}

babet_status read_scalar_result(babet_context *context, lua_State *state,
                                int index, babet_value *out_value)
{
    const int type = lua_type(state, index);
    switch (type)
    {
    case LUA_TNIL:
        out_value->type = BABET_VALUE_NIL;
        break;
    case LUA_TBOOLEAN:
        out_value->type = BABET_VALUE_BOOLEAN;
        out_value->as.boolean = lua_toboolean(state, index) ? 1 : 0;
        break;
    case LUA_TNUMBER:
        if (lua_isinteger(state, index))
        {
            out_value->type = BABET_VALUE_INTEGER;
            out_value->as.integer =
                static_cast<int64_t>(lua_tointeger(state, index));
        }
        else
        {
            out_value->type = BABET_VALUE_NUMBER;
            out_value->as.number = static_cast<double>(lua_tonumber(state, index));
        }
        break;
    case LUA_TSTRING:
    {
        size_t length = 0;
        const char *data = lua_tolstring(state, index, &length);
        context->value_string_storage.assign(data, length);
        out_value->type = BABET_VALUE_STRING;
        out_value->as.string.data = context->value_string_storage.data();
        out_value->as.string.length = context->value_string_storage.size();
        break;
    }
    default:
    {
        const char *type_name = lua_typename(state, type);
        set_error(context,
                  std::string("babet embedding: unsupported Lua value type: ") +
                      (type_name ? type_name : "unknown"));
        return BABET_STATUS_UNSUPPORTED_VALUE;
    }
    }
    return BABET_STATUS_OK;
}
} // namespace

extern "C" const char *babet_version(void)
{
    return BABET_VERSION_STRING;
}

extern "C" const char *babet_status_name(babet_status status)
{
    switch (status)
    {
    case BABET_STATUS_OK:
        return "ok";
    case BABET_STATUS_INVALID_ARGUMENT:
        return "invalid_argument";
    case BABET_STATUS_BUSY:
        return "busy";
    case BABET_STATUS_WRONG_THREAD:
        return "wrong_thread";
    case BABET_STATUS_LUA_ERROR:
        return "lua_error";
    case BABET_STATUS_OUT_OF_MEMORY:
        return "out_of_memory";
    case BABET_STATUS_INTERNAL_ERROR:
        return "internal_error";
    case BABET_STATUS_UNSUPPORTED_VALUE:
        return "unsupported_value";
    case BABET_STATUS_REENTRANT_CALL:
        return "reentrant_call";
    }
    return "unknown";
}

extern "C" babet_status babet_context_create(babet_context **out_context)
{
    if (!out_context)
        return BABET_STATUS_INVALID_ARGUMENT;
    *out_context = nullptr;

    babet_context *context = nullptr;
    try
    {
        std::lock_guard<std::mutex> lock(g_context_mutex);
        if (g_active_context)
            return BABET_STATUS_BUSY;

        context = new (std::nothrow) babet_context;
        if (!context)
            return BABET_STATUS_OUT_OF_MEMORY;

        context->owner = ::pthread_self();
        babet_runtime::register_main_thread();

        context->lua = luaL_newstate();
        if (!context->lua)
        {
            delete context;
            return BABET_STATUS_OUT_OF_MEMORY;
        }

        auto setup_runtime = [context](lua_State *state)
        {
            luaL_openlibs(state);
            register_bundled_modules(state);
            register_babet(state, nullptr, NativePluginMode::embedding);

            // The registry is shared by every coroutine of this Lua global
            // state. Host-function thunks validate against this marker instead
            // of requiring the current lua_State* to be the main thread.
            lua_pushlightuserdata(state, context);
            lua_rawsetp(state, LUA_REGISTRYINDEX, &kEmbeddingContextRegistryKey);
        };
        std::string setup_error;
        if (!lua_run_setup_protected(
                context->lua, setup_runtime,
                "babet embedding: Lua initialization failed", setup_error))
        {
            close_babet_lua_state(context->lua);
            context->lua = nullptr;
            delete context;
            return setup_error.find("out of memory") != std::string::npos
                       ? BABET_STATUS_OUT_OF_MEMORY
                       : BABET_STATUS_INTERNAL_ERROR;
        }

        // Embedding starts without an on-disk module root. The host may add
        // exactly one explicit root before its first run; until then workers
        // get only stdlib, babet.* and bundled package.preload modules.
        set_workers_init_context("", "", false);

        g_active_context = context;
        *out_context = context;
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        if (context)
        {
            close_babet_lua_state(context->lua);
            context->lua = nullptr;
            delete context;
        }
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (...)
    {
        if (context)
        {
            close_babet_lua_state(context->lua);
            context->lua = nullptr;
            delete context;
        }
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" babet_status babet_context_set_search_root(
    babet_context *context, const char *search_root)
{
    if (!context || !search_root || search_root[0] == '\0')
        return BABET_STATUS_INVALID_ARGUMENT;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;

    begin_mutating_call(context);
    if (context->execution_started)
    {
        set_error(context,
                  "babet embedding: search root must be configured before the first run");
        return BABET_STATUS_INVALID_ARGUMENT;
    }
    if (context->search_root_configured)
    {
        set_error(context,
                  "babet embedding: search root is already configured");
        return BABET_STATUS_INVALID_ARGUMENT;
    }

    try
    {
        namespace fs = std::filesystem;
        std::error_code error;
        fs::path root_path(search_root);
        fs::path absolute_root = fs::absolute(root_path, error);
        if (error)
        {
            if (search_root_path_is_invalid_argument(error))
            {
                set_error(context,
                          "babet embedding: search root is not a directory");
                return BABET_STATUS_INVALID_ARGUMENT;
            }
            set_error(context,
                      "babet embedding: unable to resolve search root: " +
                          error.message());
            return BABET_STATUS_INTERNAL_ERROR;
        }
        absolute_root = absolute_root.lexically_normal();

        if (!fs::is_directory(absolute_root, error))
        {
            if (!error || search_root_path_is_invalid_argument(error))
            {
                set_error(context,
                          "babet embedding: search root is not a directory");
                return BABET_STATUS_INVALID_ARGUMENT;
            }
            set_error(context,
                      "babet embedding: unable to inspect search root: " +
                          error.message());
            return BABET_STATUS_INTERNAL_ERROR;
        }

        const std::string root_string = absolute_root.string();
        if (root_string.find(';') != std::string::npos ||
            root_string.find('?') != std::string::npos)
        {
            set_error(context,
                      "babet embedding: search root cannot contain ';' or '?' with package.path semantics");
            return BABET_STATUS_INVALID_ARGUMENT;
        }

        const std::string package_prefix =
            (absolute_root / "?.lua").string() + ";" +
            (absolute_root / "?" / "init.lua").string() + ";";

        // Pre-copy the worker root before entering the protected Lua setup so
        // later publication cannot fail halfway through the global init state.
        std::string worker_root = root_string;

        auto setup_search_root = [&](lua_State *state)
        {
            prepend_babet_package_path(state, package_prefix);
        };
        std::string setup_error;
        if (!lua_run_setup_protected(
                context->lua, setup_search_root,
                "babet embedding: search-root setup failed", setup_error))
        {
            set_error(context, setup_error);
            return setup_error.find("out of memory") != std::string::npos
                       ? BABET_STATUS_OUT_OF_MEMORY
                       : BABET_STATUS_INTERNAL_ERROR;
        }

        set_workers_init_context(std::move(worker_root), std::string{}, false);
        context->search_root_configured = true;
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        set_error(context, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        set_fallback_error(context,
                           "babet: unknown embedding search-root failure");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" babet_status babet_context_run(babet_context *context,
                                             const char *chunk,
                                             size_t chunk_length,
                                             const char *chunk_name)
{
    if (!context || (!chunk && chunk_length != 0))
        return BABET_STATUS_INVALID_ARGUMENT;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;

    context->execution_started = true;
    begin_mutating_call(context);
    const char *name = chunk_name ? chunk_name : "=(babet-embed)";
    const char *data = chunk ? chunk : "";

    try
    {
        const int initial_top = lua_gettop(context->lua);
        int status = luaL_loadbufferx(context->lua, data, chunk_length, name, "t");
        if (status == LUA_OK)
            status = lua_pcall(context->lua, 0, LUA_MULTRET, 0);

        if (status != LUA_OK)
        {
            capture_lua_error(context, status);
            lua_settop(context->lua, initial_top);
            return status_from_lua(status);
        }

        // The initial API deliberately has no value marshalling surface.  Keep
        // repeated host calls stack-neutral while that design remains open.
        lua_settop(context->lua, initial_top);
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        try
        {
            set_error(context, error.what());
        }
        catch (...)
        {
            set_fallback_error(context, "babet: internal embedding failure");
        }
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        set_fallback_error(context, "babet: unknown embedding failure");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" babet_status babet_context_set_global(
    babet_context *context, const char *name, const babet_value *value)
{
    if (!context || !name || name[0] == '\0' || !value ||
        !valid_value_type(value->type))
        return BABET_STATUS_INVALID_ARGUMENT;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;
    if (value->type == BABET_VALUE_STRING &&
        !value->as.string.data && value->as.string.length != 0)
        return BABET_STATUS_INVALID_ARGUMENT;

    static_assert(sizeof(lua_Integer) >= sizeof(int64_t),
                  "Babet embedding requires a Lua integer wide enough for int64_t");
    static_assert(sizeof(lua_Number) >= sizeof(double),
                  "Babet embedding requires a Lua number wide enough for double");

    try
    {
        // Copy string inputs before invalidating the previous borrowed output
        // pointer so a host may safely feed a prior get_global() string back
        // into this same context.
        std::string owned_name(name);
        std::string owned_string;
        if (value->type == BABET_VALUE_STRING)
        {
            const char *data = value->as.string.data
                                   ? value->as.string.data
                                   : "";
            owned_string.assign(data, value->as.string.length);
        }

        begin_mutating_call(context);
        const int initial_top = lua_gettop(context->lua);
        if (!lua_checkstack(context->lua, 2))
        {
            set_fallback_error(context, "babet: out of memory");
            return BABET_STATUS_OUT_OF_MEMORY;
        }

        SetGlobalOperation operation;
        operation.name = owned_name.c_str();
        operation.type = value->type;
        switch (value->type)
        {
        case BABET_VALUE_NIL:
            break;
        case BABET_VALUE_BOOLEAN:
            operation.boolean_value = value->as.boolean;
            break;
        case BABET_VALUE_INTEGER:
            operation.integer_value = value->as.integer;
            break;
        case BABET_VALUE_NUMBER:
            operation.number_value = value->as.number;
            break;
        case BABET_VALUE_STRING:
            operation.string_data = owned_string.data();
            operation.string_length = owned_string.size();
            break;
        }

        lua_pushcfunction(context->lua, set_global_thunk);
        lua_pushlightuserdata(context->lua, &operation);
        const int status = lua_pcall(context->lua, 1, 0, 0);
        if (status != LUA_OK)
        {
            capture_lua_error(context, status);
            lua_settop(context->lua, initial_top);
            return status_from_lua(status);
        }

        lua_settop(context->lua, initial_top);
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        begin_mutating_call(context);
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        begin_mutating_call(context);
        set_error(context, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        begin_mutating_call(context);
        set_fallback_error(context, "babet: unknown embedding value failure");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" babet_status babet_context_get_global(
    babet_context *context, const char *name, babet_value *out_value)
{
    if (!context || !name || name[0] == '\0' || !out_value)
        return BABET_STATUS_INVALID_ARGUMENT;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;

    out_value->type = BABET_VALUE_NIL;
    out_value->as.integer = 0;

    std::string owned_name;
    try
    {
        owned_name.assign(name);
    }
    catch (const std::bad_alloc &)
    {
        begin_mutating_call(context);
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (...)
    {
        begin_mutating_call(context);
        set_fallback_error(context, "babet: unable to copy global name");
        return BABET_STATUS_INTERNAL_ERROR;
    }

    begin_mutating_call(context);
    const int initial_top = lua_gettop(context->lua);

    try
    {
        if (!lua_checkstack(context->lua, 2))
        {
            set_fallback_error(context, "babet: out of memory");
            return BABET_STATUS_OUT_OF_MEMORY;
        }
        lua_pushcfunction(context->lua, get_global_thunk);
        lua_pushlightuserdata(
            context->lua, const_cast<char *>(owned_name.c_str()));
        const int status = lua_pcall(context->lua, 1, 1, 0);
        if (status != LUA_OK)
        {
            capture_lua_error(context, status);
            lua_settop(context->lua, initial_top);
            return status_from_lua(status);
        }

        const babet_status result_status =
            read_scalar_result(context, context->lua, -1, out_value);
        lua_settop(context->lua, initial_top);
        return result_status;
    }
    catch (const std::bad_alloc &)
    {
        lua_settop(context->lua, initial_top);
        begin_mutating_call(context);
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        lua_settop(context->lua, initial_top);
        begin_mutating_call(context);
        set_error(context, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        lua_settop(context->lua, initial_top);
        begin_mutating_call(context);
        set_fallback_error(context, "babet: unknown embedding value failure");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" babet_status babet_context_call_global(
    babet_context *context, const char *function_name,
    const babet_value *arguments, size_t argument_count,
    babet_value *out_result)
{
    if (!context || !function_name || function_name[0] == '\0' || !out_result ||
        (!arguments && argument_count != 0) ||
        argument_count > static_cast<size_t>(INT_MAX - 2))
        return BABET_STATUS_INVALID_ARGUMENT;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;

    static_assert(sizeof(lua_Integer) >= sizeof(int64_t),
                  "Babet embedding requires a Lua integer wide enough for int64_t");
    static_assert(sizeof(lua_Number) >= sizeof(double),
                  "Babet embedding requires a Lua number wide enough for double");

    int initial_top = 0;
    bool lua_call_started = false;
    try
    {
        std::string owned_name(function_name);
        std::vector<OwnedCallArgument> owned_arguments;
        owned_arguments.reserve(argument_count);
        for (size_t i = 0; i < argument_count; ++i)
        {
            const babet_value &input = arguments[i];
            if (!valid_value_type(input.type) ||
                (input.type == BABET_VALUE_STRING && !input.as.string.data &&
                 input.as.string.length != 0))
                return BABET_STATUS_INVALID_ARGUMENT;

            OwnedCallArgument argument;
            argument.type = input.type;
            switch (input.type)
            {
            case BABET_VALUE_NIL:
                break;
            case BABET_VALUE_BOOLEAN:
                argument.boolean_value = input.as.boolean;
                break;
            case BABET_VALUE_INTEGER:
                argument.integer_value = input.as.integer;
                break;
            case BABET_VALUE_NUMBER:
                argument.number_value = input.as.number;
                break;
            case BABET_VALUE_STRING:
            {
                const char *data = input.as.string.data ? input.as.string.data : "";
                argument.string_value.assign(data, input.as.string.length);
                break;
            }
            }
            owned_arguments.push_back(std::move(argument));
        }

        out_result->type = BABET_VALUE_NIL;
        out_result->as.integer = 0;
        begin_mutating_call(context);
        initial_top = lua_gettop(context->lua);
        lua_call_started = true;
        if (!lua_checkstack(context->lua,
                            static_cast<int>(argument_count) + 2))
        {
            set_fallback_error(context, "babet: out of memory");
            return BABET_STATUS_OUT_OF_MEMORY;
        }

        CallGlobalOperation operation;
        operation.function_name = owned_name.c_str();
        operation.arguments = &owned_arguments;
        lua_pushcfunction(context->lua, call_global_thunk);
        lua_pushlightuserdata(context->lua, &operation);
        context->execution_started = true;
        const int status = lua_pcall(context->lua, 1, 1, 0);
        if (status != LUA_OK)
        {
            capture_lua_error(context, status);
            lua_settop(context->lua, initial_top);
            return status_from_lua(status);
        }

        const babet_status result_status =
            read_scalar_result(context, context->lua, -1, out_result);
        lua_settop(context->lua, initial_top);
        return result_status;
    }
    catch (const std::bad_alloc &)
    {
        if (lua_call_started)
            lua_settop(context->lua, initial_top);
        begin_mutating_call(context);
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        if (lua_call_started)
            lua_settop(context->lua, initial_top);
        begin_mutating_call(context);
        set_error(context, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        if (lua_call_started)
            lua_settop(context->lua, initial_top);
        begin_mutating_call(context);
        set_fallback_error(context, "babet: unknown embedding call failure");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" babet_status babet_context_register_host_function(
    babet_context *context, const char *name,
    babet_host_function function, void *userdata)
{
    if (!context || !valid_host_name(name) || !function)
        return BABET_STATUS_INVALID_ARGUMENT;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;

    try
    {
        begin_mutating_call(context);
        for (const auto &registered : context->host_functions)
        {
            if (registered && registered->name == name)
            {
                set_error(context,
                          "babet embedding: host function name is already registered");
                return BABET_STATUS_INVALID_ARGUMENT;
            }
        }

        // Reserve before Lua sees the registration pointer. The installation
        // thunk uses raw table operations, so on failure no metamethod can have
        // captured the closure. After a successful pcall, the final unique_ptr
        // move is allocation-free and cannot invalidate the closure pointer.
        context->host_functions.reserve(context->host_functions.size() + 1);

        auto registration = std::make_unique<babet_host_registration>();
        registration->name = name;
        registration->function = function;
        registration->userdata = userdata;
        babet_host_registration *registration_ptr = registration.get();

        const int initial_top = lua_gettop(context->lua);
        if (!lua_checkstack(context->lua, 3))
        {
            set_fallback_error(context, "babet: out of memory");
            return BABET_STATUS_OUT_OF_MEMORY;
        }

        InstallHostFunctionOperation operation;
        operation.context = context;
        operation.registration = registration_ptr;
        lua_pushcfunction(context->lua, install_host_function_thunk);
        lua_pushlightuserdata(context->lua, &operation);
        const int status = lua_pcall(context->lua, 1, 0, 0);
        if (status != LUA_OK)
        {
            capture_lua_error(context, status);
            lua_settop(context->lua, initial_top);
            return status_from_lua(status);
        }

        context->host_functions.push_back(std::move(registration));
        lua_settop(context->lua, initial_top);
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        begin_mutating_call(context);
        set_fallback_error(context, "babet: out of memory");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (const std::exception &error)
    {
        begin_mutating_call(context);
        set_error(context, error.what());
        return BABET_STATUS_INTERNAL_ERROR;
    }
    catch (...)
    {
        begin_mutating_call(context);
        set_fallback_error(context,
                           "babet: unknown host-function registration failure");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

extern "C" const char *babet_context_last_error(const babet_context *context)
{
    if (!context)
        return "";
    if (context->fallback_error)
        return context->fallback_error;
    return context->last_error.c_str();
}

extern "C" babet_status babet_context_destroy(babet_context *context)
{
    if (!context)
        return BABET_STATUS_OK;
    if (!on_owner_thread(context))
        return BABET_STATUS_WRONG_THREAD;
    if (inside_host_callback(context))
        return BABET_STATUS_REENTRANT_CALL;

    try
    {
        {
            std::lock_guard<std::mutex> lock(g_context_mutex);
            if (g_active_context != context)
                return BABET_STATUS_INVALID_ARGUMENT;
            g_active_context = nullptr;
        }

        close_babet_lua_state(context->lua);
        context->lua = nullptr;
        delete context;
        return BABET_STATUS_OK;
    }
    catch (...)
    {
        // close_babet_lua_state is noexcept; this is a final C-ABI safety net
        // for mutex/runtime implementation changes.
        return BABET_STATUS_INTERNAL_ERROR;
    }
}
