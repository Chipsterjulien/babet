#include "native_plugin.hpp"

#include "babet/plugin.h"
#include "lua_utils.hpp"
#include "project_core/host_call_internal.hpp"

#include <lua.hpp>

#include <dlfcn.h>

#include <cctype>
#include <cstddef>
#include <cstring>
#include <exception>
#include <filesystem>
#include <memory>
#include <new>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

struct NativePluginFunctionRegistration
{
    std::string name;
    babet_plugin_callback_v1 function = nullptr;
    void *userdata = nullptr;
    NativePluginRuntime *runtime = nullptr;
};

int native_plugin_function_thunk(lua_State *state) noexcept;

namespace
{
template <int (*Fn)(lua_State *)>
int native_plugin_boundary(lua_State *state)
{
    return lua_cfunction_exception_boundary<Fn>(
        state, "babet plugin: out of memory",
        "babet plugin: internal failure",
        "babet plugin: unknown internal failure");
}

constexpr std::size_t kMaxPluginNameLength = 128;
constexpr std::size_t kMaxPluginVersionLength = 128;
constexpr std::size_t kMaxFunctionNameLength = 128;
char kNativePluginRuntimeRegistryKey;

class DlHandleGuard
{
public:
    explicit DlHandleGuard(void *handle) noexcept : handle_(handle) {}
    ~DlHandleGuard()
    {
        if (handle_)
            ::dlclose(handle_);
    }

    DlHandleGuard(const DlHandleGuard &) = delete;
    DlHandleGuard &operator=(const DlHandleGuard &) = delete;

    void *get() const noexcept { return handle_; }
    void release() noexcept { handle_ = nullptr; }

private:
    void *handle_ = nullptr;
};

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

bool valid_function_name(std::string_view name) noexcept
{
    if (name.empty() || name.size() > kMaxFunctionNameLength)
        return false;

    const unsigned char first = static_cast<unsigned char>(name.front());
    if (!((first >= 'A' && first <= 'Z') ||
          (first >= 'a' && first <= 'z') || first == '_'))
        return false;

    for (std::size_t i = 1; i < name.size(); ++i)
    {
        const unsigned char ch = static_cast<unsigned char>(name[i]);
        if (!((ch >= 'A' && ch <= 'Z') ||
              (ch >= 'a' && ch <= 'z') ||
              (ch >= '0' && ch <= '9') || ch == '_'))
            return false;
    }

    static constexpr std::string_view lua_keywords[] = {
        "and", "break", "do", "else", "elseif", "end", "false",
        "for", "function", "goto", "if", "in", "local", "nil",
        "not", "or", "repeat", "return", "then", "true", "until",
        "while"};
    for (const std::string_view keyword : lua_keywords)
    {
        if (name == keyword)
            return false;
    }
    return true;
}

bool copy_bounded_view(const babet_string_view &source, std::size_t maximum,
                       std::string &destination)
{
    if ((!source.data && source.length != 0) || source.length == 0 ||
        source.length > maximum)
        return false;
    if (std::memchr(source.data, '\0', source.length) != nullptr)
        return false;
    destination.assign(source.data, source.length);
    return true;
}

bool same_native_plugin_runtime(lua_State *state,
                                const NativePluginRuntime *runtime) noexcept
{
    if (!runtime || !lua_checkstack(state, 1))
        return false;
    lua_rawgetp(state, LUA_REGISTRYINDEX, &kNativePluginRuntimeRegistryKey);
    const bool same = lua_touserdata(state, -1) == runtime;
    lua_pop(state, 1);
    return same;
}

babet_status read_plugin_argument(lua_State *state, int index,
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
        std::size_t length = 0;
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

void push_plugin_result(lua_State *state, const babet_value &value)
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

void clear_callback_storage(NativePluginRuntime *runtime) noexcept
{
    runtime->result_string_storage_.clear();
    runtime->callback_error_storage_.clear();
    runtime->callback_fallback_error_ = nullptr;
}

void set_callback_error(NativePluginRuntime *runtime,
                        const char *message) noexcept
{
    try
    {
        runtime->callback_error_storage_ = message ? message : "";
        runtime->callback_fallback_error_ = nullptr;
    }
    catch (...)
    {
        runtime->callback_error_storage_.clear();
        runtime->callback_fallback_error_ =
            "babet plugin: unable to store callback diagnostic";
    }
}

const char *callback_error(const NativePluginRuntime *runtime) noexcept
{
    if (runtime->callback_fallback_error_)
        return runtime->callback_fallback_error_;
    return runtime->callback_error_storage_.c_str();
}

struct PreparedPlugin
{
    std::string canonical_path;
    std::string name;
    std::string version;
    std::vector<std::unique_ptr<NativePluginFunctionRegistration>> functions;
};

struct PluginResultBuilder
{
    PreparedPlugin *plugin = nullptr;

    int operator()(lua_State *state) const
    {
        lua_newtable(state);

        lua_pushlstring(state, plugin->name.data(), plugin->name.size());
        lua_setfield(state, -2, "name");
        lua_pushlstring(state, plugin->version.data(), plugin->version.size());
        lua_setfield(state, -2, "version");
        lua_pushinteger(state, BABET_PLUGIN_ABI_VERSION_V1);
        lua_setfield(state, -2, "abi");
        lua_pushlstring(state, plugin->canonical_path.data(),
                        plugin->canonical_path.size());
        lua_setfield(state, -2, "path");

        lua_newtable(state);
        for (const auto &registration : plugin->functions)
        {
            lua_pushlightuserdata(state, registration.get());
            lua_pushcclosure(state, native_plugin_function_thunk, 1);
            lua_setfield(state, -2, registration->name.c_str());
        }
        lua_setfield(state, -2, "functions");

        lua_pushnil(state);
        return 2;
    }
};

std::string dl_error_message(const char *prefix)
{
    const char *detail = ::dlerror();
    std::string message(prefix);
    if (detail && detail[0] != '\0')
    {
        message += ": ";
        message += detail;
    }
    return message;
}

bool path_already_loaded(const NativePluginRuntime *runtime,
                         const std::string &canonical_path)
{
    for (const std::string &loaded : runtime->loaded_paths_)
    {
        if (loaded == canonical_path)
            return true;
    }
    return false;
}

bool same_file_already_loaded(const NativePluginRuntime *runtime,
                              const std::filesystem::path &canonical_path)
{
    std::error_code error;
    for (const std::string &loaded : runtime->loaded_paths_)
    {
        if (std::filesystem::equivalent(canonical_path, loaded, error))
            return true;
        error.clear();
    }
    return false;
}

bool handle_already_loaded(const NativePluginRuntime *runtime,
                           void *handle) noexcept
{
    for (void *loaded : runtime->loaded_handles_)
    {
        if (loaded == handle)
            return true;
    }
    return false;
}

bool valid_shared_object_filename(const std::filesystem::path &path)
{
    const std::string filename = path.filename().string();
    const std::size_t marker = filename.rfind(".so");
    if (marker == std::string::npos)
        return false;

    const std::size_t suffix = marker + 3;
    if (suffix == filename.size())
        return true;
    if (filename[suffix] != '.' || suffix + 1 >= filename.size())
        return false;

    bool expecting_digit = true;
    for (std::size_t i = suffix + 1; i < filename.size(); ++i)
    {
        const unsigned char ch = static_cast<unsigned char>(filename[i]);
        if (std::isdigit(ch))
        {
            expecting_digit = false;
            continue;
        }
        if (filename[i] == '.' && !expecting_digit)
        {
            expecting_digit = true;
            continue;
        }
        return false;
    }
    return !expecting_digit;
}

std::string prepare_plugin(NativePluginRuntime *runtime,
                           std::string_view requested_path,
                           PreparedPlugin &prepared,
                           void **out_handle)
{
    namespace fs = std::filesystem;
    *out_handle = nullptr;

    if (requested_path.empty() ||
        requested_path.find('\0') != std::string_view::npos)
        return "babet.plugin.load: path must be a non-empty text path";

    std::error_code error;
    const fs::path requested_fs_path(requested_path);
    if (!valid_shared_object_filename(requested_fs_path))
        return "babet.plugin.load: native plugin path must end in .so or .so.<version>";

    const fs::path absolute = fs::absolute(requested_fs_path, error);
    if (error)
        return "babet.plugin.load: unable to resolve plugin path: " + error.message();

    const fs::path canonical = fs::canonical(absolute, error);
    if (error)
        return "babet.plugin.load: plugin path does not resolve to a file";

    if (!fs::is_regular_file(canonical, error) || error)
        return "babet.plugin.load: plugin path is not a regular file";

    prepared.canonical_path = canonical.string();
    if (path_already_loaded(runtime, prepared.canonical_path) ||
        same_file_already_loaded(runtime, canonical))
        return "babet.plugin.load: this shared object is already loaded in this Lua runtime";

    ::dlerror();
    void *handle = ::dlopen(prepared.canonical_path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle)
        return dl_error_message("babet.plugin.load: dlopen failed");
    DlHandleGuard handle_guard(handle);

    // Linux/glibc can return the same handle for another pathname referring to
    // an already-loaded DSO (for example a hardlink, bind mount, or a DSO that
    // was previously reached as another plugin dependency). Path/inode checks
    // above provide the common fast path; handle identity is the final runtime
    // identity before any second Lua function table is created.
    if (handle_already_loaded(runtime, handle))
        return "babet.plugin.load: this shared object is already loaded in this Lua runtime";

    ::dlerror();
    void *symbol = ::dlsym(handle, BABET_PLUGIN_QUERY_SYMBOL_V1);
    const char *symbol_error = ::dlerror();
    if (symbol_error || !symbol)
        return "babet.plugin.load: missing required symbol "
               BABET_PLUGIN_QUERY_SYMBOL_V1;

    babet_plugin_query_v1_function query = nullptr;
    static_assert(sizeof(query) == sizeof(symbol),
                  "POSIX dlsym function pointer size mismatch");
    std::memcpy(&query, &symbol, sizeof(query));
    if (!query)
        return "babet.plugin.load: invalid plugin query symbol";

    const babet_plugin_descriptor_v1 *descriptor = query();
    if (!descriptor)
        return "babet.plugin.load: plugin query returned a null descriptor";

    constexpr std::size_t required_descriptor_size =
        offsetof(babet_plugin_descriptor_v1, function_count) + sizeof(size_t);
    constexpr std::size_t required_function_size =
        offsetof(babet_plugin_function_v1, userdata) + sizeof(void *);

    if (descriptor->abi_version != BABET_PLUGIN_ABI_VERSION_V1)
        return "babet.plugin.load: unsupported plugin ABI version";
    if (descriptor->struct_size < required_descriptor_size)
        return "babet.plugin.load: plugin descriptor is too small";
    if (descriptor->reserved != 0)
        return "babet.plugin.load: plugin descriptor reserved field must be zero";
    if (descriptor->function_struct_size < required_function_size ||
        descriptor->function_struct_size > BABET_PLUGIN_MAX_FUNCTION_STRUCT_SIZE_V1 ||
        descriptor->function_struct_size % alignof(babet_plugin_function_v1) != 0)
        return "babet.plugin.load: incompatible plugin function declaration size";
    if (!copy_bounded_view(descriptor->name, kMaxPluginNameLength,
                           prepared.name))
        return "babet.plugin.load: plugin name is missing, invalid or too long";
    if (!copy_bounded_view(descriptor->version, kMaxPluginVersionLength,
                           prepared.version))
        return "babet.plugin.load: plugin version is missing, invalid or too long";
    if (descriptor->function_count == 0 ||
        descriptor->function_count > BABET_PLUGIN_MAX_FUNCTIONS_V1 ||
        !descriptor->functions)
        return "babet.plugin.load: plugin must declare between 1 and 256 functions";

    prepared.functions.reserve(descriptor->function_count);
    std::unordered_set<std::string> declared_names;
    declared_names.reserve(descriptor->function_count);

    const auto *function_bytes =
        reinterpret_cast<const unsigned char *>(descriptor->functions);
    for (std::size_t i = 0; i < descriptor->function_count; ++i)
    {
        const auto *declared = reinterpret_cast<const babet_plugin_function_v1 *>(
            function_bytes + i * descriptor->function_struct_size);

        std::string function_name;
        if (!copy_bounded_view(declared->name, kMaxFunctionNameLength,
                               function_name) ||
            !valid_function_name(function_name) || !declared->function)
            return "babet.plugin.load: invalid function declaration";

        if (!declared_names.insert(function_name).second)
            return "babet.plugin.load: duplicate function name in descriptor";

        auto registration =
            std::make_unique<NativePluginFunctionRegistration>();
        registration->name = std::move(function_name);
        registration->function = declared->function;
        registration->userdata = declared->userdata;
        registration->runtime = runtime;
        prepared.functions.push_back(std::move(registration));
    }

    *out_handle = handle;
    handle_guard.release();
    return {};
}

int lua_native_plugin_disabled(lua_State *state) noexcept
{
    lua_pushnil(state);
    const auto mode = static_cast<NativePluginMode>(
        lua_tointeger(state, lua_upvalueindex(1)));
    switch (mode)
    {
    case NativePluginMode::generated_application:
        lua_pushliteral(state,
                        "babet.plugin.load: native plugins are unavailable in generated --create-exe applications");
        break;
    case NativePluginMode::embedding:
        lua_pushliteral(state,
                        "babet.plugin.load: native plugins are unavailable in embedding hosts in Lot 11");
        break;
    case NativePluginMode::worker:
        lua_pushliteral(state,
                        "babet.plugin.load: native plugins are unavailable in workers");
        break;
    case NativePluginMode::allowed:
        lua_pushliteral(state,
                        "babet.plugin.load: internal plugin runtime is unavailable");
        break;
    }
    return 2;
}
} // namespace

NativePluginRuntime::NativePluginRuntime(lua_State *state) noexcept : state_(state) {}
NativePluginRuntime::~NativePluginRuntime() = default;

bool native_plugin_call_is_active(const babet_host_call *call) noexcept
{
    if (!call || !call->owner)
        return false;
    const auto *runtime = static_cast<const NativePluginRuntime *>(call->owner);
    return runtime->callback_active_ && runtime->active_call_ == call;
}

babet_status native_plugin_copy_result(
    babet_host_call *call, const babet_value *value) noexcept
{
    auto *runtime = static_cast<NativePluginRuntime *>(call->owner);
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
            runtime->result_string_storage_.assign(data,
                                                   value->as.string.length);
            result.as.string.data = runtime->result_string_storage_.data();
            result.as.string.length = runtime->result_string_storage_.size();
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
        set_callback_error(runtime, "out of memory while copying plugin result");
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (...)
    {
        call->setter_status = BABET_STATUS_INTERNAL_ERROR;
        set_callback_error(runtime, "unable to copy plugin callback result");
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

babet_status native_plugin_copy_error(
    babet_host_call *call, const char *message) noexcept
{
    auto *runtime = static_cast<NativePluginRuntime *>(call->owner);
    try
    {
        runtime->callback_error_storage_ = message;
        runtime->callback_fallback_error_ = nullptr;
        return BABET_STATUS_OK;
    }
    catch (const std::bad_alloc &)
    {
        runtime->callback_error_storage_.clear();
        runtime->callback_fallback_error_ =
            "babet plugin: out of memory storing callback diagnostic";
        return BABET_STATUS_OUT_OF_MEMORY;
    }
    catch (...)
    {
        runtime->callback_error_storage_.clear();
        runtime->callback_fallback_error_ =
            "babet plugin: unable to store callback diagnostic";
        return BABET_STATUS_INTERNAL_ERROR;
    }
}

int native_plugin_function_thunk(lua_State *state) noexcept
{
    auto *registration = static_cast<NativePluginFunctionRegistration *>(
        lua_touserdata(state, lua_upvalueindex(1)));
    NativePluginRuntime *runtime = registration ? registration->runtime : nullptr;
    if (!registration || !registration->function || !runtime)
        return luaL_error(state, "babet plugin: invalid native function closure");
    if (!same_native_plugin_runtime(state, runtime))
        return luaL_error(state, "babet plugin: native function belongs to another Lua runtime");

    const int argument_count = lua_gettop(state);
    const char *argument_setup_error = nullptr;
    try
    {
        runtime->arguments_.resize(static_cast<std::size_t>(argument_count));
    }
    catch (const std::bad_alloc &)
    {
        argument_setup_error = "babet plugin: out of memory preparing arguments";
    }
    catch (...)
    {
        argument_setup_error = "babet plugin: unable to prepare arguments";
    }
    if (argument_setup_error)
        return luaL_error(state, "%s", argument_setup_error);

    for (int i = 0; i < argument_count; ++i)
    {
        babet_value *argument =
            &runtime->arguments_[static_cast<std::size_t>(i)];
        if (read_plugin_argument(state, i + 1, argument) != BABET_STATUS_OK)
        {
            const char *type_name = luaL_typename(state, i + 1);
            return luaL_error(
                state,
                "babet plugin: function '%s' argument #%d has unsupported type %s",
                registration->name.c_str(), i + 1,
                type_name ? type_name : "unknown");
        }
    }

    clear_callback_storage(runtime);
    babet_host_call call{};
    call.arguments = runtime->arguments_.data();
    call.argument_count = static_cast<std::size_t>(argument_count);
    call.result.type = BABET_VALUE_NIL;
    call.result.as.integer = 0;
    call.owner = runtime;
    call.is_active = native_plugin_call_is_active;
    call.copy_result = native_plugin_copy_result;
    call.copy_error = native_plugin_copy_error;

    runtime->active_call_ = &call;
    runtime->callback_active_ = true;

    // The v1 plugin callback type is noexcept in C++. The official Babet binary
    // statically links libgcc/libstdc++, while ordinary C++ plugins usually use
    // the shared runtimes, so a host-side catch is not a reliable cross-DSO
    // exception boundary. Plugin authors must contain exceptions inside their
    // callback and translate them to babet_status + babet_host_call_set_error().
    babet_status callback_status =
        registration->function(&call, registration->userdata);

    runtime->callback_active_ = false;
    runtime->active_call_ = nullptr;

    if (!valid_status(callback_status))
    {
        callback_status = BABET_STATUS_INTERNAL_ERROR;
        set_callback_error(runtime,
                           "plugin callback returned an unknown babet_status");
    }
    if (callback_status == BABET_STATUS_OK &&
        call.setter_status != BABET_STATUS_OK)
        callback_status = call.setter_status;

    if (callback_status != BABET_STATUS_OK)
    {
        const char *detail = callback_error(runtime);
        if (detail && detail[0] != '\0')
            return luaL_error(state,
                              "babet plugin: function '%s' failed (%s): %s",
                              registration->name.c_str(),
                              babet_status_name(callback_status), detail);
        return luaL_error(state, "babet plugin: function '%s' failed (%s)",
                          registration->name.c_str(),
                          babet_status_name(callback_status));
    }

    push_plugin_result(state, call.result);
    return 1;
}

int lua_native_plugin_load(lua_State *state)
{
    auto *runtime = static_cast<NativePluginRuntime *>(
        lua_touserdata(state, lua_upvalueindex(1)));
    if (!runtime)
        return push_fail_protected(state, "babet.plugin.load: invalid plugin runtime");
    if (!same_native_plugin_runtime(state, runtime))
        return push_fail_protected(state,
                                   "babet.plugin.load: plugin runtime belongs to another Lua state");
    if (!lua_arity_is(state, 1) || !lua_is_strict_string(state, 1))
        return push_fail_protected(state, "babet.plugin.load: expected exactly one string path");

    std::size_t path_length = 0;
    const char *path_data = lua_tolstring(state, 1, &path_length);
    const std::string requested_path(path_data, path_length);

    PreparedPlugin prepared;
    void *handle = nullptr;
    const std::string error =
        prepare_plugin(runtime, requested_path, prepared, &handle);
    if (!error.empty())
        return push_fail_protected(state, error);

    DlHandleGuard handle_guard(handle);

    // Reserve every C++ owner before Lua starts building closures. This makes
    // the post-build commit allocation-free: closure pointers stay stable when
    // the unique_ptrs move into the runtime-owned vector.
    runtime->functions_.reserve(runtime->functions_.size() +
                                prepared.functions.size());
    runtime->loaded_paths_.reserve(runtime->loaded_paths_.size() + 1);
    runtime->loaded_handles_.reserve(runtime->loaded_handles_.size() + 1);

    PluginResultBuilder builder{&prepared};
    const int result_count = lua_build_results_protected(state, builder, 2);

    for (auto &registration : prepared.functions)
        runtime->functions_.push_back(std::move(registration));
    runtime->loaded_paths_.push_back(std::move(prepared.canonical_path));
    runtime->loaded_handles_.push_back(handle);

    // Successful plugins are deliberately never dlclose()'d. Their callback
    // code and plugin-owned userdata remain valid until process exit.
    handle_guard.release();
    return result_count;
}

void register_native_plugin(lua_State *state, NativePluginRuntime *runtime,
                            NativePluginMode mode)
{
    lua_newtable(state);

    if (mode == NativePluginMode::allowed && runtime)
    {
        // The registry is shared by every coroutine of one Lua global state.
        // Store the runtime identity there so plugin.load() and plugin functions
        // work from coroutines without accepting closures from another state.
        lua_pushlightuserdata(state, runtime);
        lua_rawsetp(state, LUA_REGISTRYINDEX, &kNativePluginRuntimeRegistryKey);

        lua_pushlightuserdata(state, runtime);
        lua_pushcclosure(state, native_plugin_boundary<lua_native_plugin_load>, 1);
    }
    else
    {
        lua_pushinteger(state, static_cast<lua_Integer>(mode));
        lua_pushcclosure(state, lua_native_plugin_disabled, 1);
    }
    lua_setfield(state, -2, "load");

    lua_setfield(state, -2, "plugin");
}
